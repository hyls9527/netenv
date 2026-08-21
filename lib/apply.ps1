. "$PSScriptRoot\core.ps1"

function Invoke-NetEnvApply {
  param(
    [ValidateSet('direct','proxy','github')][string]$Profile,
    [switch]$Undo,
    [string]$SnapshotFile
  )
  $cfg = Read-NetEnvConfig
  if (-not ($cfg.profiles.PSObject.Properties.Name -contains $Profile)) { throw "未知 profile: $Profile" }

  if ($Undo) {
    if (-not $SnapshotFile) {
      $snaps = Get-ChildItem -LiteralPath (Join-Path (Get-NetEnvPaths).Backups 'snapshots') -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
      if (-not $snaps) { throw '没有可用快照' }
      $SnapshotFile = $snaps[0].FullName
    }
    $snap = Get-NetEnvSnapshot $SnapshotFile
    Write-Host "回滚到快照: $(Split-Path $SnapshotFile -Leaf)（注意：快照之后的手动修改会被覆盖）"
    Set-NetEnvProxyReg $snap.proxy.ProxyEnable $snap.proxy.ProxyServer $snap.proxy.ProxyOverride
    Set-NetEnvGitProxy $snap.gitProxy
    foreach ($n in 'HTTP_PROXY','HTTPS_PROXY','NO_PROXY') {
      [Environment]::SetEnvironmentVariable($n, $snap.env.$n, 'User')
    }
    Write-NetEnvLog 'INFO' "apply --undo 使用快照 $SnapshotFile"
    return '已回滚'
  }

  $profile = $cfg.profiles.$Profile
  $snapFile = Save-NetEnvSnapshot -Label "apply-$Profile"

  $proxyServer = if ($profile.systemProxy) { 'http=127.0.0.1:7897;https=127.0.0.1:7897' } else { $null }
  $override = if ($profile.systemProxy) { ($cfg.noProxy -join ';') } else { $null }
  Set-NetEnvProxyReg ([int][bool]$profile.systemProxy) $proxyServer $override
  Set-NetEnvGitProxy $profile.gitProxy

  $npmProxy = if ($profile.npmProxy) { $profile.npmProxy } else { 'null' }
  npm config set proxy $npmProxy 2>$null | Out-Null
  npm config set https-proxy $npmProxy 2>$null | Out-Null

  foreach ($n in 'HTTP_PROXY','HTTPS_PROXY') {
    $val = if ($profile.envProxy) { 'http://127.0.0.1:7897' } else { $null }
    [Environment]::SetEnvironmentVariable($n, $val, 'User')
  }
  $noProxyVal = if ($profile.envProxy) { ($cfg.noProxy -join ',') } else { $null }
  [Environment]::SetEnvironmentVariable('NO_PROXY', $noProxyVal, 'User')

  Write-NetEnvLog 'INFO' "apply profile=$Profile 完成, 快照 $snapFile"
  "profile=$Profile 已应用。快照: $snapFile`n提示：已运行的程序需重启才会读取新的环境变量。"
}

function Set-NetEnvProxyReg {
  param([int]$Enable, [string]$Server, [string]$Override)
  $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
  Set-ItemProperty -Path $path -Name ProxyEnable -Value $Enable
  Set-ItemProperty -Path $path -Name ProxyServer -Value $Server
  Set-ItemProperty -Path $path -Name ProxyOverride -Value $Override
}

function Set-NetEnvGitProxy {
  param([string]$Proxy)
  if ($Proxy) { git config --global http.proxy $Proxy } else { git config --global --unset http.proxy 2>$null }
}
