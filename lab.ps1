#!/usr/bin/env pwsh
#Requires -Version 7.2
<#
.SYNOPSIS
  sql-ag-lab operator front end in PowerShell 7 (Windows without WSL, Linux, macOS).
.DESCRIPTION
  ./lab.ps1 gcp <command>   the GCP target (deploy/gcp/lab-gcp.ps1); see ./lab.ps1 gcp help
  ./lab.ps1 log [MESSAGE]   create logs/progress.log and add a time-stamped line
  ./lab.ps1 watch           open a terminal that follows logs/progress.log and TRANSCRIPT.md
  The local lab engine (KVM, Docker, QEMU: build-base, provision, up, reset, ...) needs a Linux
  host and stays in bash (./lab). On GCP it runs on the lab host VM; this front end starts it there.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/LabHost.psm1') -Force -DisableNameChecking
$cmd = if ($args.Count) { [string]$args[0] } else { 'help' }
[string[]]$rest = if ($args.Count -gt 1) { $args[1..($args.Count - 1)] } else { @() }
if ($null -eq $rest) { $rest = [string[]]@() }
switch ($cmd) {
    'gcp' { & (Join-Path $PSScriptRoot 'deploy/gcp/lab-gcp.ps1') @rest; exit $LASTEXITCODE }
    'log' { Initialize-LabProgress; if ($rest.Count) { Write-LabProgress ($rest -join ' ') }; exit 0 }
    'watch' {
        Initialize-LabProgress
        Open-LabWatch -Name local -Force -Body "Get-Content -LiteralPath '$((Get-ProgressLog).Replace("'", "''"))', 'TRANSCRIPT.md' -Tail 100 -Wait"
        exit 0
    }
    { $_ -in 'help', '-h', '--help' } {
        @'
Usage: ./lab.ps1 <command> [args]        (PowerShell 7 operator front end)

  gcp <command>   Google Cloud target: Terraform, IAP SSH/tunnels, golden snapshots (./lab.ps1 gcp help)
  log [MESSAGE]   create logs/progress.log; add a time-stamped line
  watch           open a terminal that follows logs/progress.log + TRANSCRIPT.md

The local lab commands (doctor, init, build-base, provision, up, reset, health, ...) need a Linux
host with KVM and Docker: use ./lab (bash) there. On GCP they run on the VM (./lab.ps1 gcp ssh VM ...).
'@ | Write-Host
        exit 0
    }
    default { Write-Host "  error unknown command '$cmd' (the local lab engine is ./lab on a Linux host; see ./lab.ps1 help)" -ForegroundColor Red; exit 1 }
}
