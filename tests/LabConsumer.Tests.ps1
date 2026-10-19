# Pester 5+ tests for the consumer interface (lib/LabConsumer.psm1, lab.ps1 version/inventory).
# No lab VMs needed: both front ends read only lab.env, lab.local.env, VERSION and CONTRACT.
BeforeDiscovery {
    $script:HasBash = (-not $IsWindows) -and [bool](Get-Command -Name bash -ErrorAction SilentlyContinue)
}
BeforeAll {
    $script:Repo = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..')).Path
    Import-Module -Name (Join-Path -Path $script:Repo -ChildPath 'lib/LabHost.psm1') -Force -DisableNameChecking
    $consumerModule = Join-Path -Path $script:Repo -ChildPath 'lib/LabConsumer.psm1'
    Import-Module -Name $consumerModule -Force -DisableNameChecking
    $script:LabPs1 = Join-Path -Path $script:Repo -ChildPath 'lab.ps1'
    $script:LabSh = Join-Path -Path $script:Repo -ChildPath 'lab'
}

Describe 'contract and version' {
    It 'reads the contract version as MAJOR.MINOR' {
        Get-LabContractVersion | Should -Match '^\d+\.\d+$'
    }
    It 'reports version, contract and commit as JSON' {
        $v = & pwsh -NoProfile -File $script:LabPs1 version --json | ConvertFrom-Json
        $v.name | Should -Be 'sql-ag-lab'
        $v.version | Should -Match '^\d+\.\d+\.\d+'
        $v.contract | Should -Be (Get-LabContractVersion)
    }
}

Describe 'inventory' {
    BeforeAll { $script:Inv = Get-LabInventory }
    It 'lists DC1 and four SQL replicas' {
        $script:Inv.hosts.name | Should -Be @('DC1', 'SQL1', 'SQL2', 'SQL3', 'SQL4')
    }
    It 'gives every SQL replica an availability and a failover mode' {
        foreach ($h in $script:Inv.hosts | Where-Object { $_.name -ne 'DC1' }) {
            $h.sql.availability_mode | Should -BeIn @('SYNCHRONOUS_COMMIT', 'ASYNCHRONOUS_COMMIT')
            $h.sql.failover_mode | Should -BeIn @('AUTOMATIC', 'MANUAL')
        }
    }
    It 'names the listener and the preferred primary' {
        $script:Inv.ag.listener.ips.Count | Should -Be 2
        $script:Inv.ag.preferred_primary | Should -BeIn @('SQL1', 'SQL2', 'SQL3', 'SQL4')
    }
    It 'contains no password' {
        $json = $script:Inv | ConvertTo-Json -Depth 10
        $pw = Get-LabEnvValue 'LAB_PASSWORD'
        if ($pw) { $json | Should -Not -Match ([regex]::Escape($pw)) }
        $json | Should -Not -Match '"password"\s*:'
    }
    It 'makes an Ansible inventory with the replica groups' {
        $yaml = ConvertTo-LabAnsibleInventory -Inventory $script:Inv
        $yaml | Should -Match '(?m)^    lab_ag_sync:$'
        $yaml | Should -Match '(?m)^    lab_ag_async:$'
        $yaml | Should -Match "lookup\('ansible.builtin.env', 'LAB_PASSWORD'\)"
    }
}

Describe 'bash and PowerShell front ends agree' -Skip:(-not $script:HasBash) {
    It 'prints the same <Command>' -ForEach @(
        @{ Command = 'version --json'; CliArgs = @('version', '--json') }
        @{ Command = 'inventory --format json'; CliArgs = @('inventory', '--format', 'json') }
        @{ Command = 'inventory --format ansible'; CliArgs = @('inventory', '--format', 'ansible') }
    ) {
        $fromBash = (& bash $script:LabSh @CliArgs) -join "`n"
        $fromPwsh = (& pwsh -NoProfile -File $script:LabPs1 @CliArgs) -join "`n"
        $fromPwsh | Should -BeExactly $fromBash
    }
}
