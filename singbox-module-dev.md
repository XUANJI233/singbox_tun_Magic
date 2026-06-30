# 星盘 — 开发文档

> 形态:Magisk/KernelSU 模块,su 权限常驻运行。
> 设计目标(按优先级):**全天常驻省电 > 链路稳定 > 隐蔽性**。
> **当前架构(已落地):sing-box 原生 TUN 单进程**——per-app 用 Android `include_package`/`exclude_package`,目的地分流用 sing-box route 引擎,DNS 用 `hijack-dns` action,全部在一个进程里完成。
> **不再使用** hev-socks5-tunnel + 本机 loopback SOCKS 的三层拆分方案。该方案的完整设计记录在 [singbox-module-dev.legacy-hev-design.md](singbox-module-dev.legacy-hev-design.md),仅作**未来 fork/对比实验**的参考,不是当前实现的一部分(见第 17 节)。

> ⚠️ 本文档分**架构层**(模块固有设计,写死)与**配置层**(用户经 UI 设置,不硬编码)。
> 文中出现的具体协议(VLESS/gRPC/XHTTP 等)、伪装策略、CDN 等**均为配置示例**,非模块要求。模块协议无关。

---

## 0. 为什么从"三层拆分"切到"单进程原生 TUN"

旧设计(见 legacy 文档)是 `系统层 nft per-app + hev tun2socks + sing-box 核心` 三层拆分,理由是"hev 纯 C 待机更省电、职责分离更干净"。基准测试(`bench/results/*.md`)否定了这个假设里的关键部分:

- **吞吐**:并发下载场景,sing-box 原生 TUN 比 hev+SOCKS 快了近 50%(7.96 MiB/s vs 5.35 MiB/s);单流场景两者接近。
- **CPU 效率**:下载方向原生 TUN 每 MiB 耗 CPU 更低;上传方向 hev 略低,但差距在个位百分比。
- **内存**:小负载下 hev 方案省 ~4MiB;但加压并发后反转,原生 TUN 涨到 ~73MiB,hev 方案稳定在 ~58MiB。
- **架构复杂度**:Android 的 `VpnService` per-app 排除(`include_package`/`exclude_package`)是系统级机制,**排除的 APP 连 DNS 查询都不会进 VPN 接口**——这天然解决了旧文档第 3.5 节大段讨论的"DNS 不能按 uid 区分、需要两类独立 nft 规则"的问题。单进程原生 TUN 不需要手写 nftables 规则、不需要本机 SOCKS 入口、不需要凭据同步、不需要防回环 mark 方案。

**结论**:吞吐/CPU 数据没有压倒性地支持 hev 方案,而原生 TUN 在架构复杂度上大幅简化(少一个常驻进程、少一套 nft 规则、少一个本地协议接口要维护)。复杂度降低本身就是省电/省维护成本的收益,所以当前版本**全面采用 sing-box 原生 TUN**,不做三层拆分。

> 待机/Doze 下两条路线的真实功耗差异目前没有真机长时间数据(20 秒空闲窗口测不出有效信号),架构选择主要基于"复杂度 + 已测得的吞吐数据",不是"已证明待机更省电"。如果未来真机长时间待机测试显示原生 TUN 在某些 ROM 上待机明显更耗电,hev 方案可以按 legacy 文档重新拾起作为 fork 分支,不需要推翻当前实现。

---

## 1. 整体架构

### 1.1 单进程数据流

```
APP 流量 + DNS 查询
         │
         ▼
┌─────────────────────────────────────────────┐
│ Android VpnService per-app 排除/包含          │
│  (sing-box tun inbound 的 include_package/    │
│   exclude_package,系统级,DNS 与数据流量一起处理)│
│  ├─ 不代理的 APP → 完全不经过 tun 接口         │
│  └─ 要代理的 APP → 数据 + DNS 都进 tun         │
└─────────────────────────────────────────────┘
                    │ (仅被代理的 APP)
                    ▼
            sing-box tun inbound (stack: gvisor 默认)
                    │
                    ▼
            route 引擎
              ├─ protocol=dns → hijack-dns(交给 DNS 模块处理,不当数据转发)
              ├─ sniff(SNI/HTTP Host,300ms)
              ├─ clash_mode Direct/Global 覆盖
              ├─ ip_is_private → direct
              ├─ domain_suffix cn / rule_set(geosite-cn, geoip-cn) → direct
              └─ final → proxy outbound
                    │
                    ▼
              DNS 引擎(real-ip 默认 / 可选 fake-ip 高级模式)
              ├─ dns-direct-domains.txt / *.cn → local detour(direct)
              └─ 其余 → remote detour(proxy)
                    │
                    ▼
              <用户配置的协议出站>(VLESS/Trojan/...)
```

- 一个进程同时持有 tun、DNS、路由、协议出站,没有本机 SOCKS 中转,没有第二个常驻二进制。
- per-app 决策和"进不进 tun"是 Android 系统层(`VpnService`)完成的,sing-box 看到的已经是"被代理的流量",不需要也不能再按 uid 分。

### 1.2 per-app(系统级,非 nft)

- 用 sing-box tun inbound 的 `include_package`(白名单)或 `exclude_package`(黑名单)字段,对应模块的 `packages.include` / `packages.exclude` 文件,见 `module/defaults/`。
- 这是 Android `VpnService` 原生能力,**排除的 APP 的数据和 DNS 都不会进入 tun 接口**,不存在旧文档里"DNS 全局接管、排除 APP 的 DNS 仍被拦截"的问题。
- 黑/白名单两种模式见 §3。

### 1.3 各组件职责

| 组件 | 形态 | 职责 | 待机能耗 |
|------|------|------|----------|
| sing-box | Go 二进制 | tun 创建/per-app/DNS(real-ip/fake-ip)/目的地分流/协议出站,单进程全包 | 中(Go 运行时 + gvisor 默认栈) |
| magicctl | shell | 渲染配置、启停/`reload`/`rollback`、带启动互斥锁、watchdog 崩溃自愈、`fetch` 订阅、clash API 代理调用 | 取决于守护方式 |
| service.sh / post-fs-data.sh | shell | 启动编排 | 零(仅启动时跑一次) |
| WebUI(已落地) | HTML/JS | 配置入口 + 节点导入 + 状态/流量可视化 + 故障恢复 | 零(不常驻,见 §8) |

---

## 2. 解耦合设计(精简版)

**① 配置层 ↔ 架构层**
- 协议、传输层、TLS/指纹、CDN、伪装、分流规则、per-app 名单、DNS、日志级别、MTU 等均经 `module/defaults/*` + 运行时 `/data/adb/singbox_tun_Magic/configs/*` 配置,不写进模块代码;改完跑 `magicctl reload` 生效(先校验,再重启)。
- 架构层(本节固有设计):单进程 sing-box、`include_package`/`exclude_package` per-app、配置渲染管线、守护方式、WebUI 框架。
- 配置/规则放在可写的 `/data/adb/singbox_tun_Magic/`,不随二进制更新覆盖(见 `module/customize.sh` 的"已存在则跳过、否则写 `.default`"逻辑)。

**② 代理子系统 ↔ root 隐藏子系统**
- 彻底无关。代理 = 本模块(普通 Magisk 模块,不做成 Zygisk 模块)。隐藏 = 独立装 Zygisk Next 等。
- 唯一交集:启用隐藏时把本模块挂载痕迹纳入排除列表。

**③ 流量伪装 ↔ 设备隐藏**
- 防 CDN/审查识别 = 流量层(服务器侧);防 APP 检测 root = 设备层(本机)。对手与手段都不同。

