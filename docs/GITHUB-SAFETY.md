# GitHub 安全细则（最高优先级）

- 认证流量强制直连：`github.com`、`api.github.com`、`codeload.github.com`、`ssh.github.com` 永不匹配代理规则。
- `git push/pull`、`gh` CLI、网页登录不经过免费节点；公开下载（release/raw）可走 gh-proxy/jsdelivr 可信镜像，且不携带凭据。
- token/SSH 密钥只存 Windows 凭据管理器与 ssh-agent；git remote 不内嵌凭据；日志按正则脱敏。
- 2FA 备份文件（authenticator.txt）不入任何仓库、不入配置包。
- 新机重新认证用 `gh auth login`；NetEnv 不创建、不修改、不导出 GitHub 凭据值。
- 过期/无效 token 用 `netenv secrets verify --github` 检出、`secrets purge --github-expired` 清理（清理前必先归档）。
