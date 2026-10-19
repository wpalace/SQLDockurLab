#!/usr/bin/env pwsh
#Requires -Version 7.2
<#
.SYNOPSIS
  ./lab.ps1 gcp: Google Cloud deployment target for sql-ag-lab (PowerShell 7, Windows and Linux).
.DESCRIPTION
  Same subcommands and flags as the bash front end deploy/gcp/lab-gcp. Terraform makes the
  infrastructure (terraform.tfvars is the parameter source); gcloud is used for IAP SSH/SCP,
  IAP tunnels and instance start/stop. The lab itself runs unchanged on the Linux VM (bash):
  remote-deploy.sh, vm-check.sh, artifacts.sh and ./lab are started there over IAP SSH.
  No WSL, bash, ssh-keygen, tail or sed are needed on the operator machine.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Console UI of the operator front end (usage, tunnel URLs).')]
param() # no CmdletBinding: the command line is read from $args
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Native exit codes are checked by hand: several gcloud/terraform/ssh calls may fail on purpose
# (-AllowFail, probes such as Get-Rcmd), and failures get a front-end message instead of a stack.
$PSNativeCommandUseErrorActionPreference = $false
$GcpDir = $PSScriptRoot
$LabRoot = (Resolve-Path -Path (Join-Path -Path $GcpDir -ChildPath '../..')).Path
Import-Module -Name (Join-Path -Path $LabRoot -ChildPath 'lib/LabHost.psm1') -Force -DisableNameChecking
$TfShared = Join-Path -Path $GcpDir -ChildPath 'terraform/shared'
$TfVms = Join-Path -Path $GcpDir -ChildPath 'terraform/vms'
# relative to the remote home
$RemoteDir = if ($env:LAB_GCP_REMOTE_DIR) { $env:LAB_GCP_REMOTE_DIR } else { 'sql-ag-lab' }
$StateDirGcp = Join-Path -Path $GcpDir -ChildPath 'state'
$GoldenFile = Join-Path -Path $StateDirGcp -ChildPath 'golden-snapshot'
function Get-SpawnedPath {
    if ($env:LAB_GCP_SPAWNED_JSON) {
        $env:LAB_GCP_SPAWNED_JSON
    } else {
        Join-Path -Path $TfVms -ChildPath 'spawned.auto.tfvars.json'
    }
}
$script:Project = $null
$script:Zone = $null
$script:Prefix = 'sqlag'
if (-not $IsWindows) {
    foreach ($p in @("$HOME/.local/bin", "$HOME/.local/google-cloud-sdk/bin")) {
        if ($env:PATH -notlike "*$p*") { $env:PATH += [IO.Path]::PathSeparator + $p }
    }
}

function Write-GcpLog([string]$Message) { Write-LabLog -Tag gcp -Message $Message }

function Show-Usage {
    @'
Usage: ./lab.ps1 gcp <command> [args]     (VM = key like bill-1, or the full VM name)
       (the same commands as ./lab gcp on Linux; this front end needs only pwsh 7, gcloud, terraform,
        git)

Infrastructure (Terraform; ROOT = shared | vms, default vms):
  init [ROOT]            terraform init (uses backend.tf when present)
  plan [ROOT]            terraform plan
  apply [ROOT] [--yes]   terraform apply (asks "Enter a value:"; --yes / -auto-approve skips it)
  destroy [ROOT]         terraform destroy of a whole root (asks for confirmation)
  create KEY | delete KEY [--yes]
                         apply/destroy one entry of vms in terraform.tfvars
  tf-check               terraform fmt -check + validate for both roots (no credentials)
  tools                  check the operator tools (pwsh, gcloud, terraform, git, terminal)

VM lifecycle (gcloud):
  list                   lab VMs in the project (label app=sql-ag-lab)
  start VM | stop VM     start / stop (stop when idle: compute charges stop, disk charges stay)
  ssh VM [command]       SSH through IAP
  check VM               verify GCE settings + VM prerequisites, then ./lab doctor on the VM
  push VM                copy this repository (committed HEAD, git bundle) to ~/sql-ag-lab on the VM
  deploy VM [--checkpoints]
                         run the lab build on the VM in the background (resumable)
  watch VM               follow the deploy log on the VM
  watch-term VM          open the live watch terminal now (with the local TRANSCRIPT.md)
  tunnel VM [--sql] [--socks PORT] [--offset N] [--open]
                         forward the consoles (8006, 6111-6115) and optionally SQL to this
                         machine; print the authenticated console URLs (--open: open them)
  console VM             = tunnel VM --open
  snapshot VM [NAME]     snapshot the stopped VM disk
  image VM [FAMILY]      make a custom image of the VM disk (VM is stopped)

Golden snapshot and clones (MAKE.md G8-G10):
  test VM                run TC1-TC9 on the VM (tests/run-tcs.sh); fails if any test fails
  golden VM [NAME]       only after a test pass: stop the VM, snapshot its disk, record it as latest
  finish VM              test, then golden
  snapshots              list lab snapshots and the latest golden one
  use-snapshot NAME      record NAME as the latest golden snapshot
  spawn NAME [--disk-type pd-balanced|pd-ssd|pd-standard] [--snapshot S] [--machine-type M] [--owner O] [--no-up]
  destroy NAME [--yes]   delete a spawned VM and its disk (tfvars VMs are refused)

Artifacts (shared bucket; run on the VM with the VM service account):
  artifacts VM           show the bucket manifest
  publish VM ITEM...     upload iso base key image checkpoints | all (publisher VMs only)
  fetch VM [--checkpoints]

Lab SSH key (Secret Manager secret sqlag-lab-ssh-key; not in the bucket, not in Terraform state):
  key push VM            add the VM's secrets/id_ed25519 as a new version (publishers only)
  key fetch VM [--force] write the latest version to the VM (refuses a different key without --force)
  key check VM           compare the VM's key with the latest version
  key status             list the versions (from this workstation)
  cost                   rough cost estimate for the default VM size
'@ | Write-Host
}

