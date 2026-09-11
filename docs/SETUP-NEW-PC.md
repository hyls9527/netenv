# 新电脑装配

1. 复制便携包或 `export/` 迁移包到新机。
   - **PowerShell 7（`pwsh`）非必需**：全部脚本兼容 Windows PowerShell 5.1。若只有 5.1，不要执行 `install` 的默认计划任务（其 `-Execute 'pwsh.exe'` 会失败），改用下方"便携模式"。
2. `.\netenv.ps1 setup --apply`：镜像下载 mihomo/new-api（SHA256 校验）→ 安装到 `%LOCALAPPDATA%\NetEnv` → 注册 5 分钟 supervisor 计划任务 → `apply -profile proxy` → `nodes refresh` → `clients apply` → doctor 校验。
3. 凭据重建：`netenv config set-secret NetEnv/sub-<id> <URL>`（订阅）、`gh auth login`（GitHub）、new-api 上游渠道自行添加。
4. 卸载：`netenv uninstall`；回滚：`netenv apply --undo`。

## 便携模式（推荐用于无 `pwsh` / 无管理员权限的机器）

不安装、不注册计划任务，全部相对仓库根运行：

```powershell
# 1) 只读体检（随时可跑，非管理员亦可）
.\netenv.ps1 doctor
```

- `config/netenv.json` 的 `mode` 保持 `portable` → 运行态在 `<仓库>\data`，日志在 `<仓库>\logs`，备份在 `<仓库>\backups`。
- `bootstrap` 需要 `api.github.com`；若该域被 DNS 污染，可手工下载后放入 `data\bin\`（仓库带 gh-proxy 镜像回退）。
- `geosite.dat` / `geoip.metadb` 放在 **`data\` 根目录**（mihomo 的 `-d` 指向处），不是 `data\bin\`。
- 自启：把 `lib\run-supervisor-hidden.vbs` 的快捷方式放进
  `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup`（免管理员；`.vbs` 按自身路径解析，换目录不失效）。
- 需要常驻探活时，`run-supervisor-hidden.vbs` 会拉起 `lib\supervisor-loop.ps1`（按 `supervisor.intervalMinutes` 周期自愈）。

## 需要管理员的动作

改 DNS / 接口跃点 / 防火墙、注册计划任务（`install --autostart`、`fix-boot-task.ps1`）均需提权。提权后请用完整路径调用，例如：

```powershell
Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','<绝对路径>\lib\fix-boot-task.ps1'
```

WSL2（Win11 镜像网络）与 Docker Desktop（Settings→Proxies 填 `http://host.docker.internal:7890`）暂只出文档指引，不自动化。
