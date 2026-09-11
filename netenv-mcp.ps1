[Console]::OutputEncoding = [Text.Encoding]::UTF8
[Console]::InputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\lib\core.ps1"
. "$PSScriptRoot\lib\status.ps1"
. "$PSScriptRoot\lib\doctor.ps1"

function Write-McpError {
  param([string]$Message)
  [Console]::Error.WriteLine((ConvertTo-Redacted $Message))
}

function Send-McpResponse {
  param([object]$Payload)
  [Console]::Out.WriteLine(($Payload | ConvertTo-Json -Depth 10 -Compress))
}

$tools = @(
  [ordered]@{ name = 'netenv_status'; description = 'NetEnv 整体状态：profile、mihomo/new-api/Sub-Store 是否在线、订阅新鲜度、节点数、配置校验。只读、输出脱敏。'; inputSchema = @{ type = 'object'; properties = @{} } },
  [ordered]@{ name = 'netenv_doctor_summary'; description = 'NetEnv 体检摘要：端口冲突、系统代理、git/npm、旧守护任务、旧代理进程、网关健康。只读、输出脱敏。'; inputSchema = @{ type = 'object'; properties = @{} } },
  [ordered]@{ name = 'netenv_nodes_summary'; description = '订阅与节点概览：更新时间、节点数、来源健康。不输出节点名与订阅 URL。'; inputSchema = @{ type = 'object'; properties = @{} } },
  [ordered]@{ name = 'netenv_config_status'; description = '配置校验状态与备份信息。只读，不输出任何密钥值。'; inputSchema = @{ type = 'object'; properties = @{} } }
)

while ($true) {
  $line = [Console]::In.ReadLine()
  if ($null -eq $line) { break }
  $line = $line.Trim()
  if (-not $line) { continue }
  try {
    $req = $line | ConvertFrom-Json
  } catch {
    Write-McpError "无法解析请求: $($_.Exception.Message)"
    continue
  }

  switch ($req.method) {
    'initialize' {
      Send-McpResponse @{
        jsonrpc = '2.0'
        id = $req.id
        result = @{
          protocolVersion = '2024-11-05'
          capabilities = @{ tools = @{ listChanged = $false } }
          serverInfo = @{ name = 'netenv'; version = '1.0.0' }
        }
      }
    }
    'notifications/initialized' { }
    'ping' {
      Send-McpResponse @{ jsonrpc = '2.0'; id = $req.id; result = @{} }
    }
    'tools/list' {
      Send-McpResponse @{ jsonrpc = '2.0'; id = $req.id; result = @{ tools = @($tools) } }
    }
    'tools/call' {
      $name = $req.params.name
      $text = $null
      $isError = $false
      try {
        $paths = Get-NetEnvPaths
        switch ($name) {
          'netenv_status' {
            $text = (Get-NetEnvStatus -Json)
          }
          'netenv_doctor_summary' {
            $text = (Invoke-NetEnvDoctor -Json -NoExit)
          }
          'netenv_nodes_summary' {
            $st = Join-Path $paths.Data 'sub-state.json'
            if (Test-Path -LiteralPath $st) {
              $s = (Read-NetEnvFileText $st) | ConvertFrom-Json
              $text = ([PSCustomObject]@{ updatedAt = $s.updatedAt; nodeCount = $s.nodeCount; sourceStatus = $s.sourceStatus }) | ConvertTo-Json -Compress
            } else {
              $text = ([PSCustomObject]@{ initialized = $false; nodeCount = 0; note = '尚未执行 nodes refresh' }) | ConvertTo-Json -Compress
            }
          }
          'netenv_config_status' {
            $cfgValid = $true
            try { $null = Read-NetEnvConfig } catch { $cfgValid = $false }
            $text = ([PSCustomObject]@{
              configValid = $cfgValid
              backups = (Get-ChildItem -LiteralPath $paths.Backups -Filter 'config-*' -ErrorAction SilentlyContinue | Measure-Object).Count
              allowWrite = (Read-NetEnvConfig -Quiet).mcp.allowWrite
            }) | ConvertTo-Json -Compress
          }
          default {
            $text = "未知工具: $name"
            $isError = $true
          }
        }
      } catch {
        $text = ConvertTo-Redacted $_.Exception.Message
        $isError = $true
      }
      Send-McpResponse @{
        jsonrpc = '2.0'
        id = $req.id
        result = @{
          content = @(@{ type = 'text'; text = (ConvertTo-Redacted $text) })
          isError = $isError
        }
      }
    }
    default {
      Write-McpError "未知方法: $($req.method)"
    }
  }
}
