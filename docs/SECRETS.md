# 密钥治理

- `secrets scan [--github]`：只读盘点密钥文件/凭据，输出位置与类型，不输出值。
- `secrets verify --github`：逐个 GitHub token 调 API 验证，输出哈希前缀 + HTTP 状态。
- `secrets archive`：收集 overwall 密钥文件、`%USERPROFILE%\.codex\.env` 与 config 备份、`%USERPROFILE%\.dsh` 凭据、`%USERPROFILE%\Downloads` 下的 2FA 文件、gh 凭据，打 AES-256 加密 7z 到 `backups\secrets`（相对仓库根，可用 `--dir` 覆盖），附 SHA256 清单；密码不落盘，仅显示一次。
- `secrets purge --github-expired`：删除已验证无效的 GitHub token（文件/环境变量），删除前先备份并已归档。

## 路径约定

所有探测路径均从环境推导，不写死用户名或安装盘符：

| 目标 | 解析方式 |
|---|---|
| 用户目录下凭据（`.codex` / `.dsh` / `Downloads`） | `$env:USERPROFILE` |
| 7z 打包工具 | `Get-NetEnvSevenZip`：依次探测 Program Files / Program Files(x86) / LOCALAPPDATA 的 7-Zip 与 Bandizip，并回退到 PATH 中的 `7z`/`7za`/`bz` |
| 归档与日志 | 仓库根下 `backups\` / `logs\`（相对路径） |

若上述工具均未安装，`secrets archive` 与 `adopt` 会给出明确报错，而不是指向某个固定盘符。

范围：只处理密钥；`.codex`/`.dsh` 的 sqlite 会话库等含敏感上下文的数据默认不打包，需要时单独处理。
