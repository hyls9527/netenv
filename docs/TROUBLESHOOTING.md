# 排障

- 端口被占：`netenv doctor` 列出占用进程；NetEnv 不自动改端口。
- 系统代理被覆盖：Clash Verge 重开会重写系统代理（上游已知 BUG），doctor 检查 ProxyServer 是否为 `127.0.0.1:7897`。
- 已运行程序不生效：apply 后需重启客户端（环境变量只对新进程生效）。
- 订阅失效：doctor 报订阅新鲜度告警；`nodes refresh` 失败会保留旧配置。
- 局域网设备被 fake-ip 拦截：私网段（10/172.16/192.168）默认直连例外。
- MCP 无输出：检查是否以 stdio 启动；日志在 stderr。
- 便携版换盘符：配置全相对路径，启动自检；若自启动任务失效，重跑 `install --autostart`。
- 自启动没反应且桌面弹出 `Microsoft VBScript 编译器错误`：见下方「VBS 启动器语法错误」。

## 常见故障（实测记录）

- **报 `Unexpected token` / `字符串缺少终止符` / `MissingEndParenthesis` 但代码看着没问题**：
  该 `.ps1` 丢了 UTF-8 BOM，Windows PowerShell 5.1 按 GBK 解码，中文注释破坏引号配对。
  修复：`[IO.File]::WriteAllText($p, [IO.File]::ReadAllText($p,(New-Object Text.UTF8Encoding($false))), (New-Object Text.UTF8Encoding($true)))`。
  **任何编辑工具都可能顺手剥掉 BOM，改完必查。**
- **`The term 'npm' is not recognized` 导致 `apply`/`doctor` 整体中断**：
  在 `$ErrorActionPreference='Stop'` 下调用不存在的命令会终止流程。已对 `npm` 加 `Get-Command` 守卫（缺失则跳过并 WARN）。
- **`pwsh` 不存在**：全部脚本兼容 5.1；`install --autostart` 已改为 `wscript.exe` + `lib\run-supervisor-hidden.vbs`
  （零窗口、不依赖 PATH 里的 `pwsh.exe`，PATH 缺 pwsh 时 `-Execute 'pwsh.exe'` 的计划任务会静默失败）。
  仍无管理员权限的机器用便携模式 + 启动文件夹快捷方式。
- **`github.com` 打不开，但 `api.github.com` / `codeload.github.com` 正常**：
  典型 DNS 污染 —— `github.com` 被解析到不可达 IP（实测 `20.205.243.166` 超时，真实 IP `140.82.112.3` 可通）。
  诊断：`Resolve-DnsName github.com -Type A -Server 223.5.5.5`，再对解析出的 IP 做 TCP 443 探测。
  缓解：`merged.yaml` 已启用 `sniffer`（`override-destination: true`），按 TLS SNI 还原域名后再匹配规则。
