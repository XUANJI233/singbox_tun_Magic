# 2026-07-01 断流 / 长连接断开排查日志

## 现象

- 用户反馈:使用中会断开代理,长连接会断开,代理似乎经常断流。
- 影响对象重点怀疑为 xHTTP / gRPC / WS 这类长连接传输,以及切网/休眠恢复后的首段连接。
- 当前没有真机连续日志,本轮先做代码路径审计 + AVD 临时数据检查。

## 当前可用证据

- 真机已复现到模块侧自造断流路径:
  - 旧运行配置中 `SBMAGIC_NETWORK_CHANGE_FLUSH=true`、`fake-ip`、`sniff=true`、`reject_quic=true`、`ruleset_download_detour=proxy`。
  - `control.log` 出现 `network watch event` 后接 `watchdog applying requested restart` 或 `recover(network-change)`。
  - 核心重启时 `utun0` 删除/重建会产生多行 `ip monitor` 事件,其中包含不带 `utun0` 的续行,旧判断会把这些行当作真实网络变化。
  - 真机切到稳定基线并应用 netwatch 修复后,用户反馈使用中已没有可感知断流和网络卡顿。
- 45 秒真机采样显示核心未被系统杀:
  - `pid=30907 alive=true state=S oom_adj=-900 api=401 tun=true` 持续稳定。
  - `logcat` 未看到 `lmkd` 或 ActivityManager 杀 `netd-helper`;只看到 KernelSU WebUI/WebView 沙箱进程被回收,属于面板容器状态丢失方向。
- 延迟拆分结果:
  - 手机裸 `curl https://www.gstatic.com/generate_204` 多数约 267-293ms,偶发 1.27s。
  - sing-box `direct` delay 与裸链路接近,说明 `direct 260-300ms` 主要是手机当前 HTTPS 链路基线,不是 TUN direct 单独引入的额外 200ms。
  - `us` xHTTP 节点 delay 常见 815-1398ms,且 `box.log` 有 `INTERNAL_ERROR` / `closed pipe`;这属于上游/CDN/xHTTP 链路问题,和本地自造断流是两条线。
- AVD 临时数据未运行正式代理链路,只能验证配置渲染和服务管理路径。
- 代码审计发现一个高优先级主动断连接路径:
  - `magicctl netwatch` 监听 `ip monitor route address link`。
  - 每次网络事件过冷却后调用 `recover_if_unhealthy "network-change"`。
  - 旧逻辑中只要 clash API 健康且 `SBMAGIC_NETWORK_CHANGE_FLUSH=true`,就会执行 `DELETE /connections`。
  - 这会主动关闭 sing-box 跟踪的所有运行连接,对 xHTTP/gRPC/WS 长连接表现为"突然断开后等待重连"。

## 假设排序

### H1: 网络事件恢复默认 flush 过于激进

预测:
- 如果真机 control.log 中频繁出现 `network watch event` 后接 `closing stale runtime connections`,断流时间点会与这些日志接近。
- 将 `SBMAGIC_NETWORK_CHANGE_FLUSH=false` 后,长连接无故断开频率应明显下降。

处理:
- 已将默认值改为 `SBMAGIC_NETWORK_CHANGE_FLUSH=false`。
- 已修改 `recover_if_unhealthy`:API 健康且 flush 关闭时只记录 `no connection flush configured`,不再误报或关闭连接。
- 网络事件恢复现在会用轻量 `/configs` 健康检查并短重试,避免 `/connections` 列表过重或刚唤醒 API 瞬时未就绪时误判为需要重启。
- API 健康但 TUN 接口明确不存在时也会重启核心,覆盖"进程没死但代理路径坏了"的半坏状态。

### H1b: 启动返回早于 API/TUN 就绪

预测:
- `magicctl start` 后立即看到 `running=true` 但 `api_alive=false` / `tun_alive=false`,几秒后才变成 true。
- 用户体感是"启动了,但刚开始没有代理"。

处理:
- `start_service_locked` 现在启动子进程后等待 API 和 TUN 同时就绪,最多 15 秒;超时只记录 warning,不盲目杀掉可能仍在初始化的核心。
- watchdog 模式下,外层 `start` 不再只看到 PID 文件就返回;它会等 runtime ready,并在网络事件监听开启时等 `netwatch` 也出现。
- 外层 `start` 现在会容忍刚 fork supervisor 后 `watchdog.pid` 尚未写入的短暂窗口,避免误报启动失败但后台随后才启动。

### H2: 核心进程被 LMKD/Doze/ROM 策略挂起或杀死

预测:
- 断流时 `pid` 变化、`fail_count` 增加、`control.log` 出现 watchdog restart/rollback。
- `current_oom_score_adj` 不符合预期,或系统日志有 lmkd kill 记录。
- 若 `pid` 不变但 `tun_alive=false`,属于"核心活着但 TUN 路径坏"方向;当前 recover 已会在网络事件后重启。

后续证据:
- 真机抓 `magicctl status` 前后对比。
- 抓 `logs/control`、`logs/run`、Android `logcat | grep -i lmkd`。

### H3: DNS / 远程 DNS 连接在空闲后假活

预测:
- 断流后不是核心重启,而是新域名解析卡住;已建立连接可能仍可用。
- `box.log` 出现 DNS exchange timeout / upstream timeout。

当前缓解:
- 默认本地 DNS 为 UDP `223.5.5.5`,远程 DNS 走代理 `https 1.1.1.1`。
- 若真机证据指向 DNS,需要单独比较 remote DNS 协议(https/tls/udp over proxy)和出站 keepalive。

### H4: 上游传输本身被 CDN/服务端/移动网络空闲回收

预测:
- 仅特定节点/传输断,切换节点或传输后改善。
- `box.log` 或服务端日志出现 EOF / reset / stream closed。

后续证据:
- 同一应用同一时间对比 xHTTP/gRPC/WS 或不同节点。
- 服务端日志按时间点对齐。

### H5: route/package 策略导致连接路径变化

预测:
- `strategy_process_lookup=true` 或策略文件里有大量 `packages.proxy/free-flow`。
- 清空强制策略后短连接/首连改善,但长连接主动断流不一定改善。

