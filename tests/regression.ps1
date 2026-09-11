param([switch]$Live)
$ErrorActionPreference = 'Stop'

if ($Live) {
  $root = Split-Path -Parent $PSScriptRoot
  $netenv = Join-Path $root 'netenv.ps1'
  $mihomo = Join-Path $root 'data\bin\mihomo-windows-amd64.exe'
  $dataDir = Join-Path $root 'data'
  $reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
  $proc = $null
  try {
    if (-not (Test-Path -LiteralPath $mihomo)) { throw 'mihomo binary missing' }
    $cfg = Join-Path $dataDir 'test-mihomo.yaml'
    if (-not (Test-Path -LiteralPath $cfg)) {
      Set-Content -LiteralPath $cfg -Value "port: 7897`nmode: rule`nlog-level: silent`nipv6: false`nrules:`n  - MATCH,DIRECT" -Encoding utf8
    }
    $proc = Start-Process -FilePath $mihomo -ArgumentList @('-d', ('"' + $dataDir + '"'), '-f', ('"' + $cfg + '"')) -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 3
    $listening = [bool](Get-NetTCPConnection -State Listen -LocalPort 7897 -ErrorAction SilentlyContinue)
    Write-Host ("[live] mihomo 7897 listening={0} pid={1}" -f $listening, $proc.Id)
    if (-not $listening) { throw 'mihomo not listening' }
    & pwsh -NoProfile -File $netenv apply -profile proxy | Out-Host
    $ie = Get-ItemProperty -Path $reg
    Write-Host ("[live] proxy={0} git={1}" -f $ie.ProxyServer, (git config --global --get http.proxy))
    $r = Invoke-WebRequest -Uri 'http://www.baidu.com' -UseBasicParsing -TimeoutSec 15
    Write-Host ("[live] baidu HTTP {0} OK" -f $r.StatusCode)
  } finally {
    if ($proc -and -not $proc.HasExited) {
      & pwsh -NoProfile -File $netenv apply --undo | Out-Host
      Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
      Start-Sleep -Seconds 1
    }
  }
  Write-Host '[live] smoke passed'
  exit 0
}

Import-Module Pester
$testPath = Join-Path $PSScriptRoot 'netenv.tests.ps1'
$allOk = $true
foreach ($round in 1..3) {
  $r = Invoke-Pester -Path $testPath -PassThru
  Write-Host ("round {0}: Passed={1} Failed={2}" -f $round, $r.PassedCount, $r.FailedCount)
  if ($r.FailedCount -gt 0) { $allOk = $false }
}
if (-not $allOk) { exit 1 }
Write-Host 'regression: all rounds passed'
