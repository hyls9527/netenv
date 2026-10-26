# Wi-Fi + 以太网叠加：开源方案对比与选型

> 研究日期：2026-10-19。目标：在现有 NetEnv（mihomo 统一代理层）上升级，评估“Wi-Fi 与以太网同时使用/叠加”的可行路线。
> 本文只做方案对比与选型，不含实现改动。项目状态会变化，引用处标注了核验来源。

## 0. 先纠正一个前提：现在没有“有线以太网”

本机实测（2026-10-19 20:21）：

| 接口 | 状态 | IPv4 | 默认网关 | 说明 |
|---|---|---|---|---|
| WLAN（Intel Wi-Fi 6 AX101） | Up，115 Mbps | 192.168.100.5 | 192.168.100.1 | Wi-Fi |
| 以太网 5（Remote NDIS） | Up，150 Mbps | 192.168.100.100 | 192.168.100.1 | USB 网络共享，不是有线网卡 |
| 以太网（Realtek PCIe GbE） | **Disconnected** | 169.254.x.x | 无 | 有线网卡未接 |

两条“在线”链路同网段、同网关（192.168.100.1），大概率是同一台上游（手机/路由器）。
**在这种拓扑下做任何“叠加”都不会增加总带宽**，只会增加复杂度和故障面。
因此第一步不是选项目，而是确认：有线以太网接上后是否属于独立上行（不同 ISP / 不同公网出口 / 不同网关）。

## 1. “叠加”的两种语义，必须先区分

| 语义 | 机制 | 单条 TCP 连接 | 多条连接总吞吐 | 典型实现 |
|---|---|---|---|---|
| A. 连接级负载均衡 / 故障切换 | 按连接（或按流）选出口链路 | 不叠加，仍走一条链路 | 可以累加 | mihomo load-balance、mwan3、Xray balancer、dispatch-proxy |
| B. 单流带宽聚合（真正的 bonding） | 多路径传输/隧道分片（MPTCP、多链路 UDP 隧道） | 可以叠加 | 可以累加 | OpenMPTCProuter、MLVPN、Glorytun、ZeroTier multipath、Speedify |

浏览器、下载器、包管理器通常会开多条连接，所以 **A 已经能明显提升“总吞吐”**；但单个大文件单连接下载、单路视频流，只有 B 才能提速。
把 A 宣传成“带宽叠加”是常见误导；选型前先明确目标。

## 2. 本机/现有栈的事实

- mihomo：v1.19.30 windows amd64（with_gvisor）。
- 现有 `data/merged.yaml` 只有 `select` / `url-test` 组（proxy-select、auto-urltest、github-node、github-adaptive、gpt-node、gpt-adaptive），**没有** `interface-name`、`load-balance`（源码 grep 为 0）。
- 本机实测：mihomo 在 Windows 上**确实按 `interface-name` 绑定网卡**。
  测试配置把两个 direct 出站分别绑定 `WLAN` 与 `以太网 5`，请求 `https://www.baidu.com`，观察 mihomo 的 TCP 连接源地址：
  - wlan-direct → LocalAddress `192.168.100.5`
  - eth-direct → LocalAddress `192.168.100.100`
  说明“多网卡 + 每代理绑定”在 Windows 上可用，不依赖 Linux 的 SO_BINDTODEVICE。
- Windows 的 MPTCP：Cloudflare 的实现综述明确“Windows 平台没有 MPTCP 支持”；mihomo/Xray 的 MPTCP 开关不能把本机变成 MPTCP 端点。Xray 文档明确 `tcpMptcp` 需要 Linux 5.6+。
- Windows NIC Teaming / LBFO：微软 Q&A 明确 Windows 11 客户端**不正式支持**（PowerShell 可强行建 team，但属未支持状态）；且 team 面向以太网 miniport，Wi-Fi 不能加入，跨介质 L2 聚合不可行。

## 3. 代理层项目对比（“统一代理层”候选）

