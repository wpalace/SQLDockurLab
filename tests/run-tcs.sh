#!/usr/bin/env bash
# MAKE.md section 8 test cases TC1-TC7 with PASS/FAIL per test and timings.
# Usage: tests/run-tcs.sh [--resets N]   (run from the repository root, lab running at golden)
# Exit 0 only when ALL tests pass. On success writes logs/tests.passed (commit, fingerprint, time);
# on any failure removes it. ./lab gcp golden refuses to snapshot without a current tests.passed.
set -uo pipefail
cd "$(dirname "$0")/.."
RESETS=10; [[ ${1:-} == --resets ]] && RESETS=$2
MARK=logs/tests.passed; mkdir -p logs; rm -f "$MARK"
fails=0 T0=$SECONDS
res() { local name=$1 rc=$2 t=$3; if (( rc == 0 )); then echo "RESULT $name PASS ${t}s"; else echo "RESULT $name FAIL ${t}s"; fails=$((fails + 1)); fi; ./lab log "test $name $([[ $rc == 0 ]] && echo PASS || echo FAIL) (${t}s)"; }
healthy() { local want=$1 out; out=$(./lab health --deep --wait "${2:-60}" 2>&1); echo "$out" | grep -E "listener|HEALTHY"; grep -q "listener LabAGL -> $want" <<<"$out" && grep -qx "  HEALTHY" <<<"$out"; }
failover() { ./lab ssh "$1" "Invoke-Sqlcmd -Query 'ALTER AVAILABILITY GROUP [LabAG] FAILOVER'" >/dev/null 2>&1; }
ms() { date +%s%3N; }; dt() { echo $(( ($(ms) - $1) / 100 )) | sed 's/\(.\)$/.\1/'; }

./lab log "START tests/run-tcs.sh (TC1-TC7)"
t=$(ms); tests/validate.sh > logs/tc1.log 2>&1; res TC1 $? "$(dt "$t")"
t=$(ms); rc=0
for i in $(seq 1 "$RESETS"); do
  s=$(ms); ./lab reset golden >/dev/null 2>&1 || rc=1; d=$(dt "$s")
  healthy SQL1 >/dev/null || rc=1; echo "  reset $i ${d}s"
done; res TC3 $rc "$(dt "$t")"
t=$(ms); failover SQL3; healthy SQL3; res TC4 $? "$(dt "$t")"
t=$(ms); failover SQL1; healthy SQL1; res TC5 $? "$(dt "$t")"
t=$(ms); rc=0; failover SQL3; healthy SQL3 >/dev/null || rc=1; ./lab reset >/dev/null 2>&1 || rc=1
healthy SQL1 || rc=1; ./lab status 2>&1 | grep -q "checkpoint: golden" || rc=1; res TC6 $rc "$(dt "$t")"
t=$(ms); rc=0; ./lab down >/dev/null 2>&1; tests/e2e-fakeguest.sh > logs/tc2.log 2>&1 || rc=1
tail -1 logs/tc2.log; ./lab up >/dev/null 2>&1 || rc=1; ./lab console >/dev/null 2>&1; healthy SQL1 300 >/dev/null || rc=1; res TC2 $rc "$(dt "$t")"
t=$(ms); rc=0
for p in $(./lab vnc urls 2>/dev/null | grep -o 'http://[^ ]*'); do
  c=$(curl -s -o /dev/null -w '%{http_code}' "$p"); echo "  $p $c"; [[ $c == 200 ]] || rc=1
done; res TC7 $rc "$(dt "$t")"
./lab reset >/dev/null 2>&1; healthy SQL1 >/dev/null || fails=$((fails + 1))
echo "TOTAL $((SECONDS - T0))s, failures: $fails"
if (( fails == 0 )); then
  printf 'COMMIT=%s\nTIME=%s\n' "$(git rev-parse --short HEAD 2>/dev/null)" "$(date '+%F %T %Z')" > "$MARK"
  ./lab log "END tests/run-tcs.sh: ALL TESTS PASSED"; echo "ALL TESTS PASSED"; exit 0
fi
./lab log "END tests/run-tcs.sh: $fails FAILED"; echo "TESTS FAILED ($fails)"; exit 1
