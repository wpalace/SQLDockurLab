#Requires -Version 7.2
# Static checks for the PowerShell operator front end: parse, PSScriptAnalyzer, Pester.
# Usage: pwsh -File tests/validate.ps1   (installs PSScriptAnalyzer/Pester for the current user if missing)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $repo
$rc = 0
$files = @('lab.ps1', 'lib/LabHost.psm1', 'deploy/gcp/lab-gcp.ps1', 'tests/validate.ps1', 'tests/LabGcp.Tests.ps1')
Write-Host '== pwsh parse (operator scripts)'
foreach ($f in $files) {
    $e = $null; [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $f), [ref]$null, [ref]$e)
    if ($e) { $e | ForEach-Object { Write-Host "$f`:$($_.Extent.StartLineNumber) $($_.Message)" }; $rc = 1 }
}
foreach ($m in @(@('PSScriptAnalyzer', '1.21.0'), @('Pester', '5.5.0'))) {
    if (-not (Get-Module -ListAvailable $m[0] | Where-Object { $_.Version -ge [version]$m[1] })) {
        Write-Host "   installing $($m[0]) for the current user"
        Install-Module $m[0] -MinimumVersion $m[1] -Scope CurrentUser -Force -SkipPublisherCheck
    }
}
Write-Host '== PSScriptAnalyzer (Error + Warning)'
# Excluded: Write-Host is the console UI here; the Invoke-*/Set-* verbs run commands, ShouldProcess adds nothing.
$ex = @('PSAvoidUsingWriteHost', 'PSUseShouldProcessForStateChangingFunctions', 'PSUseSingularNouns', 'PSUseApprovedVerbs', 'PSUseBOMForUnicodeEncodedFile', 'PSAvoidGlobalVars')
$r = @($files | ForEach-Object { Invoke-ScriptAnalyzer -Path (Join-Path $repo $_) -Severity Error, Warning -ExcludeRule $ex })
if ($r.Count) { $r | Format-Table -AutoSize RuleName, Severity, ScriptName, Line, Message | Out-String -Width 200 | Write-Host; $rc = 1 } else { Write-Host '   no findings' }
Write-Host '== Pester'
Import-Module Pester -MinimumVersion 5.5.0
$cfg = New-PesterConfiguration
$cfg.Run.Path = Join-Path $repo 'tests/LabGcp.Tests.ps1'; $cfg.Run.PassThru = $true; $cfg.Output.Verbosity = 'Normal'
$p = Invoke-Pester -Configuration $cfg
if ($p.FailedCount -gt 0 -or $p.Result -ne 'Passed') { $rc = 1 }
if ($rc -eq 0) { Write-Host 'ALL POWERSHELL CHECKS PASSED' } else { Write-Host 'POWERSHELL CHECKS FAILED' }
exit $rc
