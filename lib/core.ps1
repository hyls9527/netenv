$script:NetEnvRoot = Split-Path -Parent $PSScriptRoot

function Get-NetEnvRoot { return $script:NetEnvRoot }

# 显式 UTF-8 读取：Windows PowerShell 5.1 的 Get-Content 默认按 ANSI(GBK) 解码，
# 无 BOM 的 UTF-8 文件里的中文会变成乱码（实测 config\netenv.json 无 BOM，
# startupItems[0] 被读成 "璇煶ChatGPT-..."，导致启动项检查静默失效）。
# File.ReadAllText 默认检测并剥离 BOM，带/不带 BOM 的 UTF-8 都能正确解码。
function Read-NetEnvFileText {
  param([Parameter(Mandatory)][string]$Path)
  return [System.IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding($false)))
}

# 原子写：先写同目录临时文件再替换，避免进程被杀/断电时留下半截文件
# （配置/状态文件被读坏会让 status、doctor 这些排障入口一起失效）。
function Save-NetEnvTextFile {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Content
  )
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $tmp = "$Path.tmp-$PID"
  [System.IO.File]::WriteAllText($tmp, $Content, (New-Object System.Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# 代理入口 URL 只从端口表派生：写死 7897 会在改 config\netenv.json 后与 mihomo 实际端口漂移
function Get-NetEnvProxyUrl {
  param($Cfg)
  if (-not $Cfg) { $Cfg = Read-NetEnvConfig -Quiet }
  $port = 7897
  if ($Cfg -and $Cfg.ports -and $Cfg.ports.mihomoHttp) { $port = [int]$Cfg.ports.mihomoHttp }
  return "http://127.0.0.1:$port"
}

# 当前生效档位需从三处实际状态推断：系统代理 / git 代理 / 用户环境变量。
# 只认 ProxyEnable 会把 github 档（只注入 git 代理）误报成 direct（见 status.ps1 历史注释）。
# doctor 与 status 共用本函数，避免两处判据各写一份而漂移。
function Get-NetEnvActiveProfile {
  $ie = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
  if ($ie.ProxyEnable) { return 'proxy' }
  $gitProxy = (git config --global --get http.proxy 2>$null)
  $envProxy = [Environment]::GetEnvironmentVariable('HTTP_PROXY', 'User')
  if ($gitProxy -or $envProxy) { return 'github' }
  return 'direct'
}

function Get-NetEnvPaths {
  $cfg = Read-NetEnvConfig -Quiet
  if ($cfg.mode -eq 'installed') {
    $dataRoot = Join-Path $env:LOCALAPPDATA 'NetEnv'
  } else {
    $dataRoot = Join-Path $script:NetEnvRoot 'data'
  }
  return [PSCustomObject]@{
    Root = $script:NetEnvRoot
    Data = $dataRoot
    Bin = Join-Path $dataRoot 'bin'
    Logs = Join-Path $script:NetEnvRoot 'logs'
    Backups = Join-Path $script:NetEnvRoot 'backups'
    ConfigDir = Join-Path $script:NetEnvRoot 'config'
  }
}

function Backup-NetEnvConfig {
  $paths = Get-NetEnvPaths
  if (-not (Test-Path -LiteralPath $paths.Backups)) { New-Item -ItemType Directory -Path $paths.Backups -Force | Out-Null }
  $src = Join-Path (Get-NetEnvRoot) 'config\netenv.json'
  if (Test-Path -LiteralPath $src) {
    Copy-Item -LiteralPath $src -Destination (Join-Path $paths.Backups ("config-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))) -Force
  }
}

function Read-NetEnvConfig {
  param([switch]$Quiet)
  $cfgPath = Join-Path (Get-NetEnvRoot) 'config\netenv.json'
  if (-not (Test-Path -LiteralPath $cfgPath)) {
    if ($Quiet) { return $null }
    throw "配置不存在: $cfgPath"
  }
  try {
    $cfg = (Read-NetEnvFileText $cfgPath) | ConvertFrom-Json
  } catch {
    # -Quiet 也必须吞掉解析错误：Write-NetEnvLog 会经 Get-NetEnvPaths 读取配置，
    # 若这里抛错，配置一坏连日志都写不出去（原注释的"配置损坏不得打断主流程"意图落空）。
    if ($Quiet) { return $null }
    throw "netenv.json 解析失败(配置校验失败): $($_.Exception.Message)"
  }
  # schema 校验
  if (-not $cfg.ports -or -not $cfg.ports.mihomoMixed) { throw "配置校验失败: 缺少 ports" }
  $dup = $cfg.ports.PSObject.Properties.Value | Group-Object | Where-Object Count -gt 1
  if ($dup) { throw "配置校验失败: 端口表重复 $($dup.Name -join ',')" }
  return $cfg
}

function Read-NetEnvJson {
  param([Parameter(Mandatory)][string]$Name)
  $path = Join-Path (Get-NetEnvRoot) "config\$Name.json"
  if (-not (Test-Path -LiteralPath $path)) { return @() }
  try { return ((Read-NetEnvFileText $path) | ConvertFrom-Json) } catch { throw "$Name 解析失败: $($_.Exception.Message)" }
}

function ConvertTo-Redacted {
  param([string]$Text)
  if (-not $Text) { return $Text }
  $patterns = @(
    'sk-[A-Za-z0-9_-]{8,}',
    'ghp_[A-Za-z0-9]{20,}',
    'github_pat_[A-Za-z0-9_]{20,}',
    'gho_[A-Za-z0-9]{20,}',
    'ghs_[A-Za-z0-9]{20,}',
    'Bearer\s+[A-Za-z0-9._~+/=-]{8,}',
    '(?i)(password|passwd|pwd|secret|token|cookie|apikey|api_key|authorization)\s*[:=]\s*[^\s,;]+'
  )
  $out = $Text
  foreach ($p in $patterns) {
    $out = [regex]::Replace($out, $p, '***REDACTED***')
  }
  return $out
}

function Write-NetEnvLog {
  param([string]$Level = 'INFO', [string]$Message)
  $paths = Get-NetEnvPaths
  $logDir = $paths.Logs
  if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
  $logFile = Join-Path $logDir "$(Get-Date -Format 'yyyyMMdd').log"
  $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, (ConvertTo-Redacted $Message)
  # 显式 UTF8：不加时 PS 5.1 按 ANSI(GBK) 追加，中文日志会写成混合编码
  Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
  # 配置缺失/损坏时不得抛错（否则日志本身会打断主流程）；rotateDays 缺省 14
  $rotateDays = 14
  try {
    $c = Read-NetEnvConfig -Quiet
    if ($c -and $c.logging -and $c.logging.rotateDays) { $rotateDays = [int]$c.logging.rotateDays }
  } catch { }
  if ($rotateDays -lt 1) { $rotateDays = 14 }
  $cutoff = (Get-Date).AddDays(-$rotateDays)
  # 逐项显式传 -LiteralPath，不用管道直接喂 Remove-Item：无匹配项时管道为空，
  # PowerShell 7 会在参数绑定阶段抛 "Remove-Item: missing path operand"（实测 7.6.6），
  # 它不受 -ErrorAction 抑制、会从本函数逃出，而日志函数是主流程各处都在调的 —— 一旦逃出
  # 就直接打断 supervisor-loop。5.1 下不抛，但目标运行时是 5.1、开发与测试常在 7，
  # 写法必须在两者下都成立（本轮实测：原写法在 7 下抛，显式 LiteralPath 不抛）。
  try {
    Get-ChildItem -LiteralPath $logDir -Filter '*.log' -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -lt $cutoff } |
      ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
  } catch { }
}

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PortOwner {
  param([int]$Port)
  $conn = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $conn) { return $null }
  # 进程可能在枚举与查询之间退出，$proc 可能为 $null —— 不能直接访问属性
  $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
  return [PSCustomObject]@{
    Port    = $Port
    Pid     = $conn.OwningProcess
    Process = if ($proc) { $proc.ProcessName } else { '(已退出)' }
    Path    = if ($proc) { $proc.Path } else { $null }
  }
}

function Enter-NetEnvLock {
  $lock = Join-Path (Get-NetEnvPaths).Data 'netenv.lock'
  if (Test-Path -LiteralPath $lock) {
    # 锁文件可能是 0 字节（进程在写入前被杀）：Get-Content -Raw 对空文件返回 $null，
    # 直接 .Trim() 会抛"不能对 Null 值表达式调用方法"，让所有命令都无法启动。
    $owner = ''
    try { $owner = (Read-NetEnvFileText $lock).Trim() } catch { $owner = '' }
    if ($owner -match '^\d+$' -and (Get-Process -Id ([int]$owner) -ErrorAction SilentlyContinue)) {
      throw "实例锁已存在(另一 NetEnv 实例运行中, PID $owner)。为避免端口冲突，本次操作中止。"
    }
    Write-NetEnvLog 'WARN' "发现失效的实例锁（内容: '$owner'），已清理"
    Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
  }
  $dir = Split-Path $lock -Parent
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  # 原子写：Set-Content 会先截断再写，被中断就留下 0 字节锁文件（正是上一个分支要处理的烂摊子）
  Save-NetEnvTextFile -Path $lock -Content "$PID"
  return $lock
}

function Exit-NetEnvLock {
  param([string]$LockFile)
  if ($LockFile -and (Test-Path -LiteralPath $LockFile)) { Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue }
}

function Save-NetEnvSnapshot {
  param([string]$Label)
  $paths = Get-NetEnvPaths
  $snapDir = Join-Path $paths.Backups 'snapshots'
  if (-not (Test-Path -LiteralPath $snapDir)) { New-Item -ItemType Directory -Path $snapDir -Force | Out-Null }
  $hasNpm = [bool](Get-Command npm -ErrorAction SilentlyContinue)
  $snap = [ordered]@{
    time = (Get-Date -Format 's')
    label = $Label
    proxy = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue) | Select-Object ProxyEnable, ProxyServer, ProxyOverride
    gitProxy = (git config --global --get http.proxy 2>$null)
    npm = [ordered]@{
      proxy = if ($hasNpm) { (npm config get proxy 2>$null) } else { $null }
      httpsProxy = if ($hasNpm) { (npm config get https-proxy 2>$null) } else { $null }
    }
    env = @{}
  }
  # NODE_USE_ENV_PROXY 必须一并快照：apply 会按档位置 1 / 清空，漏了它 --undo 后会留下
  # "开关开着却没有代理"（或反之）的半套状态。
  foreach ($n in 'HTTP_PROXY','HTTPS_PROXY','NO_PROXY','NODE_USE_ENV_PROXY','http_proxy','https_proxy','no_proxy') {
    $snap.env[$n] = [Environment]::GetEnvironmentVariable($n, 'User')
  }
  $file = Join-Path $snapDir ("snap-{0}-{1}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ($Label -replace '[^\w-]','_'))
  Save-NetEnvTextFile -Path $file -Content ($snap | ConvertTo-Json -Depth 4)
  return $file
}

function Get-NetEnvSnapshot {
  param([Parameter(Mandatory)][string]$File)
  if (-not (Test-Path -LiteralPath $File)) { throw "快照不存在: $File" }
  return ((Read-NetEnvFileText $File) | ConvertFrom-Json)
}

# 解析 7z 可执行文件（不写死安装路径；缺失时返回 $null）。
# 注意：Bandizip 的 bz.exe 与 7-Zip 参数语言不兼容（实测 -t7z/-mhe=on 均报 Parameter Paring Error），
# 必须按工具分派参数，见 Get-NetEnvArchiveArgs。
function Get-NetEnvSevenZip {
  $cands = @(
    @{ p = (Join-Path $env:ProgramFiles '7-Zip\7z.exe');            style = '7zip' },
    @{ p = (Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe');     style = '7zip' },
    @{ p = (Join-Path $env:LOCALAPPDATA 'Programs\7-Zip\7z.exe');   style = '7zip' },
    @{ p = (Join-Path $env:ProgramFiles 'Bandizip\bz.exe');         style = 'bandizip' },
    @{ p = (Join-Path ${env:ProgramFiles(x86)} 'Bandizip\bz.exe');  style = 'bandizip' }
  )
  foreach ($c in $cands) { if ($c.p -and (Test-Path -LiteralPath $c.p)) { return $c.p } }
  foreach ($n in '7z', '7za', 'bz') {
    $cmd = Get-Command $n -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
  }
  return $null
}

function Get-NetEnvArchiveStyle {
  param([Parameter(Mandatory)][string]$Exe)
  if ((Split-Path $Exe -Leaf) -match '^bz(\.exe)?$') { return 'bandizip' }
  return '7zip'
}

# 返回归档参数数组（含命令字），调用方直接 & $exe @args
function Get-NetEnvArchiveArgs {
  param(
    [Parameter(Mandatory)][string]$Exe,
    [Parameter(Mandatory)][string]$Archive,
    [Parameter(Mandatory)][string]$Source,
    [string]$Password
  )
  if ((Get-NetEnvArchiveStyle $Exe) -eq 'bandizip') {
    # -fmt:7z 指定 7z 格式；加密头默认开启（实测无密码无法列出条目名）
    $a = @('a', '-fmt:7z', '-y')
    if ($Password) { $a += ('-p:' + $Password) }
    $a += @($Archive, $Source)
    return $a
  }
  $a = @('a', '-t7z')
  if ($Password) { $a += ('-p' + $Password); $a += '-mhe=on' }
  $a += @($Archive, $Source)
  return $a
}

function Get-GithubTokenStatus {
  param([string]$Token)
  try {
    $resp = Invoke-WebRequest -Uri 'https://api.github.com/user' -Headers @{ Authorization = "Bearer $Token"; 'User-Agent' = 'netenv' } -UseBasicParsing -TimeoutSec 15
    return [PSCustomObject]@{ Valid = $true; Http = $resp.StatusCode }
  } catch {
    $code = $_.Exception.Response.StatusCode.value__
    return [PSCustomObject]@{ Valid = $false; Http = if ($code) { $code } else { 0 } }
  }
}

if (-not ('NetEnv.CredHelper' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace NetEnv {
  public static class CredHelper {
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredRead(string target, int type, int reservedFlag, out IntPtr credentialPtr);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern void CredFree(IntPtr cred);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL {
      public int Flags; public int Type; public IntPtr TargetName; public IntPtr Comment;
      public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
      public int CredentialBlobSize; public IntPtr CredentialBlob; public int Persist;
      public int AttributeCount; public IntPtr Attributes; public IntPtr TargetAlias; public IntPtr UserName;
    }
    public static string Read(string target) {
      IntPtr p;
      if (!CredRead(target, 1, 0, out p)) return null;
      try {
        CREDENTIAL c = (CREDENTIAL)Marshal.PtrToStructure(p, typeof(CREDENTIAL));
        if (c.CredentialBlobSize <= 0) return null;
        byte[] b = new byte[c.CredentialBlobSize];
        Marshal.Copy(c.CredentialBlob, b, 0, b.Length);
        return System.Text.Encoding.Unicode.GetString(b);
      } finally { CredFree(p); }
    }
  }
}
'@
}

function Get-NetEnvCredentialValue {
  param([string]$TargetName)
  $v = [NetEnv.CredHelper]::Read($TargetName)
  if ($v) { return $v }
  $local = Join-Path (Get-NetEnvRoot) 'config\local.credentials.json'
  if (Test-Path -LiteralPath $local) {
    $map = (Read-NetEnvFileText $local) | ConvertFrom-Json
    $entry = $map | Where-Object { $_.target -eq $TargetName } | Select-Object -First 1
    if ($entry) { return $entry.value }
  }
  return $null
}

# 端到端出品探针：真实经代理请求外网，回答"到底能不能上网"。
# 端口在听 ≠ 可用（实测：423 节点里仅 8 个能到 google，端口照样 LISTEN），
# 所以健康判据必须落到真实请求上，不能只看 Get-PortOwner。
function Test-NetEnvEgress {
  param(
    [string]$ProbeUrl,
    [int]$TimeoutSec = 8,
    [int]$ProxyPort,
    [switch]$VerifyCert
  )
  $cfg = Read-NetEnvConfig -Quiet
  if (-not $ProbeUrl) {
    if ($cfg -and $cfg.health -and $cfg.health.probeUrl) { $ProbeUrl = $cfg.health.probeUrl }
    else { $ProbeUrl = 'https://www.google.com/generate_204' }
  }
  if (-not $ProxyPort) {
    if ($cfg -and $cfg.ports -and $cfg.ports.mihomoHttp) { $ProxyPort = [int]$cfg.ports.mihomoHttp } else { $ProxyPort = 7897 }
  }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()

  # -VerifyCert：走 curl 真实校验证书。必要性：免费出口节点常呈现过期/伪造证书
  # （实测同一节点 curl -k 能拿到 401，而默认校验报 SEC_E_CERT_EXPIRED），
  # 而 mihomo 内部探针不校验证书，会把"能握手但证书无效"误判为健康。
  if ($VerifyCert) {
    # 无 curl 的机器退回 Invoke-WebRequest（.NET/schannel 默认即校验证书），语义一致
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
      return Test-NetEnvEgress -ProbeUrl $ProbeUrl -TimeoutSec $TimeoutSec -ProxyPort $ProxyPort
    }
    # 用 --silent --show-error 会在失败时把 curl 的 stderr 直接喷到控制台（污染 doctor 输出），
    # 因此这里完全静默，只取 http_code + 退出码；失败原因由两者推断。
    $out = & curl.exe -s -o NUL -w '%{http_code}' -x ("http://127.0.0.1:$ProxyPort") --connect-timeout $TimeoutSec --max-time ($TimeoutSec * 3) $ProbeUrl 2>$null
    $curlExit = $LASTEXITCODE
    $code = ($out -join '').Trim()
    # 关键：curl 连接/TLS 失败时 http_code 是 '000'，它也满足"3 位数字"。
    # 只判位数会把 schannel 握手失败（exit 35）误报成"证书有效"（实测 doctor 曾输出
    # "HTTP 0 in 29486ms（证书有效）"），MITM 检测形同虚设。
    $ok = ($curlExit -eq 0 -and $code -match '^[1-9]\d{2}$')
    $sw.Stop()
    return [PSCustomObject]@{
      Ok    = $ok
      Status = if ($ok) { [int]$code } else { 0 }
      Ms    = $sw.ElapsedMilliseconds
      Url   = $ProbeUrl
      Error = if ($ok) { $null }
              elseif (-not $code -or $code -eq '000') { "curl 未能建立连接（exit=$curlExit；证书校验失败/超时/代理不可达）" }
              else { "HTTP $code (curl exit=$curlExit)" }
    }
  }

  try {
    $r = Invoke-WebRequest -Uri $ProbeUrl -Proxy ("http://127.0.0.1:$ProxyPort") -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
    $sw.Stop()
    # 204/200/301/302 均视为出品可用（generate_204 正常返回 204）
    $ok = ($r.StatusCode -ge 200 -and $r.StatusCode -lt 400)
    return [PSCustomObject]@{ Ok = $ok; Status = [int]$r.StatusCode; Ms = $sw.ElapsedMilliseconds; Url = $ProbeUrl; Error = $null }
  } catch {
    $sw.Stop()
    return [PSCustomObject]@{ Ok = $false; Status = 0; Ms = $sw.ElapsedMilliseconds; Url = $ProbeUrl; Error = $_.Exception.Message }
  }
}

function Test-NetEnvEgressAny {
  # 出品可用判据：health.probeUrls 里**任一**目标可达即算可用（首个成功即返回）。
  # 为什么不能只认单目标：旧实现只探 health.probeUrl（google），而 google 在本机长期不可达、
  # github 却正常 —— 单目标会把"这一个目标不通"直接判成整机出品不可用，于是自愈循环每 5 分钟
  # 空刷一次订阅源（logs/20260917.log 实测连续 20 轮）。
  # 兼容：probeUrls 缺省时退回单个 probeUrl，再退回内置 google；老配置零改动仍可用。
  # doctor 与 supervisor-loop 共用本函数，保证两处口径一致。
  param(
    [string[]]$Urls,
    [int]$TimeoutSec = 8
  )
  if (-not $Urls -or @($Urls).Count -eq 0) {
    $cfg = Read-NetEnvConfig -Quiet
    $Urls = @()
    if ($cfg -and $cfg.health) {
      if ($cfg.health.probeUrls) { $Urls = @($cfg.health.probeUrls) }
      elseif ($cfg.health.probeUrl) { $Urls = @($cfg.health.probeUrl) }
    }
    if (@($Urls).Count -eq 0) { $Urls = @('https://www.google.com/generate_204') }
  }
  $last = $null
  foreach ($u in @($Urls)) {
    if (-not $u) { continue }
    $r = Test-NetEnvEgress -ProbeUrl $u -TimeoutSec $TimeoutSec
    if ($r.Ok) { return $r }
    $last = $r
  }
  return $last
}

function Update-NetEnvMihomoConfig {
  # 让运行中的 mihomo 重载配置（走 external-controller，不重启进程、不断监听）。
  # 为什么必须有这一步：nodes refresh 只重写 data/merged.yaml，而 supervisor.ps1 仅在
  # "端口没在听"时才拉起 mihomo —— 运行中的实例不会自己读新文件。少了重载，
  # 降级链刷新出的新节点永远不生效（真实缺陷：一级降级做了 20 轮无用功）。
  # 失败只记 WARN 并返回 $false，绝不让重载失败反过来打断自愈循环。
  param(
    [int]$ControllerPort = 19090,
    [string]$ConfigPath,
    [int]$TimeoutSec = 20
  )
  if (-not $ConfigPath -or -not (Test-Path -LiteralPath $ConfigPath)) { return $false }
  $uri = "http://127.0.0.1:$ControllerPort/configs?force=true"
  $body = (@{ path = $ConfigPath } | ConvertTo-Json)
  try {
    Invoke-WebRequest -Uri $uri -Method Put -Body $body -ContentType 'application/json' -UseBasicParsing -TimeoutSec $TimeoutSec | Out-Null
    return $true
  } catch {
    Write-NetEnvLog 'WARN' "mihomo 配置重载失败（$uri）：$_"
    return $false
  }
}

function Invoke-NetEnvGithubGroupRecovery {
  # 触发 github-adaptive 组重新测速，让它在成员（github-node / proxy-select / DIRECT）间重新择通。
  # 为什么是"组测速"而不是"刷订阅"：该组 lazy:true —— 没有流量就不测速；一旦某轮被判定
  # alive:false，就再没有流量进来，也就永远不再测速，坏状态被永久冻结。
  # 实测（2026-09-17）：github.com 经代理握手失败，而组内节点其实健康 —— 同一次测速里
  # github-node 595ms / proxy-select 686ms；触发一次组测速即恢复 HTTP 200 / 0.53s。
  # 走 external-controller 的 GET /group/<name>/delay：只读、不改配置、可反复执行。
  # 失败只记 WARN 并返回 Ok=$false，绝不让它打断自愈循环（与 Update-NetEnvMihomoConfig 同约）。
  param(
    [string]$Group = 'github-adaptive',
    [string]$TestUrl = 'https://github.com/robots.txt',
    [int]$ControllerPort = 19090,
    [int]$ProbeTimeoutMs = 5000,
    [int]$TimeoutSec = 90
  )
  $escaped = [System.Uri]::EscapeDataString($TestUrl)
  $uri = "http://127.0.0.1:$ControllerPort/group/$Group/delay?url=$escaped&timeout=$ProbeTimeoutMs"
  try {
    $r = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
    # 返回形如 {"github-node":595,"proxy-select":686}；探测失败的成员不出现在结果里。
    # 只要有任一成员拿到正延迟，就说明组内存在可用出口。
    $data = $r.Content | ConvertFrom-Json
    $ok = $false
    $pairs = New-Object System.Collections.Generic.List[string]
    foreach ($p in $data.PSObject.Properties) {
      $ms = 0
      try { $ms = [int]$p.Value } catch { $ms = 0 }
      if ($ms -gt 0) { $ok = $true }
      $pairs.Add(("{0}={1}ms" -f $p.Name, $ms))
    }
    return [PSCustomObject]@{
      Ok     = $ok
      Group  = $Group
      Detail = ($pairs -join ', ')
    }
  } catch {
    Write-NetEnvLog 'WARN' "github 组测速失败（$uri）：$_"
    return [PSCustomObject]@{ Ok = $false; Group = $Group; Detail = $null }
  }
}
