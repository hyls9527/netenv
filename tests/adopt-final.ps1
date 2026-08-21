$ErrorActionPreference = 'Continue'
$root = 'C:\Users\Admin\Desktop\Vibe coding\netenv'
$status = Join-Path $root 'data\adopt-final.status'
Set-Content -LiteralPath $status -Value 'start'
function Step { param([string]$Text) Add-Content -LiteralPath $status -Value ((Get-Date -Format 'HH:mm:ss') + ' ' + $Text) }

$action = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument ("-NoProfile -File `"$root\lib\supervisor.ps1`"")
$trigger = New-ScheduledTaskTrigger -AtStartup
$trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)).Repetition
Register-ScheduledTask -TaskName 'NetEnv-Supervisor' -Action $action -Trigger $trigger -RunLevel Highest -Force | Out-Null
Step 'supervisor registered AtStartup'
$st = Get-ScheduledTask -TaskName 'NetEnv-Supervisor' -ErrorAction SilentlyContinue
if ($st) { Step ('trigger=' + $st.Triggers[0].CimClass.CimClassName + ' enabled=' + $st.Triggers[0].Enabled) }

$ga = git -C $root add -A 2>&1 | Out-String
Add-Content -LiteralPath $status -Value $ga
$gc = git -C $root commit -m "feat: adopt 接管网络栈，GitHub 网页可走机场；supervisor 开机自启；修复参数丢失与旧栈残留" 2>&1 | Out-String
Add-Content -LiteralPath $status -Value $gc
Step ('git commit exit=' + $LASTEXITCODE)

if (Test-Path -LiteralPath 'C:\Users\Admin\Desktop\Vibe coding\_tmp_openai_overwall') {
  try {
    Remove-Item -LiteralPath 'C:\Users\Admin\Desktop\Vibe coding\_tmp_openai_overwall' -Recurse -Force -ErrorAction Stop
    Step 'removed _tmp_openai_overwall'
  } catch { Step ('FAIL remove overwall: ' + $_.Exception.Message) }
} else { Step 'overwall absent' }

if (Test-Path -LiteralPath 'C:\Users\Admin\.dev-sidecar') {
  $bak = Join-Path $root 'backups\oldstack-devsidecar-20260821'
  Move-Item -LiteralPath 'C:\Users\Admin\.dev-sidecar' -Destination $bak -Force
  Step ('moved .dev-sidecar to ' + $bak)
} else { Step 'dev-sidecar absent' }

foreach ($rp in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run') {
  $props = Get-ItemProperty -Path $rp -ErrorAction SilentlyContinue
  if (-not $props) { continue }
  foreach ($nm in $props.PSObject.Properties.Name) {
    if ($nm -in 'PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider') { continue }
    if ($props.$nm -match 'overwall|dev-sidecar|guardian|free.?proxy|voice.?chatgpt|dsh|gemini|tfg') {
      Remove-ItemProperty -Path $rp -Name $nm -ErrorAction SilentlyContinue
      Step ('removed Run key: ' + $nm)
    }
  }
}

if (Test-Path -LiteralPath 'C:\Users\Admin\Desktop\Vibe coding\netenv\data\verify-api.zip') {
  Remove-Item -LiteralPath 'C:\Users\Admin\Desktop\Vibe coding\netenv\data\verify-api.zip' -Force
  Step 'removed verify-api.zip'
}
Step 'done'
