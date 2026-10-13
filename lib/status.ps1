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
    try { $sub = (Read-NetEnvFileText $subState) | ConvertFrom-Json } catch { Write-NetEnvLog 'WARN' "status: sub-state.json 不可解析" }
  }

  # 【订阅新鲜度必须取 lastSuccessAt，不能取 updatedAt】两者语义不同：
  # updatedAt = 最近一次刷新**尝试**（源全挂的那次照样把它顶成现在），
  # lastSuccessAt = 上次**真正重写 merged.yaml** 的时间（本次没写成则跨轮继承）。
  # 2026-10-14 实测：节点池已冻结 106 小时、三个订阅源全挂，doctor 报 [!!] 106.6 小时，
  # 而 status 报 subscriptionHoursAgo=0.2 —— 同一个状态文件、两条判据、一个红一个绿。
  # doctor 的 subfresh 检查早就为此加过防回归用例（tests\netenv.tests.ps1 "订阅新鲜度必须取
  # lastSuccessAt"），status 当时漏改，于是排障入口里最常用的那个仍在"全绿着坏"。
  # 取不到 lastSuccessAt（2026-10-09 之前的旧状态文件）时按 merged.yaml 落盘时间计，
  # 与 doctor 的分支保持同一套降级顺序；最后才退回 updatedAt，并在注释里说明这是兜底。
  $subStamp = $null
  if ($sub) {
    if ($sub.lastSuccessAt) {
      try { $subStamp = [datetime]$sub.lastSuccessAt } catch { $subStamp = $null }
    }
    if (-not $subStamp) {
      $mergedFile = Join-Path $paths.Data 'merged.yaml'
      if (Test-Path -LiteralPath $mergedFile) { try { $subStamp = (Get-Item -LiteralPath $mergedFile).LastWriteTime } catch { $subStamp = $null } }
    }
    if (-not $subStamp) {
      try { $subStamp = [datetime]$sub.updatedAt } catch { $subStamp = $null }
    }
  }

  # 出品健康：由 supervisor-loop 的端到端探针写入（端口在听 ≠ 能上网）
  $health = $null
  $healthFile = Join-Path $paths.Data 'health-state.json'
  if (Test-Path -LiteralPath $healthFile) {
    try { $health = (Read-NetEnvFileText $healthFile) | ConvertFrom-Json } catch { }
  }
  # 探针数据过期（supervisor-loop 已死/未启动）时不能继续报"健康"：旧的成功记录会掩盖真故障
  $egressOk = $null
  $egressFresh = $false
  if ($health -and $health.probedAt) {
    $maxAgeMin = 30
    if ($cfg.health -and $cfg.health.probeIntervalMinutes) { $maxAgeMin = [int]$cfg.health.probeIntervalMinutes * 3 }
    if ($maxAgeMin -lt 15) { $maxAgeMin = 15 }
    try {
      if (((Get-Date) - [datetime]$health.probedAt).TotalMinutes -le $maxAgeMin) {
        $egressFresh = $true
        $egressOk = ([int]$health.consecutiveFail -eq 0)
      }
    } catch { }
  }

  # 档位推断统一走 Get-NetEnvActiveProfile：doctor 的 envvars 判据共用同一口径，
  # 两处各写一份必然漂移（此前只认 ProxyEnable，github 档被误报成 direct）。
  $ie = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
  $profile = Get-NetEnvActiveProfile

  $status = [ordered]@{
    initialized = Test-Path -LiteralPath (Join-Path $paths.Data 'initialized')
    profile = $profile
    mihomo = [bool]$mihomo
    newApi = [bool]$newApi
    subStore = [bool]$subStore
    systemProxyEnabled = [bool]$ie.ProxyEnable
    subscriptionUpdatedAt = if ($sub) { $sub.updatedAt } else { $null }
    subscriptionLastSuccessAt = if ($sub) { $sub.lastSuccessAt } else { $null }
    subscriptionHoursAgo = if ($subStamp) { [math]::Round(((Get-Date) - $subStamp).TotalHours, 1) } else { $null }
    nodeCount = if ($sub) { $sub.nodeCount } else { 0 }
    egressOk = $egressOk
    egressFresh = $egressFresh
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
