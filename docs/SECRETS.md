# 密钥治理

- `secrets scan [--github]`：只读盘点密钥文件/凭据，输出位置与类型，不输出值。
- `secrets verify --github`：逐个 GitHub token 调 API 验证，输出哈希前缀 + HTTP 状态。
- `secrets archive`：收集 overwall 密钥文件、`.codex\.env` 与 config 备份、`.dsh` 凭据、2FA 文件、gh 凭据，打 AES-256 加密 7z 到 `C:\Users\Admin\Downloads`，附 SHA256 清单；密码不落盘，仅显示一次。
- `secrets purge --github-expired`：删除已验证无效的 GitHub token（文件/环境变量），删除前先备份并已归档。

范围：只处理密钥；`.codex`/`.dsh` 的 sqlite 会话库等含敏感上下文的数据默认不打包，需要时单独处理。
