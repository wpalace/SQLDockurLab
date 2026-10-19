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
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$GcpDir = $PSScriptRoot
$LabRoot = (Resolve-Path (Join-Path $GcpDir '../..')).Path
Import-Module (Join-Path $LabRoot 'lib/LabHost.psm1') -Force -DisableNameChecking
$TfShared = Join-Path $GcpDir 'terraform/shared'
$TfVms = Join-Path $GcpDir 'terraform/vms'
$RemoteDir = if ($env:LAB_GCP_REMOTE_DIR) { $env:LAB_GCP_REMOTE_DIR } else { 'sql-ag-lab' }   # relative to the remote home
$StateDirGcp = Join-Path $GcpDir 'state'
$GoldenFile = Join-Path $StateDirGcp 'golden-snapshot'
function Get-SpawnedPath { if ($env:LAB_GCP_SPAWNED_JSON) { $env:LAB_GCP_SPAWNED_JSON } else { Join-Path $TfVms 'spawned.auto.tfvars.json' } }
$script:Project = $null; $script:Zone = $null; $script:Prefix = 'sqlag'
if (-not $IsWindows) {
    foreach ($p in @("$HOME/.local/bin", "$HOME/.local/google-cloud-sdk/bin")) { if ($env:PATH -notlike "*$p*") { $env:PATH += [IO.Path]::PathSeparator + $p } }
}

function Log([string]$m) { Write-LabLog gcp $m }
function Ok([string]$m) { Write-LabOk $m }
function Warn([string]$m) { Write-LabWarn $m }
function Die([string]$m) { Stop-Lab $m }

function Show-Usage {
    @'
Usage: ./lab.ps1 gcp <command> [args]     (VM = key like bill-1, or the full VM name)
       (the same commands as ./lab gcp on Linux; this front end needs only pwsh 7, gcloud, terraform, git)

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
                         forward VNC (8006, 6111-6115) and optionally SQL to this machine;
                         --open opens the console URLs in the default browser
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
function Need([string]$Exe, [string]$Hint) { if (-not (Get-Command $Exe -ErrorAction SilentlyContinue)) { Die "$Exe not found. $Hint" } }
function Invoke-Native {
    # run a native command; throw when it fails (unless -AllowFail)
    param([string]$Exe, [string[]]$ArgList, [switch]$AllowFail, [switch]$Quiet)
    if ($Quiet) { & $Exe @ArgList 2>$null | Out-Null } else { & $Exe @ArgList }
    $rc = $LASTEXITCODE
    if ($rc -ne 0 -and -not $AllowFail) { Die "$Exe $($ArgList[0..1] -join ' ') failed (exit $rc)" }
}
function Tf { Need terraform 'Install Terraform >= 1.5 (Windows: winget install Hashicorp.Terraform).'; & terraform @args; if ($LASTEXITCODE) { Die "terraform $($args[0..1] -join ' ') failed (exit $LASTEXITCODE)" } }
function Invoke-Gcloud { Need gcloud 'Install the Google Cloud CLI (Windows: winget install Google.CloudSDK).'; & gcloud @args }
function Get-TfRoot([string]$r = 'vms') { switch ($r) { 'shared' { $TfShared } 'vms' { $TfVms } default { Die 'ROOT must be shared or vms' } } }
function Assert-TfVars([string]$dir) { if (-not (Test-Path (Join-Path $dir 'terraform.tfvars'))) { Die "missing $dir/terraform.tfvars: copy terraform.tfvars.example and fill it in (MAKE.md G2)" } }
function Get-TfOut([string]$name) {
    if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) { return '' }
    $o = & terraform "-chdir=$TfVms" output -raw $name 2>$null; if ($LASTEXITCODE) { return '' }; ($o -join "`n")
}
function Set-Ctx {
    $script:Project = if ($env:GCP_PROJECT) { $env:GCP_PROJECT } else { Get-TfOut project_id }
    $script:Zone = if ($env:GCP_ZONE) { $env:GCP_ZONE } else { Get-TfOut zone }
    $script:Prefix = if ($env:GCP_NAME_PREFIX) { $env:GCP_NAME_PREFIX } else { 'sqlag' }
    if (-not $script:Project -or -not $script:Zone) { Die 'unknown project/zone: run ./lab.ps1 gcp apply first, or set GCP_PROJECT and GCP_ZONE' }
}
function Get-VmLines { @((Get-TfOut vm_lines) -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { , ($_ -split '\s+') }) }
function Get-VmName([string]$n) {
    if (-not $n) { Die 'VM required' }
    if ($n -like "$($script:Prefix)-*") { return $n }
    if (Test-Spawned $n) { return $n }
    foreach ($l in Get-VmLines) { if ($l[0] -eq $n -or $l[1] -eq $n) { return $l[1] } }
    "$($script:Prefix)-$n"
}
function Get-Region { $script:Zone -replace '-[a-z]$', '' }