当前状态:
- 状态页已经暴露 `strategy_package_count` 和 `strategy_process_lookup`。

### H6: netwatch 管道子进程泄漏

预测:
- `magicctl stop` 后仍能在 `ps` 里看到孤儿 `ip monitor route address link`。
- 单个孤儿开销不大,但多次启停/调试后会积累,造成常驻空转和后续事件恢复行为不可预测。

处理:
- 已把 `netwatch` 从 shell 管道改为 FIFO + 显式 monitor PID 文件。
- `stop_netwatch` / `netwatch` trap / `uninstall.sh` 都会清理 `netwatch.monitor.pid` 对应的 `ip monitor` 子进程。

## 已做代码修改

- `SBMAGIC_NETWORK_CHANGE_FLUSH` 默认从 `true` 改为 `false`。
- `recover_if_unhealthy` 在 API 健康时:
  - flush 开启:记录并关闭旧连接。
  - flush 关闭:只记录 API 健康,不关闭连接。
- API 健康检查从 `/connections` 改为轻量 `/configs`,状态页若需要流量统计才单独读取 `/connections`。
- 启动后等待 API/TUN ready,减少"PID 存在但代理路径还没可用"的短窗口。
- recover 在 API 健康但 TUN 明确丢失时重启核心,避免半坏状态长期存在。
- `netwatch` 显式跟踪并清理 `ip monitor` 子进程,避免停止服务后留下孤儿事件监听进程。
- 模块主动重启核心时,会给 netwatch 设置短暂忽略窗口;窗口内忽略核心删除/重建自身 TUN 产生的所有 `ip monitor` 事件,包括不带接口名的续行,避免 reload/start/stop 自己触发二次恢复重启。
- `last-good` 延迟晋升任务同一时间只保留一个,频繁 reload 时不会临时堆出多份 `magicctl watchdog` 睡眠子进程。
- 导入生成的 `urltest(auto)` 默认从 3 分钟放缓到 10 分钟,容忍度从 50 调到 100,减少移动端后台测速和自动节点抖动。
- WebUI 设置说明更新:明确开启 flush 可能主动切断 xHTTP/gRPC/WS 长连接。
- 开发文档同步:netwatch 默认不再关闭健康长连接。
- 注意:模块升级不会覆盖既有 `/data/adb/singbox_tun_Magic/configs/settings.env`。已经安装过的设备需要在 WebUI 设置里手动关闭"切换网络断开旧连接",或把 `SBMAGIC_NETWORK_CHANGE_FLUSH=false` 写入运行配置。

## 真机下一轮抓取清单

断流后尽快导出:

```sh
magicctl status
magicctl logs control 300
magicctl logs run 300
magicctl logs box 300
```

若可用 adb/root:

```sh
logcat -d | grep -Ei 'lmkd|lowmemory|netd|dns|sing|netd-helper'
ip rule show
ip route show table all
```

重点对齐字段:

- `network_change_flush`
- `network_watch_running`
- `fail_count`
- `pid`
- `current_oom_score_adj`
- `strategy_process_lookup`
- `dns_mode`
- `ruleset_cache_time`

## AVD 验证记录

- `magicctl check/render` 通过;渲染结果包含白名单 sentinel、`ip_is_private -> direct`、`default_domain_resolver=local`、`download_detour=direct`、`urltest interval=10m`。
- watchdog + netwatch 启动返回 `rc=0`,状态同时满足 `api_alive=true`、`tun_alive=true`、`watchdog_running=true`、`network_watch_running=true`。
- `ip link set utun0 down/up` 产生的自身 TUN 事件没有触发重启;旁路出现的真实 `eth0/wlan0` 事件只执行健康检查,因 `network_change_flush=false` 记录 `no connection flush configured`,不关闭连接。
- `magicctl stop` 后 `ps` 中没有残留 `netd-helper`、`magicctl netwatch` 或 `ip monitor route address link`。
- 手动删除临时 `utun0` 后,netwatch 绕过冷却并重启核心,PID 从 `23804` 变为 `24511`,状态恢复为 `api_alive=true` / `tun_alive=true`;日志包含 `API healthy but tun missing; restarting service`。

## 真机验证记录

设备:
- Android 真机,KernelSU root 可用。
- 模块版本基线 `2026.07.01.2`,核心 `sing-box version 1.13.14-extended-a27453e`。
- 白名单入口包:
  - `io.github.forkmaintainers.iceraven` uid `10357`
  - `xyz.nextalone.nagram` uid `10425`
  - `nu.gpu.nagram` uid `10434`

### 进程/被杀判断

- 45 秒采样中核心稳定:
  - `pid=30907 alive=true state=S oom_adj=-900 api=401 tun=true`
- `/proc/<pid>/status`:
  - `Name: netd-helper`
  - `VmRSS: ~70MB`
  - `Threads: 14`
  - `oom_score_adj=-900`
  - cgroup: `cpu:/system`
- `logcat` 没有看到 `lmkd` 或 ActivityManager 杀 `netd-helper`。
- 看到的 KernelSU/WebView 沙箱回收只影响面板容器,不代表核心被杀。

### UID 入口分流

`ip rule` 显示白名单以外 UID 被 `goto 9010` 排除,白名单 UID 进入 `table 2022`:

```text
ip route get 8.8.8.8 uid 10357 -> dev utun0 table 2022
ip route get 8.8.8.8 uid 10400 -> dev wlan0 table wlan0
ip route get 8.8.8.8 uid 0     -> dev wlan0 table wlan0
```

结论:当前入口分流不是所有应用进 TUN。非白名单应用在内核路由层绕过 TUN,符合"非代理应用几乎无损耗"目标。

### 本机 LAN 延迟

本机在同一局域网开 HTTP 服务:
- PC: `192.168.1.201`
- 手机: `192.168.1.192`
- LAN ping: `10.0-16.0ms`,平均 `13.2ms`

小文件 HTTP:
- root/非 TUN 路径:多数 `7-19ms`
- 白名单 UID 经 TUN:
  - `gvisor`:多数 `8-23ms`
  - `system`:多数 `10-18ms`
  - `mixed`:多数 `8-26ms`

