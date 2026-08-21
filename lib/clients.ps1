. "$PSScriptRoot\core.ps1"

function Invoke-NetEnvClientsCheck {
  $rows = [System.Collections.Generic.List[object]]::new()
  foreach ($c in (Read-NetEnvJson -Name 'clients')) {
    $ok = $false
    $detail = ''
    try {
      $resp = Invoke-WebRequest -Uri ($c.baseUrl + '/models') -UseBasicParsing -TimeoutSec 5
      $ok = ($resp.StatusCode -eq 200 -or $resp.StatusCode -eq 401)
      $detail = "HTTP $($resp.StatusCode)"
    } catch {
      $code = $_.Exception.Response.StatusCode.value__
      if ($code -in 401, 403, 404) { $ok = $true; $detail = "HTTP $code（端点可达，需鉴权）" }
      else { $detail = "不可达: $($_.Exception.Message)" }
    }
    $rows.Add([PSCustomObject]@{ client = $c.name; baseUrl = $c.baseUrl; ok = $ok; detail = $detail })
  }
  return $rows
}

function Invoke-NetEnvClientsApply {
  $cfg = Read-NetEnvConfig
  $written = [System.Collections.Generic.List[string]]::new()
  foreach ($c in (Read-NetEnvJson -Name 'clients')) {
    foreach ($p in $c.configPaths) {
      if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
      $dir = Split-Path $p -Parent
      $envFile = Join-Path $dir 'NetEnv.env'
      $content = @"
# NetEnv 注入（自动生成，勿手改；由 netenv clients apply 维护）
HTTP_PROXY=http://127.0.0.1:7897
HTTPS_PROXY=http://127.0.0.1:7897
NO_PROXY=$($cfg.noProxy -join ',')
NETENV_BASE_URL=$($c.baseUrl)
"@
      $bak = "$envFile.bak"
      if (Test-Path -LiteralPath $envFile) { Copy-Item -LiteralPath $envFile -Destination $bak -Force }
      Set-Content -LiteralPath $envFile -Value $content -Encoding utf8
      $written.Add($envFile)
    }
  }
  Write-NetEnvLog 'INFO' "clients apply: 写入 $($written.Count) 个注入文件"
  "已写入注入配置:`n" + ($written -join "`n") + "`n提示：客户端需重启才能生效。"
}
