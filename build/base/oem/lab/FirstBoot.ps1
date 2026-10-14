<#
.SYNOPSIS
  First boot of a sysprep'd lab clone (SYSTEM, via SetupComplete.cmd).
.DESCRIPTION
  Per-VM identity is NOT baked into the image. The launcher passes it through the
  SMBIOS system serial number:  LAB;<name>;<ip>;<prefix>;<gateway>;<dns>
  so one base image serves every node and the IP plan can change without a rebuild.
  Sets the static IP on the single NIC, renames the computer and reboots.
#>
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path 'C:\Lab\logs' | Out-Null
$serial = (Get-CimInstance Win32_BIOS).SerialNumber
Write-Host "$(Get-Date -Format o) FirstBoot serial='$serial'"
$p = $serial -split ';'
if ($p.Count -lt 6 -or $p[0] -ne 'LAB') { Write-Host 'No lab identity in SMBIOS serial; nothing to do.'; exit 0 }
$name, $ip, $prefix, $gw, $dns = $p[1], $p[2], [int]$p[3], $p[4], $p[5]

# Wait for the NIC (PnP may still be enumerating right after specialize).
$deadline = (Get-Date).AddMinutes(5)
do { $nic = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Select-Object -First 1; if (-not $nic) { Start-Sleep 2 } }
until ($nic -or (Get-Date) -gt $deadline)
if (-not $nic) { throw 'No network adapter found' }

Rename-NetAdapter -Name $nic.Name -NewName 'Lab' -ErrorAction SilentlyContinue
$nic = Get-NetAdapter -Name 'Lab' -ErrorAction SilentlyContinue
if (-not $nic) { $nic = Get-NetAdapter -Physical | Select-Object -First 1 }
Set-NetIPInterface -InterfaceIndex $nic.ifIndex -Dhcp Disabled
Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
Get-NetRoute -InterfaceIndex $nic.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
New-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress $ip -PrefixLength $prefix -DefaultGateway $gw | Out-Null
Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $dns
Write-Host "IP $ip/$prefix gw $gw dns $dns on $($nic.Name)"

if ($env:COMPUTERNAME -ne $name) { Rename-Computer -NewName $name -Force; Write-Host "Renamed to $name" }
Set-Content 'C:\Lab\firstboot.done' (Get-Date -Format o)
shutdown.exe /r /t 5 /c 'sql-ag-lab first boot' /d p:4:1
