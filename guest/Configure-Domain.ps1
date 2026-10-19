<# Post-promotion configuration on DC1: service account, AD sites/subnets for both lab subnets,
   reverse DNS zones, file share witness, deterministic time + machine-password settings. #>
. "$PSScriptRoot\Common.ps1"
$c = Get-LabConfig
Import-Module ActiveDirectory
Write-Step 'Waiting for AD Web Services'
Wait-Until -What 'AD' -TimeoutSeconds 900 -Condition { Get-ADDomain -ErrorAction Stop }
$dn = (Get-ADDomain).DistinguishedName

Write-Step "Service account $($c.sqlServiceUser)"
# Right after promotion the DC may not have its RID pool yet ("unable to allocate a relative
# identifier", 8208), so retry for up to 10 minutes.
for ($i = 0; -not (Get-ADUser -Filter "SamAccountName -eq '$($c.sqlServiceUser)'" -ErrorAction SilentlyContinue); $i++) {
    if ($i -ge 60) { throw "could not create $($c.sqlServiceUser): RID pool not available" }
    if ($i -gt 0) { Write-Host "    waiting for RID pool ($i)"; Start-Sleep -Seconds 10 }
    try {
        New-ADUser -Name $c.sqlServiceUser -SamAccountName $c.sqlServiceUser -UserPrincipalName "$($c.sqlServiceUser)@$($c.domain)" `
            -AccountPassword (ConvertTo-SecureString $c.password -AsPlainText -Force) -Enabled $true `
            -PasswordNeverExpires $true -CannotChangePassword $true -Description 'SQL Server service account (lab)' -ErrorAction Stop 
    } catch { Write-Host "    New-ADUser: $($_.Exception.Message)" }
}
# Let the service account register its own SPNs (avoids Kerberos SPN warnings / NTLM fallback).
dsacls.exe (Get-ADUser $c.sqlServiceUser).DistinguishedName /G "SELF:RPWP;servicePrincipalName" | Out-Null
Write-Ok 'sqlsvc ready'

Write-Step 'AD sites and subnets'
$siteA = Get-ADReplicationSite -Filter "Name -eq 'SiteA'" -ErrorAction SilentlyContinue
if (-not $siteA) {
    $def = Get-ADReplicationSite -Filter "Name -eq 'Default-First-Site-Name'" -ErrorAction SilentlyContinue
    if ($def) { Rename-ADObject -Identity $def.DistinguishedName -NewName 'SiteA' } else { New-ADReplicationSite -Name 'SiteA' }
}
if (-not (Get-ADReplicationSite -Filter "Name -eq 'SiteB'" -ErrorAction SilentlyContinue)) { New-ADReplicationSite -Name 'SiteB' }
foreach ($s in @(@{ n = $c.netA; site = 'SiteA' }, @{ n = $c.netB; site = 'SiteB' })) {
    if (-not (Get-ADReplicationSubnet -Filter "Name -eq '$($s.n)'" -ErrorAction SilentlyContinue)) {
        New-ADReplicationSubnet -Name $s.n -Site $s.site
    }
}
Write-Ok 'SiteA/SiteB mapped to both subnets'

Write-Step 'DNS reverse zones'
foreach ($net in $c.netA, $c.netB) {
    $o = $net.Split('/')[0].Split('.')
    $zone = "$($o[2]).$($o[1]).$($o[0]).in-addr.arpa"
    if (-not (Get-DnsServerZone -Name $zone -ErrorAction SilentlyContinue)) {
        # Right after promotion the DomainDnsZones partition may not be ready yet
        # (WIN32 9903), so retry for a while, then fall back to a file-backed zone.
        $made = $false
        for ($i = 0; $i -lt 24 -and -not $made; $i++) {
            try { Add-DnsServerPrimaryZone -NetworkId $net -ReplicationScope Domain -DynamicUpdate Secure; $made = $true }
            catch { Start-Sleep -Seconds 5 }
        }
        if (-not $made) {
            Write-Warning "AD-integrated $zone unavailable; creating a file-backed zone"
            Add-DnsServerPrimaryZone -NetworkId $net -ZoneFile "$zone.dns" -DynamicUpdate NonsecureAndSecure
        }
    }
}
# Air-gapped lab: no root hints/forwarders, so failed external lookups return instantly.
Get-DnsServerRootHint -ErrorAction SilentlyContinue | Remove-DnsServerRootHint -Force -ErrorAction SilentlyContinue
Write-Ok 'reverse zones present'

Write-Step 'File share witness'
New-Item -ItemType Directory -Force -Path 'C:\Witness' | Out-Null
if (-not (Get-SmbShare -Name 'Witness' -ErrorAction SilentlyContinue)) {
    New-SmbShare -Name 'Witness' -Path 'C:\Witness' -FullAccess 'Everyone' | Out-Null
}
icacls.exe 'C:\Witness' /grant 'Everyone:(OI)(CI)F' | Out-Null
Write-Ok '\\DC1\Witness'

Write-Step 'Determinism: time source + machine password changes'
w32tm.exe /config /syncfromflags:NO /reliable:YES /update | Out-Null
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters' -Name RefusePasswordChange -Value 1 -Type DWord
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters' -Name DisablePasswordChange -Value 1 -Type DWord
Write-Ok 'done'
exit 0