---

## 3. per-app 黑白名单

- **黑名单模式(`SBMAGIC_PACKAGE_MODE=black`,默认)**:默认全部 APP 代理,排除 `packages.exclude` 里的 APP(它们完全不经过 tun,数据和 DNS 都走系统默认网络)。优先保证"装上就大多数应用可用"。
- **白名单模式(`SBMAGIC_PACKAGE_MODE=white`)**:默认全部直连,只有 `packages.include` 里的 APP 走代理。省电收益最大(代理流量最小),长期常驻用户推荐切换。
- 默认排除列表 `module/defaults/packages.exclude` 已包含 root/模块管理类应用(`com.topjohnwu.magisk`、`me.weishu.kernelsu` 等)和 `com.termux`,避免管理工具自身被绕进隧道导致连不上自己。

进入 TUN 之后还有第二层"应用策略",和黑/白名单不是同一个概念:

- `packages.proxy`:这些应用进入 TUN 后只展开代理策略规则。
- `packages.free-flow`:这些应用进入 TUN 后只展开免流策略规则。
- 两个文件都没有列出的应用使用自动/混合策略,按 `SBMAGIC_MIXED_RULE_PRIORITY` 决定代理规则和免流规则的展开顺序。
- 同一个包名同时出现在 `packages.proxy` 与 `packages.free-flow` 会被 `magicctl render/check/start/reload` 拒绝。WebUI 保存应用策略时用 `magicctl config set-strategies` 原子写入两个文件,避免从"代理"切"免流"时出现中间态冲突。
- `packages.proxy/free-flow` 只对已经进入 TUN 的应用生效;白名单模式下没加入 `packages.include` 的应用即使设置了策略也不会进入模块。

---

## 4. DNS 设计

### 4.1 基本原理

- sing-box tun inbound 的路由规则里有 `{"protocol": "dns", "action": "hijack-dns"}`,会把所有经过 tun 的 DNS 查询接管,交给 sing-box 自己的 DNS 模块处理,而不是当成普通数据流量转发给出站。
- 因为 per-app 排除发生在 `VpnService` 层,**被排除的 APP 的 DNS 查询根本不会经过 tun**,所以这里完全不需要旧文档里"系统层全局 nft 重定向 53"那套机制。

> **DNS server 用 sing-box 1.12+ 新格式**(`{"type":"udp","server":"223.5.5.5"}` / `{"type":"https","server":"1.1.1.1"}`),不是旧的 `{"address":"https://..."}` URL 写法——后者 1.14 移除。新格式 DNS server 自带 dial fields,本地直连解析器不再写 `detour:"direct"`(运行时会报 "detour to an empty direct outbound makes no sense");只有远程解析器显式 `detour:"proxy"`。规则也用 action 式(`{"...":..., "action":"route", "server":"local"}` / `{"query_type":["AAAA"],"action":"reject"}`)。已移除的旧字段(顶层 `dns.fakeip` 对象、`reverse_mapping`、`independent_cache`)都不再下发。

### 4.2 默认:real-ip 模式(`SBMAGIC_DNS_MODE=real-ip`)

- `dns.final` = `remote`,本地 DNS(`local`,直连 dialer)处理 `dns-direct-domains.txt` 里列出的域名和 `*.cn`,其余走 `remote`(detour `proxy`)。
- 返回真实 IP,不返回 fake-ip,语义最清晰、兼容性最好。

### 4.3 可选:fake-ip 高级模式(`SBMAGIC_DNS_MODE=fake-ip`)

- `magicctl` 渲染时会加一个 `{"type":"fakeip","tag":"fakeip",...}` DNS server(1.12+ 新格式,不再用顶层 `dns.fakeip` 对象),并在直连/CN 规则之后追加 `query_type: A/AAAA -> server: fakeip` 的 DNS 规则。`dns.final` 仍保持 `remote`/`local`。**不能**把 `dns.final` 设成 `fakeip`;sing-box 1.13 会拒绝启动(`default server cannot be fakeip`)。
- fake-ip 模式下渲染会显式写 `cache_file.store_fakeip: true`,把 fake-ip↔域名映射持久化到 `cache.db`,避免重启后旧映射失效导致正在用 fake-ip 的连接断开(该字段默认值在不同 sing-box 版本间不一致,所以显式写死)。
- 因为所有流量都在 tun 内(没有"排除 APP 拿到假 IP 但流量不进 tun"的问题——排除的 APP 本来就不查这个 DNS),fake-ip 在当前架构下**不存在旧文档里 per-app 冲突的那套顾虑**,可以放心用来恢复域名级分流精度。
- IPv6 关闭时(`SBMAGIC_IPV6=false`,默认),AAAA 已被 DNS 规则最前面的 `reject` 全局拦掉(见 §4.4),所以 fake-ip 自然只产出 v4,不会下发 fake v6 段。

### 4.4 IPv6 防泄漏(`SBMAGIC_IPV6`)

这是容易被忽略的一点:**`SBMAGIC_IPV6=false` 不等于"不管 IPv6"**,而是"接管 IPv6 但全部拦截",理由如下。

- tun inbound 的 `address` 字段**始终**包含一个 ULA(`fdfe:dcba:9876::1/126`)地址,不管 `SBMAGIC_IPV6` 是否开启。这个地址本身不可全局路由,纯粹是为了让 `auto_route` 把系统的 IPv6 默认路由也劫持到 tun 接口上。
- 如果不这么做,在一台真有 IPv6 出口的设备上,被代理的 APP 的 IPv6 流量会**完全绕过 tun**,直接走运营商网络的 IPv6 通路出去——这是一个会直接暴露真实 IP 的"代理穿透"问题,比"没适配 IPv6"更糟。
- `SBMAGIC_IPV6=false`(默认)时,渲染管线额外加两条防线:
  1. **DNS 层**:在 DNS 规则最前面插入 `{"query_type": ["AAAA"], "action": "reject"}`,任何域名的 AAAA 查询直接被拒绝,不管 `SBMAGIC_DNS_STRATEGY` 设的是什么——这是兜底,不依赖用户没改错别的设置。
  2. **路由层**:在 `ip_is_private` 规则之前插入 `{"ip_version": 6, "action": "reject"}`,即便某个 APP 拿到了硬编码的 IPv6 地址(没走 DNS),数据面也直接拒绝,不会泄漏、也不会误判成"直连"。(用 `action: reject` 而不是旧的 `outbound: block`——`block` 特殊出站在 sing-box 1.13 已移除。)
- `SBMAGIC_IPV6=true` 时,上面两条防线不插入,IPv6 数据可以正常走 fake-ip/真实解析 + 域名/规则集分流,和 IPv4 走一样的 route 引擎逻辑。**但**默认的 `SBMAGIC_DNS_STRATEGY=ipv4_only` 不会因为这个开关自动改变——开 IPv6 只是"允许"接管,要真正解析到 AAAA,还需要把 DNS 策略换成 `prefer_ipv4`(双栈优先 v4)之类的值。WebUI 的设置表单在这两个字段之间加了提示文案,避免用户以为开了 IPv6 开关就立刻生效。

### 4.5 DNS 鸡生蛋

