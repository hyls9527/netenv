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
      $asset = $release.assets | Where-Object { $_.name -match '(windows-amd64|windows_x86_64)' -and $_.name -match '(\.exe$|\.zip$)' } | Select-Object -First 1
      if (-not $asset) { throw "未找到适配的 Windows 资产" }
      $mirrors = @(
        "https://gh-proxy.com/" + $asset.browser_download_url,
        "https://ghfast.top/" + $asset.browser_download_url,
        $asset.browser_download_url
      )
      $ok = $false
      foreach ($m in $mirrors) {
        try {
          Invoke-WebRequest -Uri $m -OutFile $dest -UseBasicParsing -TimeoutSec 300
          $ok = $true; break
        } catch { }
      }
      if (-not $ok) { throw '所有镜像下载失败' }
      if ($asset.name -like '*.zip') {
        Expand-Archive -LiteralPath $dest -DestinationPath $paths.Bin -Force
        Remove-Item -LiteralPath $dest -Force
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
