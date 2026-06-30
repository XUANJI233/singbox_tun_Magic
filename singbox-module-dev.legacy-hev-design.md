# sing-box 内置代理模块 — 开发文档

> 形态:Magisk/KernelSU 模块,su 权限常驻运行。
> 设计目标(按优先级):**全天常驻省电 > 链路稳定 > 隐蔽性**。
> 架构路线:**sing-box 原生 TUN 主线**。per-app、DNS 劫持、目的地分流集中在 sing-box TUN/DNS/route 引擎里,模块只负责启动编排、配置生成、状态控制。
> 默认落地形态:**sing-box tun inbound(gvisor) → route/DNS/outbounds**。hev/loopback SOCKS 与 UDS 仅保留为备选/实验路线,不是初版实现目标。
> 2026-06-29 AVD 复测结论:sing-box TUN 在并发下载和总体路径上更强,且去掉 hev 后可消除本地 SOCKS 端口、凭据同步、tun2socks 额外进程与回环控制复杂度;因此初版切换为 sing-box TUN。

> ⚠️ 本文档分**架构层**(模块固有设计,写死)与**配置层**(用户经 UI 设置,不硬编码)。
> 文中出现的具体协议(VLESS/gRPC 等)、伪装策略、CDN 等**均为配置示例**,非模块要求。模块协议无关。

---

## 0. 架构层 vs 配置层(先划清边界)

| | 内容 | 谁决定 | 是否硬编码 |
|---|------|--------|-----------|
| **架构层** | sing-box TUN 主线、per-app/DNS/route 分工、守护机制、WebUI 框架、hev 备用边界 | 模块设计 | 是(固有) |
| **配置层** | 上游协议、传输层、TLS/指纹、落地地址、CDN、伪装、分流规则、per-app 名单、DNS、日志级别、MTU…… | 用户经 UI | 否(可配置) |

**原则:凡是"针对某场景的选择",都属配置层,经 UI 设置,不写进模块代码。**
模块本身只提供"协议无关的代理管道 + 可配置入口"。

---

## 1. 整体架构

### 1.1 三层分工(核心)

```
APP 流量
  │
  ├──────────────[DNS 查询]──────────────┐
  │                                       ▼
  │                          sing-box TUN DNS hijack(全局,经 tun inbound 识别 DNS)
  │                                       ▼
  │                          sing-box DNS 服务(本地端口)
  │                            ├ 默认稳定模式 → 返回真实IP(按域名选择 DNS 出口)
  │                            └ 可选 fake-ip 模式 → 仅在非硬 per-app 场景启用
  │  (DNS 与数据是两条独立路径)            │
  ▼                                       │(APP 拿到 IP)
┌─────────────────────────────────────────────┐
│ sing-box tun inbound ← 按"应用"决策:谁进代理     │
│  ├─ exclude/include package/uid → 不进 tun     │
│  └─ 要代理的 APP → 进入 sing-box route 引擎     │
└─────────────────────────────────────────────┘
                    │ (仅被代理的 APP 数据流量)
                    ▼
            sing-box (TUN + DNS + route + outbound)
              ├─ DNS hijack:协议为 DNS 的流量交给 DNS 引擎
              ├─ 默认:真实 IP + IP 规则集 + TCP sniff(SNI/HTTP Host)
              ├─ 可选 fake-ip:收到假IP后查映射表反查回域名 ★
              ├─ route 引擎按域名/IP/rule-set 分流
              │   ├─ 该直连 → direct
              │   └─ 该代理 → proxy outbound
              └─ 协议出站 <用户配置的协议/传输层>
                    │
                    ▼
              <用户配置的上游链路>
              (示例:VLESS+gRPC+TLS over CDN → 自建落地)
```

> ★ **关键修正**:原 hev→SOCKS 路线会丢失一部分域名上下文;sing-box TUN 路线能在同一进程内处理 TUN/DNS/route,但 fake-ip 与"某些 APP 硬直连、不进 tun"仍存在冲突:全局 DNS 返回假 IP 后,被排除 APP 也会拿到假 IP。故初版默认不依赖 fake-ip,用真实 DNS + IP 规则集 + TCP sniff;fake-ip 只在"全局代理/软排除/假 IP 网段统一进 tun"等可接受语义下启用。

### 1.2 两层分流,各取所长(关键设计)

| 层 | 抓取的信息 | 负责 | 为什么在这层 |
|----|-----------|------|-------------|
| **sing-box TUN 捕获层** | **APP package/uid** | **per-app:哪些应用进代理** | sing-box TUN 在捕获入口处理 include/exclude,避免流量进入后再猜 APP |
| **sing-box** | 域名 / IP / rule-set(.srs) | 进代理流量的目的地细分流 | 规则集是 sing-box 强项,灵活成熟 |

**省电收益叠加两份:**
1. TUN 捕获层:不代理的 APP **数据转发路径不进 sing-box TUN/route/outbound**(package/uid 级排除)。DNS 仍按 3.5 全局接管到 sing-box DNS,这是独立路径。
2. sing-box:被代理的 APP,其国内域名流量仍可判 direct,**不全推给落地**。

→ 直连最大化、代理流量最小化,这是省电分流的正解。

### 1.3 各组件职责

| 组件 | 形态 | 职责 | 待机能耗 |
|------|------|------|----------|
| sing-box | Go 二进制 | TUN 捕获、per-app include/exclude、DNS hijack、目的地分流、协议出站 | 中(Go运行时) |
| 系统层规则 | 可选 nft/iptables/ip rule | 仅用于 ROM 兼容兜底、DNS/路由补强、调试 | 零(内核态,被动) |
| hev-socks5-tunnel | 纯 C 二进制 | 备用路线:tun↔SOCKS5 转换,**不做决策** | 极低(近零) |
| service.sh | shell | 启动编排、特权配置、守护 | 取决于守护方式 |
| WebUI | HTML/JS | 配置入口 + 状态可视化 | 零(不常驻) |

