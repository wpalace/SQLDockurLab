# MAKE.md: build and operate the SQL AG lab

Read this file completely before you start. Do the procedures in sequence.

## 0. Rules for the agent

1. Run all commands from the repository root (the directory that contains `lab`).
2. Record a transcript in `TRANSCRIPT.md` at the repository root. See section 10.
3. Write each time in Pacific Time. Use the label `PT` for all dates, also in summer (PDT) and winter (PST). Use the format `2026-10-15 09:15 PT`. The lab logs use the local clock of the host. On a GCE lab host, the clock is UTC: convert those times to PT.
4. Do not delete `images/` or `media/`, or anything in them, unless a procedure tells you to.
5. Do not push the repository. Do not contact other people.
6. Keep the progress log `logs/progress.log` (see step 3.0). Before and after each step, milestone, and failure, add one line: `./lab log "TEXT"`. The lab commands also write their own milestone lines to this log.

> **WARNING:** The lab uses plain-text, lab-only passwords. Keep `LAB_VNC_BIND=127.0.0.1`. Do not expose the lab ports to a network.

> **NOTE:** These are the terms used in this file. *Host* is the Linux computer. *VM* is one of DC1, SQL1, SQL2, SQL3, SQL4. *Checkpoint* is a saved RAM and disk state of all five VMs. *Golden* is the checkpoint with the full availability group (AG).

## 1. What you build

- One domain controller: DC1, 10.50.0.10, domain `lab.local`.
- Four SQL Server 2025 nodes: SQL1 and SQL2 on 10.50.0.0/24, SQL3 and SQL4 on 10.51.0.0/24.
- One WSFC cluster (`LABCLU`), AG `LabAG` with database `LabDB`, listener `LabAGL` at 10.50.0.60 and 10.51.0.60, port 1433.
- Replica modes (`LAB_AG_MODES` in `lab.env`): SQL1 and SQL2 synchronous commit with automatic failover (HA). SQL3 and SQL4 asynchronous commit with manual failover (DR).
- Passwords: see `lab.env` (`LAB_PASSWORD`). Run `./lab info` to show all connection data.

## 1a. Choose the deployment target

1. Ask the user: "Deploy the lab Local or on GCP?"
2. Record the answer in `TRANSCRIPT.md`.
3. Do the procedure for that target:

| Target | Host | Procedure |
|---|---|---|
| Local | This Linux computer | Sections 3 to 10 |
| GCP | One Google Compute Engine VM | Section G: build, test, golden snapshot, stop. Then spawn clones as necessary (G10) |

> **NOTE:** More targets can be added to this table. Each target makes a Linux host with KVM and Docker. Then the same lab procedure (sections 3 to 10) runs on that host.

## 2. Expected durations (32-thread host, NVMe, KVM)

| Step | Duration |
|---|---|
| `./lab doctor`, `./lab init` | 1-3 min |
| SQL ISO download (1.17 GB) | 1-5 min |
| `./lab build-base` | 20-60 min |
| `./lab provision` | 20-40 min |
| `./lab save NAME` | 25-30 s |
| `./lab reset` (fast, in place) | 2-3 s |
| `./lab up` (recreates containers) | 5-7 s |
| `./lab health --deep` | 3-4 s |
| AG failover (one direction) | about 5 s |

> **NOTE:** If a step takes more than 2 times the duration in the table, start section 9.

## 3. Prerequisites and checks

> **NOTE:** For the GCP target, steps 3.1 to 3.11 apply to the lab host, not to the workstation. `./lab gcp check VM` (G5) does these checks on the lab host. On the workstation, do only step 3.0 and G1.

0. Do this first. Run `./lab log "START prerequisites"`. This makes the empty file `logs/progress.log` and adds one timestamped line. Make `TRANSCRIPT.md` (section 10). Then run `./lab watch`. This opens a live watch terminal that follows `logs/progress.log` and `TRANSCRIPT.md` (`tail -F`), so that the user can monitor progress without asking. Make sure that the terminal is open before you continue.

