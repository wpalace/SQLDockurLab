<# AG failover helper (SQL authentication as sa; runs on any lab VM). Exit 0 = success.
   -Target SQLn      planned manual failover without data loss. If the current primary or the
                     target is asynchronous, both are set to SYNCHRONOUS_COMMIT first; the script
                     waits until the target is SYNCHRONIZED, runs FAILOVER on the target, then
                     restores the availability and failover modes of both replicas.
   -SetModes "SQL1:SYNCHRONOUS_COMMIT:MANUAL SQL2:..."
                     change replica modes on the primary (safe order: MANUAL first, then
                     availability mode, then AUTOMATIC). "config" = the modes in lab.env.
   -Chain "SQL2,SQL3,SQL4,SQL1"
                     planned failover to each replica in turn; after each move a heartbeat row is
                     inserted through the listener and must be visible on the new primary; then
                     all earlier heartbeat rows of the chain must still be there.
   -WaitSync SQLn    wait until SQLn is SYNCHRONIZED with the primary (before a disruption test).
   -Mark             insert a heartbeat row through the listener; print MARK=<note>.
   -WaitPrimary SQLn [-Note N] [-TimeoutSeconds S]
                     wait until the listener reaches SQLn, LabDB is writable, and the row with
                     note N exists; print the time and the listener IP of the connection. #>
param(
    [string]$Target,
    [string]$SetModes,
    [string]$Chain,
    [switch]$Mark,
    [string]$WaitSync,
    [string]$WaitPrimary,
    [string]$Note,
    [int]$TimeoutSeconds = 300
)
. "$PSScriptRoot\Common.ps1"
$c = Get-LabConfig
$ag = $c.agName
$db = $c.agDatabase
$listener = "tcp:$($c.listenerName).$($c.domain),$($c.listenerPort)"
# SQL that returns the address of the current connection (shows which listener IP answered).
$connectionIp = '(SELECT local_net_address FROM sys.dm_exec_connections WHERE session_id = @@SPID)'