# ------------------------------------------------------------------------ tools --
function Assert-Tool([string]$Exe, [string]$Hint) {
    if (-not (Get-Command $Exe -ErrorAction SilentlyContinue)) { Stop-Lab "$Exe not found. $Hint" }
}
function Invoke-Native {
    # run a native command; throw when it fails (unless -AllowFail)
    param([string]$Exe, [string[]]$ArgList, [switch]$AllowFail, [switch]$Quiet)
    if ($Quiet) { & $Exe @ArgList 2>$null | Out-Null } else { & $Exe @ArgList }
    $rc = $LASTEXITCODE
    if ($rc -ne 0 -and -not $AllowFail) { Stop-Lab "$Exe $($ArgList[0..1] -join ' ') failed (exit $rc)" }
}
function Invoke-Terraform {
    param([Parameter(Mandatory)][string[]]$ArgList)
    Assert-Tool terraform 'Install Terraform >= 1.5 (Windows: winget install Hashicorp.Terraform).'
    & terraform @ArgList
    if ($LASTEXITCODE) { Stop-Lab "terraform $($ArgList[0..1] -join ' ') failed (exit $LASTEXITCODE)" }
}
function Invoke-Gcloud {
    param([Parameter(Mandatory)][string[]]$ArgList)
    Assert-Tool gcloud 'Install the Google Cloud CLI (Windows: winget install Google.CloudSDK).'
    & gcloud @ArgList
}
function Get-TfRoot([string]$Root = 'vms') {
    switch ($Root) {
        'shared' { $TfShared }
        'vms' { $TfVms }
        default { Stop-Lab 'ROOT must be shared or vms' }
    }
}
function Assert-TfVar([string]$Dir) {
    if (-not (Test-Path -Path (Join-Path -Path $Dir -ChildPath 'terraform.tfvars'))) {
        Stop-Lab "missing $Dir/terraform.tfvars: copy terraform.tfvars.example and fill it in (MAKE.md G2)"
    }
}
function Get-TfOut([string]$name) {
    if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) { return '' }
    $o = & terraform "-chdir=$TfVms" output -raw $name 2>$null
    if ($LASTEXITCODE) { return '' }
    ($o -join "`n")
}
function Initialize-GcpContext {
    $script:Project = if ($env:GCP_PROJECT) { $env:GCP_PROJECT } else { Get-TfOut project_id }
    $script:Zone = if ($env:GCP_ZONE) { $env:GCP_ZONE } else { Get-TfOut zone }
    $script:Prefix = if ($env:GCP_NAME_PREFIX) { $env:GCP_NAME_PREFIX } else { 'sqlag' }
    if (-not $script:Project -or -not $script:Zone) {
        Stop-Lab 'unknown project/zone: run ./lab.ps1 gcp apply first, or set GCP_PROJECT and GCP_ZONE'
    }
}
function Get-VmLine {
    @((Get-TfOut vm_lines) -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { , ($_ -split '\s+') })
}
function Get-VmName([string]$n) {
    if (-not $n) { Stop-Lab 'VM required' }
    if ($n -like "$($script:Prefix)-*") { return $n }
    if (Test-Spawned $n) { return $n }
    foreach ($l in Get-VmLine) { if ($l[0] -eq $n -or $l[1] -eq $n) { return $l[1] } }
    "$($script:Prefix)-$n"
}
function Get-Region { $script:Zone -replace '-[a-z]$', '' }
# gcloud flags that select the lab project and zone.
function Get-GcloudScope { @('--project', $script:Project, '--zone', $script:Zone) }

# IAP SSH. On Windows gcloud uses PuTTY (plink/pscp); on Linux OpenSSH.
function Invoke-Gssh([string]$n, [string[]]$Extra) {
    $ssh = @('compute', 'ssh', $n) + (Get-GcloudScope) + @('--tunnel-through-iap', '--quiet')
    Invoke-Gcloud -ArgList ($ssh + $Extra)
}
# Remote command: sent base64-encoded, so no local shell (cmd.exe for gcloud.cmd, pwsh) touches
# quotes, pipes, $ or && in it. The VM decodes it and runs it with bash.
function Get-RemoteCommandArg([string]$Command) {
    $b = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Command -replace "`r`n", "`n")))
    "--command=f=`$(mktemp); echo $b | base64 -d > `$f; bash `$f < /dev/null; rc=`$?; rm -f `$f; exit `$rc"
}
function Invoke-Rcmd([string]$n, [string]$Command, [switch]$AllowFail) {
    Invoke-Gssh $n @(Get-RemoteCommandArg $Command)
    if ($LASTEXITCODE -and -not $AllowFail) { Stop-Lab "remote command on $n failed (exit $LASTEXITCODE)" }
}
function Get-Rcmd([string]$n, [string]$Command) {
    # output as text; $null on failure
    $o = Invoke-Gssh $n @(Get-RemoteCommandArg $Command) 2>$null
    if ($LASTEXITCODE) { return $null }
    ($o -join "`n")
}
# SCP of one local file. gcloud reads "C:\x" as INSTANCE:PATH, so copy from the file's folder by name.
function Copy-ToVm([string]$n, [string]$Local, [string]$Remote) {
    Push-Location -Path (Split-Path -Parent $Local)
    try {
        $scp = @('compute', 'scp') + (Get-GcloudScope) + @('--tunnel-through-iap', '--quiet')
        Invoke-Gcloud -ArgList ($scp + @((Split-Path -Leaf $Local), "${n}:$Remote"))
        if ($LASTEXITCODE) { Stop-Lab "scp to $n failed" }
    } finally { Pop-Location }
}

