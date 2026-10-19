# shellcheck shell=bash
# Consumer interface of the lab (docs/CONSUMERS.md): version, status --json, inventory, password,
# media. Sourced by ./lab, not executed. Output on stdout is machine-readable; messages go to stderr.
# Exit codes: 0 success, 1 failure, 2 usage error.

# Contract version of this interface. Minor: backward-compatible additions. Major: breaking change.
readonly LAB_CONTRACT_VERSION="1.0"
readonly LAB_TOOLS_IMAGE="sql-ag-lab/tools:latest"

usage_error() {
  printf '  error %s\n' "$*" >&2
  plog "  ERROR $*"
  exit 2
}

# JSON string literal (the lab config holds plain names, IPs and paths; escape \ and ").
json_str() {
  local s=${1//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}

lab_version() {
  local v
  v=$(tr -d '[:space:]' <"$LAB_ROOT/VERSION" 2>/dev/null || true)
  printf '%s' "${v:-0.0.0}"
}

lab_commit() {
  git -C "$LAB_ROOT" rev-parse --short=12 HEAD 2>/dev/null || printf 'unknown'
}

lab_dirty() {
  if [[ -n "$(git -C "$LAB_ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
    printf 'true'
  else
    printf 'false'
  fi
}

cmd_version() {
  local fmt=text
  case "${1:-}" in
    --json) fmt=json ;;
    "") ;;
    *) usage_error "usage: ./lab version [--json]" ;;
  esac
  if [[ $fmt == json ]]; then
    printf '{"name":"sql-ag-lab","version":%s,"contract":%s,"commit":%s,"dirty":%s}\n' \
      "$(json_str "$(lab_version)")" "$(json_str "$LAB_CONTRACT_VERSION")" \
      "$(json_str "$(lab_commit)")" "$(lab_dirty)"
  else
    printf 'sql-ag-lab %s (contract %s, commit %s)\n' \
      "$(lab_version)" "$LAB_CONTRACT_VERSION" "$(lab_commit)"
  fi
}

# Unreachable endpoints of the fast TCP probe, one per line (empty output = all reachable).
lab_tcp_failures() {
  local a
  tcp_ok "$DC1_IP" 389 || echo "DC1:389"
  for a in "${SQL_VMS[@]}"; do tcp_ok "$(vm_ip "$a")" 1433 || echo "$a:1433"; done
  if ! tcp_ok "$LAB_LISTENER_IP_A" "$LAB_LISTENER_PORT" \
    && ! tcp_ok "$LAB_LISTENER_IP_B" "$LAB_LISTENER_PORT"; then
    [[ "$(cat "$STATE_DIR/active_checkpoint" 2>/dev/null)" =~ ^(sql-standalone|cluster)$ ]] \
      || echo "listener"
  fi
  return 0
}

lab_checkpoint_names() {
  local d
  for d in "$LAB_IMAGES_DIR"/checkpoints/*/; do
    [[ -f "$d/meta.env" ]] && basename "$d"
  done
  return 0
}

json_array() { # json_array ITEM... -> ["a","b"]
  local out="" i
  for i in "$@"; do out+="${out:+,}$(json_str "$i")"; done
  printf '[%s]' "$out"
}

cmd_status_json() {
  local -A cstate=()
  local name st vm vms="" vmst n_run=0 n_pause=0 n_absent=0 state
  while read -r name st; do
    [[ -n $name ]] && cstate[$name]=$st
  done < <($DOCKER ps -a --filter name='^lab-' --format '{{.Names}} {{.State}}' 2>/dev/null)
  for vm in "${VMS[@]}"; do
    st=${cstate[$(vm_container "$vm")]:-absent}
    vmst="not running"
    [[ $st == running ]] && vmst=$(qmp "$vm" status 2>/dev/null || echo "not running")
    case $vmst in running) ((++n_run)) ;; paused) ((++n_pause)) ;; esac
    [[ $st == absent ]] && ((++n_absent))
    vms+="${vms:+,}{\"name\":$(json_str "$vm"),\"ip\":$(json_str "$(vm_ip "$vm")")"
    vms+=",\"container\":$(json_str "$st"),\"vm\":$(json_str "$vmst")}"
  done
  if ((n_run == ${#VMS[@]})); then
    state=running
  elif ((n_absent == ${#VMS[@]})); then
    state=stopped
  elif ((n_pause == ${#VMS[@]})); then
    state=paused
  else
    state=partial
  fi
  local ckpt=null fails=() tcp=skipped healthy=false
  [[ -f "$STATE_DIR/active_checkpoint" && $state != stopped ]] \
    && ckpt=$(json_str "$(cat "$STATE_DIR/active_checkpoint")")
  if [[ $state == running ]]; then
    mapfile -t fails < <(lab_tcp_failures)
    if ((${#fails[@]} == 0)); then
      tcp=ok
      healthy=true
    else
      tcp=failed
    fi
  fi
  local ckpts
  mapfile -t ckpts < <(lab_checkpoint_names)
  printf '{"contract":%s,"state":%s,"checkpoint":%s,"healthy":%s,' \
    "$(json_str "$LAB_CONTRACT_VERSION")" "$(json_str "$state")" "$ckpt" "$healthy"
  printf '"health":{"tcp":%s,"unreachable":%s},"checkpoints":%s,"vms":[%s]}\n' \
    "$(json_str "$tcp")" "$(json_array "${fails[@]}")" "$(json_array "${ckpts[@]}")" "$vms"
}

# Replica settings from LAB_AG_MODES: lab_replica_field VM FIELD(2=availability, 3=failover).
lab_replica_field() {
  local entry name mode fo
  for entry in $LAB_AG_MODES; do
    IFS=: read -r name mode fo <<<"$entry"
    if [[ ${name^^} == "${1^^}" ]]; then
      if [[ $2 == 2 ]]; then printf '%s' "$mode"; else printf '%s' "$fo"; fi
      return 0
    fi
  done
  return 1
}

# The configured (initial) primary: the first replica in LAB_AG_MODES. The AG is created there and
# every checkpoint is saved with it as primary. The current primary can differ: query the AG.
lab_preferred_primary() {
  local first=${LAB_AG_MODES%% *}
  printf '%s' "${first%%:*}"
}

# Docker network of a VM: lab_a or lab_b, from its subnet.
vm_network() {
  local ip
  ip=$(vm_ip "$1")
  if [[ ${ip%.*} == "${LAB_NET_A_HOST%.*}" ]]; then printf 'lab_a'; else printf 'lab_b'; fi
}

inventory_json() {
  local hosts="" vm ports roles sql=""
  for vm in "${VMS[@]}"; do
    if [[ $vm == DC1 ]]; then
      roles='["domain_controller"]'
      ports='{"ssh":22,"winrm":5985,"ldap":389}'
      sql=""
    else
      roles='["sql","ag_replica"]'
      ports="{\"ssh\":22,\"winrm\":5985,\"sql\":1433}"
      sql=",\"sql\":{\"instance\":\"MSSQLSERVER\""
      sql+=",\"availability_mode\":$(json_str "$(lab_replica_field "$vm" 2)")"
      sql+=",\"failover_mode\":$(json_str "$(lab_replica_field "$vm" 3)")}"
    fi
    hosts+="${hosts:+,}{\"name\":$(json_str "$vm"),\"fqdn\":$(json_str "$vm.$LAB_DOMAIN")"
    hosts+=",\"ip\":$(json_str "$(vm_ip "$vm")"),\"network\":$(json_str "$(vm_network "$vm")")"
    hosts+=",\"roles\":$roles,\"ports\":$ports$sql}"
  done
  local nets
  nets="{\"name\":\"lab_a\",\"subnet\":$(json_str "$LAB_NET_A"),\"host\":$(json_str "$LAB_NET_A_HOST")"
  nets+=",\"router\":$(json_str "$LAB_NET_A_ROUTER")}"
  nets+=",{\"name\":\"lab_b\",\"subnet\":$(json_str "$LAB_NET_B"),\"host\":$(json_str "$LAB_NET_B_HOST")"
  nets+=",\"router\":$(json_str "$LAB_NET_B_ROUTER")}"
  printf '{"contract":%s,"lab":{"name":"sql-ag-lab","version":%s},' \
    "$(json_str "$LAB_CONTRACT_VERSION")" "$(json_str "$(lab_version)")"
  printf '"domain":{"fqdn":%s,"netbios":%s,"dc":"DC1"},' \
    "$(json_str "$LAB_DOMAIN")" "$(json_str "$LAB_NETBIOS")"
  printf '"credentials":{"windows_user":%s,"sql_user":"sa","password_env":"LAB_PASSWORD",' \
    "$(json_str "$LAB_NETBIOS\\Administrator")"
  printf '"password_command":"lab password"},'
  printf '"access":{"winrm":{"scheme":"http","port":5985,"transport":"ntlm"},"ssh":{"port":22}},'
  printf '"networks":[%s],"hosts":[%s],' "$nets" "$hosts"
  printf '"cluster":{"name":%s,"ips":%s},' "$(json_str "$LAB_CLUSTER_NAME")" \
    "$(json_array "$LAB_CLUSTER_IP_A" "$LAB_CLUSTER_IP_B")"
  printf '"ag":{"name":%s,"database":%s,"preferred_primary":%s,' "$(json_str "$LAB_AG_NAME")" \
    "$(json_str "$LAB_AG_DATABASE")" "$(json_str "$(lab_preferred_primary)")"
  printf '"listener":{"name":%s,"fqdn":%s,"ips":%s,"port":%s}},' \
    "$(json_str "$LAB_LISTENER_NAME")" "$(json_str "$LAB_LISTENER_NAME.$LAB_DOMAIN")" \
    "$(json_array "$LAB_LISTENER_IP_A" "$LAB_LISTENER_IP_B")" "$LAB_LISTENER_PORT"
  printf '"media":{"dir":%s,"cache":%s}}\n' "$(json_str "$LAB_MEDIA_DIR")" \
    "$(json_str "$(media_cache_dir)")"
}

yaml_list() { # yaml_list ITEM... -> [a, b]  (plain scalars: names and IPs only)
  local out="" i
  for i in "$@"; do out+="${out:+, }$i"; done
  printf '[%s]' "$out"
}

inventory_ansible() {
  local vm
  cat <<YAML
---
# Generated by sql-ag-lab: ./lab inventory --format ansible (contract $LAB_CONTRACT_VERSION).
# Contains no secrets: lab_password reads the LAB_PASSWORD environment variable by default.
all:
  vars:
    lab_contract: "$LAB_CONTRACT_VERSION"
    lab_version: "$(lab_version)"
    lab_domain: $LAB_DOMAIN
    lab_netbios: $LAB_NETBIOS
    lab_dc: DC1
    lab_cluster_name: $LAB_CLUSTER_NAME
    lab_ag_name: $LAB_AG_NAME
    lab_ag_database: $LAB_AG_DATABASE
    lab_ag_preferred_primary: $(lab_preferred_primary)
    lab_listener_name: $LAB_LISTENER_NAME
    lab_listener_fqdn: $LAB_LISTENER_NAME.$LAB_DOMAIN
    lab_listener_ips: $(yaml_list "$LAB_LISTENER_IP_A" "$LAB_LISTENER_IP_B")
    lab_listener_port: $LAB_LISTENER_PORT
    lab_docker_networks: [lab_a, lab_b]
    lab_password: "{{ lookup('ansible.builtin.env', 'LAB_PASSWORD') }}"
    ansible_connection: winrm
    ansible_port: 5985
    ansible_winrm_scheme: http
    ansible_winrm_transport: ntlm
    ansible_user: '$LAB_NETBIOS\\Administrator'
    ansible_password: "{{ lab_password }}"
  children:
    lab_dc:
      hosts:
        DC1:
          ansible_host: $DC1_IP
          lab_fqdn: DC1.$LAB_DOMAIN
          lab_network: $(vm_network DC1)
    lab_sql:
      hosts:
YAML
  for vm in "${SQL_VMS[@]}"; do
    cat <<YAML
        $vm:
          ansible_host: $(vm_ip "$vm")
          lab_fqdn: $vm.$LAB_DOMAIN
          lab_network: $(vm_network "$vm")
          lab_sql_instance: MSSQLSERVER
          lab_ag_availability_mode: $(lab_replica_field "$vm" 2)
          lab_ag_failover_mode: $(lab_replica_field "$vm" 3)
YAML
  done
  local group mode
  for group in sync async; do
    printf '    lab_ag_%s:\n      hosts:\n' "$group"
    for vm in "${SQL_VMS[@]}"; do
      mode=$(lab_replica_field "$vm" 2)
      if [[ ($group == sync && $mode == SYNCHRONOUS_COMMIT) ||
        ($group == async && $mode == ASYNCHRONOUS_COMMIT) ]]; then
        printf '        %s: {}\n' "$vm"
      fi
    done
  done
}

cmd_inventory() {
  local fmt=json
  while (($#)); do
    case $1 in
      --format)
        fmt=${2:-}
        shift
        ;;
      --format=*) fmt=${1#--format=} ;;
      *) usage_error "usage: ./lab inventory [--format json|ansible]" ;;
    esac
    shift
  done
  case $fmt in
    json) inventory_json ;;
    ansible) inventory_ansible ;;
    *) usage_error "unknown inventory format '$fmt' (json or ansible)" ;;
  esac
}

# Prints the lab password for consumers: LAB_PASSWORD=$(./lab password). Refuses to print it to
# a terminal (shoulder surfing, screen sharing) unless --show is given.
cmd_password() {
  case "${1:-}" in
    --show | "") ;;
    *) usage_error "usage: ./lab password [--show]" ;;
  esac
  if [[ -t 1 && ${1:-} != --show ]]; then
    die "stdout is a terminal: use LAB_PASSWORD=\$(./lab password), or ./lab password --show"
  fi
  printf '%s\n' "$LAB_PASSWORD"
}

# ---------------------------------------------------------------------------------- media --
# Shared media cache for consumer payloads (installers, updates): $LAB_MEDIA_DIR/cache by default.
# The VM containers mount $LAB_MEDIA_DIR read-only at /media, so an ISO in the cache can be put
# in a VM's CD drive (QMP media change: no network transfer, no listener, no guest change).
media_cache_dir() { printf '%s' "${LAB_MEDIA_CACHE_DIR:-$LAB_MEDIA_DIR/cache}"; }

media_name_ok() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }

media_sha256() { sha256sum -- "$1" | cut -d' ' -f1; }

media_vms() { # media_vms ARG... -> VM names (all = every VM, sql = SQL1-4)
  local a
  for a in "$@"; do
    case ${a^^} in
      ALL) printf '%s\n' "${VMS[@]}" ;;
      SQL) printf '%s\n' "${SQL_VMS[@]}" ;;
      *)
        [[ " ${VMS[*]} " == *" ${a^^} "* ]] || usage_error "unknown VM '$a'"
        printf '%s\n' "${a^^}"
        ;;
    esac
  done
}

media_fetch() {
  local url="" sha="" name="" cache
  while (($#)); do
    case $1 in
      --sha256)
        sha=${2:-}
        shift
        ;;
      --name)
        name=${2:-}
        shift
        ;;
      -*) usage_error "unknown option $1" ;;
      *) url=$1 ;;
    esac
    shift
  done
  [[ -n $url && $sha =~ ^[0-9A-Fa-f]{64}$ ]] \
    || usage_error "usage: ./lab media fetch URL --sha256 HEX [--name FILE]"
  sha=${sha,,}
  name=${name:-${url##*/}}
  media_name_ok "$name" || usage_error "bad file name '$name' (use --name FILE)"
  cache=$(media_cache_dir)
  mkdir -p "$cache"
  if [[ -f "$cache/$name" ]] && [[ "$(media_sha256 "$cache/$name")" == "$sha" ]]; then
    ok "media cache: $name present (sha256 ok)" >&2
    printf '%s\n' "$sha" >"$cache/$name.sha256"
    printf '%s\n' "$cache/$name"
    return 0
  fi
  log "media cache: downloading $name" >&2
  rm -f "$cache/$name.part"
  if [[ $url == gs://* ]]; then
    gcloud storage cp -q "$url" "$cache/$name.part" >&2 || die "download failed: $url"
  else
    curl --fail --silent --show-error --location --retry 3 -o "$cache/$name.part" "$url" \
      || die "download failed: $url"
  fi
  [[ "$(media_sha256 "$cache/$name.part")" == "$sha" ]] || {
    rm -f "$cache/$name.part"
    die "sha256 mismatch for $name (download removed)"
  }
  mv -f "$cache/$name.part" "$cache/$name"
  printf '%s\n' "$sha" >"$cache/$name.sha256"
  ok "media cache: $name downloaded (sha256 ok)" >&2
  printf '%s\n' "$cache/$name"
}

ensure_tools_image() {
  $DOCKER image inspect "$LAB_TOOLS_IMAGE" >/dev/null 2>&1 && return 0
  log "building tools image $LAB_TOOLS_IMAGE" >&2
  $DOCKER build -q -t "$LAB_TOOLS_IMAGE" "$LAB_ROOT/tools" >/dev/null || die "tools image build failed"
}

# ./lab media iso NAME.iso FILE... : ISO 9660 + Joliet image of cache files, in the cache.
# Skipped when the ISO is newer than every input (use --force to rebuild).
media_iso() {
  local force=0 iso="" files=() f cache
  while (($#)); do
    case $1 in
      --force) force=1 ;;
      -*) usage_error "unknown option $1" ;;
      *) if [[ -z $iso ]]; then iso=$1; else files+=("$1"); fi ;;
    esac
    shift
  done
  [[ $iso == *.iso && ${#files[@]} -gt 0 ]] \
    || usage_error "usage: ./lab media iso NAME.iso FILE... [--force] (files from the cache)"
  media_name_ok "$iso" || usage_error "bad ISO name '$iso'"
  cache=$(media_cache_dir)
  for f in "${files[@]}"; do
    media_name_ok "$f" && [[ -f "$cache/$f" ]] || die "not in the media cache: $f"
  done
  if ((force == 0)) && [[ -f "$cache/$iso" ]]; then
    local stale=0
    for f in "${files[@]}"; do [[ "$cache/$f" -nt "$cache/$iso" ]] && stale=1; done
    if ((stale == 0)); then
      ok "media cache: $iso up to date" >&2
      printf '%s\n' "$cache/$iso"
      return 0
    fi
  fi
  ensure_tools_image
  local label=${iso%.iso}
  label=${label^^}
  label=${label//[^A-Z0-9_]/_}
  rm -f "$cache/$iso.part"
  $DOCKER run --rm -u "$(id -u):$(id -g)" -v "$cache:/work" "$LAB_TOOLS_IMAGE" \
    -as mkisofs -quiet -iso-level 3 -J -joliet-long -V "${label:0:32}" \
    -o "/work/$iso.part" "${files[@]}" >&2 || die "ISO build failed"
  mv -f "$cache/$iso.part" "$cache/$iso"
  ok "media cache: built $iso" >&2
  printf '%s\n' "$cache/$iso"
}

media_container_path() { # cache file -> path inside the VM containers (/media/...)
  local cache rel
  cache=$(media_cache_dir)
  [[ $cache == "$LAB_MEDIA_DIR"/* ]] || die "LAB_MEDIA_CACHE_DIR must be inside LAB_MEDIA_DIR to attach"
  rel=${cache#"$LAB_MEDIA_DIR"/}
  printf '/media/%s/%s' "$rel" "$1"
}

media_attach() {
  local iso=${1:-} vm vms path
  shift || true
  [[ -n $iso && $# -gt 0 ]] || usage_error "usage: ./lab media attach NAME.iso VM...|sql|all"
  media_name_ok "$iso" && [[ -f "$(media_cache_dir)/$iso" ]] || die "not in the media cache: $iso"
  mapfile -t vms < <(media_vms "$@")
  path=$(media_container_path "$iso")
  for vm in "${vms[@]}"; do
    qmp "$vm" raw "{\"execute\":\"blockdev-change-medium\",\"arguments\":{\"id\":\"cd0\",
      \"filename\":\"$path\",\"format\":\"raw\",\"read-only-mode\":\"read-only\"}}" >/dev/null \
      || die "$vm: could not insert $iso"
    ok "$vm: $iso in the CD drive" >&2
  done
}

media_eject() {
  local vm vms
  (($#)) || usage_error "usage: ./lab media eject VM...|sql|all"
  mapfile -t vms < <(media_vms "$@")
  for vm in "${vms[@]}"; do
    qmp "$vm" eject cd0 >/dev/null 2>&1 || die "$vm: eject failed"
    ok "$vm: CD drive empty" >&2
  done
}

media_list() {
  local cache f
  cache=$(media_cache_dir)
  [[ -d $cache ]] || return 0
  for f in "$cache"/*; do
    [[ -f $f && $f != *.sha256 && $f != *.part ]] || continue
    printf '%-48s %8s MB  %s\n' "$(basename "$f")" "$(($(stat -c %s "$f") / 1048576))" \
      "$(cat "$f.sha256" 2>/dev/null || echo '-')"
  done
}

cmd_media() {
  local sub=${1:-}
  shift || true
  case $sub in
    dir) media_cache_dir && echo ;;
    list) media_list ;;
    fetch) media_fetch "$@" ;;
    iso) media_iso "$@" ;;
    attach) media_attach "$@" ;;
    eject) media_eject "$@" ;;
    *) usage_error "usage: ./lab media dir|list|fetch|iso|attach|eject (docs/CONSUMERS.md)" ;;
  esac
}
