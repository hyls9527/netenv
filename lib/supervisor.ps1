[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\core.ps1"

function Start-NetEnvProcess {
  param([string]$Exe, [string[]]$Args)
  $full = Join-Path (Get-NetEnvPaths).Bin $Exe
  if (-not (Test-Path -LiteralPath $full)) { return $false }
  Start-Process -FilePath $full -ArgumentList $Args -WindowStyle Hidden | Out-Null
  return $true
}

$cfg = Read-NetEnvConfig
$paths = Get-NetEnvPaths
$stateFile = Join-Path $paths.Data 'supervisor-state.json'
$state = @{ failingRounds = 0 }
if (Test-Path -LiteralPath $stateFile) { $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json }

$restarts = 0
foreach ($item in @(@{ n = 'subStore'; p = $cfg.ports.subStore; exe = 'sub-store.exe' }, @{ n = 'newApi'; p = $cfg.ports.newApi; exe = 'new-api.exe' })) {
  $owner = Get-PortOwner $item.p
  if (-not $owner) {
    if ($item.exe -like 'new-api*') {
      if ((Start-NetEnvProcess $item.exe @('--port', "$($item.p)", '--log-dir', $paths.Logs)) -and $restarts -lt $cfg.supervisor.maxRestartPerRound) { $restarts++ }
    } else {
      if ($restarts -lt $cfg.supervisor.maxRestartPerRound) { Write-NetEnvLog 'WARN' "supervisor: $($item.n) 未运行（Sub-Store 需 Node，参见文档）" }
    }
  }
}

if ($restarts -gt 0) { $state.failingRounds = 0 } else {
  $missing = ((@('subStore','newApi') | ForEach-Object { if (-not (Get-PortOwner $cfg.ports.$_)) { $_ } }) -join ',')
  if ($missing) { $state.failingRounds++ } else { $state.failingRounds = 0 }
}
$state | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding utf8
if ($state.failingRounds -ge $cfg.supervisor.maxFailingRounds) {
  Write-NetEnvLog 'ERROR' "supervisor: 连续 $($state.failingRounds) 轮失败（$missing），请运行 netenv doctor"
}