function Get-ReplicaServer([string]$Name) {
    $ip = ($c.nodes | Where-Object { $_.name -eq $Name }).ip
    if (-not $ip) { throw "unknown replica $Name" }
    "tcp:$ip,1433"
}
function Get-Primary {
    $query = 'SELECT ars.role_desc AS r FROM sys.dm_hadr_availability_replica_states ars ' +
    "JOIN sys.availability_groups ag ON ag.group_id = ars.group_id AND ag.name = N'$ag' WHERE ars.is_local = 1"
    foreach ($n in $c.nodes.name) {
        try {
            $r = (Invoke-LabSql -Server (Get-ReplicaServer $n) -Query $query).Rows
            if ($r.Count -gt 0 -and $r[0].r -eq 'PRIMARY') { return $n }
        } catch {
            # An unreachable or restarting replica is simply not the primary; try the next one.
            Write-Verbose "$n not reachable: $($_.Exception.Message)"
        }
    }
    throw 'no primary replica found'
}
function Get-ReplicaMode([string]$Primary) {
    $query = 'SELECT ar.replica_server_name AS n, ar.availability_mode_desc AS a, ar.failover_mode_desc AS f ' +
    'FROM sys.availability_replicas ar ' +
    "JOIN sys.availability_groups ag ON ag.group_id = ar.group_id AND ag.name = N'$ag'"
    $m = @{}
    foreach ($r in (Invoke-LabSql -Server (Get-ReplicaServer $Primary) -Query $query).Rows) {
        $m[$r.n] = @{ a = $r.a; f = $r.f }
    }
    $m
}
function Set-ReplicaMode {
    [CmdletBinding(SupportsShouldProcess)]
    param([hashtable]$Want)
    $p = Get-Primary
    $cur = Get-ReplicaMode $p
    $summary = ($Want.Keys | Sort-Object | ForEach-Object { "$_=$($Want[$_].a)/$($Want[$_].f)" }) -join ' '
    if (-not $PSCmdlet.ShouldProcess("availability group $ag on $p", "set replica modes $summary")) { return }
    $alter = {
        param($n, $opt)
        $query = "ALTER AVAILABILITY GROUP [$ag] MODIFY REPLICA ON N'$n' WITH ($opt);"
        Invoke-LabSql -Server (Get-ReplicaServer $p) -NonQuery -Query $query
    }
    # Safe order: MANUAL first, then the availability mode, then AUTOMATIC.
    foreach ($n in $Want.Keys) {
        if ($Want[$n].f -eq 'MANUAL' -and $cur[$n].f -ne 'MANUAL') { & $alter $n 'FAILOVER_MODE = MANUAL' }
    }
    foreach ($n in $Want.Keys) {
        if ($Want[$n].a -ne $cur[$n].a) { & $alter $n "AVAILABILITY_MODE = $($Want[$n].a)" }
    }
    foreach ($n in $Want.Keys) {
        if ($Want[$n].f -eq 'AUTOMATIC' -and $cur[$n].f -ne 'AUTOMATIC') {
            & $alter $n 'FAILOVER_MODE = AUTOMATIC'
        }
    }
    Write-Ok "modes on ${p}: $summary"
}
function ConvertTo-ReplicaMode([string]$Spec) {
    $h = @{}
    if ($Spec -eq 'config') {
        foreach ($r in $c.replicas) { $h[$r.name] = @{ a = $r.availabilityMode; f = $r.failoverMode } }
        return $h
    }
    foreach ($e in ($Spec -split '\s+' | Where-Object { $_ })) {
        $n, $a, $f = $e -split ':'
        $h[$n] = @{ a = $a; f = $f }
    }
    $h
}
function Wait-Synchronized([string]$Primary, [string]$Name, [int]$TimeoutSeconds = 300) {
    $query = 'SELECT drs.synchronization_state_desc AS s FROM sys.dm_hadr_database_replica_states drs ' +
    "JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id WHERE ar.replica_server_name = N'$Name'"
    Wait-Until -What "$Name SYNCHRONIZED" -TimeoutSeconds $TimeoutSeconds -IntervalSeconds 1 -Condition {
        (Invoke-LabSql -Server (Get-ReplicaServer $Primary) -Query $query).Rows[0].s -eq 'SYNCHRONIZED'
    }
}
function Invoke-SafeFailover([string]$To) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Get-Primary
    if ($p -eq $To) {
        Write-Ok "$To is primary already"
        return
    }
    $orig = Get-ReplicaMode $p
    $tmp = @{}
    foreach ($n in @($p, $To)) { $tmp[$n] = @{ a = 'SYNCHRONOUS_COMMIT'; f = $orig[$n].f } }
    if ($orig[$p].a -ne 'SYNCHRONOUS_COMMIT' -or $orig[$To].a -ne 'SYNCHRONOUS_COMMIT') {
        Write-Step "temporary SYNCHRONOUS_COMMIT for $p and $To"
        Set-ReplicaMode -Want $tmp
    }
    Wait-Synchronized -Primary $p -Name $To
    Write-Step "FAILOVER $p -> $To"
    Invoke-LabSql -Server (Get-ReplicaServer $To) -NonQuery -Query "ALTER AVAILABILITY GROUP [$ag] FAILOVER;"
    $back = @{}
    foreach ($n in @($p, $To)) { $back[$n] = $orig[$n] }
    Wait-Until -What "$To primary" -TimeoutSeconds 120 -IntervalSeconds 1 -Condition { (Get-Primary) -eq $To }
    Set-ReplicaMode -Want $back
    Write-Ok ('planned failover {0} -> {1} in {2:N1} s (no data loss: target was SYNCHRONIZED)' -f
        $p, $To, $sw.Elapsed.TotalSeconds)
}
function Add-Mark([string]$Tag) {
    $n = "$Tag $([guid]::NewGuid().ToString('N').Substring(0, 12))"
    Wait-Until -What 'listener write' -TimeoutSeconds 120 -IntervalSeconds 1 -Condition {
        $query = "INSERT dbo.LabHeartbeat(note) VALUES (N'$n');"
        Invoke-LabSql -Server $listener -Database $db -MultiSubnetFailover -NonQuery -Query $query
        $true
    }
    $n
}
function Test-Mark([string]$Server, [string]$Name, [switch]$Msf) {
    $query = "SELECT @@SERVERNAME AS s, COUNT(*) AS n, $connectionIp AS ip " +
    "FROM dbo.LabHeartbeat WHERE note = N'$Name'"
    (Invoke-LabSql -Server $Server -Database $db -MultiSubnetFailover:$Msf -Query $query).Rows[0]
}

