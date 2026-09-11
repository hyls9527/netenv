# NetEnv 回归测试（Pester 3.4 兼容）
# 注意：必须带 UTF-8 BOM，且 Describe 第二参数必须是 ScriptBlock（Pester 3 不接受字符串名）。
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
. "$root\lib\core.ps1"
. "$root\lib\nodes.ps1"
. "$root\lib\secrets.ps1"

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
    [int]$cfg.health.probeIntervalMinutes | Should BeGreaterThan 0
    [int]$cfg.health.failThreshold | Should BeGreaterThan 0
  }

  It 'git 裸内容域不得同时出现在直连与自适应列表（否则自适应规则永不生效）' {
    $cfg = Read-NetEnvConfig
    $direct = @($cfg.sensitiveDomains) + @($cfg.githubAuthDomains)
    $overlap = @($cfg.githubAdaptiveDomains | Where-Object { $direct -contains $_ })
    $overlap.Count | Should Be 0
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
      # 凭据端点强制直连
      $out | Should Match 'DOMAIN-SUFFIX,api.github.com,DIRECT'
      $out | Should Match 'DOMAIN-SUFFIX,codeload.github.com,DIRECT'
      $out | Should Match 'DOMAIN-SUFFIX,ssh.github.com,DIRECT'
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
}
