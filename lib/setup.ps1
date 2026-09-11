. "$PSScriptRoot\core.ps1"
. "$PSScriptRoot\doctor.ps1"
. "$PSScriptRoot\apply.ps1"
. "$PSScriptRoot\nodes.ps1"
. "$PSScriptRoot\clients.ps1"

function Invoke-NetEnvInstall {
  param([switch]$Autostart)
  $src = Get-NetEnvRoot
  $dest = Join-Path $env:LOCALAPPDATA 'NetEnv'
  robocopy $src $dest /E /XD data logs backups export .git config tests /XF *.pdb | Out-Null
  # robocopy 显式排除了 config，但 installed 模式读的正是 $dest\config\netenv.json，
  # 首次安装若不补种，脚本会因配置不存在直接失败。重复安装保留本机改动（只补缺）。
  $destCfgDir = Join-Path $dest 'config'
  New-Item -ItemType Directory -Path $destCfgDir -Force | Out-Null
  foreach ($n in 'netenv.json', 'sources.json', 'clients.json') {
    $to = Join-Path $destCfgDir $n
    if (-not (Test-Path -LiteralPath $to)) { Copy-Item -LiteralPath (Join-Path $src ("config\" + $n)) -Destination $to -Force }
  }
  $localCfg = Join-Path $destCfgDir 'netenv.json'
  $cfg = (Read-NetEnvFileText $localCfg) | ConvertFrom-Json
  $cfg.mode = 'installed'
  Save-NetEnvTextFile -Path $localCfg -Content ($cfg | ConvertTo-Json -Depth 6)
  if ($Autostart) {
    if (-not (Test-IsAdmin)) { throw 'install --autostart 需要管理员权限（注册计划任务）。已复制文件；请用管理员重跑，或改用启动文件夹方案。' }
    # 用 wscript + VBS 零窗口启动器，而不是 pwsh.exe：
    # 1) 计划任务的 Execute 按系统 PATH 解析，PATH 里没有 pwsh.exe 时任务每次静默失败（实测本机 pwsh 装在 Program Files 但不在 PATH）；
    # 2) powershell -WindowStyle Hidden 仍会闪 conhost 窗口。
    $vbs = Join-Path $dest 'lib\run-supervisor-hidden.vbs'
    if (-not (Test-Path -LiteralPath $vbs)) { throw "缺少零窗口启动器: $vbs" }
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $vbs + '"')
    $principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$env:USERNAME" -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
    # 开机任务只负责拉起第一次；周期任务是"循环意外退出"的补拉网（VBS 内有单实例守卫，不会起两个循环）。
    Register-ScheduledTask -TaskName 'NetEnv-Supervisor' -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) -Principal $principal -Settings $settings -Force | Out-Null
    $periodic = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
    Register-ScheduledTask -TaskName 'NetEnv-Supervisor-Periodic' -Action $action -Trigger $periodic -Principal $principal -Settings $settings -Force | Out-Null
  }
  Write-NetEnvLog 'INFO' "install 完成: $dest"
  "已安装到 $dest（卸载: netenv uninstall）"
}

function Invoke-NetEnvUninstall {
  foreach ($t in 'NetEnv-Supervisor', 'NetEnv-Supervisor-Periodic') {
    Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
  }
  $dest = Join-Path $env:LOCALAPPDATA 'NetEnv'
  # 先停掉从安装目录启动的自愈循环：脚本被移走后它会继续按旧路径拉起 mihomo/new-api
  if (Test-Path -LiteralPath $dest) {
    $pat = [regex]::Escape((Join-Path $dest 'lib\supervisor-loop.ps1'))
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine -match $pat } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  }
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
