#!/usr/bin/env bash
# =============================================================================
# sql-ag-lab VM launcher (container entrypoint).
#
# Modes (LAB_MODE):
#   boot     Cold boot from /images/work/<vm>/disk.qcow2 (created on first use as a
#            qcow2 overlay of /images/base/disk.qcow2). Used while provisioning.
#   restore  Create a throw-away overlay on top of checkpoint <LAB_CHECKPOINT>,
#            start QEMU with -incoming defer -S and load the saved RAM/device state.
#            The VM is left PAUSED; `./lab up` resumes all VMs at the same instant.
#
# The QEMU command line is generated ONLY from env vars that are part of the saved
# checkpoint contract (RAM, CPUs, MAC, SMBIOS serial, CPU model). Anything that would
# change device topology between save and restore is deliberately not configurable.
# =============================================================================
set -Eeuo pipefail

log() { printf '[%s %s] %s\n' "$(date +%H:%M:%S)" "${VM_NAME:-vm}" "$*"; }
die() { log "ERROR: $*"; exit 1; }

: "${VM_NAME:?VM_NAME required}"
: "${VM_MAC:?VM_MAC required}"
RAM_MB=${VM_RAM_MB:-4096}
CPUS=${VM_CPUS:-2}
MODE=${LAB_MODE:-restore}
CKPT=${LAB_CHECKPOINT:-golden}
CPU_MODEL=${LAB_CPU_MODEL:-host}
ACCEL=${LAB_ACCEL:-kvm}
IMAGES=${LAB_IMAGES:-/images}
QMP_SOCK=/run/lab/qmp.sock
OVMF_CODE=${LAB_OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}
OVMF_VARS=${LAB_OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}
mkdir -p /run/lab
rm -f "$QMP_SOCK"

# ---------------------------------------------------------------- networking --
# Bridge the container's eth0 (attached to a Docker bridge network, with the VM's
# static IP reserved via ipv4_address) to a tap device. The VM then *owns* that IP
# and MAC on the Docker network; extra IPs (cluster / listener) just work via ARP.
setup_net() {
  local dev=${LAB_NET_DEV:-eth0}
  ip link show "$dev" >/dev/null 2>&1 || die "network device $dev missing"
  ip link add br0 type bridge 2>/dev/null || true
  ip link set br0 type bridge stp_state 0 forward_delay 0 2>/dev/null || true
  ip tuntap add dev tap0 mode tap 2>/dev/null || true
  ip addr flush dev "$dev"
  ip link set "$dev" master br0
  ip link set tap0 master br0
  ip link set "$dev" up; ip link set tap0 up; ip link set br0 up
  log "network: $dev + tap0 bridged (VM MAC $VM_MAC)"
}

# --------------------------------------------------------------------- disks --
img_create_overlay() { # <backing> <overlay>
  qemu-img create -q -f qcow2 -F qcow2 -b "$1" "$2"
}

prepare_disks_boot() {
  ACTIVE_DIR="$IMAGES/work/$VM_NAME"
  mkdir -p "$ACTIVE_DIR"
  if [[ ! -f "$ACTIVE_DIR/disk.qcow2" ]]; then
    [[ -f "$IMAGES/base/disk.qcow2" ]] || die "base image $IMAGES/base/disk.qcow2 missing (run ./lab build-base)"
    img_create_overlay "$IMAGES/base/disk.qcow2" "$ACTIVE_DIR/disk.qcow2"
    log "created work overlay on base image"
  fi
  if [[ ! -f "$ACTIVE_DIR/vars.qcow2" ]]; then
    # UEFI vars stored as qcow2 (not raw) so the whole VM stays snapshot/migration friendly.
    qemu-img convert -q -f raw -O qcow2 "$OVMF_VARS" "$ACTIVE_DIR/vars.qcow2"
  fi
}