# IAP SSH. On Windows gcloud uses PuTTY (plink/pscp); on Linux OpenSSH.
function Invoke-Gssh([string]$n, [string[]]$Extra) { Invoke-Gcloud compute ssh $n --project $script:Project --zone $script:Zone --tunnel-through-iap --quiet @Extra }
# Remote command: sent base64-encoded, so no local shell (cmd.exe for gcloud.cmd, pwsh) touches
# quotes, pipes, $ or && in it. The VM decodes it and runs it with bash.
function Invoke-Rcmd([string]$n, [string]$Command, [switch]$AllowFail) {
    $b = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Command -replace "`r`n", "`n")))
    Invoke-Gssh $n @("--command=f=`$(mktemp); echo $b | base64 -d > `$f; bash `$f < /dev/null; rc=`$?; rm -f `$f; exit `$rc")
    if ($LASTEXITCODE -and -not $AllowFail) { Die "remote command on $n failed (exit $LASTEXITCODE)" }
}
function Get-Rcmd([string]$n, [string]$Command) {
    # output as text; $null on failure
    $b = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Command -replace "`r`n", "`n")))
    $o = Invoke-Gssh $n @("--command=f=`$(mktemp); echo $b | base64 -d > `$f; bash `$f < /dev/null; rc=`$?; rm -f `$f; exit `$rc") 2>$null
    if ($LASTEXITCODE) { return $null }; ($o -join "`n")
}
# SCP of one local file. gcloud reads "C:\x" as INSTANCE:PATH, so copy from the file's folder by name.
function Copy-ToVm([string]$n, [string]$Local, [string]$Remote) {
    Push-Location (Split-Path -Parent $Local)
    try { Invoke-Gcloud compute scp --project $script:Project --zone $script:Zone --tunnel-through-iap --quiet (Split-Path -Leaf $Local) "${n}:$Remote"; if ($LASTEXITCODE) { Die "scp to $n failed" } }
    finally { Pop-Location }
}

function Open-WatchGcp([string]$key, [switch]$Force) {
    $self = (Join-Path $LabRoot 'lab.ps1').Replace("'", "''")
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
        'init' { Tf "-chdir=$dir" init -upgrade @Extra }
        'plan' { Assert-TfVars $dir; Tf "-chdir=$dir" plan @Extra }
        'apply' { Assert-TfVars $dir; Tf "-chdir=$dir" apply @Extra }
        'destroy' { Assert-TfVars $dir; Tf "-chdir=$dir" destroy @Extra }
    }
}
function Invoke-TfCheck {
    $rc = 0
    foreach ($d in @($TfShared, $TfVms)) {
        Log "terraform fmt/validate $([IO.Path]::GetRelativePath($LabRoot, $d))"
        & terraform "-chdir=$d" fmt -check -diff; if ($LASTEXITCODE) { $rc = 1 }
        & terraform "-chdir=$d" init -backend=false -input=false | Out-Null; if ($LASTEXITCODE) { $rc = 1 }
        & terraform "-chdir=$d" validate; if ($LASTEXITCODE) { $rc = 1 }
    }
    if ($rc) { Die 'terraform checks failed' }
}
function Update-TfOutputs { & terraform "-chdir=$TfVms" apply -refresh-only -auto-approve -input=false | Out-Null; if ($LASTEXITCODE) { Warn 'could not refresh terraform outputs' } }
# --yes (agents, after approval from the user) adds -auto-approve.
function Get-YesFlag([string[]]$f) { if (@($f | Where-Object { $_ -in '-y', '--yes', '-auto-approve' })) { , @('-auto-approve') } else { , @() } }
function Invoke-Create([string]$k, [string[]]$Flags) { if (-not $k) { Die 'usage: create KEY [--yes]' }; Assert-TfVars $TfVms; Tf "-chdir=$TfVms" apply @(Get-YesFlag $Flags) "-target=google_compute_instance.lab[`"$k`"]"; Update-TfOutputs }
function Invoke-Delete([string]$k, [string[]]$Flags) { if (-not $k) { Die 'usage: delete KEY [--yes]' }; Assert-TfVars $TfVms; Tf "-chdir=$TfVms" destroy @(Get-YesFlag $Flags) "-target=google_compute_instance.lab[`"$k`"]"; Update-TfOutputs }

function Test-Tools {
    # operator prerequisites (MAKE.md G1)
    $fails = 0
    Ok "pwsh $($PSVersionTable.PSVersion) on $([Runtime.InteropServices.RuntimeInformation]::OSDescription)"
    if ($PSVersionTable.PSVersion.Major -lt 7) { Warn 'PowerShell 7 or later is necessary'; $fails++ }
    foreach ($t in @(@('gcloud', 'version', 'winget install Google.CloudSDK'), @('terraform', 'version', 'winget install Hashicorp.Terraform'), @('git', '--version', 'winget install Git.Git'))) {
        $c = Get-Command $t[0] -ErrorAction SilentlyContinue
        if (-not $c) { Warn "$($t[0]) not found: $($t[2])"; $fails++; continue }
        $v = (& $t[0] $t[1] 2>$null | Select-Object -First 1); Ok "$($t[0]): $v ($($c.Source))"
    }
    if (Get-Command terraform -ErrorAction SilentlyContinue) {
        $tv = (& terraform version -json 2>$null | ConvertFrom-Json).terraform_version
        if ([version]$tv -lt [version]'1.5.0') { Warn "terraform ${tv}: 1.5 or later is necessary"; $fails++ }
    }
    if (Get-Command gcloud -ErrorAction SilentlyContinue) {
        $acct = (& gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>$null | Select-Object -First 1)
        if ($acct) { Ok "gcloud account $acct" } else { Warn 'no active gcloud account: gcloud auth login'; $fails++ }
        & gcloud auth application-default print-access-token 2>$null | Out-Null
        if ($LASTEXITCODE) { Warn 'no application-default credentials (terraform): gcloud auth application-default login'; $fails++ } else { Ok 'application-default credentials' }
    }
    if ($IsWindows) {
        if (Get-Command wt.exe -ErrorAction SilentlyContinue) { Ok 'Windows Terminal (watch terminal)' } else { Warn 'no Windows Terminal: the watch terminal opens in a new pwsh window' }
    } elseif (-not ($env:DISPLAY -or $env:WAYLAND_DISPLAY)) { Warn 'no graphical session: the watch terminal prints a command instead' }
    foreach ($d in @($TfShared, $TfVms)) { if (Test-Path (Join-Path $d 'terraform.tfvars')) { Ok "$([IO.Path]::GetRelativePath($LabRoot, $d))/terraform.tfvars present" } else { Warn "$([IO.Path]::GetRelativePath($LabRoot, $d))/terraform.tfvars missing (MAKE.md G2)" } }
    if ($fails) { Die "$fails operator prerequisite(s) missing" }
    Ok 'operator tools ready'
}

