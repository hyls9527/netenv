# NetEnv v1

统一网络代理层 + AI 软件网络适配 + 密钥治理。便携版解压即用，安装版一键装配，MCP 让 AI 检测状态。

## 快速开始（便携版）

```powershell
.\netenv.ps1 bootstrap          # 首次: 镜像下载 mihomo/new-api 并 SHA256 校验
.\netenv.ps1 doctor             # 只读体检
.\netenv.ps1 status             # 状态摘要
.\netenv.ps1 config set-secret NetEnv/sub-free-nodes <订阅URL>   # 订阅 URL 只进凭据管理器
.\netenv.ps1 nodes refresh      # 聚合免费订阅 + 剥离危险字段
.\netenv.ps1 apply -profile proxy
```

所有命令：`doctor / status / apply / nodes / clients / adopt / migrate / setup / install / uninstall / bootstrap / clean / config / secrets / mcp`，详见 `netenv.ps1 --help`。

## 设计底线（不可关闭）

- 端口表固定，冲突即报错：见 [PORTS.md](PORTS.md)
- GitHub 认证流量强制直连、凭据零明文：见 [GITHUB-SAFETY.md](GITHUB-SAFETY.md)
- 免费节点只承载普通浏览与非认证流量；敏感域名直连
- 订阅仅 HTTPS，剥离 script 等危险字段；订阅 URL 存 Windows 凭据管理器
- MCP 默认只读、输出脱敏：见 [MCP.md](MCP.md)

## 模块说明

- 密钥治理：[SECRETS.md](SECRETS.md)（GitHub token 验证/清理 + AES-256 7z 归档）
- 新电脑装配：[SETUP-NEW-PC.md](SETUP-NEW-PC.md)
- AI 软件接入：[AI-CLIENTS.md](AI-CLIENTS.md)
- 排障：[TROUBLESHOOTING.md](TROUBLESHOOTING.md)

## 目录

```text
netenv/
  netenv.ps1        主入口（调度器 + 实例锁）
  netenv-mcp.ps1    MCP stdio server（JSON-RPC 2.0）
  lib/              各命令模块
  config/           netenv.json / sources.json / clients.json（默认，不含密钥）
  data/             bin、订阅缓存、状态（gitignore）
  logs/             脱敏日志，按天轮转留 30 天（gitignore）
  backups/          快照与备份（gitignore）
  export/           新机迁移包（gitignore）
  docs/             文档
  tests/            Pester 测试
```

## 合规提示

本工具链用于网络代理配置管理，使用者自行承担当地法律法规责任；仅限个人设备使用。
