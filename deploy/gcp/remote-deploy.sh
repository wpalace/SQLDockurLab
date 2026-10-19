#!/usr/bin/env bash
# Runs ON the lab VM (./lab gcp deploy starts it in the background). The normal local flow,
# with artifacts taken from the shared bucket when they exist:
#   lab.local.env -> fetch -> ./lab init -> build-base (if no base) -> provision (if no golden)
#   -> ./lab up -> ./lab health --deep
# Idempotent: run it again after a spot preemption or a failure; finished stages are skipped.
# Options: --checkpoints  also fetch the runtime image + checkpoints (fingerprint must match)
set -Eeuo pipefail
LAB_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$LAB_ROOT"
step() { printf '\n=== %s  %s\n' "$(date '+%F %T %Z')" "$*"; }
# shellcheck disable=SC1091  # written by the startup script
[[ -f /etc/sql-ag-lab/gcp.env ]] && source /etc/sql-ag-lab/gcp.env
mkdir -p logs
touch logs/progress.log # enables ./lab watch
if [[ -n ${LAB_GCP_CPU_MODEL:-} ]]; then
  # keep the other lines (LAB_PASSWORD from ./lab gcp push); replace only LAB_CPU_MODEL
  touch lab.local.env
  chmod 600 lab.local.env
  {
    grep -v -e '^LAB_CPU_MODEL=' -e '^# written by deploy/gcp/remote-deploy.sh' lab.local.env || true
    printf '# written by deploy/gcp/remote-deploy.sh from instance metadata\nLAB_CPU_MODEL=%s\n' "$LAB_GCP_CPU_MODEL"
  } >lab.local.env.new
  mv lab.local.env.new lab.local.env
  chmod 600 lab.local.env
fi
export LAB_WATCH=0 # no GUI on the VM: the watch terminal runs on the workstation (./lab gcp)
step "fetch artifacts"
deploy/gcp/artifacts.sh fetch "$@"
step "init"
./lab init
step "console gateway"
./lab console >/dev/null || true # noVNC on 6111-6115 for ./lab gcp tunnel
if [[ ! -f images/base/disk.qcow2 ]]; then
  # A base build interrupted by preemption cannot continue safely (the guest scripts run once
  # per phase): start it again from an empty build disk.
  if [[ -f logs/.build-base.running ]]; then
    step "previous build-base was interrupted: restarting it"
    docker rm -f lab-base-build >/dev/null 2>&1 || true
    rm -rf images/base-build
  fi
  touch logs/.build-base.running
  step "build-base (35-60 min)"
  ./lab build-base
  rm -f logs/.build-base.running
fi
# Resumable (spot preemption, failures): continue from the newest checkpoint that exists.
if [[ ! -f images/checkpoints/golden/meta.env ]]; then
  from=""
  for c in cluster sql-standalone; do [[ -f images/checkpoints/$c/meta.env ]] && {
    from=$c
    break
  }; done
  step "provision ${from:+from $from }(20-40 min)"
  ./lab provision $from
fi
step "up"
./lab up
step "health"
./lab health --deep --wait 300
step "DEPLOY COMPLETE"
