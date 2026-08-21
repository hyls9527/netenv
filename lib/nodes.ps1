. "$PSScriptRoot\core.ps1"

function Invoke-NetEnvNodesRefresh {
  $cfg = Read-NetEnvConfig
  $paths = Get-NetEnvPaths
  $subDir = Join-Path $paths.Data 'subs'
  if (-not (Test-Path -LiteralPath $subDir)) { New-Item -ItemType Directory -Path $subDir -Force | Out-Null }

  $sourceStatus = @{}
  $anyOk = $false
  foreach ($src in (Read-NetEnvJson -Name 'sources')) {
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
      $raw = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30
      $text = $raw.Content
      if ($text -match '^---' -or $text -match '^\s*proxies\s*:') {
        $sanitized = Remove-NetEnvDangerousFields $text
        $out = Join-Path $subDir "$($src.id).yaml"
        Set-Content -LiteralPath $out -Value $sanitized -Encoding utf8
        $nodes = ([regex]::Matches($sanitized, '(?m)^\s{2}-\s+name\s*:')).Count
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
    $totalNodes += ([regex]::Matches((Get-Content -LiteralPath $_.FullName -Raw), '(?m)^\s{2}-\s+name\s*:')).Count
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

function Build-NetEnvMergedConfig {
  param([string]$SubDir, $Cfg)
  $first = Get-ChildItem -LiteralPath $SubDir -Filter '*.yaml' | Select-Object -First 1
  if (-not $first) { return '' }
  $body = Get-Content -LiteralPath $first.FullName -Raw
  $group = @"

proxy-groups:
  - name: auto-select
    type: url-test
    url: $($Cfg.subscription.urlTest.url)
    interval: $($Cfg.subscription.urlTest.interval)
    tolerance: $($Cfg.subscription.urlTest.tolerance)
    lazy: $($Cfg.subscription.urlTest.lazy.ToString().ToLower())
"@
  return ($body.TrimEnd() + "`n" + $group)
}
