# MAKE.md: build and operate the SQL AG lab

Read this file completely before you start. Do the procedures in sequence.

## 0. Rules for the agent

1. Run all commands from the repository root (the directory that contains `lab`).
2. Record a transcript in `TRANSCRIPT.md` at the repository root. See section 10.
3. Write each time in Pacific Time (PT). Use the format `2026-10-15 09:15 PT`.
4. Do not delete `images/` or `media/`, or anything in them, unless a procedure tells you to.
5. Do not push the repository. Do not contact other people.

> **WARNING:** The lab uses plain-text, lab-only passwords. Keep `LAB_VNC_BIND=127.0.0.1`. Do not expose the lab ports to a network.

> **NOTE:** These are the terms used in this file. *Host* is the Linux computer. *VM* is one of DC1, SQL1, SQL2, SQL3, SQL4. *Checkpoint* is a saved RAM and disk state of all five VMs. *Golden* is the checkpoint with the full availability group (AG).

## 1. What you build

- One domain controller: DC1, 10.50.0.10, domain `lab.local`.
- Four SQL Server 2025 nodes: SQL1 and SQL2 on 10.50.0.0/24, SQL3 and SQL4 on 10.51.0.0/24.
- One WSFC cluster (`LABCLU`), AG `LabAG` with database `LabDB`, listener `LabAGL` at 10.50.0.60 and 10.51.0.60, port 1433.
- Passwords: see `lab.env` (`LAB_PASSWORD`). Run `./lab info` to show all connection data.

## 2. Expected durations (32-thread host, NVMe, KVM)

| Step | Duration |
|---|---|
| `./lab doctor`, `./lab init` | 1-3 min |
| SQL ISO download (1.17 GB) | 1-5 min |
| `./lab build-base` | 35-60 min |
| `./lab provision` | 20-40 min |
| `./lab save NAME` | 25-30 s |
| `./lab reset` (fast, in place) | 2-3 s |
| `./lab up` (recreates containers) | 5-7 s |
| `./lab health --deep` | 3-4 s |
| AG failover (one direction) | about 5 s |

> **NOTE:** If a step takes more than 2 times the duration in the table, start section 9.

## 3. Prerequisites and checks

1. Make sure that the host is Linux on x86-64. Run `grep -Ec '(vmx|svm)' /proc/cpuinfo`. The result must be more than 0.
2. Make sure that `/dev/kvm` exists. If it does not exist, enable virtualization in the firmware.
3. Make sure that Docker Engine and Docker Compose v2 are installed. Run `docker info` and `docker compose version`. Both commands must succeed.
4. Make sure that the user is in groups `docker` and `kvm`. Run `id -nG`. If a group is missing, tell the user to run `sudo usermod -aG docker,kvm "$USER"` and then log out and log in.
5. Make sure that the host has 32 GB RAM or more. Make sure that it has 120 GB of free disk space or more.
   Make sure that `curl`, `sha256sum`, and an OpenSSH client are installed. `xdg-open` is optional.
   Make sure that `/dev/net/tun` exists. If it does not exist, run `sudo modprobe tun`.
6. Run `./lab doctor`.
7. Read every `warn` line in the output. Do the action that each line gives.
8. If `doctor` reports that the session is not in group `docker`, do one of these steps:
   - Tell the user to log out and log in again.
   - Send each lab command through `newgrp`. Example: `printf '%s\n' 'cd "$PWD" && ./lab doctor' | newgrp docker`.
9. Run `./lab init`. This builds the runtime image, makes the SSH key, and makes the lab networks.
10. Run `tests/validate.sh`. It must show `ALL STATIC CHECKS PASSED`.
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
5. Expect these log lines in this order: `stage 1/3`, `checkpoint 'sql-standalone' saved`, `stage 2/3`, `checkpoint 'cluster' saved`, `stage 3/3`, `HEALTHY`, `checkpoint 'golden' saved`, `provisioning finished`.
6. If provisioning stops with an error, fix the cause (section 9). Then continue from the last checkpoint that was saved:
   `./lab provision sql-standalone` or `./lab provision cluster`.

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

> **CAUTION:** You cannot replace the checkpoint that the lab currently runs on. Save under a new name.

> **NOTE:** `./lab delete` does not delete a checkpoint if other checkpoints depend on it.

## 8. Test cases

Do all these tests after provisioning. Record each result in the summary (section 10).

1. **TC1 Static checks.** Run `tests/validate.sh`. Expected: `ALL STATIC CHECKS PASSED`.
2. **TC2 Engine test.** Run `tests/e2e-fakeguest.sh`. Expected: `all e2e checks passed`. Run it only when no lab is running, because it uses the same container names.
3. **TC3 Reset loop.** Do these steps 10 times: run `./lab reset golden`, then `./lab health --deep`. Record each duration. Expected: each reset takes less than 60 s, and each result is `HEALTHY` with SQL1 as primary.
4. **TC4 Cross-subnet failover.** Run on SQL3:
   `./lab ssh SQL3 "Invoke-Sqlcmd -Query 'ALTER AVAILABILITY GROUP [LabAG] FAILOVER'"`.
   Run `./lab health --deep`. Expected: `listener LabAGL -> SQL3` and `HEALTHY`.
5. **TC5 Failback.** Do TC4 again on SQL1. Expected: `listener LabAGL -> SQL1`.
6. **TC6 Reset after change.** Run `./lab reset`, then `./lab health --deep`. Expected: SQL1 is primary, the status is `HEALTHY`, and `./lab status` shows `checkpoint: golden`.
7. **TC7 Consoles.** Run `./lab vnc`. Expected: five tabs. Each tab title starts with `QEMU (`.
8. When all the tests are complete, run `./lab reset`. Leave the lab running at golden.

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

1. Make `TRANSCRIPT.md` before step 3.1.
2. For each major step (sections 3, 4, 5, 6, 8), write one line when the step starts and one line when it ends:
   `- 2026-10-15 09:20 PT START build-base` and
   `- 2026-10-15 10:02 PT END build-base (42 min, OK)`.
3. Write each failure, its cause, and the fix below the step.
4. At the end, add a section `## Test summary` with this table:

| Test | Result | Duration | Notes |
|---|---|---|---|
| TC1 | PASS/FAIL | | |

5. Give the user the total time, the test summary, and the remaining problems.