function Open-WatchGcp([string]$key, [switch]$Force) {
    $self = (Join-Path -Path $LabRoot -ChildPath 'lab.ps1').Replace("'", "''")
    $body = @"
`$j = Start-ThreadJob -ArgumentList '$self', '$key' -ScriptBlock {
    param(`$lab, `$vm)
    `$pw = (Get-Process -Id `$PID).Path
    while (`$true) {
        Start-Process `$pw -ArgumentList @('-NoProfile', '-File', `$lab, 'gcp', 'watch', `$vm) -NoNewWindow -Wait
        [Console]::WriteLine('[watch] connection to the VM lost; retrying in 15 s (close the window to stop)')
        Start-Sleep -Seconds 15
    }
}
Get-Content -LiteralPath TRANSCRIPT.md -Tail 40 -Wait
"@
    Open-LabWatch -Name "gcp-$key" -Body $body -Force:$Force
}

# ------------------------------------------------------------------- terraform --
function Invoke-TfCmd([string]$Action, [string]$Root = 'vms', [string[]]$Extra = @()) {
    $dir = Get-TfRoot $Root
    switch ($Action) {
        'init' { Invoke-Terraform -ArgList (@("-chdir=$dir", 'init', '-upgrade') + $Extra) }
        'plan' {
            Assert-TfVar $dir
            Invoke-Terraform -ArgList (@("-chdir=$dir", 'plan') + $Extra)
        }
        'apply' {
            Assert-TfVar $dir
            Invoke-Terraform -ArgList (@("-chdir=$dir", 'apply') + $Extra)
        }
        'destroy' {
            Assert-TfVar $dir
            Invoke-Terraform -ArgList (@("-chdir=$dir", 'destroy') + $Extra)
        }
    }
}
function Invoke-TfCheck {
    $rc = 0
    foreach ($d in @($TfShared, $TfVms)) {
        Write-GcpLog "terraform fmt/validate $([IO.Path]::GetRelativePath($LabRoot, $d))"
        & terraform "-chdir=$d" fmt -check -diff
        if ($LASTEXITCODE) { $rc = 1 }
        & terraform "-chdir=$d" init -backend=false -input=false | Out-Null
        if ($LASTEXITCODE) { $rc = 1 }
        & terraform "-chdir=$d" validate
        if ($LASTEXITCODE) { $rc = 1 }
    }
    if ($rc) { Stop-Lab 'terraform checks failed' }
}
function Update-TfOutput {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not $PSCmdlet.ShouldProcess($TfVms, 'terraform apply -refresh-only')) { return }
    & terraform "-chdir=$TfVms" apply -refresh-only -auto-approve -input=false | Out-Null
    if ($LASTEXITCODE) { Write-LabWarn 'could not refresh terraform outputs' }
}
# --yes (agents, after approval from the user) adds -auto-approve.
function Get-YesFlag([string[]]$f) {
    if (@($f | Where-Object { $_ -in '-y', '--yes', '-auto-approve' })) { , @('-auto-approve') } else { , @() }
}
function Invoke-Create([string]$k, [string[]]$Flags) {
    if (-not $k) { Stop-Lab 'usage: create KEY [--yes]' }
    Assert-TfVar $TfVms
    $target = "-target=google_compute_instance.lab[`"$k`"]"
    Invoke-Terraform -ArgList (@("-chdir=$TfVms", 'apply') + @(Get-YesFlag $Flags) + @($target))
    Update-TfOutput
}
function Invoke-Delete([string]$k, [string[]]$Flags) {
    if (-not $k) { Stop-Lab 'usage: delete KEY [--yes]' }
    Assert-TfVar $TfVms
    $target = "-target=google_compute_instance.lab[`"$k`"]"
    Invoke-Terraform -ArgList (@("-chdir=$TfVms", 'destroy') + @(Get-YesFlag $Flags) + @($target))
    Update-TfOutput
}

function Test-OperatorTool {
    # operator prerequisites (MAKE.md G1)
    $fails = 0
    $os = [Runtime.InteropServices.RuntimeInformation]::OSDescription
    Write-LabOk "pwsh $($PSVersionTable.PSVersion) on $os"
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-LabWarn 'PowerShell 7 or later is necessary'
        $fails++
    }
    $tools = @(
        @('gcloud', 'version', 'winget install Google.CloudSDK'),
        @('terraform', 'version', 'winget install Hashicorp.Terraform'),
        @('git', '--version', 'winget install Git.Git')
    )
    foreach ($t in $tools) {
        $c = Get-Command $t[0] -ErrorAction SilentlyContinue
        if (-not $c) {
            Write-LabWarn "$($t[0]) not found: $($t[2])"
            $fails++
            continue
        }
        $v = (& $t[0] $t[1] 2>$null | Select-Object -First 1)
        Write-LabOk "$($t[0]): $v ($($c.Source))"
    }
    if (Get-Command terraform -ErrorAction SilentlyContinue) {
        $tv = (& terraform version -json 2>$null | ConvertFrom-Json).terraform_version
        if ([version]$tv -lt [version]'1.5.0') {
            Write-LabWarn "terraform ${tv}: 1.5 or later is necessary"
            $fails++
        }
    }
    if (Get-Command gcloud -ErrorAction SilentlyContinue) {
        $acct = & gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>$null |
            Select-Object -First 1
        if ($acct) {
            Write-LabOk "gcloud account $acct"
        } else {
            Write-LabWarn 'no active gcloud account: gcloud auth login'
            $fails++
        }
        & gcloud auth application-default print-access-token 2>$null | Out-Null
        if ($LASTEXITCODE) {
            Write-LabWarn 'no application-default credentials (terraform): gcloud auth application-default login'
            $fails++
        } else { Write-LabOk 'application-default credentials' }
    }
    if ($IsWindows) {
        if (Get-Command wt.exe -ErrorAction SilentlyContinue) {
            Write-LabOk 'Windows Terminal (watch terminal)'
        } else {
            Write-LabWarn 'no Windows Terminal: the watch terminal opens in a new pwsh window'
        }
    } elseif (-not ($env:DISPLAY -or $env:WAYLAND_DISPLAY)) {
        Write-LabWarn 'no graphical session: the watch terminal prints a command instead'
    }
    foreach ($d in @($TfShared, $TfVms)) {
        $rel = [IO.Path]::GetRelativePath($LabRoot, $d)
        if (Test-Path -Path (Join-Path -Path $d -ChildPath 'terraform.tfvars')) {
            Write-LabOk "$rel/terraform.tfvars present"
        } else {
            Write-LabWarn "$rel/terraform.tfvars missing (MAKE.md G2)"
        }
    }
    if ($fails) { Stop-Lab "$fails operator prerequisite(s) missing" }
    Write-LabOk 'operator tools ready'
}

function Invoke-List {
    Initialize-GcpContext
    $format = '--format=table(name,zone.basename(),machineType.basename(),status,labels.owner,' +
    'scheduling.provisioningModel,advancedMachineFeatures.enableNestedVirtualization:label=NESTED)'
    Invoke-Gcloud -ArgList @('compute', 'instances', 'list', '--project', $script:Project,
        '--filter=labels.app=sql-ag-lab', $format)
}

# ---------------------------------------------------------------------- check --
function Invoke-Check([string]$key) {
    Initialize-GcpContext
    $n = Get-VmName $key
    $fails = 0
    Write-GcpLog "GCE settings of $n"
    $format = '--format=value(status,advancedMachineFeatures.enableNestedVirtualization,minCpuPlatform,' +
    'cpuPlatform,machineType.basename(),scheduling.provisioningModel,networkInterfaces[0].accessConfigs[0].natIP)'
    $d = Invoke-Gcloud -ArgList (@('compute', 'instances', 'describe', $n) + (Get-GcloudScope) + @($format))
    if ($LASTEXITCODE -or -not $d) { Stop-Lab "VM $n not found in $($script:Project)/$($script:Zone)" }
    $f = @(($d | Select-Object -First 1) -split "`t") + @('', '', '', '', '', '', '')
    $status, $nested, $minp, $cpup, $mtype, $model, $natip = $f[0..6]
    if ($status -eq 'RUNNING') {
        Write-LabOk 'status RUNNING'
    } else {
        Write-LabWarn "status ${status}: run ./lab.ps1 gcp start $key"
        $fails++
    }
    if ($nested -eq 'true' -or $nested -eq 'True') {
        Write-LabOk 'enableNestedVirtualization=true'
    } else {
        Write-LabWarn 'nested virtualization OFF: set enable_nested_virtualization (terraform vms root) and apply'
        $fails++
    }
    if ($minp) {
        Write-LabOk "minCpuPlatform=$minp (running on $cpup)"
    } else {
        Write-LabWarn 'no minCpuPlatform: checkpoints may not restore on other CPUs'
    }
    if ($mtype -match '^(e2|n2d|c2d|c3d|c4d|t2d|t2a|c4a)-') {
        Write-LabWarn "$mtype does not support nested virtualization"
        $fails++
    } else { Write-LabOk "machine type $mtype ($model)" }
    if (-not $natip) {
        Write-LabOk 'no external IP (IAP only)'
    } else { Write-LabWarn "external IP $natip present" }
    $line = Get-VmLine | Where-Object { $_[1] -eq $n } | Select-Object -First 1
    if ($line) {
        $emt = $line[2]
        $emp = ($line[3] -replace '_', ' ')
        if ($emt -eq $mtype) {
            Write-LabOk 'machine type matches terraform'
        } else { Write-LabWarn "machine type $mtype, terraform says $emt" }
        if ($emp -eq $minp) {
            Write-LabOk 'min CPU platform matches terraform'
        } else { Write-LabWarn "min CPU platform '$minp', terraform says '$emp'" }
    } else { Write-LabWarn "$n is not in the terraform vms outputs (created by hand?)" }
    if ($fails) { Stop-Lab 'fix the GCE settings above first' }
    Write-GcpLog 'prerequisites on the VM'
    $tmp = New-TempDirectory
    try {
        $script = Join-Path -Path $tmp -ChildPath 'vm-check.sh'
        ConvertTo-LfFile -Path (Join-Path -Path $GcpDir -ChildPath 'vm-check.sh') -Destination $script
        Copy-ToVm -n $n -Local $script -Remote '/tmp/vm-check.sh'
    } finally { Remove-Item -Recurse -Force -Path $tmp }
    Invoke-Rcmd $n 'bash /tmp/vm-check.sh' -AllowFail
    if ($LASTEXITCODE) { Stop-Lab 'VM prerequisites failed (see FAIL lines)' }
    if ($null -ne (Get-Rcmd $n "test -x $RemoteDir/lab")) {
        Write-GcpLog './lab doctor on the VM'
        Invoke-Rcmd $n "cd $RemoteDir && ./lab doctor" -AllowFail
        if ($LASTEXITCODE) { Stop-Lab './lab doctor reported problems' }
    } else { Write-LabWarn "repository not on the VM yet: run ./lab.ps1 gcp push $key, then check again" }
    Write-LabOk "$n is ready for the lab"
}
function New-TempDirectory {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $tmp = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "sqlag-$id"
    if ($PSCmdlet.ShouldProcess($tmp, 'create directory')) { New-Item -ItemType Directory -Path $tmp | Out-Null }
    $tmp
}

