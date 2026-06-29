# sing-box 内置代理模块 — 开发文档

> 形态:Magisk/KernelSU 模块,su 权限常驻运行。
> 设计目标(按优先级):**全天常驻省电 > 链路稳定 > 隐蔽性**。
> 架构路线:**系统层 per-app 决策 + hev-socks5-tunnel(tun层) + sing-box(核心+分流)** 三层拆分。

> ⚠️ 本文档分**架构层**(模块固有设计,写死)与**配置层**(用户经 UI 设置,不硬编码)。
> 文中出现的具体协议(VLESS/gRPC 等)、伪装策略、CDN 等**均为配置示例**,非模块要求。模块协议无关。

---

## 0. 架构层 vs 配置层(先划清边界)

| | 内容 | 谁决定 | 是否硬编码 |
|---|------|--------|-----------|
| **架构层** | 三层拆分、UDS 通信、降权、守护机制、分流分工、WebUI 框架 | 模块设计 | 是(固有) |
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
  │                          系统层 nft 重定向 53(全局,不经tun)
  │                                       ▼
  │                          sing-box DNS 服务(本地端口)
  │                            ├ 代理域名 → 返回 fake-ip
  │                            └ 直连域名 → 返回 真实IP
  │  (DNS 与数据是两条独立路径)            │
  ▼                                       │(APP 拿到 IP)
┌─────────────────────────────────────────────┐
│ 系统层 (nftables + uid)  ← 按"应用"决策:谁进代理 │
│  ├─ 不代理的 APP → 直接放行,走默认网络        │
│  └─ 要代理的 APP → 打标进 tun                 │
└─────────────────────────────────────────────┘
                    │ (仅被代理的 APP 流量)
                    ▼
            hev-socks5-tunnel          ← 纯转发:tun → SOCKS5
            (纯C, 不做任何决策)            (此处域名已丢,只剩目标IP)
                    │ SOCKS5 over UDS (无端口)
                    ▼
            sing-box (核心)
              ├─ 收到目标IP;若是 fake-ip → 查映射表反查回域名 ★
              │   (fake-ip 是域名穿透 hev 的关键:hev 丢域名,
              │    但 fake-ip↔域名 表在 sing-box 手里,可还原)
              ├─ route 引擎按域名/IP/geosite 分流
              │   ├─ 该直连 → direct
              │   └─ 该代理 → 代理 outbound
              └─ 协议出站 <用户配置的协议/传输层>
                    │
                    ▼
              <用户配置的上游链路>
              (示例:VLESS+gRPC+TLS over CDN → 自建落地)
```

> ★ **关键**:hev 转 socks5 后只剩目标 IP、域名丢失。**fake-ip 正是为此而用**——代理域名在 DNS 阶段被映射成 fake-ip,sing-box 收到 fake-ip 后反查回域名,从而恢复域名级分流能力。没有 fake-ip,被代理流量就只能按 IP 分流。

### 1.2 两层分流,各取所长(关键设计)

| 层 | 抓取的信息 | 负责 | 为什么在这层 |
|----|-----------|------|-------------|
| **系统层** | **APP uid** | **per-app:哪些应用进代理** | uid 只有系统层可见,流量经 hev 转 socks 后丢失 |
| **sing-box** | 域名 / IP / geosite | 进代理流量的目的地细分流 | 域名规则集是 sing-box 强项,灵活成熟 |

**省电收益叠加两份:**
1. 系统层:不代理的 APP **整个不碰代理栈**(uid 级排除)。
2. sing-box:被代理的 APP,其国内域名流量仍可判 direct,**不全推给落地**。

→ 直连最大化、代理流量最小化,这是省电分流的正解。

### 1.3 各组件职责

| 组件 | 形态 | 职责 | 待机能耗 |
|------|------|------|----------|
| 系统层规则 | nft/iptables + ip rule | per-app 打标、策略路由 | 零(内核态,被动) |
| hev-socks5-tunnel | 纯 C 二进制 | tun 创建 + tun↔SOCKS5 转换,**不做决策** | 极低(近零) |
| sing-box | Go 二进制 | DNS 服务(解析/fakeip/分流)+ 目的地分流 + 协议出站 | 中(Go运行时) |
| service.sh | shell | 启动编排、特权配置、守护 | 取决于守护方式 |
| WebUI | HTML/JS | 配置入口 + 状态可视化 | 零(不常驻) |

### 1.4 为什么这样拆

- **省电**:tun 层纯 C(hev)待机近零;直连流量经系统层排除后零代理开销;sing-box 只处理真正要代理的流量。
- **职责清晰**:决策(系统层 per-app + sing-box 目的地)与转发(hev)分离,各司其职。
- 对比 sing-box 一体化 tun:省一组件但 Go tun 栈常驻开销高、且直连流量也得进 sing-box 走一遭。本方案选省电。

---

## 2. 解耦合设计

### 2.1 必须解耦的边界

**① tun 层 ↔ 核心层(hev ↔ sing-box)**
- 唯一接口:**SOCKS5 over Unix Domain Socket**(socket 文件,无端口)。
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
sing-box(监听 UDS socket + DNS 端口)
   └─► 系统层规则(per-app 打标 + DNS 53 重定向到 sing-box DNS 端口)
        └─► hev(连接 UDS + 接管 tun)
```
- **sing-box 必须先就绪**:它要先监听好 UDS(数据)和 DNS 端口,否则:
  - hev 连 UDS 会失败重试;
  - DNS 53 重定向的目标端口还没起来 → 开机瞬间 DNS 失败。
