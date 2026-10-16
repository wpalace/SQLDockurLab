# shellcheck shell=bash
# First-time provisioning of the lab (sourced by ./lab). Every guest script is idempotent,
# so `./lab provision` can be re-run after a failure and continues where it stopped.

prov_wait_all_ssh() {
  log "waiting for all VMs to finish first boot and answer SSH (first boot ~3-8 min)"
  local vm
  for vm in "${VMS[@]}"; do
    wait_ssh "$vm" 2700 || die "$vm unreachable; open its console: ./lab console $vm"
    ok "$vm reachable at $(vm_ip "$vm")"
  done
}

prov_push_all() { local vm; for vm in "${VMS[@]}"; do gpush "$vm" || die "upload to $vm failed"; done; ok "guest scripts uploaded"; }

_join()   { gstep "$1" Join-Domain.ps1; }
_sql()    { gstep "$1" RunAs.ps1 Install-Sql.ps1; }
_hadr()   { gstep "$1" Enable-Hadr.ps1; }
_agjoin() { gstep "$1" Join-LabAg.ps1; }
_settle() { gstep "$1" Optimize-ForSnapshot.ps1 "$2"; }
_settle_short() { _settle "$1" 30; }
_settle_long()  { _settle "$1" "$LAB_SETTLE_SECONDS"; }

prov_stage_domain_sql() {
  log "== stage 1/3: domain + standalone SQL Server instances"
  gstep DC1 Install-DomainController.ps1 || die "DC promotion failed"
  wait_ssh DC1 900 || die "DC1 did not come back"
  gpush DC1
  gstep DC1 Configure-Domain.ps1 || die "domain configuration failed"
  parallel_vms join _join "${SQL_VMS[@]}" || die "domain join failed"
  parallel_vms sqlinstall _sql "${SQL_VMS[@]}" || die "SQL Server install failed"
}

prov_stage_cluster() {
  log "== stage 2/3: two-subnet WSFC + Always On enabled"
  gstep SQL1 RunAs.ps1 New-LabCluster.ps1 || die "cluster creation failed"
  parallel_vms hadr _hadr "${SQL_VMS[@]}" || die "enabling HADR failed"
}

prov_stage_ag() {
  log "== stage 3/3: availability group + multi-subnet listener"
  gstep SQL1 RunAs.ps1 New-LabAg.ps1 || die "AG creation failed"
  parallel_vms agjoin _agjoin SQL2 SQL3 SQL4 || die "AG join failed"
  gstep SQL1 RunAs.ps1 Add-LabListener.ps1 || die "listener creation failed"
  grun SQL1 Test-Lab.ps1 -WaitSeconds 600 || die "lab is not healthy after provisioning"
  if [[ ${LAB_FAILOVER_CHAIN:-1} == 1 ]]; then
    # Validation before the golden checkpoint: planned failover to every replica and back.
    local t=$SECONDS
    log "failover chain SQL1 -> SQL2 -> SQL3 -> SQL4 -> SQL1 (heartbeat checks after each move)"
    gpush DC1 >/dev/null
    grun DC1 Invoke-LabFailover.ps1 -Chain SQL2,SQL3,SQL4,SQL1 || die "failover chain failed"
    log "failover chain OK ($((SECONDS - t)) s)"
    grun SQL1 Test-Lab.ps1 -WaitSeconds 600 || die "lab is not healthy after the failover chain"
  fi
}

# Intermediate checkpoints give automation a choice of starting states:
#   sql-standalone  domain + 4 standalone SQL instances, no cluster
#   cluster         + WSFC (2 subnets, FSW) + HADR enabled, no AG
#   golden          + AG with 4 replicas + listener (the default for ./lab up)
prov_checkpoint() { # <name> <settle-fn>
  local name=$1 settle=$2
  parallel_vms settle "$settle" "${VMS[@]}" || warn "settle step had errors (continuing)"
  cmd_save "$name" --force
}

cmd_provision() {
  local t0=$SECONDS from=${1:-}
  [[ -f "$LAB_IMAGES_DIR/base/disk.qcow2" ]] || die "no base image; run ./lab build-base first"
  cmd_log; watch_local   # live terminal (lib/watch.sh); LAB_WATCH=0 to opt out
  write_guest_config
  ensure_net
  if [[ -z "$from" ]]; then
    [[ -f "$LAB_MEDIA_DIR/$LAB_SQL_ISO" ]] || die "SQL ISO missing: $LAB_MEDIA_DIR/$LAB_SQL_ISO"
    log "booting all VMs from the base image (LAB_MODE=boot)"
    rm -f "$STATE_DIR/active_checkpoint"   # fresh boot: new checkpoints descend from base
    LAB_MODE=boot compose up -d --force-recreate
    prov_wait_all_ssh
    prov_push_all
    prov_stage_domain_sql
    if [[ "${LAB_INTERMEDIATE_CHECKPOINTS:-1}" == 1 ]]; then
      prov_checkpoint sql-standalone _settle_short
      cmd_up sql-standalone
      from=sql-standalone
    else
      from=boot
    fi
  else
    log "continuing provisioning from checkpoint '$from'"
    [[ "$from" == boot ]] || cmd_up "$from"
    prov_push_all
  fi
  if [[ "$from" == sql-standalone || "$from" == boot ]]; then
    prov_stage_cluster
    if [[ "${LAB_INTERMEDIATE_CHECKPOINTS:-1}" == 1 ]]; then
      prov_checkpoint cluster _settle_short
      cmd_up cluster
    fi
    from=cluster
  fi
  if [[ "$from" == cluster ]]; then
    prov_stage_ag
    prov_checkpoint golden _settle_long
  fi
  ok "provisioning finished in $(( (SECONDS - t0) / 60 )) min. Try: ./lab up && ./lab health --deep"
}
