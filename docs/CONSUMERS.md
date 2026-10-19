# Consumer interface: using the lab from other repositories

Other repositories (Ansible, DSC, PowerShell, Terraform, test suites) can test their automation
against this lab without copying it. They depend on a small, versioned command-line contract:
the **consumer interface**. This page is the contract.

## 1. Overview

```text
 dependent repo (for example an Ansible repo)              this repo (the lab), at LAB_HOME
 ------------------------------------------------           ---------------------------------
 lab.lock: LAB_REPO, LAB_REF (tag or commit), LAB_CONTRACT
 bootstrap:  $LAB_HOME/lab version --json   -------------->  version + contract check
             $LAB_HOME/lab status --json    -------------->  running? healthy? checkpoint?
             $LAB_HOME/lab inventory ...    -------------->  hosts, IPs, AG, listener, roles
 fixtures:   $LAB_HOME/lab reset golden     -------------->  sub-minute known state
 payloads:   $LAB_HOME/lab media fetch/iso/attach -------->  shared cache, ISO in the VMs' CD drive
 run:        control container on Docker networks lab_a + lab_b --(WinRM 5985 / SSH / SQL 1433)--> VMs
```

The lab stays the single owner of the VMs. A dependent repo never edits lab files, never reads
`lab.env` directly, and never hardcodes IPs or names: it asks the lab.

## 2. Versions and compatibility

| Item | Where | Meaning |
|---|---|---|
| Lab version | `VERSION` (semver) | Release of the lab. |
| Contract version | `CONTRACT` (`MAJOR.MINOR`) | Version of this interface. |
| Commit | `lab version --json` | The exact lab code. |

Rules:

- **Minor** contract change: additions only (a new field, a new command, a new option). Old
  consumers keep working.
- **Major** contract change: something was removed or changed meaning. A consumer that needs
  contract `1.x` refuses a lab with contract `2.0`.
- A consumer is compatible when the lab contract has the **same major** and an **equal or higher
  minor** than the contract the consumer needs.

### Recommended: release tags

Publish lab releases as semver tags (`v1.0.0`, `v1.1.0`, ...), with the contract version in the
release notes. Consumers then pin a tag instead of a commit. This repository does not create tags
automatically. Proposal for the first tag: `v1.0.0` (contract `1.0`) when this interface is merged.

## 3. Discovery: LAB_HOME

A consumer finds the lab install in this order:

1. `LAB_HOME`: the directory that contains `lab` (an existing, built lab). Recommended.
2. Otherwise, a clone of `LAB_REPO` at `LAB_REF` in a cache directory (for example
   `~/.cache/<consumer>/lab`). A fresh clone has no VM images: build it with its `MAKE.md` first.

Then the consumer checks compatibility and health:

```bash
"$LAB_HOME/lab" version --json   # {"name":"sql-ag-lab","version":"1.0.0","contract":"1.0","commit":"...","dirty":false}
"$LAB_HOME/lab" status --json    # "state":"running" and "healthy":true before a test
```

## 4. Commands

Exit codes for all consumer commands: `0` success, `1` failure, `2` usage error. Machine-readable
output goes to stdout; messages go to stderr.

| Command | Output | Notes |
|---|---|---|
| `lab version [--json]` | Version, contract, commit | No running lab needed. |
| `lab status --json` | `state`, `checkpoint`, `healthy`, `health`, `checkpoints`, `vms[]` | Exit 0 when it can report, also for a stopped lab. Check `healthy`. |
| `lab inventory [--format json\|ansible]` | Topology (section 5) | No running lab needed. No secrets. |
| `lab reset [CHECKPOINT]` | Messages | Default `golden`. Exit 0 only when the lab is back and the TCP health check passes. A missing checkpoint fails before the running lab is touched. |
| `lab health [--deep] [--wait S]` | Messages | Exit 0 when healthy. `--deep` checks cluster, AG and listener in the guests. |
| `lab password [--show]` | The lab password | For scripts: `LAB_PASSWORD=$(lab password)`. Refuses a terminal without `--show`. |
| `lab media ...` | Paths on stdout | Section 7. |

`lab.ps1` (PowerShell 7) has `version` and `inventory` with the same output on every platform. On
a Linux lab host it forwards the engine commands (`status`, `reset`, `media`, `password`, ...) to
`./lab`.

## 5. Inventory

`lab inventory` (JSON) contains:

- `contract`, `lab.version`
- `domain`: `fqdn`, `netbios`, `dc`
- `credentials`: `windows_user` (`LAB\Administrator`), `sql_user` (`sa`), `password_env`
  (`LAB_PASSWORD`), `password_command` (`lab password`). Never the password.
- `access`: WinRM (`http`, `5985`, `ntlm`) and SSH (`22`)
- `networks[]`: Docker networks `lab_a` and `lab_b` with subnet, host gateway, router
- `hosts[]`: `name`, `fqdn`, `ip`, `network`, `roles`, `ports`, and for SQL replicas
  `sql.instance`, `sql.availability_mode`, `sql.failover_mode` (from `LAB_AG_MODES`)