- 顺序:**起 sing-box(确认 UDS + DNS 端口可连)→ 配系统层规则(打标 + DNS 重定向)→ 起 hev**。
- 停止时反序:先撤系统层规则(恢复直连)→ 停 hev → 停 sing-box,避免规则指向已死进程导致全断网。

---

## 3. 系统层 per-app 代理

### 3.1 机制(Android)

- 用 **nftables/iptables 按 APP 的 uid 打 fwmark**,决定流量是否进 tun。
- `ip rule` 按 fwmark 分流到不同路由表:打标的进 tun 路由表(→hev),未打标的走默认网络(直连,零代理开销)。
- 所有规则是特权操作,在 service.sh 的 root 阶段配置。

### 3.2 黑白名单(UI 可切换)

- **黑名单模式**:默认全部 APP 代理,排除名单内的 APP(它们直连)。
- **白名单模式**:默认全部直连,只有名单内 APP 走代理(更省电,代理流量最小)。
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
| fake-ip | 代理域名给假IP、直连域名给真IP | 见到 fake-ip 的流量进 tun |
| 执行者 | 系统层 nft + sing-box DNS 引擎 | 系统层 nft + hev + sing-box |

**系统层因此有两类独立的 nft 规则,别混:**
1. **DNS 重定向规则(全局,不看 uid)**:把所有 53 流量 DNAT 到 sing-box DNS 端口。因为 DNS 由 netd 代发、不带 APP uid,所以这类规则**只能全局**,不能按 APP。
2. **per-app 打标规则(按 uid)**:把"要代理 APP"的**非 DNS 流量**打 fwmark 进 tun。

> 两类规则作用对象不同(一个管 53 DNS、一个管数据流量),独立配置,不冲突。

### 3.5.3 DNS 接管机制(应对系统 DoT / 53)

> **版本注**:sing-box **1.14+** 才有 `dns_mode: hijack` 自动生成 nftables DNAT 的便利特性;**1.13.x 没有该自动项**,需**你在系统层手写 nft 重定向**(本架构本来就用 hev、自己管系统层,所以手写 nft 是常态,不依赖 sing-box 的 tun hijack)。机制相同:nft DNAT 把 53 引到 sing-box DNS。
> **路径**:DNS 53 流量被 nft **直接重定向到 sing-box 的本地 DNS 端口,不经过 hev/tun**(DNS 不是"被代理的数据流量",不该绕 tun→socks5→UDP associate 那套,既慢又复杂)。

系统 DNS 可能是明文 53 或 DoT(853),分别处理:

**① 明文 53 — nft DNAT 重定向(标准做法)**
- 系统层 nft 把目标端口 53 的 UDP/TCP 流量 **DNAT 重定向**到本地 sing-box 的 DNS 监听端口(全局,不看 uid)。
- 不改系统 DNS 设置项,而是在**网络层劫持流量**:系统以为在查自己设的 DNS(如 8.8.8.8),包被改道到 sing-box。
- 补充:部分场景系统可能绕过劫持,辅助手段是**把接口 DNS 指向本地地址**强制送入。

**② DoT(853)— 区别对待,不要无脑 block(关键,避免断网)**
- **不能伪造**:DoT 是 TLS 加密 + 证书验证,中间人会被证书校验挡死。
- ⚠️ **风险**:若无脑 `block 853`,**强制只用 DoT、不回落的应用会拿不到解析→无法访问**(社区已知问题)。
- **正确做法 — 按应用回落能力区别对待**:
  - **会回落的(Android Private DNS"自动"模式)**:先试 853 失败才回落 53。对这类**屏蔽 853 → 它自动降级到 53 → 被 nft 劫持接管**,不断网。
  - **不回落的(严格 Private DNS / 应用强制 DoT)**:**不屏蔽,放行让它整条走代理**(进 tun,在代理出口完成 DoT)。代价:这部分做不了域名分流,但**不断网**。