prepare_disks_restore() {
  local src="$IMAGES/checkpoints/$CKPT/$VM_NAME"
  [[ -f "$src/disk.qcow2" && -f "$src/vars.qcow2" && -f "$src/state.bin" ]] \
    || die "checkpoint '$CKPT' incomplete for $VM_NAME ($src)"
  ACTIVE_DIR="$IMAGES/run/$VM_NAME"
  rm -rf "$ACTIVE_DIR"; mkdir -p "$ACTIVE_DIR"
  img_create_overlay "$src/disk.qcow2" "$ACTIVE_DIR/disk.qcow2"
  img_create_overlay "$src/vars.qcow2" "$ACTIVE_DIR/vars.qcow2"
  STATE_FILE="$src/state.bin"
}

# ---------------------------------------------------------------------- qemu --
build_cmd() {
  local cache_opts="cache.direct=off,cache.no-flush=off"
  if [[ "$MODE" == restore && "${LAB_UNSAFE_CACHE:-1}" == 1 ]]; then
    cache_opts="cache.direct=off,cache.no-flush=on"
  fi
  local vhost=off
  [[ -c /dev/vhost-net ]] && vhost=on
  local cpu="$CPU_MODEL"
  if [[ "$CPU_MODEL" == host || "$CPU_MODEL" == max ]]; then
    # Migratable Hyper-V enlightenments only (no hv-passthrough / invtsc / reenlightenment).
    cpu+=",migratable=on,hv-relaxed=on,hv-vapic=on,hv-spinlocks=0x1fff,hv-time=on,hv-vpindex=on,hv-synic=on,hv-stimer=on,hv-runtime=on"
  fi
  [[ "$ACCEL" == tcg ]] && cpu="max"
  # Identity for FirstBoot.ps1: LAB;<name>;<ip>;<prefix>;<gateway>;<dns>
  local serial=${VM_SMBIOS_SERIAL:-LAB;$VM_NAME}

  # shellcheck disable=SC2054  # commas are QEMU option syntax
  QEMU=(qemu-system-x86_64
    -name "$VM_NAME,debug-threads=on"
    -nodefaults -no-user-config
    -machine "q35,accel=$ACCEL,hpet=off,pflash0=fw-code,pflash1=fw-vars"
    -cpu "$cpu"
    -smp "$CPUS,sockets=1,cores=$CPUS,threads=1"
    -m "$RAM_MB"
    -overcommit mem-lock=off
    -rtc "base=utc,clock=${LAB_RTC_CLOCK:-vm},driftfix=slew"
    -global kvm-pit.lost_tick_policy=delay
    -global ICH9-LPC.disable_s3=1 -global ICH9-LPC.disable_s4=1
    -smbios "type=1,manufacturer=sql-ag-lab,product=labvm,serial=$serial"
    -blockdev "driver=file,filename=$OVMF_CODE,node-name=fw-code-file,read-only=on"
    -blockdev "driver=raw,file=fw-code-file,node-name=fw-code,read-only=on"
    -blockdev "driver=file,filename=$ACTIVE_DIR/vars.qcow2,node-name=fw-vars-file"
    -blockdev "driver=qcow2,file=fw-vars-file,node-name=fw-vars"
    -device virtio-scsi-pci,id=scsi0
    -blockdev "driver=file,filename=$ACTIVE_DIR/disk.qcow2,node-name=disk0-file,$cache_opts,discard=unmap"
    -blockdev "driver=qcow2,file=disk0-file,node-name=disk0,discard=unmap,cache-size=16777216"
    -device scsi-hd,bus=scsi0.0,drive=disk0,id=hd0,bootindex=1,rotation_rate=1
    -netdev "tap,id=net0,ifname=tap0,script=no,downscript=no,vhost=$vhost"
    -device "virtio-net-pci,netdev=net0,mac=$VM_MAC,id=nic0"
    -device virtio-rng-pci,id=rng0
    -device virtio-balloon-pci,id=balloon0
    -device qemu-xhci,id=xhci -device usb-tablet,bus=xhci.0
    -vga std
    -vnc "0.0.0.0:0"
    -serial none -monitor none
    -qmp "unix:$QMP_SOCK,server=on,wait=off"
  )
  # The CD-ROM device ALWAYS exists (so device topology is identical in every mode);
  # media is only inserted while provisioning.
  if [[ "$MODE" == boot && -n "${VM_CDROM:-}" && -f "${VM_CDROM}" ]]; then
    QEMU+=(-blockdev "driver=file,filename=$VM_CDROM,node-name=cd0-file,read-only=on"
           -blockdev "driver=raw,file=cd0-file,node-name=cd0-media,read-only=on"
           -device "ide-cd,bus=ide.2,id=cd0,drive=cd0-media")
    log "cdrom: $VM_CDROM"
  else
    QEMU+=(-device "ide-cd,bus=ide.2,id=cd0")
  fi
  # Testing hook (validation of the pipeline without Windows; not used in the real lab).
  if [[ -n "${LAB_TEST_KERNEL:-}" ]]; then
    QEMU+=(-kernel "$LAB_TEST_KERNEL" -initrd "$LAB_TEST_INITRD" -append "${LAB_TEST_APPEND:-}")
  fi
  [[ "$MODE" == restore ]] && QEMU+=(-incoming defer -S)
  return 0
}

