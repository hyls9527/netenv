. "$PSScriptRoot\core.ps1"

function Get-NetEnvStatus {
  param([switch]$Json)
  $cfg = Read-NetEnvConfig
  $paths = Get-NetEnvPaths

  $mihomo = Get-PortOwner $cfg.ports.mihomoMixed
  $newApi = Get-PortOwner $cfg.ports.newApi
  $subStore = Get-PortOwner $cfg.ports.subStore

  $sub = $null
  $subState = Join-Path $paths.Data 'sub-state.json'
  if (Test-Path -LiteralPath $subState) {
    $sub = Get-Content -LiteralPath $subState -Raw | ConvertFrom-Json
  }

  $ie = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
  $profile = 'direct'
  if ($ie.ProxyEnable) { $profile = 'proxy' }

  $status = [ordered]@{
    initialized = Test-Path -LiteralPath (Join-Path $paths.Data 'initialized')
    profile = $profile
    mihomo = [bool]$mihomo
    newApi = [bool]$newApi
    subStore = [bool]$subStore
    systemProxyEnabled = [bool]$ie.ProxyEnable
    subscriptionUpdatedAt = if ($sub) { $sub.updatedAt } else { $null }
    subscriptionHoursAgo = if ($sub) { [math]::Round(((Get-Date) - [datetime]$sub.updatedAt).TotalHours, 1) } else { $null }
    nodeCount = if ($sub) { $sub.nodeCount } else { 0 }
    configValid = $true
    backups = (Get-ChildItem -LiteralPath $paths.Backups -Filter 'config-*' -ErrorAction SilentlyContinue | Measure-Object).Count
  }
  try { $null = Read-NetEnvConfig } catch { $status.configValid = $false }

  if ($Json) { return [PSCustomObject]$status | ConvertTo-Json -Depth 4 }

  foreach ($k in $status.Keys) { "{0}: {1}" -f $k, $status[$k] }
}
