# 排障

- 端口被占：`netenv doctor` 列出占用进程；NetEnv 不自动改端口。
- 系统代理被覆盖：Clash Verge 重开会重写系统代理（上游已知 BUG），doctor 检查 ProxyServer 是否为 `127.0.0.1:7897`。
- 已运行程序不生效：apply 后需重启客户端（环境变量只对新进程生效）。
- 订阅失效：doctor 报订阅新鲜度告警；`nodes refresh` 失败会保留旧配置。
- 局域网设备被 fake-ip 拦截：私网段（10/172.16/192.168）默认直连例外。
- MCP 无输出：检查是否以 stdio 启动；日志在 stderr。
- 便携版换盘符：配置全相对路径，启动自检；若自启动任务失效，重跑 `install --autostart`。
