# NetEnv

本机统一网络代理层 + AI 软件网络适配 + 密钥治理（Windows / PowerShell 工具链）。

- **一个入口**：mihomo（Clash.Meta）承担全部代理职责；端口表固定，冲突即报错（见 [docs/PORTS.md](docs/PORTS.md)）
- **订阅管线**：`nodes refresh` 聚合多源免费订阅、剥离危险字段，生成 `data/merged.yaml`
- **档位管理**：`apply -profile direct|proxy|github` 切换系统代理 / Git / npm / 环境变量，带快照可回滚
- **LLM 网关**：本机 new-api 实例（端口表 8093）作为模型 API 统一入口
- **AI 可达性**：`netenv-mcp.ps1` 提供只读、输出脱敏的 MCP 状态检测
- **密钥治理**：订阅 URL 只进 Windows 凭据管理器；GitHub token 验证 / 清理；AES-256 7z 归档（见 [docs/SECRETS.md](docs/SECRETS.md)）

## 快速开始

```powershell
.\netenv.ps1 bootstrap          # 首次：镜像下载 mihomo / new-api 并 SHA256 校验
.\netenv.ps1 doctor             # 只读体检
.\netenv.ps1 status             # 状态摘要
.\netenv.ps1 config set-secret NetEnv/sub-free-nodes <订阅URL>   # 订阅 URL 只进凭据管理器
.\netenv.ps1 nodes refresh      # 聚合订阅 → data/merged.yaml
.\netenv.ps1 apply -profile proxy
```

命令全表：`doctor / status / apply / nodes / clients / adopt / migrate / setup / install / uninstall / bootstrap / clean / config / secrets / mcp`，详见 `.\netenv.ps1 --help`。

## 目录结构

```text
netenv.ps1          主入口（调度器 + 实例锁）
netenv-mcp.ps1      MCP stdio server（JSON-RPC 2.0，默认只读）
lib/                core.ps1 + 命令模块 + supervisor/supervisor-loop（常驻自愈）+ run-supervisor-hidden.vbs（零窗口启动器）
config/             netenv.json / sources.json / clients.json（默认值，不含密钥）
docs/               文档（见下方索引）
tests/              Pester 测试与回归脚本
data/  logs/  backups/  export/     运行态与归档（.gitignore，不入库）
```

## 关键设计（不可关闭的底线）

- **GitHub 可用性保底**：`github.com`、两个内容域（`raw.githubusercontent.com` / `objects.githubusercontent.com`）**以及三个凭据端点**
  （`api.github.com` / `codeload.github.com` / `ssh.github.com`）全部交给 `github-adaptive` 组，组内同时持有 `github-node` / `proxy-select` / `DIRECT`，
  按 github 自身端点探活后**自动择通择优** —— 直连抖动时自动改走节点，节点挂了自动回直连。
  凭据端点原设计强制 `DIRECT`，2026-09-11 因"直连抖动时没有任何退路，`git clone` 与 device-flow 登录直接失败"改为同组保底。
  ⚠️ **知情选择：可用性优先，等于接受凭据流量经免费节点**（TLS 仍端到端加密，但出口节点可见目标元数据）；回退步骤见 [docs/GITHUB-SAFETY.md](docs/GITHUB-SAFETY.md)。
- **`github-adaptive` 组的选点依据必须是 github 自身端点**，默认 `https://github.com/robots.txt`，可由 `config/netenv.json` 的 `subscription.githubUrlTest.url` 覆盖。
  用 `google/gstatic` 之类的通用 URL 会得出错误结论 —— 节点能通 google 不代表能通 github（实测同一时刻 DIRECT 探活 504 而节点 921 ms）。
- **敏感域名直连**：`sensitiveDomains + githubAuthDomains` 生成 `DOMAIN-SUFFIX,<domain>,DIRECT` 规则。
  ⚠️ **同一域名不得同时出现在直连列表与 `githubAdaptiveDomains`**：DIRECT 规则在前会胜出，自适应规则永远不可达（曾是真实缺陷）。
