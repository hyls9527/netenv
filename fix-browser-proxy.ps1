# 一键修复：浏览器打不开 GitHub / 被墙站点（Edge 报 ERR_CONNECTION_TIMED_OUT）
#
# 为什么需要它（这不是故障，是档位语义）：
#   `github` 档是给 git / CLI 用的 —— systemProxy=false，只注入 git 代理与环境变量。
#   浏览器吃的是 WinINET 系统代理，于是它**直连** github.com，被墙即超时。
#   需要浏览器的场景必须切到 `proxy` 档（systemProxy=true）。
#
# 为什么不能手改注册表了事：
#   `supervisor-loop` 每轮按当前档位的期望值回写系统代理（见 README「系统代理漂移自愈」），
#   手改会被它改回去；必须走官方入口 `netenv.ps1 apply`，它同时管 git / npm / 环境变量并留快照。
#
# 与仓库其它脚本同约定：
#   - 端口从 config\netenv.json 端口表派生（不写死具体端口）；
#   - 路径从 $PSScriptRoot / $MyInvocation 推导，不写死用户名或盘符；
#   - 兼容 Windows PowerShell 5.1（无 ?? / 三元 / ::new() / -Parallel）；
#   - 本文件必须带 UTF-8 BOM：-File 调用走 powershell.exe 5.1，无 BOM 时中文按 GBK 解码会破坏引号配对
#     （回归用例「所有 .ps1 必须带 UTF-8 BOM」与 doctor「脚本 UTF-8 BOM」两处守门）。
#
# 用法（普通用户即可，无需管理员）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\fix-browser-proxy.ps1
#   ... -Profile github     # 用完切回 CLI 档（浏览器随之退回直连，属预期）
#   ... -Profile direct     # 彻底不走代理
#   ... -NoProbe            # 只做落盘验收，不触网
#   ... -ProbeUrl https://github.com/robots.txt
#
# 退出码：0 = 全部验收通过；1 = 有验收项未达标（输出里会指明是哪一项）。

param(
  [ValidateSet('direct','proxy','github')][string]$Profile = 'proxy',
  [string]$ProbeUrl,
  [switch]$NoProbe
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'lib\core.ps1')

$failures = New-Object System.Collections.Generic.List[string]
$cfg = Read-NetEnvConfig
$proxyUrl = Get-NetEnvProxyUrl $cfg
$proxyHostPort = $proxyUrl -replace '^https?://', ''
$port = [int]$cfg.ports.mihomoHttp
$profCfg = $cfg.profiles.$Profile
$expectSystemProxy = [int][bool]$profCfg.systemProxy
# 期望串与 apply.ps1 / Get-NetEnvSystemProxyState 用同一个公式，避免两处判据漂移
$expectedServer = if ($expectSystemProxy -eq 1) { "http=$proxyHostPort;https=$proxyHostPort" } else { '' }

Write-Host '=== NetEnv 浏览器代理修复 ===' -ForegroundColor Cyan
Write-Host ("仓库: {0}" -f $root)
Write-Host ("目标档位: {0}（systemProxy={1}，代理入口 {2}）" -f $Profile, [bool]$profCfg.systemProxy, $proxyUrl)

# ---- 1) mihomo 入口端口必须在听：不在听时，apply 出来的系统代理同样连不上 ----
$listen = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
if ($listen) {
  Write-Host ("[OK] {0} 在听（PID {1}）" -f $proxyHostPort, @($listen)[0].OwningProcess) -ForegroundColor Green
} else {
  Write-Host ("[WARN] {0} 未监听：apply 后由 supervisor / 自愈循环拉起；若一直没起来，先跑 .\netenv.ps1 doctor" -f $proxyHostPort) -ForegroundColor Yellow
  $failures.Add("端口 $port 未监听")
}

