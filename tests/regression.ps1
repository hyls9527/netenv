param([switch]$Live)
$ErrorActionPreference = 'Stop'

# 不写死 pwsh：本机可能只有 Windows PowerShell 5.1（实测 pwsh 装在 Program Files 但不在 PATH，
# 原脚本直接调 pwsh 会 "not recognized"）。用当前宿主自己的可执行文件。
$psName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
$psExe = Join-Path $PSHOME $psName
if (-not (Test-Path -LiteralPath $psExe)) { $psExe = (Get-Process -Id $PID).Path }

if ($Live) {
  $root = Split-Path -Parent $PSScriptRoot
  $netenv = Join-Path $root 'netenv.ps1'
  $mihomo = Join-Path $root 'data\bin\mihomo-windows-amd64.exe'
  $dataDir = Join-Path $root 'data'
  $reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
  $proc = $null

  # 冒烟端口一律从端口表派生（不写死 7897）；读不到就中止，而不是猜一个。
  $livePort = 0
  try {
    $cfgJson = (Get-Content -LiteralPath (Join-Path $root 'config\netenv.json') -Raw -Encoding UTF8) | ConvertFrom-Json
    $livePort = [int]$cfgJson.ports.mihomoHttp
  } catch { $livePort = 0 }
  if ($livePort -le 0) {
    Write-Host '[live] 中止：无法从 config/netenv.json 读到 ports.mihomoHttp'
    exit 2
  }

  # 前置守卫（2026-10-09 实测补上）：本机生产 mihomo 常驻监听该端口时，这里另起的临时实例
  # 必然绑定失败并立刻退出，而紧接着的"端口在听吗"读到的正是**生产进程** —— 旧实现于是打印
  # listening=True（PID 指向已死进程）继续往下跑，还可能在 finally 里对真实环境的档位执行
  # apply --undo。即：在正常运行的机器上跑 -Live，结论完全不可信。
  $occupied = Get-NetTCPConnection -State Listen -LocalPort $livePort -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($occupied) {
    Write-Host ("[live] 中止：端口 {0} 已被 PID {1} 占用 —— -Live 需要独占该端口才能判定真实结果。" -f $livePort, $occupied.OwningProcess)
    Write-Host '[live] 用法：先停掉生产 mihomo 再跑；或改 config/netenv.json 的 ports.mihomoHttp 到一个空闲端口'
    exit 2
  }

  try {
    if (-not (Test-Path -LiteralPath $mihomo)) { throw 'mihomo binary missing' }
    $cfg = Join-Path $dataDir 'test-mihomo.yaml'
    if (-not (Test-Path -LiteralPath $cfg)) {
      Set-Content -LiteralPath $cfg -Value ("port: {0}`nmode: rule`nlog-level: silent`nipv6: false`nrules:`n  - MATCH,DIRECT" -f $livePort) -Encoding utf8
    }
    $proc = Start-Process -FilePath $mihomo -ArgumentList @('-d', ('"' + $dataDir + '"'), '-f', ('"' + $cfg + '"')) -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 3
    # 启动即退出必须先报出来：否则"端口在听"可能来自别的进程，探测结论全是假的
    if ($proc.HasExited) { throw ("mihomo 启动即退出（exit $($proc.ExitCode)）：配置或端口不可用") }
    $listening = [bool](Get-NetTCPConnection -State Listen -LocalPort $livePort -ErrorAction SilentlyContinue)
    Write-Host ("[live] mihomo {0} listening={1} pid={2}" -f $livePort, $listening, $proc.Id)
    if (-not $listening) { throw 'mihomo not listening' }
    & $psExe -NoProfile -ExecutionPolicy Bypass -File $netenv apply -profile proxy | Out-Host
    $ie = Get-ItemProperty -Path $reg
    Write-Host ("[live] proxy={0} git={1}" -f $ie.ProxyServer, (git config --global --get http.proxy))
    $r = Invoke-WebRequest -Uri 'http://www.baidu.com' -UseBasicParsing -TimeoutSec 15
    Write-Host ("[live] baidu HTTP {0} OK" -f $r.StatusCode)
  } finally {
    if ($proc -and -not $proc.HasExited) {
      & $psExe -NoProfile -ExecutionPolicy Bypass -File $netenv apply --undo | Out-Host
      Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
      Start-Sleep -Seconds 1
    }
  }
  Write-Host '[live] smoke passed'
  exit 0
}

Import-Module Pester

# 前置编码守卫：无 BOM 的 .ps1 在 Windows PowerShell 5.1 下会被按 GBK 解码，中文注释直接
# 破坏引号配对 —— 表现是整个测试文件 "Missing closing '}'" 之类的假语法错（2026-10-06 实测
# 自伤过一次：AI 编辑工具剥掉 4 个 lib\*.ps1 的 BOM，生产自愈循环连续 7 分钟报解析错误）。
# 放在 Pester 之前跑：先给出"哪个文件缺 BOM"的可执行结论，而不是让人去猜语法。
& $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'ensure-bom.ps1') -Check
if ($LASTEXITCODE -ne 0) {
  Write-Host 'regression: 中止 —— 存在缺少 UTF-8 BOM 的 .ps1。修法：.\tests\ensure-bom.ps1'
  exit 1
}

$testPath = Join-Path $PSScriptRoot 'netenv.tests.ps1'
# 日志沙箱在用例文件内部（dot-source core.ps1 之后立即生效）—— 这里再做会在
# dot-source 时被 core.ps1 的 $script:NetEnvRoot 重新覆盖掉，实测无效。
$allOk = $true
foreach ($round in 1..3) {
  $r = Invoke-Pester -Path $testPath -PassThru
  Write-Host ("round {0}: Passed={1} Failed={2}" -f $round, $r.PassedCount, $r.FailedCount)
  if ($r.FailedCount -gt 0) { $allOk = $false }
}
if (-not $allOk) { exit 1 }
Write-Host 'regression: all rounds passed'
