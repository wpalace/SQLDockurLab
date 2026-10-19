#Requires -Version 7.4
<#
.SYNOPSIS
    Checks PowerShell files with Invoke-Formatter and Invoke-ScriptAnalyzer.
.DESCRIPTION
    Fails when a file differs from the Invoke-Formatter output or has PSScriptAnalyzer findings
    (both use PSScriptAnalyzerSettings.psd1). Checks every tracked PowerShell file, or only the
    files given with -Path. PSScriptAnalyzer 1.25 on pwsh 7.6 sometimes crashes in UseCorrectCasing
    (NullReferenceException in CommandInfo.Parameters), and after such a crash its command lookup
    can fail with "The term 'Get-Command' is not recognized". A file is retried only for these two
    errors, at most 10 runs (a run that crashes is never accepted). The crash can persist in the
    PowerShell session, so retries run in a new pwsh process. Installs PSScriptAnalyzer 1.25 for the
    current user when missing. Used by tests/standards-check.sh, the standards-check CI workflow
    and the pre-commit hook (docs/CI.md).
.PARAMETER Fix
    Rewrite files with Invoke-Formatter before checking them.
.PARAMETER Path
    Files to check. Default: every tracked *.ps1, *.psm1 and *.psd1 file.
.PARAMETER NoRetry
    Check the files once in this process, without retries (used for the retries themselves).
.EXAMPLE
    pwsh -NoProfile -File tests/Test-PowerShellFile.ps1 -Fix
.EXAMPLE
    pwsh -NoProfile -File tests/Test-PowerShellFile.ps1 lab.ps1 lib/LabHost.psm1
#>
[CmdletBinding()]
param(
    [switch]$Fix,

    [switch]$NoRetry,

    [Parameter(ValueFromRemainingArguments)]
    [string[]]$Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..')).Path
$settings = Join-Path -Path $repo -ChildPath 'PSScriptAnalyzerSettings.psd1'

if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer | Where-Object Version -GE '1.25.0')) {
    Install-PSResource -Name PSScriptAnalyzer -Version 1.25.0 -Scope CurrentUser -TrustRepository
}

if ($Path) {
    $files = @($Path | ForEach-Object { (Resolve-Path -LiteralPath $_).Path })
} else {
    Set-Location -Path $repo
    $files = @(git ls-files -- '*.ps1' '*.psm1' '*.psd1')
}

# Output: the problems found in one file (empty when the file passes).
$checkFile = {
    param([string]$File)
    $raw = Get-Content -LiteralPath $File -Raw
    if ([string]::IsNullOrEmpty($raw)) {
        return
    }
    $formatted = Invoke-Formatter -ScriptDefinition $raw -Settings $settings
    if ($formatted -cne $raw) {
        "Not formatted: $File (run tests/Test-PowerShellFile.ps1 -Fix)"
    }
    Invoke-ScriptAnalyzer -Path $File -Settings $settings |
        Select-Object -Property ScriptName, Line, Severity, RuleName, Message |
        Format-Table -AutoSize -Wrap |
        Out-String -Width 200
}

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
        if ($attempt -eq 1 -or $NoRetry) {
            try {
                $out = (& $checkFile -File $f *>&1 | Out-String).Trim()
            } catch {
                $out = ($_ | Out-String).Trim()
            }
        } else {
            # A new process: after a crash, the analyzer in this session can keep failing.
            $pwsh = (Get-Process -Id $PID).Path
            $out = (& $pwsh -NoProfile -File $PSCommandPath -NoRetry $f *>&1 | Out-String).Trim()
            $out = ($out -replace '(?m)^\d+ PowerShell files checked$', '').Trim()
        }
        if ($NoRetry) {
            break
        }
        $crashed = $out -match "Object reference not set to an instance|The term 'Get-Command' is not recognized"
        if (-not $crashed) {
            break
        }
        if ($attempt -eq $maxAttempts) {
            $out = "PSScriptAnalyzer crashed on $f in all $maxAttempts runs`n$out"
            break
        }
        Write-Output "PSScriptAnalyzer crashed on $f (known 1.25 UseCorrectCasing race); retry $attempt"
    }
    if ($out) {
        Write-Output $out
        $failed = $true
    }
}
Write-Output "$($files.Count) PowerShell files checked"
if ($failed) {
    exit 1
}
