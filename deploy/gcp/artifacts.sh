#!/usr/bin/env bash
# Runs ON a lab VM. Moves build artifacts between the lab directory and the shared bucket.
#   artifacts.sh status                  show the bucket manifest
#   artifacts.sh fetch [--checkpoints]   download what exists (verify SHA-256), skip what is present
#   artifacts.sh publish ITEM...         upload: iso base key image checkpoints (or: all)
#   artifacts.sh key push|fetch|check    lab SSH key <-> Secret Manager (check: same as the latest version?)
# Bucket layout (gs://BUCKET/sql-ag-lab/):
#   manifest.tsv                         one line per item: name  object  sha256  bytes  meta
#   media/<iso>  base/disk.qcow2  runtime/vm-image.tar.zst
#   checkpoints/checkpoints.tar.zst      all checkpoints (they form a chain on top of base)
# The lab SSH private key is NOT in the bucket: it is the Secret Manager secret sqlag-lab-ssh-key
# (manifest line "key" = secretmanager:SECRET/VERSION and the SHA-256 of the private key file).
# The VM service account reads; only publisher VMs (or publishers' own credentials) can write.
set -Eeuo pipefail
LAB_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$LAB_ROOT"
# shellcheck source=lib/common.sh
source lib/common.sh
load_env
# shellcheck disable=SC1091  # written by the startup script
[[ -f /etc/sql-ag-lab/gcp.env ]] && source /etc/sql-ag-lab/gcp.env
BUCKET=${LAB_GCP_BUCKET:?no bucket: /etc/sql-ag-lab/gcp.env missing (startup script) and LAB_GCP_BUCKET unset}
PREFIX="gs://$BUCKET/sql-ag-lab"
KEY_SECRET=${LAB_GCP_KEY_SECRET:-sqlag-lab-ssh-key}
SQL_ISO_URL=https://download.microsoft.com/download/dea8c210-c44a-4a9d-9d80-0c81578860c5/ENU/SQLServer2025-x64-ENU-EntDev.iso
SQL_ISO_SHA256=f78f869d44e8c2cbf93be16ce6ea52dd811636f046ded29e7a74dd1352134851
TMP="$LAB_IMAGES_DIR/.artifacts-tmp"; mkdir -p "$TMP"
MAN="$TMP/manifest.tsv"
command -v gcloud >/dev/null || die "gcloud CLI missing on this VM (Google images include it)"

get_manifest() { gcloud storage cat "$PREFIX/manifest.tsv" > "$MAN" 2>/dev/null || : > "$MAN"; }
man_field() { awk -F'\t' -v n="$1" -v f="$2" '$1 == n {print $f}' "$MAN"; }   # name field#
put_manifest_line() { # name object sha bytes meta
  get_manifest
  { awk -F'\t' -v n="$1" '$1 != n' "$MAN"; printf '%s\t%s\t%s\t%s\t%s\n' "$@"; } > "$MAN.new"
  gcloud storage cp -q "$MAN.new" "$PREFIX/manifest.tsv"
}
host_meta() { printf 'commit=%s;cpu_model=%s;machine=%s;cpu=%s;fp=%s' "$(git rev-parse --short HEAD 2>/dev/null || echo -)" \
  "$LAB_CPU_MODEL" "${LAB_GCP_MACHINE_TYPE:-?}" "$(awk -F': ' '/model name/ {gsub(/ /,"_",$2); print $2; exit}' /proc/cpuinfo)" "$(vm_fingerprint)"; }
upload() { # name localfile object
  local sha bytes; log "hashing $2"; sha=$(sha256sum "$2" | cut -d' ' -f1); bytes=$(stat -c %s "$2")
  log "uploading $1 ($(( bytes / 1048576 )) MiB) -> $PREFIX/$3"
  gcloud storage cp -q "$2" "$PREFIX/$3"
  put_manifest_line "$1" "$3" "$sha" "$bytes" "$(host_meta)"; ok "published $1 sha256=${sha:0:16}"
}
download() { # name localfile -> 0 when fetched+verified, 1 when absent in bucket
  local obj sha; obj=$(man_field "$1" 2); sha=$(man_field "$1" 3)
  [[ -n $obj ]] || return 1
  log "downloading $1 <- $PREFIX/$obj"
  gcloud storage cp -q "$PREFIX/$obj" "$2.part"
  echo "$sha  $2.part" | sha256sum -c --quiet - || { rm -f "$2.part"; die "$1: SHA-256 mismatch"; }
  mv "$2.part" "$2"; ok "fetched $1 (sha256 ok)"
}

