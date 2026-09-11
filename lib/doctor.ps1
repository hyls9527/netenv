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
  $proxyHostPort = (Get-NetEnvProxyUrl $cfg) -replace '^https?://', ''
  $proxyOk = -not $ie.ProxyEnable -or ($ie.ProxyServer -like "*$proxyHostPort*")
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
  Add-Check 'gitproxy' 'git 全局代理' ($null -eq $gitProxy -or $gitProxy -match [regex]::Escape($proxyHostPort)) ("http.proxy=$(ConvertTo-Redacted $gitProxy)")
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

  # 订阅新鲜度（状态文件可能被半截写入，解析失败要报出来而不是让 doctor 崩掉）
  $paths = Get-NetEnvPaths
  $subState = Join-Path $paths.Data 'sub-state.json'
  if (Test-Path -LiteralPath $subState) {
    try {
      $st = (Read-NetEnvFileText $subState) | ConvertFrom-Json
      $age = ((Get-Date) - [datetime]$st.updatedAt).TotalHours
      Add-Check 'subfresh' '订阅新鲜度' ($age -lt 26) "上次更新 $([math]::Round($age,1)) 小时前（告警阈值 26h）"
    } catch {
      Add-Check 'subfresh' '订阅新鲜度' $false "sub-state.json 不可解析: $($_.Exception.Message)"
    }
  } else {
    Add-Check 'subfresh' '订阅新鲜度' $false '尚未执行 nodes refresh'
  }

  # 配置校验（schema；备份只是可回滚能力，缺备份不代表系统不健康 —— 便携版首次 apply 前必然是 0 份）
  $cfgOk = $true
  try { $null = Read-NetEnvConfig } catch { $cfgOk = $false }
  $backupCount = (Get-ChildItem -LiteralPath (Get-NetEnvPaths).Backups -Filter 'config-*' -ErrorAction SilentlyContinue | Measure-Object).Count
  $backupNote = if ($backupCount -gt 0) { "备份 $backupCount 份" } else { '尚无配置备份（apply / config edit 会自动生成）' }
  Add-Check 'config' '配置校验与备份' $cfgOk "配置有效；$backupNote"

  # .ps1 必须带 UTF-8 BOM：无 BOM 时 Windows PowerShell 5.1 按 ANSI/GBK 解码，
  # 中文注释会破坏引号配对并导致 ParseException（实测高频故障）
  $noBom = (New-Object System.Collections.Generic.List[string])
  Get-ChildItem -Path (Get-NetEnvRoot) -Recurse -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\tests\\' } | ForEach-Object {
      $b = [System.IO.File]::ReadAllBytes($_.FullName)
      $hasBom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
      if (-not $hasBom) { $noBom.Add($_.Name) }
    }
  Add-Check 'bom' '脚本 UTF-8 BOM' ($noBom.Count -eq 0) $(if ($noBom.Count) { "缺 BOM: $($noBom -join ', ')" } else { '全部运行时脚本均带 BOM' })

  # geodata 完整性：mihomo 缺任一项会尝试联网自取，失败即整包配置加载失败
  $geoMissing = (New-Object System.Collections.Generic.List[string])
  foreach ($g in 'GeoSite.dat', 'geoip.metadb') {
    $p = Join-Path (Get-NetEnvPaths).Data $g
    if (-not (Test-Path -LiteralPath $p) -or (Get-Item -LiteralPath $p).Length -lt 1000000) { $geoMissing.Add($g) }
  }
  Add-Check 'geodata' 'geodata 预置' ($geoMissing.Count -eq 0) $(if ($geoMissing.Count) { "缺失/过小: $($geoMissing -join ', ')" } else { 'GeoSite.dat + geoip.metadb 就绪' })

  # 端到端出品：端口在听不代表能上网（实测 423 节点中仅 8 个能到 google，端口照样 LISTEN）。
  # 仅当 mihomo 端口已在监听时才探测，否则只会得到误导性的失败。
  if (Get-PortOwner $cfg.ports.mihomoHttp) {
    $eg = Test-NetEnvEgress -TimeoutSec 10
    Add-Check 'egress' '端到端出品（经代理实测）' $eg.Ok $(if ($eg.Ok) { "HTTP $($eg.Status) in $($eg.Ms)ms" } else { "不可用: $($eg.Error)" })
    # 证书校验：mihomo 内部探针不校验证书，会把"能握手但证书无效"误判为健康
    $certUrl = if ($cfg.subscription.githubUrlTest.url) { $cfg.subscription.githubUrlTest.url } else { 'https://github.com/robots.txt' }
    $cert = Test-NetEnvEgress -ProbeUrl $certUrl -TimeoutSec 10 -VerifyCert
    Add-Check 'certverify' '出口证书可信（非 MITM）' $cert.Ok $(if ($cert.Ok) { "HTTP $($cert.Status) in $($cert.Ms)ms（证书有效）" } else { "证书校验失败: $($cert.Error)（换节点或走 DIRECT；见 docs/TROUBLESHOOTING.md）" })
  } else {
    Add-Check 'egress' '端到端出品（经代理实测）' $true 'mihomo 未监听，跳过'
    Add-Check 'certverify' '出口证书可信（非 MITM）' $true 'mihomo 未监听，跳过'
  }

  if ($Json) {
    # 必须用 ToArray()：Windows PowerShell 5.1 上 @($List[object]) 会抛
    # "Argument types do not match"（本机 5.1.26100 实测，List[string]/Object[] 正常），
    # 之前用 @($checks) 导致 doctor --json 与 MCP 的 netenv_doctor_summary 直接报错。
    return [PSCustomObject]@{ ok = ($script:fails -eq 0); fails = $script:fails; checks = $checks.ToArray() } | ConvertTo-Json -Depth 5
  }

  foreach ($c in $checks) {
    "{0} {1,-34} {2}" -f ('[OK]','[!!]')[([int](-not $c.ok))], $c.name, $c.detail
  }
  "共 $($checks.Count) 项，失败 $script:fails 项"
  if ($script:fails -gt 0 -and -not $NoExit) { exit 1 }
}
