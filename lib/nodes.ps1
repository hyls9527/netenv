. "$PSScriptRoot\core.ps1"

function Ensure-NetEnvGeodata {
  # mihomo 启动时会自行去墙外下载缺失的 geodata，失败即整个配置加载失败。
  # 规则同时用到 GEOSITE(需 GeoSite.dat) 与 GEOIP(需 geoip.metadb)，两者都要预置在 -d 数据根目录。
  $paths = Get-NetEnvPaths
  $mirrors = @('https://gh-proxy.com/', 'https://ghfast.top/')
  $targets = @(
    @{ name = 'geoip.metadb'; rel = 'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb' },
    @{ name = 'GeoSite.dat';  rel = 'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat' }
  )
  $allOk = $true
  foreach ($t in $targets) {
    $dest = Join-Path $paths.Data $t.name
    if ((Test-Path -LiteralPath $dest) -and (Get-Item -LiteralPath $dest).Length -gt 1000000) { continue }
    $got = $false
    foreach ($m in $mirrors) {
      try {
        & curl.exe -sS -L -C - --fail --connect-timeout 15 --max-time 300 -o $dest ($m + $t.rel)
        if ((Test-Path -LiteralPath $dest) -and (Get-Item -LiteralPath $dest).Length -gt 1000000) {
          Write-NetEnvLog 'INFO' "$($t.name) 下载完成"
          $got = $true
          break
        }
      } catch { }
    }
    if (-not $got) {
      Write-NetEnvLog 'WARN' "$($t.name) 下载失败（GEOSITE/GEOIP 规则将不可用，国内流量可能被误判走代理）"
      $allOk = $false
    }
  }
  return $allOk
}