**③ fake-ip 兜底(降低断网与泄漏)**
- fake-ip 本地维护"假IP↔域名"映射,**应用立即拿到假 IP**,不依赖上游 DNS 实时响应。
- 即使国外代理/DNS 临时不可达,本地映射仍能服务,**国内直连域名照常**,不会因上游慢/挂而全断。

### 3.5.4 fake-ip:既是分流手段,也是"域名穿透 hev"的关键

**双重作用:**
1. **让域名穿透 hev**(本架构的核心理由):hev 转 socks5 后域名丢失、只剩 IP。代理域名在 DNS 阶段被映射成 fake-ip,sing-box 收到 fake-ip 后**反查映射表还原域名**,恢复域名级分流。无 fake-ip,被代理流量只能按 IP 分。
2. **降低断网/泄漏**:本地映射表即时返回假 IP,不依赖上游 DNS 实时响应;代理临时不可达时国内直连域名照常。

**选择性返回(不是全局假 IP):**
- **代理域名(如国外)** → **fake-ip**(198.18.0.0/15)。流量带假 IP → 数据层(被代理 APP)进 tun → sing-box 反查域名做代理。
- **直连域名(如国内)** → **真实 IP**(走国内直连 DNS,detour: direct)→ 数据层判直连。

**为什么必须选择性**:若全局 fake-ip,不代理的 APP 也拿假 IP,被逼进 tun 才能反查 → 破坏直连。所以**只有代理域名给 fake-ip**。

**注意事项:**
- fake-ip 不支持 `query_type` 分流,所有请求类型统一处理。
- 移动端 fake-ip 会污染本地 DNS 缓存(Android 清缓存不便)。
- **与 IPv6 的关系**:若关闭 IPv6(见 14.2),要确保 AAAA 查询的处理一致(要么不返回 fake v6、要么 v6 也走 fake-ip 段),避免应用拿到不可达的 fake v6。

### 3.5.5 完整数据流

```
DNS 阶段(全局,直达 sing-box DNS 端口,不经 hev/tun):
  APP/netd 发起 DNS
    → 系统层 nft(全局,不看 uid):
        ├─ 明文 53 → DNAT 重定向到 sing-box DNS 端口
        ├─ DoT(会回落)→ 屏蔽853 → 降级53 → 同上
        └─ DoT(不回落)→ 放行整条走代理(不接管,不断网)
    → sing-box DNS 引擎(本地端口,非 tun):
        ├─ 代理域名 → 返回 fake-ip
        └─ 直连域名 → 返回 真实 IP(走国内 DNS,detour direct)

数据阶段(per-app,按 uid + 目标IP,经 tun):
  APP 拿 IP 发起连接 → 系统层 nft(按 uid):
    ├─ uid 不在代理集合 → 直连(不进 tun)
    └─ uid 在代理集合:
        ├─ 目标=fake-ip → 进 tun → hev → sing-box(fake-ip 反查域名 → 代理出站)
        └─ 目标=真实IP(国内) → 按策略直连或进 tun
```

### 3.5.6 边界:严格 Private DNS / 强制 DoT 应用

- 这类应用**不回落到 53**,屏蔽 853 会让它 DNS 失败、断网(社区已知问题)。
- **正确处理:不屏蔽,放行让它整条走代理**(进 tun,在代理出口完成 DoT)——它能用,只是你不接管其域名分流。
- 备选:UI 检测到系统级严格 Private DNS 时,提示用户改"自动/关闭"以获得完整接管。
- **原则:宁可放弃对它的域名分流,也不要让它断网。**

### 3.5.7 一句话本质

- **DNS = nft DNAT 劫持 53 + 按域名给真/假 IP(fake-ip 只给代理域名);DoT 区别对待(会回落的逼降级、不回落的放行走代理),不无脑 block、不伪造。**
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

- **socks inbound(数据)**:监听 **UDS socket 文件**(非端口),接 hev 转来的被代理流量。
- **DNS 服务(解析)**:监听一个**本地 DNS 端口**(如 127.0.0.1:1053),接系统层 nft 重定向来的 DNS 查询。**注意:DNS 走本地端口直达,不经 hev/tun**(见 3.5.5)。