function Invoke-List {
    Set-Ctx
    Invoke-Gcloud compute instances list --project $script:Project --filter=labels.app=sql-ag-lab `
        '--format=table(name,zone.basename(),machineType.basename(),status,labels.owner,scheduling.provisioningModel,advancedMachineFeatures.enableNestedVirtualization:label=NESTED)'
}

# ---------------------------------------------------------------------- check --
function Invoke-Check([string]$key) {
    Set-Ctx; $n = Get-VmName $key; $fails = 0
    Log "GCE settings of $n"
    $d = Invoke-Gcloud compute instances describe $n --project $script:Project --zone $script:Zone `
        '--format=value(status,advancedMachineFeatures.enableNestedVirtualization,minCpuPlatform,cpuPlatform,machineType.basename(),scheduling.provisioningModel,networkInterfaces[0].accessConfigs[0].natIP)'
    if ($LASTEXITCODE -or -not $d) { Die "VM $n not found in $($script:Project)/$($script:Zone)" }
    $f = @(($d | Select-Object -First 1) -split "`t") + @('', '', '', '', '', '', '')
    $status, $nested, $minp, $cpup, $mtype, $model, $natip = $f[0..6]
    if ($status -eq 'RUNNING') { Ok 'status RUNNING' } else { Warn "status ${status}: run ./lab.ps1 gcp start $key"; $fails++ }
    if ($nested -eq 'true' -or $nested -eq 'True') { Ok 'enableNestedVirtualization=true' } else { Warn 'nested virtualization OFF: set enable_nested_virtualization (terraform vms root) and apply'; $fails++ }
    if ($minp) { Ok "minCpuPlatform=$minp (running on $cpup)" } else { Warn 'no minCpuPlatform: checkpoints may not restore on other CPUs' }
    if ($mtype -match '^(e2|n2d|c2d|c3d|c4d|t2d|t2a|c4a)-') { Warn "$mtype does not support nested virtualization"; $fails++ } else { Ok "machine type $mtype ($model)" }
    if (-not $natip) { Ok 'no external IP (IAP only)' } else { Warn "external IP $natip present" }
    $line = Get-VmLines | Where-Object { $_[1] -eq $n } | Select-Object -First 1
    if ($line) {
        $emt = $line[2]; $emp = ($line[3] -replace '_', ' ')
        if ($emt -eq $mtype) { Ok 'machine type matches terraform' } else { Warn "machine type $mtype, terraform says $emt" }
        if ($emp -eq $minp) { Ok 'min CPU platform matches terraform' } else { Warn "min CPU platform '$minp', terraform says '$emp'" }
    } else { Warn "$n is not in the terraform vms outputs (created by hand?)" }
    if ($fails) { Die 'fix the GCE settings above first' }
    Log 'prerequisites on the VM'
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "sqlag-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try { ConvertTo-LfFile (Join-Path $GcpDir 'vm-check.sh') (Join-Path $tmp 'vm-check.sh'); Copy-ToVm $n (Join-Path $tmp 'vm-check.sh') '/tmp/vm-check.sh' }
    finally { Remove-Item -Recurse -Force $tmp }
    Invoke-Rcmd $n 'bash /tmp/vm-check.sh' -AllowFail; if ($LASTEXITCODE) { Die 'VM prerequisites failed (see FAIL lines)' }
    if ($null -ne (Get-Rcmd $n "test -x $RemoteDir/lab")) {
        Log './lab doctor on the VM'; Invoke-Rcmd $n "cd $RemoteDir && ./lab doctor" -AllowFail
        if ($LASTEXITCODE) { Die './lab doctor reported problems' }
    } else { Warn "repository not on the VM yet: run ./lab.ps1 gcp push $key, then check again" }
    Ok "$n is ready for the lab"
}