| 项目 | 许可证 / 状态 | Windows | 按网卡绑定出站 | 连接级负载均衡 | 单流聚合 | 与 NetEnv 适配性 |
|---|---|---|---|---|---|---|
| **mihomo (Clash.Meta)** | MIT，活跃（2026-10 仍有提交） | 原生 | **是**：全局 `interface-name` 或每个 proxy 的 `interface-name` | **是**：`load-balance` 组，`round-robin` / `consistent-hashing` / `sticky-sessions` | 否（`mptcp` 选项需内核支持，Windows 不可用） | **最高**：已是唯一出口，保留端口表/控制器/规则/自愈；只需扩配置生成 |
| **sing-box** | GPL-3.0 + 名称附加条款，活跃 | 原生 | **否**：`bind_interface` 文档明确仅 Linux（Android/Apple 图形客户端例外） | 以 `selector` / `urltest` 为主，无 Clash 式 load-balance 组 | 否 | 低：换核成本高，且 Windows 上失去按网卡能力 |
| **Xray-core** | MPL-2.0，活跃 | 原生 | 是：`sockopt.interface` 文档标注支持 Linux/iOS/macOS/Windows | 是：`routing.balancers`，策略 `random` / `roundRobin` / `leastPing` / `leastLoad` | 否（`tcpMptcp` 仅 Linux 5.6+） | 中：能力够，但无内置 TUN、无 Clash API/规则生态，需重做自愈与探针 |
| Clash Verge Rev | GUI（基于 mihomo） | 原生 | 取决于内核配置 | 取决于内核配置 | 否 | 仅 UI，不改变内核能力；NetEnv 已有控制器，不需要 |
| v2rayN / Nekoray / Netch | GUI/客户端 | 原生 | 否（或依赖底层核心选项） | 否 | 否 | 不适合做统一层 |

结论：**代理层没有比 mihomo 更合适的替代品**。它同时满足：Windows 按网卡绑定、连接级负载均衡、规则/探针/控制器生态、MIT 许可、与现有 NetEnv 零迁移。

## 4. 链路聚合/多路径项目对比（“真叠加”候选）

| 方案 | 许可证 / 状态 | 机制 | 真叠加单流？ | 部署要求 | Windows 可行性 | 主要限制 |
|---|---|---|---|---|---|---|
| **mihomo 多网卡 + load-balance** | MIT，活跃 | 每代理绑定一块网卡，按连接分摊 | **否** | 无新增组件 | **原生可用（本机已验证绑定）** | 单流不叠加；同一上游时无收益；同一目标站可能触发风控/会话漂移 |
| **OpenMPTCProuter** | GPL-3.0，活跃（v0.64.2，2026-09-14） | MPTCP（+ MLVPN/Glorytun 备选），最多 8 条链路 | **是** | OpenWrt 软路由或 x86 虚拟机 + **一台 VPS 作服务端** | 无原生客户端；Windows 走网关/虚拟机路由 | 需维护 VPS；MTU/延迟/调度调参；公网 IP 与端口；故障域增加 |
| **ZeroTier multipath** | 客户端 MPL-2.0；控制器非自由（source-available） | 节点间多链路 bond，策略 active-backup / balance-xor / balance-aware / balance-rr | 部分：balance-rr 可逐包，但文档注明不适合 TCP；TCP 基本按流 | 需要 ZeroTier 网络 + 对端/出口节点（通常 VPS） | 有 Windows 客户端 | 不是代理/翻墙工具；没有对端就没有公网出口；TCP 单流仍受限于按流策略 |
| **MLVPN** | BSD-2-Clause；最后提交 2022-08（基本停更） | 多链路 VPN，链路聚合/去抖 | 是 | Linux/BSD + VPS | 无 Windows 客户端 | 停更；需服务端；UDP 隧道调参 |
| **Glorytun** | BSD-2-Clause；最后提交 2022-02（基本停更） | 多路径 UDP 隧道，自带调度/整形 | 是 | Linux/BSD/macOS + VPS | 无 Windows 客户端 | 停更；需服务端；高延迟链路不推荐 |
| **mwan3** | GPL-2.0，OpenWrt 包（2.12.2） | 策略路由 + 连接跟踪，按权重负载均衡/故障切换 | 否 | OpenWrt 路由器 | 不适用（非 Windows） | 仅按连接；需要 OpenWrt |
| **dispatch-proxy** | MIT；已归档（最后提交 2022-05） | 本地 SOCKS/HTTP，按连接分发到多个上游 | 否 | Node.js | 理论可用 | 归档；不解决“多物理网卡”本身；不是 bonding |
| **Speedify**（闭源参照） | 商业订阅 | 包级分片 + 重排/纠错，跨链路 bonding | 是 | 官方 Windows 客户端 | 原生 | 非开源；付费；流量经其服务器，隐私/合规需评估 |
| **Windows NIC Teaming / SET** | 系统内置 | L2 链路聚合 | 取决于对端 | 交换机/服务器 | 客户端 SKU 不正式支持；Wi-Fi 不能加入 | 跨介质不可行；家庭路由器通常不支持 LACP；不要走这条路 |

