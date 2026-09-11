# fix-boot-task.ps1 - MUST run as Administrator
# Fixes NetEnv-Supervisor boot task:
#   1. removes stray 5-min Repetition (duplicates NetEnv-Supervisor-Periodic, causes double supervisor runs + log races)
#   2. switches action to wscript zero-window launcher (powershell -WindowStyle Hidden still flashes a conhost window)
# Run: right-click -> Run with PowerShell under admin, or from elevated terminal: powershell -File fix-boot-task.ps1

$vbs = Join-Path $PSScriptRoot 'run-supervisor-hidden.vbs'
$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $vbs + '"')
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$env:USERNAME" -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName 'NetEnv-Supervisor' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Write-Host 'NetEnv-Supervisor rebuilt: boot-only trigger, wscript zero-window launcher.'
Export-ScheduledTask -TaskName 'NetEnv-Supervisor' | Select-String -Pattern 'Repetition|BootTrigger|wscript|Command'