结论:局域网低延迟下,TUN 入口没有引入可见的几十毫秒级额外延迟。`system` 和 `mixed` 在本机上没有明显领先 `gvisor`。

### 本机 LAN 吞吐

本机 HTTP 服务返回 32MB 文件,手机下载到 `/dev/null`:

```text
root bypass: 约 90-106 MB/s,偶发首包/缓存离群
gvisor uid TUN: 101-103 MB/s
system uid TUN: 99-102 MB/s
mixed uid TUN: 101-105 MB/s
```

结论:在当前 Wi-Fi/LAN 条件下,TUN 栈不是吞吐瓶颈。三种栈都能工作,但没有证据支持把默认值从 `gvisor` 改成 `system` 或 `mixed`。

### native TUN 与 HEV 路径能耗对比

新增可复跑脚本:

```text
bench/android-tun-energy-compare.sh
```

采样口径:
- 同一真机、同一 Wi-Fi、同一 PC 局域网 HTTP 服务器。
- 白名单 UID `10357` 访问 `http://192.168.1.201:18081/32m.bin`。
- 每种模式记录 32MB 下载耗时、吞吐、核心/HEV CPU jiffies、RSS、线程数、电池 current_now/charge_counter/温度。
- 本轮手机处于充电状态,`charge_counter` 增长,所以不能把电池字段当作真实放电量;能耗比主要看 CPU jiffies / MB、RSS 和是否产生额外进程。

有效 native 样本:

```text
log: /data/adb/singbox_tun_Magic/logs/tun-energy-compare-20260701-223348.log
mode: native-singbox-tun
runs: 8 x 32MB = 256MB
avg: 67.36 MB/s
median: 70.05 MB/s
avg time: 0.673s / 32MB
median time: 0.549s / 32MB
core cpu_delta: 129 jiffies
cpu/traffic: ~0.50 jiffies/MB
core RSS: ~62MB
threads: 13
temperature: 32.2C -> 32.3C
```

HEV 路径验证:
- Linux arm64 预编译 HEV 可启动但不能正常转发;官方讨论也提示该预编译版不适合 Android root 场景。
- 已用 Android NDK 29 从 `heiher/hev-socks5-tunnel` 源码构建 arm64 版:
  - `hev-socks5-tunnel 2.15.0 67dfba5`
  - 产物大小约 `238KB`
- 已检查 `2dust/v2rayNG` 的 HEV 集成:
  - `compile-hevtun.sh` 同时构建两种产物:
    - `libhev-socks5-tunnel.so`: VPN 模式 JNI 库,由 `TProxyService` 在进程内加载。
    - `libhevsockstun.so`: Root 模式 standalone 可执行文件。
  - VPN 模式不是让 HEV 自己打开 `/dev/net/tun`;它由 `VpnService.Builder.establish()` 先创建 `ParcelFileDescriptor`,再把 `vpnInterface.fd` 传给 HEV JNI。
  - Root 模式确实让 standalone HEV 自建 TUN,但配套了完整 mangle/fwmask 路由:HEV 建 `v2raytun0`,额外加 `198.18.0.1/15`,`iptables -t mangle OUTPUT` 按 uid/模式打 mark,`ip rule fwmark -> table`,再把该 table 默认路由指向 HEV TUN。
- 后端 socks 核心可用:
  - sing-box extended `1.13.14` socks direct 健康检查通过。
  - Xray `26.3.27` socks direct 健康检查通过。
- 但 `hev+sing-box` 与 `hev+xray` 作为 TUN 入口均未跑通:
  - `ip route get 192.168.1.201 uid 10357 -> dev tun_hev0 table 2023`
  - `tun_hev0` 已 `UP, LOWER_UP`
  - 每次 curl 均 `Connection timed out after 5002ms`
  - `tun_hev0` 只出现 48B/1packet 的 TX 增量,`RX` 始终为 0
  - HEV 进程 CPU 增量为 0,后端 core 没有收到来自 HEV 的有效转发连接
- 已把测试脚本改成接近 v2rayNG Root 模式的 mangle/fwmask/default-route 方式,并对齐 HEV 配置:
  - `multi-queue: true`
  - `udp: 'udp'`
  - `tcp-fastopen: true`
  - `198.18.0.1/15`
  - `ip route get ... mark 0x5342 -> dev tun_hev0 table 2024`
  - 结果仍为 5s 超时,HEV CPU 增量仍为 0,TUN RX 仍为 0。
- 进一步用 `strace`/`tcpdump` 定位后,问题收敛到 HEV root 模式的入口抓包层:
  - `strace` 显示 HEV 已成功打开 `/dev/net/tun`,并且 `TUNSETIFF` 成功。
  - `ip route get 192.168.1.201 uid 10357` 和 `ip route get ... mark 0x5342` 都显示目标会进 HEV 测试表和 `tun_hev*`。
  - 但 `tcpdump -i tun_hev*` 只抓到 IPv6 multicast listener / router solicitation,没有抓到应用请求应有的 IPv4 TCP SYN。
  - HEV 日志停在 `socks5 tunnel run` / `lwip task run`,没有新 session;Xray access log 也只看到手动 socks 健康检查,没有 HEV 转发连接。
  - 停掉本模块后再看 `ip rule` 和 `table 2022`,模块规则已清理,没有 stale route 与 HEV 测试表冲突。

