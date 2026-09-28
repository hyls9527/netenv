[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\core.ps1"
# nodes.ps1 定义 Invoke-NetEnvNodesRefresh —— 一级降级要调它，必须显式加载。
# 曾漏掉这一行：探针失败时抛"无法将 Invoke-NetEnvNodesRefresh 项识别为 cmdlet"，
# 自愈链第一级从未真正生效（logs/20260917.log 实测连续 20 轮）。回归测试有静态守卫。
. "$PSScriptRoot\nodes.ps1"

# ---- 单实例守卫（命名互斥量）----
# 为什么不能只靠 lib\run-supervisor-hidden.vbs 的 CommandLine 匹配：计划任务以 RunLevel=Highest
# 启动循环，而非管理员会话读不到**高完整性进程**的 CommandLine（实测 Win32_Process.CommandLine
# 返回空），VBS 的 LIKE 匹配因此看不见它 —— 于是两个循环并存。实测 2026-09-24 启动的实例一直
# 跑到 2026-09-29 才被发现：两边交替写 health-state.json，把 github/GPT 的连败计数反复清零，
# 专项探针阈值形同虚设（这类故障日志里没有任何痕迹，比崩溃更难发现）。
# 互斥量与命令行可见性无关，是唯一可靠的判据；进程退出时由操作系统自动释放。
$mutexCreated = $false
$loopMutex = $null
try {
  $loopMutex = New-Object System.Threading.Mutex($false, 'Local\NetEnv.SupervisorLoop', [ref]$mutexCreated)
} catch {
  # 创建失败不能拒绝启动：那会让自愈链整体静默失效（比重复循环更糟），只记 WARN 继续
  Write-NetEnvLog 'WARN' "supervisor-loop: 单实例互斥量创建失败，继续启动（$($_.Exception.Message)）"
}
if ($loopMutex -and -not $mutexCreated) {
  Write-NetEnvLog 'INFO' 'supervisor-loop: 已有实例在运行，本实例退出（单实例守卫）'
  exit 0
}

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

# github 专项探针的配置。判据独立于出品 OR（理由见下方探针块注释），恢复动作也独立。
$githubProbeOn = $false
$githubProbeUrls = @('https://github.com/robots.txt')
$githubFailThreshold = 2
$githubGroup = 'github-adaptive'
$githubRecoverMinInterval = 10
if ($cfg.health -and $cfg.health.githubProbe) {
  $gp = $cfg.health.githubProbe
  if ($null -ne $gp.enabled) { $githubProbeOn = [bool]$gp.enabled }
  # 过滤空串：探针 URL 为空会让 Test-NetEnvEgress 回退到 health.probeUrl（google），那就探错了对象
  if ($gp.probeUrls) { $githubProbeUrls = @($gp.probeUrls | Where-Object { $_ }) }
  if (@($githubProbeUrls).Count -eq 0) { $githubProbeUrls = @('https://github.com/robots.txt') }
  if ($gp.failThreshold) { $githubFailThreshold = [int]$gp.failThreshold }
  if ($gp.group) { $githubGroup = [string]$gp.group }
  if ($null -ne $gp.recoverMinIntervalMinutes) { $githubRecoverMinInterval = [int]$gp.recoverMinIntervalMinutes }
}
if ($githubFailThreshold -lt 1) { $githubFailThreshold = 2 }
if ($githubRecoverMinInterval -lt 0) { $githubRecoverMinInterval = 0 }

# GPT（OpenAI/ChatGPT）专项探针的配置。判据独立，且比 github 多一层"地区"判别 —— 见
# core.ps1 的 ConvertTo-NetEnvGptProbeResult：免费节点里大量是香港，而香港是 OpenAI
# **不支持地区**，只看连通性会把它们判成健康，症状是"能连上 chatgpt.com 却报地区不支持"。
$gptProbeOn = $false
$gptProbeUrls = @('https://api.openai.com/v1/models')
$gptFailThreshold = 2
$gptAdaptiveGroup = 'gpt-adaptive'
$gptRotateGroup = 'gpt-node'
$gptRankGroup = 'auto-urltest'
$gptMaxCandidates = 8
$gptRecoverMinInterval = 10
$gptLatencyUrl = 'https://chatgpt.com/cdn-cgi/trace'
if ($cfg.health -and $cfg.health.gptProbe) {
  $tp = $cfg.health.gptProbe
  if ($null -ne $tp.enabled) { $gptProbeOn = [bool]$tp.enabled }
  # 过滤空串：探针 URL 为空会让 Test-NetEnvGptEgress 回退到默认值，那就探错了对象
  if ($tp.probeUrls) { $gptProbeUrls = @($tp.probeUrls | Where-Object { $_ }) }
  if (@($gptProbeUrls).Count -eq 0) { $gptProbeUrls = @('https://api.openai.com/v1/models') }
  if ($tp.failThreshold) { $gptFailThreshold = [int]$tp.failThreshold }
  if ($tp.group) { $gptAdaptiveGroup = [string]$tp.group }
  if ($tp.rotateGroup) { $gptRotateGroup = [string]$tp.rotateGroup }
  if ($tp.rankGroup) { $gptRankGroup = [string]$tp.rankGroup }
  if ($tp.maxCandidates) { $gptMaxCandidates = [int]$tp.maxCandidates }
  if ($null -ne $tp.recoverMinIntervalMinutes) { $gptRecoverMinInterval = [int]$tp.recoverMinIntervalMinutes }
}
if ($cfg.subscription -and $cfg.subscription.gptUrlTest -and $cfg.subscription.gptUrlTest.url) { $gptLatencyUrl = [string]$cfg.subscription.gptUrlTest.url }
if ($gptFailThreshold -lt 1) { $gptFailThreshold = 2 }
if ($gptRecoverMinInterval -lt 0) { $gptRecoverMinInterval = 0 }
if ($gptMaxCandidates -lt 1) { $gptMaxCandidates = 8 }

$controllerPort = 19090
if ($cfg.ports -and $cfg.ports.mihomoController) { $controllerPort = [int]$cfg.ports.mihomoController }
$mergedFile = Join-Path $paths.Data 'merged.yaml'

# 系统代理漂移自愈参数。为什么放在自愈循环里：进程探活与出品探针都发现不了这件事 ——
# 第三方 VPN / 代理客户端接管 WinINET 后，mihomo 端口照样 LISTEN、探针经隧道也照样通，
# 而吃系统代理与 HTTP_PROXY 的程序已经全部退回直连（银行/邮箱等直连清单与 github 分流失效）。
# 这是典型的"全绿着坏"，只能在状态层直接比对并修复。
$proxyRepairMinInterval = 5
$lastProxyRepair = (Get-Date).AddMinutes(-$proxyRepairMinInterval - 1)

Write-NetEnvLog 'INFO' "supervisor-loop: 启动，进程探活 $interval 分钟 / 出品探针 $probeInterval 分钟 / 目标 $($probeUrls -join ' | ')"
if ($githubProbeOn) { Write-NetEnvLog 'INFO' "supervisor-loop: github 专项探针 启用 / 目标 $($githubProbeUrls -join ' | ') / 连败 $githubFailThreshold 次触发 $githubGroup 组测速" }
if ($gptProbeOn) { Write-NetEnvLog 'INFO' "supervisor-loop: GPT 专项探针 启用 / 目标 $($gptProbeUrls -join ' | ') / 连败 $gptFailThreshold 次触发 $gptRotateGroup 节点轮换（地区判据）" }

$healthFile = Join-Path $paths.Data 'health-state.json'
# 心跳文件：每实例一个（按 PID），供 doctor 发现"循环没起来"与"重复循环"。
# 互斥量负责预防，心跳负责发现 —— 跨完整性下万一互斥量失效，也不至于再瞎 5 天才发现。
$heartbeatFile = Join-Path $paths.Data ("loop-heartbeat-$PID.json")
$loopStartedAt = (Get-Date -Format 's')
$lastProbe = (Get-Date).AddMinutes(-$probeInterval - 1)

# 探针状态的**常驻**哈希表（在 while 之外初始化，不随每轮重建）。
# 键必须齐全：加载只遍历本表的键，漏掉的键读不到已存值、每轮都被重置。
# 为什么必须常驻而不是每轮重建（两条都是实测）：
#   ① 与当年 lastRefreshAt 退避失效同一类坑 —— 键漏了就被打回默认值；
#   ② 存在"另一个循环实例交替写 health-state.json"的情形（高完整性实例躲过 CommandLine 守卫，
#      2026-09-24～29 实测）—— 对方写出的文件里没有新键，每轮重建会把 github/GPT 连败计数
#      打回 0，专项探针阈值永远攒不够。常驻内存后，文件里**缺失**的键不再覆盖内存值。
$st = @{ consecutiveFail = 0; lastOk = $null; lastOkMs = $null; lastError = $null; probedAt = $null; lastRefreshAt = $null; githubConsecutiveFail = 0; githubLastOk = $null; githubLastError = $null; githubProbedAt = $null; githubLastRecoverAt = $null; gptConsecutiveFail = 0; gptLastOk = $null; gptLastError = $null; gptProbedAt = $null; gptLastRecoverAt = $null }

while ($true) {
  # 心跳 + 清理陈旧心跳（3 倍轮询周期）。必须在 supervisor.ps1 之前写：
  # 心跳过期即代表"循环已死"，doctor 据此判定，陈旧文件由活着的实例负责回收。
  try {
    Save-NetEnvTextFile -Path $heartbeatFile -Content ([ordered]@{ pid = $PID; at = (Get-Date -Format 's'); startedAt = $loopStartedAt } | ConvertTo-Json)
    $hbCutoff = (Get-Date).AddMinutes(-1 * ([Math]::Max(5, $interval * 3)))
    Get-ChildItem -LiteralPath $paths.Data -Filter 'loop-heartbeat-*.json' -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -lt $hbCutoff } |
      Remove-Item -Force -ErrorAction SilentlyContinue
  } catch { }

  try { & "$PSScriptRoot\supervisor.ps1" } catch { Write-NetEnvLog 'ERROR' "supervisor-loop: 单轮异常 $_" }

  # ---- GPT 已验证节点的重放（每轮都查，独立于 5 分钟的探针周期）----
  # 必要性：mihomo 重载配置（nodes refresh / apply）后，select 组会重置回首个成员；
  # 不重放的话 GPT 会静默走回"未验证、甚至 OpenAI 不支持地区"的节点，而探针要 5 分钟后才发现。
  if ($gptProbeOn) {
    try {
      $wantNode = Get-NetEnvGptSelectedNode
      if ($wantNode) {
        $curNode = $null
        try {
          # 必须用 UTF-8 读取：节点名含 emoji，Invoke-WebRequest 会按 ISO-8859-1 解码成乱码，
          # 于是"当前节点 != 已验证节点"永远成立、每轮白做一次 PUT（见 core.ps1 的同名注释）
          $pj = Get-NetEnvJsonUtf8 -Uri "http://127.0.0.1:$controllerPort/proxies/$gptRotateGroup" -TimeoutSec 8
          $curNode = [string]$pj.now
        } catch { $curNode = $null }
        if ($curNode -and $curNode -ne $wantNode) {
          if (Set-NetEnvGptSelectedNode -Node $wantNode -ControllerPort $controllerPort) {
            Write-NetEnvLog 'INFO' "GPT 已验证节点重放：$curNode → $wantNode（配置重载后 select 组会回到默认成员）"
          }
        }
      }
    } catch { Write-NetEnvLog 'WARN' "GPT 节点重放异常：$_" }
  }

  # ---- 系统代理漂移自愈（每轮都查，与出品探针的 5 分钟周期无关）----
  # 只在"当前档位期望开启系统代理"时才动手：direct/github 档下 ProxyEnable=0 是预期状态，
  # 修它等于跟人工切档打架。Get-NetEnvSystemProxyState 内部已按档位算出 Drifted。
  try {
    $sps = Get-NetEnvSystemProxyState -Cfg $cfg
    if ($sps.Drifted) {
      if (((Get-Date) - $lastProxyRepair).TotalMinutes -ge $proxyRepairMinInterval) {
        Write-NetEnvLog 'WARN' ("系统代理被改写（实际 ProxyEnable=$($sps.Enabled) / ProxyServer='$($sps.Server)'；" +
          "期望 '$($sps.ExpectedServer)'）→ 疑似 VPN/其他代理客户端接管，已按当前档位重写")
        Set-NetEnvProxyReg 1 $sps.ExpectedServer $sps.ExpectedOverride
        $lastProxyRepair = Get-Date
      } else {
        # 退避不是故障：对方每轮都改的情况下，没有这个下限就会每 1 分钟重写并刷一条 WARN，
        # 把真故障淹掉（与 lastRefreshAt / githubLastRecoverAt 同一口径）。
        Write-NetEnvLog 'INFO' "系统代理仍被改写，距上次修复不足 $proxyRepairMinInterval 分钟，本轮跳过"
      }
    }
  } catch { Write-NetEnvLog 'WARN' "系统代理漂移检查异常：$_" }

  if (((Get-Date) - $lastProbe).TotalMinutes -ge $probeInterval) {
    $lastProbe = Get-Date
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
        # 计数在降级动作结束后归零（含退避跳过与 autoRefresh 关闭两种情况），否则它顺着
        # health-state.json 一直爬，产出"出品探针失败（第 17/2 次）"这种自相矛盾日志
        # （实测 logs/20260915.log 全天如此，把真故障淹了）。退避职责归 lastRefreshAt，
        # 与 github 专项链在恢复动作后置 0 的口径一致。
        if ($autoRefresh) {
          # 最小刷新间隔：否则探针目标长期不可达时每轮都去锤订阅源（实测每 5 分钟一次，
          # 20 轮下来订阅源被反复下载）。记账落在 health-state.json，进程重启也不丢。
          $lastRefresh = $null
          if ($st.lastRefreshAt) {
            try { $lastRefresh = [datetime]$st.lastRefreshAt } catch { $lastRefresh = $null }
          }
          if ($lastRefresh -and ((Get-Date) - $lastRefresh).TotalMinutes -lt $refreshMinInterval) {
            $agoMin = [int]((Get-Date) - $lastRefresh).TotalMinutes
            # 退避跳过不是故障、更不是待办动作（刷新已记在案并会自动重试），刻意用 INFO 且不记 WARN：
            # 若记 WARN，一旦订阅源长期不可达就会每 5 分钟刷一条"本轮跳过"，把真故障淹掉
            # （当年 consecutiveFail 一路爬升的刷屏就是这么来的）。
            Write-NetEnvLog 'INFO' "出品不可用，但距上次自动刷新仅 $agoMin 分钟（下限 $refreshMinInterval 分钟），本轮跳过"
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

        # 计数归零必须放在两条降级链的**最后**：二级降级的判据与一级同源（consecutiveFail），
        # 提前归零会让 autoFallbackToDirect=true 的回退永不触发。
        $st.consecutiveFail = 0
      }
    }
    # ---- github 专项探针：判据独立，不并入上面的出品 OR ----
    # 为什么必须独立：上面的出品判据是"probeUrls 里任一可达即算可用"，google 通时
    # github 单独挂掉不会触发任何自愈 —— 实测 2026-09-17 github.com 经代理握手失败，
    # 而 health-state.json 一路 lastOk、无人恢复。而 git push/clone 全依赖 github，
    # 静默不可用的代价远高于多发一次组测速。
    if ($githubProbeOn) {
      $gr = Test-NetEnvEgressAny -Urls $githubProbeUrls
      $st.githubProbedAt = (Get-Date -Format 's')
      if ($gr.Ok) {
        if ([int]$st.githubConsecutiveFail -ne 0) { Write-NetEnvLog 'INFO' "github 探针恢复：HTTP $($gr.Status) $($gr.Ms)ms" }
        $st.githubConsecutiveFail = 0
        $st.githubLastOk = (Get-Date -Format 's')
        $st.githubLastError = $null
      } else {
        $st.githubConsecutiveFail = [int]$st.githubConsecutiveFail + 1
        $st.githubLastError = ConvertTo-Redacted $gr.Error
        Write-NetEnvLog 'WARN' "github 探针失败（第 $($st.githubConsecutiveFail)/$githubFailThreshold 次）：$($st.githubLastError)"

        if ([int]$st.githubConsecutiveFail -ge $githubFailThreshold) {
          # 恢复动作刻意不同于出品降级链：github 挂多半是 URLTest 组状态陈旧（组内节点其实
          # 健康 —— 同一次测速实测 github-node 595ms / proxy-select 686ms），所以先触发该组
          # 重新测速择通。刷订阅只重写 merged.yaml、代价大且不对症，留给上面的出品链。
          $lastGithubRecover = $null
          if ($st.githubLastRecoverAt) {
            try { $lastGithubRecover = [datetime]$st.githubLastRecoverAt } catch { $lastGithubRecover = $null }
          }
          if ($lastGithubRecover -and ((Get-Date) - $lastGithubRecover).TotalMinutes -lt $githubRecoverMinInterval) {
            $gAgoMin = [int]((Get-Date) - $lastGithubRecover).TotalMinutes
            Write-NetEnvLog 'WARN' "github 不可用，但距上次专项恢复仅 $gAgoMin 分钟（下限 $githubRecoverMinInterval 分钟），本轮跳过"
          } else {
            Write-NetEnvLog 'WARN' "github 不可用 → 触发 $githubGroup 组重新测速"
            # 先记账再动手（同出品链口径）：测速自身抛错时同样要退避，否则每轮都重试
            $st.githubLastRecoverAt = (Get-Date -Format 's')
            $rec = Invoke-NetEnvGithubGroupRecovery -Group $githubGroup -TestUrl $githubProbeUrls[0] -ControllerPort $controllerPort
            if ($rec.Ok) {
              Write-NetEnvLog 'INFO' "组测速完成（$($rec.Detail)），复测中"
              Start-Sleep -Seconds 3
              $gr2 = Test-NetEnvEgressAny -Urls $githubProbeUrls
              if ($gr2.Ok) {
                Write-NetEnvLog 'INFO' "github 已恢复：HTTP $($gr2.Status) $($gr2.Ms)ms"
                $st.githubConsecutiveFail = 0
                $st.githubLastOk = (Get-Date -Format 's')
                $st.githubLastError = $null
              } else {
                Write-NetEnvLog 'ERROR' "组测速后 github 仍不可用：$($gr2.Error)"
              }
            } else {
              Write-NetEnvLog 'ERROR' "github 组测速未取到任何可用成员（$($rec.Detail)）"
            }
          }
        }
      }
    }

    # ---- GPT 专项探针：判据独立于出品 OR，且比 github 多一层"地区"判别 ----
    # 为什么独立：出品 OR 里 google 通即算可用，而 google 通不代表 OpenAI 可达 ——
    # 免费节点大量是香港（OpenAI 不支持地区），chatgpt.com 会应用层 403 而所有连通性探针全绿。
    # 恢复动作也不是刷订阅：同批节点里本来就有地区受支持的，对症做法是换节点（逐个用地区判据复测）。
    if ($gptProbeOn) {
      $tr = Test-NetEnvGptEgress -ProbeUrl $gptProbeUrls[0]
      $st.gptProbedAt = (Get-Date -Format 's')
      if ($tr.Ok) {
        if ([int]$st.gptConsecutiveFail -ne 0) { Write-NetEnvLog 'INFO' "GPT 探针恢复：HTTP $($tr.Status) $($tr.Ms)ms" }
        $st.gptConsecutiveFail = 0
        $st.gptLastOk = (Get-Date -Format 's')
        $st.gptLastError = $null
      } else {
        $st.gptConsecutiveFail = [int]$st.gptConsecutiveFail + 1
        $st.gptLastError = [string]$tr.Reason
        Write-NetEnvLog 'WARN' "GPT 探针失败（第 $($st.gptConsecutiveFail)/$gptFailThreshold 次）：$($tr.Reason)（HTTP $($tr.Status)）"

        if ([int]$st.gptConsecutiveFail -ge $gptFailThreshold) {
          $lastGptRecover = $null
          if ($st.gptLastRecoverAt) {
            try { $lastGptRecover = [datetime]$st.gptLastRecoverAt } catch { $lastGptRecover = $null }
          }
          if ($lastGptRecover -and ((Get-Date) - $lastGptRecover).TotalMinutes -lt $gptRecoverMinInterval) {
            $tAgoMin = [int]((Get-Date) - $lastGptRecover).TotalMinutes
            Write-NetEnvLog 'WARN' "GPT 不可用，但距上次节点轮换仅 $tAgoMin 分钟（下限 $gptRecoverMinInterval 分钟），本轮跳过"
          } else {
            Write-NetEnvLog 'WARN' "GPT 不可用 → 轮换 $gptRotateGroup 节点（按地区判据逐个复测）"
            # 先记账再动手（与出品/github 链同口径）：轮换自身抛错时同样要退避
            $st.gptLastRecoverAt = (Get-Date -Format 's')
            $rot = Invoke-NetEnvGptNodeRotation -Group $gptRotateGroup -AdaptiveGroup $gptAdaptiveGroup -ProbeUrl $gptProbeUrls[0] -LatencyUrl $gptLatencyUrl -RankGroup $gptRankGroup -ControllerPort $controllerPort -MaxCandidates $gptMaxCandidates
            if ($rot.Ok) {
              Write-NetEnvLog 'INFO' "GPT 节点已轮换：$($rot.Node)（$($rot.Detail)），复测中"
              Start-Sleep -Seconds 3
              $tr2 = Test-NetEnvGptEgress -ProbeUrl $gptProbeUrls[0]
              if ($tr2.Ok) {
                Write-NetEnvLog 'INFO' "GPT 已恢复：HTTP $($tr2.Status) $($tr2.Ms)ms（节点 $($rot.Node)）"
                $st.gptConsecutiveFail = 0
                $st.gptLastOk = (Get-Date -Format 's')
                $st.gptLastError = $null
              } else {
                Write-NetEnvLog 'ERROR' "轮换到 $($rot.Node) 后 GPT 仍不可用：$($tr2.Reason)"
              }
            } else {
              Write-NetEnvLog 'ERROR' "GPT 节点轮换失败：$($rot.Detail)"
            }
          }
        }
      }
    }

    try { Save-NetEnvTextFile -Path $healthFile -Content ($st | ConvertTo-Json -Depth 3) } catch { }
  }

  Start-Sleep -Seconds ($interval * 60)
}