# ---------------------------------------------------------------- push/deploy --
# A git bundle carries git objects (stored with LF, see .gitattributes); the VM clones it on
# Linux, so shell scripts arrive with LF also when this checkout on Windows uses CRLF.
function Invoke-Push([string]$key) {
    Initialize-GcpContext
    $n = Get-VmName $key
    Assert-Tool git 'Install Git (Windows: winget install Git.Git).'
    & git -C $LabRoot diff --quiet HEAD --
    if ($LASTEXITCODE) { Write-LabWarn 'uncommitted changes are NOT copied (commit first)' }
    $pw = Get-LabPassword   # fail fast before copying anything
    $br = (& git -C $LabRoot rev-parse --abbrev-ref HEAD).Trim()
    $tmp = New-TempDirectory
    try {
        $b = Join-Path -Path $tmp -ChildPath 'sql-ag-lab.bundle'
        & git -C $LabRoot bundle create $b HEAD $br 2>$null
        if ($LASTEXITCODE) { Stop-Lab 'git bundle failed' }
        Copy-ToVm -n $n -Local $b -Remote '/tmp/sql-ag-lab.bundle'
        # The password goes in a file (never on a command line) to lab.local.env on the VM (mode 600 there).
        $pf = Join-Path -Path $tmp -ChildPath 'lab-password.env'
        [IO.File]::WriteAllText($pf, "LAB_PASSWORD='$pw'`n")
        if (-not $IsWindows) { & chmod 600 $pf }
        Copy-ToVm -n $n -Local $pf -Remote '/tmp/lab-password.env'
    } finally { Remove-Item -Recurse -Force -Path $tmp }
    Invoke-Rcmd $n @"
set -e; id -nG | grep -qw docker || sudo usermod -aG docker "`$USER"
if [ -d $RemoteDir/.git ]; then git -C $RemoteDir pull -q --ff-only /tmp/sql-ag-lab.bundle $br
else git clone -q -b $br /tmp/sql-ag-lab.bundle $RemoteDir; fi
$(Get-RemotePasswordMerge)
git -C $RemoteDir log --oneline -1
"@
    Write-LabOk "repository on ${n}:~/$RemoteDir (reconnect once so group docker applies)"
}
# Remote shell: move /tmp/lab-password.env into lab.local.env (replace the LAB_PASSWORD line), mode 600.
function Get-RemotePasswordMerge {
    @"
chmod 600 /tmp/lab-password.env; touch $RemoteDir/lab.local.env; chmod 600 $RemoteDir/lab.local.env
{ grep -v '^LAB_PASSWORD=' $RemoteDir/lab.local.env || true; cat /tmp/lab-password.env; } \
  > $RemoteDir/lab.local.env.new
mv $RemoteDir/lab.local.env.new $RemoteDir/lab.local.env; chmod 600 $RemoteDir/lab.local.env
rm -f /tmp/lab-password.env /tmp/sql-ag-lab.bundle
"@
}
function Invoke-Key([string[]]$a) {
    # key push|fetch|check VM | key status
    Initialize-GcpContext
    $act = if ($a.Count) { $a[0] } else { '' }
    switch ($act) {
        { $_ -in 'push', 'fetch', 'check' } {
            if ($a.Count -lt 2 -or -not $a[1]) { Stop-Lab "usage: key $act VM" }
            $extra = if ($a.Count -gt 2) { ' ' + ($a[2..($a.Count - 1)] -join ' ') } else { '' }
            Invoke-Rcmd (Get-VmName $a[1]) "cd $RemoteDir && deploy/gcp/artifacts.sh key $act$extra"
        }
        'status' {
            $format = '--format=table(name.basename():label=VERSION,state,createTime.date(tz=LOCAL))'
            Invoke-Gcloud -ArgList @('secrets', 'versions', 'list', "$($script:Prefix)-lab-ssh-key",
                '--project', $script:Project, $format)
            if ($LASTEXITCODE) {
                Stop-Lab ('gcloud secrets versions list failed ' +
                    '(secret missing or no roles/secretmanager.viewer/secretAccessor)')
            }
        }
        default { Stop-Lab 'usage: key push|fetch|check VM | key status' }
    }
}
function Invoke-Deploy([string]$key, [string[]]$Rest) {
    $Rest = @($Rest | Where-Object { $_ })
    Initialize-GcpContext
    $n = Get-VmName $key
    $command = "cd $RemoteDir && setsid -f nohup deploy/gcp/remote-deploy.sh $($Rest -join ' ') " +
    '> logs-gcp-deploy.log 2>&1 < /dev/null; sleep 2; tail -3 logs-gcp-deploy.log'
    Invoke-Rcmd $n $command -AllowFail
    if ($LASTEXITCODE) { Write-LabWarn 'could not read the deploy log yet (the deploy runs on the VM)' }
    Write-LabOk "deploy started on $n. Follow it: ./lab.ps1 gcp watch $key   Consoles: ./lab.ps1 gcp console $key"
    Open-WatchGcp $key
}
function Invoke-Watch([string]$key) {
    Initialize-GcpContext
    $n = Get-VmName $key
    $tail = "--command=tail -n 40 -F $RemoteDir/logs-gcp-deploy.log $RemoteDir/logs/progress.log"
    Invoke-Gssh $n @($tail, '--', '-t')
}

