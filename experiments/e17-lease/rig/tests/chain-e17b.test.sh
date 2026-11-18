#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted $ here are stub bodies
# experiments/e17-lease/rig/tests/chain-e17b.test.sh
#
# Rig-free tests for chain-e17b.sh: the stage list and its order, the seal refusal, the bring-up stages allowed
# before the seal, resuming at a named stage, the squeeze stages, the per-stage analysis gate, the commit preflight.
# The chain runs from a staged copy under a scratch root (/srv/e15/src layout); rung.sh, ladder.sh, baseline.sh,
# smoke.sh and the analysis scripts are stubs that log their calls; systemctl and sudo are stubs.
#
# Run: bash experiments/e17-lease/rig/tests/chain-e17b.test.sh      (SHELLCHECK=/path/to/shellcheck if not on PATH)
set -uo pipefail

RIG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
E15RIG="$RIG/../../e15-session-density/rig"
fails=0
check() {
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1 (want '$3', got '$2')"
    fails=$((fails + 1))
  fi
}

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

# --- syntax and lint -------------------------------------------------------------------------
SC="${SHELLCHECK:-$(command -v shellcheck || true)}"
for s in chain-e17b.sh tests/chain-e17b.test.sh; do
  bash -n "$RIG/$s" 2>"$TMP/n.out"
  check "bash -n $s" "$([ -s "$TMP/n.out" ] && echo FAIL || echo clean)" "clean"
  if [ -n "$SC" ]; then
    "$SC" -x "$RIG/$s" >"$TMP/sc.out" 2>&1
    check "shellcheck $s" "$([ -s "$TMP/sc.out" ] && echo FAIL || echo clean)" "clean"
    [ -s "$TMP/sc.out" ] && sed 's/^/    /' "$TMP/sc.out" | head -20
  else
    check "shellcheck available" "missing" "present"
  fi
done

# --- fixture: a staged copy under a scratch root, stub stage commands --------------------------------------------
T="$TMP/e15-rig-test.chain"
PIN=1111111111111111111111111111111111111111
mkdir -p "$T/src/e15" "$T/src/e17" "$T/state" "$T/runs" "$TMP/stub" "$TMP/an"
cp -R "$E15RIG" "$T/src/e15/rig"
cp -R "$RIG" "$T/src/e17/rig"
CHAIN="$T/src/e17/rig/chain-e17b.sh"
PRED="$T/src/e17/predictions-e17b.json"
printf 'E17B_MOCA_PIN=%s\n' "$PIN" >"$TMP/pins.sh"
printf '%s\n' "$PIN" >"$T/state/go-stock-e17b"
echo fresh-metal >"$T/state/host_profile"
CLOG="$TMP/calls.log"
# systemctl: no unit is active, except the worker when $TMP/worker-up exists; sudo runs the command
printf '#!/usr/bin/env bash\ncase "$*" in *e15-worker.service*) [ -e "%s/worker-up" ] ;; *) exit 1 ;; esac\n' "$TMP" >"$TMP/stub/systemctl"
printf '#!/usr/bin/env bash\n[ "$1" = -n ] && shift\nexec "$@"\n' >"$TMP/stub/sudo"
chmod +x "$TMP/stub/systemctl" "$TMP/stub/sudo"
# a stage stub KIND: logs "KIND ARGS tag=<E15_TAG> memmax=<E15_SQUEEZE_MEMMAX_MB> e17b=<E17B>"; fails when the
# logged call starts with $FAIL_ON. rung writes the rung's params.json (arm, moca_commit, driver_exit, rung_failed,
# memory_abort from STUB_DRIVER_EXIT, STUB_RUNG_FAILED, STUB_MEMORY_ABORT) and record.json (aborted: STUB_ABORTED;
# none with STUB_NO_RECORD=1), ladder at the squeeze
# point a ladder.json with squeeze.stop_n 64 and the memmax it ran under.
mkstub() {
  cat >"$TMP/stub-$1.sh" <<SH
#!/usr/bin/env bash
line="$1 \$* tag=\${E15_TAG:-unset} memmax=\${E15_SQUEEZE_MEMMAX_MB:-unset} e17b=\${E17B:-unset} ram=\${E17B_GUEST_RAM_MB:-unset}"
echo "\$line" >>"$CLOG"
echo "$1 \$* ws=\${E15_WS_DELTA_MB:-unset}" >>"$TMP/ws.log"
case "\$line" in "\${FAIL_ON:-NONE}"*) echo "stub failure: \$line" >&2; exit 1 ;; esac
case "$1" in
rung)
  d=\$E15_ROOT/runs/\$3/\$1/N\$2\${E15_TAG:+-\$E15_TAG}
  mkdir -p "\$d"
  printf '{"arm": "%s", "n": %s, "moca_commit": "%s", "driver_exit": %s, "rung_failed": %s, "memory_abort": %s}\n' "\$1" "\$2" \
    "\${STUB_COMMIT:-$PIN}" "\${STUB_DRIVER_EXIT:-0}" "\${STUB_RUNG_FAILED:-null}" "\${STUB_MEMORY_ABORT:-null}" >"\$d/params.json"
  rm -f "\$d/record.json"
  [ "\${STUB_NO_RECORD:-0}" = 1 ] || printf '{"aborted": %s}\n' "\${STUB_ABORTED:-false}" >"\$d/record.json" ;;
baseline)
  mkdir -p "\$E15_ROOT/runs/\$1/\$2/N1"
  printf '{"class_medians": {"build": 1.0}}\n' >"\$E15_ROOT/runs/\$1/\$2/N1/baseline.json" ;;
ladder)
  if [ "\${1#squeeze}" != "\$1" ]; then
    mkdir -p "\$E15_ROOT/runs/\$1/\$2"
    printf '{"squeeze": {"stop_n": %s, "memmax_mb": %s}}\n' "\${STUB_STOP_N:-64}" "\$E15_SQUEEZE_MEMMAX_MB" >"\$E15_ROOT/runs/\$1/\$2/ladder.json"
  fi ;;