# ------------------------------------------------------------------- signals --
QPID=
# shellcheck disable=SC2317  # invoked via trap
on_term() {
  if [[ -n "$QPID" ]] && kill -0 "$QPID" 2>/dev/null; then
    if [[ "$MODE" == boot ]]; then
      log "SIGTERM: ACPI powerdown (boot mode)"
      python3 /opt/lab/qmp.py "$QMP_SOCK" powerdown || kill "$QPID"
      # Docker escalates to SIGKILL after stop_grace_period.
    else
      log "SIGTERM: discarding VM (restore mode)"
      kill -9 "$QPID" 2>/dev/null || true
    fi
  fi
}
trap on_term TERM INT

# ---------------------------------------------------------------------- main --
[[ "$ACCEL" != kvm || -c /dev/kvm ]] || die "/dev/kvm not available in container"
setup_net
echo "$MODE" > /run/lab/mode
# Restore mode supports in-place respawn: `./lab reset` writes the checkpoint name to
# /run/lab/respawn and kills QEMU; we then rebuild the overlay and reload the state
# without recreating the container (saves container start + network setup time).
while :; do
  rm -f /run/lab/loaded "$QMP_SOCK"
  case "$MODE" in
    boot) prepare_disks_boot ;;
    restore) prepare_disks_restore ;;
    *) die "unknown LAB_MODE=$MODE" ;;
  esac
  echo "$ACTIVE_DIR" > /run/lab/active_dir
  echo "$CKPT" > /run/lab/checkpoint
  build_cmd
  log "mode=$MODE checkpoint=$CKPT ram=${RAM_MB}M cpus=$CPUS"
  [[ "${LAB_DEBUG:-0}" == 1 ]] && log "cmd: ${QEMU[*]}"
  "${QEMU[@]}" &
  QPID=$!
  echo "$QPID" > /run/lab/qemu.pid
  if [[ "$MODE" == restore ]]; then
    python3 /opt/lab/qmp.py "$QMP_SOCK" load "$STATE_FILE" || { kill -9 "$QPID"; die "state load failed"; }
  fi
  touch /run/lab/loaded
  set +e
  while kill -0 "$QPID" 2>/dev/null; do wait "$QPID"; done
  wait "$QPID" 2>/dev/null; rc=$?
  set -e
  log "qemu exited (rc=$rc)"
  if [[ "$MODE" == restore && -s /run/lab/respawn ]]; then
    CKPT=$(cat /run/lab/respawn); rm -f /run/lab/respawn
    log "respawn requested: checkpoint=$CKPT"
    continue
  fi
  break
done
exit 0