# --------------------------------------------------------------------- tunnel --
function Test-LocalPort([int]$p) {
    $c = [Net.Sockets.TcpClient]::new()
    try { $c.ConnectAsync('127.0.0.1', $p).Wait(300) -and $c.Connected } catch { $false } finally { $c.Dispose() }
}
# Authenticated noVNC URL (same form as lib/common.sh console_url): token in the fragment.
function Get-ConsoleUrl([int]$Port, [string]$Token) {
    $opts = 'autoconnect=1&resize=scale&reconnect=1&reconnect_delay=2000'
    "http://127.0.0.1:$Port/vnc.html#$opts&path=websockify%3Ftoken%3D$Token"
}
# The console token of the VM (its secrets/console-token); starts the VM's gateway if needed.
function Get-ConsoleToken([string]$n) {
    $o = Get-Rcmd $n "cd $RemoteDir && ./lab console >/dev/null 2>&1; ./lab console token"
    if (-not $o) { return '' }
    $t = (($o -split "`n") | Select-Object -Last 1).Trim()
    if ($t -match '^[0-9a-f]{48}$') { $t } else { '' }
}
function Invoke-Tunnel([string]$key, [string[]]$Rest) {
    $Rest = @($Rest | Where-Object { $_ })
    Initialize-GcpContext
    $n = Get-VmName $key
    $sql = $false
    $socks = ''
    $off = $null
    $open = $false
    for ($i = 0; $i -lt $Rest.Count; $i++) {
        switch ($Rest[$i]) {
            '--sql' { $sql = $true }
            '--socks' { $socks = $Rest[++$i] }
            '--offset' { $off = [int]$Rest[++$i] }
            '--open' { $open = $true }
            default { Stop-Lab "unknown option $($Rest[$i])" }
        }
    }
    $vnc = @(8006, 6111, 6112, 6113, 6114, 6115)
    if ($null -eq $off) {
        $off = 0
        foreach ($p in $vnc) { if (Test-LocalPort $p) { $off = 10000 } }
        if ($off) {
            Write-LabWarn "local ports 8006/6111-6115 are in use (local lab?): forwarding to local port + $off"
        }
    }
    $token = Get-ConsoleToken $n
    if (-not $token) {
        Write-LabWarn ("could not read the console token of $n (update it: ./lab.ps1 gcp push $key); " +
            'the consoles will refuse the connection')
    }
    Write-GcpLog "tunnel to $n (Ctrl-C to stop)"
    # One IAP SSH session with local forwards. The consoles listen on 127.0.0.1 of the VM and the
    # lab networks exist only on the VM, so IAP TCP forwarding to the VM NIC cannot reach them.
    $f = @('-N')
    foreach ($p in $vnc) { $f += @('-L', "$($p + $off):127.0.0.1:$p") }
    if ($sql) {
        $sqlForwards = @(
            '14330:10.50.0.60', '14339:10.51.0.60', '14331:10.50.0.11', '14332:10.50.0.12', '14333:10.51.0.13',
            '14334:10.51.0.14'
        )
        foreach ($m in $sqlForwards) { $f += @('-L', "${m}:1433") }
    }
    if ($socks) { $f += @('-D', $socks) }
    if (-not $IsWindows) { $f = @('-o', 'ExitOnForwardFailure=yes') + $f }   # OpenSSH only (Windows: plink)
    $urls = @($vnc | ForEach-Object { Get-ConsoleUrl -Port ($_ + $off) -Token $token })
    # Console URLs go to the terminal only (they contain the console token), never to a log file.
    Write-Host "  base build console  $($urls[0])"
    $urls[1..5] | ForEach-Object { Write-Host "  VM console          $_" }
    Write-Host '  (the URLs contain the console token: do not copy them into logs or TRANSCRIPT.md)'
    if ($sql) {
        Write-Host ('  SQL listener        127.0.0.1,14330 ' +
            '(subnet A IP; use 14339 when the primary is on SQL3/SQL4)')
        Write-Host '  SQL1..SQL4          127.0.0.1,14331 .. 127.0.0.1,14334 (SQL auth)'
    }
    if ($socks) { Write-Host "  SOCKS proxy         127.0.0.1:$socks" }
    $ga = @('compute', 'ssh', $n) + (Get-GcloudScope) + @('--tunnel-through-iap', '--quiet', '--') + $f
    $proc = Start-Process -FilePath (Get-Command gcloud).Source -ArgumentList $ga -NoNewWindow -PassThru
    try {
        if ($open) {
            $deadline = (Get-Date).AddSeconds(60)
            while (-not (Test-LocalPort (6111 + $off)) -and (Get-Date) -lt $deadline -and -not $proc.HasExited) {
                Start-Sleep -Milliseconds 500
            }
            if ($proc.HasExited) { Stop-Lab "tunnel to $n stopped (exit $($proc.ExitCode))" }
            foreach ($u in $urls[1..5]) { Start-Process -FilePath $u }
            # base build console only while it runs
            if ((Invoke-WebRequestStatus "http://127.0.0.1:$(8006 + $off)/vnc.html") -eq 200) {
                Start-Process -FilePath $urls[0]
            }
            Write-LabOk 'console URLs opened in the default browser'
        }
        $proc | Wait-Process
        if ($proc.ExitCode) { Stop-Lab "tunnel to $n stopped (exit $($proc.ExitCode))" }
    } finally {
        if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    }
}
function Invoke-WebRequestStatus([string]$u) {
    try { (Invoke-WebRequest -Uri $u -TimeoutSec 5 -SkipHttpErrorCheck -UseBasicParsing).StatusCode } catch { 0 }
}

