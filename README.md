# sql-ag-lab

A repeatable local lab for SQL Server automation testing. It runs **1 domain controller and a
4-node SQL Server 2025 Always On AG on Windows Server 2025 Core, spread over two routed
subnets**, with a multi-subnet listener. You can reach every node and the listener directly
from the host. It is built once (slow). After that you **reset it to a known state in seconds**
by restoring full memory-state checkpoints of all 5 VMs at the same moment.

```
host (Linux, KVM, Docker)
 ├─ labbr-a 10.50.0.0/24 (host .1) ── DC1 .10 · SQL1 .11 · SQL2 .12 · cluster .50 · listener .60 · router .254
 └─ labbr-b 10.51.0.0/24 (host .1) ── SQL3 .13 · SQL4 .14 ·            cluster .50 · listener .60 · router .254
          router container routes between subnets (optional netem WAN delay)
```

## Host prerequisites

| Requirement | Check |
|---|---|
| Linux, x86-64, CPU virtualization enabled | `grep -Ec '(vmx|svm)' /proc/cpuinfo` > 0 and `/dev/kvm` exists |
| Docker Engine (native, not a snap) | `docker info` |
| Docker Compose v2 | `docker compose version` |
| User in groups `docker` and `kvm` | `id -nG` lists both (log out and in after adding) |
| `tun` (required), `vhost_net` (optional) | `/dev/net/tun`, `/dev/vhost-net` exist (`sudo modprobe tun vhost_net`) |
| OpenSSH client, curl, coreutils (`sha256sum`, `base64`, `timeout`), iconv, iproute2 | `./lab doctor` |
| xdg-open (optional, for `./lab vnc`) | `command -v xdg-open` |
| 32 GB RAM, 120 GB free disk (NVMe) | `./lab doctor` |

QEMU is not needed on the host; it runs inside the lab containers. `./lab doctor` checks all of
the above. Tested hosts so far: one Linux workstation with Docker 29 and KVM, and one CI-style box
with TCG emulation; other distributions are expected to work but are untested.

## Quickstart

```bash
# host: Linux with KVM (nested virt if it is itself a VM), Docker + compose v2, ~120 GB NVMe, 32 GB RAM
sudo modprobe vhost_net tun
cp ~/Downloads/SQLServer2025-x64-ENU-EntDev.iso media/
./lab build            # one time, unattended, ~1.5-3 h: init -> build-base -> provision
./lab up               # restore 'golden' and resume (target < 1 min; see Timings)
./lab health --deep    # cluster + AG + listener write test
./lab reset            # back to golden (fast in-place path)
./lab down
```

Watch the VMs: `./lab vnc` opens one noVNC tab per VM in the default browser (`xdg-open`), or
prints the URLs when there is no graphical session; `./lab vnc build` opens the dockur install
console (:8006). QEMU serves each
console on `images/run/<vm>.vnc`; `./lab console` runs the websockify gateway on 127.0.0.1:6111-6115.

Docker group: if `./lab doctor` says the session lacks group `docker`, log out and in, or run
`printf '%s\n' './lab up' | newgrp docker`. Run `sudo ./lab net` once per host boot to pin the
lab bridge MACs and add DOCKER-USER rules (without it, restores can see brief ARP/SSH timeouts).
Step-by-step build procedure for agents: [MAKE.md](MAKE.md).

Connect from the host: `sqlcmd -S tcp:10.50.0.60,1433 -U sa -P '<change me>' -C` (listener), or
any node IP. `./lab info` prints everything. Use SQL auth from the host (see *Time*).

## Checkpoints (predetermined states)

`./lab provision` saves three checkpoints, each a consistent RAM+disk snapshot of all 5 VMs:

| checkpoint | state |
|---|---|
| `sql-standalone` | domain up, 4 domain-joined standalone SQL 2025 instances, no cluster |
| `cluster` | + 2-subnet WSFC `LABCLU` (FSW on DC1), Always On enabled, endpoints, **no AG** |
| `golden` | + AG `LabAG` (SQL1/SQL2 sync-auto, SQL3 sync-manual, SQL4 async), DB `LabDB`, listener `LabAGL` |

