$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. "$root\lib\core.ps1"
. "$root\lib\nodes.ps1"
. "$root\lib\secrets.ps1"

Describe 'NetEnv config' {
  It '默认配置可解析且端口无重复' {
    $cfg = Read-NetEnvConfig
    $cfg.ports.mihomoMixed | Should Be 7890
    $dup = $cfg.ports.PSObject.Properties.Value | Group-Object | Where-Object Count -gt 1
    $dup.Count | Should Be 0
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
}

Describe '订阅合并' {
  It '多源去重、敏感域名直连、auto-select 引用节点' {
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
      ($out | Select-String -Pattern 'name: n1').Count | Should BeGreaterThan 0
      ($out | Select-String -Pattern 'name: n3').Count | Should BeGreaterThan 0
      @(Get-ClashProxyEntries $out).Count | Should Be 5
      $out | Should Match 'DOMAIN-SUFFIX,api.github.com,DIRECT'
      $out | Should Not Match 'DOMAIN-SUFFIX,github.com,DIRECT'
      $out | Should Match 'mixed-port: 7890'
      $out | Should Match 'port: 7897'
      $out | Should Match 'external-controller: 127.0.0.1:19090'
      $out | Should Match 'GEOIP,CN,DIRECT'
      $out | Should Match 'name: auto-select'
      $out | Should Not Match '(?m)^\s+- DIRECT\s*$'
      $out | Should Match 'n3'
      $out | Should Match 'n5'
      $out | Should Not Match '""'
      $out | Should Match '🔴_n4'
    } finally {
      Remove-Item -LiteralPath $subDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