# ---- 2) 走官方入口切档；已达标则跳过（每跑一次 apply 就多一个快照，没必要堆积）----
$state = Get-NetEnvSystemProxyState $cfg
$already = ($state.Intent -eq $Profile) -and (-not $state.Drifted)
if ($already) {
  Write-Host ("[OK] 已是 {0} 档且系统代理无漂移，跳过 apply" -f $Profile) -ForegroundColor Green
} else {
  $psName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
  $psExe = Join-Path $PSHOME $psName
  if (-not (Test-Path -LiteralPath $psExe)) { $psExe = (Get-Process -Id $PID).Path }
  Write-Host (">>> netenv.ps1 apply -profile {0}（当前推断档位: {1}）" -f $Profile, $state.Intent) -ForegroundColor Cyan
  & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'netenv.ps1') apply -profile $Profile | Out-Host
  $applyExit = $LASTEXITCODE
  if ($null -ne $applyExit -and $applyExit -ne 0) {
    Write-Host ("[WARN] apply 退出码={0}，继续做落盘验收" -f $applyExit) -ForegroundColor Yellow
  }
}

# ---- 3) 落盘验收：直接读 WinINET 实际值（不用 Get-NetEnvActiveProfile 的推断，避免循环论证）----
$reg = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
$actualEnable = [int][bool]$reg.ProxyEnable
$actualServer = [string]$reg.ProxyServer
Write-Host ("ProxyEnable = {0}（期望 {1}）" -f $actualEnable, $expectSystemProxy)
Write-Host ("ProxyServer = '{0}'（期望 '{1}'）" -f $actualServer, $expectedServer)
if ($actualEnable -ne $expectSystemProxy) {
  Write-Host '[FAIL] 系统代理开关与档位不符' -ForegroundColor Red
  $failures.Add('WinINET ProxyEnable 与档位不符')
} elseif ($expectSystemProxy -eq 1 -and $actualServer -ne $expectedServer) {
  Write-Host '[FAIL] ProxyServer 未指向本机代理入口' -ForegroundColor Red
  $failures.Add('WinINET ProxyServer 与端口表派生值不符')
} else {
  Write-Host '[PASS] WinINET 系统代理与档位一致' -ForegroundColor Green
}

# ---- 4) 经代理实测：判据同 doctor「端到端出品」—— 端口在听 != 能上网 ----
if ($NoProbe) {
  Write-Host '[SKIP] 已指定 -NoProbe，跳过经代理实测' -ForegroundColor Yellow
} else {
  if (-not $ProbeUrl) {
    # 默认探 github：本脚本就是为"浏览器打不开 github"而生的，且该 URL 来自配置而非写死
    if ($cfg.health.githubProbe -and @($cfg.health.githubProbe.probeUrls).Count -gt 0) {
      $ProbeUrl = @($cfg.health.githubProbe.probeUrls)[0]
    } elseif (@($cfg.health.probeUrls).Count -gt 0) {
      $ProbeUrl = @($cfg.health.probeUrls)[0]
    } else {
      $ProbeUrl = 'https://github.com/robots.txt'
    }
  }
  $r = Test-NetEnvEgress -ProbeUrl $ProbeUrl -ProxyPort $port -TimeoutSec 15
  if ($r.Ok) {
    Write-Host ("[PASS] 经代理可达 {0}：HTTP {1} {2}ms" -f $r.Url, $r.Status, $r.Ms) -ForegroundColor Green
  } else {
    Write-Host ("[FAIL] 经代理不可达 {0}：{1}" -f $ProbeUrl, $r.Error) -ForegroundColor Red
    $failures.Add("经代理探针失败（$ProbeUrl）")
  }
}

Write-Host ''
if ($failures.Count -eq 0) {
  Write-Host '验收通过。请**完全退出并重开**浏览器（WinINET 设置对已运行进程不一定即时生效）再访问。' -ForegroundColor Green
  exit 0
}
Write-Host ("验收未通过（{0} 项）：{1}" -f $failures.Count, ($failures.ToArray() -join '；')) -ForegroundColor Yellow
Write-Host '下一步：.\netenv.ps1 doctor —— 重点看「端到端出品」「系统代理(WinINET)」「VPN 类接管」；排障见 docs\TROUBLESHOOTING.md' -ForegroundColor Yellow
exit 1
