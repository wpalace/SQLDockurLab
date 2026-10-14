<# Enable Always On on the local default instance and create the HADR endpoint. Idempotent. #>
. "$PSScriptRoot\Common.ps1"
$c = Get-LabConfig
$svcLogin = "$($c.netbios)\$($c.sqlServiceUser)"
Wait-LabSql
$enabled = (Invoke-LabSql -Query "SELECT CAST(SERVERPROPERTY('IsHadrEnabled') AS int) AS h").Rows[0].h
if ($enabled -ne 1) {
    Write-Step 'Enabling Always On availability groups'
    $done = $false
    # Preferred: SQL Server WMI provider (what Enable-SqlAlwaysOn does under the hood).
    $ns = Get-CimInstance -Namespace 'root\Microsoft\SqlServer' -ClassName __NAMESPACE -ErrorAction SilentlyContinue |
        Where-Object Name -like 'ComputerManagement*' | Sort-Object Name -Descending | Select-Object -First 1
    if ($ns) {
        $flag = Get-CimInstance -Namespace "root\Microsoft\SqlServer\$($ns.Name)" -ClassName ServerSettingsGeneralFlag `
            -Filter "FlagName='Hadr' AND InstanceName='MSSQLSERVER'" -ErrorAction SilentlyContinue
        if ($flag) { $r = Invoke-CimMethod -InputObject $flag -MethodName SetValue -Arguments @{ FlagValue = $true }; $done = ($r.ReturnValue -eq 0) }
    }
    if (-not $done) {
        # Fallback: the same registry value the WMI provider writes.
        $key = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$(Get-SqlInstanceId)\MSSQLServer\HADR"
        New-Item -Path $key -Force | Out-Null
        Set-ItemProperty -Path $key -Name HADR_Enabled -Value 1 -Type DWord
    }
    Restart-Service MSSQLSERVER -Force
    Start-Service SQLSERVERAGENT -ErrorAction SilentlyContinue
    Wait-LabSql
    $enabled = (Invoke-LabSql -Query "SELECT CAST(SERVERPROPERTY('IsHadrEnabled') AS int) AS h").Rows[0].h
    if ($enabled -ne 1) { throw 'HADR still disabled after restart (is this node a member of the cluster?)' }
}
Write-Ok 'IsHadrEnabled = 1'

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
