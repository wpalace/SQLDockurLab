# PowerShell 7 operator front end (`lab.ps1`)

Windows operators can drive the GCP target without WSL. `lab.ps1` runs with PowerShell 7 on
Windows, Linux and macOS. The lab host (GCE VM) stays Linux and bash.

## Mapping

| Bash (operator machine) | PowerShell | Notes |
|---|---|---|
| `lab` (`gcp`, `log`, `watch`) | `lab.ps1` | other `lab` commands are the Linux lab engine (not converted) |
| `deploy/gcp/lab-gcp` | `deploy/gcp/lab-gcp.ps1` | same subcommands and flags; new: `tools`, `console VM`, `tunnel --open` |
| `lib/watch.sh` (`watch_open`, `watch_local`) | `lib/LabHost.psm1` (`Open-LabWatch`) | Windows Terminal or a new pwsh window; Linux terminals as before |
| `lib/common.sh` `plog` / `./lab log` | `lib/LabHost.psm1` (`Write-LabProgress`, `Add-LabNote`) | same `logs/progress.log` and `TRANSCRIPT.md` lines |
| python3 in `spawned_edit` | `Edit-Spawned` (`ConvertFrom-Json -AsHashtable`) | no python on the operator machine |
| `gcloud compute ssh -- -N -L ...` for VNC | `gcloud compute start-iap-tunnel` (one per port) | no SSH client for the consoles |
| `tests/validate.sh` | + `tests/validate.ps1`, `tests/LabGcp.Tests.ps1` | parse, PSScriptAnalyzer, Pester |

## Not converted (run on the Linux lab host)

`lab` engine (`lib/common.sh`, `lib/provision.sh`, `runtime/`, compose files), `deploy/gcp/remote-deploy.sh`,
`deploy/gcp/vm-check.sh`, `deploy/gcp/artifacts.sh` (uses the VM service account), `terraform/vms/startup.sh`,
`tests/run-tcs.sh`, `tests/e2e-fakeguest.sh`, guest scripts (Windows PowerShell 5.1 in the lab VMs).

## Design

- Remote commands are sent base64-encoded (`echo B64 | base64 -d > tmp; bash tmp`): no local shell
  (cmd.exe in `gcloud.cmd`, pwsh) changes quotes, pipes, `$` or `&&`.
- `push` sends a git bundle; the VM checks it out on Linux, so scripts have LF. `vm-check.sh` is
  converted to LF before `scp`. `.gitattributes` keeps LF in every checkout.
- `scp` runs from the file's folder with a relative name, because gcloud reads `C:\x` as `INSTANCE:PATH`.