结论:
- 当前真机 root standalone HEV 不是"性能较差",而是没有形成可用数据面,不能拿来和 native TUN 做吞吐/耗电正面对比。
- 已能排除:后端 socks 不通、HEV 二进制无法打开 TUN、当前模块 table 2022 残留冲突。
- 当前更像是 Android 16/root 环境下,standalone HEV 的 `fwmark`/`uidrange` 捕获路径没有把应用 IPv4 包交给 HEV TUN;继续深挖应抓 `wlan0`/`any`/`tun_hev*` 三侧包,确认 IPv4 SYN 是被系统路由丢弃、绕出真实网卡,还是被 Android 网络策略拒绝。
- 按 HEV 官方 README 的 Linux 模型补测后,结论进一步细化:
  - 官方模型要点是 `socks5.mark=438`、关闭 `rp_filter`、`fwmark 438 -> main` 绕开上游 socks、其余流量默认进 HEV TUN。
  - 新增复跑脚本:
    - `bench/android-hev-official-route.sh`
    - `bench/simple-socks5-server.mjs`
  - PC 侧临时 SOCKS5 已验证可用:手机 `curl --socks5 192.168.1.201:10808 http://192.168.1.201:18081/1m.bin` 返回 `code=200`。
  - 官方模型下 HEV 能收到业务包,TUN 计数明显增加,CPU 也从 0 变为有效消耗;这说明 HEV 数据面不是完全不能工作。
  - 但连接没有完成,并出现上游 socks 递归:日志只有 1 条目标 `192.168.1.201:18081`,随后出现数千条 `socks5 client tcp -> 192.168.1.201:10808`。
  - `strace` 确认 `setsockopt(SO_MARK, 438)=0`,mark 设置成功;随后 HEV 用 IPv4-mapped IPv6 socket 连接上游 socks:`AF_INET6 ::ffff:192.168.1.201:10808`。
  - 即使把规则改成 `fwmark 0x1b6/0xffff -> main`,上游 socks 连接仍会重新进入 HEV,形成递归。
  - Android connect 路径会访问 `/dev/socket/fwmarkd`;这和普通 Linux README 的 policy routing 环境不同。当前 evidence 指向:Android root standalone HEV 缺少可靠的 upstream protect/bypass,不是单纯少一条 README 规则。
- `sockstun` 不是 root standalone 替代品,而是 Android `VpnService` app:
  - `TProxyService` 继承 `VpnService`。
  - 用 `VpnService.Builder.establish()` 创建系统 VPN TUN fd。
  - 用 `addAllowedApplication`/`addDisallowedApplication` 做 per-app。
  - 最后把 `tunFd.getFd()` 传给 HEV JNI: `TProxyStartService(configPath, tunFd.getFd())`。
  - 这条路线能避开 root standalone 的 fwmark/上游绕行问题,但会改变当前模块架构,也会进入 Android VPN 模式。
- v2rayNG 最值得借鉴的是 VPN/JNI fd 模式:由 Android VPN 层创建 TUN fd,HEV 只消费 fd;这条路线需要一个 Android app/VpnService,不适合直接塞进当前纯 root 模块作为默认入口。
- v2rayNG Root 模式可以作为后续深挖参考,但本机按其核心路由思路复测仍失败;继续投入前应先用 `strace/tcpdump` 定位 HEV standalone 为什么不消费 TUN 包。
- **根因已定位并用真机路由表直接验证**:`bench/android-hev-official-route.sh` 已经按官方 README 加了 `ip -6 rule add fwmark ... lookup main`(IPv4/IPv6 都有对应 bypass 规则),但 mask 版复测(`HEV_SOCKS_MARK_MATCH=0x1b6/0xffff` + strace)仍然递归超时。直接读路由表后原因清楚:
  - `ip -6 route show table main` 返回**完全空**;`ip route show table main`(IPv4)只有各接口的本地子网直连路由(`10.130.132.224/28 dev rmnet_data2`、`192.168.1.0/24 dev wlan0`、`172.19.0.0/30 dev utun0` 等),**同样没有默认路由**。
  - 设备本身有真实可用的 IPv4/IPv6 连通性——`ip route get 8.8.8.8` 和 `ip -6 route get 2606:4700:4700::1111` 都能正确解出目标,但落地的是 `table rmnet_data2`(按接口划分的专属路由表),不是 `main`。
  - 也就是说 Android(至少本机 ROM)**根本不把默认路由放进 `main` 表**;真正生效的默认路由动态挂在当前"获胜"网络接口的专属表里,由 netd 维护的一长串 `ip rule` 优先级链决定当前该走哪张表,且这张表会随 Wi-Fi/蜂窝切换而变化。
  - 结论:HEV 官方 README 那套"给自己的上游连接打 mark,再用 `ip rule ... lookup main` 把它从自己的 TUN 里摘出去",这个模型在 Android 上**从架构层面就无法生效**——不是规则写漏了、mask 不对、或 mark 没打上(strace 已确认 `setsockopt(SO_MARK)=0` 成功),而是它假设的目标表(`main`)在 Android 上本来就是空的。要让这个模型在 Android 上工作,bypass 规则必须动态指向"当前实际生效的那张接口专属表"而不是固定写死 `main`,且要随网络切换实时更新——这正是 `VpnService.protect(fd)` 这个 Android 系统 API 存在的原因(它由系统内部处理"让这一个 socket 绕开当前生效的 VPN/TUN,不管现在是哪个物理接口在负责默认路由"),而这个 API 只对已注册的 `VpnService` 开放,纯 root CLI 进程无法调用。这也是 `sockstun`(HEV 作者自己的配套实现)选择做成 Android VpnService app 而不是 root standalone 的根本原因。
- 现阶段不建议把模块切到 `hev+xray` 或 `hev+sing-box`。native sing-box TUN 是当前唯一已跑通、能稳定测量、且入口分流语义正确的方案。若未来仍想用 HEV 的 lwIP 数据面,唯一架构正确的路径是走 Android `VpnService` + JNI fd(即 v2rayNG 的模式),而不是给当前纯 root 模块加一层 iptables/fwmark 脚本。

### 找到 benchmark 用可行方案:按目的地路由,不按 uid/mark

前面所有失败尝试(iptables mark、`ip rule` uid 直查、目的地路由丢进 `main`)都在处理"应用级/uid 级"重定向,而 Android 的 `fwmarkd`/按 uid 网络选择层恰好卡在这条路径上。改用**纯目的地匹配**后问题消失:

```sh
ip route replace default dev $TUN table $TABLE_ID
ip rule add to $SERVER_IP lookup $TABLE_ID pref 100
```

不经过 iptables、不打 mark、不按 uid。`tcpdump` 抓到完整 TCP 三次握手 + HTTP 请求/响应 + 四次挥手,HEV 日志显示 `socks5 client tcp -> [1.1.1.1]:80` 到 `socks5 session tcp splice` 全流程正常,`curl` 拿到 `code=301`。

