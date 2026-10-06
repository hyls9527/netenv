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

function Set-NetEnvProxyReg {
  # 系统代理（WinINET）的唯一写入点。原定义在 apply.ps1，但自愈循环必须能在不加载
  # apply.ps1 的前提下修复系统代理漂移，故上移到 core.ps1（apply.ps1 已 dot-source 本文件，
  # 调用点无需改动）。两处各留一份必然漂移 —— 与本仓库"判据只写一份"的既有约定一致。
  param([int]$Enable, [string]$Server, [string]$Override)
  $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
  Set-ItemProperty -Path $path -Name ProxyEnable -Value $Enable
  Set-ItemProperty -Path $path -Name ProxyServer -Value $Server
  Set-ItemProperty -Path $path -Name ProxyOverride -Value $Override
}

# 期望开启系统代理 = 从**持久化意图标记**推断档位，而不是用 Get-NetEnvActiveProfile。
# 为什么不能复用：后者把 ProxyEnable=1 当作"当前是 proxy 档"的依据，于是
#   ① VPN 把 ProxyEnable 清成 0 时（最常见的接管形态）它推断成 direct 档，
#      自愈逻辑便认为"本档期望就是关闭"，漂移永远检不出来 —— 实测真实缺陷；
#   ② 依赖被观测对象本身来自证身份，是循环论证。
# 意图标记由 apply 写入且与档位同生共死（envProxy -> HTTP_PROXY / NODE_USE_ENV_PROXY，
# 各档 -> git http.proxy），不受 VPN 篡改注册表的影响。
function Get-NetEnvProxyIntent {
  $cfg = Read-NetEnvConfig -Quiet
  if (-not $cfg -or -not $cfg.profiles) { return $null }
  $wantUrl = (Get-NetEnvProxyUrl $cfg)
  $userHttp = [Environment]::GetEnvironmentVariable('HTTP_PROXY', 'User')
  $userNode = [Environment]::GetEnvironmentVariable('NODE_USE_ENV_PROXY', 'User')
  if ($userHttp -and ($userHttp -eq $wantUrl) -and $userNode -eq '1') { return 'proxy' }
  $gitProxy = (git config --global --get http.proxy 2>$null)
  if ($gitProxy -and ($gitProxy -eq $wantUrl)) { return 'github' }
  return 'direct'
}