function Invoke-NetEnvNodesRefresh {
  $cfg = Read-NetEnvConfig
  $paths = Get-NetEnvPaths
  $null = Ensure-NetEnvGeodata
  $subDir = Join-Path $paths.Data 'subs'
  if (-not (Test-Path -LiteralPath $subDir)) { New-Item -ItemType Directory -Path $subDir -Force | Out-Null }

  $sourceStatus = @{}
  $anyOk = $false
  $activeIds = New-Object System.Collections.ArrayList
  foreach ($src in (Read-NetEnvJson -Name 'sources')) {
    if ($src.disabled) {
      $sourceStatus[$src.id] = '已停用'
      continue
    }
    $url = Get-NetEnvCredentialValue -TargetName "NetEnv/sub-$($src.id)"
    if (-not $url) {
      $sourceStatus[$src.id] = "未配置(用 netenv config set-secret NetEnv/sub-$($src.id))"
      continue
    }
    if ($url -notmatch '^https://') {
      $sourceStatus[$src.id] = '拒绝: 仅允许 HTTPS 订阅'
      continue
    }
    [void]$activeIds.Add($src.id)
    # 临时文件含订阅原文（凭据），用 finally 确保异常路径也不残留
    $tmpSub = Join-Path $paths.Data ("dl-" + $src.id + ".sub")
    # 【为什么要重试】2026-10-14 实测本机链路上 TLS 干扰是**间歇性**的：同一批 URL 连续两轮，
    # 第一轮 freesub/free-vpn-subs 抛 "基础连接已经关闭"、第二轮全部成功；单次失败率约 2/6。
    # 而 nodes refresh 一轮只要**任一源**产出节点就算成功，单源没有试错余地时会整轮空跑
    # （自愈循环随后每 5 分钟重试一次，日志里刷的全是"下载失败"，节点池却一直冻着）。
    # 三次尝试把单源失败率从 ~33% 压到 ~4% 以下，代价只有失败路径上的 2 秒退避。
    $text = $null
    $lastErr = $null
    for ($dlAttempt = 1; $dlAttempt -le 3; $dlAttempt++) {
      try {
        Invoke-WebRequest -Uri $url -OutFile $tmpSub -UseBasicParsing -TimeoutSec 30
        $text = [System.IO.File]::ReadAllText($tmpSub, [System.Text.Encoding]::UTF8)
        break
      } catch {
        $lastErr = $_
        if ($dlAttempt -lt 3) { Start-Sleep -Seconds 2 }
      } finally {
        if (Test-Path -LiteralPath $tmpSub) { Remove-Item -LiteralPath $tmpSub -Force -ErrorAction SilentlyContinue }
      }
    }
    # 【直连兜底】2026-10-18 实测：经系统代理（mihomo 规则把 raw.githubusercontent.com 交给
    # github-adaptive 组的 DIRECT 成员）下载订阅时，连续三次都是 "基础连接已经关闭: 发送时发生错误"；
    # 而同一进程里**绕过系统代理直连**同一 URL 立刻 200 并取回完整正文（655200 / 277776 字节）。
    # 后果是两个主力源全部判失败、只剩 wjkc（4 节点）成功，节点池冻结 47 小时 ——
    # 与 README 里"节点池冻结 106 小时"同一类"全绿着坏"：刷新看起来跑过，节点却一个没换。
    # 因此经代理 3 次全败后再补一次直连（.NET DefaultWebProxy 置空）：订阅 URL 只落到订阅服务器
    # 自己，不经任何第三方出口，安全性不降级；用完立即还原代理设置。
    if (-not $text) {
      $savedProxy = [System.Net.WebRequest]::DefaultWebProxy
      try {
        [System.Net.WebRequest]::DefaultWebProxy = $null
        # 直连窗口不能太短：实测 freesub 直连要 40s+（277776 字节、链路很慢），
        # 25s 会把"慢但能下"的源误判成失败；这里与经代理尝试同口径放宽到 40s。
        Invoke-WebRequest -Uri $url -OutFile $tmpSub -UseBasicParsing -TimeoutSec 40
        $text = [System.IO.File]::ReadAllText($tmpSub, [System.Text.Encoding]::UTF8)
        Write-NetEnvLog 'INFO' "nodes refresh: $($src.id) 经代理失败，改直连成功"
      } catch {
        $lastErr = $_
      } finally {
        [System.Net.WebRequest]::DefaultWebProxy = $savedProxy
        if (Test-Path -LiteralPath $tmpSub) { Remove-Item -LiteralPath $tmpSub -Force -ErrorAction SilentlyContinue }
      }
    }
    try {
      if (-not $text) { throw "下载失败（经代理 3 次 + 直连兜底后仍失败）: $($lastErr.Exception.Message)" }
      if ($text -match '(?m)^\s*proxies\s*:') {
        $sanitized = Remove-NetEnvDangerousFields $text
        $out = Join-Path $subDir "$($src.id).yaml"
        Set-Content -LiteralPath $out -Value $sanitized -Encoding utf8
        $nodes = ([regex]::Matches($sanitized, '(?m)^\s+-\s+name\s*:')).Count
        $sourceStatus[$src.id] = "OK, $nodes 节点"
        $anyOk = $true
        Write-NetEnvLog 'INFO' "nodes refresh: $($src.id) 成功($nodes 节点)"
      } else {
        $sourceStatus[$src.id] = '格式不识别(非 Clash YAML)'
      }
    } catch {
      $sourceStatus[$src.id] = "下载失败: $($_.Exception.Message)"
      # 失败必须落日志：2026-10-18 实测两轮刷新里两个主力源全败（随后节点池冻结 47 小时），
      # 而 logs 里一条相关 WARN 都没有 —— 旧实现只把失败写进 sub-state.sourceStatus，
      # 事后定位只能靠猜。日志只记源 id 与异常文本，绝不打印订阅 URL。
      Write-NetEnvLog 'WARN' "nodes refresh: $($src.id) 下载失败: $($_.Exception.Message)"
    }
  }

  # 清理已删除/停用/未配置源的残留 yaml，否则旧节点会持续混进 merged.yaml
  Get-ChildItem -LiteralPath $subDir -Filter '*.yaml' -ErrorAction SilentlyContinue | ForEach-Object {
    if ($activeIds -notcontains $_.BaseName -and -not ($sourceStatus[$_.BaseName] -like 'OK,*')) {
      Write-NetEnvLog 'INFO' "nodes refresh: 清理失效源残留 $($_.Name)"
      Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
    }
  }

  $mergedFile = Join-Path $paths.Data 'merged.yaml'
  $mergedEmpty = $false
  $mergedWritten = $false
  if ($anyOk) {
    $mwNodes = @()
    if ($cfg.multiWan -and $cfg.multiWan.enabled) { $mwNodes = @(Get-NetEnvMultiWanCandidates -Cfg $cfg) }
    $merged = Build-NetEnvMergedConfig $subDir $cfg $mwNodes
    if ($merged -and $merged.Trim().Length -gt 0) {
      Save-NetEnvTextFile -Path $mergedFile -Content $merged
      $mergedWritten = $true
    } else {
      # 源里有 proxies: 却一个可用节点都没产出（名字全被过滤、字段非法等）时，
      # 绝不能写空配置 —— 旧 merged.yaml 是当前唯一可用出口，覆盖等于主动断网。
      $mergedEmpty = $true
      Write-NetEnvLog 'WARN' 'nodes refresh: 无可用节点，保留旧 merged.yaml（原因为名字过滤/字段非法）'
    }
  }

  $totalNodes = 0
  Get-ChildItem -LiteralPath $subDir -Filter '*.yaml' -ErrorAction SilentlyContinue | ForEach-Object {
    $totalNodes += ([regex]::Matches((Get-Content -LiteralPath $_.FullName -Raw), '(?m)^\s+-\s+name\s*:')).Count
  }

  # 【为什么要有 lastSuccessAt】旧实现只写 updatedAt = 本次刷新**尝试**的时间，而 doctor 的
  # 「订阅新鲜度」就是拿它算 age —— 于是"所有订阅源全挂、merged.yaml 一个字节没动"的那次刷新
  # 也把新鲜度刷新成现在：2026-10-08 17:18 实测 4 个已配置源全部下载失败，merged.yaml 仍是
  # 10-07 21:25 的旧文件（与 sub-state 里的 hash 逐字节相同），doctor 却报"上次更新 8 小时前"，
  # 实际节点池已冻结 28 小时 —— 正是本工具反复要抓的"全绿着坏"（源全挂时反而永远不告警）。
  # 现拆成两个时间戳：updatedAt = 本次尝试（保留原语义，供 status/排障），
  # lastSuccessAt = 上次**真正重写 merged.yaml** 的时间（本次没写成则跨轮继承，绝不被尝试时间顶掉）。
  $stateFile = Join-Path $paths.Data 'sub-state.json'
  $lastSuccessAt = $null
  if (Test-Path -LiteralPath $stateFile) {
    try {
      $prevState = (Read-NetEnvFileText $stateFile) | ConvertFrom-Json
      if ($prevState.lastSuccessAt) { $lastSuccessAt = [string]$prevState.lastSuccessAt }
    } catch {
      # 半截写入/损坏时不能顺带把"上次成功时间"清零（那等于把陈旧节点重新判成新鲜）
      Write-NetEnvLog 'WARN' "nodes refresh: 旧 sub-state.json 不可解析，无法继承上次成功时间（$($_.Exception.Message)）"
    }
  }
  $nowStamp = Get-Date -Format 's'
  if ($mergedWritten) { $lastSuccessAt = $nowStamp }
  $sourceOkCount = @($sourceStatus.Values | Where-Object { $_ -like 'OK,*' }).Count

  $state = [ordered]@{
    updatedAt = $nowStamp
    lastSuccessAt = $lastSuccessAt
    mergedWritten = $mergedWritten
    mergedEmpty = $mergedEmpty
    anySourceOk = $anyOk
    sourceOkCount = $sourceOkCount
    nodeCount = $totalNodes
    sourceStatus = $sourceStatus
    hash = if (Test-Path -LiteralPath $mergedFile) {
      (Get-FileHash -LiteralPath $mergedFile -Algorithm SHA256).Hash
    } else { '' }
  }
  Save-NetEnvTextFile -Path $stateFile -Content ($state | ConvertTo-Json -Depth 4)
  return $state
}