- **订阅仅 HTTPS**，剥离 `script` 等危险字段；订阅 URL 存 Windows 凭据管理器，不入盘
- **代理面不对外**：mihomo 的 `mixed-port` / `http` / `external-controller` 均绑定 `127.0.0.1`，`allow-lan: false`
- **`.ps1` 一律带 UTF-8 BOM**：脚本含中文，且计划任务以 `powershell.exe`（Windows PowerShell 5.1）`-File` 方式执行；无 BOM 时 5.1 会按 ANSI/GBK 解码导致中文乱码。**改动任何 `.ps1` 后请复查 BOM。**
- **兼容 Windows PowerShell 5.1**：环境可能只有 `powershell.exe` 而无 `pwsh.exe`。因此脚本内**不得使用 PS7 专属语法**（`::new()` 构造、`??`、三元 `? :`、`-Parallel` 等），统一用 `New-Object` 与显式 `if/else`。
- **路径全部通用化**：不写死用户名或安装盘符 —— 用户目录用 `$env:USERPROFILE`，仓库内部用 `$PSScriptRoot` 推导，外部工具（7z）用 `Get-NetEnvSevenZip` 探测，客户端注入点用 `%USERPROFILE%` 占位符。换机只需改 `config/netenv.json`。
- **可选外部依赖缺失必须降级而非崩溃**：`npm`、`gh`、7-Zip 等未安装时跳过该步并记 WARN；在 `$ErrorActionPreference='Stop'` 下直接调用不存在的命令会终止整条流程。

## 常驻与自愈

- **双层健康判据**：`supervisor.ps1` 只负责进程存活（端口在听）；`supervisor-loop.ps1` 另按
  `health.probeIntervalMinutes` 做**端到端出品探针**（真实经代理请求 `health.probeUrls`，**任一目标可达即算可用**）。
  端口在听 ≠ 能上网 —— 实测 423 个节点中仅 8 个能到 google，而端口照样 LISTEN。
  判据取多目标 OR 而非单目标：单探 google 会把"google 被墙、github 正常"误判成整机出品不可用，
  从而每 5 分钟空刷一次订阅源（真实故障，见 `logs/20260917.log`）。
- **github 专项探针（判据独立于上面的 OR）**：`health.githubProbe.enabled` 为真时，`supervisor-loop`
  每轮再**单独**探一次 github（默认 `https://github.com/robots.txt`），连败达
  `githubProbe.failThreshold` 即触发该组**重新测速择通**（`Invoke-NetEnvGithubGroupRecovery` →
  `GET /group/<组>/delay`），复测通过则记 INFO，`recoverMinIntervalMinutes` 负责退避。
  - **为什么必须独立**：出品判据是 OR，google 通时 github 单独挂掉**不会触发任何自愈** ——
    实测 2026-09-17 `github.com` 经代理握手失败（`git push/clone` 全废），而 `health-state.json` 一路 `lastOk`。
  - **为什么恢复动作不是刷订阅**：`github-adaptive` 组是 `lazy: true`（没流量就不测速），一旦某轮被判定
    `alive:false` 就再没有流量进来、也就永远不再测速，坏状态被**冻结**；而组内节点其实健康
    （同一次测速实测 `github-node` 595ms / `proxy-select` 686ms）。触发一次组测速即恢复，代价远低于刷订阅。
- **系统代理漂移自愈**：`supervisor-loop` 每轮比对 WinINET 实际值与当前档位期望值并重写（5 分钟退避）。
  必要性：第三方 VPN / 代理客户端连接时会接管系统代理，而**进程探活与出品探针都发现不了** ——
  端口照样 LISTEN、经隧道探针照样通，吃系统代理的程序却已全部退回直连（典型的"全绿着坏"）。
  判据与 `doctor` 共用 `Get-NetEnvSystemProxyState`；`doctor` 另有 `代理绕过清单`、`VPN 类接管`、
  `VPN 类自启项` 三项，专治 TUN 接管下的探针假阳性（见 [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)）。
