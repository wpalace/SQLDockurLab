<# Deep health check, run on any SQL node. Exit 0 only if the whole lab is healthy:
   all cluster nodes Up, every AG replica CONNECTED + HEALTHY, sync replicas SYNCHRONIZED (when the primary is sync),
   listener reachable through MultiSubnetFailover and a write through it succeeds.
   -Json emits a machine-readable summary (used by `./lab health --deep`). #>
param([switch]$Json, [int]$WaitSeconds = 0)
. "$PSScriptRoot\Common.ps1"
$c = Get-LabConfig
$deadline = (Get-Date).AddSeconds($WaitSeconds)
do {
    $problems = New-Object System.Collections.Generic.List[string]
    $result = [ordered]@{ checkedAt = (Get-Date).ToUniversalTime().ToString('o'); node = $env:COMPUTERNAME }
    try {
        Import-Module FailoverClusters -ErrorAction Stop
        $nodes = @(Get-ClusterNode | ForEach-Object { [ordered]@{ name = $_.Name; state = "$($_.State)" } })
        $result.clusterNodes = $nodes
        $nodes | Where-Object { $_.state -ne 'Up' } | ForEach-Object { $problems.Add("cluster node $($_.name) is $($_.state)") }
    } catch { $problems.Add("cluster query failed: $($_.Exception.Message)") }
    try {
        # Query the primary (via the listener): a secondary only sees its own replica state.
        $rows = Invoke-LabSql -Server "tcp:$($c.listenerName).$($c.domain),$($c.listenerPort)" -MultiSubnetFailover -Query @"
SELECT ar.replica_server_name AS replica, ars.role_desc AS role, ars.connected_state_desc AS connected,
       ars.synchronization_health_desc AS health, ar.availability_mode_desc AS mode,
       ISNULL(drs.synchronization_state_desc, N'') AS dbstate
FROM sys.availability_replicas ar
JOIN sys.availability_groups ag ON ag.group_id = ar.group_id AND ag.name = N'$($c.agName)'
LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id
LEFT JOIN sys.dm_hadr_database_replica_states drs ON drs.replica_id = ar.replica_id
ORDER BY ar.replica_server_name;
"@
        $reps = @(); if ($rows) { foreach ($r in $rows.Rows) { $reps += [ordered]@{ replica = $r.replica; role = "$($r.role)"; connected = "$($r.connected)"; health = "$($r.health)"; mode = $r.mode; db = $r.dbstate } } }
        $result.replicas = $reps
        if ($reps.Count -ne @($c.replicas).Count) { $problems.Add("expected $(@($c.replicas).Count) replicas, found $($reps.Count)") }
        $primaryMode = @($reps | Where-Object { $_.role -eq 'PRIMARY' } | ForEach-Object { $_.mode })[0]
        foreach ($r in $reps) {
            if ($r.connected -and $r.connected -ne 'CONNECTED') { $problems.Add("$($r.replica) $($r.connected)") }
            if ($r.health -ne 'HEALTHY') { $problems.Add("$($r.replica) health=$($r.health)") }
            # A secondary is synchronous only when the primary is synchronous too: with an
            # asynchronous primary (for example SQL3 after a planned failover) SYNCHRONIZING is correct.
            if ($r.mode -eq 'SYNCHRONOUS_COMMIT' -and $primaryMode -eq 'SYNCHRONOUS_COMMIT' -and $r.db -ne 'SYNCHRONIZED') { $problems.Add("$($r.replica) db=$($r.db)") }
            if ($r.db -and $r.db -notin @('SYNCHRONIZED', 'SYNCHRONIZING')) { $problems.Add("$($r.replica) db=$($r.db)") }
        }
    } catch { $problems.Add("AG query failed: $($_.Exception.Message)") }
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $t = Invoke-LabSql -Server "tcp:$($c.listenerName).$($c.domain),$($c.listenerPort)" -Database $c.agDatabase -MultiSubnetFailover -Query @"
INSERT dbo.LabHeartbeat(note) VALUES (N'Test-Lab via listener');
SELECT @@SERVERNAME AS primary_server, COUNT(*) AS n FROM dbo.LabHeartbeat;
"@
        $result.listener = [ordered]@{ name = $c.listenerName; primary = $t.Rows[0].primary_server; ms = $sw.ElapsedMilliseconds }
    } catch { $problems.Add("listener write failed: $($_.Exception.Message)") }
    $result.healthy = ($problems.Count -eq 0)
    $result.problems = @($problems)
    if ($result.healthy -or (Get-Date) -gt $deadline) { break }
    Start-Sleep -Seconds 3
} while ($true)

if ($Json) { $result | ConvertTo-Json -Depth 5 -Compress | Write-Output }
else {
    $result.clusterNodes | ForEach-Object { Write-Host ("  node    {0,-6} {1}" -f $_.name, $_.state) }
    $result.replicas | ForEach-Object { Write-Host ("  replica {0,-6} {1,-10} {2,-10} {3,-9} {4}" -f $_.replica, $_.role, $_.connected, $_.health, $_.db) }
    if ($result.Contains('listener')) { Write-Host "  listener $($result.listener.name) -> $($result.listener.primary) ($($result.listener.ms) ms)" }
    if ($result.healthy) { Write-Host '  HEALTHY' } else { $result.problems | ForEach-Object { Write-Host "  PROBLEM: $_" } }
}
if ($result.healthy) { exit 0 } else { exit 1 }