- DNS server 拆成 `SBMAGIC_DNS_LOCAL_TYPE`/`SBMAGIC_DNS_LOCAL_SERVER` 与 `SBMAGIC_DNS_REMOTE_TYPE`/`SBMAGIC_DNS_REMOTE_SERVER` 两组(协议 + 地址),默认本地 `udp` + `223.5.5.5`,远程 `https` + `1.1.1.1`。本地解析器负责 bootstrap/直连域名,优先低延迟和空闲后快速恢复;远程解析器经 `proxy` 出口处理普通代理域名,避免 DNS 泄漏。`SERVER` 是 IP 时不需要再解析,天然避免"远程 DNS 走代理但落地域名要解析"的死循环。
- 如果把 `SERVER` 改成域名(如 `dns.alidns.com`),sing-box 1.12+ 要求该 server 配 `domain_resolver` 指定用谁解析它,否则会变成 DNS 鸡生蛋;当前 `magicctl` 会拒绝域名、URL、端口和伪 IP 字符串,只允许 IPv4/IPv6 字面量。**所以默认坚持填 IP 字面量**,WebUI 输入框也写了"填 IP"的提示。
- `dns-direct-domains.txt` 只接受**域名**,渲染成 sing-box 的 `domain` DNS 规则,写 IP 字面量进去不会生效。

### 4.6 出站/节点域名解析(`route.default_domain_resolver`)

- 渲染管线在 `route` 块写死 `"default_domain_resolver": {"server": "local"}`。**这是 1.12+ 的硬性要求**:当配了多个 DNS server(我们有 `local`+`remote`,fake-ip 模式还有 `fakeip`)时,sing-box 不知道该用哪个去解析**出站服务器的域名**,必须显式指定,否则节点域名解析会失败。导入的节点几乎全是域名,没有这一行它们根本连不上。
- 指向 `local`(直连解析)是因为代理服务器必须**直连可达**——不能用"走代理"的 `remote` 去解析代理自己的域名(又一个鸡生蛋)。
- 注意 sing-box 有三个名字相近、位置不同的 resolver 字段,别放错:

  | 字段 | 位置 | 用途 |
  |------|------|------|
  | `default_domain_resolver` | **`route` 块**(全局默认) | 解析出站服务器域名,我们用的这个 |
  | `domain_resolver` | `dns.servers[]` 单个 server | 该 DNS server 地址是域名时 |
  | `domain_resolver` | `outbounds[]` 单个出站 | 覆盖全局默认 |

  `default_domain_resolver` 只属于 `route`;放进 `dns` 块会被 `sing-box check` 当成 unknown field 拒绝。

---

## 5. 配置注意事项

### 5.1 sing-box

- **不再有"是否配 tun"的争议**——当前架构下 tun 就是唯一入口,`module/common/magicctl` 的 `render_config` 直接生成 `inbounds: [{"type":"tun", ...}]`。
- route 引擎用 1.13+ 的 action 式语法(`sniff`/`hijack-dns`/`reject`),避免已废弃字段。**特别注意**:`block` 和 `dns` 两种特殊出站在 sing-box **1.13 已移除**,所以默认 `outbounds.json` 里**不再有** `{"type":"block"}`/`{"type":"dns"}`,拦截一律用路由 `action: reject`、DNS 接管用 `action: hijack-dns`。装在 1.13 二进制上若带着这两个旧出站会直接 `check` 失败、服务起不来。
- 路由顺序固定为:DNS 接管 → sniff → IPv6 禁用时 reject → 私网/LAN 恒直连 → clash Direct/Global → 强制代理应用规则 → 强制免流应用规则 → 自动/混合应用规则 → `final: direct`。`SBMAGIC_PROXY_RULE_MODE` 控制代理策略(`off/global/bypass-cn`),`SBMAGIC_FREE_FLOW_RULE_MODE` 控制免流策略(`off/global`),不要再用布尔式 `SBMAGIC_FREE_FLOW` 或把"国内直连"和"免流出口"混在一个开关里。私网恒直连是全局规则,不会被 `global` 代理或免流策略覆盖,避免路由器后台、局域网设备、强制门户被送进远端出口。
- tun inbound 显式写了几个"显式优于隐式"的字段,不依赖版本默认值:
  - `endpoint_independent_nat: true` 只在 `SBMAGIC_STACK=gvisor` 时写入(官方说明该字段仅 gvisor 可用;其他 stack 默认就是 endpoint-independent NAT)。
  - `udp_timeout: "5m"`(UDP NAT 映射超时,避免大量短连接 UDP 把 NAT 表撑大,行为可预期)。
- `SBMAGIC_STACK` 默认 `gvisor`,不是 sing-box 官方在带 gVisor tag 时的默认 `mixed`。原因是 `bench/results/avd-stack-benchmark-2026-06-30.md` 在 `Pixel_9_API_36_1_root` AVD 上验证: `system`/`mixed` 能通过 `check` 并启动,但 TCP 流量没有进入 tun inbound;`mixed` 的 TCP 半边也是 `system`,所以同样不可用。`system` 理论上少一层虚拟栈,但当前模块不把"理论更快"置于"实测可用"之前。
- `cache_file` 开启;fake-ip 模式额外写 `store_fakeip: true`(见 §4.3)。
- 规则集(geosite-cn / geoip-cn,`.srs` 格式)远程拉取,默认 `download_detour: proxy`(`SBMAGIC_RULESET_DOWNLOAD_DETOUR=proxy`),更新间隔默认 `168h`(7 天)。这就是"geofiles 自动更新"——sing-box 按间隔重下。clash API 没有可用的强制更新端点,所以模块提供 `magicctl ruleset-refresh` / WebUI"更新规则集":清掉规则集缓存后走安全 `reload` 触发重新下载(见 §8.4)。状态页的"规则缓存时间"来自本地 `cache.db`/规则缓存文件的最新 mtime,用于判断当前设备上的规则大致是什么时候落盘的。

### 5.2 版本

- 核心目标切换为 **shtorm-7/sing-box-extended** 的 `extended` 分支 Android arm64/x86_64 二进制,放在 `module/bin/<abi>/sing-box`,按架构在 `customize.sh` 里选择拷贝。当前打包核心来自 revision `a27453e4f7d179585436862d7cadfcef7b518aa6`,构建标签记录在 `module/core-source.txt`。原因是它在 sing-box 1.13+ 配置模型基础上额外提供 VLESS `encryption` 与 XHTTP transport,能承接 v2rayN/Xray extended 分享链接。
- 当前模块不再承诺兼容官方主线 sing-box 二进制。官方主线缺少 `transport.type: "xhttp"`、VLESS `encryption` 等扩展字段时,导入的 extended 节点会在 `sing-box check` 阶段失败,这是预期保护。
- 配置语法与二进制版本匹配,不可错配。

---

## 6. 进程身份与权限

- **sing-box 当前以 root 运行**——原生 TUN 模式下,`auto_route`/`strict_route` 需要直接操作路由表和创建 tun 设备,降权方案比三层拆分时代更难(没有独立的特权编排进程帮它建好 tun 再交接),初版不强行降权。
- `service.sh`/`post-fs-data.sh`/`customize.sh` 同样以 root 运行(Magisk/KernelSU 模块固有)。
- 本地控制面(clash API)监听 `127.0.0.1:<随机高端口>`(默认 `SBMAGIC_API_PORT=auto`,首次启动生成并写入 `runtime/api.env`;仍可在 settings 里填数字固定),凭据(`SBMAGIC_API_SECRET`)同样由 `magicctl ensure_api_env` 随机生成,写入 `runtime/api.env`,权限 `600`(root 可读)。所有 `magicctl api` 调用都带 `Authorization: Bearer`。默认 `SBMAGIC_API_FIREWALL=true` 时,`magicctl start` 会加一条本机 OUTPUT 防火墙链,只允许 root/shell 访问该随机端口,普通 APP 扫 localhost 端口拿不到 clash API 的 401 指纹。
- **取舍**:初版接受全 root 运行,把降权列为后续优化项,不在当前阶段卡 SELinux/降权细节。