> **NOTE:** The live watch terminal also opens by itself when `./lab build-base` or `./lab provision` starts. If a watch terminal is open already, no second terminal opens (the file `logs/.watch-local.pid` records it). To prevent the automatic terminal, set `LAB_WATCH=0`. To select the terminal program, set `LAB_TERMINAL` (for example `LAB_TERMINAL=xterm`). If there is no graphical session, the command shows `bash logs/.watch-local.sh`. Give that command to the user.
1. Make sure that the host is Linux on x86-64. Run `grep -Ec '(vmx|svm)' /proc/cpuinfo`. The result must be more than 0.
2. Make sure that `/dev/kvm` exists. If it does not exist, enable virtualization in the firmware.
3. Make sure that Docker Engine and Docker Compose (version 2 or later; any newer version is OK) are installed. Run `docker info` and `docker compose version`. Both commands must succeed.
4. Make sure that the user can use Docker and `/dev/kvm`. Run `id -nG` and `ls -l /dev/kvm`. The user must be in group `docker`. Group `kvm` is necessary only if `/dev/kvm` is not readable and writable by all users (`./lab doctor` shows `/dev/kvm accessible` when it is OK). If a group is missing, tell the user to run `sudo usermod -aG docker,kvm "$USER"` and then log out and log in.
5. Make sure that the host has 32 GB RAM or more. Make sure that it has 120 GB of free disk space or more.
   Make sure that `curl`, `sha256sum`, and an OpenSSH client are installed. `xdg-open` is optional.
   Make sure that `/dev/net/tun` exists. If it does not exist, run `sudo modprobe tun`.
6. Run `./lab doctor`.
7. Read every `warn` line in the output. Do the action that each line gives. Exceptions: `SQL ISO not found` is correct before section 4. Actions that need root (`sudo`) are optional; tell the user about them and continue.
8. If `doctor` reports that the session is not in group `docker`, do one of these steps:
   - Tell the user to log out and log in again.
   - Send each lab command through `newgrp`. Example: `printf '%s\n' 'cd "$PWD" && ./lab doctor' | newgrp docker`.
9. Run `./lab init`. This builds the runtime image, makes the SSH key, and makes the lab networks.
10. Run `tests/validate.sh`. It must show `ALL STATIC CHECKS PASSED`. You do not have to install the linters (shellcheck, yamllint, pwsh). If a linter is not installed, the script runs it from a container image (the first run downloads these images).
11. If the user has root access, tell the user to run `sudo ./lab net` once after each host boot.

> **CAUTION:** Do not use Docker from a snap package. Its confinement can block `/dev/kvm` and tap devices.

> **CAUTION:** Without `sudo ./lab net`, the bridge MAC addresses are not pinned, and the firewall rules are not added. Each `up` then shows a `could not pin MAC` warning. The lab still works. Right after a restore, SSH can time out for a few seconds; the lab scripts retry.

> **NOTE:** To run a long command in the background, use `setsid nohup CMD > LOG 2>&1 < /dev/null &`. Without `setsid`, the command can stop when your tool session ends.

## 4. Get the SQL Server 2025 Enterprise Developer ISO

1. Download the ISO:
   ```bash
   mkdir -p media
   curl -fL -o media/SQLServer2025-x64-ENU-EntDev.iso \
     https://download.microsoft.com/download/dea8c210-c44a-4a9d-9d80-0c81578860c5/ENU/SQLServer2025-x64-ENU-EntDev.iso
   ```
2. Verify the checksum:
   ```bash
   echo "f78f869d44e8c2cbf93be16ce6ea52dd811636f046ded29e7a74dd1352134851  media/SQLServer2025-x64-ENU-EntDev.iso" | sha256sum -c
   ```
3. The output must be `OK`. If it is not `OK`, delete the file and do step 1 again.

> **NOTE:** If the file is already there and the checksum is `OK`, skip this section.

## 5. Build the base image (stage 1)

1. Start the build in the background:
   `setsid nohup ./lab build-base > build-base.log 2>&1 < /dev/null &`
