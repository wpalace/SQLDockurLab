#!/usr/bin/env bash
# GCE startup script for sql-ag-lab VMs. Runs as root at every boot; idempotent.
# Installs Docker Engine + Compose v2 (official installer), git, zstd; loads KVM/tun/vhost-net;
# enables KSM; writes /etc/sql-ag-lab/gcp.env from instance metadata; marks completion.
set -uo pipefail
exec > >(tee -a /var/log/sql-ag-lab-startup.log) 2>&1
echo "=== sql-ag-lab startup $(date -u +%FT%TZ)"
md() { curl -fsS -H 'Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/instance/$1" 2>/dev/null; }
mkdir -p /etc/sql-ag-lab /var/lib/sql-ag-lab
rm -f /var/lib/sql-ag-lab/startup.done

pkg_install() {
  if command -v apt-get >/dev/null; then DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
  elif command -v dnf >/dev/null; then dnf install -y -q "$@"
  elif command -v zypper >/dev/null; then zypper -n -q install "$@"
  else echo "no supported package manager for: $*"; return 1; fi
}
for t in git zstd curl; do command -v "$t" >/dev/null || pkg_install "$t"; done

if ! docker compose version >/dev/null 2>&1; then
  echo "installing Docker Engine + Compose v2 (get.docker.com)"
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && sh /tmp/get-docker.sh || echo "Docker install FAILED"
fi
systemctl enable --now docker || true

printf '%s\n' kvm tun vhost_net > /etc/modules-load.d/sql-ag-lab.conf
for m in kvm tun vhost_net; do modprobe "$m" || true; done
grep -q GenuineIntel /proc/cpuinfo && modprobe kvm_intel || modprobe kvm_amd || true
[[ -w /sys/kernel/mm/ksm/run ]] && echo 1 > /sys/kernel/mm/ksm/run

cat > /etc/sql-ag-lab/gcp.env <<CONF
LAB_GCP_BUCKET=$(md attributes/lab-bucket)
LAB_GCP_CPU_MODEL=$(md attributes/lab-cpu-model)
LAB_GCP_OWNER=$(md attributes/lab-owner)
LAB_GCP_NAME=$(md name)
LAB_GCP_MACHINE_TYPE=$(md machine-type | sed 's#.*/##')
CONF
chmod 0644 /etc/sql-ag-lab/gcp.env

{ date -u +%FT%TZ; docker --version 2>&1; docker compose version 2>&1; } > /var/lib/sql-ag-lab/startup.done
echo "=== sql-ag-lab startup done"
