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

  # 环境变量：判据必须与档位一致 —— proxy 档（envProxy=true）下这组变量是预期配置，
  # 只有 direct/github 档（envProxy=false）才把它们当"残留"。
  # 此前一律判残留，等于 apply -profile proxy 之后 doctor 必然失败（工具自相矛盾）。
  $activeProfile = Get-NetEnvActiveProfile
  $expectsEnvProxy = [bool]$cfg.profiles.$activeProfile.envProxy
  $envSet = @(foreach ($n in 'HTTP_PROXY','HTTPS_PROXY','NODE_USE_ENV_PROXY') {
    $v = [Environment]::GetEnvironmentVariable($n, 'User')
    if ($v) { "$n=$v" }
  })
  if ($expectsEnvProxy) {
    $wantUrl = Get-NetEnvProxyUrl $cfg
    $missing = @(@('HTTP_PROXY','HTTPS_PROXY') | Where-Object { [Environment]::GetEnvironmentVariable($_, 'User') -ne $wantUrl })
    $nodeOn = ([Environment]::GetEnvironmentVariable('NODE_USE_ENV_PROXY', 'User') -eq '1')
    $envOk = ($missing.Count -eq 0) -and $nodeOn
    $envDetail = if ($envOk) {
      "profile=$activeProfile 已按档位注入（$(ConvertTo-Redacted ($envSet -join '; '))）"
    } else {
      "profile=$activeProfile 期望 HTTP(S)_PROXY=$wantUrl 且 NODE_USE_ENV_PROXY=1；实际: $(if ($envSet) { ConvertTo-Redacted ($envSet -join '; ') } else { '未注入' })"
    }
  } else {
    $envOk = ($envSet.Count -eq 0)
    $envDetail = if ($envSet) { "profile=$activeProfile 不应注入，残留: $(ConvertTo-Redacted ($envSet -join '; '))" } else { "profile=$activeProfile，无残留" }
  }
  Add-Check 'envvars' '用户代理环境变量' $envOk $envDetail

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

  # 零窗口启动器：计划任务全靠它。VBS 语法错误在 wscript 下只弹模态框（实测误用保留字
  # Like 报 800A03F2 缺少标识符），日志里看不到任何痕迹 —— 所以体检至少要保证文件在且是
  # 纯 ASCII（wscript 对编码敏感）；语法本身由 tests\netenv.tests.ps1 的 cscript 自检覆盖。
  $vbsLauncher = Join-Path (Get-NetEnvRoot) 'lib\run-supervisor-hidden.vbs'
  if (-not (Test-Path -LiteralPath $vbsLauncher)) {
    Add-Check 'launcher' '零窗口启动器(VBS)' $false "缺失: $vbsLauncher（自启动任务会静默失败）"
  } else {
    $vbsNonAscii = @([System.IO.File]::ReadAllBytes($vbsLauncher) | Where-Object { $_ -gt 127 }).Count
    Add-Check 'launcher' '零窗口启动器(VBS)' ($vbsNonAscii -eq 0) $(if ($vbsNonAscii -gt 0) { "含 $vbsNonAscii 个非 ASCII 字节（wscript 编码敏感，需改回 ASCII）" } else { '就绪（纯 ASCII，语法见 tests\netenv.tests.ps1）' })
  }

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
