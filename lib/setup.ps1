. "$PSScriptRoot\core.ps1"
. "$PSScriptRoot\doctor.ps1"
. "$PSScriptRoot\apply.ps1"
. "$PSScriptRoot\nodes.ps1"
. "$PSScriptRoot\clients.ps1"

function Invoke-NetEnvInstall {
  param([switch]$Autostart)
  $src = Get-NetEnvRoot
  $dest = Join-Path $env:LOCALAPPDATA 'NetEnv'
  robocopy $src $dest /E /XD data logs backups export .git config /XF *.pdb | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $dest 'config') -Force | Out-Null
  $localCfg = Join-Path $dest 'config\netenv.json'
  $cfg = Get-Content -LiteralPath $localCfg -Raw | ConvertFrom-Json
  $cfg.mode = 'installed'
  $cfg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $localCfg -Encoding utf8
  if ($Autostart) {
    $action = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument "-NoProfile -File `"$dest\lib\supervisor.ps1`""
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName 'NetEnv-Supervisor' -Action $action -Trigger $trigger -RunLevel Highest -Force | Out-Null
  }
  Write-NetEnvLog 'INFO' "install 完成: $dest"
  "已安装到 $dest（卸载: netenv uninstall）"
}

function Invoke-NetEnvUninstall {
  Unregister-ScheduledTask -TaskName 'NetEnv-Supervisor' -Confirm:$false -ErrorAction SilentlyContinue
  $dest = Join-Path $env:LOCALAPPDATA 'NetEnv'
  if (Test-Path -LiteralPath $dest) {
    $bak = "$dest.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Move-Item -LiteralPath $dest -Destination $bak
    "已移除。配置备份保留在: $bak"
  }
  "uninstall 完成（系统代理/git/npm 残留请用 netenv apply --undo 回滚）"
}

function Invoke-NetEnvSetup {
  param([switch]$Apply)
  if (-not $Apply) { throw 'setup 会安装程序并修改系统设置，请加 -Apply 确认执行' }
  Invoke-NetEnvBootstrap
  Invoke-NetEnvInstall -Autostart
  Invoke-NetEnvApply -Profile proxy
  Invoke-NetEnvNodesRefresh | Out-Null
  Invoke-NetEnvClientsApply
  Invoke-NetEnvDoctor -NoExit
}
