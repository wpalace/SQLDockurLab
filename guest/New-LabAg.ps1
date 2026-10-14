<# On SQL1 (primary): create the lab database and the availability group (automatic seeding). #>
. "$PSScriptRoot\Common.ps1"
$c = Get-LabConfig
$ag = $c.agName; $db = $c.agDatabase
Wait-LabSql

Write-Step "Database $db"
Invoke-LabSql -NonQuery -Query @"
IF DB_ID(N'$db') IS NULL
BEGIN
    CREATE DATABASE [$db];
END;
ALTER DATABASE [$db] SET RECOVERY FULL;
"@
Invoke-LabSql -Database $db -NonQuery -Query @"
IF OBJECT_ID(N'dbo.LabHeartbeat') IS NULL
    CREATE TABLE dbo.LabHeartbeat (id int IDENTITY PRIMARY KEY, server sysname NOT NULL DEFAULT @@SERVERNAME,
                                   at datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME(), note nvarchar(200) NULL);
INSERT dbo.LabHeartbeat(note) VALUES (N'created by New-LabAg.ps1');
"@
# A full backup is required before a database can join an AG.
Invoke-LabSql -NonQuery -Query "BACKUP DATABASE [$db] TO DISK = N'NUL' WITH COPY_ONLY = OFF, INIT;"

$exists = (Invoke-LabSql -Query "SELECT COUNT(*) AS n FROM sys.availability_groups WHERE name = N'$ag'").Rows[0].n
if ($exists -eq 0) {
    Write-Step "CREATE AVAILABILITY GROUP $ag"
    $replicas = foreach ($r in $c.replicas) {
        @"
    N'$($r.name)' WITH (
        ENDPOINT_URL = N'TCP://$($r.name).$($c.domain):5022',
        AVAILABILITY_MODE = $($r.availabilityMode),
        FAILOVER_MODE = $($r.failoverMode),
        SEEDING_MODE = AUTOMATIC,
        BACKUP_PRIORITY = 50,
        PRIMARY_ROLE (ALLOW_CONNECTIONS = ALL),
        SECONDARY_ROLE (ALLOW_CONNECTIONS = ALL))
"@
    }
    Invoke-LabSql -NonQuery -Query @"
CREATE AVAILABILITY GROUP [$ag]
WITH (AUTOMATED_BACKUP_PREFERENCE = SECONDARY, DB_FAILOVER = ON, DTC_SUPPORT = NONE,
      CLUSTER_TYPE = WSFC, HEALTH_CHECK_TIMEOUT = 60000, FAILURE_CONDITION_LEVEL = 3)
FOR DATABASE [$db]
REPLICA ON
$($replicas -join ",`n");
"@
}
Write-Ok "AG $ag exists on $env:COMPUTERNAME"
exit 0
