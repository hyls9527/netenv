. "$PSScriptRoot\core.ps1"

function Invoke-NetEnvDoctor {
  [CmdletBinding()]
  param([switch]$Json, [switch]$NoExit)

  $cfg = Read-NetEnvConfig
  $checks = (New-Object System.Collections.Generic.List[object])
  $script:fails = 0

  function Add-Check {
    param([string]$Id, [string]$Name, [bool]$Ok, [string]$Detail)
    if (-not $Ok) { $script:fails++ }
    $checks.Add([PSCustomObject]@{ id = $Id; name = $Name; ok = $Ok; detail = $Detail })
  }

  # 端口表
  $optional = @($cfg.optionalServices)
  foreach ($p in $cfg.ports.PSObject.Properties) {
    $owner = Get-PortOwner $p.Value
    if ($owner) {
      $expected = @{ mihomoMixed='mihomo'; mihomoHttp='mihomo'; mihomoController='mihomo'; newApi='new-api'; subStore='sub-store' }
      $match = ($owner.Process -match ($expected[$p.Name] -replace '-','[-_]?')) -or ($owner.Path -match 'mihomo|new-api|sub-store')
      Add-Check "port.$($p.Name)" "端口 $($p.Value) ($($p.Name))" $match "被 $($owner.Process) (PID $($owner.Pid)) 占用$(if ($match) {'（符合预期）'} else {'（冲突：非 NetEnv 进程占用）'})"
    } elseif ($optional -contains $p.Name) {
      Add-Check "port.$($p.Name)" "端口 $($p.Value) ($($p.Name))" $true '未监听（可选服务未部署，跳过）'
    } else {
      Add-Check "port.$($p.Name)" "端口 $($p.Value) ($($p.Name))" $false '未监听'
    }
  }

  # 系统代理（仅 WinINET；WinHTTP 只记录）
  $ie = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
  $proxyOk = -not $ie.ProxyEnable -or ($ie.ProxyServer -like '*127.0.0.1:7897*')
  Add-Check 'sysproxy' '系统代理(WinINET)' $proxyOk "ProxyEnable=$($ie.ProxyEnable); ProxyServer=$($ie.ProxyServer)"
  $winhttp = (netsh winhttp show proxy 2>$null | Select-String 'Direct access' | Measure-Object).Count
  Add-Check 'winhttp' 'WinHTTP(仅记录)' $true ("状态: $(if ($winhttp -gt 0) {'直连'} else {'非直连'})")

  # 环境变量
  $envBad = @()
  foreach ($n in 'HTTP_PROXY','HTTPS_PROXY') {
    $v = [Environment]::GetEnvironmentVariable($n, 'User')
    if ($v) { $envBad += "$n=$v" }
  }
  Add-Check 'envvars' '用户代理环境变量' ($envBad.Count -eq 0) $(if ($envBad) { (ConvertTo-Redacted ($envBad -join '; ')) } else { '无残留' })

  # git / npm
  $gitProxy = git config --global --get http.proxy 2>$null
  Add-Check 'gitproxy' 'git 全局代理' ($null -eq $gitProxy -or $gitProxy -match '127.0.0.1:7897') ("http.proxy=$(ConvertTo-Redacted $gitProxy)")
  if (Get-Command npm -ErrorAction SilentlyContinue) {
    $npmProxy = npm config get proxy 2>$null
    $npmHttps = npm config get https-proxy 2>$null
    Add-Check 'npmproxy' 'npm 代理' (($null -eq $npmProxy -or $npmProxy -eq 'null' -or $npmProxy -match '7897') -and ($null -eq $npmHttps -or $npmHttps -eq 'null' -or $npmHttps -match '7897')) ("proxy=$npmProxy https=$npmHttps")
  } else {
    Add-Check 'npmproxy' 'npm 代理' $true '未安装 npm（跳过）'
  }

  # 旧 guardian 计划任务
  $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue
  foreach ($t in $cfg.guardianTasks) {
    $found = $tasks | Where-Object { $_.TaskName -eq $t }
    Add-Check "task.$t" "旧守护任务 $t" (-not $found -or $found.State -eq 'Disabled') $(if ($found) { "存在且状态=$($found.State)" } else { '已移除' })
  }

  # 旧自启动
  $startup = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
  foreach ($s in $cfg.startupItems) {
    Add-Check "startup.$s" "旧自启动 $s" (-not (Test-Path -LiteralPath (Join-Path $startup $s))) '检查启动文件夹'
  }

  # 旧代理进程（完整命令行匹配，防误判；排除 netenv 自身进程）
  $netenvRoot = (Get-NetEnvRoot)
  $procs = @(Get-CimInstance Win32_Process | Where-Object {
    $_.CommandLine -and $_.CommandLine -match '_tmp_openai_overwall|gemini-web2api|token-free-gateway|mihomo-windows-amd64' -and
    $_.CommandLine -notmatch [regex]::Escape($netenvRoot)
  })
  Add-Check 'oldprocs' '旧代理进程' ($procs.Count -eq 0) $(if ($procs.Count) { "仍有 $($procs.Count) 个旧进程(示例: $($procs[0].Name))" } else { '无' })

  # 其他代理进程（7890/7891/1080 类监听）
  $other = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -in 7890,7891,1080,8080,8087 } | ForEach-Object {
    $pr = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
    "$($pr.ProcessName):$($_.LocalPort)"
  } | Sort-Object -Unique
  Add-Check 'otherproxy' '其他代理类监听(仅提示)' $true $(if ($other) { ($other -join ', ') } else { '无' })

  # 本地网关健康（可选服务未监听时跳过）
  foreach ($item in @(@{n='newApi';p=$cfg.ports.newApi}, @{n='subStore';p=$cfg.ports.subStore})) {
    if ($optional -contains $item.n -and -not (Get-PortOwner $item.p)) {
      Add-Check "gw.$($item.n)" "网关 $($item.n)" $true '未部署（可选服务，跳过）'
      continue
    }
    try {
      $r = Invoke-WebRequest -Uri "http://127.0.0.1:$($item.p)/" -UseBasicParsing -TimeoutSec 3
      Add-Check "gw.$($item.n)" "网关 $($item.n)" $true "HTTP $($r.StatusCode)"
    } catch {
      Add-Check "gw.$($item.n)" "网关 $($item.n)" $false '不可达'
    }
  }

  # 订阅新鲜度
  $paths = Get-NetEnvPaths
  $subState = Join-Path $paths.Data 'sub-state.json'
  if (Test-Path -LiteralPath $subState) {
    $st = Get-Content -LiteralPath $subState -Raw | ConvertFrom-Json
    $age = ((Get-Date) - [datetime]$st.updatedAt).TotalHours
    Add-Check 'subfresh' '订阅新鲜度' ($age -lt 26) "上次更新 $([math]::Round($age,1)) 小时前（告警阈值 26h）"
  } else {
    Add-Check 'subfresh' '订阅新鲜度' $false '尚未执行 nodes refresh'
  }

  # 配置校验（schema + 备份存在性）
  $cfgOk = $true
  try { $null = Read-NetEnvConfig } catch { $cfgOk = $false }
  $backupCount = (Get-ChildItem -LiteralPath (Get-NetEnvPaths).Backups -Filter 'config-*' -ErrorAction SilentlyContinue | Measure-Object).Count
  Add-Check 'config' '配置校验与备份' ($cfgOk -and $backupCount -gt 0) "配置有效；备份 $backupCount 份"

  if ($Json) {
    return [PSCustomObject]@{ ok = ($script:fails -eq 0); fails = $script:fails; checks = @($checks) } | ConvertTo-Json -Depth 5
  }

  foreach ($c in $checks) {
    "{0} {1,-34} {2}" -f ('[OK]','[!!]')[([int](-not $c.ok))], $c.name, $c.detail
  }
  "共 $($checks.Count) 项，失败 $script:fails 项"
  if ($script:fails -gt 0 -and -not $NoExit) { exit 1 }
}
