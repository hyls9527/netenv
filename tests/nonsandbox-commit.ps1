param([string]$MessageFile, [switch]$Amend)
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$log = Join-Path $env:TEMP 'netenv-commit.log'
$msg = if (Test-Path -LiteralPath $MessageFile) { [System.IO.File]::ReadAllText($MessageFile).Trim() } else { 'chore: update' }
git -C $root add -A 2>&1 | Out-String | Set-Content -LiteralPath $log
if ($Amend) {
  git -C $root commit --amend -m $msg 2>&1 | Out-String | Add-Content -LiteralPath $log
} else {
  git -C $root commit -m $msg 2>&1 | Out-String | Add-Content -LiteralPath $log
}
Add-Content -LiteralPath $log -Value ("exit=" + $LASTEXITCODE)
