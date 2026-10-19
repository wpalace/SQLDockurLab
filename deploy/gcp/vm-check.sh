#!/usr/bin/env bash
# Runs ON the GCP lab VM (./lab gcp check copies and runs it). Verifies the environment the lab
# needs before anything is deployed. Exit 0 = all required checks passed.
# Options: --min-cpus N --min-ram-gb N --min-disk-gb N --min-free-gb N --no-io
set -uo pipefail # no -e on purpose: every check runs and all failures are reported
MIN_CPUS=12 MIN_RAM=40 MIN_DISK=200 MIN_FREE=150 IO=1
while (($#)); do
  case $1 in
    --min-cpus)
      MIN_CPUS=$2
      shift
      ;;
    --min-ram-gb)
      MIN_RAM=$2
      shift
      ;;
    --min-disk-gb)
      MIN_DISK=$2
      shift
      ;;
    --min-free-gb)
      MIN_FREE=$2
      shift
      ;;
    --no-io) IO=0 ;; *)
      echo "unknown option $1"
      exit 2
      ;;
  esac
  shift
done
fails=0 warns=0
ok() { printf '  ok    %s\n' "$*"; }
warn() {
  printf '  WARN  %s\n' "$*"
  warns=$((warns + 1))
}
fail() {
  printf '  FAIL  %s\n        fix: %s\n' "$1" "$2"
  fails=$((fails + 1))
}
md() { curl -fsS -m 3 -H 'Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/$1" 2>/dev/null; }

echo "== startup script"
if [[ -f /var/lib/sql-ag-lab/startup.done ]]; then
  ok "startup script completed $(head -1 /var/lib/sql-ag-lab/startup.done)"
else fail "startup script has not completed" "wait 2-5 min after boot; read: sudo tail -50 /var/log/sql-ag-lab-startup.log (or: sudo journalctl -u google-startup-scripts)"; fi

echo "== virtualization"
if grep -Eq '(vmx|svm)' /proc/cpuinfo; then
  ok "CPU flags include $(grep -Eom1 '(vmx|svm)' /proc/cpuinfo)"
else fail "no vmx/svm CPU flag: nested virtualization is not enabled" "VM needs advanced_machine_features.enable_nested_virtualization = true on an Intel series or N4D (terraform apply; the VM restarts)"; fi
if [[ -c /dev/kvm ]]; then
  ok "/dev/kvm present ($(stat -c '%G %a' /dev/kvm))"
  if [[ -r /dev/kvm && -w /dev/kvm ]] || sudo -n test -w /dev/kvm 2>/dev/null; then
    ok "/dev/kvm usable"
  else warn "/dev/kvm not writable by $USER (Docker opens it as root; optional: sudo usermod -aG kvm $USER)"; fi
else fail "/dev/kvm missing" "sudo modprobe kvm_intel (or kvm_amd); if that fails, nested virtualization is off"; fi
nested=""
for m in kvm_intel kvm_amd; do [[ -r /sys/module/$m/parameters/nested ]] && nested="$m=$(cat /sys/module/$m/parameters/nested)"; done
case $nested in *=Y | *=1) ok "nested: $nested" ;;
"") warn "no kvm_intel/kvm_amd module loaded" ;;
*) warn "$nested (needed only for L3 guests; the lab runs L2 VMs and does not need it)" ;; esac
echo "== devices"
if [[ -c /dev/net/tun ]]; then ok "/dev/net/tun"; else fail "/dev/net/tun missing" "sudo modprobe tun"; fi
if [[ -c /dev/vhost-net ]]; then ok "/dev/vhost-net"; else warn "/dev/vhost-net missing (optional): sudo modprobe vhost_net"; fi

echo "== docker"
if command -v docker >/dev/null; then
  if docker info >/dev/null 2>&1; then
    ok "docker $(docker version -f '{{.Server.Version}}' 2>/dev/null) reachable as $USER"
  elif sudo -n docker info >/dev/null 2>&1; then
    if id -nG "$USER" | grep -qw docker; then
      warn "daemon reachable only with sudo; group docker not active in this session (reconnect)"
    else fail "$USER is not in group docker" "sudo usermod -aG docker $USER, then reconnect (./lab gcp push does this)"; fi
  else fail "docker daemon not running" "sudo systemctl enable --now docker"; fi
  if docker compose version >/dev/null 2>&1 || sudo -n docker compose version >/dev/null 2>&1; then
    ok "$(docker compose version 2>/dev/null || sudo -n docker compose version)"
  else
    fail "docker compose v2 missing" "reinstall Docker Engine with the compose plugin (startup script uses get.docker.com)"
  fi