if ($SetModes) { Set-ReplicaMode -Want (ConvertTo-ReplicaMode $SetModes) }
if ($Target) { Invoke-SafeFailover $Target.ToUpper() }
if ($WaitSync) {
    $p = Get-Primary
    Wait-Synchronized -Primary $p -Name $WaitSync.ToUpper()
    Write-Ok "$($WaitSync.ToUpper()) SYNCHRONIZED with primary $p"
}
if ($Mark) { Write-Output "MARK=$(Add-Mark 'mark')" }
if ($Chain) {
    $all = [Diagnostics.Stopwatch]::StartNew()
    $marks = @()
    foreach ($to in ($Chain -split ',')) {
        $to = $to.Trim().ToUpper()
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Invoke-SafeFailover $to
        $m = Add-Mark "chain $to"
        $marks += $m
        $r = Test-Mark -Server $listener -Name $m -Msf
        if ($r.s -ne $to -or $r.n -ne 1) {
            throw "after failover to $to the listener reached $($r.s) (rows $($r.n))"
        }
        foreach ($old in $marks) {
            $found = Test-Mark -Server (Get-ReplicaServer $to) -Name $old
            if ($found.n -ne 1) { throw "row '$old' missing on $to" }
        }
        $format = 'chain step -> {0}: listener -> {0} ({1}), heartbeat visible, ' +
        '{2} earlier rows intact, {3:N1} s'
        Write-Ok ($format -f
            $to, $r.ip, ($marks.Count - 1), $sw.Elapsed.TotalSeconds)
    }
    Set-ReplicaMode -Want (ConvertTo-ReplicaMode 'config')
    Write-Ok ('failover chain {0} done in {1:N1} s; modes restored from lab.env' -f
        $Chain, $all.Elapsed.TotalSeconds)
}
if ($WaitPrimary) {
    $want = $WaitPrimary.ToUpper()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $last = ''
    $query = "INSERT dbo.LabHeartbeat(note) VALUES (N'after failover'); SELECT @@SERVERNAME AS s, " +
    "$connectionIp AS ip, (SELECT COUNT(*) FROM dbo.LabHeartbeat WHERE note = N'$Note') AS n"
    while ($true) {
        try {
            $r = Invoke-LabSql -Server $listener -Database $db -MultiSubnetFailover -Query $query
            $row = $r.Rows[0]
            $last = "listener -> $($row.s)"
            if ($row.s -eq $want) {
                if ($Note -and $row.n -ne 1) { throw "row '$Note' missing on $want (data loss)" }
                $rowState = if ($Note) { 'intact' } else { 'n/a' }
                Write-Output ('ONLINE primary={0} listener_ip={1} seconds={2:N1} row={3}' -f
                    $row.s, $row.ip, $sw.Elapsed.TotalSeconds, $rowState)
                exit 0
            }
        } catch {
            if ($_.Exception.Message -like '*data loss*') { throw }
            $last = $_.Exception.Message
        }
        if ($sw.Elapsed.TotalSeconds -gt $TimeoutSeconds) {
            throw "no automatic failover to $want after ${TimeoutSeconds}s (last: $last)"
        }
        Start-Sleep -Milliseconds 500
    }
}
exit 0
