. "$PSScriptRoot\core.ps1"

$script:GithubTokenPattern = 'ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|gho_[A-Za-z0-9]{20,}|ghs_[A-Za-z0-9]{20,}'

function Get-NetEnvSecretTargets {
  $targets = (New-Object System.Collections.Generic.List[string])
  $overwall = Join-Path (Get-NetEnvRoot) '_tmp_openai_overwall'
  if (Test-Path -LiteralPath $overwall) {
    Get-ChildItem -LiteralPath $overwall -File -Force -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '(account|cookie|subscription|token|secret|auth|key|proxies|known-good|nodes)' } |
      ForEach-Object { $targets.Add($_.FullName) }
  }
  $codex = Join-Path $env:USERPROFILE '.codex'
  if (Test-Path -LiteralPath $codex) {
    Get-ChildItem -LiteralPath $codex -File -Force -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -eq '.env' -or $_.Name -like 'config.toml.bak-*' } |
      ForEach-Object { $targets.Add($_.FullName) }
  }
  $dsh = Join-Path $env:USERPROFILE '.dsh'
  if (Test-Path -LiteralPath $dsh) {
    foreach ($n in '.credentials.yaml', '.env') {
      $p = Join-Path $dsh $n
      if (Test-Path -LiteralPath $p) { $targets.Add($p) }
    }
  }
  $twofa = Join-Path (Join-Path $env:USERPROFILE 'Downloads') 'GitHub 双重验证，扩展备份。authenticator.txt'
  if (Test-Path -LiteralPath $twofa) { $targets.Add($twofa) }
  return @($targets | Select-Object -Unique)
}

function Get-TokenFingerprint {
  param([string]$Token)
  # 必须兼容 Windows PowerShell 5.1 的 .NET Framework：
  # SHA256::HashData 与 Convert::ToHexString 是 .NET 5+ API，5.1 下会 MethodNotFound。
  $sha = New-Object System.Security.Cryptography.SHA256Managed
  try { $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Token)) }
  finally { $sha.Dispose() }
  return (($hash | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 8)
}

function Invoke-NetEnvSecretsScan {
  param([switch]$Github)
  $rows = (New-Object System.Collections.Generic.List[object])
  foreach ($f in (Get-NetEnvSecretTargets)) {
    $kind = 'file'
    $tokenCount = 0
    if ((Get-Item -LiteralPath $f -Force).PSIsContainer) { continue }
    try {
      $raw = Read-NetEnvFileText $f
      $tokenCount = ([regex]::Matches($raw, $script:GithubTokenPattern)).Count
      if ($raw -match '(?i)(password|secret|cookie|apikey|api_key|token|authorization)') { $kind = 'sensitive' }
    } catch { $kind = 'unreadable' }
    $row = [PSCustomObject]@{ Path = $f; Kind = $kind; GithubTokens = $tokenCount }
    if ($Github -and $tokenCount -gt 0) {
      $fingerprints = [regex]::Matches($raw, $script:GithubTokenPattern) | ForEach-Object {
        $fp = Get-TokenFingerprint $_.Value
        $st = Get-GithubTokenStatus $_.Value
        "$fp(HTTP $($st.Http))"
      }
      $row | Add-Member -NotePropertyName TokenStatus -NotePropertyValue ($fingerprints -join ', ')
    }
    $rows.Add($row)
  }
  $envToken = [Environment]::GetEnvironmentVariable('GITHUB_TOKEN', 'User')
  if ($envToken) {
    $st = if ($Github) { Get-GithubTokenStatus $envToken } else { $null }
    $rows.Add([PSCustomObject]@{ Path = 'ENV:GITHUB_TOKEN(User)'; Kind = 'env'; GithubTokens = 1; TokenStatus = if ($st) { "hash $(Get-TokenFingerprint $envToken) HTTP $($st.Http)" } else { $null } })
  }
  return $rows
}

function Invoke-NetEnvSecretsVerify {
  param([switch]$Github = $true)
  return Invoke-NetEnvSecretsScan -Github:$Github | ForEach-Object {
    $_.Path + '  ->  ' + $(if ($_.TokenStatus) { $_.TokenStatus } else { "kind=$($_.Kind), tokens=$($_.GithubTokens)" })
  }
}

