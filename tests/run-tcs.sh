#!/usr/bin/env bash
# MAKE.md section 8 test cases TC1-TC9 with PASS/FAIL per test and timings.
# Usage: tests/run-tcs.sh [--resets N]   (run from the repository root, lab running at golden)
# Exit 0 only when ALL tests pass. On success writes logs/tests.passed (commit, fingerprint, time);
# on any failure removes it. ./lab gcp golden refuses to snapshot without a current tests.passed.
set -uo pipefail # no -e on purpose: every check runs and all failures are reported
cd "$(dirname "$0")/.." || exit 1
RESETS=10
[[ ${1:-} == --resets ]] && RESETS=$2
MARK=logs/tests.passed
mkdir -p logs
rm -f "$MARK"
fails=0 T0=$SECONDS
res() {
  local name=$1 rc=$2 t=$3
  if ((rc == 0)); then echo "RESULT $name PASS ${t}s"; else
    echo "RESULT $name FAIL ${t}s"
    fails=$((fails + 1))
  fi
  ./lab log "test $name $([[ $rc == 0 ]] && echo PASS || echo FAIL) (${t}s)"
}
healthy() {
  local want=$1 out
  out=$(./lab health --deep --wait "${2:-60}" 2>&1)
  echo "$out" | grep -E "listener|HEALTHY"
  grep -q "listener LabAGL -> $want" <<<"$out" && grep -qx "  HEALTHY" <<<"$out"
}
# Planned failover without data loss (an async target is set to sync first): guest/Invoke-LabFailover.ps1
failover() {
  ./lab failover "$1" 2>&1 | grep -E "planned failover|primary already"
  return "${PIPESTATUS[0]}"
}
# Automatic failover: write a marker row through the listener, power off the primary VM,
# wait until the listener reaches the expected new primary with the marker row present.
autofail() { # <kill VM> <expect VM> <expected listener subnet prefix>
  local m out t0 rc=0
  m=$(./lab agtool -Mark 2>/dev/null | tr -d '\r' | sed -n 's/^MARK=//p')
  [[ -n $m ]] || {
    echo "  no marker row"
    return 1
  }
  t0=$(ms)
  ./lab kill "$1" >/dev/null || return 1
  out=$(./lab agtool -WaitPrimary "$2" -Note "$m" -TimeoutSeconds 300 2>&1 | tr -d '\r')
  rc=$?
  echo "$out" | grep -E "ONLINE|no automatic|missing" | sed 's/^/  /'
  echo "  power-off of $1 -> $2 online through the listener: $(dt "$t0") s (host clock)"
  ((rc == 0)) && grep -q "listener_ip=$3" <<<"$out"
}
ms() { date +%s%3N; }
dt() {
  local d=$((($(ms) - $1) / 100))
  printf "%d.%d" $((d / 10)) $((d % 10))
}

./lab log "START tests/run-tcs.sh (TC1-TC9)"
t=$(ms)
tests/validate.sh >logs/tc1.log 2>&1
res TC1 $? "$(dt "$t")"
t=$(ms)
rc=0
for i in $(seq 1 "$RESETS"); do
  s=$(ms)
  ./lab reset golden >/dev/null 2>&1 || rc=1
  d=$(dt "$s")
  healthy SQL1 >/dev/null || rc=1
  echo "  reset $i ${d}s"
done
res TC3 $rc "$(dt "$t")"
t=$(ms)
failover SQL3
healthy SQL3
res TC4 $? "$(dt "$t")"
t=$(ms)
failover SQL1
healthy SQL1
res TC5 $? "$(dt "$t")"
t=$(ms)
rc=0
failover SQL3
healthy SQL3 >/dev/null || rc=1
./lab reset >/dev/null 2>&1 || rc=1
healthy SQL1 || rc=1
./lab status 2>&1 | grep -q "checkpoint: golden" || rc=1
res TC6 $rc "$(dt "$t")"
t=$(ms)
rc=0
./lab down >/dev/null 2>&1
tests/e2e-fakeguest.sh >logs/tc2.log 2>&1 || rc=1
tail -1 logs/tc2.log
./lab up >/dev/null 2>&1 || rc=1
./lab console >/dev/null 2>&1
healthy SQL1 300 >/dev/null || rc=1
res TC2 $rc "$(dt "$t")"
t=$(ms)
rc=0
# Each console: the page loads, the WebSocket opens with the token (RFB banner), and it is refused
# without the token and from another origin. The URL goes to console_check.py on stdin and only the
# port is printed, so the token is not in argv or in the output. websockify logs request paths
# (with the token), so the gateway must keep its output discarded: the token is not in docker logs.
for p in $(./lab vnc urls 2>/dev/null | grep -o 'http://[^ ]*'); do
  port=${p#http://*:}
  port=${port%%/*}
  c=$(curl -s -o /dev/null -w '%{http_code}' "${p%%#*}")
  good=$(python3 tests/console_check.py - <<<"$p")
  notoken=$(python3 tests/console_check.py - --strip-token <<<"$p")
  foreign=$(python3 tests/console_check.py - --origin https://example.com <<<"$p")
  echo "  :$port page=$c token=${good%% *} no-token=${notoken%% *} other-origin=${foreign%% *}"
  [[ $c == 200 && $good == accepted* && $notoken == rejected* && $foreign == rejected* ]] || rc=1
done
leaks=$(docker logs lab-novnc 2>&1 | grep -c -F -f secrets/console-token)
echo "  token in docker logs lab-novnc: $leaks"
[[ $leaks == 0 ]] || rc=1
res TC7 $rc "$(dt "$t")"
# TC8: automatic failover inside subnet A (SQL1 powered off -> SQL2), then back to golden.
t=$(ms)
rc=0
./lab reset golden >/dev/null 2>&1 || rc=1
healthy SQL1 >/dev/null || rc=1
autofail SQL1 SQL2 10.50.0. || rc=1
./lab up golden >/dev/null 2>&1 || rc=1
healthy SQL1 >/dev/null || rc=1
res TC8 $rc "$(dt "$t")"
# TC9: planned failover to SQL3, then SQL3+SQL4 sync/automatic (SQL1+SQL2 sync/manual: at most
# 3 automatic replicas), SQL3 powered off -> automatic failover to SQL4 on subnet B.
t=$(ms)
rc=0
failover SQL3 || rc=1
./lab failover-modes "SQL1:SYNCHRONOUS_COMMIT:MANUAL SQL2:SYNCHRONOUS_COMMIT:MANUAL SQL3:SYNCHRONOUS_COMMIT:AUTOMATIC SQL4:SYNCHRONOUS_COMMIT:AUTOMATIC" >/dev/null 2>&1 || rc=1
./lab agtool -WaitSync SQL4 >/dev/null 2>&1 || rc=1
autofail SQL3 SQL4 10.51.0. || rc=1
./lab up golden >/dev/null 2>&1 || rc=1
healthy SQL1 >/dev/null || rc=1
res TC9 $rc "$(dt "$t")"
./lab reset >/dev/null 2>&1
healthy SQL1 >/dev/null || fails=$((fails + 1))
echo "TOTAL $((SECONDS - T0))s, failures: $fails"
if ((fails == 0)); then
  printf 'COMMIT=%s\nTIME=%s\n' "$(git rev-parse --short HEAD 2>/dev/null)" "$(date '+%F %T %Z')" >"$MARK"
  ./lab log "END tests/run-tcs.sh: ALL TESTS PASSED"
  echo "ALL TESTS PASSED"
  exit 0
fi
./lab log "END tests/run-tcs.sh: $fails FAILED"
echo "TESTS FAILED ($fails)"
exit 1
