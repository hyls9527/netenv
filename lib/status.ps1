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

  # 出品健康：由 supervisor-loop 的端到端探针写入（端口在听 ≠ 能上网）
  $health = $null
  $healthFile = Join-Path $paths.Data 'health-state.json'
  if (Test-Path -LiteralPath $healthFile) {
    try { $health = Get-Content -LiteralPath $healthFile -Raw | ConvertFrom-Json } catch { }
  }

  $ie = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
  # profile 需从三处实际状态推断：系统代理 / git 代理 / 用户环境变量。
  # 此前只认 ProxyEnable，导致 github 档（只注入 git 代理）被误报成 direct。
  $gitProxy = (git config --global --get http.proxy 2>$null)
  $envProxy = [Environment]::GetEnvironmentVariable('HTTP_PROXY', 'User')
  $profile = 'direct'
  if ($ie.ProxyEnable) { $profile = 'proxy' }
  elseif ($gitProxy -or $envProxy) { $profile = 'github' }

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
    egressOk = if ($health) { ([int]$health.consecutiveFail -eq 0) } else { $null }
    egressCheckedAt = if ($health) { $health.probedAt } else { $null }
    egressLastOk = if ($health) { $health.lastOk } else { $null }
    egressLastMs = if ($health) { $health.lastOkMs } else { $null }
    configValid = $true
    backups = (Get-ChildItem -LiteralPath $paths.Backups -Filter 'config-*' -ErrorAction SilentlyContinue | Measure-Object).Count
  }
  try { $null = Read-NetEnvConfig } catch { $status.configValid = $false }

  if ($Json) { return [PSCustomObject]$status | ConvertTo-Json -Depth 4 }

  foreach ($k in $status.Keys) { "{0}: {1}" -f $k, $status[$k] }
}
