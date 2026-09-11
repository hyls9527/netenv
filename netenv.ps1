#!/usr/bin/env pwsh
[CmdletBinding()]
param(
  [Parameter(Position = 0)][string]$Command,
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
if (-not $Rest) { $Rest = @() }

. "$PSScriptRoot\lib\core.ps1"

function Show-NetEnvUsage {
  @"
NetEnv v1 — 统一网络代理层
用法: netenv <命令> [参数]

  doctor [--json]                 只读体检（冲突时退出码 1）
  status [--json]                 整体状态
  apply -profile direct|proxy|github | --undo [--snapshot <file>]
  nodes refresh                   免费订阅源刷新 + 危险字段剥离
  clients check|apply             AI 软件连通验证 / 代理注入
  adopt [--apply] [--undo] [--report <file>] [--password <pw>]
  migrate                         导出新机配置包
  setup --apply                   新机一键装配
  install [--autostart]           安装到 %LOCALAPPDATA%\NetEnv
  uninstall                       卸载并保留配置备份
  bootstrap [--force]             镜像下载 mihomo/new-api 并 SHA256 校验
  clean                           清理过期日志与临时缓存
  config validate|edit|set-secret <target> <value>
  secrets scan|verify|archive|purge --github-expired
  mcp                             启动 MCP stdio server（供 AI 客户端调用）
"@
}

if (-not $Command -or $Command -in '-h','--help','help') { Show-NetEnvUsage; exit 0 }

# mcp 是常驻 stdio 循环、doctor/status 是只读操作：都不取实例锁，
# 否则 MCP 会长期占用 data\netenv.lock，导致其他 netenv 命令一律被拒。
$lock = $null
if ($Command -notin @('mcp', 'doctor', 'status')) { $lock = Enter-NetEnvLock }
try {
  switch ($Command) {
    'doctor' {
      . "$PSScriptRoot\lib\doctor.ps1"
      Invoke-NetEnvDoctor -Json:($Rest -contains '--json')
    }
    'status' {
      . "$PSScriptRoot\lib\status.ps1"
      Get-NetEnvStatus -Json:($Rest -contains '--json')
    }
    'apply' {
      . "$PSScriptRoot\lib\apply.ps1"
      $profile = if ($Rest -contains '--undo') { 'direct' } else {
        $i = [array]::IndexOf($Rest, '-profile'); if ($i -ge 0 -and $Rest.Count -gt $i) { $Rest[$i + 1] } else { throw '缺少 -profile direct|proxy|github' }
      }
      $snapIdx = [array]::IndexOf($Rest, '--snapshot')
      $snap = if ($snapIdx -ge 0 -and $Rest.Count -gt $snapIdx) { $Rest[$snapIdx + 1] } else { $null }
      Invoke-NetEnvApply -Profile $profile -Undo:($Rest -contains '--undo') -SnapshotFile $snap
    }
    'nodes' {
      . "$PSScriptRoot\lib\nodes.ps1"
      if ($Rest[0] -eq 'refresh') { Invoke-NetEnvNodesRefresh } else { throw "nodes 子命令: refresh" }
    }
    'clients' {
      . "$PSScriptRoot\lib\clients.ps1"
      if ($Rest[0] -eq 'check') { Invoke-NetEnvClientsCheck | Format-Table -AutoSize }
      elseif ($Rest[0] -eq 'apply') { Invoke-NetEnvClientsApply }
      else { throw "clients 子命令: check|apply" }
    }
    'adopt' {
      . "$PSScriptRoot\lib\adopt.ps1"
      $repIdx = [array]::IndexOf($Rest, '--report'); $rep = if ($repIdx -ge 0 -and $Rest.Count -gt $repIdx) { $Rest[$repIdx + 1] } else { $null }
      $pwIdx = [array]::IndexOf($Rest, '--password'); $pw = if ($pwIdx -ge 0 -and $Rest.Count -gt $pwIdx) { $Rest[$pwIdx + 1] } else { $null }
      Invoke-NetEnvAdopt -Apply:($Rest -contains '--apply') -Undo:($Rest -contains '--undo') -ReportFile $rep -Password $pw
    }
    'migrate' { . "$PSScriptRoot\lib\migrate.ps1"; Invoke-NetEnvMigrate }
    'setup' { . "$PSScriptRoot\lib\setup.ps1"; Invoke-NetEnvSetup -Apply:($Rest -contains '--apply') }
    'install' { . "$PSScriptRoot\lib\setup.ps1"; Invoke-NetEnvInstall -Autostart:($Rest -contains '--autostart') }
    'uninstall' { . "$PSScriptRoot\lib\setup.ps1"; Invoke-NetEnvUninstall }
    'bootstrap' { . "$PSScriptRoot\lib\bootstrap.ps1"; Invoke-NetEnvBootstrap -Force:($Rest -contains '--force') }
    'clean' {
      $paths = Get-NetEnvPaths
      Get-ChildItem -LiteralPath $paths.Logs -Filter '*.log' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } | Remove-Item -Force
      Get-ChildItem -LiteralPath $env:TEMP -Filter 'netenv-secrets-*' -Directory -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
      'clean 完成'
    }
    'config' {
      $sub = $Rest[0]
      if ($sub -eq 'validate') { $null = Read-NetEnvConfig; '配置校验通过' }
      elseif ($sub -eq 'edit') { Backup-NetEnvConfig; Start-Process notepad (Join-Path (Get-NetEnvRoot) 'config\netenv.json'); '已备份当前配置并打开编辑器（保存后 doctor 会重新校验）' }
      elseif ($sub -eq 'set-secret') {
        if ($Rest.Count -lt 3) { throw '用法: config set-secret <target> <value>' }
        $target = $Rest[1]; $value = $Rest[2]
        Backup-NetEnvConfig
        cmdkey /generic:$target /user:netenv /pass:$value | Out-Null
        "凭据已写入 Windows 凭据管理器: $target"
      } else { throw 'config 子命令: validate|edit|set-secret' }
    }
    'secrets' {
      . "$PSScriptRoot\lib\secrets.ps1"
      $sub = $Rest[0]
      switch ($sub) {
        'scan' { Invoke-NetEnvSecretsScan -Github:($Rest -contains '--github') | Format-Table -AutoSize }
        'verify' { Invoke-NetEnvSecretsVerify | ForEach-Object { $_ } }
        'archive' {
          $pwIdx = [array]::IndexOf($Rest, '--password'); $pw = if ($pwIdx -ge 0 -and $Rest.Count -gt $pwIdx) { $Rest[$pwIdx + 1] } else { $null }
          $dirIdx = [array]::IndexOf($Rest, '--dir'); $dir = if ($dirIdx -ge 0 -and $Rest.Count -gt $dirIdx) { $Rest[$dirIdx + 1] } else { $null }
          $r = Invoke-NetEnvSecretsArchive -Password $pw -ArchiveDir $dir
          "归档: $($r.Archive)`n清单: $($r.Manifest)`n条目: $($r.Entries)`n密码(仅此一次): $($r.Password)"
        }
        'purge' { Invoke-NetEnvSecretsPurge -GithubExpired:($Rest -contains '--github-expired') | Format-Table -AutoSize }
        default { throw 'secrets 子命令: scan|verify|archive|purge' }
      }
    }
    'mcp' { & "$PSScriptRoot\netenv-mcp.ps1" }
    default { throw "未知命令: $Command（见 netenv --help）" }
  }
} finally {
  Exit-NetEnvLock $lock
}
