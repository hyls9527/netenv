. "$PSScriptRoot\core.ps1"

function Invoke-NetEnvNodesRefresh {
  $cfg = Read-NetEnvConfig
  $paths = Get-NetEnvPaths
  $subDir = Join-Path $paths.Data 'subs'
  if (-not (Test-Path -LiteralPath $subDir)) { New-Item -ItemType Directory -Path $subDir -Force | Out-Null }

  $sourceStatus = @{}
  $anyOk = $false
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
    try {
      $tmpSub = Join-Path $paths.Data ("dl-" + $src.id + ".sub")
      Invoke-WebRequest -Uri $url -OutFile $tmpSub -UseBasicParsing -TimeoutSec 30
      $text = [System.IO.File]::ReadAllText($tmpSub, [System.Text.Encoding]::UTF8)
      Remove-Item -LiteralPath $tmpSub -Force -ErrorAction SilentlyContinue
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
    }
  }

  if ($anyOk) {
    $merged = Build-NetEnvMergedConfig $subDir $cfg
    Set-Content -LiteralPath (Join-Path $paths.Data 'merged.yaml') -Value $merged -Encoding utf8
  }

  $totalNodes = 0
  Get-ChildItem -LiteralPath $subDir -Filter '*.yaml' -ErrorAction SilentlyContinue | ForEach-Object {
    $totalNodes += ([regex]::Matches((Get-Content -LiteralPath $_.FullName -Raw), '(?m)^\s+-\s+name\s*:')).Count
  }
  $state = [ordered]@{
    updatedAt = (Get-Date -Format 's')
    nodeCount = $totalNodes
    sourceStatus = $sourceStatus
    hash = if (Test-Path -LiteralPath (Join-Path $paths.Data 'merged.yaml')) {
      (Get-FileHash -LiteralPath (Join-Path $paths.Data 'merged.yaml') -Algorithm SHA256).Hash
    } else { '' }
  }
  $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $paths.Data 'sub-state.json') -Encoding utf8
  return $state
}

function Remove-NetEnvDangerousFields {
  param([string]$Yaml)
  $lines = $Yaml -split "`r?`n"
  $out = [System.Collections.Generic.List[string]]::new()
  $skipBlock = $false
  foreach ($line in $lines) {
    $line = $line -replace '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]', ''
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
  $entries = [System.Collections.Generic.List[string]]::new()
  $lines = $Yaml -split "`r?`n"
  $inProxies = $false
  $cur = [System.Collections.Generic.List[string]]::new()
  foreach ($line in $lines) {
    if (-not $inProxies -and $line -match '^\s*proxies\s*:') { $inProxies = $true; continue }
    if (-not $inProxies) { continue }
    if ($line -match '^\S') { break }
    if ($line -match '^\s+-\s+name\s*:') {
      if ($cur.Count -gt 0) { $entries.Add(($cur -join "`n")) }
      $cur = [System.Collections.Generic.List[string]]::new()
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
  $out = [System.Collections.Generic.List[string]]::new()
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

function Build-NetEnvMergedConfig {
  param([string]$SubDir, $Cfg)
  $files = @(Get-ChildItem -LiteralPath $SubDir -Filter '*.yaml' -ErrorAction SilentlyContinue | Sort-Object Name)
  if ($files.Count -eq 0) { return '' }

  $byName = @{}
  $order = [System.Collections.Generic.List[string]]::new()
  foreach ($f in $files) {
    $text = Get-Content -LiteralPath $f.FullName -Raw
    foreach ($e in (Get-ClashProxyEntries $text)) {
      $m = [regex]::Match($e, '(?m)^\s+-\s+name\s*:\s*(.+?)\s*$')
      if ($m.Success) {
        $name = $m.Groups[1].Value.Trim()
        if ($name.Length -ge 2 -and $name[0] -eq '"' -and $name[$name.Length - 1] -eq '"') {
          $name = $name.Substring(1, $name.Length - 2)
        } elseif ($name.Length -ge 2 -and $name[0] -eq "'" -and $name[$name.Length - 1] -eq "'") {
          $name = $name.Substring(1, $name.Length - 2)
        }
        $name = ConvertFrom-YamlEscapedName $name
        if ($name -and -not $byName.ContainsKey($name)) {
          $byName[$name] = $e
          $order.Add($name)
        }
      }
    }
  }
  if ($order.Count -eq 0) { return '' }

  $base = Get-Content -LiteralPath $files[0].FullName -Raw
  $base = Remove-NetEnvDangerousFields $base

  $proxiesLines = [System.Collections.Generic.List[string]]::new()
  foreach ($n in $order) { $proxiesLines.Add((ConvertTo-NetEnvNormalizedEntry $byName[$n])) }
  $proxiesBlock = ($proxiesLines -join "`n")

  if ($base -match '(?m)^proxies\s*:') {
    $base = [regex]::Replace($base, '(?ms)^proxies\s*:\s*\r?\n.*?(?=^\S|\z)', "proxies:`n$proxiesBlock`n", 1)
  } else {
    $base = $base.TrimEnd() + "`n`nproxies:`n$proxiesBlock`n"
  }

  $directDomains = @()
  foreach ($d in @($Cfg.sensitiveDomains) + @($Cfg.githubAuthDomains)) {
    $dom = (($d -replace '^\*\.', '') -split '/')[0]
    if ($dom -and ($directDomains -notcontains $dom)) { $directDomains += $dom }
  }
  $ruleIndent = '    '
  $ruleFirst = [regex]::Match($base, '(?ms)^rules\s*:\s*\r?\n(\s*)- ')
  if ($ruleFirst.Success) { $ruleIndent = $ruleFirst.Groups[1].Value }
  $ruleLines = foreach ($dom in $directDomains) { "$ruleIndent- DOMAIN-SUFFIX,$dom,DIRECT" }
  $ruleText = $ruleLines -join "`n"
  if ($base -match '(?m)^rules\s*:') {
    $base = [regex]::Replace($base, '(?ms)^(rules\s*:\s*\r?\n)(\s+- )', "`$1$ruleText`n`$2", 1)
  } else {
    $base = $base.TrimEnd() + "`n`nrules:`n$ruleText`n$ruleIndent- MATCH,auto-select`n"
  }

  $groupNames = foreach ($n in $order) {
    $esc = $n.Replace('\', '\\').Replace('"', '\"')
    "      - `"$esc`""
  }
  $group = @"
  - name: auto-select
    type: url-test
    url: $($Cfg.subscription.urlTest.url)
    interval: $($Cfg.subscription.urlTest.interval)
    tolerance: $($Cfg.subscription.urlTest.tolerance)
    lazy: $($Cfg.subscription.urlTest.lazy.ToString().ToLower())
    proxies:
      - DIRECT
$($groupNames -join "`n")
"@
  if ($base -match '(?m)^proxy-groups\s*:') {
    $base = [regex]::Replace($base, '(?ms)^(proxy-groups\s*:\s*\r?\n)', "`$1$group`n", 1)
  } else {
    $base = $base.TrimEnd() + "`n`nproxy-groups:`n$group`n"
  }

  return $base
}