原因:目的地匹配规则不涉及"这个包属于哪个应用、该走哪张网卡"的判断,`fwmarkd` 的按 uid 网络选择层没有介入空间;HEV 自身连本地 SOCKS5 后端(`127.0.0.1`)也不需要额外的 bypass 规则,因为回环流量天然由优先级最高的 `lookup local`(pref 0)规则处理,永远轮不到我们加的这条规则。

**范围说明**:这个方案只适用于"benchmark 场景下,固定已知目标 IP 的吞吐/CPU 对比测试",不能直接用于生产环境"透明代理某个 App 的任意流量"——那仍然需要按 uid 分流,仍然会撞上同一个 `fwmarkd` 限制。

`bench/android-tun-energy-compare.sh` 已按此方案重写 `start_hev()`(移除 iptables mangle chain、`HEV_SOCKS_MARK`、`HEV_BYPASS_PREF` 等全部 mark/uid 相关变量,`RULE_PREF` 默认改为 `100`)。

### 真机最终吞吐/CPU 对比(2026-07-02)

同一局域网,PC 端 `192.168.1.201:18081` 提供 32MB 静态文件,每种模式 8 次下载:

| 模式 | 成功率 | 平均速度 | CPU 增量(256MB 总量) | jiffies/MB |
|---|---|---|---|---|
| native-singbox-tun | 8/8 | ~107 MB/s | 81(核心单进程) | **0.32** |
| hev-singbox(HEV + sing-box socks 后端) | 8/8 | ~95 MB/s,波动明显更大(69-108 MB/s) | 66(sing-box)+ 133(HEV)= 199(两进程合计) | **0.78** |
| hev-xray(HEV + Xray socks 后端) | **0/8**,全部超时 | — | xray RSS 从 40MB 涨到 293MB、CPU 大涨但零成功请求 | 数据面异常,不可用 |

结论:
- **HEV 数据面本身没问题**——hev-singbox 组合 8/8 成功,吞吐量和 native 同一数量级。
- **但同等吞吐下,CPU 成本约为 native 方案的 2.5 倍**(0.78 对 0.32 jiffies/MB),符合预期:HEV 方案多一条链路(App → HEV tun → lwIP → SOCKS5 → sing-box → 直连)、多一个常驻进程,比 native(App → sing-box tun → 直连)多一跳。
- 这为项目最初"放弃三层拆分、改用单进程原生 TUN"的架构决定(见 `singbox-module-dev.md` §0)提供了真机数据支撑,不再只是基于复杂度的主观判断。
- `hev-xray` 全部失败是一个独立问题(疑似 Xray 自身 SOCKS5 实现或它与 HEV 交互的 bug),超出本次"HEV vs sing-box"对比范围,未继续深挖。

### 补充排查:源码级三个假设(非阻塞 fd / 边缘触发 / iptables 链顺序)与最终收敛

在"官方 README 路由模型"确认递归之后,继续用 `heiher/hev-socks5-tunnel` 本地源码(NDK 29 构建,`67dfba5`)排除了 HEV 自身代码的问题,并最终把根因收敛到 Android 的 `fwmarkd` 路由架构:

1. **HEV standalone 的 tun fd 未设非阻塞**:`hev-tunnel-linux.c` 的 `hev_tunnel_open()` 只做 `open("/dev/net/tun")` + `TUNSETIFF`,没有像 `hev-socks5-tunnel.c` 里 `tunnel_init()` 处理外部(JNI/VpnService)传入 fd 那样调用 `ioctl(fd, FIONBIO, ...)`。已patch 并重新编译(`hev-linux-arm64-patched`),真机复测:症状不变(`hev_cpu_delta=0`,`tun_rx_delta=0`)。**已排除**:不是阻塞 I/O 卡死调度器的问题。
2. **`hev-task-system` 的 epoll 固定用 `EPOLLET`(边缘触发)**:`hev-task-io-reactor-epoll.h` 里 `event->event.events = events | EPOLLET`,怀疑首次 `EPOLL_CTL_ADD` 与首个包到达之间存在漏边沿的竞态。已 patch 去掉 `EPOLLET`(退化为水平触发)并重新编译(`hev-linux-arm64-lt`),真机复测:症状依旧不变。**已排除**。
3. **`tcpdump` 直接抓包确认**:在 `tun_*` 设备上抓包,全程只看到 3 个 IPv6 背景包(MLDv2 报告 ×2、路由请求 ×1),**0 个** 目标地址的 IPv4 TCP SYN;`iptables -t mangle -L $CHAIN -n -v` 显示按 `-m owner --uid-owner` 打标记的规则命中 **0 个包、0 字节**,尽管 `su $APP_UID -c curl`(不接入任何自定义路由)在同一台设备上直接访问 `1.1.1.1` 能在 0.6 秒内拿到正常的 `HTTP 301`(证明"用 su 假扮目标 uid"这一步本身完全可靠)。
4. **发现厂商 OUTPUT 链遮挡**:`iptables -t mangle -S OUTPUT` 显示本机(高通平台 ROM)在 OUTPUT 链最前面有 `tc_limiter_OUTPUT`(`owner UID match 0-4294967294`,几乎覆盖所有 uid)、`tc_wmm`、`qcom_NWMGR` 等厂商流控/QoS 自定义链。所有 HEV bench 脚本此前都用 `iptables -A OUTPUT -j $CHAIN`(追加到链尾),排在这些厂商链之后。把规则改成 `iptables -I OUTPUT 1 -j $CHAIN`(插入到链首,和本模块自己 `apply_api_firewall()` 里 clash API 防火墙的写法一致)后,复测命中数从 **0 → 5 个包 / 300 字节**——确认这是一个真实、可复现、已修复的 bug。
5. **但插入到链首后,`tcpdump` 在 tun 设备上依然只看到同样 3 个 IPv6 背景包,0 个真实 SYN;HEV CPU 依然为 0**。也就是说打标记这一步已经成功,但**依据这个标记改变路由的那一步仍未生效**。收敛到的解释:Android 的 `connect()` 系统调用会先经过 `/dev/socket/fwmarkd` 决定这次连接走哪张路由表,这个决策发生在数据包真正构造/发出**之前**;`iptables mangle OUTPUT` 之后再改 `SKB` 的 fwmark 值,不会让内核回头重新执行这个已经做完的路由决策。