# 读取系统代理实际状态并与配置期望值比对，供 doctor 与自愈循环共用（判据只写一份）。
# 为什么必须把它当回事：第三方 VPN / 代理客户端在连接与断开时会接管 WinINET 的
# ProxyEnable/ProxyServer，且"谁最后写谁赢"。一旦被改写，吃系统代理与 HTTP_PROXY 的
# 程序会直接退回直连（被墙目标全废），而 supervisor-loop 原本只做进程探活与出品探针，
# 没有任何一处重写系统代理 —— 这个错会一直挂到人工 apply 为止。
function Get-NetEnvSystemProxyState {
  param($Cfg)
  if (-not $Cfg) { $Cfg = Read-NetEnvConfig -Quiet }
  $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
  $ie = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
  $enabled = [bool]$ie.ProxyEnable
  $server = [string]$ie.ProxyServer
  $expectedServer = $null
  $expectedOverride = $null
  $intent = $null
  if ($Cfg -and $Cfg.profiles) {
    $intent = Get-NetEnvProxyIntent
    if ($intent -and ($Cfg.profiles.PSObject.Properties.Name -contains $intent)) { $intentCfg = $Cfg.profiles.$intent } else { $intentCfg = $null }
  } else { $intentCfg = $null }
  if ($intentCfg -and $intentCfg.systemProxy) {
    $hostPort = (Get-NetEnvProxyUrl $Cfg) -replace '^https?://', ''
    $expectedServer = "http=$hostPort;https=$hostPort"
    $expectedOverride = ($Cfg.noProxy -join ';')
  }
  # Drifted 只在"期望开启系统代理"时有意义：direct/github 档期望就是关闭，
  # 此时 ProxyEnable=0 属正常，不得据此自愈（否则会跟人工切档互相打架）。
  # 判据必须同时覆盖"被改写"与"被清空"两种写法 —— 客户端接管有两种常见形态：
  #   ① 改成自己的地址（ProxyEnable=1 但 ProxyServer 变了）；
  #   ② 直接关掉/清空（ProxyEnable=0，ProxyServer 可能还留着旧串）。
  # 只判 ① 会漏掉 ②，而 ② 恰恰是"连接时接管、断开时不留"的最常见形态。
  # 注意 ProxyOverride 不参与判定：本机实测它天然就与配置不一致（历史遗留条目），
  # 拿它当判据会让修复永不收敛、每轮都误判"仍在漂移"。
  $drifted = $false
  if ($expectedServer) { $drifted = (-not $enabled) -or ($server -ne $expectedServer) }
  return [PSCustomObject]@{
    Enabled          = $enabled
    Server           = $server
    Override         = [string]$ie.ProxyOverride
    ExpectedServer   = $expectedServer
    ExpectedOverride = $expectedOverride
    Intent           = $intent
    Drifted          = $drifted
  }
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
  # 日志目录可被覆盖（回归测试用）：用例会注入坏配置 / 错误端口 / 不存在的组，
  # 不重定向就会把一堆"看着像真故障"的 WARN 写进生产 logs/<日期>.log，把真事故淹掉
  # （实测一次会话跑几十轮，当天日志 650 字节 → 22 KB，217 行是测试噪声）。
  $logDir = $paths.Logs
  if ($script:NetEnvLogDirOverride) { $logDir = $script:NetEnvLogDirOverride }
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

# ---- GPT（OpenAI / ChatGPT）可达性 ----
# 为什么不能沿用"能连上就算通"：OpenAI 对**不受支持地区**在应用层返回 403
# （响应体里是 unsupported_country_region_territory），而 TCP/TLS 与 Cloudflare 边缘都是通的。
# 实测 mihomo 的 /delay 测速对 401/403 一律返回正延迟（只看连通、不看状态码），
# 因此任何 url-test 组都会把延迟最低的香港节点选进来 —— 香港恰是 OpenAI 不支持地区，
# 结果就是"GPT 长期时好时坏、换节点也白换"。地区判据只能由真实响应码给出。
function ConvertTo-NetEnvGptProbeResult {
  param([int]$HttpCode = 0, [string]$Body)
  $ok = $false
  $reason = $null
  # 200/401/429 均视为可达：401 = 地区受支持、仅缺密钥；429 = 可达但被限流。
  if ($HttpCode -eq 200 -or $HttpCode -eq 201 -or $HttpCode -eq 401 -or $HttpCode -eq 429) {
    $ok = $true
  } elseif ($HttpCode -eq 403 -and $Body -match 'unsupported_country_region_territory') {
    $reason = 'region-unsupported'
  } elseif ($HttpCode -eq 403) {
    $reason = 'forbidden'
  } elseif ($HttpCode -ge 520 -and $HttpCode -le 526) {
    # Cloudflare 源站类错误：免费出口的瞬时抖动（实测 doctor 撞到过一次 520，同一节点
    # 3 秒后连测三次全是 401）。判据上仍算不可用，但要给出可区分的原因，别混进 unreachable。
    $reason = 'cf-origin-error'
  } elseif ($HttpCode -ge 500) {
    $reason = 'upstream-error'
  } else {
    $reason = 'unreachable'
  }
  return [PSCustomObject]@{ Ok = $ok; Status = $HttpCode; Reason = $reason }
}

function Test-NetEnvGptEgress {
  # GPT 可达性判据（经代理实测）。返回 Ok/Status/Ms/Url/Reason。
  # 用 curl 而不是 Invoke-WebRequest：需要拿到 403 的**响应体**来区分"地区不受支持"与
  # "其他拒绝"，而 Invoke-WebRequest 在 4xx 上抛异常、只能从 ErrorDetails 里抠，脆弱且易漏。
  param(
    [string]$ProbeUrl = 'https://api.openai.com/v1/models',
    [int]$ProxyPort,
    [int]$TimeoutSec = 12,
    [int]$Attempts = 1
  )
  $cfg = Read-NetEnvConfig -Quiet
  if (-not $ProxyPort) {
    if ($cfg -and $cfg.ports -and $cfg.ports.mihomoHttp) { $ProxyPort = [int]$cfg.ports.mihomoHttp } else { $ProxyPort = 7897 }
  }
  # $Attempts>1 只给 doctor 这类"一次性验收"用：免费出口偶发 520/超时不应把验收判死。
  # 自愈循环刻意用默认 1 次 —— 它的容错在"连续 N 轮失败"上（failThreshold），
  # 若在单轮内部重试，退避与阈值语义都会被打乱。
  $result = $null
  $total = [int]$Attempts
  if ($total -lt 1) { $total = 1 }
  for ($attempt = 1; $attempt -le $total; $attempt++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $bodyFile = Join-Path $env:TEMP ('netenv-gpt-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
    try {
      # 必须带浏览器 UA：裸 curl 会被 Cloudflare 直接 403，把"地区受支持"误判成"被拒"
      $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
      $out = & curl.exe -s -A $ua -o $bodyFile -w '%{http_code}' -x ("http://127.0.0.1:$ProxyPort") --connect-timeout $TimeoutSec --max-time ($TimeoutSec * 2) $ProbeUrl 2>$null
      $codeText = ($out -join '').Trim()
      $code = 0
      if ($codeText -match '^\d{3}$') { $code = [int]$codeText }
      $body = ''
      if (Test-Path -LiteralPath $bodyFile) { $body = Read-NetEnvFileText $bodyFile }
      $sw.Stop()
      $mapped = ConvertTo-NetEnvGptProbeResult -HttpCode $code -Body $body
      $result = [PSCustomObject]@{ Ok = $mapped.Ok; Status = $mapped.Status; Ms = $sw.ElapsedMilliseconds; Url = $ProbeUrl; Reason = $mapped.Reason }
    } catch {
      $sw.Stop()
      $result = [PSCustomObject]@{ Ok = $false; Status = 0; Ms = $sw.ElapsedMilliseconds; Url = $ProbeUrl; Reason = 'exception' }
    } finally {
      Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue
    }
    if ($result.Ok -or $attempt -ge $total) { break }
    Start-Sleep -Seconds 1
  }
  return $result
}

# mihomo 控制器的响应是 JSON 但**不带 charset**：Windows PowerShell 5.1 的 Invoke-WebRequest
# 在缺 charset 时按 ISO-8859-1 解码，节点名里的 emoji 会被读成乱码（实测 "🔴..." 读成 "ð..."，
# 码点 240,159,148，而正确的 UTF-8 解码是代理对 55357,56628）。拿乱码名字回 PUT "选择节点"
# 必然匹配不到成员（400），GPT 节点轮换会静默全灭。这两个助手显式按 UTF-8 收发；
# 凡是控制器调用涉及**节点名**（而非 ASCII 组名）的都必须走它们。
function Get-NetEnvJsonUtf8 {
  param([string]$Uri, [int]$TimeoutSec = 30)
  $req = [System.Net.HttpWebRequest]::Create($Uri)
  $req.Method = 'GET'
  $req.Timeout = $TimeoutSec * 1000
  $req.ReadWriteTimeout = $TimeoutSec * 1000
  $resp = $req.GetResponse()
  try {
    $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), (New-Object System.Text.UTF8Encoding($false)))
    try { $json = $sr.ReadToEnd() } finally { $sr.Dispose() }
  } finally { $resp.Close() }
  return ($json | ConvertFrom-Json)
}

