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
- **`MethodNotFound: SHA256 不包含 HashData`**：`SHA256::HashData` / `Convert::ToHexString` / `MD5::HashData`
  都是 .NET 5+ API，Windows PowerShell 5.1 的 .NET Framework 下不存在。需改用
  `New-Object System.Security.Cryptography.SHA256Managed` + `ComputeHash` + 逐字节 `ToString('x2')`。
- **`secrets archive` / `adopt -Apply` 报 `Parameter Paring Error`**：说明走的是 Bandizip 的 `bz.exe`，
  而它**不兼容 7-Zip 参数语法**（`-t7z` / `-mhe=on` 均被拒）。已由 `Get-NetEnvArchiveArgs` 按工具分派：
  7-Zip 用 `a -t7z -p<pw> -mhe=on`；Bandizip 用 `a -fmt:7z -p:<pw>`（其 7z 加密头默认开启，实测无密码无法列出条目名）。
- **代理端口在听但打不开网页**：先跑 `netenv doctor`，看 `端到端出品（经代理实测）` 这一项。
  它走真实请求，能区分"进程活着"与"出口可用"；`data/health-state.json` 记录连续失败次数。
- **`SEC_E_CERT_EXPIRED` / `schannel: failed to receive handshake` / `SSL routines::unexpected eof`**：
  免费出口节点呈现的证书无效或会话被中断。诊断要点（实测得出）：
  - `curl -k`（跳过校验）若返回正常状态码 → **隧道是通的，问题在证书**，不是网络封禁；
  - mihomo 内部探针**不校验证书**，所以它会对同一节点报 200 —— 不要用它的结论判断"能否访问 github"；
  - 两者结合可判定该节点是否在**中间人（MITM）**；
  - 处理：换节点（`github-node` 组会按 github 端点重新甄选）或重试（同一操作换节点后往往直接成功）。
  这也是 `api.github.com` / `codeload.github.com` / `ssh.github.com` 保持 `DIRECT` 的原因：
  凭据不该交给证书不可信的出口。
- **`github.com` 时通时不通，而 google 一直正常**：通用组按 google 选点，但"能通 google"的节点未必能完成
  github 的 TLS 会话（实测同一节点 google 204 而 github 证书校验失败；423 节点中仅 11 个能到 github 端点）。
  已由 `github-node` 组（用 github 自身端点甄选）解决。
- **`gitclone.com` 等镜像不能用于 git 操作**：实测其 git 端点返回 502（首页 132ms 可达具有误导性），
  且走镜像需把 token 交给第三方，安全上不可接受。`gh-proxy` 系列只能加速**单文件 HTTP 下载**（实测 raw 200），
  不是 git 协议。因此 git 层面只有"直连 / 经节点"两条路。