function Invoke-Snapshot([string]$key, [string]$snap) {
    Initialize-GcpContext
    $n = Get-VmName $key
    if (-not $snap) { $snap = "$n-snap-$(Get-Date -Format yyyyMMdd-HHmm)" }
    $status = Invoke-Gcloud -ArgList (@('compute', 'instances', 'describe', $n) + (Get-GcloudScope) +
        @('--format=value(status)'))
    if ($status -ne 'TERMINATED') {
        Stop-Lab "$n must be stopped for a consistent snapshot: ./lab.ps1 gcp stop $key"
    }
    Invoke-Gcloud -ArgList @('compute', 'snapshots', 'create', $snap, '--project', $script:Project,
        '--source-disk', $n, '--source-disk-zone', $script:Zone, '--storage-location', (Get-Region),
        '--labels', 'app=sql-ag-lab')
    if ($LASTEXITCODE) { Stop-Lab 'snapshot failed' }
    Write-LabOk ("snapshot $snap. Clone: add to vms terraform.tfvars:  " +
        "`"<owner>-<n>`" = { owner = ..., source_snapshot = `"$snap`" }")
}
function Invoke-Image([string]$key, [string]$fam = 'sqlag-lab-built') {
    Initialize-GcpContext
    $n = Get-VmName $key
    if (-not $fam) { $fam = 'sqlag-lab-built' }
    Write-GcpLog "stopping $n to take a consistent disk image"
    Invoke-Gcloud -ArgList (@('compute', 'instances', 'stop', $n) + (Get-GcloudScope))
    $img = "$fam-$(Get-Date -Format yyyyMMdd-HHmm)"
    Invoke-Gcloud -ArgList @('compute', 'images', 'create', $img, '--project', $script:Project,
        '--source-disk', $n, '--source-disk-zone', $script:Zone, '--family', $fam, '--labels', 'app=sql-ag-lab')
    if ($LASTEXITCODE) { Stop-Lab 'image failed' }
    Write-LabOk ("image $img (family $fam). New VMs from it: set " +
        "image = `"projects/$($script:Project)/global/images/family/$fam`" in vms terraform.tfvars")
}

# --------------------------------------------------------- golden snapshot flow --
function Get-LatestGolden {
    if ((Test-Path -Path $GoldenFile) -and (Get-Item -Path $GoldenFile).Length -gt 0) {
        return (Get-Content -LiteralPath $GoldenFile -TotalCount 1).Trim()
    }
    $list = @('compute', 'snapshots', 'list', '--project', $script:Project,
        '--filter=labels.app=sql-ag-lab AND labels.kind=golden', '--sort-by=~creationTimestamp', '--limit', '1',
        '--format=value(name)')
    (Invoke-Gcloud -ArgList $list 2>$null | Select-Object -First 1)
}
function Wait-Ready([string]$n) {
    $probe = "test -f /var/lib/sql-ag-lab/startup.done && grep -q '^LAB_GCP_NAME=$n`$' /etc/sql-ag-lab/gcp.env"
    for ($i = 0; $i -lt 120; $i++) {
        if ($null -ne (Get-Rcmd $n $probe)) { return }
        Start-Sleep -Seconds 5
    }
    Stop-Lab "${n}: no SSH / startup script after 10 min (see /var/log/sql-ag-lab-startup.log)"
}
function Invoke-Test([string]$key) {
    Initialize-GcpContext
    $n = Get-VmName $key
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Open-WatchGcp $key
    Add-LabNote "tests started on $n"
    Invoke-Rcmd $n ("cd $RemoteDir && rm -f logs/tests.passed && " +
        'setsid -f nohup tests/run-tcs.sh > logs/tests.log 2>&1 < /dev/null')
    $r = $null
    while ($true) {
        Start-Sleep -Seconds 20
        $r = Get-Rcmd $n "grep -E '^(ALL TESTS PASSED|TESTS FAILED)' $RemoteDir/logs/tests.log"
        if ($r) { break }
        if ($sw.Elapsed.TotalMinutes -gt 60) { Stop-Lab "tests on $n did not finish in 60 min" }
    }
    Invoke-Rcmd $n "grep -E '^(RESULT|TOTAL)' $RemoteDir/logs/tests.log" -AllowFail
    $s = [int]$sw.Elapsed.TotalSeconds
    if ($r.Trim() -eq 'ALL TESTS PASSED') {
        Add-LabNote "tests on ${n}: ALL TESTS PASSED ($s s)"
        Write-LabOk "all tests passed on $n"
    } else {
        Add-LabNote "tests on ${n}: FAILED, no golden snapshot"
        Stop-Lab "tests failed on $n (see ~/$RemoteDir/logs/tests.log). No snapshot."
    }
}
function Invoke-Golden([string]$key, [string]$snap) {
    Initialize-GcpContext
    $n = Get-VmName $key
    if (-not $snap) { $snap = "sqlag-golden-$(Get-Date -Format yyyyMMdd-HHmm)" }
    $probe = "cd $RemoteDir && test -f logs/tests.passed && " +
    'test logs/tests.passed -nt images/checkpoints/golden/meta.env && ' +
    "grep -h '^FINGERPRINT=' images/checkpoints/golden/meta.env && git rev-parse --short HEAD"
    $info = Get-Rcmd $n $probe
    if (-not $info) {
        Add-LabNote "golden snapshot of $n REFUSED: no current test pass"
        Stop-Lab "no current test pass on ${n}: run ./lab.ps1 gcp test $key first"
    }
    $lines = $info -split "`n" | Where-Object { $_ }
    $fpLine = $lines | Where-Object { $_ -like 'FINGERPRINT=*' } | Select-Object -First 1
    $fp = $fpLine -replace '^FINGERPRINT=', ''
    $commit = $lines[-1].Trim()
    Write-GcpLog "stopping the lab and $n for a consistent disk"
    Invoke-Rcmd $n "cd $RemoteDir && ./lab down >/dev/null" -AllowFail
    # the VM is TERMINATED after this
    Invoke-Gcloud -ArgList (@('compute', 'instances', 'stop', $n) + (Get-GcloudScope) + @('--quiet'))
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Invoke-Gcloud -ArgList @('compute', 'snapshots', 'create', $snap, '--project', $script:Project,
        '--source-disk', $n, '--source-disk-zone', $script:Zone, '--storage-location', (Get-Region),
        '--description', "sql-ag-lab golden from $n, commit $commit, checkpoint fingerprint $fp",
        '--labels', "app=sql-ag-lab,kind=golden,source=$n,fp=$($fp.ToLower()),commit=$($commit.ToLower())")
    if ($LASTEXITCODE) { Stop-Lab 'snapshot failed' }
    New-Item -ItemType Directory -Force -Path $StateDirGcp | Out-Null
    Set-Content -LiteralPath $GoldenFile -Value $snap
    Add-LabNote ("golden snapshot $snap of $n ($([int]$sw.Elapsed.TotalSeconds) s; fingerprint $fp, " +
        "commit $commit); recorded as latest; $n is TERMINATED")
    Write-LabOk "golden snapshot $snap (latest). Spawn clones: ./lab.ps1 gcp spawn NAME"
}
function Show-Snapshot {
    Initialize-GcpContext
    Write-GcpLog "golden snapshots (latest: $(Get-LatestGolden))"
    $format = "--format=table(name,creationTimestamp.date('%Y-%m-%d %H:%M'),diskSizeGb," +
    'storageBytes.size(units_out=G):label=STORED_GB,labels.kind,labels.source,labels.fp)'
    Invoke-Gcloud -ArgList @('compute', 'snapshots', 'list', '--project', $script:Project,
        '--filter=labels.app=sql-ag-lab', '--sort-by=~creationTimestamp', $format)
}
function Set-GoldenSnapshot {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Name)
    Initialize-GcpContext
    if (-not $Name) { Stop-Lab 'usage: use-snapshot NAME' }
    Invoke-Gcloud -ArgList @('compute', 'snapshots', 'describe', $Name, '--project', $script:Project,
        '--format=value(name)') | Out-Null
    if ($LASTEXITCODE) { Stop-Lab "no snapshot $Name" }
    if (-not $PSCmdlet.ShouldProcess($GoldenFile, "record $Name as the latest golden snapshot")) { return }
    New-Item -ItemType Directory -Force -Path $StateDirGcp | Out-Null
    Set-Content -LiteralPath $GoldenFile -Value $Name
    Write-LabOk "latest golden snapshot: $Name"
}