# ---------------------------------------------------------------- push/deploy --
# A git bundle carries git objects (stored with LF, see .gitattributes); the VM clones it on
# Linux, so shell scripts arrive with LF also when this checkout on Windows uses CRLF.
function Invoke-Push([string]$key) {
    Set-Ctx; $n = Get-VmName $key
    Need git 'Install Git (Windows: winget install Git.Git).'
    & git -C $LabRoot diff --quiet HEAD --; if ($LASTEXITCODE) { Warn 'uncommitted changes are NOT copied (commit first)' }
    $pw = Get-LabPassword   # fail fast before copying anything
    $br = (& git -C $LabRoot rev-parse --abbrev-ref HEAD).Trim()
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "sqlag-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $b = Join-Path $tmp 'sql-ag-lab.bundle'
        & git -C $LabRoot bundle create $b HEAD $br 2>$null; if ($LASTEXITCODE) { Die 'git bundle failed' }
        Copy-ToVm $n $b '/tmp/sql-ag-lab.bundle'
        # The password goes in a file (never on a command line) to lab.local.env on the VM (mode 600 there).
        $pf = Join-Path $tmp 'lab-password.env'
        [IO.File]::WriteAllText($pf, "LAB_PASSWORD='$pw'`n")
        if (-not $IsWindows) { & chmod 600 $pf }
        Copy-ToVm $n $pf '/tmp/lab-password.env'
    } finally { Remove-Item -Recurse -Force $tmp }
    Invoke-Rcmd $n @"
set -e; id -nG | grep -qw docker || sudo usermod -aG docker "`$USER"
if [ -d $RemoteDir/.git ]; then git -C $RemoteDir pull -q --ff-only /tmp/sql-ag-lab.bundle $br
else git clone -q -b $br /tmp/sql-ag-lab.bundle $RemoteDir; fi
$(Get-RemotePasswordMerge)
git -C $RemoteDir log --oneline -1
"@
    Ok "repository on ${n}:~/$RemoteDir (reconnect once so group docker applies)"
}
# Remote shell: move /tmp/lab-password.env into lab.local.env (replace the LAB_PASSWORD line), mode 600.
function Get-RemotePasswordMerge {
    @"
chmod 600 /tmp/lab-password.env; touch $RemoteDir/lab.local.env; chmod 600 $RemoteDir/lab.local.env
{ grep -v '^LAB_PASSWORD=' $RemoteDir/lab.local.env || true; cat /tmp/lab-password.env; } > $RemoteDir/lab.local.env.new
mv $RemoteDir/lab.local.env.new $RemoteDir/lab.local.env; chmod 600 $RemoteDir/lab.local.env; rm -f /tmp/lab-password.env /tmp/sql-ag-lab.bundle
"@
}
function Invoke-Key([string[]]$a) {
    # key push|fetch|check VM | key status
    Set-Ctx; $act = if ($a.Count) { $a[0] } else { '' }
    switch ($act) {
        { $_ -in 'push', 'fetch', 'check' } {
            if ($a.Count -lt 2 -or -not $a[1]) { Die "usage: key $act VM" }
            $extra = if ($a.Count -gt 2) { ' ' + ($a[2..($a.Count - 1)] -join ' ') } else { '' }
            Invoke-Rcmd (Get-VmName $a[1]) "cd $RemoteDir && deploy/gcp/artifacts.sh key $act$extra"
        }
        'status' {
            Invoke-Gcloud secrets versions list "$($script:Prefix)-lab-ssh-key" --project $script:Project '--format=table(name.basename():label=VERSION,state,createTime.date(tz=LOCAL))'
            if ($LASTEXITCODE) { Die 'gcloud secrets versions list failed (secret missing or no roles/secretmanager.viewer/secretAccessor)' }
        }
        default { Die 'usage: key push|fetch|check VM | key status' }
    }
}
function Invoke-Deploy([string]$key, [string[]]$Rest) {
    $Rest = @($Rest | Where-Object { $_ })
    Set-Ctx; $n = Get-VmName $key
    Invoke-Rcmd $n "cd $RemoteDir && setsid -f nohup deploy/gcp/remote-deploy.sh $($Rest -join ' ') > logs-gcp-deploy.log 2>&1 < /dev/null; sleep 2; tail -3 logs-gcp-deploy.log" -AllowFail
    if ($LASTEXITCODE) { Warn 'could not read the deploy log yet (the deploy runs on the VM)' }
    Ok "deploy started on $n. Follow it: ./lab.ps1 gcp watch $key   Consoles: ./lab.ps1 gcp console $key"
    Open-WatchGcp $key
}
function Invoke-Watch([string]$key) {
    Set-Ctx; $n = Get-VmName $key
    Invoke-Gssh $n @("--command=tail -n 40 -F $RemoteDir/logs-gcp-deploy.log $RemoteDir/logs/progress.log", '--', '-t')
}

