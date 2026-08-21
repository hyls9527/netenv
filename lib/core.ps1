$script:NetEnvRoot = Split-Path -Parent $PSScriptRoot

function Get-NetEnvRoot { return $script:NetEnvRoot }

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
    $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
  } catch {
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
  try { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) } catch { throw "$Name 解析失败: $($_.Exception.Message)" }
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
  Add-Content -LiteralPath $logFile -Value $line
  $cutoff = (Get-Date).AddDays(-((Read-NetEnvConfig -Quiet).logging.rotateDays))
  Get-ChildItem -LiteralPath $logDir -Filter '*.log' | Where-Object { $_.LastWriteTime -lt $cutoff } | Remove-Item -Force -ErrorAction SilentlyContinue
}

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  return ([Security.Principal.WindowsPrincipal]::new($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PortOwner {
  param([int]$Port)
  $conn = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $conn) { return $null }
  $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
  return [PSCustomObject]@{ Port = $Port; Pid = $conn.OwningProcess; Process = $proc.ProcessName; Path = $proc.Path }
}

function Enter-NetEnvLock {
  $lock = Join-Path (Get-NetEnvPaths).Data 'netenv.lock'
  if (Test-Path -LiteralPath $lock) {
    $owner = (Get-Content -LiteralPath $lock -Raw).Trim()
    if ($owner -match '^\d+$' -and (Get-Process -Id ([int]$owner) -ErrorAction SilentlyContinue)) {
      throw "实例锁已存在(另一 NetEnv 实例运行中, PID $owner)。为避免端口冲突，本次操作中止。"
    }
    Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
  }
  $dir = Split-Path $lock -Parent
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  Set-Content -LiteralPath $lock -Value $PID
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
  $snap = [ordered]@{
    time = (Get-Date -Format 's')
    label = $Label
    proxy = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue) | Select-Object ProxyEnable, ProxyServer, ProxyOverride
    gitProxy = (git config --global --get http.proxy 2>$null)
    npm = [ordered]@{
      proxy = (npm config get proxy 2>$null)
      httpsProxy = (npm config get https-proxy 2>$null)
    }
    env = @{}
  }
  foreach ($n in 'HTTP_PROXY','HTTPS_PROXY','NO_PROXY','http_proxy','https_proxy','no_proxy') {
    $snap.env[$n] = [Environment]::GetEnvironmentVariable($n, 'User')
  }
  $file = Join-Path $snapDir ("snap-{0}-{1}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ($Label -replace '[^\w-]','_'))
  $snap | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $file -Encoding utf8
  return $file
}

function Get-NetEnvSnapshot {
  param([Parameter(Mandatory)][string]$File)
  if (-not (Test-Path -LiteralPath $File)) { throw "快照不存在: $File" }
  return (Get-Content -LiteralPath $File -Raw | ConvertFrom-Json)
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
    $map = Get-Content -LiteralPath $local -Raw | ConvertFrom-Json
    $entry = $map | Where-Object { $_.target -eq $TargetName } | Select-Object -First 1
    if ($entry) { return $entry.value }
  }
  return $null
}
