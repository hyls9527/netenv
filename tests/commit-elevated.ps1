$ErrorActionPreference = 'Continue'
$root = 'C:\Users\Admin\Desktop\Vibe coding\netenv'
$status = Join-Path $root 'data\commit-elevated.status'
git -C $root add -A 2>&1 | Out-String | Add-Content -LiteralPath $status
git -C $root commit -m "fix: auto-select 剔除 DIRECT，GEOIP 国内直连，geoip 自动下载" 2>&1 | Out-String | Add-Content -LiteralPath $status
Add-Content -LiteralPath $status -Value ("exit=" + $LASTEXITCODE)
