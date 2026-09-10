. "$PSScriptRoot\core.ps1"
. "$PSScriptRoot\clients.ps1"

function Invoke-NetEnvAdopt {
  param([switch]$Apply, [switch]$Undo, [string]$Password, [string]$ReportFile)
  $cfg = Read-NetEnvConfig
  $paths = Get-NetEnvPaths
  $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
  if (-not $ReportFile) { $ReportFile = Join-Path $paths.Data "adopt-report-$ts.json" }

  if ($Undo) {
    if (-not (Test-Path -LiteralPath $ReportFile)) { throw "报告不存在: $ReportFile" }
    $rep = Get-Content -LiteralPath $ReportFile -Raw | ConvertFrom-Json
    foreach ($t in $rep.taskBackups) {
      if (Test-Path -LiteralPath $t.xml) {
        Register-ScheduledTask -TaskName $t.name -Xml (Get-Content -LiteralPath $t.xml -Raw) -Force | Out-Null
      }
    }
    foreach ($s in $rep.startupBackups) {
      if (Test-Path -LiteralPath $s.backup) { Move-Item -LiteralPath $s.backup -Destination $s.original -Force }
    }
    Write-NetEnvLog 'INFO' "adopt --undo 恢复任务/启动项（归档文件不自动还原）"
    return "已按 $ReportFile 恢复。归档文件需手动还原。"
  }

  $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $cfg.guardianTasks -contains $_.TaskName -and $_.State -ne 'Disabled' }
  $startupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
  $startups = $cfg.startupItems | Where-Object { Test-Path -LiteralPath (Join-Path $startupDir $_) }
  $oldProcs = @()
  foreach ($proc in (Get-CimInstance Win32_Process)) {
    if ($proc.CommandLine -and $proc.CommandLine -match 'netenv\\data\\bin') { continue }
    foreach ($pat in $cfg.oldProcesses) {
      $namePat = ($pat -split '[\\/]')[-1]
      $hit = ($proc.CommandLine -and $proc.CommandLine -like "*$pat*") -or ($namePat -and $proc.Name -like "*$namePat*")
      if ($hit) { $oldProcs += $proc; break }
    }
  }
  $clientRows = Invoke-NetEnvClientsCheck

  $report = [ordered]@{
    time = (Get-Date -Format 's')
    dryRun = (-not $Apply)
    guardianTasks = @($tasks | ForEach-Object { @{ name = $_.TaskName; state = $_.State } })
    startupItems = @($startups)
    oldProcesses = @($oldProcs | ForEach-Object { @{ pid = $_.ProcessId; name = $_.Name; cmd = $_.CommandLine } })
    clients = @($clientRows)
    overwallArchive = $null
    taskBackups = @()
    startupBackups = @()
  }

  if ($Apply) {
    if (-not (Test-IsAdmin)) { throw 'adopt -Apply 需要管理员权限' }
    $overwall = Join-Path (Get-NetEnvRoot) '_tmp_openai_overwall'
    if (Test-Path -LiteralPath $overwall) {
      if (-not $Password) {
        $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789#!%'
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $bytes = New-Object byte[] 20; $rng.GetBytes($bytes)
        $sb = [Text.StringBuilder]::new(); foreach ($b in $bytes) { $null = $sb.Append($chars[$b % $chars.Length]) }
        $Password = $sb.ToString()
      }
      $archive = Join-Path $paths.Backups "adopt-overwall-$ts.7z"
      $sevenZip = 'C:\Program Files\7-Zip\7z.exe'
      & $sevenZip a -t7z "-p$Password" -mhe=on $archive "$overwall\*" | Out-Null
      $report.overwallArchive = $archive
    }
    foreach ($p in $oldProcs) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    $taskBackupDir = Join-Path $paths.Backups 'tasks'
    New-Item -ItemType Directory -Path $taskBackupDir -Force | Out-Null
    foreach ($t in $tasks) {
      $xml = Join-Path $taskBackupDir "$($t.TaskName).xml"
      Export-ScheduledTask -TaskName $t.TaskName | Set-Content -LiteralPath $xml -Encoding utf8
      Unregister-ScheduledTask -TaskName $t.TaskName -Confirm:$false
      $report.taskBackups += @{ name = $t.TaskName; xml = $xml }
    }
    $startupBackupDir = Join-Path $paths.Backups 'startup'
    New-Item -ItemType Directory -Path $startupBackupDir -Force | Out-Null
    foreach ($s in $startups) {
      $src = Join-Path $startupDir $s
      $bak = Join-Path $startupBackupDir $s
      Move-Item -LiteralPath $src -Destination $bak -Force
      $report.startupBackups += @{ original = $src; backup = $bak }
    }
    Invoke-NetEnvClientsApply | Out-Null
    $report.dryRun = $false
  }

  $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ReportFile -Encoding utf8
  Write-NetEnvLog 'INFO' "adopt $(if ($Apply) {'执行'} else {'dry-run'}) 完成: $ReportFile"
  if ($Apply) { "adopt 已执行。归档密码（仅显示一次，请抄录）: $Password" }
  return $ReportFile
}