### 1.4 为什么这样拆

- **省电**:直连 APP 的数据转发在 TUN 捕获层排除;不需要 hev 常驻进程、不需要 loopback SOCKS、不需要额外本机连接和回环规则。DNS 入口按全局 DNS 策略单独处理,不能等同于"完全不碰 sing-box"。
- **职责清晰**:sing-box 负责 TUN/DNS/route/outbound 的同一套连接上下文;模块脚本只负责配置、启动、守护和状态。
- 对比 hev 三层方案:少一组件、无本地 SOCKS 端口、DNS/tun/per-app 集成更完整;AVD 复测显示并发下载与总体路径更强。因此初版默认选 sing-box TUN,hev 只作为 ROM 兼容或后续专项省电验证的备选。

### 1.5 三条落地路线对比

| 路线 | 优点 | 代价/风险 | 当前建议 |
|------|------|-----------|----------|
| **A. sing-box 原生 tun(默认)** | 单进程;无本地 SOCKS 端口;include/exclude package、DNS hijack、route/outbound 能力集中;AVD 并发下载更强 | Go 进程直接处理 tun;不同 ROM 的 auto_route/auto_redirect 行为仍要真机测 | 初版主线 |
| **B. hev + loopback SOCKS(备用)** | hev 轻量;UDP-in-UDP/UDP-in-TCP 成熟;可作为 ROM 兼容 fallback | 多一个本地 SOCKS 入口;域名会丢;凭据同步/防回环/访问控制更复杂;AVD 并发性能弱 | 备用路线 |
| **C. UDS fork** | 隐藏 TCP 监听端口;理论上少一点 TCP loopback 暴露 | 需要同时改 hev/sing-box 或维护兼容分支;UDP 语义复杂;维护成本高 | 后续优化,不阻塞初版 |

**性能判断不要靠想象:**
- 吞吐/CPU:hev 的 C/lwIP 路径可能更轻,但 loopback SOCKS 会多一次本机连接、拷贝和握手;sing-box 原生 tun 少一跳,但不同 `stack`(`system`/`gvisor`/`mixed`)性能差异很大。
- 待机耗电:关键不是峰值吞吐,而是息屏后唤醒次数、常驻 RSS、DNS/规则更新、keepalive 和守护方式。只要系统层把大多数直连 APP 排除,两条路线都可能足够省电。
- 当前结论:初版默认 sing-box 原生 TUN。后续只在真机证明 hev 明显更省电或某些 ROM 的 sing-box TUN 不稳定时,才切回 hev 备用路线。

**真机对比测试计划:**
1. 同一台手机、同一网络、同一出站协议,分别跑 A/B 两套配置。
2. 测吞吐:`iperf3` TCP 上传/下载、UDP 丢包/抖动;记录 CPU 占用、RSS、线程数。
3. 测待机:息屏 30-60 分钟,记录电量下降、`dumpsys batterystats`、进程 CPU time、唤醒次数。
4. 测交互延迟:息屏 10 分钟后首次打开网页/IM 的 DNS+连接耗时。
5. 测泄漏与回环:`ss/netstat`、`ip rule`、`ip route`、nft/iptables 计数器、DNS 查询路径、fake-ip 模式下排除 APP 行为。
6. 每次只改一个变量:路线(A/B)、stack、MTU、fake-ip、DoT 策略、keepalive。

---

## 2. 解耦合设计

### 2.1 必须解耦的边界

**① tun 层 ↔ 核心层(hev ↔ sing-box)**
- 唯一协议接口:**SOCKS5**。
- 默认传输:**127.0.0.1 随机高端口 TCP**。用本机监听、认证、owner/uid 防火墙限制来降低暴露面。
- 实验传输:**Unix Domain Socket**。只有在同时 fork/改造 hev 与 sing-box,并验证 TCP/UDP 都可用后才能启用;不能把 UDS 当作上游版本的默认能力。
- hev 不关心上游协议;sing-box 不关心 tun 实现。任一侧可独立替换。

**② 系统层分流 ↔ sing-box 分流**
- 系统层只管 uid(谁进代理),sing-box 只管目的地(进了之后去哪)。
- 两层信息各用各的,不重叠不冲突。

**③ 代理子系统 ↔ root 隐藏子系统**
- 彻底无关。代理=本模块(普通 Magisk 模块,不做成 Zygisk 模块)。隐藏=独立装 Zygisk Next 等。
- 唯一交集:启用隐藏时把本模块挂载痕迹纳入排除列表。

**④ 流量伪装 ↔ 设备隐藏**
- 防 CDN/审查识别=流量层(服务器侧);防 APP 检测 root=设备层(本机)。对手与手段都不同。

**⑤ 配置层 ↔ 架构层**(见第 0 节)
- 协议、伪装、CDN、分流规则等均经 UI 配置,不硬编码。
- 配置/规则放可写 `/data/adb/<module>/`,不随二进制更新覆盖。

### 2.2 不可解耦:启动顺序

```
sing-box(监听 SOCKS 入口 + DNS 端口)
   └─► 系统层规则(per-app 打标 + DNS 53 重定向到 sing-box DNS 端口 + 防回环)
        └─► hev(连接 SOCKS + 接管 tun)
```
- **sing-box 必须先就绪**:它要先监听好 SOCKS 入口(数据)和 DNS 端口,否则:
  - hev 连 SOCKS 会失败重试;
  - DNS 53 重定向的目标端口还没起来 → 开机瞬间 DNS 失败。
