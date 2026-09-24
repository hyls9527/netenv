# NetEnv 回归测试（Pester 3.4 兼容）
# 注意：必须带 UTF-8 BOM，且 Describe 第二参数必须是 ScriptBlock（Pester 3 不接受字符串名）。
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
. "$root\lib\core.ps1"
. "$root\lib\nodes.ps1"
. "$root\lib\secrets.ps1"

# ---- 日志沙箱：只把"写日志"这一件事重定向到临时目录，不动 $script:NetEnvRoot ----
# 为什么不能直接改 root：大量用例要读仓库真实 config/data（默认配置校验、端口派生、订阅合并），
# 改 root 会把这些读操作一起指向空目录 —— 实测一次改出 8 条失败。
# 为什么要沙箱：用例里的故障注入（坏配置、错误端口、不存在的组、临时 install 目录）都会经
# Write-NetEnvLog 落盘，于是"跑一轮回归 = 生产 logs/<日期>.log 里多几十条看着像真故障的 WARN"——
# 实测一次会话跑几十轮，当天日志从 650 字节涨到 22 KB、其中 217 行是测试噪声，真事故被淹。
$script:NetEnvLogDirOverride = Join-Path $env:TEMP ('netenv-tests-logs-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $script:NetEnvLogDirOverride -Force | Out-Null

Describe 'NetEnv 配置' {
  It '默认配置可解析且端口无重复' {
    $cfg = Read-NetEnvConfig
    $cfg.ports.mihomoMixed | Should Be 7890
    $cfg.ports.mihomoHttp | Should Be 7897
    $cfg.ports.mihomoController | Should Be 19090
    $dup = $cfg.ports.PSObject.Properties.Value | Group-Object | Where-Object { $_.Count -gt 1 }
    $dup.Count | Should Be 0
  }

  It 'health 段存在且探针配置完整' {
    $cfg = Read-NetEnvConfig
    $cfg.health | Should Not BeNullOrEmpty
    $cfg.health.probeUrl | Should Match '^https://'
    # probeUrls 是多目标 OR 判据的来源；每一项都必须合法，且第一项保持与 probeUrl 一致
    @($cfg.health.probeUrls).Count | Should BeGreaterThan 0
    @($cfg.health.probeUrls | Where-Object { $_ -notmatch '^https://' }).Count | Should Be 0
    $cfg.health.probeUrls[0] | Should Be $cfg.health.probeUrl
    [int]$cfg.health.probeIntervalMinutes | Should BeGreaterThan 0
    [int]$cfg.health.failThreshold | Should BeGreaterThan 0
    # 自动刷新的最小间隔：缺了它，目标长期不可达时每轮都去锤订阅源
    [int]$cfg.health.autoRefreshMinIntervalMinutes | Should BeGreaterThan 0
  }

  It 'git 裸内容域不得同时出现在直连与自适应列表（否则自适应规则永不生效）' {
    $cfg = Read-NetEnvConfig
    $direct = @($cfg.sensitiveDomains) + @($cfg.githubAuthDomains)
    $overlap = @($cfg.githubAdaptiveDomains | Where-Object { $direct -contains $_ })
    $overlap.Count | Should Be 0
  }

  It 'github 专项探针配置完整（判据独立于出品 OR，见 supervisor-loop 探针块）' {
    $cfg = Read-NetEnvConfig
    $cfg.health.githubProbe | Should Not BeNullOrEmpty
    @($cfg.health.githubProbe.probeUrls).Count | Should BeGreaterThan 0
    @($cfg.health.githubProbe.probeUrls | Where-Object { $_ -notmatch '^https://' }).Count | Should Be 0
    [int]$cfg.health.githubProbe.failThreshold | Should BeGreaterThan 0
    # 组名写错会让"恢复"打到不存在的组上，且失败现象与节点挂掉难以区分
    $cfg.health.githubProbe.group | Should Be 'github-adaptive'
    [int]$cfg.health.githubProbe.recoverMinIntervalMinutes | Should BeGreaterThan 0
  }
}

Describe 'NetEnv 脱敏' {
  It '隐藏 GitHub token 与常见密钥' {
    $text = 'key=ghp_1234567890abcdefghijklmnop token sk-abcdEFGH12345678 password=hunter2'
    $out = ConvertTo-Redacted $text
    $out | Should Not Match 'ghp_123456'
    $out | Should Not Match 'hunter2'
    $out | Should Match 'REDACTED'
  }

  It 'token 指纹稳定且不含原文' {
    $fp = Get-TokenFingerprint 'ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $fp.Length | Should Be 8
    $fp | Should Not Match 'ghp_'
  }
}

Describe '归档工具适配' {
  It '按工具分派参数：7-Zip 用 -t7z/-mhe=on' {
    $a = Get-NetEnvArchiveArgs -Exe 'C:\x\7z.exe' -Archive 'a.7z' -Source 'src' -Password 'pw'
    ($a -join ' ') | Should Match '\-t7z'
    ($a -join ' ') | Should Match '\-mhe=on'
    ($a -join ' ') | Should Match '\-ppw'
  }

  It '按工具分派参数：Bandizip 用 -fmt:7z 且不带 -mhe（实测其不支持）' {
    $a = Get-NetEnvArchiveArgs -Exe 'C:\x\bz.exe' -Archive 'a.7z' -Source 'src' -Password 'pw'
    ($a -join ' ') | Should Match '\-fmt:7z'
    ($a -join ' ') | Should Match '\-p:pw'
    ($a -join ' ') | Should Not Match 'mhe'
    ($a -join ' ') | Should Not Match '\-t7z'
  }

  It '识别归档工具风格' {
    (Get-NetEnvArchiveStyle 'C:\x\7z.exe') | Should Be '7zip'
    (Get-NetEnvArchiveStyle 'C:\x\bz.exe') | Should Be 'bandizip'
  }
}

Describe '出品探针' {
  It '不可达目标必须返回 Ok=False（端口在听不代表能上网）' {
    $r = Test-NetEnvEgress -ProbeUrl 'https://127.0.0.1:1/definitely-not-listening' -TimeoutSec 4
    $r.Ok | Should Be $false
    $r.Status | Should Be 0
  }
}

Describe '订阅危险字段剥离' {
  It '移除 script 字段与 proxy-providers 块' {
    $yaml = @"
proxies:
  - name: n1
    type: vmess
script:
  shortcuts:
    x: 1
proxy-providers:
  p1:
    url: https://example.com
    path: ./p1.yaml
rules:
  - MATCH,auto
"@
    $out = Remove-NetEnvDangerousFields $yaml
    $out | Should Not Match 'script:'
    $out | Should Not Match 'proxy-providers:'
    $out | Should Match 'rules:'
    $out | Should Match 'name: n1'
  }

  It '行内流式 script 写法也不得漏过（防绕过）' {
    $yaml = "proxies: [{script: evil, name: n1}]"
    $out = Remove-NetEnvDangerousFields $yaml
    $out | Should Not Match 'script'
  }
}

Describe '订阅合并' {
  It '多源去重、敏感域名直连、自适应组引用节点' {
    $subDir = Join-Path $env:TEMP ('netenv-subtest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $subDir -Force | Out-Null
    try {
      Set-Content -LiteralPath (Join-Path $subDir 'a.yaml') -Value @'
mixed-port: 7890
proxies:
  - name: n1
    type: vmess
    server: 1.1.1.1
  - name: n2
    type: ss
    server: 2.2.2.2
  - name: "\U0001F534_n4"
    type: vmess
    server: 4.4.4.4
rules:
  - MATCH,auto
'@ -Encoding utf8
      Set-Content -LiteralPath (Join-Path $subDir 'b.yaml') -Value @'
proxies:
    - name: n1
      type: vmess
      server: 9.9.9.9
    - name: n3
      type: trojan
      server: 3.3.3.3
    - cipher: chacha20-ietf-poly1305
      name: n5
      server: 5.5.5.5
      type: ss
'@ -Encoding utf8
      $cfg = Read-NetEnvConfig
      $out = Build-NetEnvMergedConfig $subDir $cfg
      @(Get-ClashProxyEntries $out).Count | Should Be 5
      # 组名必须与实现一致（历史漂移点：曾断言 auto-select）
      $out | Should Match 'name: auto-urltest'
      $out | Should Match 'name: proxy-select'
      # 自适应组选点依据必须是 github 自身端点
      $out | Should Match 'https://github.com/robots.txt'
      # 凭据端点走 github-adaptive（组内同时持有 proxy-select 与 DIRECT，按 github 端点探活做双向保底）
      # 变更原因见 docs/GITHUB-SAFETY.md：强制直连在直连抖动时没有退路，实测导致 clone / device flow 失败
      $out | Should Match 'DOMAIN-SUFFIX,api.github.com,github-adaptive'
      $out | Should Match 'DOMAIN-SUFFIX,codeload.github.com,github-adaptive'
      $out | Should Match 'DOMAIN-SUFFIX,ssh.github.com,github-adaptive'
      # 内容域走自适应（可用性保底）
      $out | Should Match 'DOMAIN-SUFFIX,github.com,github-adaptive'
      # 同一域名不得重复出规则
      $doms = [regex]::Matches($out, '(?m)^\s+-\s+DOMAIN-SUFFIX,([^,]+),') | ForEach-Object { $_.Groups[1].Value }
      $dupDom = $doms | Group-Object | Where-Object { $_.Count -gt 1 }
      $dupDom.Count | Should Be 0
      $out | Should Match 'mixed-port: 7890'
      $out | Should Match 'external-controller: 127.0.0.1:19090'
      $out | Should Match 'GEOIP,CN,DIRECT'
      # sniffer 必须存在（应对 DNS 污染下按 SNI 分流）
      $out | Should Match '(?m)^sniffer:'
      $out | Should Match 'override-destination: true'
      $out | Should Match 'n3'
      $out | Should Match 'n5'
      $out | Should Match '🔴_n4'
    } finally {
      Remove-Item -LiteralPath $subDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It '节点被全部过滤时返回空串（调用方据此保住旧 merged.yaml，不写空配置断网）' {
    $subDir = Join-Path $env:TEMP ('netenv-subempty-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $subDir -Force | Out-Null
    try {
      Set-Content -LiteralPath (Join-Path $subDir 'x.yaml') -Value @'
proxies:
  - name: "https://example.com/官网"
    type: vmess
    server: 1.1.1.1
rules:
  - MATCH,auto
'@ -Encoding utf8
      $cfg = Read-NetEnvConfig
      (Build-NetEnvMergedConfig $subDir $cfg) | Should Be ''
    } finally {
      Remove-Item -LiteralPath $subDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe '配置读取与编码' {
  It '无 BOM 的 UTF-8 文件也能读出中文（PS 5.1 Get-Content 会按 GBK 解码成乱码）' {
    $dir = Join-Path $env:TEMP ('netenv-enc-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    try {
      $f = Join-Path $dir 'cfg.json'
      [System.IO.File]::WriteAllText($f, '{"name":"语音ChatGPT-开机启动.lnk"}', (New-Object System.Text.UTF8Encoding($false)))
      ([System.IO.File]::ReadAllBytes($f)[0] -eq 0xEF) | Should Be $false
      $txt = Read-NetEnvFileText $f
      $txt | Should Match '语音ChatGPT'
      ($txt | ConvertFrom-Json).name | Should Be '语音ChatGPT-开机启动.lnk'
    } finally {
      Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It '配置损坏时 -Quiet 返回 $null 而不是抛错（否则连日志都写不出去）' {
    $saved = $script:NetEnvRoot
    $dir = Join-Path $env:TEMP ('netenv-badcfg-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path (Join-Path $dir 'config') -Force | Out-Null
    try {
      Set-Content -LiteralPath (Join-Path $dir 'config\netenv.json') -Value '{ "ports": ' -Encoding utf8
      $script:NetEnvRoot = $dir
      (Read-NetEnvConfig -Quiet) | Should BeNullOrEmpty
      { Read-NetEnvConfig } | Should Throw
    } finally {
      $script:NetEnvRoot = $saved
      Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It 'Save-NetEnvTextFile 原子落盘：内容正确、无 BOM、不留临时文件' {
    $dir = Join-Path $env:TEMP ('netenv-atomic-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    try {
      $f = Join-Path $dir 'state.json'
      Save-NetEnvTextFile -Path $f -Content '{"节点":1}'
      (Read-NetEnvFileText $f) | Should Be '{"节点":1}'
      ([System.IO.File]::ReadAllBytes($f)[0] -eq 0xEF) | Should Be $false
      @(Get-ChildItem -LiteralPath $dir -Filter '*.tmp-*').Count | Should Be 0
      # 覆盖写也必须成功
      Save-NetEnvTextFile -Path $f -Content '{"节点":2}'
      (Read-NetEnvFileText $f) | Should Be '{"节点":2}'
    } finally {
      Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe '端口派生' {
  It '代理 URL 只从端口表派生，改 netenv.json 不会与 mihomo 实际端口漂移' {
    (Get-NetEnvProxyUrl (Read-NetEnvConfig)) | Should Be 'http://127.0.0.1:7897'
    $fake = [PSCustomObject]@{ ports = [PSCustomObject]@{ mihomoHttp = 18123 } }
    (Get-NetEnvProxyUrl $fake) | Should Be 'http://127.0.0.1:18123'
  }
}

Describe '实例锁' {
  It '0 字节锁文件不得让命令崩溃，且应被回收' {
    $lock = Join-Path (Get-NetEnvPaths).Data 'netenv.lock'
    if (Test-Path -LiteralPath $lock) { Remove-Item -LiteralPath $lock -Force }
    New-Item -ItemType File -Path $lock -Force | Out-Null
    try {
      $got = Enter-NetEnvLock
      $got | Should Be $lock
      (Read-NetEnvFileText $got).Trim() | Should Be "$PID"
    } finally {
      Exit-NetEnvLock $lock
    }
  }
}

Describe '证书校验探针' {
  It '连接失败（curl http_code=000）不得判为"证书有效"' {
    $r = Test-NetEnvEgress -ProbeUrl 'https://github.com/robots.txt' -TimeoutSec 3 -ProxyPort 1 -VerifyCert
    $r.Ok | Should Be $false
    $r.Status | Should Be 0
    $r.Error | Should Not BeNullOrEmpty
  }
}

Describe 'doctor JSON 输出' {
  It '--json 必须是合法 JSON 且含 ok/fails/checks（PS 5.1 下 @($List[object]) 会抛 types do not match）' {
    . "$root\lib\doctor.ps1"
    # 只验证 JSON 序列化路径：桩掉网络探针与最慢的三个系统查询
    # （Get-ScheduledTask / Get-CimInstance / Get-NetTCPConnection 在 5.1 下各要 1-3s，
    #   真跑会把本用例拖到 ~30s，且网络探针结果不稳定）
    function Test-NetEnvEgress { param([string]$ProbeUrl, [int]$TimeoutSec, [int]$ProxyPort, [switch]$VerifyCert)
      [PSCustomObject]@{ Ok = $true; Status = 204; Ms = 1; Url = $ProbeUrl; Error = $null } }
    function Get-ScheduledTask { [CmdletBinding()] param() }
    function Get-CimInstance { [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)]$Rest) }
    function Get-NetTCPConnection { [CmdletBinding()] param([Parameter(ValueFromRemainingArguments = $true)]$Rest) }
    $raw = Invoke-NetEnvDoctor -Json -NoExit
    $obj = $raw | ConvertFrom-Json
    ($obj.PSObject.Properties.Name -contains 'ok') | Should Be $true
    ($obj.PSObject.Properties.Name -contains 'fails') | Should Be $true
    @($obj.checks).Count | Should BeGreaterThan 0
    @($obj.checks | Where-Object { $_.id -eq 'egress' }).Count | Should Be 1
    # fail 计数必须与 checks 里 ok=false 的条数一致（防统计与实际状态漂移）
    @($obj.checks | Where-Object { -not $_.ok }).Count | Should Be ([int]$obj.fails)
  }
}

Describe '订阅刷新（离线，不触网）' {
  It '无可用源时不写 merged.yaml，sub-state.json 仍合法可解析' {
    $saved = $script:NetEnvRoot
    $dir = Join-Path $env:TEMP ('netenv-refresh-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path (Join-Path $dir 'config') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dir 'data') -Force | Out-Null
    try {
      Copy-Item -LiteralPath (Join-Path $root 'config\netenv.json') -Destination (Join-Path $dir 'config\netenv.json') -Force
      '[{"id":"test-no-such-source","name":"x","trusted":true},{"id":"test-disabled","name":"y","disabled":true}]' |
        Set-Content -LiteralPath (Join-Path $dir 'config\sources.json') -Encoding utf8
      # 预置 geodata（>1MB 视为就绪），避免刷新流程真的去下载
      foreach ($g in 'GeoSite.dat', 'geoip.metadb') {
        [System.IO.File]::WriteAllBytes((Join-Path $dir ("data\" + $g)), (New-Object byte[] 1000001))
      }
      $script:NetEnvRoot = $dir
      $st = Invoke-NetEnvNodesRefresh
      (Test-Path -LiteralPath (Join-Path $dir 'data\merged.yaml')) | Should Be $false
      [int]$st.nodeCount | Should Be 0
      $st.sourceStatus['test-disabled'] | Should Be '已停用'
      $st.sourceStatus['test-no-such-source'] | Should Match '未配置'
      $parsed = (Read-NetEnvFileText (Join-Path $dir 'data\sub-state.json')) | ConvertFrom-Json
      $parsed.sourceStatus.'test-disabled' | Should Be '已停用'
    } finally {
      $script:NetEnvRoot = $saved
      Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe 'install 配置种子' {
  It '首次安装必须种入 config/*.json，重复安装不得覆盖本机配置' {
    . "$root\lib\setup.ps1"
    $savedLocal = $env:LOCALAPPDATA
    $dir = Join-Path $env:TEMP ('netenv-install-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    try {
      $env:LOCALAPPDATA = $dir
      Invoke-NetEnvInstall | Out-Null
      $installed = Join-Path $dir 'NetEnv'
      (Test-Path -LiteralPath (Join-Path $installed 'config\netenv.json')) | Should Be $true
      (Test-Path -LiteralPath (Join-Path $installed 'config\sources.json')) | Should Be $true
      (Test-Path -LiteralPath (Join-Path $installed 'config\clients.json')) | Should Be $true
      ((Read-NetEnvFileText (Join-Path $installed 'config\netenv.json')) | ConvertFrom-Json).mode | Should Be 'installed'
      # 本机改过的配置在重复安装时必须保留
      Save-NetEnvTextFile -Path (Join-Path $installed 'config\netenv.json') -Content '{"mode":"installed","ports":{"mihomoMixed":1,"mihomoHttp":2,"mihomoController":3},"marker":"keep-me"}'
      Invoke-NetEnvInstall | Out-Null
      ((Read-NetEnvFileText (Join-Path $installed 'config\netenv.json')) | ConvertFrom-Json).marker | Should Be 'keep-me'
    } finally {
      $env:LOCALAPPDATA = $savedLocal
      Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe '自愈链完整性' {
  It 'supervisor-loop 调用的 NetEnv 函数必须都能解析（曾漏 dot-source nodes.ps1）' {
    # 背景：supervisor-loop.ps1 只 dot-source 了 core.ps1，却调用 nodes.ps1 里的
    # Invoke-NetEnvNodesRefresh —— 一级降级每轮抛"无法将 ... 识别为 cmdlet"，
    # 而且 $ErrorActionPreference='Continue' 让它既不中断也不被 doctor 发现，
    # 静默失效 20 轮才被人看出来。这条守门就是为它加的。
    $src = Read-NetEnvFileText (Join-Path $root 'lib\supervisor-loop.ps1')
    $called = [regex]::Matches($src, '\b((?:Invoke|Test|Get|Set|Read|Save|Write|Update|ConvertTo|ConvertFrom|Remove|Ensure|Build|Start|Stop)-NetEnv[A-Za-z0-9]+)\b') |
      ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    $local = [regex]::Matches($src, '(?m)^\s*function\s+([A-Za-z0-9\-]+)') | ForEach-Object { $_.Groups[1].Value }
    $dotSourced = [regex]::Matches($src, '(?m)^\s*\.\s+"\$PSScriptRoot\\([A-Za-z0-9\-\.]+)"') | ForEach-Object { $_.Groups[1].Value }
    $domains = New-Object System.Collections.Generic.List[string]
    foreach ($f in $dotSourced) {
      $domains.Add((Read-NetEnvFileText (Join-Path $root ('lib\' + $f))))
    }
    $defined = [regex]::Matches(($domains -join "`n"), '(?m)^\s*function\s+([A-Za-z0-9\-]+)') | ForEach-Object { $_.Groups[1].Value }
    $unresolved = @($called | Where-Object { $local -notcontains $_ -and $defined -notcontains $_ })
    ($unresolved -join ', ') | Should Be ''
  }

  It '刷新后必须重载 mihomo（刷新只改 merged.yaml，运行中的 mihomo 不会自己读）' {
    # 两半缺一不可：循环里要真的调用重载，core.ps1 里要有打到 external-controller 的实现。
    $loop = Read-NetEnvFileText (Join-Path $root 'lib\supervisor-loop.ps1')
    $loop | Should Match 'Update-NetEnvMihomoConfig -ControllerPort'
    $core = Read-NetEnvFileText (Join-Path $root 'lib\core.ps1')
    $core | Should Match 'function Update-NetEnvMihomoConfig'
    $core | Should Match '/configs\?force=true'
  }
  It '失败计数必须在降级动作后归零（否则日志永远打"第 N/2 次"，N 一路爬）' {
    # 背景：consecutiveFail 记在 health-state.json 里，触发降级后若不归零，它就一直爬 ——
    # 实测 logs/20260915.log 全天刷"出品探针失败（第 11/2 次）"这类自相矛盾的日志，
    # 把"降级链空转"这条真故障淹在里面。归零后 N 只表示本轮第几次，退避交给 lastRefreshAt。
    # 两条链（出品、github）都必须有这个归零点；github 链在复测成功分支，故只断言出品链。
    $loop = Read-NetEnvFileText (Join-Path $root 'lib\supervisor-loop.ps1')
    $m = [regex]::Match($loop, '(?m)^        \$st\.consecutiveFail = 0\s*$')
    $m.Success | Should Be $true
    # 顺序守卫：二级降级的判据与一级同源（同一个 consecutiveFail），归零若排在它前面，
    # autoFallbackToDirect=true 的"回退直连"就永不触发（静默失效，正是本文件最怕的坑）
    $lvl2 = $loop.IndexOf('二级降级')
    $lvl2 | Should BeGreaterThan 0
    $m.Index | Should BeGreaterThan $lvl2
    # 退避跳过是正常状态，不得记 WARN 刷屏
    $loop | Should Match "Write-NetEnvLog 'INFO' `"出品不可用，但距上次自动刷新仅"
  }

  It '归零语句的落点与幂等性（结构守卫，非行为测试）' {
    # 为什么不写成"真跑一遍循环体"的行为测试（试过，代价太大，留档免得后人重复踩）：
    #   1) 循环体依赖 while 之前赋值的 $healthFile / $lastProbe，只抽循环体就要连前置行一起注入，
    #      任何一处漏掉都表现为"探针一次都不跑、refresh=0"，指标全绿但其实是空跑；
    #   2) 桩要装在脚本作用域才拦得住 core.ps1 的真身：Pester 3.4 的 It 块跑在模块作用域，
    #      本会话 Set-Item function: 装的桩根本命中不了目标函数；
    #   3) 曾因截取少一个大括号导致 Invoke-Expression 解析失败后死循环，把整轮 Pester 挂满 10 分钟。
    # 三条都真踩过，净收益是负的。真正的行为验证放在生产侧：logs/ 里再出现"第 N/2 次"且 N>2 即回归。
    $loop = Read-NetEnvFileText (Join-Path $root 'lib\supervisor-loop.ps1')
    # 结构：缩进 8 空格的归零语句必须存在（就在降级分支收尾处）
    $m = [regex]::Match($loop, '(?m)^        \$st\.consecutiveFail = 0\s*$')
    $m.Success | Should Be $true
    # 顺序：必须在"二级降级"之后，否则 autoFallbackToDirect=true 的回退永不触发（静默失效）
    $lvl2 = $loop.IndexOf('二级降级')
    $lvl2 | Should BeGreaterThan 0
    $m.Index | Should BeGreaterThan $lvl2
    # 幂等性：该缩进层级只允许出现一处，多了说明归零被挪进了分支内部（退避跳过分支就归不了零）
    @([regex]::Matches($loop, '(?m)^        \$st\.consecutiveFail = 0\s*$')).Count | Should Be 1
    # 退避跳过是正常状态，不得记 WARN 刷屏
    $loop | Should Match "Write-NetEnvLog 'INFO' `"出品不可用，但距上次自动刷新仅"
  }
}

Describe 'github 专项探针' {
  It '组测速助手在控制器不可达时返回 Ok=$false 且不抛错（不得打断自愈循环）' {
    # 与 Update-NetEnvMihomoConfig 同约：恢复动作失败只能记日志，绝不能让异常逃出去。
    $r = Invoke-NetEnvGithubGroupRecovery -Group 'github-adaptive' -ControllerPort 1 -TimeoutSec 2
    $r.Ok | Should Be $false
    $r.Group | Should Be 'github-adaptive'
  }

  It '组名不存在时同样返回 Ok=$false 且不抛错' {
    $r = Invoke-NetEnvGithubGroupRecovery -Group 'no-such-group-xyz' -ControllerPort 19090 -TimeoutSec 10
    $r.Ok | Should Be $false
  }

  It 'supervisor-loop 必须独立探 github 并调用组测速恢复（只靠出品 OR 判据会漏）' {
    # 背景：出品判据是多目标 OR（任一可达即算可用），google 通时 github 单独挂掉
    # 不会触发任何自愈 —— 实测 2026-09-17 github.com 经代理握手失败，health-state.json
    # 却一路 lastOk。而 git push/clone 全依赖 github，静默不可用代价高。
    $loop = Read-NetEnvFileText (Join-Path $root 'lib\supervisor-loop.ps1')
    $loop | Should Match 'githubProbe'
    $loop | Should Match 'Invoke-NetEnvGithubGroupRecovery'
    # 恢复动作要与出品链区分：github 挂多半是组状态陈旧，刷订阅不对症
    $loop | Should Not Match 'github.*Invoke-NetEnvNodesRefresh'
  }

  It 'github 探针的状态键必须在 health-state 默认键表内（漏了会每轮被重置、阈值失效）' {
    # 加载逻辑只遍历默认键表，未列入的键读不到已存值 —— 与当年 lastRefreshAt 退避
    # 失效是同一类坑，故用静态守卫兜住。
    $loop = Read-NetEnvFileText (Join-Path $root 'lib\supervisor-loop.ps1')
    $m = [regex]::Match($loop, '(?m)^\s*\$st = @\{([^}]*)\}')
    $m.Success | Should Be $true
    foreach ($k in @('githubConsecutiveFail', 'githubProbedAt', 'githubLastOk', 'githubLastError', 'githubLastRecoverAt')) {
      $m.Groups[1].Value | Should Match $k
    }
  }
}

Describe '日志函数健壮性' {
  It 'Write-NetEnvLog 在无过期日志时不得抛错（轮转管道不能反噬主流程）' {
    # 背景：原写法 "... | Remove-Item -Force" 在过滤结果为空时，PowerShell 7 会在参数
    # 绑定阶段抛 "Remove-Item: missing path operand"（实测 7.6.6）；它不受 -ErrorAction
    # 抑制、会从日志函数逃出，而日志函数主流程各处都在调，一旦逃出即打断 supervisor-loop。
    # 5.1 行为不同不抛 —— 正因如此生产日志里看不到，只有换宿主才暴露。
    { Write-NetEnvLog 'INFO' 'Pester: 日志函数健壮性自检' } | Should Not Throw
  }
}

Describe '出品探针多目标' {
  It '首个目标失败、次个成功时判为可用（单目标实现会把整机误判成不可用）' {
    # 用 script 作用域替换，Test-NetEnvEgressAny 定义在 core.ps1=脚本作用域，必然看到替换
    $orig = (Get-Item function:script:Test-NetEnvEgress).ScriptBlock
    try {
      Set-Item function:script:Test-NetEnvEgress -Value {
        param([string]$ProbeUrl, [int]$TimeoutSec, [int]$ProxyPort, [switch]$VerifyCert)
        if ($ProbeUrl -match 'google') {
          [PSCustomObject]@{ Ok = $false; Status = 0; Ms = 1; Url = $ProbeUrl; Error = 'timeout' }
        } else {
          [PSCustomObject]@{ Ok = $true; Status = 200; Ms = 7; Url = $ProbeUrl; Error = $null }
        }
      }
      $ok = Test-NetEnvEgressAny -Urls @('https://www.google.com/generate_204', 'https://github.com/robots.txt') -TimeoutSec 1
      $ok.Ok | Should Be $true
      $ok.Url | Should Match 'github'

      $bad = Test-NetEnvEgressAny -Urls @('https://www.google.com/generate_204') -TimeoutSec 1
      $bad.Ok | Should Be $false
      $bad.Error | Should Be 'timeout'

      $none = Test-NetEnvEgressAny -Urls @() -TimeoutSec 1
      ($none -eq $null) | Should Be $false
    } finally {
      Set-Item function:script:Test-NetEnvEgress -Value $orig
    }
  }
}

Describe '运行时脚本编码' {
  It '所有 .ps1 必须带 UTF-8 BOM（无 BOM 时 5.1 按 GBK 解码，中文注释会破坏引号配对）' {
    # 这不是洁癖：实测把 supervisor-loop.ps1 的 BOM 去掉后，powershell.exe 5.1 的
    # Parser::ParseFile 直接报 6 个 "Unexpected token '}'" —— 编辑工具很容易顺手剥掉 BOM，
    # 所以必须有测试兜住，而不是靠人记得复查。
    $bad = New-Object System.Collections.Generic.List[string]
    Get-ChildItem -Path $root -Recurse -File -Filter '*.ps1' | ForEach-Object {
      $b = [System.IO.File]::ReadAllBytes($_.FullName)
      if (-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) {
        $bad.Add($_.FullName.Replace($root, '').TrimStart('\'))
      }
    }
    ($bad -join ', ') | Should Be ''
  }
}

Describe '自愈链重载助手' {
  It '配置文件不存在时返回 false，不抛错（重载失败不得打断自愈循环）' {
    (Update-NetEnvMihomoConfig -ControllerPort 1 -ConfigPath (Join-Path $env:TEMP 'netenv-no-such-merged.yaml')) | Should Be $false
  }

  It '控制器不可达时返回 false，不抛错' {
    $tmp = Join-Path $env:TEMP ('netenv-reload-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.yaml')
    Set-Content -LiteralPath $tmp -Value "rules:`n  - MATCH,DIRECT" -Encoding utf8
    try {
      (Update-NetEnvMihomoConfig -ControllerPort 1 -ConfigPath $tmp -TimeoutSec 2) | Should Be $false
    } finally {
      Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
  }
}

Describe '零窗口启动器（VBS）' {
  It 'cscript 语法自检通过、能拉起目标、且单实例守卫生效' {
    # 背景：wscript 是 GUI 宿主，VBS 语法错误只弹模态框（如误用保留字 Like 会报
    # 800A03F2 缺少标识符），日志里什么都看不到 —— 必须由测试兜住。
    $vbs = Join-Path $root 'lib\run-supervisor-hidden.vbs'
    (Test-Path -LiteralPath $vbs) | Should Be $true
    # wscript 对编码敏感：文件必须是纯 ASCII
    @([System.IO.File]::ReadAllBytes($vbs) | Where-Object { $_ -gt 127 }).Count | Should Be 0

    $dir = Join-Path $env:TEMP ('netenv-vbs-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $probePid = 0
    try {
      # 用桩替换 supervisor-loop.ps1：写 PID 后常驻，既能验证被拉起，又不会真起自愈循环
      Set-Content -LiteralPath (Join-Path $dir 'supervisor-loop.ps1') -Encoding ascii -Value @(
        '"$PID" | Set-Content -LiteralPath (Join-Path $PSScriptRoot ''marker.txt'')',
        'Start-Sleep -Seconds 20'
      )
      Copy-Item -LiteralPath $vbs -Destination (Join-Path $dir 'launcher.vbs') -Force
      $marker = Join-Path $dir 'marker.txt'

      $out = & cscript.exe //nologo (Join-Path $dir 'launcher.vbs') 2>&1 | Out-String
      $out.Trim() | Should Be ''
      Start-Sleep -Seconds 3
      (Test-Path -LiteralPath $marker) | Should Be $true
      $first = (Read-NetEnvFileText $marker).Trim()
      $first | Should Match '^\d+$'
      $probePid = [int]$first

      # 第二次运行必须被守卫拦下：marker 内容（即 PID）不得被刷新
      $null = & cscript.exe //nologo (Join-Path $dir 'launcher.vbs') 2>&1
      Start-Sleep -Seconds 2
      (Read-NetEnvFileText $marker).Trim() | Should Be $first
    } finally {
      if ($probePid -gt 0) { Stop-Process -Id $probePid -Force -ErrorAction SilentlyContinue }
      Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}