# spawned.auto.tfvars.json: { "spawned": { NAME: {owner, source_snapshot, publisher, disk_type?, machine_type?} } }
function Get-SpawnedData {
    if (Test-Path -Path (Get-SpawnedPath)) {
        Get-Content -LiteralPath (Get-SpawnedPath) -Raw | ConvertFrom-Json -AsHashtable
    } else { @{} }
}
function Test-Spawned([string]$name) {
    $d = Get-SpawnedData
    $d.ContainsKey('spawned') -and $d.spawned.ContainsKey($name)
}
function Edit-Spawned([string]$Op, [string]$Name, [hashtable]$Entry) {
    $d = Get-SpawnedData
    if (-not $d.ContainsKey('spawned')) { $d.spawned = [ordered]@{} }
    if ($Op -eq 'add') { $d.spawned[$Name] = $Entry } else { $d.spawned.Remove($Name) }
    $json = (($d | ConvertTo-Json -Depth 5) -replace "`r`n", "`n") + "`n"
    [IO.File]::WriteAllText((Get-SpawnedPath), $json, [Text.UTF8Encoding]::new($false))
}
function Invoke-Spawn([string[]]$a) {
    Initialize-GcpContext
    if (-not $a -or -not $a[0]) {
        Stop-Lab 'usage: spawn NAME [--disk-type pd-ssd|pd-standard|pd-balanced] [--snapshot S] [--no-up]'
    }
    $name = $a[0]
    $dtype = ''
    $snap = ''
    $mtype = ''
    $up = $true
    $owner = if ($env:LAB_GCP_OWNER) {
        $env:LAB_GCP_OWNER
    } else {
        ([Environment]::UserName.ToLower() -replace '[^a-z0-9-]', '')
    }
    if ($owner.Length -gt 30) { $owner = $owner.Substring(0, 30) }
    for ($i = 1; $i -lt $a.Count; $i++) {
        switch ($a[$i]) {
            '--disk-type' { $dtype = $a[++$i] }
            '--snapshot' { $snap = $a[++$i] }
            '--machine-type' { $mtype = $a[++$i] }
            '--owner' { $owner = $a[++$i] }
            '--no-up' { $up = $false }
            default { Stop-Lab "unknown option $($a[$i])" }
        }
    }
    if ($name -cnotmatch '^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$') {
        Stop-Lab 'NAME must be a GCE name (lowercase letters, digits, hyphens)'
    }
    if ((Get-VmLine | Where-Object { $_[0] -eq $name -or $_[1] -eq $name }) -and -not (Test-Spawned $name)) {
        Stop-Lab "$name is a VM from terraform.tfvars (vms); spawn only makes new clones"
    }
    if (-not $snap) { $snap = Get-LatestGolden }
    if (-not $snap) { Stop-Lab 'no golden snapshot: run ./lab.ps1 gcp finish VM (or use-snapshot NAME)' }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $e = [ordered]@{ owner = $owner; source_snapshot = $snap; publisher = $false }
    if ($dtype) { $e.disk_type = $dtype }
    if ($mtype) { $e.machine_type = $mtype }
    Edit-Spawned -Op add -Name $name -Entry $e
    Add-LabNote "spawn $name from $snap (disk $(if ($dtype) { $dtype } else { 'pd-balanced default' }))"
    & terraform "-chdir=$TfVms" apply -auto-approve "-target=google_compute_instance.lab[`"$name`"]"
    if ($LASTEXITCODE) {
        Stop-Lab ("terraform apply failed (entry kept in $(Get-SpawnedPath); fix and rerun, " +
            "or ./lab.ps1 gcp destroy $name)")
    }
    Update-TfOutput
    $t1 = $sw.Elapsed.TotalSeconds
    Wait-Ready $name
    $t2 = $sw.Elapsed.TotalSeconds
    Write-LabOk ("$name created in {0:N0} s, SSH ready after {1:N0} s" -f $t1, ($t2 - $t1))
    Invoke-Check $name
    if (-not $up) { return }
    Invoke-Push $name
    # Secret Manager; must be the key in the snapshot
    Invoke-Rcmd $name "cd $RemoteDir && deploy/gcp/artifacts.sh key fetch"
    Write-GcpLog 'first restore of golden (a disk from a snapshot loads blocks on first read: can take minutes)'
    # Each clone gets its own console token (the snapshot carries the token of the build VM).
    Invoke-Rcmd $name ("cd $RemoteDir && LAB_UP_TIMEOUT=1800 ./lab up golden && " +
        './lab console rotate >/dev/null && ./lab health --deep --wait 300')
    Add-LabNote ("spawn $name ready at golden (create {0:N0} s, SSH {1:N0} s, golden {2:N0} s)" -f
        $t1, ($t2 - $t1), ($sw.Elapsed.TotalSeconds - $t2))
    Write-LabOk "$name is at golden. Consoles: ./lab.ps1 gcp console $name   Remove: ./lab.ps1 gcp destroy $name"
}
function Invoke-DestroyVm([string]$name, [string]$flag) {
    if (-not (Test-Spawned $name)) {
        Stop-Lab ("$name was not made by ./lab.ps1 gcp spawn. VMs in terraform.tfvars (for example bill-1) " +
            'are kept safe: remove them with ./lab.ps1 gcp delete KEY')
    }
    if ($flag -ne '--yes') {
        $prompt = "Delete VM $name and its disk (data on it is lost; snapshots stay)? Type the name to confirm"
        $a = Read-Host -Prompt $prompt
        if ($a -ne $name) { Stop-Lab 'not confirmed' }
    }
    & terraform "-chdir=$TfVms" destroy -auto-approve "-target=google_compute_instance.lab[`"$name`"]"
    if ($LASTEXITCODE) { Stop-Lab 'terraform destroy failed' }
    Edit-Spawned -Op del -Name $name
    Update-TfOutput
    Add-LabNote "destroyed spawned VM $name (and its boot disk)"
    Write-LabOk "$name deleted"
}
function Show-Cost {
    @'
Rough ESTIMATE from public us-central1 list prices (2025-2026); check the Pricing Calculator:
  n2-standard-16 standard  ~ $0.78 / h        spot  ~ $0.19-0.25 / h (varies)
  pd-ssd 300 GB            ~ $51 / month      (~ $0.07 / h, charged also while STOPPED)
  Cloud NAT                ~ $0.045 / h per gateway + $0.045 / GB processed
  Bucket (Standard)        ~ $0.02 / GB-month (ISO 1.2 GB + base 7 GB + checkpoints ~25-40 GB)
  Example: one spot VM, 40 h/month running: ~$10 compute + $51 disk + NAT ~ $35 = about $95 / month.
Stop VMs when idle (./lab.ps1 gcp stop VM). Delete them when not needed for days (disk is the main idle cost).
'@ | Write-Host
}