- 顺序:**起 sing-box(确认 SOCKS + DNS 端口可连)→ 配系统层规则(打标 + DNS 重定向 + 防回环)→ 起 hev**。
- 停止时反序:先撤系统层规则(恢复直连)→ 停 hev → 停 sing-box,避免规则指向已死进程导致全断网。

---

## 3. 系统层 per-app 代理

### 3.1 机制(Android)

- 用 **nftables/iptables 按 APP 的 uid 打 fwmark**,决定流量是否进 tun。
- `ip rule` 按 fwmark 分流到不同路由表:打标的进 tun 路由表(→hev),未打标的走默认网络(直连,零代理开销)。
- 所有规则是特权操作,在 service.sh 的 root 阶段配置。

### 3.2 黑白名单(UI 可切换)

- **黑名单模式**:架构默认模式,默认全部 APP 代理,排除名单内的 APP(它们数据流量直连)。优先保证"装上就大多数应用可用"。
- **白名单模式**:省电推荐模式,默认全部直连,只有名单内 APP 走代理(代理流量最小)。UI 应引导长期常驻用户切到白名单。
- 两种模式经 UI 切换,底层是 uid 集合的"默认动作 + 例外"翻转。

### 3.3 限制

- 被系统层判定要代理的 APP,流量进 hev 后 **uid 丢失**,故 sing-box 那层**不能再按 APP 区分**,只能按目的地。这没问题——APP 级决策已在系统层完成。

---

## 3.5 DNS 处理设计(单独成节,易错)

> DNS 这块逻辑绕、容易做错(典型错误:按 APP uid 屏蔽 DNS)。本节给出正确设计。

### 3.5.1 三个基础事实

1. **Private DNS 是系统全局设置**,不是 per-app。用户在系统设置里设一次,全局生效。
2. **APP 用系统解析器时,DNS 查询由系统 netd 统一代发**——带的是**系统 uid,不带 APP uid**。故 **DNS 无法按 APP uid 区分**。
3. **DNS 解析与"哪个 APP"无关**:同一域名谁查都该得到相同的直连/代理判断。所以 DNS 本就不需要按 APP 分。

### 3.5.2 核心原则:两层解耦 + 系统层两类 nft 规则

**DNS 全局统一接管,按"域名"分流;per-app 在"数据流量"层按 uid 分流。两层互不干扰。**

| | DNS 层 | 数据流量层 |
|---|--------|-----------|
| 粒度 | **全局**(不分 APP) | **per-app**(按 uid) |
| 依据 | 域名 | uid + 目标 IP(真实/fake) |
| 接管方式 | nft 重定向 53 到 sing-box DNS 端口 | nft 按 uid 打 fwmark 进 tun |
| 路径 | **直达 sing-box DNS,不经 hev/tun** | 经 tun → hev → sing-box |
| fake-ip | 默认关闭;仅在域名优先模式可启用 | 假 IP 网段必须统一进 tun,否则排除 APP 会访问失败 |
| 执行者 | 系统层 nft + sing-box DNS 引擎 | 系统层 nft + hev + sing-box |

**系统层因此有两类独立的 nft 规则,别混:**
1. **DNS 重定向规则(全局,不看 uid)**:把所有 53 流量 DNAT 到 sing-box DNS 端口。因为 DNS 由 netd 代发、不带 APP uid,所以这类规则**只能全局**,不能按 APP。
2. **per-app 打标规则(按 uid)**:把"要代理 APP"的**非 DNS 流量**打 fwmark 进 tun。
3. **可选 fake-ip 网段规则(按目标 IP)**:若启用 fake-ip,`198.18.0.0/15` 等假 IP 网段必须进入 tun 交给 sing-box 反查;这会让"排除 APP 访问代理域名"不再是硬直连,因此只适合域名优先模式。

> 两类规则作用对象不同(一个管 53 DNS、一个管数据流量),独立配置,不冲突。

### 3.5.3 DNS 接管机制(应对系统 DoT / 53)

> **版本注**:`dns_mode: hijack` 是 sing-box **原生 tun inbound** 的 1.14+ 特性。hev 路线不配置 sing-box tun,因此不要依赖该字段;本架构默认由系统层手写 nft/iptables DNS 重定向。机制类似:把 53 引到 sing-box DNS。
> **路径**:DNS 53 流量被 nft **直接重定向到 sing-box 的本地 DNS 端口,不经过 hev/tun**(DNS 不是"被代理的数据流量",不该绕 tun→socks5→UDP associate 那套,既慢又复杂)。

系统 DNS 可能是明文 53 或 DoT(853),分别处理:

**① 明文 53 — nft DNAT 重定向(标准做法)**
- 系统层 nft 把目标端口 53 的 UDP/TCP 流量 **DNAT 重定向**到本地 sing-box 的 DNS 监听端口(全局,不看 uid)。
- 不改系统 DNS 设置项,而是在**网络层劫持流量**:系统以为在查自己设的 DNS(如 8.8.8.8),包被改道到 sing-box。
- 补充:部分场景系统可能绕过劫持,辅助手段是**把接口 DNS 指向本地地址**强制送入。

**② DoT(853)— 区别对待,不要承诺 per-app 接管**
- **不能伪造**:DoT 是 TLS 加密 + 证书验证,中间人会被证书校验挡死。
- **系统级 Private DNS 常由 netd 发起**,UID 是系统组件,不是原 APP;因此不能稳定按 APP 判断"这个 DoT 属于谁"。
- **会回落的(Android Private DNS"自动"模式)**:可选择屏蔽 853 逼其回落到 53,再由 nft 劫持到 sing-box DNS。必须真机验证回落,失败就撤规则。
- **严格 Private DNS(hostname 模式)**:默认不拦截,UI 检测后提示用户改"自动/关闭"以获得完整接管。若强行 block,严格模式会直接断解析。
- **应用内置 DoH/DoT**:本质是普通 HTTPS/TLS 数据流,只能随该 APP 的数据流量走代理或直连;模块无法在 DNS 层还原域名分流。