## 5. 选型建议（按目标）

| 你的目标 | 建议路线 | 代价 | 备注 |
|---|---|---|---|
| 多任务/多连接总吞吐提升，尽量少改 | **mihomo 多网卡 + load-balance**（Phase 1） | 低：只改 `lib/nodes.ps1` 配置生成 + 新配置项 + 测试 | 单流不提速；需独立上行 |
| 单连接下载/视频也要叠加 | **OpenMPTCProuter + VPS**（Phase 2） | 高：软路由/VM + VPS + 运维 | 真正的 MPTCP；Windows 作为客户端路由 |
| 只要无感故障切换，不追求叠加 | mihomo 多网卡 + 健康检查/故障切换 | 低 | 比 load-balance 更稳，避免会话漂移 |
| 已用 ZeroTier 且有常开对端 | ZeroTier multipath | 中 | 适合站点互联，不是通用翻墙出口 |
| 不想自建、能接受付费 | Speedify（闭源） | 中 | 仅作参照，不满足“开源” |
| 想用 sing-box 替换 mihomo | **不建议为了叠加而换** | 高 | Windows 上 `bind_interface` 不可用 |

**推荐落地顺序**：

1. **先测上行独立性**：接上有线以太网，确认公网出口 IP、网关、ISP、上下行容量是否与 Wi-Fi 不同。若同网关/同出口，停止“叠加”项目。
2. **Phase 1（推荐先做）**：在 NetEnv 增加 `multiWan` 配置（启用、接口名、模式、参与节点数），生成：
   - 每个参与节点复制为 `<node>@wlan` / `<node>@eth` 两个 proxy，分别写 `interface-name`；
   - 新增 `lb-wan`（load-balance）+ 必要的 `url-test` 健康检查；
   - 仅对非敏感流量启用；GitHub 凭据域、GPT 域仍走现有 select/adaptive 组，避免出口 IP 漂移。
   - 用独立测试端口（如 7899）先验证，再切系统代理；保留快照回滚。
3. **Phase 2（仅当单流必须叠加）**：单独评估 OpenMPTCProuter。它和 mihomo 是竞争关系而非叠加关系：要么 Windows 默认网关指向 OMR，要么 mihomo 的上游走 OMR。不要同时叠两层代理。

## 6. 风险与验证清单

- **同上游假叠加**：当前 Wi-Fi 与“以太网 5”同 `192.168.100.0/24`、同网关；先换独立上行再谈。
- **单流不叠加**：任何“按连接”的负载均衡都无法让单条 TCP 超过单链路容量；验收要用多线程下载 + 单线程下载分开测。
- **会话/风控**：同一站点不同连接出口 IP 不同，可能触发登录失效、验证码、支付风控；用 `sticky-sessions`/规则白名单规避。
- **GitHub 凭据安全**：现有设计已接受“凭据流量可能经免费节点”的知情风险；再按连接分散出口会放大元数据暴露面，建议凭据域保持现有策略。
- **UDP/QUIC**：按流转发可能让 QUIC 连接迁移/失败；必要时对 QUIC 降级或固定出口。
- **MTU/延迟**：真叠加方案需要调 MTU（通常 1400 左右）、处理乱序；OMR 有现成参数，但需实测。
- **自愈系统**：NetEnv 的探针、系统代理漂移自愈、GPT 探针入口隔离都假设“单一出口组”；多网卡组要纳入探针，否则会出现“端口在听但某条链路已死”。
- **资源**：订阅节点复制为两份会让节点数、测速与探针成本翻倍；建议只复制精选节点（如 top 8-16），不要全池复制。
- **BOM/PS 5.1**：任何 `.ps1` 改动仍需 UTF-8 BOM、PS 5.1 语法；本方案若落地必须过 `tests\regression.ps1` 与 Pester。