# --------------------------------------------------------------------- tunnel --
function Test-LocalPort([int]$p) {
    $c = [Net.Sockets.TcpClient]::new()
    try { $c.ConnectAsync('127.0.0.1', $p).Wait(300) -and $c.Connected } catch { $false } finally { $c.Dispose() }
}
function Invoke-Tunnel([string]$key, [string[]]$Rest) {
    $Rest = @($Rest | Where-Object { $_ })
    Set-Ctx; $n = Get-VmName $key; $sql = $false; $socks = ''; $off = $null; $open = $false
    for ($i = 0; $i -lt $Rest.Count; $i++) {
        switch ($Rest[$i]) { '--sql' { $sql = $true } '--socks' { $socks = $Rest[++$i] } '--offset' { $off = [int]$Rest[++$i] } '--open' { $open = $true } default { Die "unknown option $($Rest[$i])" } }
    }
    $vnc = @(8006, 6111, 6112, 6113, 6114, 6115)
    if ($null -eq $off) {
        $off = 0; foreach ($p in $vnc) { if (Test-LocalPort $p) { $off = 10000 } }
        if ($off) { Warn "local ports 8006/6111-6115 are in use (local lab?): forwarding to local port + $off" }
    }
    Log "tunnel to $n (Ctrl-C to stop)"
    # One IAP SSH session with local forwards. The consoles listen on 127.0.0.1 of the VM and the
    # lab networks exist only on the VM, so IAP TCP forwarding to the VM NIC cannot reach them.
    $f = @('-N')
    foreach ($p in $vnc) { $f += @('-L', "$($p + $off):127.0.0.1:$p") }
    if ($sql) { foreach ($m in @('14330:10.50.0.60', '14339:10.51.0.60', '14331:10.50.0.11', '14332:10.50.0.12', '14333:10.51.0.13', '14334:10.51.0.14')) { $f += @('-L', "${m}:1433") } }
    if ($socks) { $f += @('-D', $socks) }
    if (-not $IsWindows) { $f = @('-o', 'ExitOnForwardFailure=yes') + $f }   # OpenSSH only (Windows: plink)
    $urls = @("http://127.0.0.1:$(8006 + $off)") + @(6111..6115 | ForEach-Object { "http://127.0.0.1:$($_ + $off)/vnc.html?autoconnect=1&resize=scale&reconnect=1" })
    Write-Host "  base build console  $($urls[0])"
    $urls[1..5] | ForEach-Object { Write-Host "  VM console          $_" }
    if ($sql) {
        Write-Host '  SQL listener        127.0.0.1,14330 (subnet A IP; use 14339 when the primary is on SQL3/SQL4)'
        Write-Host '  SQL1..SQL4          127.0.0.1,14331 .. 127.0.0.1,14334 (SQL auth)'
    }
    if ($socks) { Write-Host "  SOCKS proxy         127.0.0.1:$socks" }
    $ga = @('compute', 'ssh', $n, '--project', $script:Project, '--zone', $script:Zone, '--tunnel-through-iap', '--quiet', '--') + $f
    $proc = Start-Process (Get-Command gcloud).Source -ArgumentList $ga -NoNewWindow -PassThru
    try {
        if ($open) {
            $deadline = (Get-Date).AddSeconds(60)
            while (-not (Test-LocalPort (6111 + $off)) -and (Get-Date) -lt $deadline -and -not $proc.HasExited) { Start-Sleep -Milliseconds 500 }
            if ($proc.HasExited) { Die "tunnel to $n stopped (exit $($proc.ExitCode))" }
            foreach ($u in $urls[1..5]) { Start-Process $u }
            if ((Invoke-WebRequestStatus $urls[0]) -eq 200) { Start-Process $urls[0] }   # base build console only while it runs
            Ok 'console URLs opened in the default browser'
        }
        $proc | Wait-Process
        if ($proc.ExitCode) { Die "tunnel to $n stopped (exit $($proc.ExitCode))" }
    } finally { if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } }
}
function Invoke-WebRequestStatus([string]$u) {
    try { (Invoke-WebRequest -Uri $u -TimeoutSec 5 -SkipHttpErrorCheck -UseBasicParsing).StatusCode } catch { 0 }
}

