$ErrorActionPreference = 'Continue'
$root = 'C:\Users\Admin\Desktop\Vibe coding\netenv'
$status = Join-Path $root 'data\commit2.status'
git -C $root add -A 2>&1 | Out-String | Add-Content -LiteralPath $status
git -C $root commit -m "perf: supervisor 探活间隔缩短至 1 分钟，代理故障更快自愈" 2>&1 | Out-String | Add-Content -LiteralPath $status
Add-Content -LiteralPath $status -Value ("exit=" + $LASTEXITCODE)
