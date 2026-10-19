#Requires -Version 7.4
<#
.SYNOPSIS
    Static checks for the PowerShell operator front end: parse, PSScriptAnalyzer, Pester.
.DESCRIPTION
    PSScriptAnalyzer uses the house settings (PSScriptAnalyzerSettings.psd1). Installs PSScriptAnalyzer
    1.25+ and Pester 5.5+ for the current user when missing. tests/standards-check.sh runs the same
    analyzer settings, plus Invoke-Formatter, over every PowerShell file in the repository.
.EXAMPLE
    pwsh -NoProfile -File tests/validate.ps1
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Console report of a test script.')]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..')).Path
Set-Location -Path $repo
$rc = 0
$files = @('lab.ps1', 'lib/LabHost.psm1', 'deploy/gcp/lab-gcp.ps1', 'tests/validate.ps1', 'tests/LabGcp.Tests.ps1')

Write-Host '== pwsh parse (operator scripts)'
foreach ($f in $files) {
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        (Join-Path -Path $repo -ChildPath $f), [ref]$null, [ref]$parseErrors)
    if ($parseErrors) {
        foreach ($e in $parseErrors) {
            Write-Host "${f}:$($e.Extent.StartLineNumber) $($e.Message)"
        }
        $rc = 1
    }
}

$modules = @(
    @{ Name = 'PSScriptAnalyzer'; Minimum = [version]'1.25.0' }
    @{ Name = 'Pester'; Minimum = [version]'5.5.0' }
)
foreach ($m in $modules) {
    $found = Get-Module -ListAvailable -Name $m.Name | Where-Object { $_.Version -ge $m.Minimum }
    if (-not $found) {
        Write-Host "   installing $($m.Name) for the current user"
        Install-Module -Name $m.Name -MinimumVersion $m.Minimum -Scope CurrentUser -Force -SkipPublisherCheck
    }
}

Write-Host '== PSScriptAnalyzer (PSScriptAnalyzerSettings.psd1)'
Import-Module -Name PSScriptAnalyzer -MinimumVersion 1.25.0
$settings = Join-Path -Path $repo -ChildPath 'PSScriptAnalyzerSettings.psd1'
$findings = @(
    foreach ($f in $files) {
        Invoke-ScriptAnalyzer -Path (Join-Path -Path $repo -ChildPath $f) -Settings $settings
    }
)
if ($findings.Count) {
    $findings | Format-Table -AutoSize -Property RuleName, Severity, ScriptName, Line, Message |
        Out-String -Width 200 | Write-Host
    $rc = 1
} else {
    Write-Host '   no findings'
}

Write-Host '== Pester'
Import-Module -Name Pester -MinimumVersion 5.5.0
$cfg = New-PesterConfiguration
$cfg.Run.Path = Join-Path -Path $repo -ChildPath 'tests/LabGcp.Tests.ps1'
$cfg.Run.PassThru = $true
$cfg.Output.Verbosity = 'Normal'
$result = Invoke-Pester -Configuration $cfg
if ($result.FailedCount -gt 0 -or $result.Result -ne 'Passed') {
    $rc = 1
}

if ($rc -eq 0) {
    Write-Host 'ALL POWERSHELL CHECKS PASSED'
} else {
    Write-Host 'POWERSHELL CHECKS FAILED'
}
exit $rc
