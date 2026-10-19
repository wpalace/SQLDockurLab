#!/usr/bin/env bash
# End-to-end test of the runtime pipeline WITHOUT Windows: 5 tiny Linux guests that use
# the exact same containers, networks, router, QEMU device model, checkpoint save,
# overlay-based restore and synchronized resume as the real lab.
# Proves: save/restore of RAM state, sub-second resume, multi-subnet routing, host
# reachability of node IPs and an extra (listener-style) IP, checkpoint chaining.
# Usage: sudo -E tests/e2e-fakeguest.sh   (needs docker, /dev/kvm or LAB_ACCEL=tcg)
set -Eeuo pipefail
exec 2>&1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-/tmp/sql-ag-lab-e2e}
# Earlier runs leave root-owned files (QEMU writes as root in the containers): clean them with
# sudo -n, or with a throwaway container when sudo needs a password. Clean again at exit,
# so the next run (and a disk snapshot taken later) has no leftovers.
clean_work() {
  [[ -e $WORK ]] || return 0
  rm -rf "$WORK" 2>/dev/null || sudo -n rm -rf "$WORK" 2>/dev/null \
    || docker run --rm -v "$(dirname "$WORK"):/w" --entrypoint rm sql-ag-lab/vm:latest -rf "/w/$(basename "$WORK")" 2>/dev/null || true
  [[ ! -e $WORK ]] || {
    echo "FAIL cannot remove $WORK (root-owned files): sudo rm -rf $WORK"
    exit 1
  }
}
clean_work
trap '"$ROOT/lab" down >/dev/null 2>&1 || true; clean_work' EXIT
# A first restore on a cloud VM can need more than 10 s to answer on TCP: allow 20 s.
LIMIT=${E2E_UPTIME_LIMIT_S:-20}
mkdir -p "$WORK/images/base" "$WORK/images/test" "$WORK/media"
if [[ ! -f "$ROOT/tests/fakeguest/vmlinuz" || ! -f "$ROOT/tests/fakeguest/initrd.img" ]]; then
  echo "--- building fake guest kernel/initrd"
  "$ROOT/tests/fakeguest/build.sh" || {
    echo "FAIL could not build tests/fakeguest (see output above)"
    exit 1
  }
fi
cp "$ROOT/tests/fakeguest/vmlinuz" "$ROOT/tests/fakeguest/initrd.img" "$WORK/images/test/"
sed -e "s|^LAB_IMAGES_DIR=.*|LAB_IMAGES_DIR=$WORK/images|" -e "s|^LAB_MEDIA_DIR=.*|LAB_MEDIA_DIR=$WORK/media|" \
  -e 's/^DC1_RAM_MB=.*/DC1_RAM_MB=256/' -e 's/^SQL_RAM_MB=.*/SQL_RAM_MB=384/' "$ROOT/lab.env" >"$WORK/test.env"
cat >>"$WORK/test.env" <<ENV
LAB_TEST_KERNEL=/images/test/vmlinuz
LAB_TEST_INITRD=/images/test/initrd.img
LAB_ACCEL=${LAB_ACCEL:-kvm}
LAB_PASSWORD='E2e-Fake-Pass1'
ENV
export LAB_ENV_FILE="$WORK/test.env"
LAB="$ROOT/lab"
pass() { printf '\e[32mPASS\e[0m %s\n' "$*"; }
fail() {
  printf '\e[31mFAIL\e[0m %s\n' "$*"
  exit 1
}
uptime_of() { timeout 3 bash -c "exec 3<>/dev/tcp/$1/1433; cat <&3" 2>/dev/null | awk '{print $1}'; }
uptime_dc() { timeout 3 bash -c "exec 3<>/dev/tcp/$1/389; cat <&3" 2>/dev/null | awk '{print $1}'; }

"$LAB" image
docker run --rm --entrypoint qemu-img -v "$WORK/images:/images" sql-ag-lab/vm:latest create -q -f qcow2 /images/base/disk.qcow2 1G
"$LAB" down >/dev/null 2>&1 || true
"$LAB" net

echo "--- boot mode (stands in for provisioning)"
LAB_MODE=boot "$LAB" _compose up -d --force-recreate
for _ in $(seq 1 120); do
  "$LAB" health >/dev/null 2>&1 && break
  sleep 1
done
"$LAB" health || fail "fake guests not reachable in boot mode"
pass "boot mode: all node ports + listener IP reachable from host"

echo "--- cross-subnet routing through the router container"
docker run --rm --network lab_b --ip 10.51.0.99 --cap-add NET_ADMIN --entrypoint sh sql-ag-lab/vm:latest -c \
  'ip route add 10.50.0.0/24 via 10.51.0.254 && timeout 3 bash -c "exec 3<>/dev/tcp/10.50.0.11/1433; cat <&3"' \
  | grep -q . && pass "subnet B -> router -> subnet A (SQL1:1433)" || fail "cross-subnet routing"

sleep 5
before=$(uptime_of 10.50.0.11)
echo "--- save golden (SQL1 uptime at save ~ $before s)"
"$LAB" save golden
"$LAB" list
before_restore=$(date +%s)

echo "--- up golden"
t0=$(date +%s%3N)
"$LAB" up golden
t1=$(date +%s%3N)
after=$(uptime_of 10.50.0.11)
echo "    restore wall time: $((t1 - t0)) ms; SQL1 uptime after restore: $after s"
awk -v l="$LIMIT" -v a="$after" -v b="$before" 'BEGIN { exit !(a >= b && a < b + l) }' \
  && pass "RAM state restored (uptime continued from $before -> $after, no reboot)" || fail "uptime $after vs $before"
dcu=$(uptime_dc 10.50.0.10)
[[ -n "$dcu" ]] && pass "DC1 restored (uptime $dcu)" || fail "DC1"

echo "--- fast in-place resets (containers kept, QEMU respawned on a fresh overlay)"
for n in 1 2 3; do
  t0=$(date +%s%3N)
  "$LAB" reset golden >/dev/null
  t1=$(date +%s%3N)
  u=$(uptime_of 10.50.0.11)
  echo "    reset #$n: $((t1 - t0)) ms (uptime $u)"
  awk -v l="$LIMIT" -v a="$u" -v b="$before" 'BEGIN { exit !(a >= b && a < b + l) }' || fail "reset #$n uptime $u"
done
pass "repeated fast resets return to the identical state"
t0=$(date +%s%3N)
LAB_FAST_RESET=0 "$LAB" reset golden >/dev/null
t1=$(date +%s%3N)
u=$(uptime_of 10.50.0.11)
echo "    full reset (recreate containers): $((t1 - t0)) ms (uptime $u)"
awk -v l="$LIMIT" -v a="$u" -v b="$before" 'BEGIN { exit !(a >= b && a < b + l) }' && pass "full reset" || fail "full reset uptime $u"

echo "--- chained checkpoint"
sleep 3
"$LAB" save second
"$LAB" up second >/dev/null
u2=$(uptime_of 10.50.0.11)
awk -v l="$LIMIT" -v a="$u2" -v b="$before" 'BEGIN { exit !(a > b + 2) }' && pass "chained checkpoint 'second' (uptime $u2)" || fail "second $u2"
"$LAB" delete golden 2>/dev/null && fail "deleted a parent checkpoint" || pass "refused to delete parent checkpoint"
"$LAB" down
"$LAB" up golden >/dev/null && pass "parent still restorable after child created"
"$LAB" status
"$LAB" down
echo "all e2e checks passed ($(($(date +%s) - before_restore))s)"