2. Wait 60 s.
3. Run `./lab vnc build`. This opens the Windows install console (http://127.0.0.1:8006) in the default browser. If there is no graphical session, the command prints the URL.
4. Give the URL to the user.
5. Monitor `build-base.log` and `build/base/shared/` every 5-10 min.
6. Expect these files in `build/base/shared/`, in this order: `phase1.started`, `phase1.done`, `phase2.started`, `sysprep.started`.
7. The build is complete when `build-base.log` shows `base image ready`.

> **CAUTION:** The dockur console shows the Windows setup screens and then a command prompt (sconfig). The lab scripts run hidden. To see their progress, read `build/base/shared/*.txt`.

> **NOTE:** If `build/base/shared/phase1.failed` or `phase2.failed` appears, `build-base` stops. The VM continues to run so that you can examine it. Go to section 9.

## 6. Provision the lab (stage 2)

1. Start provisioning in the background:
   `setsid nohup ./lab provision > provision.log 2>&1 < /dev/null &`
2. Wait until `provision.log` shows `waiting for all VMs`.
3. Run `./lab vnc`. This opens one noVNC tab for each VM (DC1, SQL1-SQL4) in the default browser. If there is no graphical session, give the printed URLs to the user.
4. Monitor `provision.log` every 5 min.
5. Expect these log lines in this order: `stage 1/3`, `checkpoint 'sql-standalone' saved`, `stage 2/3`, `checkpoint 'cluster' saved`, `stage 3/3`, `HEALTHY`, `failover chain OK`, `HEALTHY`, `checkpoint 'golden' saved`, `provisioning finished`.
   The failover chain is a planned failover SQL1 -> SQL2 -> SQL3 -> SQL4 -> SQL1. After each move, a heartbeat row is written through the listener and must be visible on the new primary. The chain ends with SQL1 as primary and the modes from `lab.env`, before the golden checkpoint is saved. To skip it, set `LAB_FAILOVER_CHAIN=0`.
6. If provisioning stops with an error, fix the cause (section 9). Then continue from the last checkpoint that was saved:
   `./lab provision sql-standalone` or `./lab provision cluster`.
   If no checkpoint is saved yet (a failure in stage 1), run `./lab provision` again. The VM disks keep the work that is done, and the guest scripts skip the steps that are complete.

> **NOTE:** Each restore recreates the VM containers. The noVNC tabs reconnect without help. If a tab shows "Disconnected" for more than 30 s, run `./lab vnc` again.

## 7. Operate the lab

| Task | Command |
|---|---|
| Restore golden and start | `./lab up` |
| Restore another checkpoint | `./lab up NAME` |
| Go back to golden fast | `./lab reset` |
| Stop and discard the running state | `./lab down` |
| Save the running state | `./lab save NAME` |
| Replace a checkpoint | `./lab save NAME --force` |
| List checkpoints | `./lab list` |
| Delete a checkpoint | `./lab delete NAME` |
| Fast reachability check | `./lab health` |
| Full check (cluster, AG, listener, write) | `./lab health --deep` |
| Open VM consoles | `./lab vnc` |
| Show status | `./lab status` |
| PowerShell on a VM | `./lab ssh SQL1` |
| Planned failover, no data loss | `./lab failover SQL3` |
| Change replica modes | `./lab failover-modes "SQL3:SYNCHRONOUS_COMMIT:MANUAL ..."` (`config` = `lab.env`) |
| Power off one VM (test) | `./lab kill SQL1` |

> **CAUTION:** Do not run `ALTER AVAILABILITY GROUP ... FAILOVER` on an asynchronous replica. Use `./lab failover SQLn`. The command does these steps: (1) it sets the primary and the target to `SYNCHRONOUS_COMMIT`, (2) it waits until the target is `SYNCHRONIZED`, (3) it runs `FAILOVER` on the target (no data loss), (4) it sets the original modes again. `FORCE_FAILOVER_ALLOW_DATA_LOSS` is necessary only if the primary is lost; do not use it for planned failovers.

> **NOTE:** An AG can have at most 3 replicas with automatic failover (SQL Server 2025, including the primary). Before you set more replicas to `AUTOMATIC`, set others to `MANUAL`. `./lab failover-modes` changes the modes in a safe sequence: `MANUAL` first, then the availability mode, then `AUTOMATIC`.

> **CAUTION:** You cannot replace the checkpoint that the lab currently runs on. Save under a new name.

> **NOTE:** `./lab delete` does not delete a checkpoint if other checkpoints depend on it.

## 8. Test cases

Do all these tests after provisioning. Record each result in the summary (section 10).

> **NOTE:** `tests/run-tcs.sh` does TC1 to TC9 automatically. It shows `PASS` or `FAIL` and the duration for each test, and ends with `ALL TESTS PASSED` or `TESTS FAILED`. For TC7, it examines the URLs with `curl`; ask the user to confirm the screens.

1. **TC1 Static checks.** Run `tests/validate.sh`. Expected: `ALL STATIC CHECKS PASSED`.
2. **TC2 Engine test.** Run `tests/e2e-fakeguest.sh`. Expected: `all e2e checks passed`. Run it only when no lab is running, because it uses the same container names.
3. **TC3 Reset loop.** Do these steps 10 times: run `./lab reset golden`, then `./lab health --deep --wait 60`. (Without `--wait`, a check right after a restore can show `unreachable` for a few seconds.) Record each duration. Expected: each reset takes less than 60 s, and each result is `HEALTHY` with SQL1 as primary.
4. **TC4 Cross-subnet failover to an asynchronous replica.** Run `./lab failover SQL3` (planned, no data loss; see section 7).
   Run `./lab health --deep --wait 60`. Expected: `listener LabAGL -> SQL3` and `HEALTHY`.
5. **TC5 Failback.** Do TC4 again on SQL1. Expected: `listener LabAGL -> SQL1`.
6. **TC6 Reset after change.** Do TC4 again (SQL3 becomes primary). Run `./lab reset`, then `./lab health --deep --wait 60`. Expected: SQL1 is primary, the status is `HEALTHY`, and `./lab status` shows `checkpoint: golden`.
7. **TC7 Consoles.** Run `./lab vnc`. Expected: five tabs. Each tab title starts with `QEMU (`. If you cannot see the browser, run `./lab vnc urls` and `curl -s -o /dev/null -w '%{http_code}' URL` for each URL. Expected: `200`. Ask the user to confirm that the tabs show the VM screens.
8. **TC8 Automatic failover in subnet A.** From golden: write a marker row through the listener, run `./lab kill SQL1`, and wait until the listener reaches SQL2 (`./lab agtool -WaitPrimary SQL2 -Note MARK`). Expected: listener -> SQL2 on 10.50.0.60, `LabDB` writable, the marker row is present. Record the time from power-off to online. Then run `./lab up golden` and `./lab health --deep --wait 60` (SQL1 primary, `HEALTHY`).
9. **TC9 Automatic failover in subnet B.** From golden: `./lab failover SQL3`. Then `./lab failover-modes "SQL1:SYNCHRONOUS_COMMIT:MANUAL SQL2:SYNCHRONOUS_COMMIT:MANUAL SQL3:SYNCHRONOUS_COMMIT:AUTOMATIC SQL4:SYNCHRONOUS_COMMIT:AUTOMATIC"` and `./lab agtool -WaitSync SQL4`. Write a marker row, run `./lab kill SQL3`, and wait for SQL4. Expected: listener -> SQL4 on 10.51.0.60, the marker row is present. Then `./lab up golden` and the deep health check (SQL1 primary, `HEALTHY`).
10. When all the tests are complete, run `./lab reset`. Leave the lab running at golden.

## 7a. Connect with VS Code

Use the VS Code extension `ms-mssql.mssql` (SQL Server). Windows authentication does not work from a Linux host that is not in the domain. Use SQL authentication.

| Item | Value |
|---|---|
| Login | `sa` (setup uses `/SECURITYMODE=SQL`) |
| Password | `LAB_PASSWORD` in `lab.env` |
| Encrypt | Mandatory, with *Trust server certificate* (the lab uses self-signed certificates) |
| Listener (local lab) | `10.50.0.60,1433` with `MultiSubnetFailover=True` (the host cannot resolve `LabAGL.lab.local`, so use the IP) |
| SQL1-SQL4 (local lab) | `10.50.0.11`, `10.50.0.12`, `10.51.0.13`, `10.51.0.14` |
| GCP lab host | Run `./lab gcp tunnel VM --sql`. Listener `127.0.0.1,14330`, SQL1-SQL4 `127.0.0.1,14331` to `14334`. Do not set `MultiSubnetFailover` for the tunnel. |

1. Start the lab: `./lab up`.
2. In VS Code, open the *SQL Server* view. Add a connection with the values above, or add entries to `mssql.connections` in the user `settings.json`.
3. Connect and run `SELECT @@SERVERNAME`. On the listener, the result is the primary (SQL1 at golden).

> **NOTE:** After `./lab reset`, the connections are closed. Connect again.

## 9. Recover from failures

| Symptom | Cause | Action |
|---|---|---|
| `permission denied` on the Docker socket | The session is not in group `docker` | Do step 3.8 |
| `could not pin MAC` warning | No root access | Tell the user to run `sudo ./lab net` (step 3.11). You can continue. |
| `ssh: connect ... timed out` just after a restore | ARP is slow on a busy guest | Run the command again. If the error stays for more than 2 min, run `./lab reset`. |
| `build-base` shows no new marker for 30 min | A guest script stopped | Look at the console (`./lab vnc build`). Read `build/base/shared/*.txt`. Fix the script in `build/base/oem/lab/`. Then run `./lab build-base` again. |
| `X.ps1 exited N` during `provision` | Guest script error | Read the error text above that line. Fix the script in `guest/`. Then continue from the last checkpoint (step 6.6). |
| SQL error 35222 or 41105 at `CREATE AVAILABILITY GROUP` | Always On was enabled without its cluster parts | `Enable-Hadr.ps1` and `Wait-LabHadrReady` correct this. Continue from `sql-standalone`. |
| noVNC tab shows "Disconnected" | The VM container was recreated, or `lab-novnc` is stopped | Run `./lab console stop`, then `./lab vnc`. |
| Restore fails with a fingerprint error | The runtime image changed after the checkpoint was saved | Run `./lab provision` again. Do not delete the base image. |

> **WARNING:** Do not run `docker system prune` or delete `images/base/`. A new base image takes 35-60 min.

> **NOTE:** To see a VM screen for diagnosis, open its noVNC tab. For the dockur build VM, send `screendump` to `/run/shm/monitor.sock` in container `lab-base-build`.

## 10. Transcript and summary

1. Make `TRANSCRIPT.md` before step 3.1. If `TRANSCRIPT.md` exists already (from an earlier build), do not delete it and do not write over it. Add a new section at the end, for example `## Build 2026-10-16 09:00 PT`, and write the new lines in that section.
2. For each major step (sections 3, 4, 5, 6, 8), write one line when the step starts and one line when it ends. Write the same lines to the progress log with `./lab log`:
   `- 2026-10-15 09:20 PT START build-base` and
   `- 2026-10-15 10:02 PT END build-base (42 min, OK)`.
3. Write each failure, its cause, and the fix below the step.
4. At the end, add a section `## Test summary` with this table:

| Test | Result | Duration | Notes |
|---|---|---|---|
| TC1 | PASS/FAIL | | |

5. Give the user the total time, the test summary, and the remaining problems.

## G. Target: GCP

> **NOTE:** In this section, *workstation* is the computer of the user. *Lab host* is the GCE VM. Run `./lab gcp ...` on the workstation. Run `./lab ...` on the lab host.

> **CAUTION:** The GCP target makes resources that cost money. Get approval from the user before each `apply`, `create`, and `deploy`. Stop the lab host when you finish (G9).

### G0. Select the workstation front end

You can operate the GCP target from Linux, macOS, or Windows. Windows does not need WSL.

| Workstation | Front end | Command form |
|---|---|---|
| Linux, macOS (bash) | `lab` (bash) | `./lab gcp COMMAND` |
| Windows, Linux, macOS (PowerShell 7) | `lab.ps1` | `./lab.ps1 gcp COMMAND` |

The two front ends have the same commands and options. In this section, `./lab gcp` means the front end that you use. On Windows, write `.\lab.ps1 gcp` in place of `./lab gcp`.

> **NOTE:** The lab host is always Linux. On the lab host, the scripts stay bash (`./lab`, `remote-deploy.sh`, `vm-check.sh`, `artifacts.sh`). `lab.ps1` starts them through IAP SSH.

#### G0.1 Windows workstation (no WSL)

1. Install the tools. Open PowerShell and run:
   ```powershell
   winget install --id Microsoft.PowerShell -e
   winget install --id Google.CloudSDK -e
   winget install --id Hashicorp.Terraform -e
   winget install --id Git.Git -e
   ```
2. Close the window. Open PowerShell 7 (`pwsh`). Make sure that `pwsh`, `gcloud`, `terraform`, and `git` are found: `Get-Command pwsh, gcloud, terraform, git`.
3. Clone the repository with LF line ends: `git clone -c core.autocrlf=false URL`. The file `.gitattributes` also keeps the scripts for the lab host in LF.
4. If PowerShell does not run the script, run `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` one time.
5. Go to the repository directory. Run `.\lab.ps1 gcp tools`. The output must end with `operator tools ready`.
6. Optional: install Windows Terminal (`winget install --id Microsoft.WindowsTerminal -e`). The live watch terminal opens there. Without it, the watch terminal opens in a new `pwsh` window.

> **NOTE:** On Windows, `gcloud compute ssh` uses PuTTY (`plink`, `pscp`). gcloud installs these tools and makes the SSH key in `%USERPROFILE%\.ssh\google_compute_engine.ppk` at the first connection. `./lab.ps1 gcp tunnel` uses `gcloud compute start-iap-tunnel` for the console ports. `--sql` and `--socks` use SSH port forwarding.

> **NOTE:** `./lab.ps1 gcp console VM` makes the tunnel and opens the console URLs in the default browser.

> **NOTE:** `./lab.ps1 log TEXT` and `./lab.ps1 watch` do the same as `./lab log TEXT` and `./lab watch` (section 3.0) on the workstation. The other local lab commands (`./lab up`, `./lab provision`, and so on) need a Linux host with KVM. On GCP, they run on the lab host.

#### G0.2 Linux or macOS workstation

Use `./lab gcp` (bash), or install PowerShell 7 and use `./lab.ps1 gcp`. Install the Google Cloud CLI, Terraform 1.5 or later, and Git with the package manager of the system.

### G1. Workstation prerequisites

1. Make sure that the workstation has the Google Cloud CLI. Run `gcloud version`.
2. Make sure that the workstation has Terraform 1.5 or later. Run `terraform version`.
3. Tell the user to sign in: `gcloud auth login` and `gcloud auth application-default login`.
4. Run `./lab gcp tf-check`. The output must show `Success!` two times.
5. PowerShell front end only: run `./lab.ps1 gcp tools`. The output must end with `operator tools ready`.

### G2. Parameters

1. Copy the examples only if the files do not exist. Do not write over a `terraform.tfvars` that the user filled in:
   `cp -n deploy/gcp/terraform/shared/terraform.tfvars.example deploy/gcp/terraform/shared/terraform.tfvars` and
   `cp -n deploy/gcp/terraform/vms/terraform.tfvars.example deploy/gcp/terraform/vms/terraform.tfvars`.
2. If the files existed already, show the values to the user and make sure that they are correct. Then tell the user to fill in each value marked `REQUIRED`: `project_id`, `bucket_name`, `team_members`, and the `vms` entries (`<owner>-<n>`).
3. Make sure that the user agrees to the other values: region and zone, machine type, disk size and type, spot, `public_ip`.
4. Optional: to share Terraform state with the team, copy `backend.tf.example` to `backend.tf` in each root and set the state bucket.

> **NOTE:** Defaults: `n2-standard-16` (16 vCPU, 64 GB), `Intel Ice Lake`, `pd-ssd` 300 GB, Debian 12 image, spot, no public IP. Nested virtualization works on Intel machine series (N1, N2, N4, C2, C3, C4) and on AMD N4D only. It does not work on E2, Arm, other AMD, or memory-optimized series. N4, C3, and C4 need `hyperdisk-balanced`.

> **NOTE:** The `terraform.tfvars` files, `backend.tf`, and the state are not committed (`.gitignore`).

### G3. Shared infrastructure (one time for each project)

1. Run `./lab gcp init shared`.
2. Run `./lab gcp plan shared`. Show the plan to the user.
3. Run `./lab gcp apply shared`. This makes the VPC, the subnet, Cloud NAT, the IAP SSH firewall rule, two service accounts (read and publish), and the artifact bucket.

> **NOTE:** `apply` shows the plan and asks `Enter a value:`. Type `yes`. An agent without an interactive terminal must get approval from the user first, and then use `./lab gcp apply shared --yes` (or `vms --yes`). `--yes` adds `-auto-approve`.

> **NOTE:** If the shared root exists already (another team member applied it), skip G3.

### G4. Lab host VM

1. Run `./lab gcp init vms`.
2. Run `./lab gcp plan vms`. Show the plan to the user.
3. Run `./lab gcp apply vms` (an agent: `./lab gcp apply vms --yes`, after approval).
4. Run `./lab gcp list`. The VM must show `RUNNING` and `NESTED True`.
5. Do not wait for a fixed time. The startup script installs Docker (2-5 min). Go to G5: `./lab gcp check VM` shows `startup script has not completed` until it is complete. If it shows that line, wait 1 min and run the check again.

### G5. Verify the lab host (do not skip)

1. Run `./lab gcp push VM`. This copies the committed repository to `~/sql-ag-lab` on the lab host.
2. Run `./lab gcp check VM`.
3. The output must end with `is ready for the lab`. The check examines:
   - GCE settings: nested virtualization on, machine type and minimum CPU platform the same as Terraform, no external IP.
   - The lab host: startup script complete, `vmx`/`svm` CPU flag, `/dev/kvm`, KVM module, `/dev/net/tun`, `/dev/vhost-net`, Docker and Compose, group `docker`, vCPUs, RAM, disk size and free space, disk throughput, bucket access, clock sync, internet egress.
   - `./lab doctor` on the lab host.
4. If a line shows `FAIL`, do the `fix:` action on that line. Then do step 2 again.

### G6. Shared artifacts

1. Run `./lab gcp artifacts VM`. This shows what the bucket has.
2. If the bucket has the ISO and the base image, the deploy (G7) downloads them and does not build them.
3. After the first complete build, publish (step G8.5) the artifacts from a VM with `publisher = true`:
   `./lab gcp publish VM iso base key` and optionally `./lab gcp publish VM image checkpoints` (run `./lab down` on the lab host first).

> **CAUTION:** Memory checkpoints restore only on a lab host with the same runtime image, the same `LAB_CPU_MODEL`, and the same `lab.env`. Use the same machine type and minimum CPU platform on all VMs that share checkpoints. With `cpu_model = "host"`, a different CPU generation makes the restore fail. The fetch step compares fingerprints and skips checkpoints that do not agree.

> **NOTE:** Publish times on n2-standard-16 with pd-ssd: ISO + base image + runtime image about 2 min. Checkpoints: archive about 2.5 min, hash about 2 min, upload about 3.5 min (22 GB compressed from 55 GB).

> **NOTE:** Clone a built lab host: stop it, run `./lab gcp snapshot VM`, then add a `vms` entry with `source_snapshot` (and optionally `name`). The clone contains the repository, the runtime image, and the checkpoints. The first restore on a clone reads the snapshot blocks for the first time and can be slow, especially on `pd-standard`. Use `LAB_UP_TIMEOUT=900 ./lab up golden` for the first restore. Measured (n2-standard-16, pd-standard 300 GB): snapshot 277 s, VM create 93 s, SSH ready 28 s later, first restore more than 180 s (timed out), then 4.4 s; resets 2.2-2.7 s.

> **NOTE:** Optional fast clone: `./lab gcp image VM` makes a custom image of a fully built lab host. Set `image` for a new VM to that image family. The checkpoints on the lab host stay the reset method (`./lab reset`).

### G7. Deploy the lab

1. Open a second terminal on the workstation. Run `./lab gcp tunnel VM`. Keep it open.
2. Run `./lab gcp deploy VM` (add `--checkpoints` to use published checkpoints).
3. Give the console URLs that the tunnel prints to the user: `http://127.0.0.1:8006` (base build), `http://127.0.0.1:6111` to `6115` (DC1, SQL1-SQL4). If a local lab uses these ports on the workstation, the tunnel adds 10000 (`18006`, `16111` to `16115`). Use the URLs that the tunnel prints.
4. Make sure that the live watch terminal is open on the workstation. `./lab gcp deploy` and `./lab gcp publish` open it by themselves. It follows the progress log and the deploy log on the lab host (through IAP SSH, with automatic reconnect) and the local `TRANSCRIPT.md`. If it is not open, run `./lab gcp watch-term VM`. The deploy is complete when the log shows `DEPLOY COMPLETE`.
4a. To see the VM screens, open the console URLs (step 3) in a browser on the workstation, for example `xdg-open http://127.0.0.1:6111`. Open `8006` during the base build, and `6111` to `6115` when `provision.log` shows `waiting for all VMs`. Tell the user which URLs are open.
5. For SQL access from the workstation, run `./lab gcp tunnel VM --sql`. Connect to `127.0.0.1,14330` (listener) or `127.0.0.1,14331` to `14334` (SQL1-SQL4).

> **NOTE:** The networks 10.50.0.0/24 and 10.51.0.0/24 exist only on the lab host. Use the port forwards, or `--socks PORT` for a SOCKS proxy.

> **NOTE:** A spot VM can be preempted. Then it stops and keeps its disk. Run `./lab gcp start VM`, then `./lab gcp deploy VM` again. The deploy continues from the last completed stage (base image, checkpoint). An interrupted base build starts again.

> **NOTE:** Measured on GCP (n2-standard-16, pd-ssd 300 GB, empty bucket): apply shared 1 min, apply vms 30 s, startup script 2 min, deploy 40 min (build-base 22 min, provision 17 min), reset 2-6 s.

### G8. Tests

1. Run `./lab gcp test VM`. This runs the test cases TC1 to TC9 (section 8) on the lab host with `tests/run-tcs.sh`. The live watch terminal opens.
2. The output must end with `all tests passed on VM`. The output shows one `RESULT` line with `PASS` or `FAIL` and the duration for each test.
3. Record the results in `TRANSCRIPT.md` (section 10).
4. If a test fails, go to section 9. Do not do G9. You can run `./lab gcp test VM` again: TC2 removes the old files in `/tmp/sql-ag-lab-e2e` at start and at end.
5. **Publish (do this step after the first complete build, before G9).** The VM must have `publisher = true`. Run `./lab gcp ssh VM "cd sql-ag-lab && ./lab down"`. Then run `./lab gcp publish VM iso base key` and `./lab gcp publish VM image checkpoints`. Run `./lab gcp artifacts VM`. The output must show `iso` (or `iso-media`), `base`, `key`, `image`, and `checkpoints`. Skip this step if the bucket has these items with the same fingerprint already.

> **NOTE:** There are two fingerprints. They have different functions:
> - The *checkpoint fingerprint* (`FINGERPRINT=` in `images/checkpoints/golden/meta.env`, snapshot label `fp`) identifies the runtime image, `LAB_CPU_MODEL`, and `lab.env` that saved the checkpoints. A restore needs the same value.
> - The *host fingerprint* (`meta` column in `./lab gcp artifacts VM`) shows the machine type and CPU of the VM that published an item. `fetch` downloads checkpoints only when the checkpoint fingerprint agrees.

### G9. Golden snapshot (final build step)

1. Do this step only after all tests pass (G8). Get approval from the user, because the step stops the lab host.
2. Run `./lab gcp golden VM`. The command:
   - Makes sure that `logs/tests.passed` on the lab host is newer than the golden checkpoint. If not, it stops and makes no snapshot.
   - Stops the lab and the lab host, so that the disk is consistent.
   - Makes the snapshot `sqlag-golden-YYYYMMDD-HHMM` with the labels `kind=golden`, `source`, `fp` (checkpoint fingerprint), and `commit`.
   - Records the snapshot as the latest golden snapshot in `deploy/gcp/state/golden-snapshot` (not committed).
   - Adds a line to `logs/progress.log` and to `TRANSCRIPT.md`.
3. Run `./lab gcp list`. The lab host must show `TERMINATED`. `golden` stops the lab host, so G11 step 1 is not necessary after G9.
4. Run `./lab gcp snapshots`. The new snapshot must show as latest.

> **NOTE:** `./lab gcp finish VM` does G8 and G9 in one command. It makes no snapshot if a test fails.

> **NOTE:** A snapshot costs about $0.05 for each GB-month of stored data (estimate). A lab host with checkpoints stores about 50 GB, so about $2.50 for each month. A stopped 300 GB `pd-ssd` disk costs about $51 for each month. Thus, to keep a lab for later use, keep the snapshot and delete the VM.

### G10. Delete VMs and spawn clones from the golden snapshot

1. To make a new lab host from the latest golden snapshot, run `./lab gcp spawn NAME`. Get approval from the user first (it makes a VM that costs money). The command:
   - Adds `NAME` to `deploy/gcp/terraform/vms/spawned.auto.tfvars.json` (not committed) and applies only that VM with Terraform.
   - Uses the same machine type, minimum CPU platform, network, and service account as the defaults in `terraform.tfvars`.
   - Uses a `pd-balanced` boot disk (`default_spawned_disk_type`). The build VM uses `pd-ssd` (`default_disk_type`) for the base image and the lab build.
   - Waits for SSH and the startup script, does `./lab gcp check NAME`, and copies the repository.
   - Restores golden with `LAB_UP_TIMEOUT=1800`, and does a deep health check.
2. Options: `--disk-type pd-balanced|pd-ssd|pd-standard` (default `pd-balanced`), `--snapshot SNAPSHOT`, `--machine-type TYPE`, `--no-up` (no restore).
3. To delete a spawned VM and its disk, run `./lab gcp destroy NAME`. Type the name to confirm, or use `--yes`. The snapshots stay.
4. To use a different snapshot as latest, run `./lab gcp use-snapshot SNAPSHOT`.

> **CAUTION:** `./lab gcp destroy NAME` deletes only VMs made by `spawn`. It refuses the VMs in `terraform.tfvars` (for example `bill-1`). To delete one of those, use `./lab gcp delete KEY` after approval from the user.

> **NOTE:** The first restore on a spawned VM is slow. The disk loads each block from the snapshot when it is read for the first time. On `pd-standard`, the first restore took more than 180 s; after that, resets took 2.2-2.7 s. If you need faster first restores, use `--disk-type pd-ssd`. `pd-balanced` and `pd-ssd` both use the quota `SSD_TOTAL_GB`.

> **CAUTION:** A golden snapshot restores correctly only on a VM with the same CPU model and runtime image as the source VM. Keep the machine type and the minimum CPU platform the same as the source (the defaults). The snapshot label `fp` shows the checkpoint fingerprint. `./lab up` shows a warning when the fingerprint is different.

> **NOTE:** The shared bucket (G6) is a fallback. If no golden snapshot is available, or a snapshot does not agree with the CPU of the new VM, make a VM with `./lab gcp create KEY`. Then run `./lab gcp deploy KEY --checkpoints`. The deploy downloads the ISO, the base image, and (if the fingerprint agrees) the checkpoints from the bucket, and builds what is missing.

### G11. Stop the lab host

1. If you did G9, the lab host is stopped already. Otherwise run `./lab gcp stop VM` when you finish. Compute charges stop. Disk charges continue.
2. Run `./lab gcp cost` to show the estimate to the user.
3. To delete a VM from `terraform.tfvars`, run `./lab gcp delete KEY`. Get approval from the user first.

| Task (GCP) | Command |
|---|---|
| List lab VMs | `./lab gcp list` |
| Start or stop | `./lab gcp start VM`, `./lab gcp stop VM` |
| Shell on the lab host | `./lab gcp ssh VM` |
| Consoles and SQL | `./lab gcp tunnel VM [--sql]` |
| Add one VM from tfvars | `./lab gcp create KEY` |
| Tests, then golden snapshot | `./lab gcp finish VM` |
| Clone from the golden snapshot | `./lab gcp spawn NAME [--disk-type T]` |
| Delete a clone | `./lab gcp destroy NAME` |
| List snapshots | `./lab gcp snapshots` |
