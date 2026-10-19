<# Create the 4-node, two-subnet WSFC (run on SQL1 via RunAs.ps1 as LAB\Administrator).
   One static cluster IP per subnet (OR dependency), file share witness on DC1,
   relaxed heartbeat thresholds, and rights for the CNO to create the listener VCO. #>
. "$PSScriptRoot\Common.ps1"
$c = Get-LabConfig
Import-Module FailoverClusters
$nodes = @($c.nodes | ForEach-Object { $_.name })

$existing = Get-Cluster -ErrorAction SilentlyContinue
if (-not $existing) {
    Write-Step "Waiting for all nodes to be reachable: $($nodes -join ', ')"
    foreach ($n in $c.nodes) {
        Wait-Until -What "$($n.name) SMB" -TimeoutSeconds 600 -Condition { Test-TcpPort -HostName $n.ip -Port 445 }
    }
    Write-Step "New-Cluster $($c.clusterName) [$($c.clusterIpA), $($c.clusterIpB)]"
    New-Cluster -Name $c.clusterName -Node $nodes -StaticAddress $c.clusterIpA, $c.clusterIpB -NoStorage `
        -AdministrativeAccessPoint ActiveDirectoryAndDns -Force -WarningAction SilentlyContinue | Out-Null
} else { Write-Ok "Cluster $($existing.Name) already exists" }

Wait-Until -What 'all cluster nodes Up' -TimeoutSeconds 600 -Condition {
    @(Get-ClusterNode | Where-Object State -NE 'Up').Count -eq 0
}
$missing = $nodes | Where-Object { $_ -notin @(Get-ClusterNode | ForEach-Object Name) }
foreach ($m in $missing) {
    Write-Step "Adding node $m"
    Add-ClusterNode -Name $m -NoStorage | Out-Null
}

Write-Step 'Quorum: file share witness'
$q = Get-ClusterQuorum
if (-not $q.QuorumResource -or $q.QuorumResource.ResourceType.Name -ne 'File Share Witness') {
    Set-ClusterQuorum -FileShareWitness "\\$($c.dcName).$($c.domain)\Witness" | Out-Null
}

Write-Step 'Cluster tuning'
$cl = Get-Cluster
$cl.SameSubnetThreshold = [uint32]$c.sameSubnetThreshold
$cl.CrossSubnetThreshold = [uint32]$c.crossSubnetThreshold
foreach ($net in Get-ClusterNetwork) {
    $addr = "$($net.Address)/$($net.AddressMask)"
    if ($net.Address -eq $c.netA.Split('/')[0]) { $net.Name = 'SubnetA' }
    elseif ($net.Address -eq $c.netB.Split('/')[0]) { $net.Name = 'SubnetB' }
    $net.Role = 3   # cluster and client
    Write-LabLine "    network $($net.Name) $addr role=$($net.Role)"
}
# Short DNS TTL for the cluster name.
Get-ClusterResource -Name 'Cluster Name' |
    Set-ClusterParameter -Name HostRecordTTL -Value 60 -ErrorAction SilentlyContinue

Write-Step 'Grant the CNO rights to create computer objects (listener VCO)'
$dn = (Get-ADDomain).DistinguishedName
dsacls.exe "CN=Computers,$dn" /G "$($c.netbios)\$($c.clusterName)`$:CC;computer" | Out-Null

Get-ClusterNode | Format-Table -AutoSize -Property Name, State | Out-String | Write-LabLine
Write-Ok "Cluster $($c.clusterName) ready"
exit 0
