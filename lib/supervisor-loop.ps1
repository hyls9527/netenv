[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\core.ps1"
# nodes.ps1 定义 Invoke-NetEnvNodesRefresh —— 一级降级要调它，必须显式加载。
# 曾漏掉这一行：探针失败时抛"无法将 Invoke-NetEnvNodesRefresh 项识别为 cmdlet"，
# 自愈链第一级从未真正生效（logs/20260917.log 实测连续 20 轮）。回归测试有静态守卫。
. "$PSScriptRoot\nodes.ps1"

# 出品探针判据见 core.ps1 的 Test-NetEnvEgressAny：多目标 OR —— 任一目标可达即视为出品可用。
# doctor 与自愈循环共用同一函数，避免"doctor 说不可用、循环说可用"两套口径。
# 单目标（旧实现只认 health.probeUrl）会把"这一个目标被墙/节点不通"直接判成整机出品不可用：
# 实测 google 长期不可达而 github 正常，于是每轮都空刷一次节点。

# 刷新只重写 data/merged.yaml；运行中的 mihomo 不会自动重载（supervisor.ps1 仅在端口
# 没在听时才拉起进程）。重载助手 Update-NetEnvMihomoConfig 定义在 core.ps1，便于被测试覆盖。

# 周期自愈循环：快速轮询进程存活（intervalMinutes），并按 probeIntervalMinutes
# 做端到端出品探针。端口在听不等于能上网，所以健康判据必须落在真实请求上。
$cfg = Read-NetEnvConfig
$paths = Get-NetEnvPaths
$interval = [int]$cfg.supervisor.intervalMinutes
if ($interval -lt 1) { $interval = 1 }
$probeInterval = 15
$failThreshold = 2
$probeUrls = @('https://www.google.com/generate_204')
$autoRefresh = $true
$autoDirect = $false
$refreshMinInterval = 30
if ($cfg.health) {
  if ($cfg.health.probeIntervalMinutes) { $probeInterval = [int]$cfg.health.probeIntervalMinutes }
  if ($cfg.health.failThreshold) { $failThreshold = [int]$cfg.health.failThreshold }
  # probeUrls 优先；缺省退回单个 probeUrl；老配置零改动仍可用
  if ($cfg.health.probeUrls) { $probeUrls = @($cfg.health.probeUrls) }
  elseif ($cfg.health.probeUrl) { $probeUrls = @($cfg.health.probeUrl) }
  if ($null -ne $cfg.health.autoRefreshOnFail) { $autoRefresh = [bool]$cfg.health.autoRefreshOnFail }
  if ($null -ne $cfg.health.autoFallbackToDirect) { $autoDirect = [bool]$cfg.health.autoFallbackToDirect }
  if ($cfg.health.autoRefreshMinIntervalMinutes) { $refreshMinInterval = [int]$cfg.health.autoRefreshMinIntervalMinutes }
}
if ($probeInterval -lt 1) { $probeInterval = 15 }
if ($failThreshold -lt 1) { $failThreshold = 2 }
if ($refreshMinInterval -lt 0) { $refreshMinInterval = 0 }
$controllerPort = 19090
if ($cfg.ports -and $cfg.ports.mihomoController) { $controllerPort = [int]$cfg.ports.mihomoController }
$mergedFile = Join-Path $paths.Data 'merged.yaml'
Write-NetEnvLog 'INFO' "supervisor-loop: 启动，进程探活 $interval 分钟 / 出品探针 $probeInterval 分钟 / 目标 $($probeUrls -join ' | ')"

$healthFile = Join-Path $paths.Data 'health-state.json'
$lastProbe = (Get-Date).AddMinutes(-$probeInterval - 1)

while ($true) {
  try { & "$PSScriptRoot\supervisor.ps1" } catch { Write-NetEnvLog 'ERROR' "supervisor-loop: 单轮异常 $_" }

  if (((Get-Date) - $lastProbe).TotalMinutes -ge $probeInterval) {
    $lastProbe = Get-Date
    $st = @{ consecutiveFail = 0; lastOk = $null; lastOkMs = $null; lastError = $null; probedAt = $null; lastRefreshAt = $null }
    if (Test-Path -LiteralPath $healthFile) {
      try {
        $loaded = (Read-NetEnvFileText $healthFile) | ConvertFrom-Json
        # 归一化进哈希表：ConvertFrom-Json 给出的是 PSCustomObject，在其上"新增"属性会抛
        # "在此对象上找不到属性 ..."（PS 5.1 实测），于是 lastRefreshAt 永远写不进去、退避失效。
        # 哈希表可自由增删键，且键永远齐全（缺字段时保留默认值）。
        foreach ($k in @($st.Keys)) {
          if ($null -ne $loaded.$k) { $st[$k] = $loaded.$k }
        }
      } catch { Write-NetEnvLog 'WARN' 'supervisor-loop: health-state.json 不可解析，已重置' }
    }
    $r = Test-NetEnvEgressAny -Urls $probeUrls
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
          # 最小刷新间隔：否则探针目标长期不可达时每轮都去锤订阅源（实测每 5 分钟一次，
          # 20 轮下来订阅源被反复下载）。记账落在 health-state.json，进程重启也不丢。
          $lastRefresh = $null
          if ($st.lastRefreshAt) {
            try { $lastRefresh = [datetime]$st.lastRefreshAt } catch { $lastRefresh = $null }
          }
          if ($lastRefresh -and ((Get-Date) - $lastRefresh).TotalMinutes -lt $refreshMinInterval) {
            $agoMin = [int]((Get-Date) - $lastRefresh).TotalMinutes
            Write-NetEnvLog 'WARN' "出品不可用，但距上次自动刷新仅 $agoMin 分钟（下限 $refreshMinInterval 分钟），本轮跳过"
          } else {
            Write-NetEnvLog 'WARN' '出品不可用 → 触发 nodes refresh'
            # 先记账再动手：刷新自身抛错时同样要退避，否则每轮都重试
            $st.lastRefreshAt = (Get-Date -Format 's')
            try {
              $null = Invoke-NetEnvNodesRefresh
              # 必须重载：刷新只改文件，运行中的 mihomo 不会自己读新配置
              if (Update-NetEnvMihomoConfig -ControllerPort $controllerPort -ConfigPath $mergedFile) {
                Write-NetEnvLog 'INFO' 'nodes refresh 完成，已重载 mihomo 配置'
              }
              Start-Sleep -Seconds 12
              $r2 = Test-NetEnvEgressAny -Urls $probeUrls
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
    try { Save-NetEnvTextFile -Path $healthFile -Content ($st | ConvertTo-Json -Depth 3) } catch { }
  }

  Start-Sleep -Seconds ($interval * 60)
}
