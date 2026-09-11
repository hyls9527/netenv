# AI 软件接入

`clients.json` 登记 Codex、Hermes、DeepSeek Agent 等软件；`clients check` 验证端点可达，`clients apply` 在软件配置目录写入 `NetEnv.env`（代理注入 + NETENV_BASE_URL），修改前自动备份，应用后需重启客户端。

AI 统一端点默认 `http://127.0.0.1:8093/v1`（new-api）；上游模型渠道由用户自行在 new-api 添加，NetEnv 不管理免费模型渠道矩阵。

## configPaths 写法

`config/clients.json` 的 `configPaths` 支持环境变量占位符，**不要写死用户名**：

```json
"configPaths": ["%USERPROFILE%\\.codex\\config.toml"]
```

`clients apply` 会先做 `[Environment]::ExpandEnvironmentVariables` 展开再判断存在性；路径不存在则静默跳过（不报错）。因此换机/换用户名后无需改仓库。
