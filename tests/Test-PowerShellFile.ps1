#Requires -Version 7.4
<#
.SYNOPSIS
    Runs the house PowerShell standard check (.standards/scripts/Test-PowerShellStandard.ps1) per file.
.DESCRIPTION
    Checks every tracked PowerShell file outside .standards/ with Invoke-Formatter and
    Invoke-ScriptAnalyzer (PSScriptAnalyzerSettings.psd1). PSScriptAnalyzer 1.25 on pwsh 7.6
    sometimes crashes in UseCorrectCasing (NullReferenceException in CommandInfo.Parameters); a file
    is retried only for that crash, at most 10 runs (a run that crashes is never accepted, even with exit
    code 0). Installs PSScriptAnalyzer 1.25 for the current
    user when missing. Used by tests/standards-check.sh and the standards-check CI workflow.
.PARAMETER Fix
    Rewrite files with Invoke-Formatter before checking them.
.EXAMPLE
    pwsh -NoProfile -File tests/Test-PowerShellFile.ps1 -Fix
#>
[CmdletBinding()]
param([switch]$Fix)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..')).Path
Set-Location -Path $repo
$settings = Join-Path -Path $repo -ChildPath 'PSScriptAnalyzerSettings.psd1'
$standard = Join-Path -Path $repo -ChildPath '.standards/scripts/Test-PowerShellStandard.ps1'

if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer | Where-Object Version -GE '1.25.0')) {
    Install-PSResource -Name PSScriptAnalyzer -Version 1.25.0 -Scope CurrentUser -TrustRepository
}

$files = @(git ls-files -- '*.ps1' '*.psm1' '*.psd1' ':!:.standards/**')
$failed = $false
# Measured on pwsh 7.6.7: up to 4 runs were needed for one file (the race hits about 1 run in 3).
$maxAttempts = 10
foreach ($f in $files) {
    if ($Fix) {
        $raw = Get-Content -LiteralPath $f -Raw
        $new = Invoke-Formatter -ScriptDefinition $raw -Settings $settings
        if ($new -cne $raw) {
            [IO.File]::WriteAllText((Resolve-Path -LiteralPath $f), $new)
        }
    }
    foreach ($attempt in 1..$maxAttempts) {
        $global:LASTEXITCODE = 0 # the standard script ends without exit when the file passes
        try {
            $out = & $standard -Path $f *>&1 | Out-String
            $rc = $LASTEXITCODE
        } catch {
            $out = $_ | Out-String
            $rc = 1
        }
        $crashed = $out -match 'Object reference not set to an instance'
        if (-not $crashed) {
            break
        }
        if ($attempt -eq $maxAttempts) {
            $rc = 1
            break
        }
        Write-Output "PSScriptAnalyzer crashed on $f (known 1.25 UseCorrectCasing race); retry $attempt"
    }
    if ($out.Trim()) {
        Write-Output $out
    }
    if ($rc -ne 0) {
        $failed = $true
    }
}
Write-Output "$($files.Count) PowerShell files checked"
if ($failed) {
    exit 1
}