- **`www.google.com` 解析到 `157.240.7.20`（Facebook 的 IP）**：同为污染特征，属出口节点问题，需可用节点。
- **mihomo 启动即失败并报 `can't download GeoSite.dat`**：
  它会在启动时去墙外下载 geodata。需预置 `data\GeoSite.dat` 与 `data\geoip.metadb`（放在 `-d` 指向的数据根，**不是** `data\bin\`）。
- **规则重复**：同一域名同时命中 `DIRECT` 与 `github-adaptive` 说明该域被同时写进 `sensitiveDomains`/`githubAuthDomains` 与 `githubAdaptiveDomains`。前者优先，后者永远不可达，需从 `githubAdaptiveDomains` 移除。
- **`tests\netenv.tests.ps1` 在 Pester 3.4.0 下失败**（历史记录，已修复）：
  1. `Describe 'NetEnv config'` 报 `PSInvalidCastException` —— Pester 3 的 `Describe` 第二参数必须是 ScriptBlock，测试却传了字符串；
  2. `$out | Should Match 'name: auto-select'` 断言组名 `auto-select`，但 `Build-NetEnvMergedConfig` 生成的是 `auto-urltest`。
  两者都是**测试与实现的历史漂移**，已按实现修正断言；当时 20 个用例全绿（用例数会随守卫增补上涨，
  以 `.\tests\regression.ps1` 的实际输出为准，不要照抄数字）。
- 测试文件中的 `ghp_...` 字面量是**脱敏用例的样本值**，不是真实凭据，无需处理。
- **`doctor --json` 或 MCP `netenv_doctor_summary` 报 `Argument types do not match`**：
  Windows PowerShell 5.1 下 `@($genericListOfObject)` 会抛 `ArgumentException`（`List[string]`、`Object[]` 均正常，实测 5.1.26100）。
  已改为 `.ToArray()`；`secrets archive` 写 manifest 时有同一处坑，一并修复。**新增 List→JSON 的代码请照此写法。**
- **`出口证书可信（非 MITM）`显示 `HTTP 0 in 29486ms（证书有效）`**：假阳性。
  `curl` 连接/TLS 失败时 `%{http_code}` 是 `000`，也满足"3 位数字"判断，于是把 schannel 握手失败（exit 35）误判成证书有效。
  已改为「退出码为 0 且状态码 > 0」才算通过，并把失败原因（含 curl 退出码）写进 detail。现在同一情形会如实报失败。
- **`supervisor` 每分钟一条 `连续 N 轮失败（newApi）`**：误报。可选服务（new-api / Sub-Store）未部署也被计入失败。
  现在判据是"**二进制存在才算已部署**"：未部署则静默跳过、不计失败；已部署但没起来才计入并尝试拉起。
- **`nodes refresh` 后节点全没了 / mihomo 起不来**：曾出现"源里有 `proxies:` 但一个可用节点都没产出"时把空配置写进 `merged.yaml`。
  现已加保护：**生成的节点列表为空则保留旧 `merged.yaml`** 并在 `data\sub-state.json` 记 `mergedEmpty: true`。
- **配置里的中文变乱码（`语音ChatGPT-开机启动.lnk` 读成 `璇煶ChatGPT-...`）**：
  `config\netenv.json` 无 BOM，而 5.1 的 `Get-Content` 默认按 ANSI(GBK) 解码。
  已统一改用 `Read-NetEnvFileText`（显式 UTF-8，兼容有/无 BOM），启动项检查随之恢复有效。
- **所有命令都报 `不能对 Null 值表达式调用方法`**：`data\netenv.lock` 被写成了 0 字节（进程在写入前被杀）。
  现已容错（空/损坏锁文件自动回收），且锁改为原子写，不会再产生半截文件。
- **`install` 首次安装即失败（配置不存在）**：`robocopy` 排除了 `config`，安装后又去读 `%LOCALAPPDATA%\NetEnv\config\netenv.json`。
  现在首次安装会补种 `netenv.json`/`sources.json`/`clients.json`，重复安装不覆盖本机改动。
- **开机/定时任务没反应，桌面弹出 `Microsoft VBScript 编译器错误`（例：`行: 12 字符: 48 800A03F2 缺少标识符`）**：
  `lib\run-supervisor-hidden.vbs` 有语法或编码问题。`wscript.exe` 是 GUI 宿主，**错误只弹模态框，日志里没有任何痕迹**，
  所以表现为「自愈循环再也没起来」而不是报错。
  - 诊断：`cscript //nologo lib\run-supervisor-hidden.vbs` —— cscript 会把编译错误打到控制台（本次实测就靠它定位）。
  - 已踩过的坑：**VBScript 保留字不能当变量名**（`Like` 是运算符，`Dim ... like` 直接编译失败）；该文件必须保持**纯 ASCII**。
  - 兜底：`doctor` 有「零窗口启动器(VBS)」项检查存在性与 ASCII；`tests\netenv.tests.ps1` 用 cscript 做语法自检，
    并验证「能拉起目标」与「单实例守卫生效」。
- **`MethodNotFound: SHA256 不包含 HashData`**：`SHA256::HashData` / `Convert::ToHexString` / `MD5::HashData`
  都是 .NET 5+ API，Windows PowerShell 5.1 的 .NET Framework 下不存在。需改用
  `New-Object System.Security.Cryptography.SHA256Managed` + `ComputeHash` + 逐字节 `ToString('x2')`。
- **`secrets archive` / `adopt -Apply` 报 `Parameter Paring Error`**：说明走的是 Bandizip 的 `bz.exe`，
  而它**不兼容 7-Zip 参数语法**（`-t7z` / `-mhe=on` 均被拒）。已由 `Get-NetEnvArchiveArgs` 按工具分派：
  7-Zip 用 `a -t7z -p<pw> -mhe=on`；Bandizip 用 `a -fmt:7z -p:<pw>`（其 7z 加密头默认开启，实测无密码无法列出条目名）。
- **代理端口在听但打不开网页**：先跑 `netenv doctor`，看 `端到端出品（经代理实测）` 这一项。
  它走真实请求，能区分"进程活着"与"出口可用"；`data/health-state.json` 记录连续失败次数。