## 7. Phase 1 已落地（2026-10-19）

### 7.1 代码改动

- `lib/nodes.ps1`：新增 `Get-NetEnvMultiWanPlan`（纯函数，生成复制/组计划）与 `Get-NetEnvMultiWanCandidates`（从控制器 `auto-urltest` 历史延迟选 top N）；`Build-NetEnvMergedConfig` 增加可选 `-MultiWanNodeNames`；生成顶层 `egress-select`，`MATCH` 指向它，**`proxy-select` 保持原样**（github-adaptive 的保底不能被多网卡组劫持）。
- `config/netenv.json`：新增 `multiWan` 段，默认 `enabled: false`，不改变现有行为。
- `netenv.ps1`：新增 `nodes reload`（`nodes refresh` 只写文件，不会让运行中的 mihomo 重载）；重载后显式把 `egress-select` 切到 `wan-lb`/`wan-failover`（mihomo 会从 cache.db 恢复旧选择）。
- `tests/netenv.tests.ps1`：新增 8 个用例（关闭、load-balance、failover、prefer=false、非法配置、自动选点、控制器排序、重载后选择重放）；全量回归通过。

### 7.2 配置示例

```json
"multiWan": {
  "enabled": false,
  "interfaces": [
    { "name": "WLAN", "label": "wlan" },
    { "name": "以太网", "label": "eth" }
  ],
  "mode": "load-balance",
  "strategy": "sticky-sessions",
  "maxNodes": 8,
  "nodes": [],
  "include": ["hysteria2-", "vless-", "trojan-", "ss-", "vmess-", "tuic-"],
  "exclude": ["github.com/", "免费", "剩余", "到期", "官网", "套餐", "电报", "日期", "请充值", "节点列表", "自动选择"],
  "url": "https://www.cloudflare.com/cdn-cgi/trace",
  "interval": 300,
  "lazy": true,
  "prefer": true
}
```

字段语义：

- `interfaces[].name`：必须是 `Get-NetAdapter` 的 `Name`（中文/空格原样保留）；`label` 只用于副本后缀与日志。
- `nodes`：显式节点名列表，优先级最高；为空时先用控制器 `auto-urltest` 的历史延迟取 top `maxNodes`，控制器不可用再按 `include`/`exclude` 从合并顺序兜底。
- `mode`：`load-balance`（多连接吞吐）或 `failover`（链路故障切换）。
- `strategy`：仅 load-balance 使用；`sticky-sessions` 减少同一站点会话漂移，`round-robin` 最直观，`consistent-hashing` 按目标地址粘滞。
- `prefer`：true 时把 `MATCH` 指向 `egress-select`（首成员是 `wan-lb`/`wan-failover`，启用即生效）；false 只生成组，`MATCH` 仍走 `proxy-select`，由用户手动选择。
- **为什么另开 `egress-select`**：`github-adaptive` 的成员里有 `proxy-select`。若把 `proxy-select` 切成 `wan-lb`，GitHub 保底也会走多网卡组（2026-10-19 实测启用后 github.com 从 200 变 000）。因此只改顶层 `MATCH`，不动 `proxy-select`。
- `maxNodes`：只复制少量节点，避免把 800+ 节点全池翻倍；默认 8，上限 64。

### 7.3 启用 / 回滚

