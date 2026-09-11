# GitHub 安全细则（最高优先级）

- **认证流量保底策略（现行设计）**：`github.com` 不再强制直连，而是交给 `github-adaptive` 组做**双向保底** ——
  该组同时持有 `proxy-select` 与 `DIRECT` 两个候选，按 `https://github.com/robots.txt` 持续探活，**谁通/谁快就用谁**。
  理由：实测直连 `github.com` 会间歇性不可用（`DIRECT` 探活返回 504，而代理侧 921 ms 正常），强制直连会导致完全中断。
  代价与知情选择：可用性优先于"绝不经第三方节点"。走节点时 TLS 仍端到端加密，但**出口节点可见目标元数据**。
- `api.github.com`、`codeload.github.com`、`ssh.github.com` 亦走 `github-adaptive`（**2026-09-11 变更**）：
  这三个是**承载凭据的端点**（token 校验、仓库数据、SSH 认证）。原设计强制直连（`DOMAIN-SUFFIX,…,DIRECT`），
  理由是"不让免费节点经手凭据"。
  ⚠️ 实测该设计在直连抖动时**没有退路**，代价已经真实发生：`git clone` 与 device-flow 登录直接失败
  （直连 `github.com:443` 超时 10 s，同一时刻经代理 996 ms 正常，见 dsh-config-manager#29/#30）。
  故改为与 `github.com` 同组保底。**知情选择：可用性优先，等于接受凭据流量经免费节点**；
  走节点时 TLS 仍端到端加密，但出口节点可见目标元数据。
  回退方式：把这三个域移回 `githubAuthDomains` 与 `sensitiveDomains`、并加回 `noProxy`，然后重建
  `merged.yaml` 规则并 reload mihomo —— 注意 `netenv apply -profile proxy` 只改系统/环境代理，
  **不会**重算 mihomo 规则（规则由 `config/netenv.json` → `Build-NetEnvMergedConfig` 生成）。
- 公开下载（`raw.githubusercontent.com`、`objects.githubusercontent.com`）走 `github-adaptive`；也可改用 gh-proxy/jsdelivr 可信镜像，且不携带凭据。
- 手动干预：控制台 `http://127.0.0.1:19090`，或 `netenv apply -profile github`（只注入 git 代理，不动系统流量）。
- token/SSH 密钥只存 Windows 凭据管理器与 ssh-agent；git remote 不内嵌凭据；日志按正则脱敏。
- 2FA 备份文件（authenticator.txt）不入任何仓库、不入配置包。
- 新机重新认证用 `gh auth login`；NetEnv 不创建、不修改、不导出 GitHub 凭据值。
- 过期/无效 token 用 `netenv secrets verify --github` 检出、`secrets purge --github-expired` 清理（清理前必先归档）。