---

## 7. 启动与进程守护

### 7.1 启动阶段

- `post-fs-data.sh`:只创建 `runtime/` 目录、记录模块路径,不做网络相关操作(此阶段网络栈未就绪)。
- `module/system/etc/init/netd-helper.rc`:提供可选 Android init service `netd_helper`,在 `sys.boot_completed=1` 后调用 `magicctl initd`。rc 里设置 `oom_score_adjust -900`,等价于把 init 拉起的 native 进程放到接近 Android `SYSTEM_ADJ` 的 low-memory killer 档位;这不是 framework `ProcessRecord#setPersistent(true)`。
- `magicctl initd` 必须以前台方式持有 supervisor:默认 `SBMAGIC_WATCHDOG=true` 时直接在 init service 进程里运行 `watchdog`;如果用户关闭 watchdog,则前台启动核心并 `wait` 一次。不能在 init service 里后台 fork 后立刻退出,因为 Android init 对 oneshot service 的进程组可能会清理额外子进程,导致 watchdog/core 被一起杀掉。
- `service.sh`(late_start):等待 `sys.boot_completed=1`,再 sleep 5 秒缓冲,然后调用 `magicctl boot-dispatch`。若 `SBMAGIC_BOOT_START=false`(默认)会直接退出,不接管网络;若已开启开机自启且 `SBMAGIC_INIT_SERVICE=true`,先尝试 `setprop ctl.start netd_helper`;若 ROM/模块管理器不支持 systemless rc 注入,或 init service 8 秒内没有进入,自动回退到直接 `magicctl boot`。

### 7.2 守护:无轮询 supervisor(当前实现)

- `magicctl watchdog` 当前是**事件式 supervisor**:父进程启动 sing-box 子进程后阻塞在 `wait <pid>`,只有子进程退出/崩溃/被 LMKD 杀掉时才被唤醒并处理重启或回退。正常运行期间没有 `while sleep 300; pid_alive` 这种周期性巡检,不会因为"看门狗轮询"固定唤醒设备。
- `SBMAGIC_WATCHDOG_INTERVAL` 仍保留,但含义从"巡检间隔"变成"last-good 晋升延迟":核心持续运行满这个时间(默认 300s)后,后台一次性延时任务才把当前 `runtime/config.json` 提升为 `runtime/config.last-good.json`。这保留了"能活过一段时间才算好配置"的安全门槛,但不再周期性检查。
- `start_service`/`rollback_service` 在 `SBMAGIC_WATCHDOG=true` 时会先拉起 supervisor,由 supervisor 启动核心;`restart`/`reload`/`rollback` 通过 runtime 标记文件通知 supervisor 执行对应动作,避免一个外部 shell 和 supervisor 同时拉起两个核心进程。
- `magicctl stop` 和 `disable` 会**连 supervisor 一起停**(`stop_watchdog`),然后停核心。内部的 restart/rollback/崩溃自愈路径不杀 supervisor,只让它重新启动子进程。
- Android 正常没有 systemd/systemctl,模块不能依赖 `systemctl`。当前默认优先尝试 Android init `.rc`,但保留 late_start 直接启动兜底,因为 Magisk/KernelSU/APatch 的 systemless rc 注入在不同 ROM 上仍可能受 SELinux 域、capability 或导入时机影响。
- framework 级 `ProcessRecord#setPersistent(true)` / `setMaxAdj(ProcessList.SYSTEM_ADJ)` 不是 root shell 能调用的公开能力,需要改 `system_server`、定制 ROM 或 Xposed/LSPosed hook。模块默认不做这种高侵入注入;rc 路径使用 init 原生 `oom_score_adjust -900`,direct/fallback 路径可选 `SBMAGIC_OOM_PROTECT` 写 `/proc/<pid>/oom_score_adj`,用于验证/缓解 LMKD 空闲回收。
- `magicctl netwatch` 是**事件式网络恢复器**:阻塞在 `ip monitor route address link`,只在链路/地址/路由变化(例如休眠恢复、Wi-Fi/蜂窝切换)后检查本机 API。API 正常时可关闭旧连接让传输层重拨;PID 活着但 API 卡死时触发 restart。它不做固定外网测速,避免网络本身断开时反复重启;默认 `SBMAGIC_NETWORK_RECOVERY_COOLDOWN=30` 秒,防止 ROM 连续路由事件造成频繁断连。

### 7.3 配置回退与崩溃自愈

> 编辑配置(尤其是 `outbounds.json`、IPv6/DNS 相关开关)出错是真实会发生的事,需要一个"改坏了也能自己爬回来"的兜底,而不是指望用户每次都记得手动备份。

**两层备份,两种粒度:**

1. **单个配置文件级(`config.json` 的源文件)**——`magicctl config set <key>` 写入前会把旧文件备份成 `<file>.bak`(`settings.env.bak`、`outbounds.json.bak` 等)。`magicctl config rollback <key>` 把当前文件和 `.bak` 互换,所以连续调用两次等于"改了再改回去",不是单向操作。WebUI 每个编辑区都配了对应的"撤销上次保存"按钮。
2. **渲染后整份运行配置级(`runtime/config.json`)**——supervisor 启动核心后,安排一次延时任务;如果核心持续存活满 `$SBMAGIC_WATCHDOG_INTERVAL`,就把当前 `config.json` 提升为 `runtime/config.last-good.json`。这个"必须先活过一段时间才算数"的门槛,是为了避免把一个"能跑 1 秒但 10 分钟后崩"的坏配置误判成"好配置"。

**崩溃自愈状态机(`watchdog()`):**

```
子进程退出/崩溃/被杀 → 失败计数 +1
  ├─ 失败计数 < 3  → 用当前配置重启(走正常 start_service)
  └─ 失败计数 ≥ 3  → 判定为"这份配置本身有问题/反复崩溃",尝试:
        ├─ 有 last-good 快照 → 回退到 last-good 并直接启动(跳过渲染)
        │     ├─ 成功 → 失败计数清零,继续正常巡检
        │     └─ 失败 → 判定为更严重的问题(二进制损坏/设备环境变化等)
        └─ 没有 last-good 快照,或 last-good 也启动失败
              → 关闭模块(SBMAGIC_ENABLED=false)、停掉看门狗,而不是无限重启
                耗电、也不是放着一份会反复崩的配置在那干扰系统网络
```

- **为什么 3 次才触发,不是 1 次**:避免偶发的网络抖动/系统资源紧张导致的单次退出就被误判成"配置坏了"而立刻回退。只要某次运行活过 last-good 延迟,失败计数会归零。
- **为什么最终选择"关闭"而不是"无限重启"**:无限重启在前台是吵的(`run_log` 狂刷),在后台是隐形耗电源(频繁拉起 Go 运行时 + gvisor 栈),"宁可暂时没有代理,也不要一个反复重启的进程在背景烧电"。
- **手动触发**:`magicctl rollback`(WebUI 状态页有对应按钮)可以在用户自己发现"刚保存的配置好像有问题"时,不等 15 分钟,直接手动回退到 last-good。

**已知限制(诚实写在这里,不要假装解决了)**:
- 自动恢复只检查本机健康(PID / Clash API / TUN)和网络事件,没有做真正的外网连通性自检(比如"代理是否真的能访问目标网站")。节点凭据错误、服务器侧封禁、CDN 回源异常时,sing-box 进程和本机 API 都可能正常,这类问题仍需要用户看连接面板/日志或手动切节点。
- last-good 快照依赖看门狗持续运行;如果 `SBMAGIC_WATCHDOG=false`,快照不会更新,回退能力随之失效——这是默认开看门狗的另一个理由。
- 全新安装后,如果用户第一次配置就写错了且在 15 分钟内反复崩,此时还没有任何 last-good 快照,自愈会直接走到"关闭模块"这一步,而不是回退到某个旧配置(因为没有旧配置可回退)。这是预期内的安全失败模式,不是 bug。

