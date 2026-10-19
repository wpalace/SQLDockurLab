# Container images and pins

This page lists the container images that the lab uses and tells you how to change the pinned
installer image.

## The installer image (dockur/windows)

Stage 1 (`./lab build-base`, file `build/base/compose.yml`) uses the dockur/windows image to
install Windows Server. The image is pinned by digest in `lab.env`:

```
LAB_DOCKUR_IMAGE=docker.io/dockurr/windows@sha256:16fd7c39a3e48bb946d29c59dc6015942e5b900a1fa5d7e5552053bfc48ee2ea
```

This digest is dockur/windows 6.06 (image label `org.opencontainers.image.version=6.06`,
revision `013ea27498e0`, created 2026-10-05). The lab base image (`images/base/disk.qcow2`)
was built and tested with this image. A digest cannot change, so a new upstream release does
not change the build without a review.

The compose file has no default for `LAB_DOCKUR_IMAGE`. If the value is missing, the build stops
with an error.

### Change the pin

Do these steps on a lab host with Docker:

1. Pull the new release, and read its version and digest:

   ```
   docker pull docker.io/dockurr/windows:latest
   docker image inspect --format '{{index .RepoDigests 0}} {{index .Config.Labels "org.opencontainers.image.version"}}' docker.io/dockurr/windows:latest
   ```

2. Read the upstream release notes for that version
   (<https://github.com/dockur/windows/releases>). Make sure that the changes do not affect the
   environment variables that `build/base/compose.yml` sets (`HOST_PORTS`, `DISK_TYPE`,
   `ADAPTER`, `BOOT_MODE` and the others), and that the web viewer and VNC ports (8006, 5900) did
   not change.
3. Put the new `repository@sha256:...` value in `LAB_DOCKUR_IMAGE` in `lab.env`. Change the
   version in the comment above it and in this page.
4. Build a new base image: `./lab build-base`. Then do the tests in MAKE.md (TC1 to TC9).
5. Commit the change to `lab.env` and this page in one commit. Write the old and the new version
   in the commit message.

> **NOTE:** A new installer image makes a new base image. The checkpoints that you made from the
> old base image do not change. Make new checkpoints (`./lab provision`) after the new base build.

## Other images

| Image | Where | Pin |
| --- | --- | --- |
| `sql-ag-lab/vm:latest` | `lab.env` (`LAB_IMAGE`), `compose.yml`, the console gateway | Built locally from `runtime/Dockerfile` (`./lab image`). Not pulled from a registry. |
| `debian:trixie-slim` | `runtime/Dockerfile` | Tag only |
| `docker.io/cytopia/yamllint:latest` | `tests/standards-check.sh` | Tag only (`latest`) |
| `docker.io/hashicorp/terraform:1.13` | `tests/standards-check.sh`, `tests/validate.sh` | Minor version tag |
| `mcr.microsoft.com/dotnet/sdk:10.0` | `tests/standards-check.sh` (PowerShell checks) | Major version tag |
| shfmt, ShellCheck, hadolint, tflint, ruff | `tests/standards-check.sh` | Exact version tags |

Only the installer image is pinned by digest. It installs the Windows system that all lab VMs
start from, and the build pulls it from a registry. The runtime image is built once on the lab
host, and its inputs are frozen (a change makes all checkpoints incompatible). The other images
only run the code checks. To pin one of them, use the same procedure: read the digest with
`docker image inspect --format '{{index .RepoDigests 0}}' IMAGE` and replace the tag with
`repository@sha256:...`.
