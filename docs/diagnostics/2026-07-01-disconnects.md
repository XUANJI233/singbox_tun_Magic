# 2026-07-01 断流 / 长连接断开排查日志

## 现象

- 用户反馈:使用中会断开代理,长连接会断开,代理似乎经常断流。
- 影响对象重点怀疑为 xHTTP / gRPC / WS 这类长连接传输,以及切网/休眠恢复后的首段连接。
- 当前没有真机连续日志,本轮先做代码路径审计 + AVD 临时数据检查。

## 当前可用证据

- AVD 临时数据未运行正式代理链路,无法复现真实断流。
- `/data/local/tmp/sbmagic-dns-test/logs/control.log` 目前没有真实 `network watch event` 样本;只看到旧 DNS 配置校验错误和 outbounds 占位错误。
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
- **规则集默认本地预置**:打包时预取 geosite-cn / geoip-cn `.srs`,安装时复制到 `$CACHE_DIR/rulesets`,渲染时优先使用 `type: local`。`SBMAGIC_RULESET_DOWNLOAD_DETOUR=direct` 只用于本地文件缺失后的远程兜底,避免首次启动出现规则下载/代理就绪互相等待。规则文件时间已在状态页展示;直连无法更新时再切到 `proxy`。
- **`packages.proxy/free-flow` 是 route 层强制策略**:这些文件非空时会生成 `package_name` 条件,对进入 TUN 的连接做包名/进程识别;大量短连接场景会增加成本。省电优先时应主要用 TUN 白名单入口控制,把强制策略列表保持短。
- **auto_redirect 不是 UDP/QUIC 加速器**:Android 上它主要优化 IPv4 TCP。应用侧 HTTP/3/QUIC 仍走 UDP/gVisor 路径;`SBMAGIC_REJECT_QUIC=false` 默认关闭,只有确认设备被 UDP/443 成本拖慢时才建议开启,让应用回退 TCP。Hysteria2/TUIC/QUIC 节点出站不受这个路由拒绝规则影响。
- **`udp_timeout=5m` 是固定折中**:对多数场景省资源;HTTP/3、游戏、语音等 UDP 长空闲场景可能需要更长超时,但调长会增加 NAT 表占用。
- **手动 reload 会重启核心;ruleset-refresh 条件重启**:sing-box clash API 没有真实热重载配置接口,所以配置 reload 会重建 TUN 并打断已有连接。`ruleset-refresh` 只在 `bypass-cn` 规则集正在使用且核心运行时 reload;停机或未使用规则集时只更新本地 `.srs` 文件。这不是后台自发断流。
- **手动切换 selector 会影响连接**:导入生成的 selector 仍保留 `interrupt_exist_connections=true`,用户主动切节点时旧连接会被切断,新连接立即走新节点;这属于显式操作。

## 外部资料对当前取舍的影响

- OpenYQ 的 Android transparent proxy 方案倾向 TProxy:在 Linux 数据面上 TProxy 转发更直接,但 fake-ip 与应用黑/白名单容易发生 DNS/UID 语义冲突。当前模块已经避开全局 53 劫持,用 sing-box/sing-tun `include_package`/`exclude_package` 在入口层做 UID 路由,因此继续保留单进程 TUN 是更低耦合的 Android root 模块取舍。
- `linxhome/android_performance` 和 Android 官方性能建议的共同点是先减少高频无效工作,再做底层替换。本轮落地的 `config set-per-app` 属于这一类:不改数据面,但把应用页保存从最多 4 次 `sing-box check` 降为 1 次。
- 真正比较 gvisor/system/mixed、TProxy 或未来 eBPF/SDK 接入时,必须用 Perfetto/simpleperf/可重复脚本在真机上采样 CPU、唤醒、流量延迟和断流时间点。仅凭 AVD 或理论路径不能替换默认数据面。

## 当前结论

已修掉当前代码中能明确证明的模块自造断流/空转路径:切网默认 flush、重 `/connections` 健康检查、启动过早返回、watchdog 启动竞态、netwatch monitor 孤儿、自身 TUN 事件误触发、规则集代理冷启动依赖、过于积极的默认 urltest、real-ip 域名路由缺反向映射、非 `.cn` 中国站点 DNS 首次解析绕远程。若真机仍断流,下一步必须按日志时间点区分:核心是否重启、DNS 是否卡住、上游/CDN 是否断开、还是应用自身连接池重拨。
