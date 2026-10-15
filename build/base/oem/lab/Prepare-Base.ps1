<#
.SYNOPSIS
  sql-ag-lab base image, phase 1 (runs once inside the dockur build VM, elevated).
.DESCRIPTION
  Installs the roles/features every lab VM needs, enables OpenSSH with the lab key,
  strips background noise (Defender, Windows Update, scheduled maintenance) so that
  restored checkpoints are quiet and deterministic, installs the clone first-boot
  hook, then reboots into phase 2 (Finalize-Base.ps1 -> sysprep -> power off).
  Windows PowerShell 5.1 compatible.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$LabRoot = 'C:\Lab'
New-Item -ItemType Directory -Force -Path "$LabRoot\logs" | Out-Null
Start-Transcript -Path "$LabRoot\logs\prepare-base.txt" -Append | Out-Null

function Step([string]$m) { Write-Host "==> [Prepare-Base] $m" }
function Try-Do([string]$what, [scriptblock]$sb) {
    try { & $sb } catch { Write-Warning "$what failed: $($_.Exception.Message)" }
}
function Publish-Status([string]$name) {
    # Best effort: drop a marker into dockur's shared folder so the host can follow progress.
    Try-Do 'publish status' {
        Set-Content -Path "\\host.lan\Data\$name" -Value (Get-Date -Format o) -ErrorAction Stop
        Copy-Item "$LabRoot\logs\*" '\\host.lan\Data\' -Force -ErrorAction SilentlyContinue
    }
}

# New-Item -Force on an existing registry key tries to delete and recreate it, which
# fails on keys with protected subkeys (e.g. ServerManager). Only create when missing.
function Initialize-RegKey([string]$path) { if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null } }
# Any terminating error: publish a failure marker + logs so the host stops waiting.
trap {
    Write-Warning "FATAL: $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)"
    Publish-Status 'phase1.failed'
    break
}

$cfg = Get-Content "$LabRoot\generated\lab-config.json" -Raw | ConvertFrom-Json

# SMB guest access to dockur's share (2025 requires signing / blocks guest by default).
$lw = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters'
Try-Do 'smb guest' {
    Set-ItemProperty $lw -Name AllowInsecureGuestAuth -Value 1 -Type DWord
    Set-ItemProperty $lw -Name RequireSecuritySignature -Value 0 -Type DWord
}
Publish-Status 'phase1.started'

Step 'Time zone UTC'
Set-TimeZone -Id 'UTC'

Step 'Windows features'
$features = @(
    'Failover-Clustering', 'RSAT-Clustering-PowerShell', 'RSAT-Clustering-CmdInterface',
    'RSAT-AD-PowerShell', 'RSAT-ADDS-Tools', 'AD-Domain-Services'
)
$r = Install-WindowsFeature -Name $features
Write-Host "  features: success=$($r.Success) restart=$($r.RestartNeeded)"
Step 'Remove Windows Defender (memory/CPU noise; lab only)'
Try-Do 'remove defender' { Uninstall-WindowsFeature -Name Windows-Defender | Out-Null }