function Invoke-NetEnvJsonPut {
  param([string]$Uri, [string]$Json, [int]$TimeoutSec = 15)
  $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes([string]$Json)
  $req = [System.Net.HttpWebRequest]::Create($Uri)
  $req.Method = 'PUT'
  $req.ContentType = 'application/json'
  $req.Timeout = $TimeoutSec * 1000
  $req.ReadWriteTimeout = $TimeoutSec * 1000
  $req.ContentLength = $bytes.Length
  $s = $req.GetRequestStream()
  try { $s.Write($bytes, 0, $bytes.Length) } finally { $s.Dispose() }
  $resp = $req.GetResponse()
  $resp.Close()
  return $true
}

function Get-NetEnvGptSelectedNode {
  # 上次轮换验证通过的节点（data/gpt-state.json）。文件缺失/损坏一律返回 $null，不抛。
  $f = Join-Path (Get-NetEnvPaths).Data 'gpt-state.json'
  if (-not (Test-Path -LiteralPath $f)) { return $null }
  try {
    $o = (Read-NetEnvFileText $f) | ConvertFrom-Json
    if ($o.node) { return [string]$o.node }
  } catch { }
  return $null
}

function Set-NetEnvGptSelectedNode {
  # 把 select 组切到指定节点。默认 Group=gpt-node（线上组），传 ProbeGroup 则只动探针池。
  # 失败返回 $false、不抛（自愈循环不得被打断）。
  param([string]$Node, [int]$ControllerPort = 19090, [string]$Group = 'gpt-node')
  if (-not $Node) { return $false }
  if (-not $Group) { $Group = 'gpt-node' }
  try {
    # 必须走 UTF-8 PUT：节点名含 emoji，走 Invoke-WebRequest 会以乱码匹配（见上方注释）
    [void](Invoke-NetEnvJsonPut -Uri "http://127.0.0.1:$ControllerPort/proxies/$Group" -Json (@{ name = $Node } | ConvertTo-Json) -TimeoutSec 10)
    return $true
  } catch { return $false }
}

