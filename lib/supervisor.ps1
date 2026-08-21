[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\core.ps1"

function Start-NetEnvProcess {
  param([string]$Exe, [string[]]$ArgList)
  $full = Join-Path (Get-NetEnvPaths).Bin $Exe
  if (-not (Test-Path -LiteralPath $full)) { return $false }
  $quoted = foreach ($a in $ArgList) { if ($a -match '\s') { '"' + $a + '"' } else { $a } }
  Start-Process -FilePath $full -ArgumentList $quoted -WindowStyle Hidden | Out-Null
  return $true
}

$cfg = Read-NetEnvConfig
$paths = Get-NetEnvPaths
$mergedFile = Join-Path $paths.Data 'merged.yaml'
$stateFile = Join-Path $paths.Data 'supervisor-state.json'
$state = @{ failingRounds = 0 }
if (Test-Path -LiteralPath $stateFile) { $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json }

$restarts = 0
foreach ($item in @(
  @{ n = 'mihomo'; p = $cfg.ports.mihomoMixed; exe = 'mihomo-windows-amd64.exe' },
  @{ n = 'subStore'; p = $cfg.ports.subStore; exe = 'sub-store.exe' },
  @{ n = 'newApi'; p = $cfg.ports.newApi; exe = 'new-api.exe' }
)) {
  $owner = Get-PortOwner $item.p
  if (-not $owner) {
    if ($item.n -eq 'mihomo') {
      if (-not (Test-Path -LiteralPath $mergedFile)) {
        Write-NetEnvLog 'WARN' 'supervisor: merged.yaml 不存在，请先运行 nodes refresh'
      } elseif ((Start-NetEnvProcess $item.exe @('-d', $paths.Data, '-f', $mergedFile)) -and $restarts -lt $cfg.supervisor.maxRestartPerRound) {
        $restarts++
      }
    } elseif ($item.n -eq 'newApi') {
      if ((Start-NetEnvProcess $item.exe @('--port', "$($item.p)", '--log-dir', $paths.Logs)) -and $restarts -lt $cfg.supervisor.maxRestartPerRound) { $restarts++ }
    } else {
      if ($restarts -lt $cfg.supervisor.maxRestartPerRound) { Write-NetEnvLog 'WARN' "supervisor: $($item.n) 未运行（Sub-Store 需 Node，参见文档）" }
    }
  }
}

if ($restarts -gt 0) { $state.failingRounds = 0 } else {
  $missing = ((@('mihomo','subStore','newApi') | ForEach-Object { if (-not (Get-PortOwner $cfg.ports.$_)) { $_ } }) -join ',')
  if ($missing) { $state.failingRounds++ } else { $state.failingRounds = 0 }
}
$state | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding utf8
if ($state.failingRounds -ge $cfg.supervisor.maxFailingRounds) {
  Write-NetEnvLog 'ERROR' "supervisor: 连续 $($state.failingRounds) 轮失败（$missing），请运行 netenv doctor"
}