- `cluster`: `name`, `ips`
- `ag`: `name`, `database`, `preferred_primary` (first replica in `LAB_AG_MODES`; every checkpoint
  is saved with it as primary), `listener` (`name`, `fqdn`, `ips`, `port`)
- `media`: `dir`, `cache`

`lab inventory --format ansible` writes the same data as an Ansible YAML inventory: groups
`lab_dc`, `lab_sql`, `lab_ag_sync`, `lab_ag_async`; host vars `ansible_host`,
`lab_ag_availability_mode`, `lab_ag_failover_mode`; WinRM/NTLM connection vars; and
`lab_password: "{{ lookup('ansible.builtin.env', 'LAB_PASSWORD') }}"`. Override `lab_password`
in your own `group_vars` to read it from another source (for example a secret file).

> **NOTE:** The modes in the inventory are the *configured* (desired) modes. The current primary
> and the current modes can differ after a failover: query the AG when it matters.

## 6. Reaching the VMs

The VMs have their IPs on two Docker bridge networks: `lab_a` (10.50.0.0/24) and `lab_b`
(10.51.0.0/24). The lab host can reach them directly.

Recommended for a control container: **join both Docker networks** (`external: true` in Compose).
This adds no published ports and no new listener. The container gets an address from the small
dynamic range (`.224/28`) that no VM uses.

```yaml
services:
  control:
    networks: [lab_a, lab_b]
networks:
  lab_a: { external: true, name: lab_a }
  lab_b: { external: true, name: lab_b }
```

Protocols in the guests (already enabled in every image, no guest change needed):

- **WinRM** HTTP 5985 (default Windows Server listener, firewall open for the domain profile).
  Use NTLM with message encryption (pywinrm `auto`). Kerberos from the host does not work in the
  default `LAB_TIME_MODE=frozen` (clock skew).
- **SSH** 22 (OpenSSH, PowerShell; key `secrets/id_ed25519` of the lab, used by `lab ssh`).
- **SQL Server** 1433 on every replica and on the listener. SQL authentication (`sa`) or Windows
  authentication.

> **CAUTION:** Do not publish the WinRM or SQL ports on the host network. The lab uses one
> plain-text, lab-only password.

## 7. Shared media cache

Payloads that consumers need in the VMs (cumulative updates, installers, modules) are downloaded
**once** into the lab's media cache (`$LAB_MEDIA_DIR/cache`, default `media/cache`, gitignored)
and shared by every consumer. The VMs are air-gapped (`LAB_INTERNET=0`), so the cache is also the
way in:

```bash
lab media fetch URL --sha256 HEX [--name FILE]   # download once; checksum verified; prints the path
lab media iso NAME.iso FILE...                   # ISO 9660 + Joliet image of cache files (tools image)
lab media attach NAME.iso SQL1 SQL2 | sql | all  # insert the ISO into the VMs' CD drives
lab media eject sql | all
lab media list | dir
```

- `fetch` is idempotent: a file that exists with the right SHA-256 is not downloaded again.
  `gs://` URLs use `gcloud storage cp` (GCP lab hosts; not tested yet).
- `attach` changes the medium of the VM's existing CD drive through QMP. The VM sees a new drive
  letter (D: on the SQL VMs) within seconds. Nothing goes over the network, no listener is
  opened, and the checkpoint device layout does not change. The ISO stays in the drive across
  guest reboots, until the next `lab reset`, `up` or `down`. `lab save` ejects it.
- `iso` uses the small tools image `sql-ag-lab/tools` (`tools/Dockerfile`, built on first use).

GCP: put shared payloads in the artifacts bucket under `media/cache/` and fetch them on the lab
host with `lab media fetch gs://BUCKET/sql-ag-lab/media/cache/FILE --sha256 HEX`.

## 8. Checkpoints as test fixtures

| Checkpoint | State |
|---|---|
| `sql-standalone` | Domain + four standalone SQL Server instances |
| `cluster` | + two-subnet WSFC, HADR enabled, no AG |
| `golden` | + AG with four replicas and the listener |

A test starts from a known state and ends there:

```bash
"$LAB_HOME/lab" reset golden        # < 1 min; exit code 0 = up and healthy
# ... run the automation and the assertions ...
"$LAB_HOME/lab" reset golden        # leave the lab clean for the next consumer
```

A consumer can also save its own fixture (`lab save NAME`, then `lab reset NAME`). Use a
prefixed name (for example `ansible-cu9`) and delete it when done (`lab delete NAME`).

## 9. Example: the Ansible consumer

A separate repository tests a desired-state SQL Server CU patch with Ansible. Its flow:

1. `lab.lock` pins `LAB_REF` and needs `LAB_CONTRACT=1.0`.
2. Bootstrap: `version --json` (contract), `status --json` (healthy), `inventory --format ansible`.
3. Media: `lab media fetch` (CU + module), `lab media iso`, `lab media attach ... sql`.
4. An Ansible control container joins `lab_a` and `lab_b` and reads the password from a
   Compose secret file (`LAB_PASSWORD=$(lab password)` on the host).
5. Tests: `lab reset golden`, patch, verify, rerun (changed=0), partial state, `lab reset golden`.