**统一结论**:上面 3 个独立方向(`main` 表为空、厂商链遮挡、`fwmarkd` 提前定死路由)其实是同一件事的三个表现——**Android 用自己的 `fwmarkd` + 按接口分表 + netd 维护的 `ip rule` 优先级链,取代了传统 Linux "打 mark 事后走 `ip rule` 改路由"这套机制**,HEV 官方 README 面向纯 Linux 设计的透明代理方案,在这三个层面都撞上了同一堵墙。这不是 HEV 代码质量问题(两个 C 源码级假设都已用真实 patch+重新编译+真机测试排除),也不是简单的脚本 bug(厂商链遮挡是真 bug 且已修复,但修复后症状仍未消失)。

**对"修复难度"的最终判断**:要在不使用 `VpnService` 的纯 root 场景下让 standalone HEV(或任何基于"事后打 mark 改路由"思路的 tun2socks 实现)在这类厂商 ROM 上正确工作,需要在 `connect()`/路由决策发生**之前**就让目标流量走向我们的 tun,而不是事后补救——这基本等价于要重新实现一套 Android 自己的 `fwmarkd`/`netd` 按 uid 路由逻辑,复杂度和维护成本远超"改几行配置",不建议投入。当前模块用 sing-box 自身的 `include_package`/`exclude_package`(对应到 Android 原生支持的 uid-range `ip rule`,在连接发生前就生效)是这条路的正确解法,这也是它没有踩到上述任何一个坑的根本原因。
- 官方 [Benchmarks wiki](https://github.com/heiher/hev-socks5-tunnel/wiki/Benchmarks) 核实后确认测试环境是两个 Linux network namespace 通过 veth 对连(host `eth0` 192.168.0.8,guest `veth0/veth1` 192.168.1.1/.2),tun0 用 MTU **8500**、`multi-queue`。命名空间是纯内核构造,没有 Android netd 的按接口分表机制,`main` 表在命名空间里就是唯一真实生效的表,所以官方模型在那个环境里天然成立。单流 32.8 Gbit/s、十流 113 Gbit/s 本质是同一内核里两块 veth 网卡间的内存拷贝吞吐,不涉及真实无线链路,不能作为 Android root 场景的参考基线。
- 追加验证了一个理论上应该更稳的替代方案:不再尝试把 HEV 自己(uid 0)的上游连接从它自己的 TUN 里"绕出去"(这条路已证明在 Android 上不成立),而是从源头上只把目标 App 的 uid 流量 mark 进 HEV 的 TUN,HEV 自身的 root 流量完全不参与这套 mark/路由,天然不需要任何 bypass 规则。同时按队列亲和性怀疑复测了 `multi-queue: false`(排查"包被投到 HEV 没在读的队列"这类问题)。
  - 结果:两种 `multi-queue` 设置下现象一致——`ip route get <目标> uid <APP_UID>` 和 `uid 0` 都能正确解析到真实默认路由;`iptables -t mangle --uid-owner <APP_UID>` 打标成功;但发起请求后 `tun_rx_delta=0`、`hev_cpu_delta=0`,只有 2-3 个包的 `tx_delta`(内核往接口方向递了包),5 秒超时。HEV 日志停在 `event task run` 之后再无新会话。
  - 结论:排除了 mark/bypass 规则写法和 multi-queue 队列亲和性这两类假设。问题收敛到更底层——HEV 已经 `TUNSETIFF` 成功、接口 UP、内核也确实往接口方向投递了包,但 HEV 自身的 lwIP 读循环表现为完全没有收到数据(CPU 增量为 0,不是"收到但处理失败")。继续定位需要 `bpftrace`/`ftrace` 级别跟踪 HEV 进程对 tun fd 的 `read()` 系统调用返回值和 errno,确认是内核没有实际投递到该 fd,还是 SELinux/seccomp 在这一层静默拦截了读取——这已经超出配置调整能解决的范围。
  - 现阶段判断:**没有再值得尝试的配置层面办法**。Android root standalone HEV 卡在比路由策略更底层的一层,唯一已知可行的路径仍是 `VpnService` + JNI fd 模式(需要一个真正的 Android VPN app,不是给当前 root 模块加脚本)。

### 控制面空闲能耗

15 秒空闲采样:

```text
log: /data/adb/singbox_tun_Magic/logs/control-plane-idle-cpu-20260701-224102.log
watchdog delta_jiffies=0
netwatch delta_jiffies=0
ip monitor delta_jiffies=0
promote-last-good delta_jiffies=0
```

结论:
- 当前 watchdog/netwatch/promote timer 都是阻塞式等待,核心正常时没有可见 CPU 空转。
- 把这些逻辑迁到 init 本身不会明显降低耗电;如果只是 init 拉起同一套脚本,能耗不变。
- 真正影响耗电的是数据面栈、远端连接稳定性、DNS/规则冷启动、以及应用短连接数量。

### 公网延迟拆分

- 手机裸 `curl https://www.gstatic.com/generate_204`:多数约 `230-290ms`,偶发 `1s+`。
- sing-box `direct` delay 与裸链路接近。
- 当前 `us` xHTTP 节点常见 `700-1400ms`,并出现 API delay 超时。
- `box.log` 有 `INTERNAL_ERROR` / `closed pipe`。

结论:
- `direct 260-300ms` 主要是手机当前 HTTPS 公网路径基线,不是 TUN direct 单独造成。
- proxy 慢和断续更偏上游/CDN/xHTTP 节点链路问题,不是本地 TUN 栈问题。

### DNS 自动化限制

- 用 `su <app_uid>` 假扮应用进程时,域名解析直接失败;固定 IP/`--resolve` 请求可成功。
- 这说明 UID shell 没有正常 App resolver 上下文,不能用它判断真实 App 的 DNS 行为。
- `real-ip` / `fake-ip` 都能 `check` + `reload` 并保持 `api_alive=true` / `tun_alive=true`;真实域名解析仍需通过实际 App 操作或专门 DNS 日志来验证。

### init service

- 当前运行状态:
  - `init_service=true`
  - `init_service_seen=none`
  - `getprop init.svc.netd_helper` 为空
- rc 文件存在于模块 overlay: `/data/adb/modules/singbox_tun_Magic/system/etc/init/netd-helper.rc`。
- 当前不重启无法证明 init service 会被系统 init 加载;本轮运行仍是手动/`service.sh` 路径拉起的 watchdog。
- 结论:需要一次真机重启后再看 `init_service_seen` 和 `getprop init.svc.netd_helper`。

### init 与 watchdog 的职责边界

- init 适合做系统入口和开机兜底。
- 当前 watchdog 是事件式 supervisor,核心正常时阻塞在 `wait "$pid"`,不参与数据转发。
- `netwatch` 阻塞在 `ip monitor route address link`,只处理系统网络事件。
- `promote-last-good` 是一次性延迟计时任务,只在配置稳定后保存 last-good。

结论:
- 把崩溃重启、last-good 回滚、手动 reload 协调全部迁到 init,不会改善网络延迟或吞吐。
- 如果只是让 init 运行一个包装脚本,本质上还是同一个 supervisor,只是进程父子关系变化。
- 如果完全依赖 Android init 的重启能力,会丢失动态配置预校验、last-good 回滚、reload 协调、API firewall 和 TUN 事件静默窗口这些模块逻辑。
- 更合理的取舍是:保留 init 作为启动入口,保留轻量 supervisor 做模块控制面。若未来要减少 shell 进程观感,应把 supervisor 做成小型原生 helper,而不是为了性能把逻辑塞进 init。

## 运行期性能审计

### 已确认不是当前问题

- **状态页不再比较大二进制**:`status()` 只读运行状态和缓存版本;`prepare_process_binary()` 用 inode / size+mtime 指纹判断新鲜度,没有 `cmp -s` 全量读 `.core` 和运行名。
- **WebUI 没有定时轮询**:状态页只在进入页面或点击刷新时调用 `magicctl status`;只有 `running=true` 且 `api_alive=true` 时才额外读一次 `/connections` 做流量显示。
- **应用页保存已批量化**:`config set-per-app` 一次写入入口名单、策略名单和 `SBMAGIC_PACKAGE_MODE`,只做一次临时渲染 + `sing-box check`;旧路径最多会连续校验 4 次。
- **watchdog 不是轮询看门狗**:父进程阻塞在 `wait "$pid"`,核心正常运行时不会周期性唤醒。`promote_last_good_later` 是每次启动后一次性的延迟晋升,不是循环巡检。
- **netwatch 是事件式**:阻塞在 `ip monitor route address link`;当前实现会记录 monitor PID 并在 stop/trap/uninstall 清理,避免停止后留下孤儿监听进程。
- **白名单入口不会空列表退化成全量接管**:白名单模式会写 sentinel `include_uid=4294967294` 与 `include_package`,空白名单时没有真实应用进入 TUN。
- **默认不 sniff**:`SBMAGIC_SNIFF=false`,首包不等待 SNI/HTTP Host 嗅探。
- **real-ip 域名分流重新接上**:`dns.reverse_mapping=true` 默认开启,route 层可以通过 DNS 缓存把目标 IP 回查到域名;DNS 层也把 `geosite-cn` 交给本地解析,不再只靠 `.cn` 后缀和 `geoip-cn` 单保险。
- **加密 DNS 不再依赖 IP SAN 巧合**:DoH/DoT/DoQ/DoH3 支持单独的 `SBMAGIC_DNS_*_TLS_SERVER_NAME`,默认远程 `1.1.1.1 + cloudflare-dns.com`,用户换 Google/Quad9 时可填对应证书域名。

### 仍需注意的性能/稳定性取舍

- **gvisor 栈仍是主要转发开销**:AVD 中 system/mixed 不是可靠路径,所以默认保留 gvisor。真实机若 system 栈可用,仍可单独对比,但不能作为默认。
- **远程 DNS 经 proxy**:`dns.final=remote` + remote DNS `detour=proxy` 能防 DNS 泄漏,但代理链路抖动时新域名解析会慢;这会表现为"新连接打不开",不一定是长连接真的断。CN/直连域名现在会优先用本地 DNS,减少这种冷启动绕路。
- **DNS 独立失败预算暂不硬塞配置字段**:sing-box 官方 `dns.timeout` / DNS rule action `timeout` 是 1.14 系列字段,当前模块核心是 1.13.14-extended。为了避免升级前被 `sing-box check` 拒绝,本轮不渲染这些字段;后续升级核心后再把 `SBMAGIC_DNS_TIMEOUT` 做成受版本保护的配置项。
- **规则集默认本地预置**:打包时预取 geosite-cn / geoip-cn `.srs`,安装时复制到 `$CACHE_DIR/rulesets`,渲染时优先使用 `type: local`。`SBMAGIC_RULESET_DOWNLOAD_DETOUR=direct` 只用于本地文件缺失后的远程兜底,避免首次启动出现规则下载/代理就绪互相等待。规则文件时间已在状态页展示;直连无法更新时再切到 `proxy`。
- **只有非默认策略侧需要包名识别**:`packages.proxy/free-flow` 是 route 层强制策略。渲染时会跳过与 `SBMAGIC_MIXED_RULE_PRIORITY` 相同的一侧,所以默认代理优先下,`packages.proxy` 不再生成 `package_name` 条件;只有少数强制走另一侧策略的应用才需要包名/进程识别。
- **auto_redirect 不是 UDP/QUIC 加速器**:Android 上它主要优化 IPv4 TCP。应用侧 HTTP/3/QUIC 仍走 UDP/gVisor 路径;`SBMAGIC_REJECT_QUIC=false` 默认关闭,只有确认设备被 UDP/443 成本拖慢时才建议开启,让应用回退 TCP。Hysteria2/TUIC/QUIC 节点出站不受这个路由拒绝规则影响。
- **UDP 超时已改成自动默认**:`SBMAGIC_UDP_TIMEOUT=auto` 会在渲染时落成实际时长:普通配置 `5m`,Full Cone NAT 时 `10m`,拒绝 QUIC 时 `2m`;仍可手动填 `2m`/`5m`/`10m` 等 Go duration。
- **手动 reload 会重启核心;ruleset-refresh 条件重启**:sing-box clash API 没有真实热重载配置接口,所以配置 reload 会重建 TUN 并打断已有连接。`ruleset-refresh` 只在 `bypass-cn` 规则集正在使用且核心运行时 reload;停机或未使用规则集时只更新本地 `.srs` 文件。这不是后台自发断流。
- **手动切换 selector 会影响连接**:导入生成的 selector 仍保留 `interrupt_exist_connections=true`,用户主动切节点时旧连接会被切断,新连接立即走新节点;这属于显式操作。

### 2026-07-02 真机审计补充

只读审计结论:
- auto_redirect IPv4 TCP 快路径在真机实测生效:NAT `sing-box-output` REDIRECT 只处理首包,SYN 后数据没有进 `utun0`;此前 0.32 jiffies/MB 是快路径状态。
- IPv6 防泄漏在内核路由层验证通过:白名单 UID 的 v4/v6 都落入 `table 2022 -> default dev utun0`,非白名单 UID 绕过。
- 非代理流量零成本目标达成:非代理 30 秒窗口 wlan0 约 891MB,核心 CPU 只增加 2 jiffies,tun 零流量。
- watchdog/ip monitor 基本静默;核心 27 分钟累计约 1 秒 CPU,RSS 约 70MB,14 线程。

发现并处理:
- RA/IPv6 地址 lifetime 刷新会每 8-15 分钟触发一次 `ip monitor` 地址事件,旧 netwatch 会做一次健康检查。已新增 IPv6 地址快照,对已知地址的 `inet6 ... valid_lft/preferred_lft` 刷新直接忽略;新地址、删除地址、link/route/default 变化仍会触发恢复检查。
- 已新增 `cleanup_netwatch_fifos`,在 netwatch 启动和停止时清理 `runtime/netwatch.events.*` 孤儿 FIFO。SIGKILL 本身无法执行 trap,但下一次 stop/start 会清掉残留。
- 已新增网络恢复细调项:`SBMAGIC_NETWORK_SETTLE_DELAY`、`SBMAGIC_NETWORK_HEALTH_RETRIES`、`SBMAGIC_NETWORK_HEALTH_RETRY_DELAY`、`SBMAGIC_NETWORK_OWN_TUN_GRACE`,避免把 ROM 刚切网/刚重建 TUN 的短暂状态当成需要重启。
- IPv6 已从旧布尔改成 `SBMAGIC_IPV6_MODE=auto/proxy/block/off`:默认 `auto`,按内核当前 IPv6 路由结果自动选择运行时有效模式;无默认 IPv6 出口按 `off` 渲染,有 IPv6 但短探测不通按 `block` 渲染。手动 `proxy` 是强制开启,不会被自动回退覆盖。
- 已修正 `settings.env` 的 auto_redirect 注释:Android 上是 iptables REDIRECT 快路径,不是 nftables 依赖。
- 已优化策略渲染:与 `SBMAGIC_MIXED_RULE_PRIORITY` 相同的一侧不再生成 `package_name` 规则。当前常见的白名单 + 代理优先配置下,即使 UI 中 `packages.proxy` 与入口白名单相同,route 层也不会再触发每连接包名识别。
- 已把配置渲染从 2800+ 行 shell 主控中拆出到 `tools/magicctl-go/`:shell `magicctl` 保留启动/停止/watchdog/netwatch 等 Android 生命周期编排,Go `magicctl-go render` 专管 DNS/TUN/route/fake-ip/ruleset JSON。渲染逻辑按文件拆分,并补了默认策略包名识别、QUIC 范围、fake-ip IPv6 的单元测试。

真机应用:
- 已把新版 `magicctl` 同步到 `/data/adb/singbox_tun_Magic/magicctl` 和模块目录。
- 重新拉起后状态为 `running=true`、`api_alive=true`、`tun_alive=true`、`watchdog_running=true`、`network_watch_running=true`。
- `runtime/netwatch.ipv6-addrs` 已生成,`runtime/` 下没有残留 `netwatch.events.*` FIFO。
- `magicctl check` 返回 `rc=0`。

## 外部资料对当前取舍的影响

- OpenYQ 的 Android transparent proxy 方案倾向 TProxy:在 Linux 数据面上 TProxy 转发更直接,但 fake-ip 与应用黑/白名单容易发生 DNS/UID 语义冲突。当前模块已经避开全局 53 劫持,用 sing-box/sing-tun `include_package`/`exclude_package` 在入口层做 UID 路由,因此继续保留单进程 TUN 是更低耦合的 Android root 模块取舍。
- `linxhome/android_performance` 和 Android 官方性能建议的共同点是先减少高频无效工作,再做底层替换。本轮落地的 `config set-per-app` 属于这一类:不改数据面,但把应用页保存从最多 4 次 `sing-box check` 降为 1 次。
- HEV 官方 Benchmarks 显示 HEV 在 Linux/namespace/iperf3 场景下吞吐和内存占用都很强;但该基准使用普通 Linux policy routing、外部 socks 上游、MTU 8500 和多队列,不能直接代表 Android root standalone 模块。当前真机实测的阻塞点是 upstream bypass/protect,不是 HEV 的 lwIP 转发性能。
- 真正比较 gvisor/system/mixed、TProxy 或未来 eBPF/SDK 接入时,必须用 Perfetto/simpleperf/可重复脚本在真机上采样 CPU、唤醒、流量延迟和断流时间点。仅凭 AVD 或理论路径不能替换默认数据面。

## 当前结论

已修掉当前代码中能明确证明的模块自造断流/空转路径:切网默认 flush、重 `/connections` 健康检查、启动过早返回、watchdog 启动竞态、netwatch monitor 孤儿、自身 TUN 事件误触发、IPv6 RA 续租健康检查空转、规则集代理冷启动依赖、默认策略侧重复包名识别、过于积极的默认 urltest、real-ip 域名路由缺反向映射、非 `.cn` 中国站点 DNS 首次解析绕远程、IPv6/DNS 错配、UDP 超时固定不可调。若真机仍断流,下一步必须按日志时间点区分:核心是否重启、DNS 是否卡住、上游/CDN 是否断开、还是应用自身连接池重连。
