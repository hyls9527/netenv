[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\core.ps1"

# 周期自愈循环：快速轮询进程存活（intervalMinutes），并按 probeIntervalMinutes
# 做端到端出品探针。端口在听不等于能上网，所以健康判据必须落在真实请求上。
$cfg = Read-NetEnvConfig
$interval = [int]$cfg.supervisor.intervalMinutes
if ($interval -lt 1) { $interval = 1 }
$probeInterval = 15
$failThreshold = 2
$probeUrl = 'https://www.google.com/generate_204'
$autoRefresh = $true
$autoDirect = $false
if ($cfg.health) {
  if ($cfg.health.probeIntervalMinutes) { $probeInterval = [int]$cfg.health.probeIntervalMinutes }
  if ($cfg.health.failThreshold) { $failThreshold = [int]$cfg.health.failThreshold }
  if ($cfg.health.probeUrl) { $probeUrl = $cfg.health.probeUrl }
  if ($null -ne $cfg.health.autoRefreshOnFail) { $autoRefresh = [bool]$cfg.health.autoRefreshOnFail }
  if ($null -ne $cfg.health.autoFallbackToDirect) { $autoDirect = [bool]$cfg.health.autoFallbackToDirect }
}
if ($probeInterval -lt 1) { $probeInterval = 15 }
if ($failThreshold -lt 1) { $failThreshold = 2 }
Write-NetEnvLog 'INFO' "supervisor-loop: 启动，进程探活 $interval 分钟 / 出品探针 $probeInterval 分钟"

$healthFile = Join-Path (Get-NetEnvPaths).Data 'health-state.json'
$lastProbe = (Get-Date).AddMinutes(-$probeInterval - 1)

while ($true) {
  try { & "$PSScriptRoot\supervisor.ps1" } catch { Write-NetEnvLog 'ERROR' "supervisor-loop: 单轮异常 $_" }

  if (((Get-Date) - $lastProbe).TotalMinutes -ge $probeInterval) {
    $lastProbe = Get-Date
    $st = @{ consecutiveFail = 0; lastOk = $null; lastOkMs = $null; lastError = $null; probedAt = $null }
    if (Test-Path -LiteralPath $healthFile) {
      try { $st = Get-Content -LiteralPath $healthFile -Raw | ConvertFrom-Json } catch { }
    }
    $r = Test-NetEnvEgress -ProbeUrl $probeUrl
    $st.probedAt = (Get-Date -Format 's')
    if ($r.Ok) {
      if ([int]$st.consecutiveFail -ne 0) { Write-NetEnvLog 'INFO' "出品探针恢复：HTTP $($r.Status) $($r.Ms)ms" }
      $st.consecutiveFail = 0
      $st.lastOk = (Get-Date -Format 's')
      $st.lastOkMs = $r.Ms
      $st.lastError = $null
    } else {
      $st.consecutiveFail = [int]$st.consecutiveFail + 1
      $st.lastError = ConvertTo-Redacted $r.Error
      Write-NetEnvLog 'WARN' "出品探针失败（第 $($st.consecutiveFail)/$failThreshold 次）：$($st.lastError)"

      if ([int]$st.consecutiveFail -ge $failThreshold) {
        # 一级降级：刷新免费节点（付费源不动）。nodes refresh 自带"失败保留旧配置"保护。
        if ($autoRefresh) {
          Write-NetEnvLog 'WARN' '出品不可用 → 触发 nodes refresh'
          try {
            $null = Invoke-NetEnvNodesRefresh
            Start-Sleep -Seconds 12
            $r2 = Test-NetEnvEgress -ProbeUrl $probeUrl
            if ($r2.Ok) {
              Write-NetEnvLog 'INFO' "刷新后出品恢复：HTTP $($r2.Status) $($r2.Ms)ms"
              $st.consecutiveFail = 0
              $st.lastOk = (Get-Date -Format 's')
              $st.lastOkMs = $r2.Ms
              $st.lastError = $null
            } else {
              Write-NetEnvLog 'ERROR' "刷新后仍不可用：$($r2.Error)"
            }
          } catch { Write-NetEnvLog 'ERROR' "nodes refresh 异常：$_" }
        }

        # 二级降级：回退直连（默认关闭，需 config 显式开启 autoFallbackToDirect）
        if ([int]$st.consecutiveFail -ge $failThreshold -and $autoDirect) {
          try {
            Write-NetEnvLog 'WARN' '仍不可用 → 回退 apply -profile direct'
            & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path (Get-NetEnvRoot) 'netenv.ps1') apply -profile direct | Out-Null
            $st.lastError = ("$($st.lastError) | 已回退 direct")
          } catch { Write-NetEnvLog 'ERROR' "回退 direct 失败：$_" }
        }
      }
    }
    try { $st | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $healthFile -Encoding utf8 } catch { }
  }

  Start-Sleep -Seconds ($interval * 60)
}