You can also save your own at any time: `./lab save my-state` (for example after a test sets
up a scenario), then `./lab up my-state`. Checkpoints chain as qcow2 backing files. `./lab list`
shows them, and `./lab delete` refuses to delete a checkpoint that another one depends on.

## Architecture and why

**Build once, restore memory state.** A Windows cold boot plus cluster and AG convergence takes
minutes, so a reset that boots VMs can never get under a minute. So:

1. **Stage 1, base image (dockur).** `dockurr/windows` downloads the Server 2025 eval and does the
   unattended Core install with virtio drivers. Its `install.bat` hook runs `Prepare-Base.ps1`
   (roles, OpenSSH with the lab key, Defender/Update/maintenance removed, quiet tasks, first-boot
   hook), reboots into `Finalize-Base.ps1` (ngen, DISM cleanup, trim), then runs
   `sysprep /generalize /mode:vm` and powers off. The disk becomes `images/base/disk.qcow2`,
   which is read-only and shared by all 5 VMs.
2. **Stage 2, provisioning (own runtime image).** Five containers each run QEMU on a qcow2 overlay
   of the base. Identity (name, IP, gateway, DNS) is passed through the **SMBIOS serial**, so one
   image serves every node. `FirstBoot.ps1` applies it. After that the host drives everything over
   SSH (`lib/provision.sh`, `guest/*.ps1`; the logic is ported from SQLVagrantLab and made
   idempotent and resumable: `./lab provision cluster` continues from a checkpoint).
3. **Checkpoint.** All VMs are paused together (`stop`). Each VM's device and RAM state goes to a
   file (QEMU `migrate` to `file:` with the `mapped-ram` format). The live overlays are frozen
   read-only as the checkpoint's disks.
4. **Restore.** A new overlay goes on top of each checkpoint disk (instant). QEMU starts with
   `-incoming defer -S` and loads the state. When **all five** are loaded they get `cont` at the
   same instant, so the guests never notice time passing and no cluster heartbeat is missed.
   `./lab reset` keeps the containers and respawns QEMU in place.