- **`doctor` 报 `自愈循环存活/单实例` 失败（0 个或 ≥2 个实例）**：
  - `0 个`：循环没起来。自启动没装（便携/无管理员）时属预期；否则用
    `wscript.exe lib\run-supervisor-hidden.vbs` 拉起，或 `install --autostart` 重装计划任务。
  - `≥2 个`：**重复循环**，最隐蔽的一类故障。计划任务以 `RunLevel=Highest` 启动循环，而非管理员
    会话读不到高完整性进程的 `Win32_Process.CommandLine`（返回空），`run-supervisor-hidden.vbs`
    的 LIKE 单实例守卫**看不见它**，于是每个周期任务都可能补拉一个新循环。实测 2026-09-24 起
    两个循环并存 5 天：它们交替写 `health-state.json`，把 github/GPT 的连败计数**反复清零**，
    专项探针的阈值永远攒不够，自愈静默失效（日志里毫无痕迹，因为两边都"正常"）。
    - 诊断：`doctor` 该项会列出实例 PID；也可看 `data\loop-heartbeat-<pid>.json` 的心跳时间。
    - 处置：`Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'powershell.exe' }` 逐个确认后
      保留一个、结束其余；新版本循环有命名互斥量守卫，重启后不会再并存。
- **ChatGPT 提示"地区不支持" / `unsupported_country_region_territory`，而其它网站一切正常**：
  出口节点落在 OpenAI **不支持地区**（免费池里大量香港/澳门节点）。这类故障的特点是**所有连通性判据都是绿的**：
  端口在听、google 204、github 200，连 `chatgpt.com` 的 TLS 握手都成功 —— 封锁发生在**应用层 403**。
  - 诊断：`netenv doctor` 看 `GPT 可达性（经代理）`；或直接
    `curl -s -A "Mozilla/5.0" -x http://127.0.0.1:7897 https://api.openai.com/v1/models`
    （**401 = 地区受支持、仅缺密钥**；403 + `unsupported_country_region_territory` = 地区封锁）。
  - 处置：`supervisor-loop` 的 GPT 专项探针会自动轮换 `gpt-node`（`data/gpt-state.json` 记录已验证节点，
    reload 后每轮自动重放）。手工立即轮换：`. .\lib\core.ps1; Invoke-NetEnvGptNodeRotation`（需
    `powershell -ExecutionPolicy Bypass`）。
  - ⚠️ **不要用"延迟最低"挑 GPT 节点**：mihomo 的 `/delay` 不判状态码，香港节点延迟最低却必然 403
    （实测一次组重测速就把出口从 SG 换成 HK，GPT 立刻从 401 变 403）。`gpt-node` 因此是 select + 轮换，不是 url-test。
  - ⚠️ **页面报「无法加载网站 / 请稍后再试。如果你用的是VPN，试着关闭它」**：这是 `chatgpt.com` 返回的
    **应用层拦截页**（HTML 外壳照常渲染、页脚带 `[IP: <出口> | 雷ID: <Cloudflare Ray ID>]`），
    与"节点连不上"是两回事 —— 连通性判据全绿也会长这样。先查那个 IP 是谁：
    `curl -s -x http://127.0.0.1:7897 https://chatgpt.com/cdn-cgi/trace` 给出当前出口的 `ip=` / `loc=`，
    再对照 OpenAI 支持地区。**页面上的 IP 只是"报错那一刻"的出口，不代表现在的出口** ——
    2026-10-06 实测页面显示 `212.192.15.177`（香港 AS26383、`proxy=true`），几分钟后 `loc` 已回到 FR，
    因为轮换窗口结束、线上组被还原了。
  - ⚠️ **现象若是"偶发、几秒后自己恢复"，先怀疑轮换本身，而不是节点抖动**：GPT 专项探针连败即触发
    `Invoke-NetEnvGptNodeRotation`，而**修复前**的实现是把**线上组** `gpt-node` 逐个候选切过去复测 ——
    复测窗口内用户真实流量全程跟着候选走。2026-10-06 16:53:07 探针连败 → 16:53:27 用户打开 `chatgpt.com`
    正好落在窗口里 → 香港候选返回地区拦截 → 16:53:32 轮换失败还原。现在复测走**独立探针入口**
    （`ports.mihomoProbe`，默认 `7898`；`rules` 首条 `IN-PORT,<port>,gpt-probe` → select 组 `gpt-probe`），
    线上组只在候选**真的通过地区判据**之后做一次原子切换。
    - 隔离自检：日志出现 `GPT 节点轮换：探针专用入口不可用（组 gpt-probe / 端口 0）→ 退回切线上组的旧路径`
      即说明隔离**未生效**（配置缺 `ports.mihomoProbe` / `health.gptProbe.probeGroup`，或 `merged.yaml` 改完没重载）。
    - 绑定自检（**必须用"出口 IP"判，不能用"某站点通不通"判**）：把两个组临时钉到不同节点，再看两个入口的出口是否不同 ——
      ```
      curl -s -X PUT http://127.0.0.1:19090/proxies/gpt-probe -d '{"name":"<池里另一个节点>"}' -H "Content-Type: application/json"
      curl -s -x http://127.0.0.1:7897 https://chatgpt.com/cdn-cgi/trace   # 线上组出口
      curl -s -x http://127.0.0.1:7898 https://chatgpt.com/cdn-cgi/trace   # 探针组出口
      ```
      两者 `ip=` **必须不同**（2026-10-06 实测：`gpt-node=trojan-1681917898/jp` 时 7897 回 `ip=45.32.52.173 colo=NRT loc=JP`，
      `gpt-probe` 换成中国节点后 7898 直接失败；还原后 7898 再回 JP）。相同就说明 `IN-PORT` 没生效，
      最常见原因是它没有排在 `rules` **最前面**；端口根本连不上（`curl: (7) Failed to connect`）则说明
      `listeners` 里没有该入口，也就是 `merged.yaml` 改完没重载。
      ⚠️ **别用 `https://www.baidu.com/` 当判据**：探针出口是境外节点，baidu 从境外照样能 200，
      于是"7898 该失败却回 200"的假警报会出现（本文件早期版本就写错过这条）。
  - **被判定 `region-unsupported` 的节点会进 `data/gpt-blocklist.json`**（TTL = `gptProbe.blocklistHours`，默认 12 小时），
    轮换挑候选时直接剔除：地区封锁是**节点属性**，不会自己恢复（实测一天内同一香港节点被重复复测 8 次）。
    某节点反复出现在轮换日志里时，先看它是否已在名单、名单是否已过期。
  - ⚠️ **`region-unsupported` 反复出现但名单始终是空的**：查 `Save-NetEnvGptBlocklist` 的参数名与局部变量名
    是否只差大小写（PowerShell 不区分大小写，后者会静默清掉前者）。2026-10-06 实测过两起同类静默事故，
    现由 `tests\netenv.tests.ps1` 的「源码静态检查：变量名大小写冲突」用例兜住。
  - ⚠️ **日志出现 `GPT 节点轮换失败：<节点>=unreachable, …` 而你还在等它自己恢复**：先分清是
    **地区问题**还是**池子枯死**。免费池是一批烂节点，整体死亡率极高（2026-10-06 18:00 实测
    `auto-urltest` 全部 **650** 个成员做一次组测速，8 秒只回来 **1 个**，649 个已死）。
    一条命令看清池子还剩多少：
    ```
    curl -s "http://127.0.0.1:19090/group/auto-urltest/delay?url=https://chatgpt.com/cdn-cgi/trace&timeout=8000"
    ```
    只回 1-2 个 key 就说明是**节点供给**问题，不是代码问题 —— 此时轮换再怎么挑也挑不出东西。
    - 别把 curl 的 403 当地区封锁：`https://chatgpt.com/` 对非浏览器客户端常返回 **403 + `Cf-Mitigated: challenge`**
      （body 里有 `Just a moment`），这是 Cloudflare 的常规人机挑战，**真浏览器能过**。
      判地区只看两个：`cdn-cgi/trace` 是否 200、`api.openai.com/v1/models` 是否 401。
    - 补池子：`.\netenv.ps1 nodes refresh`。它**只重写 `data/merged.yaml`，不 reload 也不 apply**，
      所以运行中是安全的；但**运行中的 mihomo 不会自己读新配置**，刷新完必须重载：
      `PUT http://127.0.0.1:19090/configs?force=true`，body `{"path":"<仓库>\\data\\merged.yaml"}`（成功回 204）。
      ⚠️ **重载会把 gpt-node / gpt-probe 的选择重置为组内第一个成员**（实测重置成了中国节点
      `🟢🇨🇳_github.com/Ruk1ng001_6607b0a2`，对 GPT 是地区封锁）—— 重载后**必须立刻再轮换一次**，
      否则等于亲手把线上出口换成一个 403 节点。
    - 订阅源本身可能是坏的：`data/sub-state.json` 的 `sourceStatus` 会写「下载失败: 基础连接已经关闭」
      /「The operation has timed out.」。注意 `data/*.json` 与 `merged.yaml` 都是**无 BOM 的 UTF-8**，
      用 PowerShell 5.1 `Get-Content` 直接看会是 GBK 乱码 —— 那是显示层现象，不代表文件坏了
      （`Read-NetEnvJson` 显式按 UTF-8 读）。
  - 浏览器侧还需系统代理开着：档位得是 `proxy`（`.\netenv.ps1 apply -profile proxy`），否则浏览器直连照样超时
    （一键脚本：`.\fix-browser-proxy.ps1`）。
