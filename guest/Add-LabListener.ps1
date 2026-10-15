<# On the primary: add the multi-subnet listener (one IP per subnet) and tune its DNS behaviour. #>
. "$PSScriptRoot\Common.ps1"
$c = Get-LabConfig
$ag = $c.agName
$n = (Invoke-LabSql -Query "SELECT COUNT(*) AS n FROM sys.availability_group_listeners l JOIN sys.availability_groups g ON g.group_id = l.group_id WHERE g.name = N'$ag'").Rows[0].n
if ($n -eq 0) {
    Write-Step "Listener $($c.listenerName) [$($c.listenerIpA), $($c.listenerIpB)]:$($c.listenerPort)"
    Invoke-LabSql -NonQuery -Query @"
ALTER AVAILABILITY GROUP [$ag] ADD LISTENER N'$($c.listenerName)' (
    WITH IP ((N'$($c.listenerIpA)', N'$($c.netmask)'), (N'$($c.listenerIpB)', N'$($c.netmask)')),
    PORT = $($c.listenerPort));
"@
}
Import-Module FailoverClusters
$res = Get-ClusterResource | Where-Object { $_.ResourceType.Name -eq 'Network Name' -and $_.OwnerGroup.Name -eq $ag } | Select-Object -First 1
if ($res) {
    # RegisterAllProvidersIP=1 (both IPs in DNS, clients use MultiSubnetFailover=True); short TTL.
    $want = @{ RegisterAllProvidersIP = 1; HostRecordTTL = 60 }
    $cur = @{}; $res | Get-ClusterParameter -Name @($want.Keys) | ForEach-Object { $cur[$_.Name] = $_.Value }
    $changed = @($want.Keys | Where-Object { "$($cur[$_])" -ne "$($want[$_])" })
    if ($changed) {
        $res | Set-ClusterParameter -Multiple $want -WarningAction SilentlyContinue
        # Network Name parameters apply only after an offline/online cycle. Stopping the name
        # also stops the listener resource that depends on it; starting the group restores all.
        Write-Step "Cycling $($res.Name) to apply $($changed -join ', ')"
        Stop-ClusterResource -InputObject $res -Wait 60 | Out-Null
        Start-ClusterGroup -Name $ag -Wait 120 | Out-Null
        Wait-Until -What "listener resources online" -TimeoutSeconds 120 -IntervalSeconds 2 -Condition {
            -not (Get-ClusterResource | Where-Object { $_.OwnerGroup.Name -eq $ag -and $_.State -ne 'Online' })
        }
    }
}
Write-Ok "Listener $($c.listenerName) configured"
exit 0