esac
exit 0
SH
  chmod +x "$TMP/stub-$1.sh"
}
for k in rung ladder baseline smoke ownwalk; do mkstub "$k"; done
# analysis stubs: warmcold_lease.py writes warmcold-report.json (unknown = STUB_UNKNOWN), lease_ends.py lease_ends.json
cat >"$TMP/an/warmcold_lease.py" <<'PY'
import json, os, sys
fnv = int(os.environ.get("STUB_FNV", "0"))
cfg = os.environ.get("STUB_CFG", "")  # a configuration refusal cause on every failed_no_vm row (E17B-R42)
json.dump({"unknown": int(os.environ.get("STUB_UNKNOWN", "0")), "disagreements": int(os.environ.get("STUB_DIS", "0")),
           "failed_no_vm": fnv, "failed_no_vm_by_reason": {"no-vm": fnv} if fnv else {},
           "failed_no_vm_by_cause": {(cfg or "memory-budget"): fnv} if fnv else {},
           "config_refusals": fnv if cfg else 0, "config_refusals_by_cause": {cfg: fnv} if cfg and fnv else {},
           "valid": os.environ.get("STUB_WC_VALID", "1") == "1"}, open(sys.argv[1] + "/warmcold-report.json", "w"))
print("warm 1 cold 1 unknown %s" % os.environ.get("STUB_UNKNOWN", "0"))
open(os.environ["ALOG"], "a").write("warmcold_lease %s\n" % sys.argv[1])
PY
cat >"$TMP/an/lease_ends.py" <<'PY'
import json, os, sys
c4 = {"1": True, "0": False, "null": None}[os.environ.get("STUB_C4", "1")]
json.dump({"notices": {"unmatched_ends": [{"key": "k"}] * int(os.environ.get("STUB_UNMATCHED", "0"))},
           "valid": os.environ.get("STUB_LE_VALID", "1") == "1", "invalid_reasons": ["stub reason"], "criterion4_pass": c4},
          open(sys.argv[1] + "/lease_ends.json", "w"))
print("valid True")
open(os.environ["ALOG"], "a").write("lease_ends %s\n" % sys.argv[1])
PY
cat >"$TMP/an/freed_from_shmem.py" <<'PY'
import json, os, sys
json.dump({}, open(sys.argv[1] + "/shmem.json", "w"))
open(os.environ["ALOG"], "a").write("freed_from_shmem %s\n" % sys.argv[1])
print("heavy 0 with_delta 0")
PY
cat >"$TMP/an/vm_age_lease.py" <<'PY'
import json, os, sys
json.dump({"mapping_valid": os.environ.get("STUB_MAP_VALID", "1") == "1", "mapping_reasons": ["stub mapping"]}, open(sys.argv[1] + "/vm_age_lease.json", "w"))
open(os.environ["ALOG"], "a").write("vm_age_lease %s\n" % " ".join(sys.argv[1:]))
print("mapping_valid")
PY
# verdict.py stub: logs its arguments, writes --out (fails with STUB_VERDICT_FAIL=1)
cat >"$TMP/an/verdict.py" <<'PY'
import os, sys
a = sys.argv[1:]
open(os.environ["ALOG"], "a").write("verdict %s\n" % " ".join(a))
if os.environ.get("STUB_VERDICT_FAIL") == "1":
    sys.exit("stub verdict failure")
open(a[a.index("--out") + 1], "w").write("{}")
print("verdict written")
PY
# latency_report.py stub: logs its rung dirs and --out
cat >"$TMP/an/latency_report.py" <<'PY'
import os, sys
a = sys.argv[1:]
out = a[a.index("--out") + 1]
os.makedirs(out, exist_ok=True)
open(os.path.join(out, "latency.json"), "w").write("{}")
dirs = [x for x in a if x != "--out" and x != out]
open(os.environ["ALOG"], "a").write("latency_report %s --out %s\n" % (" ".join(sorted(dirs)), out))
PY

seal() { printf '{"status": "sealed", "sealed": %s, "predictions": []}\n' "$1" >"$PRED"; }
chain() { # [VAR=val ...] -- ARGS: run the staged chain; rc echoed, output in $TMP/c.out
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    envs+=("$1")
    shift
  done
  [ "${1:-}" != -- ] || shift
  : >"$CLOG"
  : >"$TMP/alog"
  env -u E17B E15_ROOT="$T" E15_TEST_ROOT="$T" E15_TEST_PINS="$TMP/pins.sh" E15_MANIFEST="$TMP/m.md" PATH="$TMP/stub:$PATH" \
    E17B_TEST_HARNESS=1 E17B_RUNG="$TMP/stub-rung.sh" E17B_LADDER="$TMP/stub-ladder.sh" E17B_BASELINE="$TMP/stub-baseline.sh" E17B_SMOKE="$TMP/stub-smoke.sh" \
    E17B_OWNWALK="$TMP/stub-ownwalk.sh" E17B_ANALYSIS="$TMP/an" ALOG="$TMP/alog" ${envs[@]+"${envs[@]}"} bash "$CHAIN" "$@" >"$TMP/c.out" 2>&1
  echo $?
}
calls() { sed 's/ *tag=.*//' "$CLOG" | tr '\n' ';'; }
reset() { rm -rf "$T/e17b" "$T/runs" && mkdir -p "$T/runs"; }
BRINGUP="smoke;baseline default sbx;baseline default ship-300;baseline pycache sbx;baseline pycache ship-300;"

