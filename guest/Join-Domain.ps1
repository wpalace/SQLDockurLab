<# Join this node to the lab domain. Exit 3010 when a reboot is needed. #>
. "$PSScriptRoot\Common.ps1"
$c = Get-LabConfig
$cs = Get-CimInstance Win32_ComputerSystem
if ($cs.PartOfDomain -and $cs.Domain -ieq $c.domain) {
    Write-Ok "Already joined to $($c.domain)"
    exit 0
}
Write-Step "Waiting for DC $($c.dcIp) (LDAP/DNS)"
Wait-Until -What 'DC LDAP' -TimeoutSeconds 900 -Condition {
    (Test-TcpPort -HostName $c.dcIp -Port 389) -and (Test-TcpPort -HostName $c.dcIp -Port 53)
}
Wait-Until -What 'domain DNS' -TimeoutSeconds 600 -Condition {
    Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$($c.domain)" -Type SRV -Server $c.dcIp -ErrorAction Stop
}
Write-Step "Joining $($c.domain)"
Add-Computer -DomainName $c.domain -Credential (Get-LabCredential) -Force -WarningAction SilentlyContinue
Write-Ok 'Joined; reboot required'
exit 3010
