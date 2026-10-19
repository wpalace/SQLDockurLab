#Requires -Version 7.4
<#
.SYNOPSIS
    Checks PowerShell files against the house formatter and analyzer rules.

.DESCRIPTION
    Fails when a file differs from Invoke-Formatter output or has PSScriptAnalyzer findings.
    Used by the standards-check workflow and the pre-commit hook.

.EXAMPLE
    ./.standards/scripts/Test-PowerShellStandard.ps1

.EXAMPLE
    ./.standards/scripts/Test-PowerShellStandard.ps1 ./build.ps1 ./src/Module.psm1
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$Path,

    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$SettingsPath = (Join-Path -Path $PWD -ChildPath 'PSScriptAnalyzerSettings.psd1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $Path) {
    $Path = git ls-files -- '*.ps1' '*.psm1' '*.psd1' ':!:.standards/**'
}

$failed = $false
foreach ($file in $Path) {
    $raw = Get-Content -LiteralPath $file -Raw
    if ([string]::IsNullOrEmpty($raw)) {
        continue
    }

    $formatted = Invoke-Formatter -ScriptDefinition $raw -Settings $SettingsPath
    if ($formatted -cne $raw) {
        Write-Warning -Message "Not formatted: $file (run Invoke-Formatter with $SettingsPath)"
        $failed = $true
    }

    $findings = @(Invoke-ScriptAnalyzer -Path $file -Settings $SettingsPath)
    if ($findings.Count -gt 0) {
        $findings | Select-Object -Property ScriptName, Line, Severity, RuleName, Message
        $failed = $true
    }
}

if ($failed) {
    exit 1
}
