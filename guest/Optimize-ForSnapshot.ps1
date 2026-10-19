<# Run on every VM right before the golden checkpoint. Anything still "pending" when the
   memory snapshot is taken would re-run after EVERY restore, so drain it now:
   .NET native image queue, deferred service start work, then wait for CPU idle. #>
param([int]$SettleSeconds = 120)
. "$PSScriptRoot\Common.ps1"
Write-Step 'Draining ngen queue'
foreach ($fw in 'Framework64', 'Framework') {
    $ngen = "$env:windir\Microsoft.NET\$fw\v4.0.30319\ngen.exe"
    if (Test-Path $ngen) { & $ngen executeQueuedItems /nologo /silent | Out-Null }
}
Write-Step 'Re-applying quiet settings (roles may have re-enabled tasks)'
foreach ($tp in '\Microsoft\Windows\Defrag\', '\Microsoft\Windows\Server Manager\', '\Microsoft\Windows\UpdateOrchestrator\',
    '\Microsoft\Windows\.NET Framework\', '\Microsoft\Windows\Application Experience\', '\Microsoft\Windows\Diagnosis\') {
    Get-ScheduledTask -TaskPath $tp -ErrorAction SilentlyContinue | Where-Object State -NE 'Disabled' |
        ForEach-Object { try { $_ | Disable-ScheduledTask | Out-Null } catch { } }
}
[GC]::Collect()
Write-Step "Waiting for CPU idle (<10% for 20s, max ${SettleSeconds}s)"
$deadline = (Get-Date).AddSeconds([Math]::Max($SettleSeconds, 30))
$quiet = 0
while ((Get-Date) -lt $deadline -and $quiet -lt 4) {
    $cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    if ($cpu -lt 10) { $quiet++ } else { $quiet = 0 }
    Start-Sleep -Seconds 5
}
Write-Ok "settled (quiet samples=$quiet)"
exit 0