function Remove-NetEnvDangerousFields {
  param([string]$Yaml)
  $lines = $Yaml -split "`r?`n"
  $out = (New-Object System.Collections.Generic.List[string])
  $skipBlock = $false
  foreach ($line in $lines) {
    $line = $line -replace '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]', ''
    # 行内流式写法（如 {script: ...}）也要剥离，否则过滤可被绕过
    if ($line -match '(^|[\s,{])script\s*:') { continue }
    if ($line -match '^\s*script\s*:') { continue }
    if ($line -match '^\s*(cfw-bypass|cfw-latency|cfw-latency-timeout|prepend|append)\s*:') { continue }
    if ($line -match '^\s*proxy-providers\s*:') { $skipBlock = $true; continue }
    if ($skipBlock) {
      if ($line -match '^\S' -and $line -match ':\s*$' -and $line -notmatch '^proxy-providers') { $skipBlock = $false }
      if ($line.Trim() -ne '' -and $line -notmatch '^\s') { $skipBlock = $false }
      if ($skipBlock) { continue }
    }
    $out.Add($line)
  }
  return ($out -join "`n")
}

function Get-ClashProxyEntries {
  param([string]$Yaml)
  $entries = (New-Object System.Collections.Generic.List[string])
  $lines = $Yaml -split "`r?`n"
  $inProxies = $false
  $cur = (New-Object System.Collections.Generic.List[string])
  foreach ($line in $lines) {
    if (-not $inProxies -and $line -match '^\s*proxies\s*:') { $inProxies = $true; continue }
    if (-not $inProxies) { continue }
    if ($line -match '^\S') { break }
    if ($line -match '^\s+-\s+') {
      if ($cur.Count -gt 0) { $entries.Add(($cur -join "`n")) }
      $cur = (New-Object System.Collections.Generic.List[string])
      $cur.Add($line)
    } elseif ($cur.Count -gt 0) {
      $cur.Add($line)
    }
  }
  if ($cur.Count -gt 0) { $entries.Add(($cur -join "`n")) }
  return $entries
}

function ConvertTo-NetEnvNormalizedEntry {
  param([string]$Entry)
  $lines = $Entry -split "`n"
  $nameIndent = 0
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i].Trim() -ne '') {
      $nameIndent = ([regex]::Match($lines[$i], '^(\s*)').Groups[1].Value).Length
      break
    }
  }
  $out = (New-Object System.Collections.Generic.List[string])
  foreach ($line in $lines) {
    if ($line.Trim() -eq '') { $out.Add(''); continue }
    $m = [regex]::Match($line, '^(\s*)(.*)$')
    $rel = [Math]::Max(0, $m.Groups[1].Value.Length - $nameIndent)
    $out.Add((' ' * (2 + $rel)) + $m.Groups[2].Value)
  }
  return ($out -join "`n")
}

function ConvertFrom-YamlEscapedName {
  param([string]$Name)
  $Name = [regex]::Replace($Name, '\\U([0-9A-Fa-f]{8})', {
    param($m)
    [char]::ConvertFromUtf32([Convert]::ToInt32($m.Groups[1].Value, 16))
  })
  $Name = [regex]::Replace($Name, '\\u([0-9A-Fa-f]{4})', {
    param($m)
    [string][char][Convert]::ToInt32($m.Groups[1].Value, 16)
  })
  $Name = $Name -replace '\\n', "`n" -replace '\\t', "`t" -replace '\\"', '"' -replace '\\\\', '\'
  return $Name
}

