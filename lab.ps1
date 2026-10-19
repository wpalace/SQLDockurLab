#!/usr/bin/env pwsh
#Requires -Version 7.2
<#
.SYNOPSIS
  sql-ag-lab operator front end in PowerShell 7 (Windows without WSL, Linux, macOS).
.DESCRIPTION
  ./lab.ps1 gcp <command>   the GCP target (deploy/gcp/lab-gcp.ps1); see ./lab.ps1 gcp help
  ./lab.ps1 log [MESSAGE]   create logs/progress.log and add a time-stamped line
  ./lab.ps1 watch           open a terminal that follows logs/progress.log and TRANSCRIPT.md
  ./lab.ps1 version [--json]              lab and consumer contract version (docs/CONSUMERS.md)
  ./lab.ps1 inventory [--format json|ansible]   hosts, AG, listener, roles (no secrets)
  The local lab engine (KVM, Docker, QEMU: build-base, provision, up, reset, ...) needs a Linux
  host and stays in bash (./lab). On GCP it runs on the lab host VM; this front end starts it there.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Console UI of the operator front end.')]
param() # no CmdletBinding: the command line is read from $args
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'lib/LabHost.psm1') -Force -DisableNameChecking
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'lib/LabConsumer.psm1') -Force -DisableNameChecking
# Commands of the bash lab engine. On a Linux host with bash they are forwarded to ./lab.
$engineCommands = @('status', 'reset', 'up', 'down', 'health', 'list', 'password', 'media', 'info', 'ssh',
    'failover', 'failover-modes', 'kill', 'console', 'vnc', 'doctor', 'init', 'build-base', 'provision',
    'build', 'save', 'delete', 'net')
$cmd = if ($args.Count) { [string]$args[0] } else { 'help' }
[string[]]$rest = if ($args.Count -gt 1) { $args[1..($args.Count - 1)] } else { @() }
if ($null -eq $rest) { $rest = [string[]]@() }
switch ($cmd) {
    'gcp' {
        & (Join-Path -Path $PSScriptRoot -ChildPath 'deploy/gcp/lab-gcp.ps1') @rest
        exit $LASTEXITCODE
    }
    'log' {
        Initialize-LabProgress
        if ($rest.Count) { Write-LabProgress ($rest -join ' ') }
        exit 0
    }
    'watch' {
        Initialize-LabProgress
        $logq = (Get-ProgressLog).Replace("'", "''")
        Open-LabWatch -Name local -Force -Body "Get-Content -LiteralPath '$logq', 'TRANSCRIPT.md' -Tail 100 -Wait"
        exit 0
    }
    'version' {
        $info = Get-LabVersionInfo
        if ($rest -contains '--json') {
            $info | ConvertTo-Json -Compress | Write-Output
        } elseif ($rest.Count) {
            Write-Host '  error usage: ./lab.ps1 version [--json]' -ForegroundColor Red
            exit 2
        } else {
            $line = 'sql-ag-lab {0} (contract {1}, commit {2})'
            Write-Output ($line -f $info.version, $info.contract, $info.commit)
        }
        exit 0
    }
    'inventory' {
        $format = 'json'
        for ($i = 0; $i -lt $rest.Count; $i++) {
            if ($rest[$i] -eq '--format' -and $i + 1 -lt $rest.Count) { $format = $rest[++$i] }
            elseif ($rest[$i] -like '--format=*') { $format = $rest[$i].Substring(9) }
            else { $format = '?' }
        }
        switch ($format) {
            'json' { Get-LabInventory | ConvertTo-Json -Compress -Depth 10 | Write-Output }
            'ansible' { [Console]::Out.Write((ConvertTo-LabAnsibleInventory -Inventory (Get-LabInventory))) }
            default {
                Write-Host '  error usage: ./lab.ps1 inventory [--format json|ansible]' -ForegroundColor Red
                exit 2
            }
        }
        exit 0
    }
    { $_ -in $engineCommands } {
        $lab = Join-Path -Path $PSScriptRoot -ChildPath 'lab'
        if (-not $IsWindows -and (Get-Command -Name bash -ErrorAction SilentlyContinue)) {
            & bash $lab $cmd @rest
            exit $LASTEXITCODE
        }
        Write-Host ("  error '$cmd' runs on the Linux lab host (./lab $cmd). For a GCP lab: " +
            "./lab.ps1 gcp ssh VM './lab $cmd'") -ForegroundColor Red
        exit 1
    }
    { $_ -in 'help', '-h', '--help' } {
        @'
Usage: ./lab.ps1 <command> [args]        (PowerShell 7 operator front end)

  gcp <command>   Google Cloud target: Terraform, IAP SSH/tunnels, golden snapshots (./lab.ps1 gcp help)
  log [MESSAGE]   create logs/progress.log; add a time-stamped line
  watch           open a terminal that follows logs/progress.log + TRANSCRIPT.md
  version [--json]                     lab version and consumer contract version
  inventory [--format json|ansible]    hosts, AG, listener, replica roles (no secrets)

On a Linux lab host, the lab engine commands (status, reset, media, password, ...) are forwarded
to ./lab. The local lab commands (doctor, init, build-base, provision, up, reset, health, ...) need a Linux
host with KVM and Docker: use ./lab (bash) there. On GCP they run on the VM (./lab.ps1 gcp ssh VM ...).
'@ | Write-Host
        exit 0
    }
    default {
        $message = "  error unknown command '$cmd' " +
        '(the local lab engine is ./lab on a Linux host; see ./lab.ps1 help)'
        Write-Host $message -ForegroundColor Red
        exit 1
    }
}
