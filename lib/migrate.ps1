. "$PSScriptRoot\core.ps1"

function Invoke-NetEnvMigrate {
  $paths = Get-NetEnvPaths
  $hostName = $env:COMPUTERNAME
  $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
  $export = Join-Path $paths.Root "export\$hostName-$ts"
  New-Item -ItemType Directory -Path $export -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $paths.ConfigDir 'netenv.json') -Destination $export
  Copy-Item -LiteralPath (Join-Path $paths.ConfigDir 'sources.json') -Destination $export
  Copy-Item -LiteralPath (Join-Path $paths.ConfigDir 'clients.json') -Destination $export
  Copy-Item -LiteralPath (Join-Path $paths.Root 'docs') -Destination $export -Recurse
  $dsc = @"
properties:
  resources:
    - resource: Microsoft.WinGet.DSC/WinGetPackage
      id: ClashVergeRev
      directives:
        description: 代理客户端（唯一入口）
      settings:
        id: ClashVergeRev.ClashVergeRev
    - resource: Microsoft.WinGet.DSC/WinGetPackage
      id: 7Zip
      directives:
        description: 密钥归档加密
      settings:
        id: 7zip.7zip
  configurationVersion: 0.2.0
"@
  Set-Content -LiteralPath (Join-Path $export 'configuration.winget') -Value $dsc -Encoding utf8
  @{
    host = $hostName
    exportedAt = (Get-Date -Format 's')
    credentialNote = '订阅 URL（NetEnv/sub-*）、GitHub 凭据、AI Key 均不随包导出；新机请用 netenv config set-secret 与 gh auth login 重新录入。'
  } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $export 'manifest.json') -Encoding utf8
  Write-NetEnvLog 'INFO' "migrate 导出: $export"
  return $export
}
