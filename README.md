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
lib/                core.ps1 + 12 个命令模块 + 1 个零窗口启动器（run-supervisor-hidden.vbs）
config/             netenv.json / sources.json / clients.json（默认值，不含密钥）
docs/               文档（见下方索引）
tests/              Pester 测试与回归脚本
data/  logs/  backups/  export/     运行态与归档（.gitignore，不入库）
```

## 关键设计（不可关闭的底线）

- **GitHub 认证流量强制直连**：`github.com` / `api.github.com` / `codeload.github.com` / `ssh.github.com` 不经过免费节点，凭据零明文（见 [docs/GITHUB-SAFETY.md](docs/GITHUB-SAFETY.md)）
- **`github-adaptive` 组的选点依据必须是 github 自身端点**，默认 `https://github.com/robots.txt`，可由 `config/netenv.json` 的 `subscription.githubUrlTest.url` 覆盖。
  用 `google/gstatic` 之类的通用 URL 会得出错误结论 —— 节点能通 google 不代表能通 github，会把 `github.com` 判给机场节点，后果是访问变慢**且**认证流量被送上第三方节点。
- **敏感域名直连**：`sensitiveDomains + githubAuthDomains` 生成 `DOMAIN-SUFFIX,<domain>,DIRECT` 规则
- **订阅仅 HTTPS**，剥离 `script` 等危险字段；订阅 URL 存 Windows 凭据管理器，不入盘
- **代理面不对外**：mihomo 的 `mixed-port` / `http` / `external-controller` 均绑定 `127.0.0.1`，`allow-lan: false`
- **`.ps1` 一律带 UTF-8 BOM**：脚本含中文，且计划任务以 `powershell.exe`（Windows PowerShell 5.1）`-File` 方式执行；无 BOM 时 5.1 会按 ANSI/GBK 解码导致中文乱码。**改动任何 `.ps1` 后请复查 BOM。**

## 常驻与自愈

- 计划任务 `NetEnv-Supervisor`（开机）+ `NetEnv-Supervisor-Periodic`（定时）→ `lib\run-supervisor-hidden.vbs` → `lib\supervisor.ps1`：探活并拉起 mihomo / new-api
- 日志按天轮转、脱敏，保留 30 天（`logs/`，不入库）
- **订阅刷新不是自动的**：需手动 `nodes refresh`（或用你自己的调度；`merged.yaml` 的生成时间可在 `data/sub-state.json` 查看）
- 非管理员可用的只读动作：`doctor` / `status`；`adopt -Apply` 等接管动作需要管理员权限

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