### 7.4 配置应用(`reload`)与启动并发安全

- **没有进程内热重载**:sing-box 的 clash API `PUT /configs`(`updateConfigs`)在源码里是空函数(只 `render.NoContent`),根本不 reload;`PATCH /configs` 只改 `mode`。所以**不能**靠 clash API 热重载配置(那会"返回成功但什么都没发生",比重启更坑)。
- 因此应用配置改动统一走 `magicctl reload` = **先渲染 + `sing-box check` 校验,通过了才 restart**。好处:配置写错时校验直接失败、**保住正在运行的进程**,而不是停成一个死服务。WebUI 的"应用并重启"按钮对应 `reload`,失败会提示"已保持原进程运行"。代价:restart 会重建 tun,现有连接会断后自动重连(亚秒级)。
- **启动互斥锁**:`start_service`/`rollback_service` 的启动临界区用 `mkdir` 原子锁(`acquire_start_lock`)串行化。否则快速连点"启动",或看门狗恰好和手动启动同时触发,两个进程可能都通过 `pid_alive` 检查、都拉起 sing-box,后者覆盖 PID 文件、前者变成占着 tun 的孤儿,最终拖垮整个网络栈。锁会自动回收"持有者 PID 已死"的陈旧锁,避免被一个被杀的 magicctl 永久卡住。

---

## 8. WebUI 与本地控制面

> 实现见 `module/webroot/`。

### 8.1 目标

- 不用 node、不常驻,KernelSU WebUI 机制(`webroot/index.html` + `import { exec } from 'kernelsu'`)按需在 WebView 里渲染。
- **面板并入 WebUI,不单独部署 Yacd/metacubexd 之类的静态 clash 面板**:自己的 WebUI 同时承担"配置编辑"和"状态/流量可视化"两件事,统一一个入口,减少多一份前端资源占用和维护成本。
- 数据来源两条:
  1. `exec()` 调 `magicctl status|logs|render`,拿模块自身状态、日志、配置文件内容(用于编辑表单)。
  2. 通过 `magicctl api METHOD PATH [JSON]` 由 root 侧转发到 sing-box clash API,拿连接列表、流量统计等实时数据,以及调用真实可用的缓存清理端点(见 §8.4)。页面 JS 不直接读取 Bearer secret,也不直接 `fetch(127.0.0.1)`。

### 8.2 访问控制

- **clash API 凭据不下发到页面 JS 里硬编码,也不进入页面运行时**——WebUI 只调用 `magicctl api`,由 root 侧读取 `runtime/api.env` 并附加 Bearer。凭据始终只存在于 root-only 文件和 `magicctl` 子进程环境里,不进 webroot 静态资源、不进版本控制。
- **clash API 本身只监听 `127.0.0.1` + 随机高端口**,且默认额外启用 owner/uid 防火墙,只允许 root/shell 访问控制端口。这样普通 APP 即使扫全 localhost 端口,也拿不到未授权响应指纹;如果 ROM 缺少 iptables owner match,防火墙会 best-effort 跳过,仍保留随机端口 + Bearer secret 作为防线。
- WebUI 本身只能在 KernelSU Manager/KsuWebUI standalone app 的 WebView 里加载(`exec()` 桥接是 KernelSU 提供的特权能力,普通浏览器打开同样的 HTML 没有 `exec`,拿不到 secret,也就调不通控制类接口),这天然限制了"谁能打开这个面板"。
- 结论:**不需要再加一层 nft/uid 限制访问面板**,当前的"root-only 凭据文件 + Bearer 校验 + WebUI 只能跑在特权 WebView 里"三件套已经构成合理的访问控制,后续如果发现本地检测/抓包能拿到 secret 再加固。

### 8.3 机制

- Web 资源放 `module/webroot/`,入口 `index.html`,KernelSU 安装时自动设权限和 SELinux context,不手动改。
- 页面结构:深色主题 + 顶部 sticky header(状态点 + pill 式 Tab),五个 Tab——**状态 / 节点 / 应用 / 设置 / 日志**:
  - **状态**:运行概览(running/pid/版本/API/模式…)、实时流量(走 clash API,含"清空 DNS / fake-ip 缓存"按钮,见 §8.4)、故障恢复(last-good 时间、失败计数、"立即回退"按钮 → `magicctl rollback`)。
  - **节点**:节点导入(见 §8.4)+ `outbounds.json` 编辑(保存前本地 JSON 校验,写入时再做 `outbounds` 语义校验)+ "撤销上次保存"(`config rollback outbounds`)。
  - **应用**:per-app 黑/白名单模式 + 全部应用选择器(进入应用页时同步一次,可手动刷新;可筛用户/系统;点击行加入/移除当前模式名单,右侧下拉选择 自动/代理/免流,新安装应用同步后置顶) + 高级包名文件编辑 + 撤销。
  - **设置**:`settings.env` 按"基础/网络与TUN/免流/DNS/本机控制面/维护"分组成 6 张卡片,数据驱动渲染,IPv6 开关旁带依赖提示;每张可"保存/撤销上次保存"。
  - **日志**:`magicctl logs run|box|control`。
- 改配置后统一走"应用并重启"按钮 → `exec("magicctl reload")`(先校验再重启,见 §7.4)。

### 8.4 节点导入(分享链接/订阅)与 clash API 端点现状

**节点导入(对标 v2rayN 的"导入"体验)**——在 WebUI 的"节点"Tab:
- 解析在**页面 JS** 里完成(JS 自带 base64/URL/JSON 能力,比 sh 干净可靠),把分享链接转成 sing-box 原生 outbound,再 `config set outbounds` 写入。
- 支持协议:`vmess` / `vless`(含 reality、flow、`encryption`、ws/grpc/http/xhttp 传输、uTLS 指纹)/ `trojan` / `ss`(SIP002 与旧版全 base64 两种写法,含 plugin)/ `hysteria2`(含 salamander obfs)/ `tuic` / `anytls`。
- VLESS `encryption` 在导入阶段按当前 sing-box-extended 的 `mlkem768x25519plus.<native|xorpub|random>.<0rtt|1rtt>.<key...>` 规则做本地预校验,key 必须是 base64url 解码后 32 或 1184 字节;不符合时拒绝该节点并在 UI 显示具体原因,避免写出 `sing-box check` 必炸的配置。
- VLESS XHTTP 导入按 sing-box-extended 的字段落盘:`type=xhttp` 会生成 `transport.type: "xhttp"`;`extra` 内仅导入客户端安全字段,例如 `xPadding*`、`noGRPCHeader`、`scMaxEachPostBytes`、`scMinPostsIntervalMs`、`session*`、`seq*`、`uplink*` 与 `xmux`。`noSSEHeader`、`scMaxBufferedPosts`、`scStreamUpServerSecs`、`serverMaxHeaderBytes` 等服务端专用字段会在分享链接导入时丢弃,避免把服务端流控/缓冲策略误写进客户端 outbound。未提供 `xPaddingBytes` 时默认写 `"100-1000"`,避免 extended 核心校验拒绝空 padding。
- 支持**订阅链接/导出配置**:WebUI 调模块自带 `magic-fetch` 拉取 URL(UA 用 `v2rayN/...` 以拿到通用的 base64 分享链接列表),再按行解析。缺少 `magic-fetch` 视为安装不完整,不再退回 curl/wget/nc 这类设备环境不稳定的后端。订阅正文是单段 base64 时自动解码;也可直接粘贴 sing-box JSON/outbounds 导出。
- 不支持 Clash YAML 订阅(需 YAML 解析器,暂不引入);这类订阅请先转换成分享链接列表或 sing-box outbounds JSON。
- 写入方式两种:**替换**(整体替换节点)/ **追加**(保留已有节点再并入,同名自动改名 `-2`/`-3`…)。组装结果 = `selector(proxy)` + `urltest(auto)` + 各节点 + `direct`,但 `proxy.default` 指向第一个真实节点,`auto` 只作为可手动选择的自动测速出口,避免空测速历史或坏首节点把新连接拖进长 TCP 超时。导入后会立刻做 `outbounds` 语义校验(`proxy/direct` 必需、tag 不重复、selector/urltest 引用必须存在)和整配置 `check`,通过后仍需点"应用并重启"。
- 节点页通过 Clash API 切换 selector 时,WebUI 同时把该 selector 的 `default` 写回 `outbounds.json`;运行时立即生效,并能在后续 reload/watchdog 重启后保留选择。否则 sing-box 重启会回到配置默认出口,容易让用户误以为"手动切到非 auto 后仍然被 auto 接管"。
- **不**在 sh 里写分享链接解析器(协议边界太多、极易出错),解析集中在 JS。