其他:
- **不配 tun inbound**。
- **route 引擎做目的地分流**:1.13 的 action 式语法(`{"action":"sniff"}`/`"resolve"`/`"reject"`),按域名/IP/geosite 决定 outbound。
- **DNS 引擎**:fake-ip server(代理域名)+ 国内直连 DNS(detour direct)+ 远程 DNS(走代理)。
- **废弃字段规避**(1.13 已删):legacy special outbounds、inbound 的 sniff/domain_strategy 字段、direct 的 override_address/port、WireGuard outbound(改 endpoint)。

### 5.2 hev-socks5-tunnel

- tun 设备:名称、地址、MTU。tun `interface_name` 可设不显眼名(隐蔽)。
- 上游:指向 sing-box 的 **UDS socket 路径**(非端口)。
- 不做任何分流/决策,纯转发。

### 5.3 版本

- 二进制用官方 sing-box **1.13.x 或更高 arm64**;配置语法与二进制版本匹配,不可错配。
- **DNS 相关版本差异**:`dns_mode: hijack` 自动生成 nft DNAT 是 **1.14+** 特性;1.13.x 用独立 DNS 配置项 + **你手写系统层 nft**(本架构本就手写,不受影响)。若想用自动 hijack 则需 1.14+。
- fake-ip server、DNS 分流、各协议出站在 1.13.x 已具备。

---

## 6. 进程身份与权限(最小权限)

| 组件 | 身份 | 原因 |
|------|------|------|
| service.sh 编排 | root | 配系统层规则、建 tun 必需;做完即退 |
| 系统层规则 + tun + 路由 | root | 特权操作 |
| hev | root 建tun后可降权 | open /dev/net/tun 需权限 |
| **sing-box 核心** | **普通 uid + inet 组** | 只需 UDS + 出站,不需要 root;降权更安全更隐蔽 |
| WebUI 查询命令 | 普通 uid | 只读状态无需 root |
| WebUI 控制命令 | root | 重启/改路由才需要 |

- **SELinux**:降权后 domain 要正确,否则 UDS 读写/网络被拦,可能需 `sepolicy.rule`。这是降权最易卡的点。
- **文件权限**:socket/配置/日志属主匹配降权 uid。
- **取舍**:初版可全 root 跑通,稳定后再降权加固,别一上来卡 SELinux。

---

## 7. 进程间通信:Unix Domain Socket

- **不用端口**:UDS 用 socket 文件路径,扫端口检测扫不到,减少被检测面;且不走 TCP 栈,比回环更快。
- **不用 binder/广播**:广播是事件信令传不了数据流;binder 要改 hev/sing-box 源码、对字节流是弱项(单事务~1MB)、破坏解耦。
- **配置**:socket 文件放可写目录(如 `/data/adb/<module>/sock/proxy.sock`);hev 上游和 sing-box socks inbound 都指向它;权限要让两进程(若降权到不同 uid)都能读写。

---

## 8. 面板:KernelSU WebUI(配置入口 + 状态可视化)

### 8.1 为什么 WebUI(不用 node,不用纯 clash 面板)

- **不用 node**:避免常驻进程,续航负担。
- **clash 静态面板不够**:sing-box 在本架构只见 UDS 来的 socks 连接,拿不到 hev 侧 tun 统计、也拿不到 uid(在系统层),可视化失真。
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
- 规则集订阅源(geosite/geoip srs)+ 更新间隔(默认 ≥7d)
- 自定义规则(域名/IP → 代理/直连/拒绝)
- 规则顺序调整(高频靠前)
- `clash_mode` 全局/规则/直连切换

### 9.4 DNS(详见 3.5)
- 远程 DNS(DoH/DoH3,走代理)、本地 DNS(直连)、sing-box DNS 监听端口
- DNS 域名分流规则(决定哪些域名走代理/直连)
- **fake-ip 开关 + fake-ip 域名范围**(只对代理域名给假IP)
- **系统 DoT 处理**:区别对待(会回落的逼降级、不回落的放行走代理),严格模式提示
- nft DNS 重定向开关(53 → sing-box DNS 端口)
- 缓存(optimistic)开关
- **bootstrap DNS**(解析落地域名,防鸡生蛋,见 14.1)

### 9.5 网络 / tun
- tun MTU、地址、interface_name
- IPv6 开关
- UDS socket 路径

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

### 14.2 IPv6(高频翻车)
- 链路 v6 不完整→走 v6 通不了→卡。建议初期关 v6 跑通再开。tun 的 v6 地址/路由别漏(防泄漏)。