- **浏览器（Edge/Chrome）打不开 GitHub，但同一时刻 `git` / CLI 正常**：这是**档位语义**，不是故障。
  `github` 档 `systemProxy=false`（只注入 git 代理与环境变量），而浏览器吃的是 WinINET 系统代理，
  于是它**直连**被墙目标直到超时（Edge 报 `ERR_CONNECTION_TIMED_OUT`）。
  一键切档并验收：`powershell -NoProfile -ExecutionPolicy Bypass -File .\fix-browser-proxy.ps1`
  （默认切 `proxy` 档；用完 `-Profile github` 切回 CLI 档，`-NoProbe` 可离线只做落盘验收）。
  - **不要手改注册表**：`supervisor-loop` 每轮按档位期望值回写系统代理（见 README「系统代理漂移自愈」），
    手改会被改回去；该脚本走官方 `netenv.ps1 apply`，保留快照与 git/npm/环境变量的同档语义。
  - 浏览器需**完全退出重开**：WinINET 设置对已运行进程不一定即时生效。
  - 验收仍失败时按上面「装了第三方 VPN」一节处置（`doctor` 的 `VPN 类接管` 看多默认路由）。
- **装了第三方 VPN（Proton VPN / WireGuard / 其他代理客户端）后，某天开机代理全废**：
  与 mihomo **不是端口冲突，而是抢夺同一层网络状态**。三条已验证的互斥通道：
  1. **系统代理**：VPN 客户端连接/断开时接管 WinINET 的 `ProxyEnable/ProxyServer`，谁最后写谁赢。
     症状是吃系统代理与 `HTTP_PROXY` 的程序全部退回直连，而 mihomo 端口照样 LISTEN。
     现在 `supervisor-loop` 每轮比对实际值与配置期望值并自动重写（5 分钟退避），
     `doctor` 的 `系统代理(WinINET)` 会给出实际值与期望值的差异。
  2. **Kill Switch / 泄漏保护的 WFP 拦截**：VPN 会拦掉"非隧道"流量，包括去往 `127.0.0.1:7897`
     的连接与 mihomo 的出站。此时端口仍 LISTEN 但出品探针全红；退出 VPN 请走客户端自己的
     退出（勿 `Stop-Process` 强杀 —— 带 WFP callout 的进程被强杀可能留下未回收的过滤规则，
     表现为整机断网）。
  3. **TUN 默认路由劫持（"绿着坏"）**：VPN 装上 TUN 网卡并加 `0.0.0.0/0` 路由后，经
     `127.0.0.1:7897` 的探针**仍然能通**，于是 `doctor` 报绿、`health-state.json` 一路 `lastOk`，
     而流量根本没走 mihomo 规则 —— `sensitiveDomains` 直连清单与 github 自适应分流静默失效。
     端口与探针都发现不了，因此另有独立检测项：`VPN 类接管`（看是否有已连接的 VPN 类适配器、
     是否存在多条默认路由）与 `VPN 类自启项`（看 Run 键/启动文件夹里的 VPN 客户端，这类自启
     会在登录后自动连接并接管）。**判据是"多默认路由"而不是"有 VPN 适配器"** —— 多出口确实
     能分流，单出口接管才是问题。
  - 处置**顺序**：① 退出 VPN 客户端并由其恢复网络设置 → ② `netenv doctor` 复核
    `系统代理(WinINET)` 与 `端到端出品` → ③ 若必须两者并存，**不要让两者抢同一层**：
    首选把 VPN 的 WireGuard 配置导入 mihomo 做上游（系统代理只由 mihomo 持有），
    次选让 VPN 走 TUN 并把 NetEnv 切到 `apply -profile direct`，二选一而非并存。
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