# ---- GPT "地区不受支持"节点名单（data/gpt-blocklist.json）----
# 为什么值得单独记账：出口地区是**节点的稳定属性** —— 同一个香港节点今天、明天都仍是 OpenAI
# 不支持地区。旧实现每次轮换都把它重新复测一遍（每个候选最长 20s），2026-10-06 一天就复测了
# 8 次（logs/20261006.log 里 8 条 hysteria2-1446360527=region-unsupported）。
# 名单带 TTL 而不是永久拉黑：机场会换出口 IP，同一节点名下的实际地区可能变；
# 到期自动重试，避免"曾经不行就永远不用"把可用节点永久排除。
function Get-NetEnvGptBlocklistPath {
  return (Join-Path (Get-NetEnvPaths).Data 'gpt-blocklist.json')
}

function Get-NetEnvGptBlocklist {
  # 返回 @{ 节点名 = 解封时刻[datetime] }，已过期的条目直接不返回。文件缺失/损坏一律返回空表，不抛。
  $out = @{}
  try {
    $f = Get-NetEnvGptBlocklistPath
    if (-not (Test-Path -LiteralPath $f)) { return $out }
    $o = (Read-NetEnvFileText $f) | ConvertFrom-Json
    if (-not $o -or -not $o.entries) { return $out }
    $now = Get-Date
    foreach ($p in $o.entries.PSObject.Properties) {
      $until = $null
      try { $until = [datetime]$p.Value.until } catch { $until = $null }
      if ($until -and $until -gt $now) { $out[$p.Name] = $until }
    }
  } catch { }
  return $out
}

function Save-NetEnvGptBlocklist {
  param([hashtable]$Entries)
  # 局部变量不能叫 $entries —— 与参数 $Entries 大小写不敏感同名，会把参数清成空表，
  # 于是名单永远写成空（2026-10-06 静态扫描抓到，与 $probePort/$ProbePort 同一类错误）。
  try {
    $map = [ordered]@{}
    foreach ($k in @($Entries.Keys)) {
      $map[[string]$k] = [ordered]@{ reason = 'region-unsupported'; until = ([datetime]$Entries[$k]).ToString('s') }
    }
    $payload = [ordered]@{ version = 1; updatedAt = (Get-Date -Format 's'); entries = $map }
    Save-NetEnvTextFile -Path (Get-NetEnvGptBlocklistPath) -Content ($payload | ConvertTo-Json -Depth 4)
    return $true
  } catch { return $false }
}

function Add-NetEnvGptBlockedNode {
  # 记一个"地区不受支持"的节点。只应由 region-unsupported 这类**稳定**判据调用；
  # 超时/520 之类的瞬时故障不得入账（否则会把好节点误伤进名单）。
  param([string]$Node, [int]$Hours = 12)
  if (-not $Node) { return $false }
  if ($Hours -lt 1) { $Hours = 12 }
  try {
    $bl = Get-NetEnvGptBlocklist
    $bl[$Node] = (Get-Date).AddHours($Hours)
    [void](Save-NetEnvGptBlocklist -Entries $bl)
    return $true
  } catch { return $false }
}

function Remove-NetEnvGptBlockedNode {
  # 节点复测通过即除名（地区可能已变、或当初是误判）。
  param([string]$Node)
  if (-not $Node) { return $false }
  try {
    $bl = Get-NetEnvGptBlocklist
    if (-not $bl.ContainsKey($Node)) { return $false }
    $bl.Remove($Node)
    [void](Save-NetEnvGptBlocklist -Entries $bl)
    return $true
  } catch { return $false }
}

