# MCP（AI 状态检测）

`netenv mcp` 以 stdio JSON-RPC 2.0 提供只读工具，stdout 只输出 JSON、日志走 stderr，输出字段白名单、无任何密钥值。

| 工具 | 返回 |
| --- | --- |
| netenv_status | profile、mihomo/new-api/Sub-Store 状态、订阅新鲜度、节点数 |
| netenv_doctor_summary | 端口/系统代理/git/npm/旧任务/旧进程/网关健康 |
| netenv_nodes_summary | 订阅更新时间、节点数、来源健康 |
| netenv_config_status | 配置校验、备份数、allowWrite |

注册到 Codex（`.codex/config.toml`）：

```toml
[mcp_servers.netenv]
command = "pwsh"
args = ["-NoProfile", "-File", "C:\\path\\to\\netenv\\netenv-mcp.ps1"]
```

- 没有 `pwsh`（或它不在 PATH）的机器改用完整路径的 Windows PowerShell：
  `command = "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"`（脚本本身兼容 5.1）。
- `netenv_doctor_summary` 走完整体检（含真实出品与证书探针），冷启动可能十几秒到几十秒；客户端读取超时请放宽。

写操作默认禁用；`netenv.json` 中 `mcp.allowWrite` 显式改为 true 才开启。
