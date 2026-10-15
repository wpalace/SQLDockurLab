# shellcheck shell=bash
# Shared helpers for ./lab. Sourced, not executed.

LAB_ROOT=${LAB_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
STATE_DIR="$LAB_ROOT/state"
SECRETS_DIR="$LAB_ROOT/secrets"
SSH_KEY="$SECRETS_DIR/id_ed25519"
# shellcheck disable=SC2034  # used by ./lab and lib/provision.sh
VMS=(DC1 SQL1 SQL2 SQL3 SQL4)
SQL_VMS=(SQL1 SQL2 SQL3 SQL4)

_c_red=$'\e[31m'; _c_grn=$'\e[32m'; _c_yel=$'\e[33m'; _c_cyn=$'\e[36m'; _c_off=$'\e[0m'
[[ -t 1 ]] || { _c_red=; _c_grn=; _c_yel=; _c_cyn=; _c_off=; }
# Progress log: when logs/progress.log exists, every log/ok/warn/error line is also appended to it
# with a timestamp, so the user can follow it with `./lab watch` (tail -F).
PROGRESS_LOG=${LAB_PROGRESS_LOG:-$LAB_ROOT/logs/progress.log}
plog() { [[ -f $PROGRESS_LOG ]] || return 0; printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*" >> "$PROGRESS_LOG" 2>/dev/null || true; }
log()  { printf '%s[lab %s]%s %s\n' "$_c_cyn" "$(date +%H:%M:%S)" "$_c_off" "$*"; plog "$*"; }
ok()   { printf '%s  ok%s  %s\n' "$_c_grn" "$_c_off" "$*"; plog "  ok   $*"; }
warn() { printf '%s  warn%s %s\n' "$_c_yel" "$_c_off" "$*" >&2; plog "  WARN $*"; }
die()  { printf '%s  error%s %s\n' "$_c_red" "$_c_off" "$*" >&2; plog "  ERROR $*"; exit 1; }
now_ms() { date +%s%3N; }
elapsed() { local t0=$1; local ms=$(( $(now_ms) - t0 )); printf '%d.%01ds' $((ms / 1000)) $(((ms % 1000) / 100)); }

load_env() {
  local envfile=${LAB_ENV_FILE:-$LAB_ROOT/lab.env}
  [[ -f "$envfile" ]] || die "missing $envfile"
  set -a
  # shellcheck disable=SC1090
  source "$envfile"
  # Optional per-host overrides (gitignored), e.g. LAB_CPU_MODEL written by the GCP target.
  # shellcheck disable=SC1091
  [[ -f "$LAB_ROOT/lab.local.env" ]] && source "$LAB_ROOT/lab.local.env"
  set +a
  LAB_ENV_FILE=$envfile
  # Compose resolves relative paths against the compose file's directory; make them absolute.
  for v in LAB_IMAGES_DIR LAB_MEDIA_DIR; do
    local p=${!v}
    [[ "$p" == /* ]] || p="$LAB_ROOT/${p#./}"
    printf -v "$v" '%s' "$p"; export "${v?}"
  done
  export LAB_ENV_FILE
  mkdir -p "$STATE_DIR/logs"
  DOCKER=${DOCKER:-docker}
  # shellcheck disable=SC2034
  if [[ $EUID -eq 0 ]]; then SUDO=; else SUDO="sudo -n"; fi
}

compose() {
  local files=(-f "$LAB_ROOT/compose.yml")
  # vhost-net = in-kernel virtio-net backend (much lower network latency); optional.
  [[ -c /dev/vhost-net ]] && files+=(-f "$LAB_ROOT/compose.vhost.yml")
  $DOCKER compose "${files[@]}" --env-file "$LAB_ENV_FILE" "$@"
}

vm_lc() { printf '%s' "${1,,}"; }
vm_container() { printf 'lab-%s' "$(vm_lc "$1")"; }
vm_ip() { local v="${1^^}_IP"; printf '%s' "${!v}"; }

# Run a tool inside the runtime image with the images dir mounted at /images
# (qemu-img, mv, chmod on root-owned files, without needing host qemu-utils or sudo).
in_tool() { $DOCKER run --rm --entrypoint "" -v "$LAB_IMAGES_DIR:/images" "$LAB_IMAGE" "$@"; }

qmp() { # <VM> <args...>
  $DOCKER exec "$(vm_container "$1")" python3 /opt/lab/qmp.py /run/lab/qmp.sock "${@:2}"
}

# Run "$@" for each VM in parallel: fn VM. Logs to state/logs/<action>-<vm>.log, prefixes output.
parallel_vms() { # <action-name> <fn> <vm...>
  local action=$1 fn=$2; shift 2
  local -A pids=(); local vm rc=0
  for vm in "$@"; do
    ( set -o pipefail; "$fn" "$vm" 2>&1 | tee "$STATE_DIR/logs/$action-$vm.log" | sed -u "s/^/[$vm] /" ) &
    pids[$vm]=$!
  done
  for vm in "$@"; do
    if ! wait "${pids[$vm]}"; then warn "$action failed on $vm (see state/logs/$action-$vm.log)"; rc=1; fi
  done
  return $rc
}

# ------------------------------------------------------------------------- ssh --
SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
          -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=6 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
# shellcheck disable=SC2029  # remote command is built locally on purpose
gssh() { # <VM> <remote powershell command string>
  ssh "${SSH_OPTS[@]}" "Administrator@$(vm_ip "$1")" "$2"
}
# Run a PowerShell snippet via -EncodedCommand (no quoting problems).
gps() { # <VM> <powershell code>
  local enc
  enc=$(printf '%s' "\$ProgressPreference='SilentlyContinue'; $2" | iconv -f utf-8 -t utf-16le | base64 -w0)
  gssh "$1" "powershell.exe -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand $enc"
}
# Run a guest script from C:\Lab\guest; propagates its exit code.
grun() { # <VM> <Script.ps1> [args...]
  local vm=$1 script=$2; shift 2
  local a args=""
  for a in "$@"; do args+=" '${a//\'/\'\'}'"; done
  gssh "$vm" "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\\Lab\\guest\\$script$args; exit \$LASTEXITCODE"
}
gpush() { # <VM>  upload guest scripts + generated config
  gps "$1" 'New-Item -ItemType Directory -Force -Path C:\Lab\guest, C:\Lab\logs | Out-Null' >/dev/null
  scp -q "${SSH_OPTS[@]}" "$LAB_ROOT"/guest/*.ps1 "$STATE_DIR/lab-config.json" "Administrator@$(vm_ip "$1"):C:/Lab/guest/"
}
ssh_ready() { gssh "$1" 'exit 0' >/dev/null 2>&1; }
wait_ssh() { # <VM> [timeout_s]
  local vm=$1 t=${2:-1800} t0=$SECONDS
  until ssh_ready "$vm"; do
    (( SECONDS - t0 > t )) && { warn "$vm: SSH not reachable after ${t}s"; return 1; }
    sleep 5
  done
}
boot_id() { gps "$1" '(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString("o")' 2>/dev/null | tr -d '\r'; }
reboot_wait() { # <VM>
  local vm=$1 before after t0=$SECONDS
  before=$(boot_id "$vm")
  log "$vm: rebooting"
  gps "$vm" 'Restart-Computer -Force' >/dev/null 2>&1 || true
  sleep 15
  while :; do
    after=$(boot_id "$vm" || true)
    [[ -n "$after" && "$after" != "$before" ]] && break
    (( SECONDS - t0 > 1800 )) && { warn "$vm did not come back after reboot"; return 1; }
    sleep 5
  done
  ok "$vm back after $((SECONDS - t0))s"
}
# Run a guest script; reboot+wait when it exits 3010; fail otherwise. (ssh truncates exit codes to 8 bits: 3010 arrives as 194)
gstep() { # <VM> <Script.ps1> [args...]
  local vm=$1 rc=0
  log "$vm: ${*:2}"
  # Right after a restore a busy guest can miss the host's first ARP probes; make sure
  # SSH answers before running a step (ConnectionAttempts covers the rest).
  wait_ssh "$vm" 120 || true
  grun "$@" || rc=$?
  case $rc in
    0) return 0 ;;
    3010|194) reboot_wait "$vm" ;;
    *) warn "$vm: ${2} exited $rc"; return "$rc" ;;
  esac
}

# --------------------------------------------------------------- tcp probing --
tcp_ok() { timeout "${3:-1}" bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }

# ------------------------------------------------------------- guest config --
write_guest_config() {
  local f="$STATE_DIR/lab-config.json" nodes="" reps="" vm entry name mode fo
  for vm in "${SQL_VMS[@]}"; do
    nodes+="${nodes:+,}{\"name\":\"$vm\",\"ip\":\"$(vm_ip "$vm")\"}"
  done
  for entry in $LAB_AG_MODES; do
    IFS=: read -r name mode fo <<<"$entry"
    reps+="${reps:+,}{\"name\":\"$name\",\"availabilityMode\":\"$mode\",\"failoverMode\":\"$fo\"}"
  done
  local pw=${LAB_PASSWORD//\\/\\\\}; pw=${pw//\"/\\\"}
  cat > "$f" <<JSON
{
  "domain": "$LAB_DOMAIN", "netbios": "$LAB_NETBIOS", "password": "$pw",
  "sqlServiceUser": "$LAB_SQL_SVC_USER", "sqlPid": "22222-00000-00000-00000-00000",
  "sqlMaxMemoryMb": $SQL_MAX_MEMORY_MB, "sqlMinMemoryMb": $SQL_MIN_MEMORY_MB,
  "dcName": "DC1", "dcIp": "$DC1_IP",
  "netA": "$LAB_NET_A", "netB": "$LAB_NET_B", "netmask": "$(prefix_to_mask "$LAB_PREFIX")",
  "clusterName": "$LAB_CLUSTER_NAME", "clusterIpA": "$LAB_CLUSTER_IP_A", "clusterIpB": "$LAB_CLUSTER_IP_B",
  "sameSubnetThreshold": $LAB_SAME_SUBNET_THRESHOLD, "crossSubnetThreshold": $LAB_CROSS_SUBNET_THRESHOLD,
  "agName": "$LAB_AG_NAME", "agDatabase": "$LAB_AG_DATABASE",
  "listenerName": "$LAB_LISTENER_NAME", "listenerIpA": "$LAB_LISTENER_IP_A", "listenerIpB": "$LAB_LISTENER_IP_B",
  "listenerPort": $LAB_LISTENER_PORT,
  "nodes": [$nodes],
  "replicas": [$reps]
}
JSON
}
prefix_to_mask() {
  local p=$1 m="" o
  for _ in 1 2 3 4; do
    if (( p >= 8 )); then o=255; p=$((p - 8)); else o=$(( 256 - 2 ** (8 - p) )); (( o == 256 )) && o=0; p=0; fi
    m+="${m:+.}$o"
  done
  printf '%s' "$m"
}

# Fingerprint of everything baked into a memory-state checkpoint. If it changes, a
# checkpoint cannot be restored (the QEMU device model / RAM layout would differ).
vm_fingerprint() {
  printf '%s|' "$LAB_CPU_MODEL" "$DC1_RAM_MB" "$DC1_CPUS" "$SQL_RAM_MB" "$SQL_CPUS" \
    "$DC1_MAC" "$SQL1_MAC" "$SQL2_MAC" "$SQL3_MAC" "$SQL4_MAC" \
    "$DC1_IP" "$SQL1_IP" "$SQL2_IP" "$SQL3_IP" "$SQL4_IP" "$LAB_NET_A_ROUTER" "$LAB_NET_B_ROUTER" \
    "$($DOCKER image inspect -f '{{.Id}}' "$LAB_IMAGE" 2>/dev/null)" | sha256sum | cut -c1-16
}