**clash API 端点现状(挖了 sing-box 主分支源码,避免做"假功能")**:
- `PUT /configs` = 空桩(不 reload);`PATCH /configs` 只改 mode → 所以**没有**热重载,配置应用走 `reload`(§7.4)。
- `PUT /providers/rules/*`(规则集 provider 更新)= 整段被注释掉、`findRuleProviderByName` 永远 404 → **规则集无法经 clash API 强制更新**。模块的手动更新按钮走 `magicctl ruleset-refresh`:清 cache 后安全重启,不是 API 热更新。
- `POST /cache/dns/flush`、`POST /cache/fakeip/flush` = **真实现** → WebUI 状态页据此提供"清空 DNS / fake-ip 缓存"按钮(改了分流规则后清缓存,新查询立即按新规则走;但新增 server/节点仍需"应用并重启")。

---

## 9. UI 可配置项清单

> 设计:几乎所有 sing-box/per-app 参数都经 `settings.env` + WebUI 表单设置,模块不硬编码。改完点"应用并重启"生效(`magicctl reload`:先渲染/check,通过后重启;失败保持原进程)。

### 9.1 节点 / 上游(协议无关)
- **分享链接/订阅/sing-box JSON 导入**(vmess/vless/trojan/ss/hysteria2/tuic/anytls,见 §8.4;VLESS 支持 sing-box-extended 的 XHTTP/encryption)——对标 v2rayN 的导入,无需手写 JSON;节点名/路径等文本按 UTF-8 解码,并对老中文订阅尝试 GB18030 兜底
- 协议类型(VLESS/VMess/Trojan/Shadowsocks/Hysteria2/TUIC/AnyTLS… 由 sing-box 支持的全集),编辑 `outbounds.json`
- 服务器地址、端口、UUID/密码等凭据
- 传输层(TCP/WS/gRPC/HTTPUpgrade/HTTP2/XHTTP…)及其参数
- TLS:开关、SNI、ALPN、证书校验、uTLS 指纹
- 多节点管理 + `urltest` 自动选优(参考 `outbounds.example.json`)

### 9.2 per-app 与应用策略
- 黑/白名单模式切换(`SBMAGIC_PACKAGE_MODE`)
- APP 列表勾选(WebUI 默认显示全部已安装应用,按应用名/包名搜索,点击行加入/移除当前模式名单)
- 应用策略下拉:自动/代理/免流,分别落到 `packages.proxy` / `packages.free-flow` / 两者都不写。保存时原子写入两个策略文件。

### 9.3 分流
- `SBMAGIC_PROXY_RULE_MODE`: `off` / `global` / `bypass-cn`
- `SBMAGIC_FREE_FLOW_RULE_MODE`: `off` / `global`
- `SBMAGIC_MIXED_RULE_PRIORITY`: `proxy` / `free-flow`
- `SBMAGIC_RULESET_DOWNLOAD_DETOUR`: `proxy` / `direct`,默认 `proxy`
- 规则集订阅源 + 更新间隔(`SBMAGIC_RULE_UPDATE_INTERVAL`,默认 168h;按间隔自动重下,无强制立即更新端点,见 §8.4)
- 自定义直连域名(`dns-direct-domains.txt`)
- `clash_mode` 全局/规则/直连切换(走 clash API `default_mode` / `PATCH /configs`,这个 PATCH 改 mode 是真实现)

### 9.4 DNS
- `SBMAGIC_DNS_MODE`:real-ip(默认)/ fake-ip
- `SBMAGIC_DNS_LOCAL_TYPE` / `SBMAGIC_DNS_LOCAL_SERVER`(直连解析,默认 `udp` + `223.5.5.5`)
- `SBMAGIC_DNS_REMOTE_TYPE` / `SBMAGIC_DNS_REMOTE_SERVER`(走代理解析,默认 `https` + `1.1.1.1`)
- `SBMAGIC_DNS_STRATEGY`(ipv4_only / prefer_ipv4 / ...)
- `SBMAGIC_FAKEIP4` / `SBMAGIC_FAKEIP6`(fake-ip 模式才用)

### 9.5 网络 / tun
- `SBMAGIC_PROCESS_NAME`(默认 `netd-helper`,运行时二进制文件名,改名后 `reload` 会先停旧进程再用新名启动)
- `SBMAGIC_MTU`、`SBMAGIC_INTERFACE`(默认 `utun0`,避免和模块 id 同名暴露身份)
- `SBMAGIC_IPV6`
- `SBMAGIC_STACK`(默认 `gvisor`;`system`/`mixed` 保留为实验选项,不作为默认)
- `SBMAGIC_SNIFF_TIMEOUT`(默认 `100ms`;降低首连固定等待,极慢首包场景可适当调大)

### 9.6 保活 / 省电
- `SBMAGIC_INIT_SERVICE`:默认 `true`;开机时优先尝试 Android init service `netd_helper`,失败自动走 late_start 直接启动。
- `SBMAGIC_WATCHDOG`:无轮询 supervisor 开关;开启时由父进程 `wait` 子进程退出,不是定时轮询。
- `SBMAGIC_WATCHDOG_INTERVAL`:last-good 晋升延迟,默认 300s。
- `SBMAGIC_NETWORK_WATCH` / `SBMAGIC_NETWORK_CHANGE_FLUSH` / `SBMAGIC_NETWORK_RECOVERY_COOLDOWN`:默认开启,冷却 30 秒;阻塞监听系统网络事件,切网/休眠恢复后检查本机 API,必要时重启或关闭旧连接重拨。
- `SBMAGIC_OOM_PROTECT` / `SBMAGIC_OOM_SCORE_ADJ`:高级选项,默认关闭;用于 direct/fallback 路径尝试写 `/proc/<pid>/oom_score_adj` 降低 LMKD 回收概率。init rc 路径已经声明 `oom_score_adjust -900`。它不是 Android framework 的 `setPersistent(true)`,也不会把 native 进程注册成系统 persistent 进程。
- 电池白名单开关(Doze 对抗,需要 WebUI 引导用户去系统设置加白名单,模块本身不能直接改)

