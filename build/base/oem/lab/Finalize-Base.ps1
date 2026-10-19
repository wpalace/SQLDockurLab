<#
.SYNOPSIS
  sql-ag-lab base image, phase 2 (SYSTEM, at startup after phase 1 reboot).
  Precompiles .NET, shrinks the component store, trims free space, then
  sysprep /generalize /oobe /shutdown /mode:vm with the clone unattend file.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$LabRoot = 'C:\Lab'
Start-Transcript -Path "$LabRoot\logs\finalize-base.txt" -Append | Out-Null
function Step([string]$m) { Write-Host "==> [Finalize-Base] $(Get-Date -Format s) $m" }
function Publish-Status([string]$name) {
    try {
        Set-Content "\\host.lan\Data\$name" (Get-Date -Format o) -ErrorAction Stop
        Copy-Item "$LabRoot\logs\*" '\\host.lan\Data\' -Force -ErrorAction SilentlyContinue 
    } catch { }
}
Unregister-ScheduledTask -TaskName 'LabFinalizeBase' -Confirm:$false -ErrorAction SilentlyContinue
Start-Sleep -Seconds 30   # let boot-time services settle
trap {
    Write-Warning "FATAL: $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)"
    Publish-Status 'phase2.failed'
    break
}
Publish-Status 'phase2.started'

Step 'ngen queued items (otherwise .NET recompiles after every restore)'
foreach ($fw in 'Framework64', 'Framework') {
    $ngen = "$env:windir\Microsoft.NET\$fw\v4.0.30319\ngen.exe"
    if (Test-Path $ngen) { & $ngen executeQueuedItems /nologo /silent | Out-Null }
}

Step 'Component store cleanup (smaller base image)'
& dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase /Quiet | Out-Null

Step 'Remove build user'
Get-CimInstance Win32_UserProfile | Where-Object { $_.LocalPath -like '*\labbuild' } | Remove-CimInstance -ErrorAction SilentlyContinue
Remove-LocalUser -Name 'labbuild' -ErrorAction SilentlyContinue

Step 'Trim free space (so qemu-img convert produces a compact base)'
Optimize-Volume -DriveLetter C -ReTrim -ErrorAction SilentlyContinue | Out-Null
Remove-Item 'C:\OEM' -Recurse -Force -ErrorAction SilentlyContinue

Step 'Sysprep'
Publish-Status 'sysprep.started'
Stop-Transcript | Out-Null
& "$env:windir\System32\Sysprep\sysprep.exe" /generalize /oobe /shutdown /quiet /mode:vm "/unattend:$LabRoot\unattend-clone.final.xml"
