---
name: powershell
description: "House coding standard for PowerShell 7.6 LTS. Use when writing, editing, or reviewing PowerShell code (*.ps1, *.psm1, *.psd1)."
---

# PowerShell Standards

> **Before calling work done:** run the formatter and linter checks in the Formatting section (`Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1 -EnableExit`) and fix every finding. Reference config: `PSScriptAnalyzerSettings.psd1` beside this file, which `sync-standards.sh` installs at the project root.

**Targets:** PowerShell 7.6 LTS (7.6.7, built on .NET 10, supported until Nov 2028). Windows PowerShell 5.1 only when a host requires it.

Write PowerShell as tools rather than scripts: discoverable, pipeline-friendly, and safe to re-run.

## Naming

- Functions use **Verb-Noun** with approved verbs (`Get-Verb`) and singular nouns: `Get-UserReport`.
- Use PascalCase for functions, parameters, and variables.
- Write full cmdlet names in scripts. Aliases are for the console only (PSScriptAnalyzer flags them).

## Formatting

Code is formatted for human readability and review. A formatter settles layout so reviewers can focus on logic.

- Format with **`Invoke-Formatter`** and lint with **PSScriptAnalyzer**, using a committed `PSScriptAnalyzerSettings.psd1`. Style: **OTBS** braces (opening brace on the same line, `else` and `catch` cuddled), 4-space indent, consistent whitespace.
- CI fails on any analyzer finding. Run the formatter over changed files before committing.
- Keep lines under 115 characters. Put one statement per line, and never chain statements with `;`.
- For long calls, use **splatting** with one key per line, not backtick line continuations.
- Break pipelines *after* the `|`, with one stage per line.
- Put a blank line between logical blocks. Write comments that explain *why*, and use comment-based help for *what*.
- Don't mix reformatting with logic changes in one PR.

```powershell
# PSScriptAnalyzerSettings.psd1
@{
    IncludeDefaultRules = $true
    Rules = @{
        PSPlaceOpenBrace           = @{ Enable = $true; OnSameLine = $true }
        PSUseConsistentIndentation = @{ Enable = $true; IndentationSize = 4; Kind = 'space' }
        PSUseConsistentWhitespace  = @{ Enable = $true }
    }
}
```

```powershell
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1 -EnableExit
```

```powershell
# Before
New-AzVM -ResourceGroupName $rg -Name $name -Location $loc `
    -Size 'Standard_B2s' -Image 'Ubuntu2404'

# After
$vmParams = @{
    ResourceGroupName = $rg
    Name              = $name
    Location          = $loc
    Size              = 'Standard_B2s'
    Image             = 'Ubuntu2404'
}
New-AzVM @vmParams
```

## Parameter Design

- Every function gets `[CmdletBinding()]`, a `param()` block, strong types, and validation attributes.
- Use `SupportsShouldProcess` on anything that changes state, so callers get `-WhatIf` and `-Confirm`.
- Use modern types for validation: `[semver]` for versions and `[ValidateSet()]` for fixed choices.

```powershell
function Remove-StaleLog {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateScript({ Test-Path $_ -PathType Container })]
        [string]$Path,

        [ValidateRange(1, 365)]
        [int]$OlderThanDays = 30
    )
    process {
        Get-ChildItem -LiteralPath $Path -Filter '*.log' |
            Where-Object LastWriteTime -lt (Get-Date).AddDays(-$OlderThanDays) |
            ForEach-Object {
                if ($PSCmdlet.ShouldProcess($_.FullName, 'Delete')) { Remove-Item -LiteralPath $_.FullName }
            }
    }
}
```

## Error Handling

- Start every script with strict settings. Native executables now participate in error handling too:

```powershell
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true   # non-zero exit codes throw (7.4+)
Set-StrictMode -Version Latest
```

- Wrap risky operations in `try/catch`, catching specific exception types where possible.
- Use `throw` or `$PSCmdlet.ThrowTerminatingError()` for errors, never `Write-Host`.

```powershell
try {
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
}
catch [System.IO.FileNotFoundException] {
    throw "Config not found: $ConfigPath"
}
```

## Pipeline-First Design

- Emit **objects**, never formatted text. Never call `Format-*` inside a function.
- Accept pipeline input and do the work in `process {}`.
- Use `Write-Verbose` and `Write-Debug` for diagnostics.
- Use `ForEach-Object -Parallel -ThrottleLimit` for I/O-bound fan-out, and `Start-ThreadJob` instead of `Start-Job`. Pass variables in with `$using:`.

```powershell
$servers | ForEach-Object -Parallel {
    Test-Connection -TargetName $_ -Count 1 -Quiet
} -ThrottleLimit 8
```

## Modules & Packages

- Put reusable code in a module: a `.psm1` plus a `.psd1` with explicit `FunctionsToExport`, and one function per file under `Public/` and `Private/`.
- Use **PSResourceGet** (`Install-PSResource`, `Publish-PSResource`) instead of legacy PowerShellGet. Pin versions in CI.
- Declare `#Requires -Version 7.6` and `CompatiblePSEditions = 'Core'` when you depend on 7.6 behavior.
- Test with **Pester 5** in CI.

```powershell
Install-PSResource -Name Pester -Version '[5.0,6.0)' -Scope CurrentUser -TrustRepository
```

## What's New to Use (7.4 to 7.6)

- `Join-Path -ChildPath` accepts `string[]` (7.6). Build multi-segment paths in a single call.
- `$PSNativeCommandUseErrorActionPreference` and `PSNativeWindowsTildeExpansion` are mainstream features.
- Tab completion improved across providers and parameters. `Register-ArgumentCompleter -NativeFallback` covers native tools.
- Error output respects `NO_COLOR`, which helps keep CI logs clean.

## Avoid

- **String concatenation for paths.** Use `Join-Path`, and `-LiteralPath` for user input.

```powershell
# Bad:  $file = $root + '\logs\' + $name
$file = Join-Path -Path $root -ChildPath 'logs', $name   # 7.6+
```

- **`Invoke-Expression`.** Use the call operator `&` with splatting.

```powershell
$params = @{ Path = $src; Destination = $dst; Recurse = $true }
Copy-Item @params
```

- **Unquoted variables in strings and paths.** Write `"$Path"` and `"$($obj.Prop)"`.
- Checking `$LASTEXITCODE` by hand when strict native error handling is on.
- Aliases, positional parameters, and `Write-Host` for data. Hardcoded credentials (use `Microsoft.PowerShell.SecretManagement`).

## Sources

- Microsoft PowerShell Team, "Announcing PowerShell 7.6 (LTS) GA Release" (devblogs, Mar 18, 2026)
- The Sharp Ninja, "PowerShell Snippets: What's New in 2026" (Medium, Feb 19, 2026)