function Invoke-Snapshot([string]$key, [string]$snap) {
    Set-Ctx; $n = Get-VmName $key; if (-not $snap) { $snap = "$n-snap-$(Get-Date -Format yyyyMMdd-HHmm)" }
    if ((Invoke-Gcloud compute instances describe $n --project $script:Project --zone $script:Zone '--format=value(status)') -ne 'TERMINATED') { Die "$n must be stopped for a consistent snapshot: ./lab.ps1 gcp stop $key" }
    Invoke-Gcloud compute snapshots create $snap --project $script:Project --source-disk $n --source-disk-zone $script:Zone --storage-location (Get-Region) --labels app=sql-ag-lab
    if ($LASTEXITCODE) { Die 'snapshot failed' }
    Ok "snapshot $snap. Clone: add to vms terraform.tfvars:  `"<owner>-<n>`" = { owner = ..., source_snapshot = `"$snap`" }"
}
function Invoke-Image([string]$key, [string]$fam = 'sqlag-lab-built') {
    Set-Ctx; $n = Get-VmName $key; if (-not $fam) { $fam = 'sqlag-lab-built' }
    Log "stopping $n to take a consistent disk image"; Invoke-Gcloud compute instances stop $n --project $script:Project --zone $script:Zone
    $img = "$fam-$(Get-Date -Format yyyyMMdd-HHmm)"
    Invoke-Gcloud compute images create $img --project $script:Project --source-disk $n --source-disk-zone $script:Zone --family $fam --labels app=sql-ag-lab
    if ($LASTEXITCODE) { Die 'image failed' }
    Ok "image $img (family $fam). New VMs from it: set image = `"projects/$($script:Project)/global/images/family/$fam`" in vms terraform.tfvars"
}

# --------------------------------------------------------- golden snapshot flow --
function Get-LatestGolden {
    if ((Test-Path $GoldenFile) -and (Get-Item $GoldenFile).Length -gt 0) { return (Get-Content -LiteralPath $GoldenFile -TotalCount 1).Trim() }
    (Invoke-Gcloud compute snapshots list --project $script:Project '--filter=labels.app=sql-ag-lab AND labels.kind=golden' --sort-by=~creationTimestamp --limit 1 '--format=value(name)' 2>$null | Select-Object -First 1)
}
function Wait-Ready([string]$n) {
    for ($i = 0; $i -lt 120; $i++) {
        if ($null -ne (Get-Rcmd $n "test -f /var/lib/sql-ag-lab/startup.done && grep -q '^LAB_GCP_NAME=$n`$' /etc/sql-ag-lab/gcp.env")) { return }
        Start-Sleep -Seconds 5
    }
    Die "${n}: no SSH / startup script after 10 min (see /var/log/sql-ag-lab-startup.log)"
}
function Invoke-Test([string]$key) {
    Set-Ctx; $n = Get-VmName $key; $sw = [Diagnostics.Stopwatch]::StartNew()
    Open-WatchGcp $key; Add-LabNote "tests started on $n"
    Invoke-Rcmd $n "cd $RemoteDir && rm -f logs/tests.passed && setsid -f nohup tests/run-tcs.sh > logs/tests.log 2>&1 < /dev/null"
    $r = $null
    while ($true) {
        Start-Sleep -Seconds 20
        $r = Get-Rcmd $n "grep -E '^(ALL TESTS PASSED|TESTS FAILED)' $RemoteDir/logs/tests.log"
        if ($r) { break }
        if ($sw.Elapsed.TotalMinutes -gt 60) { Die "tests on $n did not finish in 60 min" }
    }
    Invoke-Rcmd $n "grep -E '^(RESULT|TOTAL)' $RemoteDir/logs/tests.log" -AllowFail
    $s = [int]$sw.Elapsed.TotalSeconds
    if ($r.Trim() -eq 'ALL TESTS PASSED') { Add-LabNote "tests on ${n}: ALL TESTS PASSED ($s s)"; Ok "all tests passed on $n" }
    else { Add-LabNote "tests on ${n}: FAILED, no golden snapshot"; Die "tests failed on $n (see ~/$RemoteDir/logs/tests.log). No snapshot." }
}
function Invoke-Golden([string]$key, [string]$snap) {
    Set-Ctx; $n = Get-VmName $key; if (-not $snap) { $snap = "sqlag-golden-$(Get-Date -Format yyyyMMdd-HHmm)" }
    $info = Get-Rcmd $n "cd $RemoteDir && test -f logs/tests.passed && test logs/tests.passed -nt images/checkpoints/golden/meta.env && grep -h '^FINGERPRINT=' images/checkpoints/golden/meta.env && git rev-parse --short HEAD"
    if (-not $info) { Add-LabNote "golden snapshot of $n REFUSED: no current test pass"; Die "no current test pass on ${n}: run ./lab.ps1 gcp test $key first" }
    $lines = $info -split "`n" | Where-Object { $_ }
    $fp = ($lines | Where-Object { $_ -like 'FINGERPRINT=*' } | Select-Object -First 1) -replace '^FINGERPRINT=', ''
    $commit = $lines[-1].Trim()
    Log "stopping the lab and $n for a consistent disk"
    Invoke-Rcmd $n "cd $RemoteDir && ./lab down >/dev/null" -AllowFail
    Invoke-Gcloud compute instances stop $n --project $script:Project --zone $script:Zone --quiet   # the VM is TERMINATED after this
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Invoke-Gcloud compute snapshots create $snap --project $script:Project --source-disk $n --source-disk-zone $script:Zone `
        --storage-location (Get-Region) --description "sql-ag-lab golden from $n, commit $commit, checkpoint fingerprint $fp" `
        --labels "app=sql-ag-lab,kind=golden,source=$n,fp=$($fp.ToLower()),commit=$($commit.ToLower())"
    if ($LASTEXITCODE) { Die 'snapshot failed' }
    New-Item -ItemType Directory -Force -Path $StateDirGcp | Out-Null; Set-Content -LiteralPath $GoldenFile -Value $snap
    Add-LabNote "golden snapshot $snap of $n ($([int]$sw.Elapsed.TotalSeconds) s; fingerprint $fp, commit $commit); recorded as latest; $n is TERMINATED"
    Ok "golden snapshot $snap (latest). Spawn clones: ./lab.ps1 gcp spawn NAME"
}
function Invoke-Snapshots {
    Set-Ctx; Log "golden snapshots (latest: $(Get-LatestGolden))"
    Invoke-Gcloud compute snapshots list --project $script:Project --filter=labels.app=sql-ag-lab --sort-by=~creationTimestamp `
        "--format=table(name,creationTimestamp.date('%Y-%m-%d %H:%M'),diskSizeGb,storageBytes.size(units_out=G):label=STORED_GB,labels.kind,labels.source,labels.fp)"
}
function Set-UseSnapshot([string]$s) {
    Set-Ctx; if (-not $s) { Die 'usage: use-snapshot NAME' }
    Invoke-Gcloud compute snapshots describe $s --project $script:Project '--format=value(name)' | Out-Null; if ($LASTEXITCODE) { Die "no snapshot $s" }
    New-Item -ItemType Directory -Force -Path $StateDirGcp | Out-Null; Set-Content -LiteralPath $GoldenFile -Value $s; Ok "latest golden snapshot: $s"
}

# spawned.auto.tfvars.json: { "spawned": { NAME: {owner, source_snapshot, publisher, disk_type?, machine_type?} } }
function Get-SpawnedData { if (Test-Path (Get-SpawnedPath)) { Get-Content -LiteralPath (Get-SpawnedPath) -Raw | ConvertFrom-Json -AsHashtable } else { @{} } }
function Test-Spawned([string]$name) { $d = Get-SpawnedData; $d.ContainsKey('spawned') -and $d.spawned.ContainsKey($name) }
function Edit-Spawned([string]$Op, [string]$Name, [hashtable]$Entry) {
    $d = Get-SpawnedData; if (-not $d.ContainsKey('spawned')) { $d.spawned = [ordered]@{} }
    if ($Op -eq 'add') { $d.spawned[$Name] = $Entry } else { $d.spawned.Remove($Name) }
    [IO.File]::WriteAllText((Get-SpawnedPath), (($d | ConvertTo-Json -Depth 5) -replace "`r`n", "`n") + "`n", [Text.UTF8Encoding]::new($false))
}
function Invoke-Spawn([string[]]$a) {
    Set-Ctx; if (-not $a -or -not $a[0]) { Die 'usage: spawn NAME [--disk-type pd-ssd|pd-standard|pd-balanced] [--snapshot S] [--no-up]' }
    $name = $a[0]; $dtype = ''; $snap = ''; $mtype = ''; $up = $true
    $owner = if ($env:LAB_GCP_OWNER) { $env:LAB_GCP_OWNER } else { ([Environment]::UserName.ToLower() -replace '[^a-z0-9-]', '') }
    if ($owner.Length -gt 30) { $owner = $owner.Substring(0, 30) }
    for ($i = 1; $i -lt $a.Count; $i++) {
        switch ($a[$i]) { '--disk-type' { $dtype = $a[++$i] } '--snapshot' { $snap = $a[++$i] } '--machine-type' { $mtype = $a[++$i] } '--owner' { $owner = $a[++$i] } '--no-up' { $up = $false } default { Die "unknown option $($a[$i])" } }
    }
    if ($name -cnotmatch '^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$') { Die 'NAME must be a GCE name (lowercase letters, digits, hyphens)' }
    if ((Get-VmLines | Where-Object { $_[0] -eq $name -or $_[1] -eq $name }) -and -not (Test-Spawned $name)) { Die "$name is a VM from terraform.tfvars (vms); spawn only makes new clones" }
    if (-not $snap) { $snap = Get-LatestGolden }; if (-not $snap) { Die 'no golden snapshot: run ./lab.ps1 gcp finish VM (or use-snapshot NAME)' }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $e = [ordered]@{ owner = $owner; source_snapshot = $snap; publisher = $false }
    if ($dtype) { $e.disk_type = $dtype }; if ($mtype) { $e.machine_type = $mtype }
    Edit-Spawned add $name $e
    Add-LabNote "spawn $name from $snap (disk $(if ($dtype) { $dtype } else { 'pd-balanced default' }))"
    & terraform "-chdir=$TfVms" apply -auto-approve "-target=google_compute_instance.lab[`"$name`"]"
    if ($LASTEXITCODE) { Die "terraform apply failed (entry kept in $(Get-SpawnedPath); fix and rerun, or ./lab.ps1 gcp destroy $name)" }
    Update-TfOutputs
    $t1 = $sw.Elapsed.TotalSeconds; Wait-Ready $name; $t2 = $sw.Elapsed.TotalSeconds
    Ok ("$name created in {0:N0} s, SSH ready after {1:N0} s" -f $t1, ($t2 - $t1))
    Invoke-Check $name
    if (-not $up) { return }
    Invoke-Push $name
    Invoke-Rcmd $name "cd $RemoteDir && deploy/gcp/artifacts.sh key fetch"   # Secret Manager; must be the key in the snapshot
    Log 'first restore of golden (a disk from a snapshot loads blocks on first read: can take minutes)'
    Invoke-Rcmd $name "cd $RemoteDir && LAB_UP_TIMEOUT=1800 ./lab up golden && ./lab console >/dev/null && ./lab health --deep --wait 300"
    Add-LabNote ("spawn $name ready at golden (create {0:N0} s, SSH {1:N0} s, golden {2:N0} s)" -f $t1, ($t2 - $t1), ($sw.Elapsed.TotalSeconds - $t2))
    Ok "$name is at golden. Consoles: ./lab.ps1 gcp console $name   Remove: ./lab.ps1 gcp destroy $name"
}
function Invoke-DestroyVm([string]$name, [string]$flag) {
    if (-not (Test-Spawned $name)) { Die "$name was not made by ./lab.ps1 gcp spawn. VMs in terraform.tfvars (for example bill-1) are kept safe: remove them with ./lab.ps1 gcp delete KEY" }
    if ($flag -ne '--yes') {
        $a = Read-Host "Delete VM $name and its disk (data on it is lost; snapshots stay)? Type the name to confirm"
        if ($a -ne $name) { Die 'not confirmed' }
    }
    & terraform "-chdir=$TfVms" destroy -auto-approve "-target=google_compute_instance.lab[`"$name`"]"; if ($LASTEXITCODE) { Die 'terraform destroy failed' }
    Edit-Spawned del $name; Update-TfOutputs; Add-LabNote "destroyed spawned VM $name (and its boot disk)"; Ok "$name deleted"
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
    function Arg1([string]$what = 'VM required') { if (-not $a.Count -or -not $a[0]) { Die $what }; $a[0] }
    function Rest1 { if ($a.Count -gt 1) { , [string[]]$a[1..($a.Count - 1)] } else { , [string[]]@() } }
    switch ($c) {
        { $_ -in 'help', '-h', '--help' } { Show-Usage }
        'destroy' { if (-not $a.Count -or $a[0] -in 'shared', 'vms') { Invoke-TfCmd destroy $(if ($a.Count) { $a[0] } else { 'vms' }) } else { Set-Ctx; Invoke-DestroyVm $a[0] $(if ($a.Count -gt 1) { $a[1] } else { '' }) } }
        { $_ -in 'init', 'plan' } {
            $root = 'vms'; $x = @(); foreach ($v in $a) { if ($v -in 'shared', 'vms') { $root = $v } else { $x += $v } }
            Invoke-TfCmd $c $root $x
        }
        'apply' {
            $root = 'vms'; $x = @()
            foreach ($v in $a) { switch ($v) { { $_ -in 'shared', 'vms' } { $root = $v } { $_ -in '-y', '--yes', '-auto-approve' } { $x += '-auto-approve' } default { $x += $v } } }
            Invoke-TfCmd apply $root $x
        }
        'test' { Invoke-Test (Arg1) }
        'golden' { Invoke-Golden (Arg1) $(if ($a.Count -gt 1) { $a[1] } else { '' }) }
        'finish' { Invoke-Test (Arg1); Invoke-Golden $a[0] $(if ($a.Count -gt 1) { $a[1] } else { '' }) }
        'spawn' { Invoke-Spawn $a }
        'key' { Invoke-Key $a }
        'snapshots' { Invoke-Snapshots }
        'use-snapshot' { Set-UseSnapshot $(if ($a.Count) { $a[0] } else { '' }) }
        'tf-check' { Invoke-TfCheck }
        'tools' { Test-Tools }
        'create' { Invoke-Create $(if ($a.Count) { $a[0] } else { '' }) (Rest1) }
        'delete' { Invoke-Delete $(if ($a.Count) { $a[0] } else { '' }) (Rest1) }
        'list' { Invoke-List }
        { $_ -in 'start', 'stop' } { Set-Ctx; Invoke-Gcloud compute instances $c (Get-VmName (Arg1)) --project $script:Project --zone $script:Zone; if ($LASTEXITCODE) { Die "$c failed" } }
        'ssh' { Set-Ctx; $n = Get-VmName (Arg1); if ($a.Count -gt 1) { Invoke-Rcmd $n ((Rest1) -join ' ') } else { Invoke-Gssh $n @() } }
        'check' { Invoke-Check (Arg1) }
        'push' { Invoke-Push (Arg1) }
        'deploy' { Invoke-Deploy (Arg1) (Rest1) }
        'watch' { Invoke-Watch (Arg1) }
        'tunnel' { Invoke-Tunnel (Arg1) (Rest1) }
        'console' { Invoke-Tunnel (Arg1) ([string[]](Rest1) + '--open') }
        'image' { Invoke-Image (Arg1) $(if ($a.Count -gt 1) { $a[1] } else { '' }) }
        'snapshot' { Invoke-Snapshot (Arg1) $(if ($a.Count -gt 1) { $a[1] } else { '' }) }
        'artifacts' { Set-Ctx; Invoke-Rcmd (Get-VmName (Arg1)) "cd $RemoteDir && deploy/gcp/artifacts.sh status" }
        'watch-term' { Set-Ctx; Open-WatchGcp (Arg1) -Force }
        'publish' { Set-Ctx; $n = Get-VmName (Arg1); Open-WatchGcp $a[0]; Invoke-Rcmd $n "cd $RemoteDir && deploy/gcp/artifacts.sh publish $((Rest1) -join ' ')" }
        'fetch' { Set-Ctx; $n = Get-VmName (Arg1); Invoke-Rcmd $n "cd $RemoteDir && deploy/gcp/artifacts.sh fetch $((Rest1) -join ' ')" }
        'cost' { Show-Cost }
        default { Show-Usage; Die "unknown command: $c" }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    # dot-sourcing (Pester) loads the functions only
    try { Invoke-LabGcp -Argv ([string[]]$args); exit 0 }
    catch {
        [Console]::Error.WriteLine("  error $($_.Exception.Message)")
        if ($_.Exception.GetType().Name -ne 'LabError') { [Console]::Error.WriteLine($_.ScriptStackTrace) }
        exit 1
    }
}
