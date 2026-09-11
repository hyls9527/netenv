[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\core.ps1"

# 周期自愈循环：每 intervalMinutes 探活一次；计划任务不可用时由启动文件夹的
# run-supervisor-hidden.vbs 拉起，等效于 NetEnv-Supervisor-Periodic。
$cfg = Read-NetEnvConfig
$interval = [int]$cfg.supervisor.intervalMinutes
if ($interval -lt 1) { $interval = 1 }
Write-NetEnvLog 'INFO' "supervisor-loop: 启动，周期 $interval 分钟"

while ($true) {
  try {
    & "$PSScriptRoot\supervisor.ps1"
  } catch {
    Write-NetEnvLog 'ERROR' "supervisor-loop: 单轮异常 $_"
  }
  Start-Sleep -Seconds ($interval * 60)
}
