# 端口表

| 端口 | 服务 | 用途 |
| --- | --- | --- |
| 7890 | mihomo mixed | 代理混合入口（http+socks） |
| 7897 | mihomo http | 系统代理 / git / npm 注入 |
| 19090 | mihomo controller | Clash Verge 控制台 |
| 8093 | new-api | AI 统一端点（127.0.0.1） |
| 3001 | Sub-Store | 订阅管理（127.0.0.1）；`config/netenv.json` 的 `ports.subStore` |
| 8099 | （未启用） | 原文档误标为 Sub-Store 端口；实际未使用，保留以免再被占用 |

规则：端口冲突时报错并列出占用进程，NetEnv 不自动改端口。8094/8095 为已退役的 gemini-web2api/tfg 预留，不再启用。