**③ fake-ip 不是默认兜底**
- fake-ip 可以让 sing-box 用"假IP↔域名"映射恢复域名,但它会影响所有 APP 的 DNS 答案。
- 在硬 per-app 模式下,默认关闭 fake-ip,避免排除 APP 拿到假 IP 后无法直连。
- 若启用 fake-ip,必须把假 IP 网段统一送入 sing-box,并在 UI 中明确提示:排除 APP 访问这些域名时也会被域名策略接管。

### 3.5.4 fake-ip:可选能力,不是默认架构前提

**先承认冲突:**
- DNS 答案是全局的,不是 per-app 的。
- 如果某个代理域名被返回 fake-ip,排除 APP 也会拿到这个 fake-ip。
- 如果排除 APP 的数据流量不进 tun,它会直接访问 `198.18.0.0/15` 等假地址并失败。

**因此定义两个模式:**

| 模式 | fake-ip | per-app 语义 | 适用场景 |
|------|---------|--------------|----------|
| **硬 per-app 模式(默认)** | 关闭 | 排除 APP 的数据流量不进 tun/hev/sing-box SOCKS;DNS 仍全局接管 | 省电、兼容、语义清晰 |
| **域名优先模式(高级)** | 开启 | 假 IP 网段统一进 tun;排除 APP 访问代理域名也会被接管 | 更强域名分流,接受"软排除" |

**默认硬 per-app 模式如何分流:**
- DNS 对 APP 返回真实 IP,按域名选择本地/远程 DNS 出口,但不返回 fake-ip。
- 数据层按 uid 决定进不进 tun。
- 进 tun 后,sing-box 可用 IP 规则集、已缓存 DNS 结果、TCP sniff(SNI/HTTP Host)恢复部分域名信息。
- 限制:QUIC/ECH/无 SNI/纯 IP 访问无法稳定恢复域名,需要靠 IP rule-set 或直接走默认策略。

**高级 fake-ip 模式如何启用:**
- DNS 对代理域名返回 fake-ip,直连域名返回真实 IP。
- 系统层增加目标 IP 规则:fake-ip CIDR 必须进 tun。
- sing-box 收到 fake-ip 后反查域名,恢复域名级分流。
- UI 必须明确提示:此模式不是"硬 per-app 排除";排除 APP 访问被判代理的域名时仍会进入 sing-box。

**注意事项:**
- fake-ip 不支持 `query_type` 分流,所有请求类型统一处理。
- 移动端 fake-ip 会污染本地 DNS 缓存(Android 清缓存不便),切换模式时要重启相关 APP 或清理网络状态。
- **与 IPv6 的关系**:若关闭 IPv6(见 14.5),域名优先模式也不能返回 fake v6。AAAA 应返回空成功/NODATA 促使应用走 A fallback,或在启用 IPv6 时把 v6 fake 网段也统一进 tun;不要让应用拿到不可达 fake v6 后直接失败。

### 3.5.5 完整数据流

```
DNS 阶段(全局,直达 sing-box DNS 端口,不经 hev/tun):
  APP/netd 发起 DNS
    → 系统层 nft(全局,不看 uid):
        ├─ 明文 53 → DNAT 重定向到 sing-box DNS 端口
        ├─ DoT(自动模式且已验证会回落)→ 可屏蔽853 → 降级53 → 同上
        └─ DoT(严格/不回落/应用内置)→ 不承诺DNS层接管,按数据流量策略处理
    → sing-box DNS 引擎(本地端口,非 tun):
        ├─ 硬 per-app 默认 → 返回真实 IP(按域名选择 DNS 出口)
        └─ 域名优先模式 → 代理域名 fake-ip、直连域名真实 IP

数据阶段(per-app,按 uid + 目标IP,经 tun):
  APP 拿 IP 发起连接 → 系统层 nft(按 uid):
    ├─ uid 不在代理集合 → 直连(不进 tun)
    └─ uid 在代理集合:
        ├─ 目标=真实IP → 进 tun → hev → sing-box(IP规则集/sniff/默认策略)
        └─ 目标=fake-ip(仅域名优先模式) → 进 tun → sing-box反查域名

可选 fake-ip 网段规则:
  目标 IP 属于 fake-ip CIDR → 无论 APP uid,统一进 tun → sing-box 反查域名
  代价:排除 APP 访问这些域名时不是硬直连。
```

### 3.5.6 边界:严格 Private DNS / 强制 DoT 应用

- 这类应用**不回落到 53**,屏蔽 853 会让它 DNS 失败、断网(社区已知问题)。
- **系统级严格 Private DNS**:默认不屏蔽;UI 检测到后提示用户改"自动/关闭"以获得完整接管。若用户坚持严格模式,接受 DNS 层不可接管。
- **应用内置强制 DoT/DoH**:按该 APP 的数据流量策略走代理或直连;模块不能在 DNS 层解密或还原。
- **原则:宁可放弃对它的域名分流,也不要让它断网。**

### 3.5.7 一句话本质

- **DNS = nft DNAT 劫持 53 + 默认返回真实 IP;fake-ip 是域名优先高级模式,不是硬 per-app 默认。DoT 只对已验证会回落的自动模式可逼降级;严格模式提示用户调整,不无脑 block、不伪造。**
- **per-app = 数据层按 uid 决定连接走不走代理。**
- 两者解耦:DNS 不分 APP,代理与否在数据层定。**原则:宁可放弃域名分流,不让应用断网。**

