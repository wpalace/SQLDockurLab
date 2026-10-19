# Consumer interface of the lab in PowerShell 7 (docs/CONSUMERS.md): version and inventory.
# Same output as ./lab version --json and ./lab inventory (tests/LabConsumer.Tests.ps1 compares
# them). Both read only lab.env and lab.local.env, so they also work on Windows without the lab.
Set-StrictMode -Version Latest
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'LabHost.psm1') -DisableNameChecking

$script:VmNames = @('DC1', 'SQL1', 'SQL2', 'SQL3', 'SQL4')
$script:SqlNames = @('SQL1', 'SQL2', 'SQL3', 'SQL4')

function Get-LabFileValue([string]$Name) {
    $p = Join-Path -Path (Get-LabRoot) -ChildPath $Name
    if (Test-Path -LiteralPath $p) { (Get-Content -LiteralPath $p -Raw).Trim() } else { $null }
}

<#
.SYNOPSIS
    Returns the consumer interface contract version (MAJOR.MINOR) from the CONTRACT file.
#>
function Get-LabContractVersion { Get-LabFileValue 'CONTRACT' }

<#
.SYNOPSIS
    Returns the lab name, version, contract, commit and dirty flag (same fields as ./lab version --json).
#>
function Get-LabVersionInfo {
    $root = Get-LabRoot
    $version = Get-LabFileValue 'VERSION'
    if (-not $version) { $version = '0.0.0' }
    $commit = 'unknown'
    $dirty = $false
    if (Get-Command -Name git -ErrorAction SilentlyContinue) {
        $c = & git -C $root rev-parse --short=12 HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $c) { $commit = [string]$c }
        $s = & git -C $root status --porcelain --untracked-files=no 2>$null
        $dirty = [bool]$s
    }
    [ordered]@{
        name = 'sql-ag-lab'; version = $version; contract = (Get-LabContractVersion)
        commit = $commit; dirty = $dirty
    }
}

function Get-LabConfigValue([string]$Name) {
    $v = Get-LabEnvValue $Name
    if ($null -eq $v) { throw "lab.env has no $Name" }
    $v
}

function Get-LabReplicaMode([string]$Vm) {
    # @(availability mode, failover mode) from LAB_AG_MODES
    foreach ($entry in (Get-LabConfigValue 'LAB_AG_MODES') -split '\s+') {
        $parts = $entry -split ':'
        if ($parts.Count -eq 3 -and $parts[0] -eq $Vm) { return , @($parts[1], $parts[2]) }
    }
    , @($null, $null)
}

function Get-LabPreferredPrimary { (((Get-LabConfigValue 'LAB_AG_MODES') -split '\s+')[0] -split ':')[0] }

function Get-LabVmNetwork([string]$Vm) {
    $ip = Get-LabConfigValue "${Vm}_IP"
    $hostA = Get-LabConfigValue 'LAB_NET_A_HOST'
    $prefix = $ip.Substring(0, $ip.LastIndexOf('.'))
    if ($prefix -eq $hostA.Substring(0, $hostA.LastIndexOf('.'))) { 'lab_a' } else { 'lab_b' }
}

function Resolve-LabPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return $Path }
    $rel = $Path -replace '^\./', ''
    (Get-LabRoot).TrimEnd('/', '\') + '/' + $rel
}

<#
.SYNOPSIS
    Returns the lab topology as an ordered dictionary (same data as ./lab inventory --format json).
    It never contains the password.
#>
function Get-LabInventory {
    $domain = Get-LabConfigValue 'LAB_DOMAIN'
    $netbios = Get-LabConfigValue 'LAB_NETBIOS'
    $hosts = foreach ($vm in $script:VmNames) {
        $h = [ordered]@{
            name = $vm; fqdn = "$vm.$domain"; ip = (Get-LabConfigValue "${vm}_IP")
            network = (Get-LabVmNetwork $vm)
        }
        if ($vm -eq 'DC1') {
            $h.roles = @('domain_controller')
            $h.ports = [ordered]@{ ssh = 22; winrm = 5985; ldap = 389 }
        } else {
            $modes = Get-LabReplicaMode $vm
            $h.roles = @('sql', 'ag_replica')
            $h.ports = [ordered]@{ ssh = 22; winrm = 5985; sql = 1433 }
            $h.sql = [ordered]@{
                instance = 'MSSQLSERVER'; availability_mode = $modes[0]; failover_mode = $modes[1]
            }
        }
        $h
    }
    $networks = foreach ($n in 'A', 'B') {
        [ordered]@{
            name = "lab_$($n.ToLower())"; subnet = (Get-LabConfigValue "LAB_NET_$n")
            host = (Get-LabConfigValue "LAB_NET_${n}_HOST"); router = (Get-LabConfigValue "LAB_NET_${n}_ROUTER")
        }
    }
    $media = Resolve-LabPath (Get-LabConfigValue 'LAB_MEDIA_DIR')
    $cache = Get-LabEnvValue 'LAB_MEDIA_CACHE_DIR'
    if (-not $cache) { $cache = "$media/cache" }
    $listener = Get-LabConfigValue 'LAB_LISTENER_NAME'
    [ordered]@{
        contract    = (Get-LabContractVersion)
        lab         = [ordered]@{ name = 'sql-ag-lab'; version = (Get-LabVersionInfo).version }
        domain      = [ordered]@{ fqdn = $domain; netbios = $netbios; dc = 'DC1' }
        credentials = [ordered]@{
            windows_user = "$netbios\Administrator"; sql_user = 'sa'; password_env = 'LAB_PASSWORD'
            password_command = 'lab password'
        }
        access      = [ordered]@{
            winrm = [ordered]@{ scheme = 'http'; port = 5985; transport = 'ntlm' }; ssh = [ordered]@{ port = 22 }
        }
        networks    = @($networks)
        hosts       = @($hosts)
        cluster     = [ordered]@{
            name = (Get-LabConfigValue 'LAB_CLUSTER_NAME')
            ips  = @((Get-LabConfigValue 'LAB_CLUSTER_IP_A'), (Get-LabConfigValue 'LAB_CLUSTER_IP_B'))
        }
        ag          = [ordered]@{
            name = (Get-LabConfigValue 'LAB_AG_NAME'); database = (Get-LabConfigValue 'LAB_AG_DATABASE')
            preferred_primary = (Get-LabPreferredPrimary)
            listener          = [ordered]@{
                name = $listener; fqdn = "$listener.$domain"
                ips  = @((Get-LabConfigValue 'LAB_LISTENER_IP_A'), (Get-LabConfigValue 'LAB_LISTENER_IP_B'))
                port = [int](Get-LabConfigValue 'LAB_LISTENER_PORT')
            }
        }
        media       = [ordered]@{ dir = $media; cache = $cache }
    }
}