function ConvertTo-NetEnvYamlQuoted {
  param([string]$Value)
  if ($null -eq $Value) { return '""' }
  return '"' + ($Value.Replace('\', '\\').Replace('"', '\"')) + '"'
}

function Get-NetEnvMultiWanCandidates {
  # 从运行中的 mihomo 控制器取 auto-urltest 的历史延迟，选最近一轮可达且延迟最低的 N 个节点。
  # 目的：multiWan 只复制少量节点，不能靠订阅顺序瞎选（免费源前几个常是广告/死节点）。
  # 控制器不可用（mihomo 正在故障、端口没起）时返回空数组，由 Build 走确定性过滤兜底。
  param($Cfg)
  if (-not $Cfg -or -not $Cfg.multiWan -or -not $Cfg.multiWan.enabled) { return @() }
  $explicit = @()
  foreach ($n in @($Cfg.multiWan.nodes)) { if ($n) { $explicit += [string]$n } }
  if ($explicit.Count -gt 0) { return $explicit }

  $maxNodes = 8
  if ($null -ne $Cfg.multiWan.maxNodes) { $maxNodes = [int]$Cfg.multiWan.maxNodes }
  if ($maxNodes -lt 1) { $maxNodes = 1 }
  if ($maxNodes -gt 64) { $maxNodes = 64 }
  $rankGroup = 'auto-urltest'
  if ($Cfg.multiWan.rankGroup) { $rankGroup = [string]$Cfg.multiWan.rankGroup }
  $port = 0
  if ($Cfg.ports -and $Cfg.ports.mihomoController) { $port = [int]$Cfg.ports.mihomoController }
  if ($port -le 0) { return @() }
  try {
    $data = Get-NetEnvJsonUtf8 -Uri ("http://127.0.0.1:{0}/proxies" -f $port) -TimeoutSec 4
    $groupProp = $data.proxies.PSObject.Properties[$rankGroup]
    if (-not $groupProp) { return @() }
    $members = @($groupProp.Value.all)
    $ranked = New-Object System.Collections.Generic.List[object]
    foreach ($name in $members) {
      $p = $data.proxies.PSObject.Properties[[string]$name]
      if (-not $p) { continue }
      $history = @($p.Value.history)
      if ($history.Count -eq 0) { continue }
      $last = $history[$history.Count - 1]
      $delay = 0
      if ($last -and $last.delay) { $delay = [int]$last.delay }
      if ($delay -gt 0) { $ranked.Add([PSCustomObject]@{ Name = [string]$name; Delay = $delay }) }
    }
    $out = @()
    foreach ($r in ($ranked | Sort-Object Delay | Select-Object -First $maxNodes)) { $out += $r.Name }
    return $out
  } catch {
    return @()
  }
}

function Set-NetEnvMultiWanSelection {
  # 把 egress-select 切到 multiWan 生成的首成员。为什么必须显式切：mihomo 的 select 组会从
  # cache.db 恢复上次选择，config 里把 wan-lb 放第一位并不等于重载后就会选它（本机实测
  # 重载后仍是 auto-urltest）。只读一次控制器，已经是目标就不 PUT。
  param($Cfg, [int]$ControllerPort = 19090)
  if (-not $Cfg -or -not $Cfg.multiWan -or -not $Cfg.multiWan.enabled) { return $false }
  if ($null -ne $Cfg.multiWan.prefer -and -not [bool]$Cfg.multiWan.prefer) { return $false }
  try {
    $psel = Get-NetEnvJsonUtf8 -Uri "http://127.0.0.1:$ControllerPort/proxies/egress-select" -TimeoutSec 5
    $all = @($psel.all)
    if ($all.Count -eq 0) { return $false }
    $target = [string]$all[0]
    # 生成计划被跳过时 egress-select 不存在（404）或首成员异常，不能把“没生成”误判成“已切换”。
    if (@('proxy-select', 'auto-urltest', 'github-node', 'gpt-node', 'DIRECT') -contains $target) { return $false }
    if ([string]$psel.now -eq $target) { return $true }
    [void](Invoke-NetEnvJsonPut -Uri "http://127.0.0.1:$ControllerPort/proxies/egress-select" -Json (@{ name = $target } | ConvertTo-Json) -TimeoutSec 10)
    return $true
  } catch {
    return $false
  }
}

function Get-NetEnvMultiWanPlan {
  # 纯函数：只根据合并后的节点名列表与配置生成计划，不碰网络/不写文件，便于 Pester 覆盖。
  param([string[]]$Order, $Cfg, [string[]]$PreferredNodes = @())
  if (-not $Cfg -or -not $Cfg.multiWan) { return $null }
  $mw = $Cfg.multiWan
  if (-not $mw.enabled) { return $null }

  $ifaces = New-Object System.Collections.Generic.List[object]
  $usedLabels = @{}
  $ifIndex = 0
  foreach ($item in @($mw.interfaces)) {
    if ($null -eq $item) { continue }
    $ifIndex = $ifIndex + 1
    $name = ''
    $label = ''
    if ($item -is [string]) {
      $name = [string]$item
    } else {
      if ($item.name) { $name = [string]$item.name }
      if ($item.label) { $label = [string]$item.label }
    }
    $name = $name.Trim()
    if (-not $name) { continue }
    if (-not $label) {
      if ($name -match '^[A-Za-z0-9_-]+$') { $label = $name.ToLower() } else { $label = 'wan' + [string]$ifIndex }
    }
    $label = ($label.ToLower() -replace '[^a-z0-9_-]', '')
    if (-not $label) { $label = 'wan' + [string]$ifIndex }
    if ($usedLabels.ContainsKey($label)) { $label = $label + [string]$ifIndex }
    $usedLabels[$label] = $true
    $ifaces.Add([PSCustomObject]@{ Name = $name; Label = $label })
  }
  if ($ifaces.Count -lt 2) {
    Write-NetEnvLog 'WARN' 'multiWan: interfaces 少于两个，已跳过'
    return $null
  }

  $mode = 'load-balance'
  if ([string]$mw.mode -eq 'failover') { $mode = 'failover' }
  $strategy = 'sticky-sessions'
  if (@('round-robin', 'consistent-hashing', 'sticky-sessions') -contains [string]$mw.strategy) {
    $strategy = [string]$mw.strategy
  }

  $maxNodes = 8
  if ($null -ne $mw.maxNodes) { $maxNodes = [int]$mw.maxNodes }
  if ($maxNodes -lt 1) { $maxNodes = 1 }
  if ($maxNodes -gt 64) { $maxNodes = 64 }
  $include = @()
  foreach ($p in @($mw.include)) { if ($p) { $include += [string]$p } }
  $exclude = @()
  foreach ($p in @($mw.exclude)) { if ($p) { $exclude += [string]$p } }
  $explicit = @()
  foreach ($n in @($mw.nodes)) { if ($n) { $explicit += [string]$n } }

  $selected = New-Object System.Collections.Generic.List[string]
  if ($explicit.Count -gt 0) {
    foreach ($n in $explicit) {
      if (($Order -contains $n) -and (-not $selected.Contains($n))) { $selected.Add($n) }
    }
    if ($selected.Count -eq 0) {
      Write-NetEnvLog 'WARN' 'multiWan: nodes 中列出的节点在本次合并结果中都不存在，已跳过'
      return $null
    }
  } else {
    foreach ($n in @($PreferredNodes)) {
      if ($n -and ($Order -contains $n) -and (-not $selected.Contains([string]$n))) { $selected.Add([string]$n) }
      if ($selected.Count -ge $maxNodes) { break }
    }
    if ($selected.Count -eq 0) {
      foreach ($n in $Order) {
        $keep = $true
        if ($include.Count -gt 0) {
          $keep = $false
          foreach ($p in $include) { if ($n -like ('*' + $p + '*')) { $keep = $true; break } }
        }
        if ($keep -and $exclude.Count -gt 0) {
          foreach ($p in $exclude) { if ($n -like ('*' + $p + '*')) { $keep = $false; break } }
        }
        if ($keep) { $selected.Add($n) }
        if ($selected.Count -ge $maxNodes) { break }
      }
    }
  }
  if ($selected.Count -eq 0) {
    Write-NetEnvLog 'WARN' 'multiWan: 没有可用节点，已跳过'
    return $null
  }

  $reserved = @('proxy-select', 'auto-urltest', 'github-node', 'github-adaptive', 'gpt-node', 'gpt-adaptive', 'gpt-probe')
  $topGroup = 'wan-lb'
  if ($mode -eq 'failover') { $topGroup = 'wan-failover' }
  if ($mw.groupName) {
    $candidate = ([string]$mw.groupName).Trim()
    $candidate = $candidate -replace '[^A-Za-z0-9_-]', '-'
    if ($candidate) { $topGroup = $candidate }
  }
  if (($reserved -contains $topGroup) -or ($Order -contains $topGroup)) { $topGroup = 'mw-' + $topGroup }

  $usedNames = @{}
  foreach ($n in $Order) { $usedNames[$n] = $true }
  $duplicates = New-Object System.Collections.Generic.List[object]
  foreach ($n in $selected) {
    foreach ($iface in $ifaces) {
      $dupName = $n + ' @' + $iface.Label
      $suffix = 2
      while ($usedNames.ContainsKey($dupName)) {
        $dupName = $n + ' @' + $iface.Label + '#' + [string]$suffix
        $suffix = $suffix + 1
      }
      $usedNames[$dupName] = $true
      $duplicates.Add([PSCustomObject]@{
        Name = $dupName
        Node = $n
        Interface = $iface.Name
        Label = $iface.Label
      })
    }
  }

  $probeUrl = 'https://www.google.com/generate_204'
  if ($mw.url) { $probeUrl = [string]$mw.url }
  elseif ($Cfg.subscription -and $Cfg.subscription.urlTest -and $Cfg.subscription.urlTest.url) { $probeUrl = [string]$Cfg.subscription.urlTest.url }
  $interval = 300
  if ($null -ne $mw.interval) { $interval = [int]$mw.interval }
  if ($interval -lt 30) { $interval = 30 }
  $lazy = $true
  if ($null -ne $mw.lazy) { $lazy = [bool]$mw.lazy }
  $prefer = $true
  if ($null -ne $mw.prefer) { $prefer = [bool]$mw.prefer }

  return [PSCustomObject]@{
    Mode = $mode
    Strategy = $strategy
    TopGroup = $topGroup
    Prefer = $prefer
    Url = $probeUrl
    Interval = $interval
    Lazy = $lazy
    Interfaces = $ifaces.ToArray()
    Duplicates = $duplicates.ToArray()
  }
}

function Build-NetEnvMergedConfig {
  param([string]$SubDir, $Cfg, [string[]]$MultiWanNodeNames = @())
  $files = @(Get-ChildItem -LiteralPath $SubDir -Filter '*.yaml' -ErrorAction SilentlyContinue | Sort-Object Name)
  if ($files.Count -eq 0) { return '' }

  $byName = @{}
  $order = (New-Object System.Collections.Generic.List[string])
  foreach ($f in $files) {
    $text = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8
    foreach ($e in (Get-ClashProxyEntries $text)) {
      if ($e -notmatch '(?m)^\s+-\s+(name|cipher)\s*:') { continue }
      # mihomo 对非法 REALITY public-key 会整包拒绝加载，构建期直接剔除
      if ($e -match 'reality-opts') {
        $pk = [regex]::Match($e, '(?m)^\s+public-key\s*:\s*(\S+)').Groups[1].Value
        if ($pk -notmatch '^[A-Za-z0-9_-]{43}$') { continue }
      }
      $m = [regex]::Match($e, '(?m)^\s+(?:-\s+)?name\s*:\s*(.+?)\s*$')
      if ($m.Success) {
        $name = $m.Groups[1].Value.Trim()
        if ($name.Length -ge 2 -and $name[0] -eq '"' -and $name[$name.Length - 1] -eq '"') {
          $name = $name.Substring(1, $name.Length - 2)
        } elseif ($name.Length -ge 2 -and $name[0] -eq "'" -and $name[$name.Length - 1] -eq "'") {
          $name = $name.Substring(1, $name.Length - 2)
        }
        $name = ConvertFrom-YamlEscapedName $name
        if ($name -and -not $byName.ContainsKey($name) -and $name -notmatch 'https?://|电报群|日期：|免费VPN|剩余|到期|官网|套餐|expire') {
          $byName[$name] = $e
          $order.Add($name)
        }
      }
    }
  }
  if ($order.Count -eq 0) { return '' }

  $mwPlan = $null
  if ($Cfg -and $Cfg.multiWan -and $Cfg.multiWan.enabled) {
    $mwPlan = Get-NetEnvMultiWanPlan -Order @($order) -Cfg $Cfg -PreferredNodes $MultiWanNodeNames
  }

  $proxiesLines = (New-Object System.Collections.Generic.List[string])
  foreach ($n in $order) { $proxiesLines.Add((ConvertTo-NetEnvNormalizedEntry $byName[$n])) }
  if ($mwPlan) {
    # flow 写法（- {name: ...}）无法安全地在后面追加字段；一旦有这种节点，整块 multiWan 放弃，
    # 避免生成“组里引用了不存在的成员”的配置让 mihomo 直接拒绝加载。
    $flowNodes = @()
    foreach ($d in $mwPlan.Duplicates) {
      if ($byName[$d.Node] -match '(?m)^\s+-\s+\{') { $flowNodes += $d.Node }
    }
    if ($flowNodes.Count -gt 0) {
      Write-NetEnvLog 'WARN' ("multiWan: 节点为行内 flow 写法，无法附加 interface-name，已跳过: " + (($flowNodes | Select-Object -Unique) -join ', '))
      $mwPlan = $null
    }
  }
  if ($mwPlan) {
    foreach ($d in $mwPlan.Duplicates) {
      $baseEntry = ConvertTo-NetEnvNormalizedEntry $byName[$d.Node]
      $baseEntry = [regex]::Replace($baseEntry, '(?m)^(\s*(?:-\s+)?name\s*:\s*).*$', {
        param($m)
        return $m.Groups[1].Value + (ConvertTo-NetEnvYamlQuoted $d.Name)
      }, 1)
      $proxiesLines.Add($baseEntry + "`n    interface-name: " + (ConvertTo-NetEnvYamlQuoted $d.Interface))
    }
    Write-NetEnvLog 'INFO' ("multiWan: 组 {0}，模式 {1}，节点 {2} 个 × 接口 {3} 个，共 {4} 条出站" -f $mwPlan.TopGroup, $mwPlan.Mode, @($mwPlan.Duplicates | ForEach-Object { $_.Node } | Select-Object -Unique).Count, @($mwPlan.Interfaces).Count, @($mwPlan.Duplicates).Count)
  }
  $proxiesBlock = ($proxiesLines -join "`n")

  $directDomains = @()
  foreach ($d in @($Cfg.sensitiveDomains) + @($Cfg.githubAuthDomains)) {
    $dom = (($d -replace '^\*\.', '') -split '/')[0]
    if ($dom -and ($directDomains -notcontains $dom)) { $directDomains += $dom }
  }
  $ruleLines = foreach ($dom in $directDomains) { "    - DOMAIN-SUFFIX,$dom,DIRECT" }
  $ruleText = $ruleLines -join "`n"

  $adaptiveDomains = @()
  foreach ($d in @($Cfg.githubAdaptiveDomains)) {
    $dom = (($d -replace '^\*\.', '') -split '/')[0]
    if ($dom -and ($adaptiveDomains -notcontains $dom)) { $adaptiveDomains += $dom }
  }
  $adaptiveRuleLines = foreach ($dom in $adaptiveDomains) { "    - DOMAIN-SUFFIX,$dom,github-adaptive" }
  $adaptiveRuleText = $adaptiveRuleLines -join "`n"

  # GPT 分流：与 githubAdaptiveDomains 同一套写法（域名去 *./路径后缀再生成 DOMAIN-SUFFIX）。
  # 必须放在 GEOSITE,cn 之前，否则 openai.com 之类的境外域不会被误判——但 gemini/其他
  # 国内 CDN 域名若被写进来就会抢占，故这里只列 OpenAI 自有域与静态资源域。
  $gptDomains = @()
  foreach ($d in @($Cfg.gptAdaptiveDomains)) {
    $dom = (($d -replace '^\*\.', '') -split '/')[0]
    if ($dom -and ($gptDomains -notcontains $dom)) { $gptDomains += $dom }
  }
  $gptRuleLines = foreach ($dom in $gptDomains) { "    - DOMAIN-SUFFIX,$dom,gpt-adaptive" }
  $gptRuleText = $gptRuleLines -join "`n"

  $groupNames = foreach ($n in $order) {
    $esc = $n.Replace('\', '\\').Replace('"', '\"')
    "      - `"$esc`""
  }

  # multiWan：把少量节点按接口各复制一份，放进一个 load-balance（吞吐）或 fallback（故障切换）组。
  # 组名与成员全部在这里生成；关闭时两个变量为空，输出与旧版逐字节一致（回归用例钉住）。
  $multiWanGroupsBlock = ''
  $proxySelectLines = New-Object System.Collections.Generic.List[string]
  if ($mwPlan) {
    $members = New-Object System.Collections.Generic.List[string]
    if ($mwPlan.Mode -eq 'failover') {
      # fallback 按顺序取第一个可用成员：先放接口 1 的全部节点，再放接口 2，才叫“链路故障切换”。
      foreach ($iface in $mwPlan.Interfaces) {
        foreach ($d in $mwPlan.Duplicates) {
          if ($d.Label -eq $iface.Label) { $members.Add((ConvertTo-NetEnvYamlQuoted $d.Name)) }
        }
      }
    } else {
      foreach ($d in $mwPlan.Duplicates) { $members.Add((ConvertTo-NetEnvYamlQuoted $d.Name)) }
    }
    $mwType = 'load-balance'
    if ($mwPlan.Mode -eq 'failover') { $mwType = 'fallback' }
    $mwLines = New-Object System.Collections.Generic.List[string]
    $mwLines.Add('  - name: ' + $mwPlan.TopGroup)
    $mwLines.Add('    type: ' + $mwType)
    if ($mwType -eq 'load-balance') { $mwLines.Add('    strategy: ' + $mwPlan.Strategy) }
    $mwLines.Add('    url: ' + (ConvertTo-NetEnvYamlQuoted $mwPlan.Url))
    $mwLines.Add('    interval: ' + [string]$mwPlan.Interval)
    $mwLines.Add('    tolerance: 50')
    $mwLines.Add('    lazy: ' + $mwPlan.Lazy.ToString().ToLower())
    $mwLines.Add('    proxies:')
    foreach ($m in $members) { $mwLines.Add('      - ' + $m) }
    $multiWanGroupsBlock = ($mwLines -join [Environment]::NewLine) + [Environment]::NewLine
  }
  $proxySelectLines.Add('      - auto-urltest')
  $proxySelectLines.Add('      - github-node')
  $proxySelectLines.Add('      - gpt-node')
  $proxySelectLines.Add('      - DIRECT')
  $proxySelectBlock = $proxySelectLines -join [Environment]::NewLine

  # 为什么另开 egress-select，而不是把 wan-lb 塞进 proxy-select：
  # github-adaptive 的成员里有 proxy-select；一旦 proxy-select 被切成 wan-lb，GitHub 的保底
  # 也会跟着走多网卡组（实测 2026-10-19 启用后 github.com 从 200 变成 000）。
  # 因此 proxy-select 保持原样，只让 MATCH 走 egress-select；prefer=false 时连 MATCH 都不改。
  $multiWanEgressBlock = ''
  $proxyMatchTarget = 'proxy-select'
  if ($mwPlan) {
    $egressLines = New-Object System.Collections.Generic.List[string]
    $egressLines.Add('  - name: egress-select')
    $egressLines.Add('    type: select')
    $egressLines.Add('    proxies:')
    $egressLines.Add('      - ' + $mwPlan.TopGroup)
    $egressLines.Add('      - proxy-select')
    $egressLines.Add('      - DIRECT')
    $multiWanEgressBlock = ($egressLines -join [Environment]::NewLine) + [Environment]::NewLine
    if ($mwPlan.Prefer) { $proxyMatchTarget = 'egress-select' }
  }

  # 探针专用入口 + 专用节点池。端口缺省时**整块不生成**（含 IN-PORT 规则）：
  # 老配置没有 ports.mihomoProbe，若照旧往 YAML 里塞一个空端口的 listener，mihomo 会
  # 直接拒绝加载 —— 那是断网级故障，而不是"少一个优化"。缺端口时行为退回旧路径。
  $probePort = 0
  if ($Cfg.ports -and $Cfg.ports.mihomoProbe) { $probePort = [int]$Cfg.ports.mihomoProbe }
  $probeListenersBlock = ''
  $probeRuleText = ''
  $probeGroupsBlock = ''
  if ($probePort -gt 0) {
    $probeListenersBlock = @"
# ---- 探针专用入口（GPT 节点轮换用）----
# 为什么必须单开一条入口：地区判据只能由**真实响应码**给出，于是轮换必须把候选节点切过去
# 逐个复测。若切的是线上组（gpt-node，即 7897/7890 入口），正在上网的流量会跟着"尚未验证"
# 的候选一起走 —— 2026-10-06 16:53 实测：轮换把线上组切到香港候选，用户恰在同一秒打开
# chatgpt.com，拿到 Cloudflare 的 403 unsupported_country_region_territory「无法加载网站」页。
# 单开入口后，轮换只动 gpt-probe 组，线上 gpt-node 在整个复测期间纹丝不动，最终只做一次
# "已通过地区判据"的原子切换。规则侧第一条 IN-PORT 把这条入口整体导向 gpt-probe。
listeners:
  - name: gpt-probe
    type: mixed
    port: $probePort
    listen: 127.0.0.1
"@
    $probeRuleText = "    - IN-PORT,$probePort,gpt-probe"
    $probeGroupsBlock = @"
  # 探针专用节点池：与 gpt-node 同一批节点，但只被探针入口（IN-PORT 规则）使用。
  # 轮换在这里反复切换候选，线上流量看不到这个过程。
  - name: gpt-probe
    type: select
    proxies:
$($groupNames -join "`n")
"@
  }

  $merged = @"
mixed-port: $($Cfg.ports.mihomoMixed)
port: $($Cfg.ports.mihomoHttp)
allow-lan: false
mode: rule
log-level: info
ipv6: false
external-controller: 127.0.0.1:$($Cfg.ports.mihomoController)
$probeListenersBlock
# sniffer：按 TLS SNI / HTTP Host 还原真实域名后再匹配规则。
# 必要性：本地 DNS 对 github.com / www.google.com 等存在投毒（实测 github.com 被解析到不可达 IP
# 20.205.243.166，而真实 IP 140.82.112.3 可通），仅靠 IP 分流会判错目标。
sniffer:
  enable: true
  force-dns-mapping: true
  parse-pure-ip: true
  override-destination: true
  sniff:
    HTTP:
      ports:
        - 80
        - 8080-8880
      override-destination: true
    TLS:
      ports:
        - 443
        - 8443
      override-destination: true
    QUIC:
      ports:
        - 443
        - 8443
dns:
  enable: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  default-nameserver:
    - 223.5.5.5
    - 119.29.29.29
  nameserver:
    - https://doh.pub/dns-query
    - https://223.5.5.5/dns-query
proxies:
$proxiesBlock
proxy-groups:
$multiWanGroupsBlock  - name: proxy-select
    type: select
    proxies:
$proxySelectBlock
  - name: auto-urltest
    type: url-test
    url: $($Cfg.subscription.urlTest.url)
    interval: $($Cfg.subscription.urlTest.interval)
    tolerance: 150
    lazy: $($Cfg.subscription.urlTest.lazy.ToString().ToLower())
    proxies:
$($groupNames -join "`n")
  # github 专用节点池：同一批节点，但用 github 自身端点甄选。
  # 必要性：通用组按 google 选点，而"能通 google"的节点未必能完成 github 的 TLS 会话
  # （实测同一节点 google 204 而 github TLS 失败；全池 423 节点中仅 11 个能到 github 端点）。
  - name: github-node
    type: url-test
    url: $(if ($Cfg.subscription.githubUrlTest.url) { $Cfg.subscription.githubUrlTest.url } else { 'https://github.com/robots.txt' })
    interval: $(if ($Cfg.subscription.githubUrlTest.interval) { $Cfg.subscription.githubUrlTest.interval } else { 60 })
    tolerance: 100
    lazy: true
    proxies:
$($groupNames -join "`n")
  - name: github-adaptive
    # 选点依据必须是 github 自身端点：用通用 URL(google/gstatic) 会把 github.com 判给机场节点，
    # 后果 1) github.com 经节点仍 30s；2) 认证流量经第三方免费节点（违反 docs/GITHUB-SAFETY.md）。
    # 实测 github.com/robots.txt：直连 0.52s vs 经节点 1.55s -> 该组会自行选 DIRECT。
    type: url-test
    url: $(if ($Cfg.subscription.githubUrlTest.url) { $Cfg.subscription.githubUrlTest.url } else { 'https://github.com/robots.txt' })
    interval: 120
    tolerance: 50
    lazy: true
    proxies:
      - github-node
      - proxy-select
      - DIRECT
  # GPT（OpenAI / ChatGPT）专用组。为什么不能只靠 url-test 选点：实测 mihomo 测速**只看连通、
  # 不看状态码**（chatgpt.com 的 403 挑战与 api.openai.com 的 401/403 都返回正延迟），
  # 于是"延迟最低"的香港节点必被选中 —— 而香港是 OpenAI 不支持地区，GPT 会应用层 403。
  # 因此 gpt-node 用 select：由 supervisor-loop 用真实响应码轮换并钉住"地区受支持"的节点
  # （见 core.ps1 的 Invoke-NetEnvGptNodeRotation）；gpt-adaptive 是顶层入口 + 人工兜底。
  - name: gpt-node
    type: select
    proxies:
$($groupNames -join "`n")
$probeGroupsBlock
  - name: gpt-adaptive
    type: select
    proxies:
      - gpt-node
      - proxy-select
      - DIRECT
$multiWanEgressBlock
rules:
$probeRuleText
$ruleText
$adaptiveRuleText
$gptRuleText
    - GEOSITE,cn,DIRECT
    - GEOIP,CN,DIRECT,no-resolve
    - MATCH,$proxyMatchTarget
"@
  return $merged
}