---

## 4. 启动与进程守护

### 4.1 启动阶段

- 用 **`service.sh`(late_start)**,不用 post-fs-data(网络栈未就绪,tun 创建会失败)。
- 主动等待网络就绪,失败容错重试(建 tun 失败别直接退出)。
- KernelSU 的 `boot-completed.sh` 更晚,确需系统完全起来可用它。

### 4.2 进程守护:事件驱动优先

- **优选:init service 托管**——hev 和 sing-box 注册为 init service,进程退出时 init 自动重启。系统级事件驱动,**闲时零轮询唤醒**,最省电。代价:init/SELinux 语法,跨 ROM 差异。
- **回落:长间隔轮询**——while + pidof,间隔 ≥300s,异常时才密集检查。短间隔轮询是隐形耗电源,禁用。
- 两个进程都要守护。

### 4.3 tun 创建

- 推荐 hev 自己 open `/dev/net/tun`(自包含)。确保设备存在、权限/SELinux 正确。

---

## 5. 配置注意事项(架构相关的固定要求)

> 注意:本节是**架构强制的配置要求**(如"sing-box 不配 tun"),区别于第 9 节用户可调的配置项。

### 5.1 sing-box(纯核心 + 目的地分流 + DNS 服务)

sing-box 在本架构有**两个入口**(都不碰 tun):

- **socks inbound(数据)**:默认监听 **127.0.0.1 随机高端口**(非公网地址),接 hev 转来的被代理流量。必须配认证,并用系统层规则限制只有 hev/module 专用 uid 可访问。
- **UDS 实验入口**:仅在同时确认 sing-box 与 hev/fork 都支持 UDS 后启用;不要在初版配置里依赖它。
- **DNS 服务(解析)**:监听一个**本地 DNS 端口**(如 127.0.0.1:1053),接系统层 nft 重定向来的 DNS 查询。**注意:DNS 走本地端口直达,不经 hev/tun**(见 3.5.5)。

其他:
- **不配 tun inbound**。
- **route 引擎做目的地分流**:1.13 的 action 式语法(`{"action":"sniff"}`/`"resolve"`/`"reject"`),按域名/IP/rule-set(.srs) 决定 outbound。
- **DNS 引擎**:默认真实 IP 模式(本地 DNS detour direct + 远程 DNS detour proxy);fake-ip server 只作为域名优先高级模式启用。
- **废弃字段规避**(1.13 已删):legacy special outbounds、inbound 的 sniff/domain_strategy 字段、direct 的 override_address/port、WireGuard outbound(改 endpoint)。

### 5.2 hev-socks5-tunnel

- tun 设备:名称、地址、MTU。tun `interface_name` 可设不显眼名(隐蔽)。
- 上游:默认指向 sing-box 的 **127.0.0.1 随机高端口 SOCKS**。配置 `username/password`,并设置 `socks5.mark` 用于防回环。
- UDS:仅在 fork 版本验证 TCP/UDP 后再作为可选传输。
- 不做任何分流/决策,纯转发。

### 5.3 版本

- 二进制用官方 sing-box **1.13.x 或更高 arm64**;配置语法与二进制版本匹配,不可错配。
- **DNS 相关版本差异**:`dns_mode: hijack` 是 sing-box 原生 tun 的 **1.14+** 特性;hev 路线不配 sing-box tun,所以固定使用独立 DNS 配置项 + 手写系统层 nft/iptables 重定向。
- fake-ip server、DNS 分流、各协议出站在 1.13.x 已具备,但 fake-ip 不作为硬 per-app 默认模式。

---

## 6. 进程身份与权限(最小权限)

| 组件 | 身份 | 原因 |
|------|------|------|
| service.sh 编排 | root | 配系统层规则、建 tun 必需;做完即退 |
| 系统层规则 + tun + 路由 | root | 特权操作 |
| hev | root 建tun;初版保持 root,稳定后再评估降权 | open /dev/net/tun 需权限;上游 SOCKS socket 必须打模块专用 fwmark |
| **sing-box 核心** | **普通 uid + inet 组** | 只需本地 SOCKS 监听 + 出站,不需要 root;降权更安全更隐蔽 |
| WebUI 查询命令 | 普通 uid | 只读状态无需 root |
| WebUI 控制命令 | root | 重启/改路由才需要 |

- **初版钦定隔离方式:fwmark 优先,UID 降权后置。** 模块定义固定 mark 集合:`SBTUN_PROXY_MARK`(APP 数据进 tun)、`SBTUN_INTERNAL_MARK`(hev 连接本地 SOCKS)、`SBTUN_CORE_MARK`(sing-box 自身出站/规则更新/bootstrap)。系统层规则按 mark 排除回环和限制 SOCKS 访问。
- **UID 策略**:初版不依赖固定系统 uid 来保证正确性,因为 Magisk/KernelSU/APatch 与 ROM 对 native 进程降权支持不一致。稳定后若目标环境支持可靠降权,再让 sing-box 使用普通 uid+inet 组;hev 仍需 root 建 tun,可在建 tun 后尝试降权。
- **SELinux**:降权后 domain 要正确,否则本地监听/网络/配置读取可能被拦,可能需 `sepolicy.rule`。这是降权最易卡的点。
- **本地 SOCKS 访问控制**:必选规则是"只允许带 `SBTUN_INTERNAL_MARK` 的 loopback 连接访问 sing-box SOCKS 端口";uid/owner 匹配只作为目标 ROM 支持时的额外加固。
- **文件权限**:配置/日志属主匹配降权 uid;凭据文件 root 可读即可,不要给普通 APP 可读。
- **取舍**:初版可全 root 跑通,稳定后再降权加固,别一上来卡 SELinux。