function Invoke-LabGcp([string[]]$Argv) {
    $c = if ($Argv.Count) { $Argv[0] } else { 'help' }
    [string[]]$a = if ($Argv.Count -gt 1) { $Argv[1..($Argv.Count - 1)] } else { @() }
    if ($null -eq $a) { $a = [string[]]@() }
    function Get-FirstArg([string]$what = 'VM required') {
        if (-not $a.Count -or -not $a[0]) { Stop-Lab $what }
        $a[0]
    }
    function Get-RestArg { if ($a.Count -gt 1) { , [string[]]$a[1..($a.Count - 1)] } else { , [string[]]@() } }
    $first = if ($a.Count) { $a[0] } else { '' }
    $second = if ($a.Count -gt 1) { $a[1] } else { '' }
    switch ($c) {
        { $_ -in 'help', '-h', '--help' } { Show-Usage }
        'destroy' {
            if (-not $a.Count -or $a[0] -in 'shared', 'vms') {
                Invoke-TfCmd -Action destroy -Root $(if ($a.Count) { $a[0] } else { 'vms' })
            } else {
                Initialize-GcpContext
                Invoke-DestroyVm $a[0] $second
            }
        }
        { $_ -in 'init', 'plan' } {
            $root = 'vms'
            $x = @()
            foreach ($v in $a) { if ($v -in 'shared', 'vms') { $root = $v } else { $x += $v } }
            Invoke-TfCmd -Action $c -Root $root -Extra $x
        }
        'apply' {
            $root = 'vms'
            $x = @()
            foreach ($v in $a) {
                switch ($v) {
                    { $_ -in 'shared', 'vms' } { $root = $v }
                    { $_ -in '-y', '--yes', '-auto-approve' } { $x += '-auto-approve' }
                    default { $x += $v }
                }
            }
            Invoke-TfCmd -Action apply -Root $root -Extra $x
        }
        'test' { Invoke-Test (Get-FirstArg) }
        'golden' { Invoke-Golden (Get-FirstArg) $second }
        'finish' {
            Invoke-Test (Get-FirstArg)
            Invoke-Golden $a[0] $second
        }
        'spawn' { Invoke-Spawn $a }
        'key' { Invoke-Key $a }
        'snapshots' { Show-Snapshot }
        'use-snapshot' { Set-GoldenSnapshot -Name $first }
        'tf-check' { Invoke-TfCheck }
        'tools' { Test-OperatorTool }
        'create' { Invoke-Create $first (Get-RestArg) }
        'delete' { Invoke-Delete $first (Get-RestArg) }
        'list' { Invoke-List }
        { $_ -in 'start', 'stop' } {
            Initialize-GcpContext
            Invoke-Gcloud -ArgList (@('compute', 'instances', $c, (Get-VmName (Get-FirstArg))) + (Get-GcloudScope))
            if ($LASTEXITCODE) { Stop-Lab "$c failed" }
        }
        'ssh' {
            Initialize-GcpContext
            $n = Get-VmName (Get-FirstArg)
            if ($a.Count -gt 1) { Invoke-Rcmd $n ((Get-RestArg) -join ' ') } else { Invoke-Gssh $n @() }
        }
        'check' { Invoke-Check (Get-FirstArg) }
        'push' { Invoke-Push (Get-FirstArg) }
        'deploy' { Invoke-Deploy (Get-FirstArg) (Get-RestArg) }
        'watch' { Invoke-Watch (Get-FirstArg) }
        'tunnel' { Invoke-Tunnel (Get-FirstArg) (Get-RestArg) }
        'console' { Invoke-Tunnel (Get-FirstArg) ([string[]](Get-RestArg) + '--open') }
        'image' { Invoke-Image (Get-FirstArg) $second }
        'snapshot' { Invoke-Snapshot (Get-FirstArg) $second }
        'artifacts' {
            Initialize-GcpContext
            Invoke-Rcmd (Get-VmName (Get-FirstArg)) "cd $RemoteDir && deploy/gcp/artifacts.sh status"
        }
        'watch-term' {
            Initialize-GcpContext
            Open-WatchGcp (Get-FirstArg) -Force
        }
        'publish' {
            Initialize-GcpContext
            $n = Get-VmName (Get-FirstArg)
            Open-WatchGcp $a[0]
            Invoke-Rcmd $n "cd $RemoteDir && deploy/gcp/artifacts.sh publish $((Get-RestArg) -join ' ')"
        }
        'fetch' {
            Initialize-GcpContext
            $n = Get-VmName (Get-FirstArg)
            Invoke-Rcmd $n "cd $RemoteDir && deploy/gcp/artifacts.sh fetch $((Get-RestArg) -join ' ')"
        }
        'cost' { Show-Cost }
        default {
            Show-Usage
            Stop-Lab "unknown command: $c"
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    # dot-sourcing (Pester) loads the functions only
    try {
        Invoke-LabGcp -Argv ([string[]]$args)
        exit 0
    } catch {
        [Console]::Error.WriteLine("  error $($_.Exception.Message)")
        if ($_.Exception.GetType().Name -ne 'LabError') { [Console]::Error.WriteLine($_.ScriptStackTrace) }
        exit 1
    }
}
