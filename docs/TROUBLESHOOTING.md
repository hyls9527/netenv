# 排障

- 端口被占：`netenv doctor` 列出占用进程；NetEnv 不自动改端口。
- 系统代理被覆盖：Clash Verge 重开会重写系统代理（上游已知 BUG），doctor 检查 ProxyServer 是否为 `127.0.0.1:7897`。
- 已运行程序不生效：apply 后需重启客户端（环境变量只对新进程生效）。
- 订阅失效：doctor 报订阅新鲜度告警；`nodes refresh` 失败会保留旧配置。
- 局域网设备被 fake-ip 拦截：私网段（10/172.16/192.168）默认直连例外。
- MCP 无输出：检查是否以 stdio 启动；日志在 stderr。
- 便携版换盘符：配置全相对路径，启动自检；若自启动任务失效，重跑 `install --autostart`。

## 常见故障（实测记录）

- **报 `Unexpected token` / `字符串缺少终止符` / `MissingEndParenthesis` 但代码看着没问题**：
  该 `.ps1` 丢了 UTF-8 BOM，Windows PowerShell 5.1 按 GBK 解码，中文注释破坏引号配对。
  修复：`[IO.File]::WriteAllText($p, [IO.File]::ReadAllText($p,(New-Object Text.UTF8Encoding($false))), (New-Object Text.UTF8Encoding($true)))`。
  **任何编辑工具都可能顺手剥掉 BOM，改完必查。**
- **`The term 'npm' is not recognized` 导致 `apply`/`doctor` 整体中断**：
  在 `$ErrorActionPreference='Stop'` 下调用不存在的命令会终止流程。已对 `npm` 加 `Get-Command` 守卫（缺失则跳过并 WARN）。
- **`pwsh` 不存在**：全部脚本兼容 5.1；但 `install --autostart` 生成的计划任务写的是 `pwsh.exe`，此类机器请改用便携模式 + 启动文件夹。
- **`github.com` 打不开，但 `api.github.com` / `codeload.github.com` 正常**：
  典型 DNS 污染 —— `github.com` 被解析到不可达 IP（实测 `20.205.243.166` 超时，真实 IP `140.82.112.3` 可通）。
  诊断：`Resolve-DnsName github.com -Type A -Server 223.5.5.5`，再对解析出的 IP 做 TCP 443 探测。
  缓解：`merged.yaml` 已启用 `sniffer`（`override-destination: true`），按 TLS SNI 还原域名后再匹配规则。
- **`www.google.com` 解析到 `157.240.7.20`（Facebook 的 IP）**：同为污染特征，属出口节点问题，需可用节点。
- **mihomo 启动即失败并报 `can't download GeoSite.dat`**：
  它会在启动时去墙外下载 geodata。需预置 `data\GeoSite.dat` 与 `data\geoip.metadb`（放在 `-d` 指向的数据根，**不是** `data\bin\`）。
- **规则重复**：同一域名同时命中 `DIRECT` 与 `github-adaptive` 说明该域被同时写进 `sensitiveDomains`/`githubAuthDomains` 与 `githubAdaptiveDomains`。前者优先，后者永远不可达，需从 `githubAdaptiveDomains` 移除。
- **`tests\netenv.tests.ps1` 在 Pester 3.4.0 下失败**（已实测，非版本兼容问题）：
  1. `Describe 'NetEnv config'` 报 `PSInvalidCastException` —— Pester 3 的 `Describe` 第二参数必须是 ScriptBlock，测试却传了字符串；
  2. `$out | Should Match 'name: auto-select'` 断言组名 `auto-select`，但 `Build-NetEnvMergedConfig` 生成的是 `auto-urltest`。
  两者都是**测试与实现的历史漂移**（测试按 Pester 5 语法编写），需更新测试而非改配置。运行时功能不受影响。
- 测试文件中的 `ghp_...` 字面量是**脱敏用例的样本值**，不是真实凭据，无需处理。