**Why not dockur at runtime?** A memory-state restore needs a byte-identical device model. dockur
builds its QEMU command line on the fly, keeps UEFI vars in a raw file (which blocks snapshots),
and runs its own NAT/DHCP. Its maintainer declined snapshot support (dockur/windows#485, #1288);
the suggested approach is copying `/storage`, which still cold-boots. So dockur does what it is
good at (the install), and `runtime/launcher.sh` runs a fixed, minimal device set: q35, OVMF with
**qcow2 vars**, virtio-scsi, virtio-net with a fixed MAC, migratable Hyper-V enlightenments only.
The day-to-day UX is still `compose up`.

**Alternatives considered**
- *Hyper-V checkpoints*: the best Windows-native option, but the host is Linux. They also don't
  coordinate 5 VMs atomically, and restores are slower than local qcow2 + mapped-ram.
- *libvirt managed save / snapshots*: would work (same QEMU features underneath). It adds host
  daemon config and XML, and is less turnkey than one compose file. The launcher is the same idea
  without the daemon.
- *Vagrant (SQLVagrantLab)*: fine for builds, but `vagrant up` cold-boots and has no memory-state
  restore. The Packer/Vagrant provisioning logic was reused in `guest/`.
- *podman*: `compose.yml` uses only standard features. Rootful podman + podman-compose should work
  (untested). Quadlets/systemd add nothing for speed. Rootless won't work (bridges, tap, ip link).

**Networking.** Each VM container bridges its Docker `eth0` to a tap device, so the VM owns the
container's reserved IP and its own MAC. Extra IPs (cluster, listener) work via plain ARP. A tiny
router container at `.254` on both networks is every VM's gateway, so cross-subnet traffic really
is routed. The host sits on both bridges, so it reaches every IP directly. The networks are
external and persistent. **The host bridge MACs and router MACs are pinned**, because they live
in every guest's ARP cache inside the saved RAM. `ensure_net` also adds `DOCKER-USER` ACCEPT rules
for the lab bridges, in case a host firewall filters bridged traffic.

**Time (`LAB_TIME_MODE`).** The default, `frozen`, resumes guests at the checkpoint's wall-clock
time. RTC is `clock=vm`, so nothing jumps later. All VMs agree with each other, so Kerberos inside
the lab works and the Windows eval never expires. Host-side Kerberos will be skewed, so use SQL
auth from the host. `sync` sets every guest to host UTC right after resume. Machine-account and
CNO password rotation is disabled, so restoring an old checkpoint is safe in either mode. AD has a
single DC that is always restored together with its members, so there is no USN-rollback risk.
**Never restore a subset of the VMs.**

## Memory / CPU plan (8 threads, 32 GB)

| VM | vCPU | RAM | notes |
|---|---|---|---|
| DC1 | 1 | 2 GB | Server Core DC + DNS |
| SQL1-4 | 2 each | 5 GB each | SQL max server memory 2 GB, min 512 MB |
| total | 9 (slight overcommit) | 22 GB | + ~1 GB QEMU overhead, ~9 GB left for host + page cache |

Defender is removed (≈200-300 MB/VM). Turning on KSM (`echo 1 > /sys/kernel/mm/ksm/run`)
deduplicates identical Windows pages across VMs. State files hold only the touched pages
(≈2-4 GB per SQL node). Everything is tunable in `lab.env`, but changing RAM/CPU/MAC/IP
invalidates checkpoints (a fingerprint check warns you).

## Timings (honest)

| operation | expected | basis |
|---|---|---|
| `build-base` | 30-60 min | dockur install + DISM cleanup; download speed dominates |
| `provision` | 45-90 min | 4 SQL installs in parallel on 8 threads, AG seeding is trivial |
| `up` (cold, containers created) | **10-30 s** | measured 5.6 s with tiny guests on this sandbox; real time is dominated by reading ~12-18 GB of state (NVMe ~2-3 GB/s, parallel); page-cache warm is much faster |
| `reset` (fast in-place) | **5-20 s** | measured **~1.0 s** with tiny guests; same state-read cost as above |
| `down` | 1-2 s | measured 1.1 s |
| `save` | 15-60 s | writes all state files (measured ~1 GB in 6.5 s under TCG emulation, much faster with KVM) |
| first deep health after resume | 1-5 s | needs validation on real Windows |

The sub-minute target has comfortable margin on paper. It has **not been measured with Windows
guests** (the build sandbox cannot run KVM guests).

## What to test first on your machine (in this order)

1. `./lab doctor` and `tests/validate.sh` (static checks), then `sudo -E tests/e2e-fakeguest.sh`.
   That runs the whole runtime pipeline (networks, router, save/restore, resets, chained
   checkpoints) with tiny Linux guests under KVM in ~1 min. It must pass before anything Windows.
2. `./lab build-base`. Watch http://127.0.0.1:8006. Confirm `build/base/shared/phase1.done` and
   `sysprep.started` appear and that the container exits by itself. Then `qemu-img info
   images/base/disk.qcow2` should be roughly 8-14 GB.
3. `./lab provision` up to the first checkpoint. Check FirstBoot (SMBIOS identity → IP/name),
   SSH key login, DC promotion, domain join, and the SQL install from `/media`.
4. **The critical one:** `./lab up sql-standalone`. Windows must resume from the memory state on
   the runtime image with KVM + Hyper-V enlightenments, and `./lab health` must pass. If it doesn't,
   set `LAB_DEBUG=1` and read `docker logs lab-sql1`.
5. Finish provisioning, then run `./lab up && ./lab health --deep` 10× in a loop, timing it. Watch
   for cluster failovers after resume (`Get-ClusterLog`, AG role changes).
6. Try `LAB_TIME_MODE=sync` once and check that Kerberos/cluster stay healthy after a big clock jump.
7. Try `./lab save scenario-x` / `./lab up scenario-x` and a manual failover to SQL3 (cross-subnet).

## Known risks / open questions

- **Not run against Windows yet.** Every guest script parses and lints cleanly but has not
  executed. Expect a few fix-ups during the first build (all steps are idempotent and resumable).
- **Hardware change between the dockur build VM and the runtime VM.** Both use virtio-scsi and
  virtio-net, and the base is sysprepped, so specialize re-detects devices. This is believed safe
  but unverified. Fallback: build the base in the runtime image from the ISO + virtio-win ISO.
- dockur specifics: `EDITION=core` mapping, the `data.qcow2` file name, and SMB guest access for
  progress markers (best effort only) may change between releases. **Pin `LAB_DOCKUR_IMAGE`** to a
  tested tag.
- Windows resume after migration: hv-time/stimer state migrates in QEMU 10. A one-off clock or
  timer hiccup right after `cont` is possible. The cluster thresholds are raised (20/40) to absorb it.
- `cpu host` checkpoints only restore on the same CPU model and QEMU version (the runtime image is
  pinned through its digest in the fingerprint). Rebuilding the runtime image invalidates checkpoints.
- SQL 2025 setup flags (`/SQLMAXMEMORY`, PID `22222-...` for Enterprise Developer) come from the
  docs. Enable-Hadr uses `Enable-SqlAlwaysOn` (SQLPS); the registry fallback also grants the
  service SID cluster access and registers the AG resource type (else error 35222 / 41105).
- Firewalls: hosts with the iptables nft shim work with `./lab net`; ufw/firewalld do not affect host→VM traffic (the host sits on the lab bridges) or cross-subnet
  traffic (routed inside the router container). Default AppArmor/SELinux container profiles allow the
  `/dev/kvm`/`/dev/net/tun` devices and `NET_ADMIN` that the containers use. Avoid snap Docker.
- Docker ≥ 28 changed bridge filtering. Host→VM traffic doesn't depend on it, but verify
  cross-subnet with the e2e test. Rootful podman is untested.
- Disk: base ~12 GB + 3 checkpoints × (5 disks of deltas + ~12-18 GB state) ≈ 70-100 GB.
- The lab is air-gapped by default (`LAB_INTERNET=0`). Uses lab-only plain-text credentials; never
  expose `LAB_VNC_BIND` beyond localhost.

## Layout

```
lab                     CLI (bash)            lab.env        all settings
compose.yml             runtime: router + 5 VMs   compose.vhost.yml  auto-added if /dev/vhost-net
runtime/                Dockerfile, launcher.sh (QEMU + checkpoint/respawn), qmp.py, router.sh
build/base/             stage-1 dockur compose + OEM payload (Prepare/Finalize-Base, FirstBoot, unattend)
guest/                  provisioning scripts pushed over SSH (DC, join, SQL, WSFC, HADR, AG, listener, tests)
lib/                    common.sh (ssh/qmp/helpers), provision.sh (stage-2 orchestration)
tests/                  validate.sh (static), e2e-fakeguest.sh + fakeguest/ (runtime pipeline e2e)
ci/                     GitHub Actions self-hosted runner example
```

## Deployment targets

The lab runs on any Linux host with KVM and Docker. `MAKE.md` section 1a selects the target:

- **Local**: this computer (sections 3-10).
- **GCP**: one Compute Engine VM per team member, with nested virtualization, made with Terraform
  (`deploy/gcp/terraform/{shared,vms}`), reached through IAP (no public IP), spot by default.
  A shared bucket holds the ISO, base image, and optionally the runtime image and checkpoints.
  Command: `./lab gcp help`. Procedure: `MAKE.md` section G.

## Live watch terminal

Long steps (`./lab build-base`, `./lab provision`, `./lab gcp deploy`, `./lab gcp publish`) open one
terminal window by themselves that follows the build in real time: `logs/progress.log` and
`TRANSCRIPT.md` (for GCP: the lab host's logs over IAP SSH plus the local `TRANSCRIPT.md`).
Only one window per target opens (pid file in `logs/`). Open it yourself with `./lab watch` or
`./lab gcp watch-term VM`. Opt out with `LAB_WATCH=0`; select the program with `LAB_TERMINAL`.
Without a graphical session, the command to run is printed.
