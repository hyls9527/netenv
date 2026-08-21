. "$PSScriptRoot\core.ps1"

function Invoke-NetEnvBootstrap {
  param([switch]$Force)
  $cfg = Read-NetEnvConfig
  $paths = Get-NetEnvPaths
  if (-not (Test-Path -LiteralPath $paths.Bin)) { New-Item -ItemType Directory -Path $paths.Bin -Force | Out-Null }
  $results = [System.Collections.Generic.List[object]]::new()
  foreach ($key in 'mihomo','newApi') {
    $bin = $cfg.binaries.$key
    $dest = Join-Path $paths.Bin $bin.filename
    if ((Test-Path -LiteralPath $dest) -and -not $Force) { $results.Add("$key 已存在，跳过"); continue }
    try {
      $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$($bin.source)/releases/latest" -Headers @{ 'User-Agent' = 'netenv' } -TimeoutSec 30
      $asset = $null
      if ($bin.assetPattern) {
        $asset = $release.assets | Where-Object { $_.name -match $bin.assetPattern } | Sort-Object name | Select-Object -First 1
      }
      if (-not $asset -and $key -eq 'newApi') {
        $asset = $release.assets | Where-Object { $_.name -match '\.exe$' -and $_.name -notmatch 'macos|arm64' } | Select-Object -First 1
      }
      if (-not $asset -and $key -eq 'mihomo') {
        $asset = $release.assets | Where-Object { $_.name -match 'windows-amd64.*\.zip$' } | Sort-Object name | Select-Object -First 1
      }
      if (-not $asset) { throw "未找到适配的 Windows 资产" }
      $mirrors = @(
        ("https://gh-proxy.com/" + $asset.browser_download_url),
        ("https://ghfast.top/" + $asset.browser_download_url),
        $asset.browser_download_url
      )
      $ok = $false
      $lastErr = ''
      $downloadPath = if ($asset.name -like '*.zip') { Join-Path $paths.Bin $asset.name } else { $dest }
      foreach ($m in $mirrors) {
        try {
          $errFile = Join-Path $paths.Logs 'bootstrap-curl.err'
          Set-Content -LiteralPath $errFile -Value ("URL=" + $m)
          & curl.exe -sSL --fail --retry 2 --connect-timeout 15 --max-time 90 -o $downloadPath $m 2>> $errFile
          if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $downloadPath) -and (Get-Item -LiteralPath $downloadPath).Length -gt 5000000) {
            $ok = $true; break
          }
          $curlErr = if (Test-Path -LiteralPath $errFile) { (Get-Content -LiteralPath $errFile -Raw) } else { '' }
          $lastErr = "curl exit=$LASTEXITCODE $curlErr"
        } catch { $lastErr = $_.Exception.Message }
      }
      if (-not $ok -and $release.tag_name) {
        try {
          $job = Start-Job -ScriptBlock {
            param($repo, $pattern, $dir, $tag)
            gh release download $tag --repo $repo --pattern $pattern --dir $dir --clobber 2>$null
          } -ArgumentList $bin.source, $bin.assetPattern, $paths.Bin, $release.tag_name
          if (Wait-Job $job -Timeout 120) {
            $null = Receive-Job $job
          }
          Stop-Job $job -ErrorAction SilentlyContinue
          Remove-Job $job -Force -ErrorAction SilentlyContinue
        } catch { }
      }
      if ($asset.name -like '*.zip') {
        if (-not (Test-Path -LiteralPath $downloadPath) -or (Get-Item -LiteralPath $downloadPath).Length -lt 5000000) { throw "zip 未下载成功(镜像与 gh 通道均失败: $lastErr)" }
        $extractDir = Join-Path $paths.Bin ("_extract-" + [guid]::NewGuid().ToString('N').Substring(0,8))
        Expand-Archive -LiteralPath $downloadPath -DestinationPath $extractDir -Force
        Remove-Item -LiteralPath $downloadPath -Force
        $found = Get-ChildItem -LiteralPath $extractDir -Recurse -Filter '*.exe' | Select-Object -First 1
        if ($found) {
          if ($found.Length -lt 1000000) { throw '解包出的 exe 过小（疑似 HTML 错误页）' }
          Move-Item -LiteralPath $found.FullName -Destination $dest -Force
          Remove-Item -LiteralPath $extractDir -Recurse -Force
        } else {
          throw 'zip 内未找到 exe'
        }
      } else {
        if (-not (Test-Path -LiteralPath $dest) -or (Get-Item -LiteralPath $dest).Length -lt 1000000) { throw "exe 未下载成功: $lastErr" }
      }
      $exe = Join-Path $paths.Bin $bin.filename
      $hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
      Set-Content -LiteralPath "$exe.sha256" -Value $hash -Encoding ascii
      $results.Add("$key OK sha256=$($hash.Substring(0,12))…")
      Write-NetEnvLog 'INFO' "bootstrap ${key}: $($asset.name) $hash"
    } catch {
      $results.Add("$key 失败: $($_.Exception.Message)")
    }
  }
  $results.Add('subStore 提示: Sub-Store 需 Node 运行，bootstrap 不下载 exe，见 docs/README.md')
  return $results
}