---

## 7. 进程间通信:本地 SOCKS 接口

### 7.1 默认方案:loopback TCP SOCKS

- sing-box socks inbound 监听 `127.0.0.1:<随机高端口>`,不监听 `0.0.0.0`、WLAN/LAN 地址或公网地址。
- socks inbound 必须启用 `username/password`。
- 凭据由 `service.sh` 在启动/重置阶段**生成同一份**随机值,写入 root-only 的运行态凭据文件(如 `/data/adb/sbtun/runtime/credentials.env`),再用这份值同时渲染 sing-box socks inbound 和 hev `socks5.username/password`。禁止两边各自随机。
- 系统层加访问控制:仅允许带 `SBTUN_INTERNAL_MARK` 的 hev/module 内部连接访问该端口,其他 uid/mark 连接直接拒绝;目标 ROM 支持 owner 匹配时再叠加 uid 限制。
- hev 配置 `socks5.mark`,并在策略路由里让该 mark 查 main 表,避免 hev 连接 sing-box 的流量再次进 tun 形成回环。
- sing-box 自身出站、规则集更新、bootstrap DNS 也必须排除自身 uid/mark,否则 direct/outbound 可能被重新打进 tun。

**是否会被发现:**
- 本机普通 APP 通常不能直接读取所有进程 socket 信息;但 root 检测类 APP、同 root 环境或有调试权限的对手可以通过 `/proc/net/tcp`、`ss/netstat`、端口探测、进程列表和路由规则发现本地监听。
- 只监听 `127.0.0.1` + 随机端口 + 认证 + owner/uid 防火墙后,暴露面主要从"可连接代理"降为"可观察到本机有一个监听"。
- 如果威胁模型包含本地 root 级检测,UDS 也不是万能:它隐藏端口,但 socket 文件、进程、tun 接口、路由/nft 规则仍可被发现。真正的隐藏要放在独立 root 隐藏子系统处理。

### 7.2 UDS 实验方案

- 只改 hev 不够:sing-box inbound 也要能监听 UDS,且 TCP/UDP relay 语义都要验证。
- TCP over UDS 简单;UDP 若要全程无端口,需要确认 SOCKS5 UDP ASSOCIATE、UDP-in-TCP 或自定义封装在两侧一致。
- 不建议增加一个常驻 TCP↔UDS bridge 来凑能力:多进程、多复制、多故障点,还抵消省电收益。
- 结论:UDS 可以作为 fork 分支优化,但初版以 loopback TCP SOCKS 跑通和真机测电为准。

### 7.3 不用 binder/广播

- 广播是事件信令,传不了持续数据流。
- binder 要改 hev/sing-box 源码,对大流量字节流不合适,并且破坏 SOCKS 协议边界。

---

## 8. 面板:KernelSU WebUI(配置入口 + 状态可视化)

### 8.1 为什么 WebUI(不用 node,不用纯 clash 面板)

- **不用 node**:避免常驻进程,续航负担。
- **clash 静态面板不够**:sing-box 在本架构只见 hev 转来的 socks 连接,拿不到 hev 侧 tun 统计、也拿不到 uid(在系统层),可视化失真。
- **WebUI 方案**:前端是自写 HTML/JS,"后端"是 shell `exec()`,能跨系统层/hev/sing-box 三处取数,**零常驻进程**(WebView 按需开)。

### 8.2 机制

- Web 资源放模块根目录 `webroot/`,入口 `index.html`。安装时 KernelSU 自动设权限和 SELinux context,**勿手动改**。
- `import { exec } from 'kernelsu'` 调系统命令拼视图。
- Magisk 用户用 **KsuWebUI standalone** app 也能跑 WebUI。

---

## 9. UI 可配置项清单(完整可视化)

> 设计:**几乎所有 sing-box/hev/系统层参数都经 UI 设置**,模块不硬编码。
> 生效方式:**统一"应用并重启代理"按钮**(改任何项后点一次,按 2.2 顺序:sing-box→系统层规则→hev)。

### 9.1 节点 / 上游(协议无关)
- 协议类型(VLESS/VMess/Trojan/Shadowsocks/Hysteria2/TUIC/AnyTLS… 由 sing-box 支持的全集)
- 服务器地址、端口、UUID/密码等凭据
- 传输层(TCP/WS/gRPC/HTTPUpgrade/HTTP2…)及其参数(path、host、service-name)
- TLS:开关、SNI、ALPN、证书校验、**uTLS 指纹**(Chrome 等)
- 多节点管理 + 切换 + 延迟测试(测试为按需触发,非常驻轮询)

### 9.2 per-app 代理(系统层)
- **黑/白名单模式切换**
- APP 列表勾选(读已安装应用 + uid)
- 子进程/系统应用的处理

### 9.3 分流(sing-box 目的地)
- 规则集订阅源(rule-set `.srs`,如 geoip/geosite 转换后的规则集)+ 更新间隔(默认 ≥7d)
- 自定义规则(域名/IP → 代理/直连/拒绝)
- 规则顺序调整(高频靠前)
- `clash_mode` 全局/规则/直连切换

### 9.4 DNS(详见 3.5)
- 远程 DNS(DoH/DoH3,走代理)、本地 DNS(直连)、sing-box DNS 监听端口
- DNS 域名分流规则(决定哪些域名走代理/直连)
- **DNS 模式**:硬 per-app 默认(真实 IP) / 域名优先高级模式(fake-ip)
- **fake-ip 开关 + fake-ip 域名范围**:仅域名优先模式启用;UI 必须提示"排除 APP 访问假 IP 域名也会被接管"
- **系统 DoT 处理**:自动模式可验证回落后逼降级;严格模式提示用户改自动/关闭;应用内置 DoH/DoT 按数据流量策略处理
- nft DNS 重定向开关(53 → sing-box DNS 端口)
- 缓存(optimistic)开关
- **bootstrap DNS**(解析落地域名,防鸡生蛋,见 14.1)

