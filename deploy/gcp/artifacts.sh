#!/usr/bin/env bash
# Runs ON a lab VM. Moves build artifacts between the lab directory and the shared bucket.
#   artifacts.sh status                  show the bucket manifest
#   artifacts.sh fetch [--checkpoints]   download what exists (verify SHA-256), skip what is present
#   artifacts.sh publish ITEM...         upload: iso base key image checkpoints (or: all)
# Bucket layout (gs://BUCKET/sql-ag-lab/):
#   manifest.tsv                         one line per item: name  object  sha256  bytes  meta
#   media/<iso>  base/disk.qcow2  secrets/lab-ssh.tar  runtime/vm-image.tar.zst
#   checkpoints/checkpoints.tar.zst      all checkpoints (they form a chain on top of base)
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
pub_key() { tar -C "$LAB_ROOT" -cf "$TMP/lab-ssh.tar" secrets/id_ed25519 secrets/id_ed25519.pub; upload key "$TMP/lab-ssh.tar" secrets/lab-ssh.tar; }
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
  get_manifest; [[ -s $MAN ]] || { warn "no artifacts in $PREFIX"; return 0; }
  printf '%-12s %10s  %-18s %s\n' ITEM MiB SHA256 META
  awk -F'\t' '{printf "%-12s %10d  %-18s %s\n", $1, $4/1048576, substr($3,1,16), $5}' "$MAN"
}

cmd_fetch() {
  local with_ckpt=0; [[ ${1:-} == --checkpoints ]] && with_ckpt=1
  get_manifest
  mkdir -p "$LAB_MEDIA_DIR" "$LAB_IMAGES_DIR/base"
  if [[ -f "$LAB_MEDIA_DIR/$LAB_SQL_ISO" ]]; then ok "ISO present"
  elif ! download iso "$LAB_MEDIA_DIR/$LAB_SQL_ISO"; then
    log "ISO not in bucket: downloading from Microsoft"
    curl -fL -o "$LAB_MEDIA_DIR/$LAB_SQL_ISO.part" "$SQL_ISO_URL"
    echo "$SQL_ISO_SHA256  $LAB_MEDIA_DIR/$LAB_SQL_ISO.part" | sha256sum -c --quiet - || die "ISO checksum mismatch"
    mv "$LAB_MEDIA_DIR/$LAB_SQL_ISO.part" "$LAB_MEDIA_DIR/$LAB_SQL_ISO"; ok "ISO downloaded and verified"
  fi
  # The base image has the lab SSH key baked in: take both or neither.
  if [[ -f "$LAB_IMAGES_DIR/base/disk.qcow2" ]]; then ok "base image present"
  elif [[ -n $(man_field base 2) && -n $(man_field key 2) ]]; then
    download key "$TMP/lab-ssh.tar"; tar -C "$LAB_ROOT" -xf "$TMP/lab-ssh.tar"; chmod 600 "$SSH_KEY"
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
  rm -f "$TMP"/*.tar "$TMP"/*.zst
}

cmd_publish() {
  (( $# )) || die "usage: artifacts.sh publish iso|base|key|image|checkpoints|all ..."
  local items=("$@"); [[ $1 == all ]] && items=(iso base key image checkpoints)
  local i; for i in "${items[@]}"; do
    case $i in iso|base|key|image|checkpoints) "pub_$i" ;; *) die "unknown item $i" ;; esac
  done
  [[ " ${items[*]} " == *" base "* && " ${items[*]} " != *" key "* ]] && pub_key
  rm -f "$TMP"/*.tar "$TMP"/*.zst; true
}

case ${1:-} in
  status) cmd_status ;;
  fetch) shift; cmd_fetch "$@" ;;
  publish) shift; cmd_publish "$@" ;;
  *) sed -n '2,10p' "$0"; exit 2 ;;
esac