1. 确认 `Get-NetAdapter` 名称与各链路公网出口是否独立。注意：**同 `/24`、同网关不等于同上行**——本机两块 USB 都是 `192.168.100.0/24`、网关 `192.168.100.1`，但公网出口分别是联通/移动；最终以 `curl --noproxy '*' --interface <本机IP> https://ifconfig.me/ip` 的结果为准。
2. 编辑 `config/netenv.json`：`multiWan.enabled = true`，按实际网卡改 `interfaces`。
3. `.\netenv.ps1 nodes refresh`：重建 `data/merged.yaml`（订阅源失败时保留旧配置）。
4. `.\netenv.ps1 nodes reload`：让运行中的 mihomo 加载新配置；控制器不可达时该命令会报错，可改为重启 mihomo。
5. 验证：经 7890/7897 访问、`Get-NetTCPConnection` 看 TCP 源地址、多线程下载与单线程下载分别对比。
6. 回滚：`enabled = false` → `nodes refresh` → `nodes reload`；或把 `prefer` 改为 `false` 后重载，`MATCH` 会退回 `proxy-select`（不改 `proxy-select` 本身，GitHub 保底不受影响）。

### 7.4 已验证 / 未验证

- **已验证**：生成 YAML 通过 `mihomo -t`；Windows 上 `interface-name` 生效（WLAN→192.168.100.5，以太网 5→192.168.100.100）；控制器候选排序在本机返回可达节点列表；启用后抓 mihomo TCP 连接，同一 trojan 节点的 `@wlan`/`@eth` 副本分别出现源地址 `192.168.100.5` 与 `192.168.100.100`，确认两块网卡都在承载流量。
- **已启用（2026-10-19）**：`interfaces` 现为 `以太网 4` + `以太网 5`（两块 USB 共享 `192.168.100.0/24`，但实测出口分别是**中国联通 112.111.24.185** 与**中国移动 223.104.55.137**，属独立上行）；`egress-select.now=wan-lb`、`proxy-select.now=auto-urltest`、`github-adaptive.now=DIRECT`；`cloudflare.com`、`github.com`、`baidu.com` 经 7897 均 200；`wan-lb` 共 16 条出站（8 节点 × 2 网卡）。
- **未验证**：独立上行下的真实吞吐增益、会话/风控表现、单链路故障切换时延。这些必须在有线接上、Phase 0 确认独立出口后实测。

## 8. 参考来源（核验日期 2026-10-19）

- mihomo 代理通用字段（`interface-name`、`mptcp`）：https://wiki.metacubex.one/config/proxies/
- mihomo 全局出站接口：https://wiki.metacubex.one/config/general/
- mihomo 负载均衡策略：https://wiki.metacubex.one/config/proxy-groups/load-balance/
- sing-box Dial Fields（`bind_interface` 仅 Linux）：https://sing-box.sagernet.org/configuration/shared/dial/
- Xray Sockopt（`interface` 支持 Windows；`tcpMptcp` 需 Linux 5.6+）：https://github.com/XTLS/Xray-docs-next/blob/main/docs/en/config/transports/sockopt.md
- Xray 路由 balancer 策略：https://xtls.github.io/en/config/routing.html
- OpenMPTCProuter 首页（版本/能力）：https://www.openmptcprouter.com/
- OpenMPTCProuter 仓库（GPL-3.0）：https://github.com/Ysurac/openmptcprouter
- ZeroTier Multipath 文档：https://docs.zerotier.com/multipath
- ZeroTier 发布说明（multipath 1.6.0 / 1.14.0）：https://github.com/zerotier/ZeroTierOne/blob/dev/RELEASE-NOTES.md
- ZeroTier 许可证布局：https://github.com/zerotier/ZeroTierOne
- MLVPN：https://github.com/zehome/MLVPN
- Glorytun：https://github.com/angt/glorytun
- mwan3：https://openwrt.org/docs/guide-user/network/wan/multiwan/mwan3
- dispatch-proxy（已归档）：https://github.com/alexkirsz/dispatch-proxy
- Cloudflare：MPTCP 平台支持（Windows 无原生支持）：https://blog.cloudflare.com/multi-path-tcp-revolutionizing-connectivity-one-path-at-a-time
- Microsoft Q&A：Windows 11 不正式支持 NIC Teaming：https://learn.microsoft.com/en-us/answers/questions/2117728/network-interface-teaming-in-windows-11