pub_iso() { upload iso "$LAB_MEDIA_DIR/$LAB_SQL_ISO" "media/$LAB_SQL_ISO"; }
pub_base() { upload base "$LAB_IMAGES_DIR/base/disk.qcow2" base/disk.qcow2; }
# ------------------------------------------------------- lab SSH key (Secret Manager) --
sm_account() { gcloud config get account 2>/dev/null || echo "the VM service account"; }
sm_fail() { # stderr-file action
  if grep -qiE 'PERMISSION_DENIED|403|does not have permission' "$1"; then
    die "no permission to $2 secret $KEY_SECRET as $(sm_account). Grant it in deploy/gcp/terraform/shared/terraform.tfvars, then ./lab gcp apply shared --yes:
      read (roles/secretmanager.secretAccessor): VM service accounts and team_members have it; add other principals to lab_key_readers
      add versions (roles/secretmanager.secretVersionAdder): publisher VMs and publishers"
  elif grep -qiE 'NOT_FOUND|not found' "$1"; then
    die "secret $KEY_SECRET (or a version of it) not found: run ./lab gcp apply shared, then ./lab gcp key push VM from the host that built the base image"
  else cat "$1" >&2; die "Secret Manager: $2 $KEY_SECRET failed"; fi
}
key_latest() { # -> file with the latest key version (mode 600); returns the version number on stdout
  local err="$TMP/sm.err" ver
  ver=$(gcloud secrets versions describe latest --secret "$KEY_SECRET" --format='value(name.basename())' 2>"$err") || sm_fail "$err" read
  ( umask 077; gcloud secrets versions access "$ver" --secret "$KEY_SECRET" > "$1" 2>"$err" ) || { rm -f "$1"; sm_fail "$err" read; }
  [[ -s $1 ]] && grep -q 'PRIVATE KEY' "$1" || { rm -f "$1"; die "secret $KEY_SECRET version $ver is not an SSH private key"; }
  echo "$ver"
}
pub_key() {
  [[ -f $SSH_KEY ]] || die "no lab SSH key at $SSH_KEY (./lab init makes it; build-base bakes its public key into the base image)"
  local err="$TMP/sm.err" ver sha
  ver=$(gcloud secrets versions add "$KEY_SECRET" --data-file="$SSH_KEY" --format='value(name.basename())' 2>"$err") || sm_fail "$err" "add a version to"
  sha=$(sha256sum "$SSH_KEY" | cut -d' ' -f1)
  put_manifest_line key "secretmanager:$KEY_SECRET/$ver" "$sha" "$(stat -c %s "$SSH_KEY")" "$(host_meta)"
  ok "lab SSH key published: secret $KEY_SECRET version $ver (sha256=${sha:0:16})"
}
fetch_key() { # [--force]: write secrets/id_ed25519(.pub) from the latest version
  local f="$TMP/id_ed25519.sm" ver; ver=$(key_latest "$f")
  if [[ -f $SSH_KEY ]] && ! cmp -s "$f" "$SSH_KEY"; then
    [[ ${1:-} == --force ]] || { rm -f "$f"; die "the local lab key $SSH_KEY differs from secret $KEY_SECRET version $ver. The base image, checkpoints and golden snapshots accept only the key they were built with. Use --force to replace the local key"; }
    warn "replacing the local lab key with secret $KEY_SECRET version $ver (--force)"
  fi
  mkdir -p "$(dirname "$SSH_KEY")"; install -m 600 "$f" "$SSH_KEY"; rm -f "$f"
  ssh-keygen -y -f "$SSH_KEY" > "$SSH_KEY.pub"; chmod 644 "$SSH_KEY.pub"
  local want; get_manifest; want=$(man_field key 3)
  [[ -z $want || $want == "$(sha256sum "$SSH_KEY" | cut -d' ' -f1)" ]] || warn "the key differs from the manifest entry (published from another host?)"
  ok "lab SSH key from Secret Manager: $KEY_SECRET version $ver"
}
check_key() {
  local f="$TMP/id_ed25519.sm" ver; ver=$(key_latest "$f")
  [[ -f $SSH_KEY ]] || { rm -f "$f"; die "no local lab key: ./lab gcp fetch VM (or artifacts.sh key fetch)"; }
  if cmp -s "$f" "$SSH_KEY"; then rm -f "$f"; ok "local lab key = secret $KEY_SECRET version $ver"
  else rm -f "$f"; die "local lab key differs from secret $KEY_SECRET version $ver"; fi
}
pub_image() { log "saving runtime image $LAB_IMAGE"; $DOCKER save "$LAB_IMAGE" | zstd -q -T0 -3 -f -o "$TMP/vm-image.tar.zst"; upload image "$TMP/vm-image.tar.zst" runtime/vm-image.tar.zst; }
pub_checkpoints() {
  [[ -z "$($DOCKER ps -q -f name='^lab-sql1$')" ]] || die "run ./lab down first (checkpoints must not change while archived)"
  [[ -d "$LAB_IMAGES_DIR/checkpoints" ]] || die "no checkpoints"
  log "archiving checkpoints (sparse, zstd)"
  # state.bin files are written by QEMU as root: read them with sudo when possible (fast), else
  # inside the runtime image (root, read-only mount; slower, the stream goes through dockerd)
  local tarcmd=(tar -C "$LAB_IMAGES_DIR" -S -cf - checkpoints)
  if ! sudo -n true 2>/dev/null; then
    # shellcheck disable=SC2206  # DOCKER may be "sudo docker": split on purpose
    tarcmd=($DOCKER run --rm -v "$LAB_IMAGES_DIR:/images:ro" --entrypoint tar "$LAB_IMAGE" -C /images -S -cf - checkpoints)
  else tarcmd=(sudo -n "${tarcmd[@]}"); fi
  "${tarcmd[@]}" | zstd -q -T0 -3 -f -o "$TMP/checkpoints.tar.zst"
  upload checkpoints "$TMP/checkpoints.tar.zst" checkpoints/checkpoints.tar.zst
}