Step 'OpenSSH server with lab key'
$cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
if ($cap -and $cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
Set-Service sshd -StartupType Automatic
Start-Service sshd
$ak = 'C:\ProgramData\ssh\administrators_authorized_keys'
Set-Content -Path $ak -Value $cfg.authorizedKey -Encoding ascii
icacls.exe $ak /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
    -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force | Out-Null

Step 'Firewall rules'
Try-Do 'fw ssh' { Enable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' }
Enable-NetFirewallRule -DisplayGroup 'File and Printer Sharing' -ErrorAction SilentlyContinue
Get-NetFirewallRule -Name 'FPS-ICMP4-ERQ-In*' -ErrorAction SilentlyContinue | Enable-NetFirewallRule
$rules = @(
    @{ n = 'Lab-SSH-22';    p = 'TCP'; port = '22' },
    @{ n = 'Lab-SQL-1433';  p = 'TCP'; port = '1433' },
    @{ n = 'Lab-SQL-DAC';   p = 'TCP'; port = '1434' },
    @{ n = 'Lab-SQL-Browser'; p = 'UDP'; port = '1434' },
    @{ n = 'Lab-HADR-5022'; p = 'TCP'; port = '5022' },
    @{ n = 'Lab-ICMPv4';    p = 'ICMPv4'; port = $null }
)
foreach ($x in $rules) {
    if (-not (Get-NetFirewallRule -Name $x.n -ErrorAction SilentlyContinue)) {
        $a = @{ Name = $x.n; DisplayName = $x.n; Direction = 'Inbound'; Action = 'Allow'; Protocol = $x.p; Profile = 'Any' }
        if ($x.port) { $a.LocalPort = $x.port }
        New-NetFirewallRule @a | Out-Null
    }
}

Step 'Quiet the OS (updates, maintenance, telemetry)'
foreach ($svc in 'wuauserv', 'UsoSvc', 'WaaSMedicSvc', 'DiagTrack', 'dmwappushservice', 'MapsBroker') {
    Try-Do "disable $svc" {
        Stop-Service $svc -Force -ErrorAction SilentlyContinue
        Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$svc" -Name Start -Value 4 -Type DWord
    }
}
$au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
Initialize-RegKey $au
Set-ItemProperty $au -Name NoAutoUpdate -Value 1 -Type DWord
$taskPaths = @(
    '\Microsoft\Windows\Defrag\', '\Microsoft\Windows\Server Manager\', '\Microsoft\Windows\UpdateOrchestrator\',
    '\Microsoft\Windows\WindowsUpdate\', '\Microsoft\Windows\Application Experience\',
    '\Microsoft\Windows\Customer Experience Improvement Program\', '\Microsoft\Windows\Diagnosis\',
    '\Microsoft\Windows\DiskDiagnostic\', '\Microsoft\Windows\.NET Framework\', '\Microsoft\Windows\Maintenance\',
    '\Microsoft\Windows\Windows Error Reporting\', '\Microsoft\Windows\Chkdsk\', '\Microsoft\Windows\Data Integrity Scan\'
)
foreach ($tp in $taskPaths) {
    Get-ScheduledTask -TaskPath $tp -ErrorAction SilentlyContinue | ForEach-Object {
        Try-Do "disable task $($_.TaskName)" { $_ | Disable-ScheduledTask | Out-Null }
    }
}
Initialize-RegKey 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance'
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance' -Name MaintenanceDisabled -Value 1 -Type DWord
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' -Name Disabled -Value 1 -Type DWord -ErrorAction SilentlyContinue
Initialize-RegKey 'HKLM:\SOFTWARE\Microsoft\ServerManager'
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\ServerManager' -Name DoNotOpenServerManagerAtLogon -Value 1 -Type DWord

Step 'Power, pagefile, networking defaults'
powercfg.exe /setactive SCHEME_MIN
powercfg.exe /hibernate off
Try-Do 'pagefile' {
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.AutomaticManagedPagefile) { $cs | Set-CimInstance -Property @{ AutomaticManagedPagefile = $false } }
    $pf = Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue
    if ($pf) { $pf | Set-CimInstance -Property @{ InitialSize = 1024; MaximumSize = 2048 } }
    else { New-CimInstance -ClassName Win32_PageFileSetting -Property @{ Name = 'C:\pagefile.sys'; InitialSize = [uint32]1024; MaximumSize = [uint32]2048 } | Out-Null }
}
# Prefer IPv4 + disable IPv6 tunnel adapters (keeps cluster networks clean). 0x21.
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' -Name DisabledComponents -Value 0x21 -Type DWord
# Machine account passwords never rotate: restored checkpoints of any age stay valid
# no matter how far the guest clock moves (TIME_MODE=sync).
$nl = 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters'
Set-ItemProperty $nl -Name DisablePasswordChange -Value 1 -Type DWord
# Allow clean ACPI shutdown from the lock screen; no shutdown event tracker.
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name shutdownwithoutlogon -Value 1 -Type DWord
Initialize-RegKey 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Reliability'
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Reliability' -Name ShutdownReasonOn -Value 0 -Type DWord
# Remote UAC filtering off for local admin accounts (lab convenience for remote mgmt).
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name LocalAccountTokenFilterPolicy -Value 1 -Type DWord
Try-Do 'winrm' { Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null }

Step 'Disable autologon (dockur build user)'
$wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty $wl -Name AutoAdminLogon -Value '0'
Remove-ItemProperty $wl -Name DefaultPassword -ErrorAction SilentlyContinue

Step 'Install clone first-boot hook + unattend'
$scripts = 'C:\Windows\Setup\Scripts'
New-Item -ItemType Directory -Force -Path $scripts | Out-Null
Get-ChildItem $scripts -File | Remove-Item -Force   # drop dockur's own setup hooks
Copy-Item "$LabRoot\SetupComplete.cmd" "$scripts\SetupComplete.cmd" -Force
$xml = (Get-Content "$LabRoot\unattend-clone.xml" -Raw).Replace('__ADMIN_PASSWORD__', [Security.SecurityElement]::Escape($cfg.password))
Set-Content -Path "$LabRoot\unattend-clone.final.xml" -Value $xml -Encoding UTF8

Step 'Register phase 2 (runs as SYSTEM at next boot)'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File $LabRoot\Finalize-Base.ps1"
$trigger = New-ScheduledTaskTrigger -AtStartup
Register-ScheduledTask -TaskName 'LabFinalizeBase' -Action $action -Trigger $trigger -User 'SYSTEM' -RunLevel Highest -Force | Out-Null

Publish-Status 'phase1.done'
Stop-Transcript | Out-Null
Restart-Computer -Force
