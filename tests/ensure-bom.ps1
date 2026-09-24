# 确保仓库内所有 .ps1 都带 UTF-8 BOM。
#
# 为什么需要它：编辑工具（含 AI 代理的 edit/write）常常顺手剥掉 BOM，而本仓库脚本含中文，
# Windows PowerShell 5.1 在无 BOM 时按 ANSI/GBK 解码 —— 中文注释会破坏引号配对，
# Parser::ParseFile 直接报一串 "Unexpected token '}'"。计划任务以 powershell.exe -File
# 方式执行 supervisor-loop.ps1，被剥 BOM 就等于自愈链整体失效且没有报错。
#
# 用法：
#   .\tests\ensure-bom.ps1          # 补 BOM，打印改动清单（幂等：已带 BOM 的不动）
#   .\tests\ensure-bom.ps1 -Check   # 只检查不修改，有缺则退出码 1
#
# 写回必须是"临时文件 + Move-Item -Force 原子替换"：
#   1) 直接 WriteAllText 会先截断再写，读到半截文件的进程会解析失败；
#   2) 更隐蔽的是写入瞬间文件里没有 BOM —— 自愈循环每轮都会 spawn 子 powershell 重新加载
#      core.ps1（github 组测速恢复就是这么调的），正好落在那个毫秒窗口里就会把中文注释按
#      ANSI/GBK 解出乱码，日志里留下 "单轮异常 ... 表达式或语句中包含意外的标记" 这种假故障。
#      实测 2026-09-22 01:56:40 就留下过一条。
#   Move-Item 是同卷重命名，替换是原子的：读者要么看到旧文件、要么看到新文件。
#
# 兼容 Windows PowerShell 5.1：不使用 PS7 专属语法。
param([switch]$Check)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fixed = New-Object System.Collections.Generic.List[string]
$missing = New-Object System.Collections.Generic.List[string]

foreach ($f in (Get-ChildItem -Path $root -Recurse -File -Filter '*.ps1')) {
  $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
  $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  if ($hasBom) { continue }

  $rel = $f.FullName.Replace($root, '').TrimStart('\')
  $missing.Add($rel)
  if ($Check) { continue }

  # 源文件确定是 UTF-8（本仓库约定），故按 UTF-8 解码后补 BOM
  $text = [System.Text.Encoding]::UTF8.GetString($bytes)
  $enc = New-Object System.Text.UTF8Encoding($true)
  $tmp = $f.FullName + '.bomfix-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
  [System.IO.File]::WriteAllText($tmp, $text, $enc)
  Move-Item -LiteralPath $tmp -Destination $f.FullName -Force
  $fixed.Add($rel)
}

if ($Check) {
  if ($missing.Count -gt 0) {
    Write-Host ("缺少 UTF-8 BOM（" + $missing.Count + " 个）：" + ($missing -join ', '))
    exit 1
  }
  Write-Host 'BOM 检查通过：所有 .ps1 均带 UTF-8 BOM'
  exit 0
}

if ($fixed.Count -gt 0) { Write-Host ("已补 BOM（" + $fixed.Count + " 个）：" + ($fixed -join ', ')) }
else { Write-Host 'BOM 检查通过：无需改动' }
