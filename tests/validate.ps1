#Requires -Version 7.4
<#
.SYNOPSIS
    Static checks for the PowerShell operator front end: parse, PSScriptAnalyzer, Pester; and the
    Windows PowerShell 5.1 syntax of the guest scripts.
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

# PSScriptAnalyzer 1.25 on pwsh 7.6 sometimes crashes in UseCorrectCasing (NullReferenceException in
# CommandInfo.Parameters). Retry only that crash, at most 3 runs per file.
function Invoke-AnalyzerWithRetry([string]$Path, [object]$Settings) {
    foreach ($attempt in 1..3) {
        try {
            return Invoke-ScriptAnalyzer -Path $Path -Settings $Settings
        } catch [System.NullReferenceException] {
            Write-Host "   PSScriptAnalyzer crashed on $Path (known 1.25 race); retry $attempt"
        } catch {
            if ($_.Exception.Message -notmatch 'Object reference not set') { throw }
            Write-Host "   PSScriptAnalyzer crashed on $Path (known 1.25 race); retry $attempt"
        }
    }
    throw "PSScriptAnalyzer crashed 3 times on $Path"
}

Write-Host '== PSScriptAnalyzer (PSScriptAnalyzerSettings.psd1)'
Import-Module -Name PSScriptAnalyzer -MinimumVersion 1.25.0
$settings = Join-Path -Path $repo -ChildPath 'PSScriptAnalyzerSettings.psd1'
$findings = @(
    foreach ($f in $files) {
        Invoke-AnalyzerWithRetry -Path (Join-Path -Path $repo -ChildPath $f) -Settings $settings
    }
)
if ($findings.Count) {
    $findings | Format-Table -AutoSize -Property RuleName, Severity, ScriptName, Line, Message |
        Out-String -Width 200 | Write-Host
    $rc = 1
} else {
    Write-Host '   no findings'
}

Write-Host '== pwsh parse and Windows PowerShell 5.1 syntax (guest and base image scripts run in 5.1)'
$compat = @{
    IncludeRules = @('PSUseCompatibleSyntax')
    Rules        = @{ PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1') } }
}
$guestScripts = @(Get-ChildItem -Path (Join-Path -Path $repo -ChildPath 'guest'),
    (Join-Path -Path $repo -ChildPath 'build/base/oem/lab') -Filter '*.ps1')
foreach ($g in $guestScripts) {
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($g.FullName, [ref]$null, [ref]$parseErrors)
    foreach ($e in @($parseErrors)) {
        if ($e) {
            Write-Host "$($g.Name):$($e.Extent.StartLineNumber) $($e.Message)"
            $rc = 1
        }
    }
}
$compatFindings = @(
    foreach ($g in $guestScripts) { Invoke-AnalyzerWithRetry -Path $g.FullName -Settings $compat }
)
if ($compatFindings.Count) {
    $compatFindings | Format-Table -AutoSize -Property ScriptName, Line, Message |
        Out-String -Width 200 | Write-Host
    $rc = 1
} else {
    Write-Host "   $($guestScripts.Count) scripts, no findings"
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
