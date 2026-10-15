<# Enable Always On on the local default instance and create the HADR endpoint. Idempotent. #>
. "$PSScriptRoot\Common.ps1"
$c = Get-LabConfig
$svcLogin = "$($c.netbios)\$($c.sqlServiceUser)"
Wait-LabSql
$enabled = (Invoke-LabSql -Query "SELECT CAST(SERVERPROPERTY('IsHadrEnabled') AS int) AS h").Rows[0].h
if ($enabled -ne 1) {
    Write-Step 'Enabling Always On availability groups'
    # Enable only once the local cluster node is Up, or the replica manager can hang waiting for WSFC.
    Wait-Until -What "cluster node $env:COMPUTERNAME Up" -TimeoutSeconds 300 -IntervalSeconds 3 -Condition {
        (Get-ClusterNode -Name $env:COMPUTERNAME -ErrorAction Stop).State -eq 'Up'
    }
    # Preferred: Enable-SqlAlwaysOn (SqlServer or the SQLPS module SQL Setup installs). Besides the
    # HADR flag it grants the service SID cluster access and registers the AG resource type;
    # without that CREATE AVAILABILITY GROUP fails with 35222 / 41105. It restarts the service.
    $done = $false
    foreach ($m in 'SqlServer', 'SQLPS') {
        if ($done -or -not (Get-Module -ListAvailable $m)) { continue }
        try {
            Import-Module $m -DisableNameChecking -ErrorAction Stop 3>$null
            Enable-SqlAlwaysOn -ServerInstance $env:COMPUTERNAME -Force -ErrorAction Stop
            $done = $true
        } catch { Write-Warning "Enable-SqlAlwaysOn via $m failed: $($_.Exception.Message)" }
    }
    if (-not $done) {
        # Fallback: the HADR flag in the registry plus the cluster pieces done by hand.
        Write-Warning 'falling back to registry HADR flag + manual cluster ACL / resource type'
        $key = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$(Get-SqlInstanceId)\MSSQLServer\HADR"
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        Set-ItemProperty -Path $key -Name HADR_Enabled -Value 1 -Type DWord
        Grant-LabSqlClusterAccess
        Register-LabAgResourceType
        Restart-Service MSSQLSERVER -Force
    }
    Start-Service SQLSERVERAGENT -ErrorAction SilentlyContinue
    Wait-LabSql
    $enabled = (Invoke-LabSql -Query "SELECT CAST(SERVERPROPERTY('IsHadrEnabled') AS int) AS h").Rows[0].h
    if ($enabled -ne 1) { throw 'HADR still disabled after restart (is this node a member of the cluster?)' }
}
Wait-LabHadrReady
Write-Ok 'IsHadrEnabled = 1, HADR manager running'

Write-Step 'HADR endpoint'
Invoke-LabSql -NonQuery -Query @"
IF SUSER_ID(N'$svcLogin') IS NULL CREATE LOGIN [$svcLogin] FROM WINDOWS;
IF NOT EXISTS (SELECT 1 FROM sys.database_mirroring_endpoints)
    CREATE ENDPOINT [Hadr_endpoint] STATE = STARTED
    AS TCP (LISTENER_PORT = 5022, LISTENER_IP = ALL)
    FOR DATABASE_MIRRORING (ROLE = ALL, AUTHENTICATION = WINDOWS NEGOTIATE, ENCRYPTION = REQUIRED ALGORITHM AES);
ALTER ENDPOINT [Hadr_endpoint] STATE = STARTED;
GRANT CONNECT ON ENDPOINT::[Hadr_endpoint] TO [$svcLogin];
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = 'AlwaysOn_health')
BEGIN
    ALTER EVENT SESSION [AlwaysOn_health] ON SERVER WITH (STARTUP_STATE = ON);
    IF NOT EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = 'AlwaysOn_health')
        ALTER EVENT SESSION [AlwaysOn_health] ON SERVER STATE = START;
END
"@
Write-Ok 'Hadr_endpoint on 5022'
exit 0
