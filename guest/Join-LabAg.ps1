<# On each secondary: join the AG and allow automatic seeding to create the database. #>
. "$PSScriptRoot\Common.ps1"
$c = Get-LabConfig
$ag = $c.agName; $db = $c.agDatabase
Wait-LabSql
Wait-LabHadrReady
$joined = (Invoke-LabSql -Query "SELECT COUNT(*) AS n FROM sys.availability_groups WHERE name = N'$ag'").Rows[0].n
if ($joined -eq 0) {
    Write-Step "Joining $ag"
    Wait-Until -What "AG $ag visible in the cluster" -TimeoutSeconds 300 -Condition {
        (Invoke-LabSql -Query "SELECT COUNT(*) AS n FROM sys.availability_groups_cluster WHERE name = N'$ag'").Rows[0].n -eq 1
    }
    Invoke-LabSql -NonQuery -Query "ALTER AVAILABILITY GROUP [$ag] JOIN; ALTER AVAILABILITY GROUP [$ag] GRANT CREATE ANY DATABASE;"
}
Write-Step "Waiting for $db to be seeded"
Wait-Until -What "$db seeded" -TimeoutSeconds 900 -IntervalSeconds 5 -Condition {
    (Invoke-LabSql -Query "SELECT COUNT(*) AS n FROM sys.databases WHERE name = N'$db' AND replica_id IS NOT NULL").Rows[0].n -eq 1
}
Write-Ok "$db present on $env:COMPUTERNAME"
exit 0