### 9.5 网络 / tun
- tun MTU、地址、interface_name
- IPv6 开关
- 本地 SOCKS 监听端口(随机生成/可重置)、访问控制状态
- UDS socket 路径(仅 fork/实验模式显示)

### 9.6 保活 / 省电
- keepalive 间隔(协议心跳参数)
- 守护方式(init / 轮询间隔)
- 电池白名单开关(Doze 对抗)

### 9.7 伪装 / 隐蔽(可选,按需)
- tun interface_name 低调名
- 进程名(固定低调名)
- 日志级别(默认 warn)

### 9.8 系统 / 维护
- 启动开关、开机自启
- 配置导入/导出、备份
- 二进制版本管理 / 更新
- 状态面板:三层状态(系统层规则是否生效、hev/sing-box 存活)、流量统计、连接列表、日志查看

---

## 10. root 隐藏配合(仅当需要时)

> 只防 CDN/服务器侧识别则**完全不需要本节**;仅当手机上有检测 root 会罢工的 APP 时相关。

- 本模块保持普通 Magisk 模块,不做成 Zygisk 模块。
- 隐藏靠独立装 Zygisk Next(整合了 Shamiko 大部分挂载隐藏)或 ReZygisk(注意与 Shamiko 不兼容,改配 NoHello/Treat Wheel)。
- 进阶过 Play Integrity:Zygisk Next + Tricky-Store + PlayIntegrityFix。
- 配合点:把本模块挂载痕迹纳入排除列表,tun interface_name 设低调名。

---

## 11. 流量伪装(配置层示例,非模块要求)

> 这是"过 CDN + 防识别为代理"场景的**一种配置选择**,全部经 UI 配置,非模块硬编码。

- 核心手段:落地挂真实网站 + 代理走自定义 path,让 CDN 看到"正常 HTTPS 站点"。
- 传输层 path 设成像正常 API,避开烂大街默认 path。
- 回源用域名 + 正规证书 + 443,不用裸 IP + 自签。
- uTLS Chrome 指纹(防 CDN 厂家自动识别,强度够;对抗国家级 DPI 有局限)。
- "稍微伪装即可":不需要 REALITY/多层混淆(杀鸡用牛刀且耗电)。

---

## 12. 连接保活与 Doze 对抗(分层)

### 12.1 协议心跳 — 核心自动处理
- gRPC/WS/传输层 keepalive 由 sing-box **配置参数**驱动,自动发心跳、检测死连、重连。**不手搓发包**。
- WS 与 gRPC 都有等价心跳,选哪个取决于"省电 vs 抗丢包",不取决于 ping/pong。

### 12.2 对抗 Doze — 系统层(核心管不到)
- Doze 息屏冻结后台网络,在 sing-box 之上,换协议不解决。
- 手段:**电池优化白名单**(优先,温和省电)、wakelock(费电慎用)、前台服务/持久通知。

### 12.3 调参真机实测
- 看息屏后首次访问延迟:太长→连接断了调 keepalive/白名单;掉电快→心跳太勤调稀。电池白名单是性价比最高第一步。

---

## 13. 进程名伪装

- 只防最低级字符串检测,**要固定低调名,不要随机化**(随机本身可疑;伪装内核线程名露馅)。
- 优先级:tun 接口名 > uid 降权 > Zygisk 挂载隐藏 ≫ 进程名。最弱一环,顺手做。
- 只防 CDN 则完全不用做。

---

## 14. 常见坑与排查(真机才暴露)

### 14.1 DNS 鸡生蛋(必踩)
- 远程 DNS 走代理,但落地域名要解析→死循环。解决:落地用 IP,或配 bootstrap 直连 DNS 解析落地域名。

### 14.2 防回环(必踩)
- hev 连接 sing-box 本地 SOCKS 的流量必须查 main 表,不能再次进 tun。使用 `socks5.mark` + `ip rule fwmark ... lookup main`。
- sing-box 自身出站、规则集更新、bootstrap DNS、direct outbound 也要排除自身 uid/mark。
- 验证方法:看 nft/iptables 计数器、`ip rule` 命中、sing-box direct 是否真的走默认网络。

### 14.3 本地 SOCKS 暴露面
- 只监听 `127.0.0.1`,随机高端口,启用认证。
- 防火墙按 owner/uid 限制访问,普通 APP 即使知道端口也连不上。
- root 级本地检测仍可看到进程、tun、规则或监听,这属于 root 隐藏子系统范围,不要指望 SOCKS/UDS 单独解决。

### 14.4 fake-ip 与 per-app 冲突
- 硬 per-app 模式默认关闭 fake-ip。
- 启用 fake-ip 时,假 IP 网段必须统一进 tun;这会让排除 APP 访问代理域名时也被接管。
- UI 必须把"硬排除"和"域名优先软排除"说清楚。

### 14.5 IPv6(高频翻车)
- 链路 v6 不完整→走 v6 通不了→卡。建议初期关 v6 跑通再开。tun 的 v6 地址/路由别漏(防泄漏)。
- 关闭 IPv6 时,域名优先/fake-ip 模式必须同步处理 AAAA:默认不返回 fake v6,AAAA 返回空成功/NODATA 让应用走 A fallback;若仍返回 fake v6,必须把 v6 fake CIDR 也统一进 tun,否则部分应用会把不可达 v6 当成最终失败而不是回落到 v4。
- 该行为必须真机验证:分别测 Chrome/WebView、IM、应用内 DoH/DoT、QUIC 开关下的 A/AAAA fallback。

