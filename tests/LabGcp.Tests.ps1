# Pester 5+ tests for the PowerShell operator front end (no GCP access, no credentials).
BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    # Never touch the real terraform files: every test uses a registry file in TestDrive.
    $env:LAB_GCP_SPAWNED_JSON = Join-Path $TestDrive 'spawned.auto.tfvars.json'
    $env:PROGRESS_LOG = Join-Path $TestDrive 'progress.log'   # never write test lines to the real logs/progress.log
    . (Join-Path $script:Repo 'deploy/gcp/lab-gcp.ps1')
}
AfterAll { Remove-Item Env:LAB_GCP_SPAWNED_JSON, Env:PROGRESS_LOG -ErrorAction SilentlyContinue }

Describe 'VM names' {
    BeforeEach {
        Mock Get-TfOut { param($name) if ($name -eq 'vm_lines') { "bill-1 sqlag-bill-1 n2-standard-16 Intel_Ice_Lake`nann-2 custom-name n2-standard-16 Intel_Ice_Lake" } else { '' } }
        Mock Test-Spawned { param($name) $name -eq 'bill-t1' }
        $script:Prefix = 'sqlag'
    }
    It 'maps a tfvars key to its GCE name' { Get-VmName 'bill-1' | Should -Be 'sqlag-bill-1' }
    It 'maps a key with name = "..."' { Get-VmName 'ann-2' | Should -Be 'custom-name' }
    It 'keeps a full name' { Get-VmName 'sqlag-x-9' | Should -Be 'sqlag-x-9' }
    It 'keeps a spawned name' { Get-VmName 'bill-t1' | Should -Be 'bill-t1' }
    It 'adds the prefix to an unknown key' { Get-VmName 'zed-3' | Should -Be 'sqlag-zed-3' }
    It 'parses vm_lines with the CPU platform' { (Get-VmLines)[0][3] -replace '_', ' ' | Should -Be 'Intel Ice Lake' }
}

Describe 'remote commands' {
    It 'sends the command base64-encoded with LF line ends' {
        $script:sent = $null
        Mock Invoke-Gssh { param($Extra) $script:sent = $Extra; $global:LASTEXITCODE = 0 }
        Invoke-Rcmd 'vm' "cd x && echo `"a|b`" > `$HOME/f`r`nls"
        $script:sent.Count | Should -Be 1
        $b64 = [regex]::Match($script:sent[0], 'echo (\S+) \| base64 -d').Groups[1].Value
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) | Should -Be "cd x && echo `"a|b`" > `$HOME/f`nls"
        $script:sent[0] | Should -Not -Match '"'
    }
    It 'fails on a non-zero exit' {
        Mock Invoke-Gssh { $global:LASTEXITCODE = 3 }
        { Invoke-Rcmd 'vm' 'false' } | Should -Throw '*exit 3*'
    }
    It 'returns $null from Get-Rcmd on failure' {
        Mock Invoke-Gssh { $global:LASTEXITCODE = 1 }
        Get-Rcmd 'vm' 'false' | Should -BeNullOrEmpty
    }
}

Describe 'apply flags' {
    It 'maps --yes to -auto-approve and keeps the root' {
        Mock Invoke-TfCmd { param($Action, $Root, $Extra) $script:tf = @($Action, $Root) + $Extra }
        Invoke-LabGcp -Argv @('apply', 'shared', '--yes')
        $script:tf | Should -Be @('apply', 'shared', '-auto-approve')
    }
    It 'defaults to the vms root' {
        Mock Invoke-TfCmd { param($Action, $Root, $Extra) $script:tf = @($Action, $Root) + $Extra }
        Invoke-LabGcp -Argv @('apply')
        $script:tf | Should -Be @('apply', 'vms')
    }
    It 'rejects an unknown command' { { Invoke-LabGcp -Argv @('nonsense') 6>$null } | Should -Throw '*unknown command*' }
    It 'passes console options to tunnel and adds --open' {
        Mock Invoke-Tunnel { param($key, $Rest) $script:tun = @($key) + $Rest }
        Invoke-LabGcp -Argv @('console', 'bill-1', '--offset', '20000')
        $script:tun | Should -Be @('bill-1', '--offset', '20000', '--open')
    }
    It 'needs a VM for check' { { Invoke-LabGcp -Argv @('check') } | Should -Throw '*VM required*' }
}

Describe 'spawned VM registry' {
    BeforeEach { $env:LAB_GCP_SPAWNED_JSON = Join-Path $TestDrive 'spawned.auto.tfvars.json' }
    It 'adds, finds and removes an entry; writes LF JSON' {
        Edit-Spawned add 'bill-t9' ([ordered]@{ owner = 'bill'; source_snapshot = 's1'; publisher = $false })
        Test-Spawned 'bill-t9' | Should -BeTrue
        (Get-Content $env:LAB_GCP_SPAWNED_JSON -Raw | ConvertFrom-Json).spawned.'bill-t9'.source_snapshot | Should -Be 's1'
        [IO.File]::ReadAllText($env:LAB_GCP_SPAWNED_JSON) | Should -Not -Match "`r"
        Edit-Spawned del 'bill-t9'
        Test-Spawned 'bill-t9' | Should -BeFalse
    }
}

Describe 'helpers' {
    It 'converts CRLF to LF for files copied to the VM' {
        $src = Join-Path $TestDrive 'a.sh'; $dst = Join-Path $TestDrive 'b.sh'
        [IO.File]::WriteAllText($src, "#!/bin/bash`r`necho hi`r`n")
        ConvertTo-LfFile $src $dst
        [IO.File]::ReadAllText($dst) | Should -Be "#!/bin/bash`necho hi`n"
    }
    It 'labels Pacific time PT, else a UTC offset' { Get-LabZoneLabel | Should -Match '^(PT|UTC[+-]\d\d:\d\d)$' }
    It 'derives the region from the zone' { $script:Zone = 'us-central1-a'; Get-Region | Should -Be 'us-central1' }
    It 'sees a listening local port' {
        $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $l.Start()
        try { Test-LocalPort $l.LocalEndpoint.Port | Should -BeTrue } finally { $l.Stop() }
    }
    It 'refuses to destroy a VM that spawn did not make' {
        Mock Test-Spawned { $false }
        { Invoke-DestroyVm 'sqlag-bill-1' '--yes' } | Should -Throw '*not made by*'
    }
}

Describe 'watch terminal script' {
    It 'generates a gcp watch script that parses' {
        Mock Open-LabWatch { param($Body) $script:body = $Body }
        Open-WatchGcp 'bill-1'
        $e = $null; [void][Management.Automation.Language.Parser]::ParseInput($script:body, [ref]$null, [ref]$e)
        $e | Should -BeNullOrEmpty
        $script:body | Should -Match 'Get-Content -LiteralPath TRANSCRIPT.md -Tail 40 -Wait'
    }
}

Describe 'repository line endings' {
    It 'checks out scripts for Linux with LF' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $attr = git -C $script:Repo check-attr eol -- lab deploy/gcp/remote-deploy.sh deploy/gcp/vm-check.sh lib/common.sh
        $attr | ForEach-Object { $_ | Should -Match 'eol: lf$' }
    }
}