test_chain_lists_stages() {
  reset
  rm -f "$PRED"
  check "list: exit 0, the predictions state in the header" "$(chain -- --list)/$(head -1 "$TMP/c.out" | grep -c 'predictions: missing')" "0/1"
  check "list: the ordered stages (Task 12 bring-up, Task 14 Steps 1-4, optional ladders, the 256 MiB runs last)" \
    "$(sed -n '2,$p' "$TMP/c.out" | awk '{print $1}' | tr '\n' ' ')" \
    "smoke cal-default-sbx cal-default-ship-300 cal-pycache-sbx cal-pycache-ship-300 base-pycache-low-sbx base-pycache-low-ship-300 base-pycache-ship-30 base-pycache-ship-120 lat-pycache-sbx-n1 lat-pycache-ship-300-n1 lat-pycache-low-sbx-n1 lat-pycache-low-ship-300-n1 lat-pycache-sbx-n128 lat-pycache-ship-300-n128 lat-pycache-low-sbx-n128 lat-pycache-low-ship-300-n128 lat-pycache-ship-30-n128 lat-pycache-ship-120-n128 ladder-default-sbx ladder-default-ship-300 base-squeeze-sbx base-squeeze-ship-300 squeeze-ship-300 squeeze-sbx probe-overhead ownwalk base-default-ship-30 base-default-ship-120 ladder-default-ship-30 ladder-default-ship-120 ram256-pycache-sbx-n1 ram256-pycache-ship-300-n1 ram256-base-squeeze-sbx ram256-base-squeeze-ship-300 ram256-squeeze-ship-300 ram256-squeeze-sbx verdict "
  check "list: only the smoke and the four calibration baselines run before the seal; every other stage needs it" \
    "$(sed -n '2,$p' "$TMP/c.out" | awk '$2 == "-" {print $1}' | tr '\n' ' ')/$(sed -n '2,$p' "$TMP/c.out" | awk '$2 != "-" && $2 != "seal" && $2 != "opt" && $2 != "ram256"' | wc -l | tr -d ' ')" \
    "smoke cal-default-sbx cal-default-ship-300 cal-pycache-sbx cal-pycache-ship-300 /0"
  check "list: the optional stages are the ship-30/ship-120 default ladders and their baselines" \
    "$(awk '$2 == "opt" {print $1}' "$TMP/c.out" | tr '\n' ' ')" "base-default-ship-30 base-default-ship-120 ladder-default-ship-30 ladder-default-ship-120 "
}
test_chain_refuses_unsealed() {
  local v
  for v in missing false '"true"' broken; do
    reset
    case "$v" in missing) rm -f "$PRED" ;; broken) printf '{"sealed": true,' >"$PRED" ;; *) seal "$v" ;; esac
    printf '%s:%s:%s:%s ' "$v" "$(chain)" "$(grep -c 'E17B REFUSED: predictions' "$TMP/c.out")" "$(grep -c . "$CLOG")"
  done >"$TMP/ref.out"
  check "seal: refused up front (exit 1, nothing run) unless predictions-e17b.json says \"sealed\": true (the boolean)" \
    "$(cat "$TMP/ref.out")" 'missing:1:1:0 false:1:1:0 "true":1:1:0 broken:1:1:0 '
  check "seal: the refusal names the stages that need it and how to stop before them" \
    "$(grep -c 'stages that need the seal: base-pycache-low-sbx .* (stop before them with --to cal-pycache-ship-300)' "$TMP/c.out")" "1"
  reset
  rm -f "$PRED"
  check "seal: --from a sealed stage is refused too" "$(chain -- --from ladder-default-sbx --to ladder-default-sbx)/$(grep -c . "$CLOG")" "1/0"
}
test_chain_runs_bringup_unsealed() {
  reset
  rm -f "$PRED"
  check "bring-up: --to cal-pycache-ship-300 runs without the seal: smoke, then the four calibration baselines, in order" \
    "$(chain -- --to cal-pycache-ship-300)/$(calls)" "0/$BRINGUP"
  check "bring-up: every stage ran with E17B=1, each wrote its own log and a .done" \
    "$(grep -c 'e17b=1 ' "$CLOG")/$(find "$T/e17b" -name '*.log' | wc -l | tr -d ' ')/$(find "$T/e17b" -name '*.done' | wc -l | tr -d ' ')" "5/5/5"
  check "bring-up: the stage log holds the stage's own output" "$(grep -c 'stub' "$T/e17b/smoke.log")/$(grep -c 'E17B smoke DONE' "$TMP/c.out")" "0/1"
  check "bring-up: run again, everything selected is done: nothing runs" "$(chain -- --to cal-pycache-ship-300)/$(grep -c . "$CLOG")/$(grep -c 'is done' "$TMP/c.out")" "0/0/1"
}
test_chain_resumes_at_stage() {
  reset
  seal true
  check "resume: a failing stage stops the chain there, naming the --from to resume with" \
    "$(chain FAIL_ON='rung ship-300 128 pycache ' -- --to ladder-default-sbx)/$(grep -c 'E17B lat-pycache-ship-300-n128 FAILED rc=1 .*resume with --from lat-pycache-ship-300-n128' "$TMP/c.out")/$(tail -1 "$CLOG" | cut -d' ' -f1-4)" \
    "1/1/rung ship-300 128 pycache"
  check "resume: the stages before it are done, it and the later ones are not" \
    "$([ -f "$T/e17b/lat-pycache-sbx-n128.done" ] && echo before-done)/$([ -f "$T/e17b/lat-pycache-ship-300-n128.done" ] && echo failed-done || echo failed-open)/$([ -f "$T/e17b/lat-pycache-low-sbx-n128.done" ] && echo later-done || echo later-open)" \
    "before-done/failed-open/later-open"
  check "resume: without --from the next run starts at the failed stage and does not re-run earlier ones" \
    "$(chain -- --to lat-pycache-low-sbx-n128)/$(grep -c 'resuming at lat-pycache-ship-300-n128' "$TMP/c.out")/$(calls)" \
    "0/1/rung ship-300 128 pycache;rung sbx 128 pycache-low;"
  check "resume: --from STAGE starts there whatever is done, --to STAGE stops after it" \
    "$(chain -- --from lat-pycache-sbx-n1 --to lat-pycache-ship-300-n1)/$(calls)" "0/rung sbx 1 pycache;rung ship-300 1 pycache;"
  check "resume: an unknown stage, or --from after --to, is a usage error (exit 2), nothing run" \
    "$(chain -- --from nowhere)/$(chain -- --to nowhere)/$(chain -- --from ladder-default-sbx --to smoke)/$(grep -c . "$CLOG")" "2/2/2/0"
  reset
  check "resume: a full sealed run goes stage by stage in the list's order (to the squeeze climb)" \
    "$(chain E17B_SQUEEZE_MEMMAX_MB=8192 -- --to squeeze-ship-300)/$(calls)" \
    "0/${BRINGUP}baseline pycache-low sbx;baseline pycache-low ship-300;baseline pycache ship-30;baseline pycache ship-120;rung sbx 1 pycache;rung ship-300 1 pycache;rung sbx 1 pycache-low;rung ship-300 1 pycache-low;rung sbx 128 pycache;rung ship-300 128 pycache;rung sbx 128 pycache-low;rung ship-300 128 pycache-low;rung ship-30 128 pycache;rung ship-120 128 pycache;ladder default sbx 56;ladder default ship-300 80;baseline squeeze sbx;baseline squeeze ship-300;ladder squeeze ship-300;"
  check "resume: rung stages are tagged lat; the caller's E15_TAG, E15_SQUEEZE_MEMMAX_MB and E17B_GUEST_RAM_MB never reach a stage" \
    "$(chain E15_TAG=evil E15_SQUEEZE_MEMMAX_MB=1 E17B_GUEST_RAM_MB=256 -- --from lat-pycache-sbx-n1 --to lat-pycache-sbx-n1)/$(sed 's/.* tag=//' "$CLOG")" "0/lat memmax=unset e17b=1 ram=unset"
}
test_chain_squeeze_stages() {
  reset
  seal true
  check "squeeze: the stage list says the host-MemAvailable reclaim trigger is not exercised" "$(chain -- --list)/$(grep -c 'host-MemAvailable reclaim trigger is not exercised' "$TMP/c.out")" "0/1"
  check "squeeze: the note is shown after the command, never inside it" \
    "$(chain -- --list)/$(grep -c 'squeeze-ladder squeeze ship-300  # budget' "$TMP/c.out")" "0/1"
  check "squeeze: the climb without E17B_SQUEEZE_MEMMAX_MB fails, naming it" \
    "$(chain -- --from squeeze-ship-300 --to squeeze-ship-300)/$(grep -c 'needs E17B_SQUEEZE_MEMMAX_MB' "$T/e17b/squeeze-ship-300.log")/$(grep -c . "$CLOG")" "1/1/0"
  check "squeeze: the climb is ladder.sh squeeze ship-300 under the value, then sbx runs once at its stop N under the same" \
    "$(chain E17B_SQUEEZE_MEMMAX_MB=8192 -- --from squeeze-ship-300 --to squeeze-sbx)/$(tr '\n' ';' <"$CLOG")" \
    "0/ladder squeeze ship-300 tag=unset memmax=8192 e17b=1 ram=unset;rung sbx 64 squeeze tag=sq memmax=8192 e17b=1 ram=unset;"
  check "squeeze: sbx refuses a value other than the climb's" \
    "$(chain E17B_SQUEEZE_MEMMAX_MB=4096 -- --from squeeze-sbx --to squeeze-sbx)/$(grep -c 'the ship-300 climb ran under 8192' "$T/e17b/squeeze-sbx.log")" "1/1"
  check "squeeze: sbx alone takes the climb's value from its ladder.json" \
    "$(chain -- --from squeeze-sbx --to squeeze-sbx)/$(cat "$CLOG")" "0/rung sbx 64 squeeze tag=sq memmax=8192 e17b=1 ram=unset"
  printf '{"squeeze": {"stop_n": 64,' >"$T/runs/squeeze/ship-300/ladder.json"
  check "squeeze (PR #34 nit): an unreadable ladder.json stops the stage, naming it (never an empty N)" \
    "$(chain -- --from squeeze-sbx --to squeeze-sbx)/$(grep -c "unreadable.*ladder.json\|ladder.json.*unreadable" "$T/e17b/squeeze-sbx.log")/$(grep -c . "$CLOG")" "1/1/0"
  printf '{"squeeze": {"stop_n": null, "memmax_mb": 8192}}\n' >"$T/runs/squeeze/ship-300/ladder.json"
  check "squeeze: a climb that stopped at no N leaves sbx nothing to run (fails)" \
    "$(chain -- --from squeeze-sbx --to squeeze-sbx)/$(grep -c 'stopped at no N' "$T/e17b/squeeze-sbx.log")/$(grep -c . "$CLOG")" "1/1/0"
}
test_chain_analysis_gate() {
  reset
  seal true
  check "gate: each ship-* rung the stage wrote is analysed (warmcold_lease, lease_ends, freed_from_shmem before vm_age_lease, with --sbx the same-named sbx rung); sbx rungs are not" \
    "$(chain -- --from lat-pycache-sbx-n1 --to lat-pycache-ship-300-n1)/$(grep -v '^latency_report' "$TMP/alog" | sed "s#$T/runs/##g" | tr '\n' ';')" \
    "0/warmcold_lease pycache/ship-300/N1-lat;lease_ends pycache/ship-300/N1-lat;freed_from_shmem pycache/ship-300/N1-lat;vm_age_lease pycache/ship-300/N1-lat --sbx pycache/sbx/N1-lat;"
  check "gate: without a same-named sbx rung vm_age_lease runs without --sbx" \
    "$(chain -- --from lat-pycache-ship-30-n128 --to lat-pycache-ship-30-n128)/$(grep '^vm_age_lease' "$TMP/alog" | sed "s#$T/runs/##g")" \
    "0/vm_age_lease pycache/ship-30/N128-lat"
  check "gate: an unknown call stops the chain at that stage, which stays not done" \
    "$(chain STUB_UNKNOWN=2 -- --from lat-pycache-ship-300-n1 --to lat-pycache-low-sbx-n1)/$(grep -c 'STOP pycache/ship-300/N1-lat: 2 unknown call(s)' "$TMP/c.out")/$([ -f "$T/e17b/lat-pycache-ship-300-n1.done" ] && echo "done" || echo open)/$(grep -c . "$CLOG")" \
    "1/1/open/1"
  check "gate (E17B-R35): failed_no_vm calls are reported (a NOTE naming the count and reasons), not a stop; the stage is done" \
    "$(chain STUB_FNV=3 -- --from lat-pycache-ship-300-n1 --to lat-pycache-ship-300-n1)/$(grep -c 'NOTE pycache/ship-300/N1-lat: 3 failed_no_vm call(s) {"no-vm": 3} by cause {"memory-budget": 3}' "$TMP/c.out")/$(grep -c STOP "$TMP/c.out")/$([ -f "$T/e17b/lat-pycache-ship-300-n1.done" ] && echo "done" || echo open)" \
    "0/1/0/done"
  local c out=""
  for c in stale-mode lease-unsupported permission-denied req-id-in-flight; do
    out+="$c=$(chain STUB_FNV=2 STUB_CFG=$c -- --from lat-pycache-ship-300-n1 --to lat-pycache-ship-300-n1):$(grep -c "STOP pycache/ship-300/N1-lat: 2 configuration refusal(s) {\"$c\": 2}" "$TMP/c.out"):$([ -f "$T/e17b/lat-pycache-ship-300-n1.done" ] && echo "done" || echo open) "
  done
  check "gate (E17B-R42): a configuration refusal cause in any row stops the stage, naming the cause" \
    "$out" "stale-mode=1:1:open lease-unsupported=1:1:open permission-denied=1:1:open req-id-in-flight=1:1:open "
  check "gate: no failed_no_vm call, no NOTE" \
    "$(chain -- --from lat-pycache-ship-300-n1 --to lat-pycache-ship-300-n1)/$(grep -c 'failed_no_vm' "$TMP/c.out")" "0/0"
  check "gate: an unmatched lease end stops it too" \
    "$(chain STUB_UNMATCHED=1 -- --from lat-pycache-ship-300-n1 --to lat-pycache-ship-300-n1)/$(grep -c '1 unmatched lease end(s)' "$TMP/c.out")" "1/1"
  check "gate: a rung written before the stage started is not re-analysed (only the stage's own rung is reported)" \
    "$(chain -- --from lat-pycache-sbx-n128 --to lat-pycache-sbx-n128)/$(grep -c '^warmcold_lease' "$TMP/alog")" "0/0"
  local v
  for v in "STUB_LE_VALID=0:lease_ends.json valid false (stub reason)" "STUB_C4=0:criterion 4 failed" "STUB_WC_VALID=0:warmcold-report valid false" \
    "STUB_DIS=1:1 source disagreement(s)" "STUB_MAP_VALID=0:vm_age_lease mapping_valid false (stub mapping)"; do
    printf '%s=%s:%s ' "${v%%:*}" "$(chain "${v%%:*}" -- --from lat-pycache-ship-300-n1 --to lat-pycache-ship-300-n1)" "$(grep -cF "STOP pycache/ship-300/N1-lat: ${v#*:}" "$TMP/c.out")"
  done >"$TMP/gate.out"
  check "gate: stops on lease_ends valid false, criterion4_pass false, warmcold valid false, any disagreement, vm_age_lease mapping_valid false" \
    "$(cat "$TMP/gate.out")" "STUB_LE_VALID=0=1:1 STUB_C4=0=1:1 STUB_WC_VALID=0=1:1 STUB_DIS=1=1:1 STUB_MAP_VALID=0=1:1 "
  check "gate: criterion4_pass null (no lease ended: vacuous) does not stop" "$(chain STUB_C4=null -- --from lat-pycache-ship-300-n1 --to lat-pycache-ship-300-n1)" "0"
  check "gate: after a measured stage latency_report.py runs over the stage's rungs (every arm) to the stage's log dir" \
    "$(chain -- --from lat-pycache-sbx-n128 --to lat-pycache-ship-300-n128)/$(grep '^latency_report' "$TMP/alog" | sed "s#$T/runs/##g; s#$T/e17b/##" | tr '\n' ';')/$([ -s "$T/e17b/lat-pycache-ship-300-n128.latency/latency.json" ] && echo written)" \
    "0/latency_report pycache/sbx/N128-lat --out lat-pycache-sbx-n128.latency;latency_report pycache/ship-300/N128-lat --out lat-pycache-ship-300-n128.latency;/written"
  reset
  rm -f "$PRED"
  check "gate: no latency_report after a bring-up stage (not a measured stage)" \
    "$(chain -- --to cal-default-sbx)/$(grep -c '^latency_report' "$TMP/alog")" "0/0"
  seal true
}
# M1: the final verdict stage (needs the seal) computes every criterion's inputs from the runs.
test_chain_verdict_stage() {
  reset
  rm -f "$PRED"
  check "verdict: refused before the seal (nothing run)" "$(chain -- --from verdict)/$(grep -c . "$TMP/alog")" "1/0"
  seal true
  check "verdict: the last stage runs verdict.py over the runs, at the pin, to \$L/verdict.json" \
    "$(chain -- --from verdict)/$(sed "s#$T/##g" "$TMP/alog")/$([ -f "$T/e17b/verdict.json" ] && echo written)/$([ -f "$T/e17b/verdict.done" ] && echo "done")" \
    "0/verdict runs --moca-commit $PIN --out e17b/verdict.json/written/done"
  check "verdict: a verdict.py failure fails the stage" "$(chain STUB_VERDICT_FAIL=1 -- --from verdict)/$([ -f "$T/e17b/verdict.done" ] && echo "done" || echo open)" "1/open"
}
# I3: the gate reads every rung's own failure flags (ship and sbx), whatever its analyses say.
test_chain_gate_reads_rung_failure_flags() {
  reset
  seal true
  local v arm stage
  for arm in sbx ship-300; do
    stage=lat-pycache-$arm-n1
    for v in 'STUB_RUNG_FAILED="driver_exit=1" STUB_DRIVER_EXIT=1:rung_failed driver_exit=1' \
      'STUB_RUNG_FAILED="set_mode_failed=2" STUB_DRIVER_EXIT=1:rung_failed set_mode_failed=2' \
      'STUB_ABORTED=true STUB_DRIVER_EXIT=1:record.json aborted (driver_exit 1)' \
      'STUB_NO_RECORD=1 STUB_DRIVER_EXIT=3:driver_exit 3 (no memory abort)'; do
      read -r -a envs <<<"${v%%:*}"
      printf '%s|%s=%s:%s:%s ' "$arm" "${v%%:*}" "$(chain "${envs[@]}" -- --from "$stage" --to "$stage")" \
        "$(grep -cF "STOP pycache/$arm/N1-lat: ${v#*:}" "$TMP/c.out")" "$([ -f "$T/e17b/$stage.done" ] && echo "done" || echo open)"
    done
  done >"$TMP/flags.out"
  check "gate: a rung's rung_failed, record.json aborted or a non-zero driver exit stops the stage, sbx and ship alike" \
    "$(cat "$TMP/flags.out")" \
    "sbx|STUB_RUNG_FAILED=\"driver_exit=1\" STUB_DRIVER_EXIT=1=1:1:open sbx|STUB_RUNG_FAILED=\"set_mode_failed=2\" STUB_DRIVER_EXIT=1=1:1:open sbx|STUB_ABORTED=true STUB_DRIVER_EXIT=1=1:1:open sbx|STUB_NO_RECORD=1 STUB_DRIVER_EXIT=3=1:1:open ship-300|STUB_RUNG_FAILED=\"driver_exit=1\" STUB_DRIVER_EXIT=1=1:1:open ship-300|STUB_RUNG_FAILED=\"set_mode_failed=2\" STUB_DRIVER_EXIT=1=1:1:open ship-300|STUB_ABORTED=true STUB_DRIVER_EXIT=1=1:1:open ship-300|STUB_NO_RECORD=1 STUB_DRIVER_EXIT=3=1:1:open "
  check "gate: a failed ship rung is not analysed (its outputs would be partial)" \
    "$(chain STUB_ABORTED=true STUB_DRIVER_EXIT=1 -- --from lat-pycache-ship-300-n1 --to lat-pycache-ship-300-n1)/$(grep -c '^warmcold_lease' "$TMP/alog")" "1/0"
  check "gate: a memory-watchdog abort (driver killed, not aborted: a host verdict) does not stop the stage" \
    "$(chain STUB_DRIVER_EXIT=143 STUB_MEMORY_ABORT='{"reason":"floor"}' -- --from lat-pycache-sbx-n1 --to lat-pycache-sbx-n1)/$(chain STUB_NO_RECORD=1 STUB_DRIVER_EXIT=143 STUB_MEMORY_ABORT='{"reason":"floor"}' -- --from lat-pycache-sbx-n1 --to lat-pycache-sbx-n1)" "0/0"
  check "gate: a ship rung's memory-watchdog abort (rung_failed set with memory_abort) does not stop the stage" \
    "$(chain STUB_DRIVER_EXIT=143 STUB_RUNG_FAILED='"driver_exit=143"' STUB_MEMORY_ABORT='{"reason":"floor"}' -- --from lat-pycache-ship-300-n1 --to lat-pycache-ship-300-n1)/$(grep -c 'STOP' "$TMP/c.out")" "0/0"
  check "gate (PR #34 nit): set_mode failures stop the stage even when the rung also had a memory abort (independent failures)" \
    "$(chain STUB_DRIVER_EXIT=143 STUB_RUNG_FAILED='"set_mode_failed=2"' STUB_MEMORY_ABORT='{"reason":"floor"}' -- --from lat-pycache-ship-300-n1 --to lat-pycache-ship-300-n1)/$(grep -c 'STOP pycache/ship-300/N1-lat: rung_failed set_mode_failed=2' "$TMP/c.out")" "1/1"
  check "gate: a clean sbx rung passes the flag check (driver_exit 0, rung_failed null, aborted false)" \
    "$(chain -- --from lat-pycache-sbx-n1 --to lat-pycache-sbx-n1)/$([ -f "$T/e17b/lat-pycache-sbx-n1.done" ] && echo "done")" "0/done"
  check "gate: an unreadable params.json stops the stage (never passes)" \
    "$(chain STUB_RUNG_FAILED='{broken' -- --from lat-pycache-sbx-n1 --to lat-pycache-sbx-n1)/$(grep -c 'STOP pycache/sbx/N1-lat: the rung flags are unreadable' "$TMP/c.out")" "1/1"
}
test_chain_preflight_and_guards() {
  reset
  seal true
  mkdir -p "$T/runs/pycache/sbx/N1-old"
  printf '{"arm": "sbx", "moca_commit": "c13d55649777e69ec7649d6fa8c08f4acb1f4e2e"}\n' >"$T/runs/pycache/sbx/N1-old/params.json"
  check "preflight: a run directory holding another commit's rung refuses the stage (nothing run)" \
    "$(chain -- --from lat-pycache-sbx-n1 --to lat-pycache-sbx-n1)/$(grep -c 'is not from E17B_MOCA_PIN' "$T/e17b/lat-pycache-sbx-n1.log")/$(grep -c . "$CLOG")" "1/1/0"
  reset
  mkdir -p "$T/runs/pycache/sbx/N1-list"
  echo '[1, 2]' >"$T/runs/pycache/sbx/N1-list/params.json"
  check "preflight: a check that fails (a params.json that is not an object) refuses the stage, not passes it" \
    "$(chain -- --from lat-pycache-sbx-n1 --to lat-pycache-sbx-n1)/$(grep -c 'preflight check failed' "$T/e17b/lat-pycache-sbx-n1.log")/$(grep -c . "$CLOG")" "1/1/0"
  reset
  : >"$TMP/ws.log"
  chain E17B_SQUEEZE_MEMMAX_MB=8192 -- --from lat-pycache-sbx-n1 --to lat-pycache-sbx-n1 >/dev/null
  chain -- --from ladder-default-sbx --to ladder-default-sbx >/dev/null
  chain E17B_SQUEEZE_MEMMAX_MB=8192 -- --from squeeze-ship-300 --to squeeze-ship-300 >/dev/null
  check "workspace delta (E17B-R51): 8 MiB at the pycache and squeeze points, unset at default" \
    "$(tr '\n' ';' <"$TMP/ws.log")" \
    "rung sbx 1 pycache ws=8;ladder default sbx 56 ws=unset;ladder squeeze ship-300 ws=8;"
  reset
  check "squeeze resume (E17B-R51): E17B_SQUEEZE_START_N is passed to the climb as its START_N" \
    "$(chain E17B_SQUEEZE_MEMMAX_MB=8192 E17B_SQUEEZE_START_N=24 -- --from squeeze-ship-300 --to squeeze-ship-300)/$(cat "$CLOG")" \
    "0/ladder squeeze ship-300 24 tag=unset memmax=8192 e17b=1 ram=unset"
  reset
  check "ram256 (E17B-R45): without E17B_RAM256=1 every ram256 stage is SKIPPED as cut, nothing run" \
    "$(chain -- --from ram256-pycache-sbx-n1 --to ram256-squeeze-sbx)/$(grep -c 'SKIP (cut, E17B-R45' "$TMP/c.out")/$(grep -c . "$CLOG")" "0/6/0"
  check "ram256: the pycache N=1 stages run at pycache-d64 (D scaled 256 -> 64 with the RAM) with E17B_GUEST_RAM_MB=256, tag ram256" \
    "$(chain E17B_RAM256=1 -- --from ram256-pycache-sbx-n1 --to ram256-pycache-ship-300-n1)/$(tr '\n' ';' <"$CLOG")" \
    "0/rung sbx 1 pycache-d64 tag=ram256 memmax=unset e17b=1 ram=256;rung ship-300 1 pycache-d64 tag=ram256 memmax=unset e17b=1 ram=256;"
  check "ownwalk: ownwalk.sh once per size (10k, 100k, 500k files), in order, each under E17B=1" \
    "$(chain -- --from ownwalk --to ownwalk)/$(tr '\n' ';' <"$CLOG")" \
    "0/ownwalk 10000 tag=unset memmax=unset e17b=1 ram=unset;ownwalk 100000 tag=unset memmax=unset e17b=1 ram=unset;ownwalk 500000 tag=unset memmax=unset e17b=1 ram=unset;"
  check "ownwalk: a failed size stops the stage there, naming it" \
    "$(chain FAIL_ON='ownwalk 100000' -- --from ownwalk --to ownwalk)/$(grep -c 'ownwalk.sh 100000 failed' "$T/e17b/ownwalk.log")/$(grep -c . "$CLOG")" "1/1/2"
  reset
  check "ram256 squeeze (E17B-R21): squeeze-256 baselines, the ship-300 climb under E17B_SQUEEZE256_MEMMAX_MB, then sbx at its stop N, all at 256 MiB" \
    "$(chain E17B_RAM256=1 E17B_SQUEEZE256_MEMMAX_MB=12288 E17B_SQUEEZE_MEMMAX_MB=16384 -- --from ram256-base-squeeze-sbx --to ram256-squeeze-sbx)/$(tr '\n' ';' <"$CLOG")" \
    "0/baseline squeeze-256 sbx tag=unset memmax=unset e17b=1 ram=256;baseline squeeze-256 ship-300 tag=unset memmax=unset e17b=1 ram=256;ladder squeeze-256 ship-300 tag=unset memmax=12288 e17b=1 ram=256;rung sbx 64 squeeze-256 tag=sq memmax=12288 e17b=1 ram=256;"
  reset
  check "ram256 squeeze: the climb without E17B_SQUEEZE256_MEMMAX_MB fails, naming it (the 1024 MiB value is not reused)" \
    "$(chain E17B_RAM256=1 E17B_SQUEEZE_MEMMAX_MB=16384 -- --from ram256-squeeze-ship-300 --to ram256-squeeze-ship-300)/$(grep -c 'needs E17B_SQUEEZE256_MEMMAX_MB' "$T/e17b/ram256-squeeze-ship-300.log")/$(grep -c . "$CLOG")" "1/1/0"
  check "ram256 squeeze: sbx refuses without the squeeze-256 climb's ladder.json (not the 1024 MiB one)" \
    "$(mkdir -p "$T/runs/squeeze/ship-300"; printf '{"squeeze": {"stop_n": 64, "memmax_mb": 16384}}\n' >"$T/runs/squeeze/ship-300/ladder.json"; chain E17B_RAM256=1 -- --from ram256-squeeze-sbx --to ram256-squeeze-sbx)/$(grep -c "no $T/runs/squeeze-256/ship-300/ladder.json" "$T/e17b/ram256-squeeze-sbx.log")" "1/1"
  check "probe-overhead: the stage runs probe-overhead.sh: baseline.sh for ship-300 at the default point, under E17B=1" \
    "$(chain -- --from probe-overhead --to probe-overhead)/$(cat "$CLOG")/$([ -f "$T/runs/default/ship-300/N1/baseline.probe-overhead.json" ] && echo kept)" \
    "0/baseline default ship-300 tag=unset memmax=unset e17b=1 ram=unset/kept"
  mkdir -p "$T/runs/default/ship-300/N1-s1"
  printf '{"arm": "ship-300", "moca_commit": "c13d55649777e69ec7649d6fa8c08f4acb1f4e2e"}\n' >"$T/runs/default/ship-300/N1-s1/params.json"
  check "probe-overhead: the commit preflight of default ship-300 runs first: another commit's rung there refuses the stage, nothing run" \
    "$(chain -- --from probe-overhead --to probe-overhead)/$(grep -c 'is not from E17B_MOCA_PIN' "$T/e17b/probe-overhead.log")/$(grep -c . "$CLOG")" "1/1/0"
  rm -rf "$T/runs/default/ship-300/N1-s1"
  check "optional: the ship-30/ship-120 ladder stages SKIP without E17B_OPTIONAL=1, run with it" \
    "$(chain -- --from base-default-ship-30 --to ladder-default-ship-120)/$(grep -c 'SKIP (optional' "$TMP/c.out")/$(chain E17B_OPTIONAL=1 -- --from base-default-ship-30 --to ladder-default-ship-120)/$(calls)" \
    "0/4/0/baseline default ship-30;baseline default ship-120;ladder default ship-30;ladder default ship-120;"
  touch "$TMP/worker-up"
  check "guard: a rung's worker running -> refused before any stage" "$(chain -- --from smoke --to smoke)/$(grep -c 'refusing to preempt it' "$TMP/c.out")/$(grep -c . "$CLOG")" "1/1/0"
  rm -f "$TMP/worker-up"
  printf 'E17B_MOCA_PIN=%s\n' 0000000000000000000000000000000000000000 >"$TMP/pins0.sh"
  check "guard: the placeholder pin is refused before any stage" \
    "$(chain E15_TEST_PINS="$TMP/pins0.sh" -- --from smoke --to smoke)/$(grep -c 'placeholder' "$TMP/c.out")/$(grep -c . "$CLOG")" "1/1/0"
  check "guard: only the staged copy runs" \
    "$(env E15_ROOT="$T" E15_TEST_ROOT="$T" E15_TEST_PINS="$TMP/pins.sh" PATH="$TMP/stub:$PATH" bash "$RIG/chain-e17b.sh" --list >"$TMP/c.out" 2>&1; echo $?)/$(grep -c 'run the staged copy' "$TMP/c.out")" "1/1"
}
# E17B-R36: a stage-changing knob in the caller's environment refuses the chain up front, naming it; the chain's own
# test hooks are honoured only under E17B_TEST_HARNESS=1 (set by chain() above).
test_chain_refuses_stage_knobs() {
  reset
  seal true
  local v out=""
  for v in E15_RUNG E15_MAX_COMMITTED_MB E15_MAX_RUNS E15_LADDER_EXTRA E15_SPREAD_S E15_MEMAVAIL_FLOOR_MIB E15_END_SESSION_RATE \
    E15_ATTACH_TIMEOUT_S E15_BASELINE_MAX_SEEDS E15_WS_DELTA_MB E15_CLASSPROBE E15_PROBE_CALLS E15_PROBE_SEED E15_MEMINFO \
    E15_OS_RELEASE E15_SLICE_DIR E15_STATS_URL E15_PROC E15_DISK_DEV E15_DISK_PATH E15_SQUEEZE_ACTIVE E15_SQUEEZE_RESTORED \
    E15_SQUEEZE_ORIG_MAX E15_SQUEEZE_ORIG_HIGH E15_SQUEEZE_MAX E15_SQUEEZE_HIGH; do
    out+="$v=$(chain "$v=1" -- --from lat-pycache-sbx-n1 --to lat-pycache-sbx-n1):$(grep -c "REFUSED: .*$v" "$TMP/c.out"):$(grep -c . "$CLOG") "
  done
  check "knobs: each stage-changing knob set in the environment refuses the chain (exit 1), naming it, nothing run" \
    "$(printf '%s' "$out" | tr ' ' '\n' | grep -vc '=1:1:0$')" "0"
  check "knobs: an empty value counts as set" "$(chain E15_LADDER_EXTRA= -- --from lat-pycache-sbx-n1 --to lat-pycache-sbx-n1)/$(grep -c . "$CLOG")" "1/0"
  check "knobs: two set are both named" \
    "$(chain E15_LADDER_EXTRA="1280 1536" E15_MAX_RUNS=9 -- --from lat-pycache-sbx-n1 --to lat-pycache-sbx-n1)/$(grep -c 'REFUSED: .*E15_LADDER_EXTRA.*E15_MAX_RUNS\|REFUSED: .*E15_MAX_RUNS.*E15_LADDER_EXTRA' "$TMP/c.out")" "1/1"
  check "knobs: --list is refused too (the chain refuses to start)" "$(chain E15_RUNG=/tmp/x -- --list)/$(grep -c 'REFUSED: .*E15_RUNG' "$TMP/c.out")" "1/1"
  out=$(chain E17B_TEST_HARNESS= -- --from lat-pycache-sbx-n1 --to lat-pycache-sbx-n1)
  check "hooks: without E17B_TEST_HARNESS=1 the test hooks are refused, each named, nothing run" \
    "$out/$(for v in E17B_RUNG E17B_LADDER E17B_BASELINE E17B_SMOKE E17B_OWNWALK E17B_ANALYSIS; do grep -q "REFUSED: .*$v" "$TMP/c.out" && printf '%s ' "$v"; done)/$(grep -c . "$CLOG")" \
    "1/E17B_RUNG E17B_LADDER E17B_BASELINE E17B_SMOKE E17B_OWNWALK E17B_ANALYSIS /0"
  check "hooks: with E17B_TEST_HARNESS=1 they are honoured (the stub rung ran)" \
    "$(chain -- --from lat-pycache-sbx-n1 --to lat-pycache-sbx-n1)/$(calls)" "0/rung sbx 1 pycache;"
  check "knobs: the operator's own inputs are not knobs (E17B_OPTIONAL, E17B_SQUEEZE_MEMMAX_MB, E17B_OVERHEAD_REF, E15_MANIFEST)" \
    "$(chain E17B_OPTIONAL=0 E17B_SQUEEZE_MEMMAX_MB=8192 E17B_OVERHEAD_REF=/tmp/x -- --from lat-pycache-sbx-n1 --to lat-pycache-sbx-n1)" "0"
}
test_chain_lists_stages
test_chain_refuses_stage_knobs
test_chain_refuses_unsealed
test_chain_runs_bringup_unsealed
test_chain_resumes_at_stage
test_chain_squeeze_stages
test_chain_analysis_gate
test_chain_gate_reads_rung_failure_flags
test_chain_verdict_stage
test_chain_preflight_and_guards

echo
if [ "$fails" -eq 0 ]; then echo "chain-e17b.test.sh: all checks passed"; else echo "chain-e17b.test.sh: $fails FAILED"; fi
exit "$([ "$fails" -eq 0 ] && echo 0 || echo 1)"