### 14.6 MTU/MSS(隐蔽)
- MTU 不对+层层封装→分片/黑洞。表现:开网页正常、大文件卡死。tun MTU 保守(1400),必要时 MSS clamping。

### 14.7 时间同步(TLS 前提)
- 时间不准→TLS 校验失败→代理全挂且报错难懂。service.sh 加时间检查/同步。

### 14.8 系统层规则与 ROM 差异
- nft/iptables、fwmark、策略路由在不同 ROM/内核行为有差异,per-app 打标可能失效。这是系统层方案最需真机验证处。

### 14.9 开机竞速
- tun 创建与系统网络初始化打架。等网络 + 容错重试。

### 14.10 热点/共享网络
- 开热点时转发逻辑不同,热点设备流量可能不走代理或断网。需单独处理热点接口路由+其 uid 归属。

### 14.11 配置生效与统计口径
- "应用并重启":起 sing-box(SOCKS+DNS就绪)→ 重载系统层规则 → 起 hev;停止反序(先撤规则恢复直连,再停 hev、sing-box)。
- 流量统计:系统层(打标流量)、hev(tun 总量)、sing-box(经它部分)口径不同,UI 展示别混。

---

## 15. 关键检查清单

**架构正确性**
- [ ] 系统层 nft/iptables 按 uid 打标做 per-app(谁进代理)
- [ ] sing-box 只做目的地分流(域名/IP),不配 tun
- [ ] hev 纯转发,不做决策
- [ ] hev↔sing-box 默认用 `127.0.0.1` 随机高端口 SOCKS + 认证 + uid/owner 访问控制
- [ ] UDS 仅作为 fork/实验路线,不阻塞初版
- [ ] 启动顺序:sing-box(SOCKS+DNS就绪)→系统层规则(含防回环)→hev;停止反序

**省电**
- [ ] 架构默认黑名单(兼容优先);UI 引导长期常驻用户切白名单(代理流量最小)
- [ ] 守护用 init 事件驱动(或 ≥300s 轮询)
- [ ] 直连 APP 的数据转发经系统层排除,不进 tun/hev/sing-box SOCKS;DNS 全局接管单独看
- [ ] 日志 warn+、规则集更新 ≥7d、DNS 缓存开
- [ ] 电池白名单(Doze 对抗)

**权限身份**
- [ ] 特权操作集中 service.sh root 阶段
- [ ] sing-box 降权 普通uid+inet 组(稳定后)
- [ ] 初版用固定 fwmark 区分内部/代理/核心流量;uid 降权稳定后再作为加固
- [ ] 本地 SOCKS 端口只允许带 `SBTUN_INTERNAL_MARK` 的模块内部连接访问;凭据由 service.sh 统一生成并同步渲染两边配置
- [ ] SELinux 验证通过、配置/日志/凭据权限匹配

**配置兼容**
- [ ] 官方 sing-box 1.13.x+ arm64,配置语法与版本匹配
- [ ] hev 路线不使用 sing-box tun 的 `dns_mode`;DNS 53 手写系统层 nft/iptables 重定向
- [ ] 废弃字段已规避

**UI**
- [ ] per-app 黑白名单可切换
- [ ] 协议/传输/TLS/分流/DNS/网络/保活 全可视化配置
- [ ] "应用并重启"统一生效按钮
- [ ] 三层状态 + 流量 + 日志可视化

**保活/坑**
- [ ] 协议心跳走配置(不手搓);真机实测息屏延迟
- [ ] DNS 鸡生蛋:落地用 IP 或 bootstrap DNS
- [ ] IPv6 初期关;若 fake-ip 开启,AAAA/fake v6 行为已真机验证;tun MTU 保守;时间同步检查
- [ ] 系统层规则在目标 ROM 实测

**DNS(详见 3.5)**
- [ ] DNS 全局接管(不按 APP uid),分流在域名层
- [ ] DNS 53 直达 sing-box DNS 端口,不经 hev/tun
- [ ] sing-box 开两个入口:socks(loopback TCP,数据)+ DNS(本地端口)
- [ ] 明文 53:nft DNAT 重定向到 sing-box DNS
- [ ] DoT 区别对待:自动模式需验证回落;严格模式提示改自动/关闭;应用内置 DoH/DoT 按数据流量策略处理
- [ ] 不无脑 block 853(会让强制DoT应用断网);不尝试伪造 DoT
- [ ] 硬 per-app 默认关闭 fake-ip,返回真实 IP
- [ ] fake-ip 仅域名优先高级模式启用;假 IP CIDR 必须统一进 tun
- [ ] UI 明确提示 fake-ip 会把排除 APP 访问代理域名变成软排除
- [ ] 系统层两类 nft 规则独立:DNS重定向(全局)+ per-app打标(uid)
- [ ] 可选 fake-ip 网段规则与 per-app 语义分开展示
- [ ] per-app(uid)在数据层,与 DNS 解耦

**隐蔽(仅防本地检测才做)**
- [ ] tun interface_name 低调名(优先级高于进程名)
- [ ] 进程名固定低调名(非随机)
- [ ] 伪装(挂站/path/证书/uTLS)属配置层,按需

**解耦验证**
- [ ] 系统层分流 与 sing-box 分流 职责不重叠
- [ ] hev↔sing-box 仅通过 SOCKS 协议通信,传输层可从 loopback TCP 演进到 UDS fork
- [ ] 代理 与 隐藏 子系统独立
- [ ] 配置/规则 与 二进制 分离
