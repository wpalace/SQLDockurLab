<#
  Shared helpers for sql-ag-lab guest scripts. Windows PowerShell 5.1 compatible.
  Dot-source:  . "$PSScriptRoot\Common.ps1"
  Exit-code contract with the host orchestrator (./lab):  0 = done, 3010 = reboot required, other = failure.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:LabGuestRoot = $PSScriptRoot
New-Item -ItemType Directory -Force -Path 'C:\Lab\logs' | Out-Null

function Write-Step([string]$Message) { Write-Host "==> [$env:COMPUTERNAME $(Get-Date -Format HH:mm:ss)] $Message" }
function Write-Ok([string]$Message)   { Write-Host "    OK  $Message" }

function Get-LabConfig {
    if (-not $script:LabConfig) {
        $script:LabConfig = Get-Content (Join-Path $script:LabGuestRoot 'lab-config.json') -Raw | ConvertFrom-Json
    }
    return $script:LabConfig
}

function Get-LabCredential {
    $c = Get-LabConfig
    $sec = ConvertTo-SecureString $c.password -AsPlainText -Force
    New-Object System.Management.Automation.PSCredential("$($c.netbios)\Administrator", $sec)
}

function Wait-Until {
    param([scriptblock]$Condition, [int]$TimeoutSeconds = 600, [int]$IntervalSeconds = 5, [string]$What = 'condition')
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $ok = $false
        try { $ok = [bool](& $Condition) } catch { $ok = $false }
        if ($ok) { return }
        if ((Get-Date) -gt $deadline) { throw "Timed out after ${TimeoutSeconds}s waiting for $What" }
        Start-Sleep -Seconds $IntervalSeconds
    }
}

function Test-TcpPort([string]$HostName, [int]$Port, [int]$TimeoutMs = 2000) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($iar); return $true
    } catch { return $false } finally { $client.Close() }
}

# --- SQL (System.Data.SqlClient ships with .NET Framework; no modules needed) -------
function New-LabSqlConnectionString {
    param([string]$Server = 'localhost', [string]$Database = 'master', [switch]$MultiSubnetFailover, [int]$Timeout = 15)
    $c = Get-LabConfig
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b['Data Source'] = $Server
    $b['Initial Catalog'] = $Database
    $b['User ID'] = 'sa'
    $b['Password'] = $c.password
    $b['Connect Timeout'] = $Timeout
    $b['Application Name'] = 'sql-ag-lab'
    if ($MultiSubnetFailover) { $b['MultiSubnetFailover'] = $true }
    return $b.ConnectionString
}

function Invoke-LabSql {
    param(
        [Parameter(Mandatory)][string]$Query,
        [string]$Server = 'localhost', [string]$Database = 'master',
        [switch]$MultiSubnetFailover, [int]$CommandTimeout = 300, [switch]$NonQuery
    )
    $conn = New-Object System.Data.SqlClient.SqlConnection (New-LabSqlConnectionString -Server $Server -Database $Database -MultiSubnetFailover:$MultiSubnetFailover)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand(); $cmd.CommandText = $Query; $cmd.CommandTimeout = $CommandTimeout
        if ($NonQuery) { [void]$cmd.ExecuteNonQuery(); return }
        $da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
        $ds = New-Object System.Data.DataSet
        [void]$da.Fill($ds)
        if ($ds.Tables.Count -gt 0) { return , $ds.Tables[0] }
    } finally { $conn.Dispose() }
}

function Wait-LabSql([string]$Server = 'localhost', [int]$TimeoutSeconds = 300) {
    Wait-Until -What "SQL Server on $Server" -TimeoutSeconds $TimeoutSeconds -IntervalSeconds 3 -Condition {
        (Invoke-LabSql -Server $Server -Query 'SELECT 1 AS ok').Rows[0].ok -eq 1
    }
}

function Get-SqlInstanceId {
    (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction Stop).MSSQLSERVER
}

# --- Run a script as the domain administrator ---------------------------------------
# SSH key-based sessions have no network credentials (no Kerberos TGT), so anything
# that must talk to AD or other nodes as a domain admin (New-Cluster, SQL setup with a
# domain service account, dsacls) runs as a one-shot scheduled task with a password logon.
function Invoke-AsDomainAdmin {
    param([Parameter(Mandatory)][string]$Script, [string[]]$Arguments = @(), [int]$TimeoutMinutes = 120)
    $c = Get-LabConfig
    $path = if ([IO.Path]::IsPathRooted($Script)) { $Script } else { Join-Path $script:LabGuestRoot $Script }
    if (-not (Test-Path $path)) { throw "Script not found: $path" }
    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $log = "C:\Lab\logs\runas-$id.log"; $rcFile = "C:\Lab\logs\runas-$id.rc"
    $argStr = ($Arguments | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ' '
    $inner = @"
`$ErrorActionPreference = 'Continue'
`$rc = 1
try {
    & '$path' $argStr *>&1 | ForEach-Object { "`$_" } | Out-File -FilePath '$log' -Encoding utf8 -Append
    `$rc = if (`$null -ne `$LASTEXITCODE) { `$LASTEXITCODE } else { 0 }
    if (-not `$?) { if (`$rc -eq 0) { `$rc = 1 } }
} catch { "`$_" | Out-File -FilePath '$log' -Encoding utf8 -Append; `$rc = 1 }
Set-Content -Path '$rcFile' -Value `$rc
"@
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $enc"
    $task = "LabRunAs-$id"
    Register-ScheduledTask -TaskName $task -Action $action -User "$($c.netbios)\Administrator" -Password $c.password -RunLevel Highest -Force | Out-Null
    try {
        Start-ScheduledTask -TaskName $task
        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        $printed = 0
        while (-not (Test-Path $rcFile)) {
            if ((Get-Date) -gt $deadline) { throw "RunAs $Script timed out after $TimeoutMinutes min" }
            Start-Sleep -Seconds 3
            if (Test-Path $log) {
                $lines = @(Get-Content $log -ErrorAction SilentlyContinue)
                if ($lines.Count -gt $printed) { $lines[$printed..($lines.Count - 1)] | ForEach-Object { Write-Host "    | $_" }; $printed = $lines.Count }
            }
        }
        Start-Sleep -Milliseconds 500
        if (Test-Path $log) {
            $lines = @(Get-Content $log -ErrorAction SilentlyContinue)
            if ($lines.Count -gt $printed) { $lines[$printed..($lines.Count - 1)] | ForEach-Object { Write-Host "    | $_" } }
        }
        return [int](Get-Content $rcFile -Raw).Trim()
    } finally {
        Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
    }
}
