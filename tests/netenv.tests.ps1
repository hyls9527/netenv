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