function Invoke-NetEnvGptNodeRotation {
  # GPT 节点轮换：用**真实响应码**逐个复测候选节点，把 gpt-node 钉在"地区受支持"的节点上。
  # 为什么必须自己轮换而不是交给 url-test：见 ConvertTo-NetEnvGptProbeResult 的注释 ——
  # mihomo 测速不看状态码，香港节点延迟最低却对 OpenAI 是不受支持地区。
  # 候选顺序：先复测当前节点（避免无谓切换），再按延迟从快到慢取前 N 个；
  # 第一个通过地区探针的节点胜出并持久化到 data/gpt-state.json（供 reload 后重放）；全部失败则还原。
  #
  # 【复测必须在探针专用入口上进行】旧实现每试一个候选就把**线上组** gpt-node 切过去，
  # 于是整个复测期间所有真实流量（浏览器、ChatGPT 桌面端）都在跟着"尚未验证"的候选走。
  # 2026-10-06 16:53 实测后果：16:53:07 探针连败触发轮换 → 16:53:27 用户打开 chatgpt.com，
  # 流量正走香港候选 → Cloudflare 返回 403 unsupported_country_region_territory，
  # 页面显示「无法加载网站 / 如果你用的是VPN，试着关闭它」（logs/20261006.log:226-234）。
  # 现在复测只在 ProbeGroup（探针池）上进行、经 ProbePort 出网，线上组**一次都不动**，
  # 直到某个候选真的通过地区判据，才做一次原子切换；一个都没通过就完全不切。
  param(
    [string]$Group = 'gpt-node',
    [string]$AdaptiveGroup = 'gpt-adaptive',
    [string]$ProbeUrl = 'https://api.openai.com/v1/models',
    [string]$LatencyUrl = 'https://chatgpt.com/cdn-cgi/trace',
    [string]$RankGroup = 'auto-urltest',
    [int]$ControllerPort = 19090,
    [int]$MaxCandidates = 8,
    [int]$ProbeTimeoutSec = 10,
    [string]$ProbeGroup = '',
    [int]$ProbePort = 0,
    [int]$BlocklistHours = 0,
    [int]$RankRetryTimeoutMs = 15000,
    [int]$PoolScanMax = 40,
    [int]$PoolScanTimeoutSec = 4,
    [int]$PoolScanBudgetSec = 120,
    [int]$PoolScanSeed = 0
  )
  $api = "http://127.0.0.1:$ControllerPort"
  $tested = New-Object System.Collections.Generic.List[string]

  # 参数缺省时从配置补齐（手工 `Invoke-NetEnvGptNodeRotation` 调用不带参也能享受到隔离通道）
  $rc = $null
  try { $rc = Read-NetEnvConfig -Quiet } catch { $rc = $null }
  if (-not $ProbeGroup) {
    if ($rc -and $rc.health -and $rc.health.gptProbe -and $rc.health.gptProbe.probeGroup) { $ProbeGroup = [string]$rc.health.gptProbe.probeGroup }
    else { $ProbeGroup = 'gpt-probe' }
  }
  if ($ProbePort -le 0 -and $rc -and $rc.ports -and $rc.ports.mihomoProbe) { $ProbePort = [int]$rc.ports.mihomoProbe }
  if ($BlocklistHours -le 0) {
    if ($rc -and $rc.health -and $rc.health.gptProbe -and $rc.health.gptProbe.blocklistHours) { $BlocklistHours = [int]$rc.health.gptProbe.blocklistHours }
    else { $BlocklistHours = 12 }
  }
  try {
    $proxies = Get-NetEnvJsonUtf8 -Uri "$api/proxies" -TimeoutSec 10
  } catch {
    Write-NetEnvLog 'WARN' "GPT 节点轮换：控制器不可达（$api）"
    return [PSCustomObject]@{ Ok = $false; Node = $null; Detail = 'controller-unreachable' }
  }
  $entry = $proxies.proxies.PSObject.Properties[$Group]
  if (-not $entry) {
    Write-NetEnvLog 'WARN' "GPT 节点轮换：组 $Group 不存在（需 nodes refresh 生成 gpt 组）"
    return [PSCustomObject]@{ Ok = $false; Node = $null; Detail = 'group-missing' }
  }
  $original = [string]$entry.Value.now

  # ---- 复测通道解析与降级 ----
  # 三条同时成立才算隔离通道可用：① 探针端口已配且真的在听；② 探针组存在于运行中的配置里。
  # 任一条不成立就退回"切线上组"的旧路径并记 WARN —— 配置没跟上时（例如运行中的 merged.yaml
  # 还是改动前生成的、里面没有 gpt-probe 组），宁可保留会打扰用户的老行为，
  # 也不能让自愈直接失效。
  # 注意：局部变量**不能**叫 $probePort —— PowerShell 变量名不区分大小写，它会和参数
  # $ProbePort 是同一个变量，一句 $probePort = 0 就把参数清零，隔离判断永远为假。
  # （2026-10-06 隔离运行时验证首跑抓到：日志里打印"端口 0"，线上组真的被切了一路。）
  $switchGroup = $Group
  $egressPort = 0
  $probeIsolated = $false
  if ($ProbePort -gt 0 -and $proxies.proxies.PSObject.Properties[$ProbeGroup]) {
    try {
      $tcp = New-Object System.Net.Sockets.TcpClient
      $tcp.Connect('127.0.0.1', $ProbePort)
      $tcp.Close()
      $probeIsolated = $true
    } catch { $probeIsolated = $false }
  }
  if ($probeIsolated) {
    $switchGroup = $ProbeGroup
    $egressPort = $ProbePort
  } else {
    Write-NetEnvLog 'WARN' ("GPT 节点轮换：探针专用入口不可用（组 $ProbeGroup / 端口 $ProbePort）→ " +
      '退回切线上组的旧路径，复测期间线上流量会跟着未验证的候选走（执行 nodes refresh 可生成 gpt-probe 入口）')
  }

  $ranked = New-Object System.Collections.Generic.List[object]
  try {
    $esc = [System.Uri]::EscapeDataString($LatencyUrl)
    $raw = Get-NetEnvJsonUtf8 -Uri "$api/group/$RankGroup/delay?url=$esc&timeout=5000" -TimeoutSec 180
    foreach ($p in $raw.PSObject.Properties) {
      $ms = 0
      try { $ms = [int]$p.Value } catch { $ms = 0 }
      if ($ms -gt 0) { $ranked.Add([PSCustomObject]@{ Node = $p.Name; Ms = $ms }) }
    }
  } catch { Write-NetEnvLog 'WARN' "GPT 节点轮换：$RankGroup 组测速失败（$_）" }

  # 组测速是"并行但会丢"的预筛：只回传在 timeout 内响应的成员，5s 对跨境免费节点偏紧。
  # 2026-10-06 17:50 实测整组测速 504（零候选）→ 自愈明明有一个池子却换不动。
  # 首次无结果时放宽一次（仍是并行的，代价只有一次往返），拿到的候选越全，
  # 越不需要往下走"全池顺序扫描"那条更慢的路。
  if ($ranked.Count -eq 0 -and $RankRetryTimeoutMs -gt 0) {
    try {
      $esc = [System.Uri]::EscapeDataString($LatencyUrl)
      $raw2 = Get-NetEnvJsonUtf8 -Uri "$api/group/$RankGroup/delay?url=$esc&timeout=$RankRetryTimeoutMs" -TimeoutSec 180
      foreach ($p in $raw2.PSObject.Properties) {
        $ms = 0
        try { $ms = [int]$p.Value } catch { $ms = 0 }
        if ($ms -gt 0) { $ranked.Add([PSCustomObject]@{ Node = $p.Name; Ms = $ms }) }
      }
      if ($ranked.Count -gt 0) {
        Write-NetEnvLog 'INFO' "GPT 节点轮换：$RankGroup 首次测速无结果，放宽到 $($RankRetryTimeoutMs)ms 后取到 $($ranked.Count) 个候选"
      }
    } catch {
      Write-NetEnvLog 'WARN' "GPT 节点轮换：$RankGroup 放宽超时重测仍失败（$_）"
    }
  }

  # 必须 .ToArray() 再排序：Windows PowerShell 5.1 上 @($genericListOfObject) 会抛
  # "Argument types do not match"（README「实测坑位」第 1 条），本次首跑就踩了。
  $rankedSorted = @($ranked.ToArray() | Sort-Object Ms)

  $candidates = New-Object System.Collections.Generic.List[string]
  $skippedBlocked = New-Object System.Collections.Generic.List[string]
  $blocked = Get-NetEnvGptBlocklist
  # 当前节点总是第一个复测（且不受名单限制）：它可能就是被瞬时抖动误判的，先探它能避免
  # "本不该切却切了"—— 探针只失败一次（failThreshold=1）就进来的，这一步收益最高。
  if ($original -and $original -ne 'DIRECT') { $candidates.Add($original) }
  foreach ($r in $rankedSorted) {
    if ($candidates.Count -ge $MaxCandidates) { break }
    if ($candidates -contains $r.Node) { continue }
    if ($blocked.ContainsKey($r.Node)) {
      if ($skippedBlocked -notcontains $r.Node) { $skippedBlocked.Add($r.Node) }
      continue
    }
    $candidates.Add($r.Node)
  }
  if ($skippedBlocked.Count -gt 0) {
    Write-NetEnvLog 'INFO' "GPT 节点轮换：跳过 $($skippedBlocked.Count) 个已知地区不受支持节点（$($skippedBlocked.ToArray() -join ', ')）"
  }
  # 全池都进了名单（或测速无结果）：名单是提示不是闸门，忽略它重来一遍。
  # 否则名单一旦写坏就会退化成"永远无候选"，自愈能力直接归零。
  if ($candidates.Count -eq 0) {
    foreach ($r in $rankedSorted) {
      if ($candidates.Count -ge $MaxCandidates) { break }
      if ($candidates -notcontains $r.Node) { $candidates.Add($r.Node) }
    }
    if ($candidates.Count -gt 0) {
      Write-NetEnvLog 'WARN' "GPT 节点轮换：候选全在地区名单内（$($skippedBlocked.ToArray() -join ', ')），已忽略名单重试"
    }
  }
  # ---- 全池兜底扫描 ----
  # 为什么需要：上面的候选只来自 $RankGroup 的**一次并行测速**，它可能只回传极少数成员
  # （2026-10-06 17:34：整个池子只有 1 个节点响应，偏偏还是地区封锁的香港节点），
  # 也可能整组 504、零候选（同一天 17:50 → 自愈有池子却换不动）。这两种情况下都别急着放弃：
  # 池子里还有几百个没被预筛命中的节点，按顺序经**探针入口**逐个验一遍，成本可控
  # （单点 4s、总预算 120s，且只在预筛候选全部失败之后才真正花这笔钱）。
  # 只允许在隔离通道上做：退路模式下每试一个都会把线上组切走，全池扫一遍等于把用户扔进海选。
  $rankedCandidateCount = $candidates.Count
  $poolScanArmed = $false
  if ($probeIsolated -and $PoolScanMax -gt 0) {
    $allMembers = @()
    try { $allMembers = @($proxies.proxies.PSObject.Properties[$switchGroup].Value.all) } catch { $allMembers = @() }
    if ($allMembers.Count -gt 0) {
      $poolScanArmed = $true
      # 每次轮换从池子的不同位置开始，否则前 N 个节点会被反复复测、后面的永远轮不到。
      # 5.1 下用 System.Random + Fisher-Yates 自己洗牌；种子默认取当前时钟，也可显式指定以便复现。
      $seed = $PoolScanSeed
      if ($seed -le 0) { $seed = [int](Get-Date -Format 'HHmmss') }
      $rnd = New-Object System.Random($seed)
      $shuffled = New-Object System.Collections.ArrayList
      foreach ($m in $allMembers) { [void]$shuffled.Add([string]$m) }
      for ($i = $shuffled.Count - 1; $i -gt 0; $i--) {
        $j = $rnd.Next($i + 1)
        $tmp = $shuffled[$i]; $shuffled[$i] = $shuffled[$j]; $shuffled[$j] = $tmp
      }
      $scanAdded = 0
      $scanSkippedBlocked = 0
      foreach ($m in $shuffled) {
        if ($scanAdded -ge $PoolScanMax) { break }
        if (-not $m -or $m -eq 'DIRECT' -or $m -eq 'REJECT' -or $m -eq 'GLOBAL') { continue }
        if ($candidates -contains $m) { continue }
        if ($blocked.ContainsKey($m)) { $scanSkippedBlocked++; continue }
        [void]$candidates.Add($m)
        $scanAdded++
      }
      Write-NetEnvLog 'INFO' ("GPT 节点轮换：追加全池兜底扫描 $scanAdded 个（池 $($allMembers.Count)" +
        " / 跳过地区名单 $scanSkippedBlocked / 单点超时 $($PoolScanTimeoutSec)s / 预算 $($PoolScanBudgetSec)s）")
    }
  }
  if ($candidates.Count -eq 0) {
    Write-NetEnvLog 'WARN' 'GPT 节点轮换：无候选节点（组测速无结果且当前无选中节点）'
    return [PSCustomObject]@{ Ok = $false; Node = $null; Detail = 'no-candidates' }
  }

  $probeIdx = 0
  $scanDeadline = $null
  if ($poolScanArmed -and $PoolScanBudgetSec -gt 0) { $scanDeadline = (Get-Date).AddSeconds($PoolScanBudgetSec) }
  foreach ($n in $candidates) {
    $probeIdx++
    # 兜底扫描段单独计时：预筛候选（前 $rankedCandidateCount 个）不设预算，它们本来就只有几个。
    $inPoolScan = ($poolScanArmed -and $probeIdx -gt $rankedCandidateCount)
    if ($inPoolScan -and $scanDeadline -and (Get-Date) -gt $scanDeadline) {
      $tested.Add('pool-scan=budget-exhausted')
      Write-NetEnvLog 'WARN' "GPT 节点轮换：全池兜底扫描预算 $($PoolScanBudgetSec)s 用尽（已试 $($probeIdx - 1) 个）仍无可用节点"
      break
    }
    if (-not (Set-NetEnvGptSelectedNode -Node $n -ControllerPort $ControllerPort -Group $switchGroup)) { $tested.Add("$n=switch-failed"); continue }
    Start-Sleep -Milliseconds 300
    # 隔离通道上经 egressPort 出网（走 IN-PORT → gpt-probe）；退回旧路径时 $egressPort=0，
    # 则 Test-NetEnvGptEgress 按配置回落到线上端口，与旧行为一致。
    # 兜底扫描段用更短的超时：池子越大越要控单点成本 —— 与其在一个死节点上耗 10s，
    # 不如多试几个（死节点/被墙节点几乎都是"超时"而不是"快速拒绝"）。
    $probeTimeout = $ProbeTimeoutSec
    if ($inPoolScan -and $PoolScanTimeoutSec -gt 0 -and $PoolScanTimeoutSec -lt $ProbeTimeoutSec) { $probeTimeout = $PoolScanTimeoutSec }
    $p = Test-NetEnvGptEgress -ProbeUrl $ProbeUrl -TimeoutSec $probeTimeout -ProxyPort $egressPort
    if ($p.Ok) {
      $tested.Add("$n=OK($($p.Status),$($p.Ms)ms)")
      # 到这里候选才第一次接触线上：$n 已通过地区判据，切换是原子的。
      # 隔离通道下 $switchGroup 是探针组，线上组从头到尾没被动过，必须显式切过去（并确认成功）。
      if ($switchGroup -ne $Group) {
        if (Set-NetEnvGptSelectedNode -Node $n -ControllerPort $ControllerPort -Group $Group) {
          $tested.Add('live-switch=OK')
        } else {
          $tested.Add('live-switch=FAILED')
          Write-NetEnvLog 'WARN' "GPT 节点轮换：$n 已通过地区判据，但切换到线上组 $Group 失败"
        }
      }
      [void](Remove-NetEnvGptBlockedNode -Node $n)
      try {
        Save-NetEnvTextFile -Path (Join-Path (Get-NetEnvPaths).Data 'gpt-state.json') -Content ([ordered]@{
          node        = $n
          verifiedAt  = (Get-Date -Format 's')
          status      = $p.Status
          probeUrl    = $ProbeUrl
        } | ConvertTo-Json)
      } catch { }
      # 顶层组指向 gpt-node：轮换只在"探针已失败"之后被调用，此时归位不算跟人工切档打架
      try {
        [void](Invoke-NetEnvJsonPut -Uri "$api/proxies/$AdaptiveGroup" -Json (@{ name = $Group } | ConvertTo-Json) -TimeoutSec 10)
      } catch { }
      return [PSCustomObject]@{ Ok = $true; Node = $n; Detail = ($tested.ToArray() -join ', ') }
    }
    $tested.Add("$n=$($p.Reason)")
    # 只对"地区不受支持"记账：它由响应码给出、是节点的稳定属性；超时/520 是瞬时故障，
    # 记进名单会把好节点误伤（下次轮换直接跳过它）。
    if ($p.Reason -eq 'region-unsupported') { [void](Add-NetEnvGptBlockedNode -Node $n -Hours $BlocklistHours) }
  }
  # 全部失败 → 还原。走隔离通道时线上组**从未被改过**，这里还原的是探针组（保持整洁）；
  # 走退路时线上组被切了一路，必须显式还原，别把系统留在"未验证"状态。
  if ($original) { [void](Set-NetEnvGptSelectedNode -Node $original -ControllerPort $ControllerPort -Group $switchGroup) }
  return [PSCustomObject]@{ Ok = $false; Node = $null; Detail = ($tested.ToArray() -join ', ') }
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