### 9.7 系统 / 维护
- `SBMAGIC_ENABLED` 启动开关
- 配置导入/导出、备份(`/data/adb/singbox_tun_Magic/configs/`)
- 状态面板:running/pid/版本、流量统计、连接列表、日志查看(WebUI,见 §8)

---

## 10. root 隐藏配合(仅当需要时)

> 只防 CDN/服务器侧识别则完全不需要本节;仅当手机上有检测 root 会罢工的 APP 时相关。

- 本模块保持普通 Magisk 模块,不做成 Zygisk 模块。
- 隐藏靠独立装 Zygisk Next(整合了 Shamiko 大部分挂载隐藏)或 ReZygisk。
- 配合点:把本模块挂载痕迹纳入排除列表,tun `interface_name` 设低调名(已默认 `utun0`)。

---

## 11. 流量伪装(配置层示例,非模块要求)

- 核心手段:落地挂真实网站 + 代理走自定义 path,让 CDN 看到"正常 HTTPS 站点"。
- 传输层 path 设成像正常 API,避开烂大街默认 path。
- 回源用域名 + 正规证书 + 443,不用裸 IP + 自签。
- uTLS Chrome 指纹(防 CDN 厂家自动识别,强度够;对抗国家级 DPI 有局限)。
- "稍微伪装即可":不需要 REALITY/多层混淆(杀鸡用牛刀且耗电)。

---

## 12. 连接保活与 Doze 对抗

### 12.1 协议心跳 — 核心自动处理
- gRPC/WS/传输层 keepalive 由 sing-box 配置参数驱动,自动发心跳、检测死连、重连。

### 12.2 对抗 Doze — 系统层(核心管不到)
- 手段:电池优化白名单(优先,温和省电)、wakelock(费电慎用)、前台服务/持久通知。

### 12.3 调参真机实测
- 看息屏后首次访问延迟:太长 → 连接断了调 keepalive/白名单;掉电快 → 心跳太勤调稀。

---

## 13. 进程名伪装

- **已实现基础低调化**:`customize.sh` 把 sing-box 原始二进制安装为 `$DATA_DIR/bin/.core`,`magicctl` 再按 `SBMAGIC_PROCESS_NAME` 生成运行时硬链接/副本(默认 `$DATA_DIR/bin/netd-helper`)并只执行这个路径。改进程名不需要更新模块包,WebUI 设置后 `reload` 会停旧路径进程并用新路径启动。
- 这只防最低级字符串检测,不是 root 隐藏。高权限检测仍可通过 `/data/adb/singbox_tun_Magic` 路径、模块挂载痕迹、TUN 接口和路由规则判断代理模块存在。
- 优先级仍然是:tun 接口名/per-app 排除/控制面收敛 > 进程名。

---

## 14. 常见坑与排查

### 14.1 DNS 鸡生蛋
- 见 §4.5。`SBMAGIC_DNS_LOCAL_SERVER`/`SBMAGIC_DNS_REMOTE_SERVER` 配 IP 字面量是默认解法;改成域名要给该 server 配 `domain_resolver`。
- 节点/出站服务器域名解析靠 `route.default_domain_resolver`(见 §4.6),多 DNS server 时必须有,否则节点连不上。

### 14.2 本地控制面暴露面
- clash API 只监听 `127.0.0.1` + 随机高端口,凭据 root-only,WebUI 通过 `magicctl api` 转发而不是页面直连。默认还有 OUTPUT owner 防火墙,普通 APP 不应能连到该端口拿 401 指纹;若目标 ROM 缺少 iptables/owner match,会自动降级为随机端口 + Bearer secret,见 §8.2。

### 14.3 IPv6
- 链路 v6 不完整 → 走 v6 通不了 → 卡。`SBMAGIC_IPV6=false` 是默认,建议先用 v4 跑通再开。fake-ip 模式下 v6 关闭则不返回 fake v6(见 §4.3)。
- `SBMAGIC_IPV6=false` 不是"放过 IPv6 不管",而是"接管 IPv6 路由后整体拦截",防止真有 v6 出口的设备绕过代理泄漏,见 §4.4。
- 开 `SBMAGIC_IPV6=true` 后如果没把 `SBMAGIC_DNS_STRATEGY` 从默认 `ipv4_only` 改掉,实际效果是"看起来开了但没生效"(不会有任何变化),这是预期行为,不是 bug,见 §4.4。

### 14.4 MTU/MSS
- `SBMAGIC_MTU` 默认 1400,够保守;层层封装后仍黑洞需考虑 MSS clamping(sing-box tun 本身不直接提供,需出站层配合或调小 MTU)。

### 14.5 时间同步
- 时间不准 → TLS 校验失败 → 代理全挂且报错难懂。

### 14.6 默认配置不会真正代理
- 全新安装时 `outbounds.json` 的 `proxy` selector 只有 `direct` 一个选项(`module/defaults/outbounds.json`),刻意做成"能保存草稿但不会误以为已经代理"的安全默认值。由于默认 `SBMAGIC_PROXY_RULE_MODE=bypass-cn`,真正 `start/reload/check` 会拒绝这个空代理,提示用户先导入真实节点。用户可参考 `outbounds.example.json` 填真实 `proxy` 节点;如果启用免流规则,还必须提供可用的 `free-flow` 出站。
- `outbounds.example.json` 同时给出 `proxy` 和 `free-flow` 两个出口的示例。WebUI 的普通节点导入只重建 `proxy/auto/direct` 代理分支,会保留现有 `free-flow` 出站及其引用节点,避免导入普通代理时误删免流配置。

### 14.7 开机竞速
- tun 创建与系统网络初始化打架。`service.sh` 已等 `sys.boot_completed` + 5 秒缓冲,如果某些 ROM 仍偶发失败,可以加重试逻辑。

### 14.8 坏 settings.env 不能把停机路径打瘫
- `magicctl start/reload/render/check` 仍使用严格 `load_settings` 校验,坏配置会被拒绝。
- `magicctl status` 走降级读取:能展示 `config_valid=false` 与错误原因,同时仍尽量显示 PID/API/当前运行状态。
- `magicctl stop/disable` 不依赖 `validate_settings` 成功,只要 PID 文件还在就能清理进程、watchdog 和本机控制端口防火墙。对接管全网的模块来说,"配置坏了还能关"优先级高于严格失败。

### 14.9 以为能"热重载 / 强制更新规则集"
- sing-box 的 clash API `PUT /configs` 是空桩、rule-provider 更新被注释掉(见 §8.4),所以**没有**进程内热重载、也**没有**强制立即更新规则集的接口。配置改动一律走 `reload`(校验后重启,§7.4),规则集靠 `update_interval` 自动更新。能即时生效的只有 `POST /cache/*/flush` 清缓存。

### 14.10 升到 sing-box 1.14 前注意
- 当前 DNS 已用 1.12+ 新 server 格式(§4.1),但 `route` 里若残留任何 1.14 才移除的旧字段需提前迁移;升级二进制后务必先 `magicctl check` 再 `reload`。`block`/`dns` 旧出站已在 1.13 清除(§5.1),不要在 `outbounds.json` 里加回来。

### 14.11 `system` / `mixed` TUN stack
- sing-box 官方定义里,`system` 使用系统网络栈做 L3→L4 转换,`gvisor` 使用 gVisor 虚拟网络栈,`mixed` 是 system TCP + gVisor UDP。理论上 `system` 可能更省 CPU/内存,但当前 AVD root shell 测试显示它没有接管 TCP 连接,表现为客户端 `dial tcp ... i/o timeout`,日志里没有 inbound connection。
- 因为 `mixed` 的 TCP 半边也是 `system`,它在同一测试里也失败。当前默认固定为 `gvisor`;除非在目标真机上完成 `magicctl check`、实际连通性和吞吐测试,否则不要为了理论性能切到 `system`/`mixed`。