else fail "docker not installed" "check /var/log/sql-ag-lab-startup.log; rerun: sudo google_metadata_script_runner startup"; fi

echo "== size"
cpus=$(nproc)
ram=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
disk=$(df -Pk "$HOME" | awk 'NR==2 {printf "%d", $2/1024/1024}')
free=$(df -Pk "$HOME" | awk 'NR==2 {printf "%d", $4/1024/1024}')
if ((cpus >= MIN_CPUS)); then ok "vCPUs $cpus (min $MIN_CPUS)"; else fail "only $cpus vCPUs (min $MIN_CPUS)" "use a larger machine_type (default n2-standard-16)"; fi
if ((ram >= MIN_RAM)); then ok "RAM ${ram} GB (min $MIN_RAM)"; else fail "RAM ${ram} GB (min $MIN_RAM)" "use a larger machine_type"; fi
if ((disk >= MIN_DISK)); then ok "disk ${disk} GB (min $MIN_DISK)"; else fail "disk ${disk} GB (min $MIN_DISK)" "raise disk_size_gb and apply; then grow the filesystem (sudo growpart/resize2fs or reboot)"; fi
if ((free >= MIN_FREE)); then ok "free ${free} GB at $HOME (min $MIN_FREE)"; else fail "free ${free} GB (min $MIN_FREE)" "delete old checkpoints (./lab delete) or grow the disk"; fi

if ((IO)); then
  echo "== disk throughput (2 GiB write, 2 GiB read, direct I/O)"
  f="$HOME/.sqlag-io-test"
  w=$(dd if=/dev/zero of="$f" bs=4M count=512 oflag=direct conv=fsync 2>&1 | awk '/copied/ {print $(NF-1), $NF}')
  r=$(dd if="$f" of=/dev/null bs=4M iflag=direct 2>&1 | awk '/copied/ {print $(NF-1), $NF}')
  rm -f "$f"
  ok "write $w, read $r (pd-ssd 300 GB: about 140 MB/s; restores load 5-25 GB of RAM state)"
  case $r in *kB/s* | *" B/s"*) warn "disk read is very slow; restores will take minutes" ;; esac
  rv=${r%% *}
  rv=${rv%%.*}
  if [[ $r == *MB/s* ]] && ((rv < 200)); then
    warn "disk read below 200 MB/s: the FIRST restore (cold page cache, or a disk made from a snapshot, which loads blocks on first read) can exceed 180 s. fix: LAB_UP_TIMEOUT=900 ./lab up golden"
  fi
fi

echo "== bucket access (VM service account)"
bucket=$(md instance/attributes/lab-bucket)
sa=$(md instance/service-accounts/default/email)
if [[ -z $bucket ]]; then
  fail "metadata lab-bucket is empty" "set bucket_name in the vms terraform.tfvars and apply"
elif ! command -v gcloud >/dev/null; then
  warn "gcloud not installed; bucket access not tested (fetch/publish need it)"
elif gcloud storage ls "gs://$bucket/" >/dev/null 2>&1; then
  ok "gs://$bucket readable as $sa"
else fail "cannot list gs://$bucket as $sa" "shared root must grant roles/storage.objectViewer to $sa; private Google access or NAT must be on"; fi

echo "== clock"
if command -v timedatectl >/dev/null; then
  if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == yes ]]; then
    ok "clock synchronized (NTP)"
  else
    warn "clock not reported synchronized: check chronyd/systemd-timesyncd (metadata.google.internal is the NTP server)"
  fi
else warn "timedatectl missing; clock sync not checked"; fi

echo "== egress"
if curl -fsS -m 5 -o /dev/null https://download.microsoft.com; then
  ok "internet egress (download.microsoft.com)"
else
  warn "no internet egress: base build and ISO download need Cloud NAT (enable_nat) unless artifacts come from the bucket"
fi

echo
if ((fails)); then
  echo "VM CHECK FAILED: $fails failure(s), $warns warning(s)"
  exit 1
fi
echo "VM CHECK PASSED ($warns warning(s))"
