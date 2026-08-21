# 新电脑装配

1. 复制便携包或 `export/` 迁移包到新机（PowerShell 7 已装）。
2. `.\netenv.ps1 setup --apply`：镜像下载 mihomo/new-api（SHA256 校验）→ 安装到 `%LOCALAPPDATA%\NetEnv` → 注册 5 分钟 supervisor 计划任务 → `apply -profile proxy` → `nodes refresh` → `clients apply` → doctor 校验。
3. 凭据重建：`netenv config set-secret NetEnv/sub-<id> <URL>`（订阅）、`gh auth login`（GitHub）、new-api 上游渠道自行添加。
4. 卸载：`netenv uninstall`；回滚：`netenv apply --undo`。

WSL2（Win11 镜像网络）与 Docker Desktop（Settings→Proxies 填 `http://host.docker.internal:7890`）暂只出文档指引，不自动化。