cmd_status() {
  get_manifest
  if [[ -s $MAN ]]; then
    printf '%-12s %10s  %-18s %s\n' ITEM MiB SHA256 META
    awk -F'\t' '{printf "%-12s %10d  %-18s %s\n", $1, $4/1048576, substr($3,1,16), $5}' "$MAN"
  else warn "no manifest entries in $PREFIX"; fi
  # media/ objects are used by fetch even without a manifest entry (checked with the known SHA-256)
  if [[ -z $(man_field iso 2) ]]; then
    local sz; sz=$(gcloud storage ls -l "$PREFIX/media/$LAB_SQL_ISO" 2>/dev/null | awk 'NR==1{print $1}')
    [[ -n $sz ]] && printf '%-12s %10d  %-18s %s\n' iso-media $((sz/1048576)) "${SQL_ISO_SHA256:0:16}" "media/$LAB_SQL_ISO (no manifest entry; fetch verifies the known SHA-256)"
  fi
  return 0
}

cmd_fetch() {
  local with_ckpt=0; [[ ${1:-} == --checkpoints ]] && with_ckpt=1
  get_manifest
  mkdir -p "$LAB_MEDIA_DIR" "$LAB_IMAGES_DIR/base"
  if [[ -f "$LAB_MEDIA_DIR/$LAB_SQL_ISO" ]]; then ok "ISO present"
  elif download iso "$LAB_MEDIA_DIR/$LAB_SQL_ISO"; then :
  elif gcloud storage cp -q "$PREFIX/media/$LAB_SQL_ISO" "$LAB_MEDIA_DIR/$LAB_SQL_ISO.part" 2>/dev/null \
       && echo "$SQL_ISO_SHA256  $LAB_MEDIA_DIR/$LAB_SQL_ISO.part" | sha256sum -c --quiet -; then
    # media/ without a manifest entry (for example after a bucket cleanup): verify with the known checksum
    mv "$LAB_MEDIA_DIR/$LAB_SQL_ISO.part" "$LAB_MEDIA_DIR/$LAB_SQL_ISO"; ok "ISO fetched from $PREFIX/media (sha256 ok)"
  else
    rm -f "$LAB_MEDIA_DIR/$LAB_SQL_ISO.part"
    log "ISO not in bucket: downloading from Microsoft"
    curl -fL -o "$LAB_MEDIA_DIR/$LAB_SQL_ISO.part" "$SQL_ISO_URL"
    echo "$SQL_ISO_SHA256  $LAB_MEDIA_DIR/$LAB_SQL_ISO.part" | sha256sum -c --quiet - || die "ISO checksum mismatch"
    mv "$LAB_MEDIA_DIR/$LAB_SQL_ISO.part" "$LAB_MEDIA_DIR/$LAB_SQL_ISO"; ok "ISO downloaded and verified"
  fi
  # The base image has the lab SSH key baked in: take both or neither.
  if [[ -f "$LAB_IMAGES_DIR/base/disk.qcow2" ]]; then ok "base image present"
  elif [[ -n $(man_field base 2) ]]; then
    fetch_key
    download base "$LAB_IMAGES_DIR/base/disk.qcow2"; chmod 0444 "$LAB_IMAGES_DIR/base/disk.qcow2"
  else log "no base image in bucket: run ./lab build-base"; fi
  if (( with_ckpt )); then
    if [[ -n $(man_field image 2) ]] && ! $DOCKER image inspect "$LAB_IMAGE" >/dev/null 2>&1; then
      download image "$TMP/vm-image.tar.zst"; zstd -q -dc "$TMP/vm-image.tar.zst" | $DOCKER load
    fi
    if [[ -n $(man_field checkpoints 2) ]]; then
      local want; want=$(man_field checkpoints 5 | sed -n 's/.*fp=\([0-9a-f]*\).*/\1/p')
      if [[ "$want" != "$(vm_fingerprint)" ]]; then
        warn "checkpoints were saved with fingerprint $want, this VM has $(vm_fingerprint)"
        warn "  (same runtime image, LAB_CPU_MODEL and lab.env are required; see MAKE.md G6); skipping"
      else
        download checkpoints "$TMP/checkpoints.tar.zst"
        zstd -q -dc "$TMP/checkpoints.tar.zst" | tar -C "$LAB_IMAGES_DIR" -S -xf -
        ok "checkpoints restored: $(command ls -1 "$LAB_IMAGES_DIR/checkpoints" | tr '\n' ' ')"
      fi
    fi
  fi
  rm -f "$TMP"/*.tar "$TMP"/*.zst "$TMP"/*.sm
}

cmd_publish() {
  (( $# )) || die "usage: artifacts.sh publish iso|base|key|image|checkpoints|all ..."
  local items=("$@"); [[ $1 == all ]] && items=(iso base key image checkpoints)
  local i; for i in "${items[@]}"; do
    case $i in iso|base|key|image|checkpoints) "pub_$i" ;; *) die "unknown item $i" ;; esac
  done
  [[ " ${items[*]} " == *" base "* && " ${items[*]} " != *" key "* ]] && pub_key
  rm -f "$TMP"/*.tar "$TMP"/*.zst "$TMP"/*.sm; true
}

case ${1:-} in
  status) cmd_status ;;
  fetch) shift; cmd_fetch "$@" ;;
  key) case ${2:-} in push) pub_key ;; fetch) fetch_key "${3:-}" ;; check) check_key ;; *) die "usage: artifacts.sh key push|fetch [--force]|check" ;; esac ;;
  publish) shift; cmd_publish "$@" ;;
  *) sed -n '2,13p' "$0"; exit 2 ;;
esac
