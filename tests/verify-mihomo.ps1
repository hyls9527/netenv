$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$bin = Join-Path $root 'data\bin'
$tmp = Join-Path $env:TEMP 'mihomo-official.zip'
$job = Start-Job -ScriptBlock {
  param($binDir, $outZip)
  & gh release download v1.19.30 --repo MetaCubeX/mihomo --pattern 'mihomo-windows-amd64-v1.19.30.zip' --dir $binDir --clobber
  if (Test-Path -LiteralPath (Join-Path $binDir 'mihomo-windows-amd64-v1.19.30.zip')) {
    Move-Item -LiteralPath (Join-Path $binDir 'mihomo-windows-amd64-v1.19.30.zip') -Destination $outZip -Force
  }
} -ArgumentList $bin, $tmp
if (Wait-Job $job -Timeout 120) {
  Receive-Job $job | Out-Host
} else {
  Write-Host '[verify] gh release download timed out'
}
Stop-Job $job -ErrorAction SilentlyContinue
Remove-Job $job -Force -ErrorAction SilentlyContinue

if (Test-Path -LiteralPath $tmp) {
  $size = (Get-Item -LiteralPath $tmp).Length
  Write-Host ("[verify] official zip size={0}" -f $size)
  if ($size -gt 5000000) {
    $extract = Join-Path $env:TEMP ('mihomo-x-' + [guid]::NewGuid().ToString('N').Substring(0,6))
    Expand-Archive -LiteralPath $tmp -DestinationPath $extract -Force
    $exe = Get-ChildItem -LiteralPath $extract -Recurse -Filter '*.exe' | Select-Object -First 1
    $officialHash = (Get-FileHash -LiteralPath $exe.FullName -Algorithm SHA256).Hash
    $stored = (Get-Content -LiteralPath (Join-Path $bin 'mihomo-windows-amd64.exe.sha256') -Raw).Trim()
    Write-Host ("[verify] official exe sha256={0}" -f $officialHash)
    Write-Host ("[verify] stored sha256={0}" -f $stored)
    Write-Host ("[verify] match={0}" -f ($officialHash -eq $stored))
    Remove-Item -LiteralPath $extract -Recurse -Force
  }
  Remove-Item -LiteralPath $tmp -Force
} else {
  Write-Host '[verify] no official zip obtained'
}