### 14.3 MTU/MSS(隐蔽)
- MTU 不对+层层封装→分片/黑洞。表现:开网页正常、大文件卡死。tun MTU 保守(1400),必要时 MSS clamping。

### 14.4 时间同步(TLS 前提)
- 时间不准→TLS 校验失败→代理全挂且报错难懂。service.sh 加时间检查/同步。

### 14.5 系统层规则与 ROM 差异
- nft/iptables、fwmark、策略路由在不同 ROM/内核行为有差异,per-app 打标可能失效。这是系统层方案最需真机验证处。

### 14.6 开机竞速
- tun 创建与系统网络初始化打架。等网络 + 容错重试。

### 14.7 热点/共享网络
- 开热点时转发逻辑不同,热点设备流量可能不走代理或断网。需单独处理热点接口路由+其 uid 归属。

### 14.8 配置生效与统计口径
- "应用并重启":起 sing-box(UDS+DNS就绪)→ 重载系统层规则 → 起 hev;停止反序(先撤规则恢复直连,再停 hev、sing-box)。
- 流量统计:系统层(打标流量)、hev(tun 总量)、sing-box(经它部分)口径不同,UI 展示别混。

---

## 15. 关键检查清单

**架构正确性**
- [ ] 系统层 nft/iptables 按 uid 打标做 per-app(谁进代理)
- [ ] sing-box 只做目的地分流(域名/IP),不配 tun
- [ ] hev 纯转发,不做决策
- [ ] hev↔sing-box 用 UDS(无端口)
- [ ] 启动顺序:sing-box(UDS+DNS就绪)→系统层规则→hev;停止反序

**省电**
- [ ] 白名单模式优先(代理流量最小)/ 按需黑名单
- [ ] 守护用 init 事件驱动(或 ≥300s 轮询)
- [ ] 直连流量经系统层排除,不进代理栈
- [ ] 日志 warn+、规则集更新 ≥7d、DNS 缓存开
- [ ] 电池白名单(Doze 对抗)

**权限身份**
- [ ] 特权操作集中 service.sh root 阶段
- [ ] sing-box 降权 普通uid+inet 组(稳定后)
- [ ] SELinux 验证通过、文件/ socket 权限匹配

**配置兼容**
- [ ] 官方 sing-box 1.13.x+ arm64,配置语法与版本匹配
- [ ] 自动 DNS hijack 需 1.14+;1.13.x 手写系统层 nft
- [ ] 废弃字段已规避

**UI**
- [ ] per-app 黑白名单可切换
- [ ] 协议/传输/TLS/分流/DNS/网络/保活 全可视化配置
- [ ] "应用并重启"统一生效按钮
- [ ] 三层状态 + 流量 + 日志可视化

**保活/坑**
- [ ] 协议心跳走配置(不手搓);真机实测息屏延迟
- [ ] DNS 鸡生蛋:落地用 IP 或 bootstrap DNS
- [ ] IPv6 初期关;tun MTU 保守;时间同步检查
- [ ] 系统层规则在目标 ROM 实测

**DNS(详见 3.5)**
- [ ] DNS 全局接管(不按 APP uid),分流在域名层
- [ ] DNS 53 直达 sing-box DNS 端口,不经 hev/tun
- [ ] sing-box 开两个入口:socks(UDS,数据)+ DNS(本地端口)
- [ ] 明文 53:nft DNAT 重定向到 sing-box DNS
- [ ] DoT 区别对待:会回落的屏蔽853逼降级;不回落的放行走代理(不断网)
- [ ] 不无脑 block 853(会让强制DoT应用断网);不尝试伪造 DoT
- [ ] fake-ip 选择性:只对代理域名给假IP,直连域名给真IP
- [ ] fake-ip 兼作"域名穿透 hev"手段(被代理流量靠它反查域名)
- [ ] fake-ip 兜底,降低上游不可达时的断网
- [ ] 系统层两类 nft 规则独立:DNS重定向(全局)+ per-app打标(uid)
- [ ] per-app(uid)在数据层,与 DNS 解耦

**隐蔽(仅防本地检测才做)**
- [ ] tun interface_name 低调名(优先级高于进程名)
- [ ] 进程名固定低调名(非随机)
- [ ] 伪装(挂站/path/证书/uTLS)属配置层,按需

**解耦验证**
- [ ] 系统层分流 与 sing-box 分流 职责不重叠
- [ ] hev↔sing-box 仅 UDS 通信,可独立替换
- [ ] 代理 与 隐藏 子系统独立
- [ ] 配置/规则 与 二进制 分离