- **降级链**：探针连续失败达 `health.failThreshold` → 触发 `nodes refresh`（自带"失败保留旧配置"）
  → **经控制器 `PUT /configs?force=true` 重载 mihomo**（刷新只改 `data/merged.yaml`；运行中的 mihomo 不会自己读新配置，
  不重载则刷新出的节点永远不生效）→ 仍不可用且 `health.autoFallbackToDirect` 为真时回退 `apply -profile direct`。
  状态写入 `data/health-state.json`；其中 `lastRefreshAt` 配合 `health.autoRefreshMinIntervalMinutes`（默认 30 分钟）
  限制自动刷新频率，避免目标长期不可达时每 5 分钟锤一次订阅源。
- 计划任务 `NetEnv-Supervisor`（开机）+ `NetEnv-Supervisor-Periodic`（每 5 分钟）→ `lib\run-supervisor-hidden.vbs` → `lib\supervisor-loop.ps1`：探活并拉起 mihomo / new-api
  - `install --autostart` 需要管理员权限；**两条任务都用 `wscript.exe` 启动 VBS，不依赖 PATH 里的 `pwsh.exe`**（PATH 缺 pwsh 时计划任务会静默失败），且不闪黑窗
  - VBS 内有**单实例守卫**：周期任务只在自愈循环已死时补拉，不会出现两个循环抢重启与日志
- **失败统计只认"已部署"的服务**：二进制不存在的可选服务（new-api/Sub-Store）直接跳过，
  不参与失败计数（否则未部署的 new-api 会让日志每分钟刷一条 ERROR，把真故障淹没）
- 日志按天轮转、脱敏、UTF-8 编码，保留天数由 `logging.rotateDays`（默认 14）决定，`netenv clean` 用同一口径（`logs/`，不入库）
- **订阅刷新不是自动的**：需手动 `nodes refresh`（或用你自己的调度；`merged.yaml` 的生成时间可在 `data/sub-state.json` 查看）
- 非管理员可用的只读动作：`doctor` / `status`；`adopt -Apply` 等接管动作需要管理员权限

## 维护与自检

- 回归：`Import-Module Pester; .\tests\regression.ps1`（Pester 3.4，跑 3 轮）；`.\tests\regression.ps1 -Live` 会真起 mihomo 并临时切系统代理，仅在需要冒烟时用
- 体检：`netenv doctor`（失败项退出码 1）；`doctor --json` 提供给 MCP 的 `netenv_doctor_summary`
- **改完任何 `.ps1` 必须复查 UTF-8 BOM**：编辑工具常常顺手剥掉 BOM，5.1 会按 GBK 解码使中文破坏引号配对（`doctor` 有 `脚本 UTF-8 BOM` 项兜底）
- Windows PowerShell 5.1 实测坑位（改代码前先看，避免重新踩）：
  - `@($genericListOfObject)` 会抛 `Argument types do not match`（`List[string]`/`Object[]` 正常）→ 统一用 `.ToArray()`
  - `Get-Content -Raw` 默认按 ANSI(GBK) 解码 → 读配置/状态一律走 `Read-NetEnvFileText`（显式 UTF-8，兼容有/无 BOM）
  - `curl` 连接失败时 `%{http_code}` 返回 `000`，"3 位数字"不等于成功 → 必须结合退出码判断
  - 外部命令缺失（`npm`/`gh`/`7z`）在 `$ErrorActionPreference='Stop'` 下会终止整条流程 → 先 `Get-Command` 守卫再降级

## 文档索引

| 文档 | 内容 |
|---|---|
| [docs/PORTS.md](docs/PORTS.md) | 端口表（固定，冲突即报错） |
| [docs/GITHUB-SAFETY.md](docs/GITHUB-SAFETY.md) | GitHub 认证流量与凭据安全细则 |
| [docs/SECRETS.md](docs/SECRETS.md) | 密钥盘点 / 验证 / 归档 / 清理 |
| [docs/MCP.md](docs/MCP.md) | MCP 接入与权限 |
| [docs/AI-CLIENTS.md](docs/AI-CLIENTS.md) | AI 软件（编辑器 / CLI）代理接入 |
| [docs/SETUP-NEW-PC.md](docs/SETUP-NEW-PC.md) | 新机装配 |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | 排障 |

## 合规提示

本工具链用于网络代理配置管理，使用者自行承担当地法律法规责任；仅限个人设备使用。