---

## 15. 构建与发布

- 模块 ID 固定为 `singbox_tun_Magic`,展示名为 `星盘`,运行目录为 `/data/adb/singbox_tun_Magic`。
- 本地打包产物名固定为 `星盘.zip`:先运行 `scripts/build-helpers.ps1` 重建 `magic-fetch`(arm64-v8a/x86_64)和 `applist.dex`,再运行 `python scripts/package-module.py --output dist/星盘.zip`。x86_64 Go/Android helper 需要 Android NDK clang wrapper,脚本会从 `ANDROID_HOME`/`ANDROID_SDK_ROOT` 下自动查找。
- `scripts/write-update-json.py` 生成 Magisk update metadata,`module.prop` 的 `updateJson` 指向 GitHub latest release 的 `update.json`;该 JSON 的 `zipUrl` 指向同一 release 下的 `星盘.zip`。
- GitHub Actions `.github/workflows/release.yml` 在 tag `v*` 推送时自动构建、打包、生成 `update.json`,并把 `星盘.zip` 与 `update.json` 发布为 release 资产。workflow_dispatch 也可手动构建 artifacts。

---

## 16. 关键检查清单

**架构正确性**
- [ ] sing-box 单进程持有 tun + DNS + 路由 + 出站,不依赖第二个常驻二进制
- [ ] per-app 用 `include_package`/`exclude_package`,不是 nft/iptables
- [ ] route 引擎做目的地分流(域名/IP/rule-set),`hijack-dns` 接管 DNS
- [ ] 配置渲染管线:`settings.env` + `outbounds.json` + packages 列表(`include/exclude/proxy/free-flow`) + dns-direct 列表 → `runtime/config.json`

**省电**
- [ ] 架构默认黑名单(可用性优先);白名单模式给长期常驻用户作为更省电选项
- [ ] 默认优先 Android init service 托管启动,失败自动回退 late_start 直接启动
- [ ] 守护用事件式 supervisor,正常运行不做周期性存活轮询;`SBMAGIC_WATCHDOG_INTERVAL` 只作为 last-good 提升延迟
- [ ] 网络恢复用 `ip monitor` 事件触发,不做固定外网测速/常规轮询
- [ ] 直连 APP(per-app 排除)不进 tun;数据和 DNS 都走系统默认网络,不存在全局 53 劫持或 uid 级 DNS 分叉
- [ ] 日志 warn、规则集更新 ≥7d、cache_file 开
- [ ] 电池白名单(Doze 对抗,需 WebUI 引导)

**权限身份**
- [ ] sing-box 当前以 root 运行(原生 TUN 降权比三层拆分更难,初版不强求)
- [ ] 控制面凭据 root-only(600),Bearer 校验,`127.0.0.1` only,端口默认 `auto` 随机高端口,默认 owner 防火墙阻断普通 UID 扫描

**配置版本**
- [ ] sing-box-extended `extended` 分支核心,配置语法与版本匹配
- [ ] DNS 用 1.12+ 新 server 格式(type+server)、规则用 action 式;旧字段(`address` URL、顶层 `fakeip`、`reverse_mapping`、`independent_cache`)不下发
- [ ] `block`/`dns` 旧特殊出站已移除(1.13 删除),拦截用 `action: reject`、DNS 用 `hijack-dns`
- [ ] `route.default_domain_resolver` 已设(多 DNS server 时解析节点域名必需,见 §4.6)
- [ ] tun 在 gvisor stack 下显式 `endpoint_independent_nat: true`,所有 stack 显式 `udp_timeout: "5m"`;fake-ip 模式显式 `store_fakeip: true`

**应用配置 / 并发(详见 §7.4)**
- [ ] 配置改动走 `reload`(校验后重启),不依赖 clash API 热重载(那是空桩)
- [ ] `start`/`rollback` 有 `mkdir` 启动互斥锁,防快速连点产生孤儿进程
- [ ] `stop`/`disable` 连看门狗一起停,不会被自动拉起

**IPv6(详见 §4.4)**
- [ ] tun 始终带 IPv6 地址,claim 默认 v6 路由(不管 `SBMAGIC_IPV6` 开关)
- [ ] `SBMAGIC_IPV6=false` 时:DNS 层拒绝 AAAA + 路由层 `action: reject` 所有 v6 目的地,双重防线
- [ ] `SBMAGIC_IPV6=true` 时额外提示用户调整 `SBMAGIC_DNS_STRATEGY`,否则"开了等于没开"
- [ ] fake-ip 的 v6 段只在 `SBMAGIC_IPV6=true` 时下发

**回退与崩溃自愈(详见 §7.3)**
- [ ] 每个配置源文件 `config set` 自动留 `.bak`,`config rollback <key>` 可逆切换
- [ ] supervisor 确认核心存活满 `SBMAGIC_WATCHDOG_INTERVAL` 才把 `config.json` 提升为 `last-good`
- [ ] 连续失败 ≥3 次自动尝试回退到 last-good,last-good 也失败则关闭模块而不是无限重启
- [ ] `magicctl rollback` 支持手动立即回退,不必等 15 分钟

**WebUI**
- [ ] 面板并入 WebUI,不单独部署静态 clash 面板
- [ ] clash API 凭据只由 `magicctl api` 在 root 侧读取,不写进静态页面资源,也不暴露给页面 JS
- [ ] WebUI 只能在 KernelSU 特权 WebView 里跑,`exec()` 桥接天然限制访问者
- [ ] 节点导入(分享链接/订阅,vmess/vless/trojan/ss/hysteria2/tuic,见 §8.4)
- [ ] 状态页"清空 DNS / fake-ip 缓存"用真实 clash API 端点;各编辑区"撤销上次保存" + 故障恢复"立即回退"

**隐蔽**
- [ ] tun `interface_name` 用 `utun0` 等低调名(已完成)
- [ ] 进程名基础低调化为 `netd-helper`,且可通过 `SBMAGIC_PROCESS_NAME` 手动改名(已完成,见 §13)
- [ ] 伪装(挂站/path/证书/uTLS)属配置层,按需

---

## 17. 未来考虑:hev 三层拆分(fork 分支,不阻塞当前版本)

完整的 hev + 本机 SOCKS + 系统层 nft 方案设计记录在 [singbox-module-dev.legacy-hev-design.md](singbox-module-dev.legacy-hev-design.md),包括:

- hev↔sing-box 的 SOCKS 协议解耦、UDS 实验路线
- 系统层 nftables per-app 打标 + 全局 DNS 重定向的两类规则设计
- fake-ip 与 per-app 排除的冲突分析与两种模式定义
- 进程降权(普通 uid + inet 组)、SELinux 隔离方案

**触发重新评估的条件**(任一满足再考虑拾起):
1. 真机长时间息屏待机数据显示原生 TUN 在主流 ROM 上明显更耗电(不是模拟器 20 秒空闲窗口这种噪声级别的差异)。
2. 需要把 sing-box 降权到普通 uid 跑,而原生 TUN 模式下降权方案验证不通过(降权后无法自建 tun/改路由)。
3. 出现"必须隐藏本机正在监听的 TCP 控制端口"这类强隐蔽需求(原生 TUN 模式下控制面仍是 loopback TCP)。

在以上条件出现前,**不要并行维护两套架构**,以免文档/代码精力分散。
