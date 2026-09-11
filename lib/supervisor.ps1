[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\core.ps1"

function Start-NetEnvProcess {
  param([string]$Exe, [string[]]$ArgList, [string]$Cwd)
  $full = Join-Path (Get-NetEnvPaths).Bin $Exe
  if (-not (Test-Path -LiteralPath $full)) { return $false }
  $quoted = foreach ($a in $ArgList) { if ($a -match '\s') { '"' + $a + '"' } else { $a } }
  if ($Cwd) {
    Start-Process -FilePath $full -ArgumentList $quoted -WindowStyle Hidden -WorkingDirectory $Cwd | Out-Null
  } else {
    Start-Process -FilePath $full -ArgumentList $quoted -WindowStyle Hidden | Out-Null
  }
  return $true
}

$cfg = Read-NetEnvConfig
$paths = Get-NetEnvPaths
$mergedFile = Join-Path $paths.Data 'merged.yaml'
$stateFile = Join-Path $paths.Data 'supervisor-state.json'
$state = @{ failingRounds = 0 }
if (Test-Path -LiteralPath $stateFile) {
  # 状态文件损坏时（掉电/半截写入）不能让整轮自愈崩掉
  try {
    $loaded = (Read-NetEnvFileText $stateFile) | ConvertFrom-Json
    if ($null -ne $loaded.failingRounds) { $state.failingRounds = [int]$loaded.failingRounds }
  } catch { Write-NetEnvLog 'WARN' 'supervisor: 状态文件不可解析，已重置' }
}

# 判定规则：**已部署**（二进制存在）的服务才计入失败统计。
# 原实现把 optionalServices 一律排除出重启范围，却又把 newApi 写进失败清单，
# 结果 newApi 没部署时每轮都 ERROR（实测连续 224 轮），真故障被噪声淹没。
$restarts = 0
$optional = @($cfg.optionalServices)
$missing = (New-Object System.Collections.Generic.List[string])
foreach ($item in @(
  @{ n = 'mihomo'; p = $cfg.ports.mihomoMixed; exe = 'mihomo-windows-amd64.exe' },
  @{ n = 'subStore'; p = $cfg.ports.subStore; exe = 'sub-store.exe' },
  @{ n = 'newApi'; p = $cfg.ports.newApi; exe = 'new-api.exe' }
)) {
  if (Get-PortOwner $item.p) { continue }
  $deployed = Test-Path -LiteralPath (Join-Path $paths.Bin $item.exe)
  if (-not $deployed) {
    # 未部署的可选服务按设计跳过（静默，避免每分钟刷日志）；必需的 mihomo 缺失要报
    if ($optional -notcontains $item.n) {
      Write-NetEnvLog 'WARN' "supervisor: $($item.n) 二进制缺失（$($item.exe)），请运行 netenv bootstrap"
      [void]$missing.Add($item.n)
    }
    continue
  }
  if ($item.n -eq 'mihomo' -and -not (Test-Path -LiteralPath $mergedFile)) {
    Write-NetEnvLog 'WARN' 'supervisor: merged.yaml 不存在，请先运行 nodes refresh'
    [void]$missing.Add($item.n)
    continue
  }
  # 先判预算再动手：原实现先启动进程才比较 maxRestartPerRound，预算形同虚设
  if ($restarts -ge $cfg.supervisor.maxRestartPerRound) {
    Write-NetEnvLog 'WARN' "supervisor: 本轮重启次数达上限($($cfg.supervisor.maxRestartPerRound))，跳过 $($item.n)"
    [void]$missing.Add($item.n)
    continue
  }
  if ($item.n -eq 'newApi') {
    $started = Start-NetEnvProcess $item.exe @('--port', "$($item.p)", '--log-dir', $paths.Logs) -Cwd (Join-Path (Get-NetEnvRoot) 'lib')
  } else {
    $started = Start-NetEnvProcess $item.exe @('-d', $paths.Data, '-f', $mergedFile)
  }
  if ($started) {
    Write-NetEnvLog 'INFO' "supervisor: 拉起 $($item.n) (端口 $($item.p))"
    $restarts++
  } else {
    [void]$missing.Add($item.n)
  }
}

if ($restarts -gt 0 -or $missing.Count -eq 0) { $state.failingRounds = 0 } else { $state.failingRounds = [int]$state.failingRounds + 1 }
# 原子写：半截 JSON 会让下一轮的失败计数与 doctor 读取一起失效
Save-NetEnvTextFile -Path $stateFile -Content ($state | ConvertTo-Json)
if ($state.failingRounds -ge $cfg.supervisor.maxFailingRounds) {
  Write-NetEnvLog 'ERROR' "supervisor: 连续 $($state.failingRounds) 轮失败（$($missing -join ',')），请运行 netenv doctor"
}