function Invoke-NetEnvSecretsArchive {
  param(
    [string]$Password,
    [string]$ArchiveDir
  )
  $cfg = Read-NetEnvConfig
  if (-not $ArchiveDir) { $ArchiveDir = $cfg.secrets.archiveDir }
  if (-not (Test-Path -LiteralPath $ArchiveDir)) { New-Item -ItemType Directory -Path $ArchiveDir -Force | Out-Null }
  if (-not $Password) {
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789#!%'
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] 20
    $rng.GetBytes($bytes)
    $sb = (New-Object Text.StringBuilder)
    foreach ($b in $bytes) { $null = $sb.Append($chars[$b % $chars.Length]) }
    $Password = $sb.ToString()
  }

  $staging = Join-Path $env:TEMP ("netenv-secrets-" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $staging | Out-Null
  $manifest = (New-Object System.Collections.Generic.List[object])
  $skipped = (New-Object System.Collections.Generic.List[object])
  try {
    foreach ($f in (Get-NetEnvSecretTargets)) {
      $name = (Split-Path $f -Leaf)
      $dest = Join-Path $staging $name
      if ((Split-Path $f -Parent) -eq (Join-Path $env:USERPROFILE 'Downloads')) { $dest = Join-Path $staging ("2FA-" + $name) }
      try {
        Copy-Item -LiteralPath $f -Destination $dest -Force -ErrorAction Stop
        $hash = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
        $manifest.Add([PSCustomObject]@{ name = $name; sha256 = $hash; size = (Get-Item -LiteralPath $dest).Length })
      } catch {
        $skipped.Add([PSCustomObject]@{ name = $name; reason = '复制失败(可能被占用)' })
      }
    }
    $envToken = [Environment]::GetEnvironmentVariable('GITHUB_TOKEN', 'User')
    if ($envToken) {
      Set-Content -LiteralPath (Join-Path $staging 'gh-env-token.txt') -Value $envToken -NoNewline -Encoding ascii
      $hash = (Get-FileHash -LiteralPath (Join-Path $staging 'gh-env-token.txt') -Algorithm SHA256).Hash
      $manifest.Add([PSCustomObject]@{ name = 'gh-env-token.txt'; sha256 = $hash; size = (Get-Item -LiteralPath (Join-Path $staging 'gh-env-token.txt')).Length })
    }
    $ghToken = (& gh auth token --hostname github.com 2>$null)
    if ($ghToken) {
      Set-Content -LiteralPath (Join-Path $staging 'gh-keyring-token.txt') -Value $ghToken -NoNewline -Encoding ascii
      $hash = (Get-FileHash -LiteralPath (Join-Path $staging 'gh-keyring-token.txt') -Algorithm SHA256).Hash
      $manifest.Add([PSCustomObject]@{ name = 'gh-keyring-token.txt'; sha256 = $hash; size = (Get-Item -LiteralPath (Join-Path $staging 'gh-keyring-token.txt')).Length })
    }

    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $archive = Join-Path $ArchiveDir "$($cfg.secrets.archivePrefix)-$ts.7z"
    $sevenZip = Get-NetEnvSevenZip
    if (-not $sevenZip) { throw '未找到 7z 可执行文件（请安装 7-Zip，或用已安装的 Bandizip）' }
    $zargs = Get-NetEnvArchiveArgs -Exe $sevenZip -Archive $archive -Source (Join-Path $staging '*') -Password $Password
    & $sevenZip @zargs | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $archive)) { throw "7z 打包失败（$sevenZip 退出码 $LASTEXITCODE）" }

    $manifestFile = Join-Path $ArchiveDir "$($cfg.secrets.archivePrefix)-$ts-manifest.json"
    # ToArray()：PS 5.1 下 @($List[object]) 会抛 "Argument types do not match"（见 doctor.ps1 同处注释）
    $manifestJson = @{ archive = $archive; generatedAt = (Get-Date -Format 's'); entries = $manifest.ToArray(); skipped = $skipped.ToArray() } | ConvertTo-Json -Depth 3
    Save-NetEnvTextFile -Path $manifestFile -Content $manifestJson

    Write-NetEnvLog 'INFO' "secrets archive 已生成: $archive（$($manifest.Count) 项，密码不落盘）"
    return [PSCustomObject]@{
      Archive = $archive
      Manifest = $manifestFile
      Entries = $manifest.Count
      Skipped = $skipped.Count
      Password = $Password
    }
  } finally {
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

function Invoke-NetEnvSecretsPurge {
  param([switch]$GithubExpired)
  if (-not $GithubExpired) { throw "purge 只支持 --github-expired（其他清理请先归档）" }
  $cfg = Read-NetEnvConfig
  $report = (New-Object System.Collections.Generic.List[object])
  foreach ($f in (Get-NetEnvSecretTargets)) {
    # 文件可能被占用/无权限：必须逐项跳过，不能让 purge 整体中断
    $raw = ''
    try { $raw = Read-NetEnvFileText $f } catch { continue }
    if (-not $raw) { continue }
    $tokens = [regex]::Matches($raw, $script:GithubTokenPattern)
    $badTokens = @()
    foreach ($m in $tokens) {
      $st = Get-GithubTokenStatus $m.Value
      if (-not $st.Valid) {
        if ($badTokens -notcontains $m.Value) { $badTokens += $m.Value }
      }
    }
    if ($badTokens.Count -gt 0) {
      $backupDir = Join-Path (Get-NetEnvPaths).Backups 'secrets-purge'
      if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
      $bak = Join-Path $backupDir ((Split-Path $f -Leaf) + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
      Copy-Item -LiteralPath $f -Destination $bak -Force
      $new = $raw
      foreach ($bad in $badTokens) { $new = $new.Replace($bad, '') }
      # BOM-less 原子写：Set-Content -Encoding utf8 在 5.1 会加 BOM，改坏 .env/.credentials.yaml 的消费者
      Save-NetEnvTextFile -Path $f -Content $new
      $report.Add([PSCustomObject]@{ Path = $f; Removed = $badTokens.Count; Backup = $bak })
    }
  }
  $envToken = [Environment]::GetEnvironmentVariable('GITHUB_TOKEN', 'User')
  if ($envToken) {
    $st = Get-GithubTokenStatus $envToken
    if (-not $st.Valid) {
      [Environment]::SetEnvironmentVariable('GITHUB_TOKEN', $null, 'User')
      $report.Add([PSCustomObject]@{ Path = 'ENV:GITHUB_TOKEN(User)'; Removed = 1; Backup = '归档中已含原值' })
    }
  }
  Write-NetEnvLog 'INFO' "secrets purge: 清理 $($report.Count) 处无效 token"
  return $report
}