<#
.SYNOPSIS
    Converts Get-LabInventory output to an Ansible YAML inventory (same text as
    ./lab inventory --format ansible).
#>
function ConvertTo-LabAnsibleInventory {
    param([Parameter(Mandatory = $true)] $Inventory)
    $i = $Inventory
    $l = $i.ag.listener
    $out = [Collections.Generic.List[string]]::new()
    $out.Add('---')
    $out.Add("# Generated by sql-ag-lab: ./lab inventory --format ansible (contract $($i.contract)).")
    $out.Add('# Contains no secrets: lab_password reads the LAB_PASSWORD environment variable by default.')
    $out.Add('all:')
    $out.Add('  vars:')
    $out.Add("    lab_contract: `"$($i.contract)`"")
    $out.Add("    lab_version: `"$($i.lab.version)`"")
    $out.Add("    lab_domain: $($i.domain.fqdn)")
    $out.Add("    lab_netbios: $($i.domain.netbios)")
    $out.Add('    lab_dc: DC1')
    $out.Add("    lab_cluster_name: $($i.cluster.name)")
    $out.Add("    lab_ag_name: $($i.ag.name)")
    $out.Add("    lab_ag_database: $($i.ag.database)")
    $out.Add("    lab_ag_preferred_primary: $($i.ag.preferred_primary)")
    $out.Add("    lab_listener_name: $($l.name)")
    $out.Add("    lab_listener_fqdn: $($l.fqdn)")
    $out.Add("    lab_listener_ips: [$($l.ips -join ', ')]")
    $out.Add("    lab_listener_port: $($l.port)")
    $out.Add('    lab_docker_networks: [lab_a, lab_b]')
    $out.Add("    lab_password: `"{{ lookup('ansible.builtin.env', 'LAB_PASSWORD') }}`"")
    $out.Add('    ansible_connection: winrm')
    $out.Add('    ansible_port: 5985')
    $out.Add('    ansible_winrm_scheme: http')
    $out.Add('    ansible_winrm_transport: ntlm')
    $out.Add("    ansible_user: '$($i.credentials.windows_user)'")
    $out.Add('    ansible_password: "{{ lab_password }}"')
    $out.Add('  children:')
    $dc = $i.hosts | Where-Object { $_.name -eq 'DC1' }
    $out.Add('    lab_dc:')
    $out.Add('      hosts:')
    $out.Add('        DC1:')
    $out.Add("          ansible_host: $($dc.ip)")
    $out.Add("          lab_fqdn: $($dc.fqdn)")
    $out.Add("          lab_network: $($dc.network)")
    $out.Add('    lab_sql:')
    $out.Add('      hosts:')
    $sql = @($i.hosts | Where-Object { $_.name -ne 'DC1' })
    foreach ($h in $sql) {
        $out.Add("        $($h.name):")
        $out.Add("          ansible_host: $($h.ip)")
        $out.Add("          lab_fqdn: $($h.fqdn)")
        $out.Add("          lab_network: $($h.network)")
        $out.Add("          lab_sql_instance: $($h.sql.instance)")
        $out.Add("          lab_ag_availability_mode: $($h.sql.availability_mode)")
        $out.Add("          lab_ag_failover_mode: $($h.sql.failover_mode)")
    }
    foreach ($g in @(@('sync', 'SYNCHRONOUS_COMMIT'), @('async', 'ASYNCHRONOUS_COMMIT'))) {
        $out.Add("    lab_ag_$($g[0]):")
        $out.Add('      hosts:')
        foreach ($h in $sql) { if ($h.sql.availability_mode -eq $g[1]) { $out.Add("        $($h.name): {}") } }
    }
    ($out -join "`n") + "`n"
}

Export-ModuleMember -Function Get-LabContractVersion, Get-LabVersionInfo, Get-LabInventory,
ConvertTo-LabAnsibleInventory
