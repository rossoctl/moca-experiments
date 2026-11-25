#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted $ here are stub bodies
# experiments/e17-lease/rig/tests/chain-e17d.test.sh
#
# Rig-free tests for chain-e17d.sh (PLAN-E17D Task 7): the stage list and its order, the seal refusal
# (predictions-e17d.json), --from/--to, the knob and switch refusals, the socket check's hook, the N = 1 seal seeds
# (min_seeds, min_warm through level2.py --warm-count, at most 8), the load rungs at the sealed n_load, the squeeze
# climbs, the gate's level2.py, and the verdict stage. The chain runs from a staged copy under a scratch root
# (/srv/e15/src layout); rung.sh, ladder.sh, baseline.sh, smoke.sh, socket-check.sh and the analysis scripts are stubs.
#
# Run: bash experiments/e17-lease/rig/tests/chain-e17d.test.sh      (SHELLCHECK=/path/to/shellcheck if not on PATH)
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

SC="${SHELLCHECK:-$(command -v shellcheck || true)}"
for s in chain-e17d.sh tests/chain-e17d.test.sh; do
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

# --- fixture ------------------------------------------------------------------------------------------------------
T="$TMP/e15-rig-test.chain"
PIN=3333333333333333333333333333333333333333
mkdir -p "$T/src/e15" "$T/src/e17" "$T/state" "$T/runs" "$TMP/stub" "$TMP/an"
cp -R "$E15RIG" "$T/src/e15/rig"
cp -R "$RIG" "$T/src/e17/rig"
CHAIN="$T/src/e17/rig/chain-e17d.sh"
PRED="$T/src/e17/predictions-e17d.json"
printf 'E17B_MOCA_PIN=%s\nE17C_MOCA_PIN=%s\nE17D_MOCA_PIN=%s\n' 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 "$PIN" >"$TMP/pins.sh"
printf '%s\n' "$PIN" >"$T/state/go-stock-e17b"
echo fresh-metal >"$T/state/host_profile"
CLOG="$TMP/calls.log"
printf '#!/usr/bin/env bash\ncase "$*" in *e15-worker.service*) [ -e "%s/worker-up" ] ;; *) exit 1 ;; esac\n' "$TMP" >"$TMP/stub/systemctl"
printf '#!/usr/bin/env bash\n[ "$1" = -n ] && shift\nexec "$@"\n' >"$TMP/stub/sudo"
chmod +x "$TMP/stub/systemctl" "$TMP/stub/sudo"
# a stage stub KIND: logs "KIND ARGS tag= seed= zero= memmax= e17d= e17c= e17b="; fails when the line starts with $FAIL_ON.
# rung writes params.json (arm, n, moca_commit) and record.json (reason ok; STUB_EMPTY_SEEDS lists seeds whose record
# is empty_window); baseline writes N1-s1..N1-s4 and N1/baseline.json.
mkstub() {
  cat >"$TMP/stub-$1.sh" <<SH
#!/usr/bin/env bash
line="$1 \$* tag=\${E15_TAG:-unset} seed=\${E15_SEED:-unset} zero=\${E15_START_ZERO:-unset} memmax=\${E15_SQUEEZE_MEMMAX_MB:-unset} e17d=\${E17D:-unset} e17c=\${E17C:-unset} e17b=\${E17B:-unset}"
echo "\$line" >>"$CLOG"
case "\$line" in "\${FAIL_ON:-NONE}"*) echo "stub failure: \$line" >&2; exit 1 ;; esac
rungdir() { # DIR ARM N REASON
  mkdir -p "\$1"
  printf '{"arm": "%s", "n": %s, "moca_commit": "%s", "driver_exit": 0, "rung_failed": null, "memory_abort": null}\n' "\$2" "\$3" "$PIN" >"\$1/params.json"
  printf '{"aborted": false, "holds": true, "reason": "%s"}\n' "\$4" >"\$1/record.json"
}
case "$1" in
rung)
  r=ok
  case " \${STUB_EMPTY_SEEDS:-} " in *" \${E15_SEED:-x} "*) r=empty_window ;; esac
  rungdir "\$E15_ROOT/runs/\$3/\$1/N\$2\${E15_TAG:+-\$E15_TAG}" "\$1" "\$2" "\$r" ;;
baseline)
  for s in 1 2 3 4; do rungdir "\$E15_ROOT/runs/\$1/\$2/N1-s\$s" "\$2" 1 ok; done
  mkdir -p "\$E15_ROOT/runs/\$1/\$2/N1"
  printf '{}\n' >"\$E15_ROOT/runs/\$1/\$2/N1/baseline.json" ;;
esac
exit 0
SH
  chmod +x "$TMP/stub-$1.sh"
}
for k in rung ladder baseline smoke socket; do mkstub "$k"; done
for a in warmcold_lease lease_ends freed_from_shmem vm_age_lease; do
  cat >"$TMP/an/$a.py" <<PY
import json, os, sys
out = {"warmcold_lease": "warmcold-report.json", "lease_ends": "lease_ends.json", "freed_from_shmem": "shmem.json",
       "vm_age_lease": "vm_age_lease.json"}["$a"]
json.dump({"valid": True, "mapping_valid": True, "criterion4_pass": True, "notices": {}}, open(sys.argv[1] + "/" + out, "w"))
open(os.environ["ALOG"], "a").write("$a %s\n" % " ".join(sys.argv[1:]))
PY
done
# level2.py: the gate's call is logged; --warm-count answers min = (number of rungs) x WARM_PER_SEED
cat >"$TMP/an/level2.py" <<'PY'
import json, os, sys
a = sys.argv[1:]
open(os.environ["ALOG"], "a").write("level2 %s\n" % " ".join(a))
if a and a[0] == "--warm-count":
    n = len(a) - 2
    w = n * int(os.environ.get("WARM_PER_SEED", "10"))
    print(json.dumps({"py_requery": w, "py_refit": w, "min": w}))
else:
    print("restarts 0")
PY
printf 'import os, sys\na = sys.argv[1:]\nos.makedirs(a[a.index("--out") + 1], exist_ok=True)\n' >"$TMP/an/latency_report.py"
printf 'import os, sys\na = sys.argv[1:]\nopen(os.environ["ALOG"], "a").write("verdict_e17d %%s\\n" %% " ".join(a))\nopen(a[a.index("--out") + 1], "w").write("{}")\n' >"$TMP/an/verdict_e17d.py"

seal() { # SEALED [EXTRA JSON FIELDS]
  printf '{"sealed": %s, "n_load": 96, "min_seeds": 4, "min_warm": 20%s}\n' "$1" "${2:-}" >"$PRED"
}
chain() { # [VAR=val ...] -- ARGS
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    envs+=("$1")
    shift
  done
  [ "${1:-}" != -- ] || shift
  : >"$CLOG"
  : >"$TMP/alog"
  env -u E17B -u E17C -u E17D E15_ROOT="$T" E15_TEST_ROOT="$T" E15_TEST_PINS="$TMP/pins.sh" E15_MANIFEST="$TMP/m.md" PATH="$TMP/stub:$PATH" \
    E17D_TEST_HARNESS=1 E17D_RUNG="$TMP/stub-rung.sh" E17D_LADDER="$TMP/stub-ladder.sh" E17D_BASELINE="$TMP/stub-baseline.sh" \
    E17D_SMOKE="$TMP/stub-smoke.sh" E17D_SOCKET_CHECK="$TMP/stub-socket.sh" E17D_ANALYSIS="$TMP/an" ALOG="$TMP/alog" \
    ${envs[@]+"${envs[@]}"} bash "$CHAIN" "$@" >"$TMP/c.out" 2>&1
  echo $?
}
calls() { sed 's/ *tag=.*//' "$CLOG" | tr '\n' ';'; }
reset() { rm -rf "$T/e17d" "$T/runs" && mkdir -p "$T/runs"; }

# --- the stage list ----------------------------------------------------------------------------------------------
ALL="smoke socket-check cal-pycache-l2-sbx cal-pycache-l2-ship-300 cal-pycache-l2-ship-300-l2 memcheck-pycache-l2-ship-300-l2-n128 lat-pycache-l2-sbx-n1 lat-pycache-l2-ship-300-n1 lat-pycache-l2-ship-300-l2-n1 lat-pycache-l2-sbx-n128 lat-pycache-l2-ship-300-n128 lat-pycache-l2-ship-300-l2-n128 base-squeeze-l2-ship-300 base-squeeze-l2-ship-300-l2 squeeze-l2-ship-300 squeeze-l2-ship-300-l2 verdict "
seal false
check "list: exactly the plan's stages, in order" "$(chain -- --list)/$(tail -n +2 "$TMP/c.out" | awk '{print $1}' | tr '\n' ' ')" "0/$ALL"
check "list: only the six bring-up and calibration stages before the seal; every other needs it" \
  "$(tail -n +2 "$TMP/c.out" | awk '$2 == "-" {print $1}' | tr '\n' ' ')/$(tail -n +2 "$TMP/c.out" | awk '$2 != "-" && $2 != "seal"' | wc -l | tr -d ' ')" \
  "smoke socket-check cal-pycache-l2-sbx cal-pycache-l2-ship-300 cal-pycache-l2-ship-300-l2 memcheck-pycache-l2-ship-300-l2-n128 /0"
check "list: says the predictions are not sealed" "$(head -1 "$TMP/c.out" | grep -c 'not sealed')" "1"

# --- the seal ----------------------------------------------------------------------------------------------------
reset
for p in false missing; do
  if [ "$p" = missing ]; then rm -f "$PRED"; else seal false; fi
  check "seal ($p): every stage after it refuses up front, nothing runs" \
    "$(chain -- --from lat-pycache-l2-sbx-n1)/$(grep -c 'E17D REFUSED: predictions' "$TMP/c.out")/$(grep -c . "$CLOG")" "1/1/0"
  check "seal ($p): a run from the start that reaches the seal refuses up front" "$(chain --)/$(grep -c . "$CLOG")" "1/0"
done
seal false
check "seal: --to memcheck runs the six pre-seal stages without it" \
  "$(chain -- --to memcheck-pycache-l2-ship-300-l2-n128)/$(grep -c 'DONE' "$TMP/c.out")" "0/6"
check "bring-up: smoke, socket check, three cal baselines from the first call, the memcheck rung at N=128 (tag memcheck)" \
  "$(grep -E '^(smoke|socket|baseline|rung ship-300-l2 128)' "$CLOG" | sed 's/ seed=[^ ]*//; s/ memmax=.*//' | tr '\n' ';')" \
  "smoke  tag=unset zero=unset;socket  tag=unset zero=unset;baseline pycache-l2 sbx tag=unset zero=1;baseline pycache-l2 ship-300 tag=unset zero=1;baseline pycache-l2 ship-300-l2 tag=unset zero=1;rung ship-300-l2 128 pycache-l2 tag=memcheck zero=unset;"
check "every stage runs under E17D=1 E17C=1 E17B=1" "$(grep -vc 'e17d=1 e17c=1 e17b=1' "$CLOG")" "0"
check "the chain itself checks the seal right before a stage that needs it (in the loop)" \
  "$(grep -c 'if \[ "$(s_needs "$st")" != - \] && ! sealed; then' "$RIG/chain-e17d.sh")" "1"

# --- --from / --to -----------------------------------------------------------------------------------------------
check "--from/--to: unknown names and a reversed range are usage errors (exit 2), nothing runs" \
  "$(chain -- --from nowhere)/$(chain -- --to nowhere)/$(chain -- --from verdict --to smoke)/$(grep -c . "$CLOG")" "2/2/2/0"
reset
check "--from/--to: one named stage" "$(chain -- --from socket-check --to socket-check)/$(calls)" "0/socket;"
check "resume: without --from the chain starts at the first stage without its .done" \
  "$(chain -- --to cal-pycache-l2-sbx)/$(grep -c "resuming at smoke" "$TMP/c.out")" "0/1"

# --- refusals ----------------------------------------------------------------------------------------------------
for k in E15_SPREAD_S E17C_GATE_LIBRARY E17C_OPTIONAL E17B_RAM256; do
  check "refusal: $k set (even empty) refuses the chain, nothing runs" "$(chain "$k=" -- --list)/$(grep -c "$k" "$TMP/c.out")" "1/1"
done
check "refusal: E17B_SQUEEZE_MEMMAX_MB other than 24576 refuses; 24576 is accepted" \
  "$(chain E17B_SQUEEZE_MEMMAX_MB=16384 -- --list)/$(chain E17B_SQUEEZE_MEMMAX_MB=24576 -- --list)" "1/0"
check "refusal: a test hook without the harness switch refuses the chain" \
  "$(env -u E17B -u E17C -u E17D E15_ROOT="$T" E15_TEST_ROOT="$T" E15_TEST_PINS="$TMP/pins.sh" E17D_RUNG=x bash "$CHAIN" --list >"$TMP/c.out" 2>&1; echo $?)/$(grep -c 'E17D_RUNG' "$TMP/c.out")" "1/1"

# --- the socket check (Task 9's script) --------------------------------------------------------------------------
reset
check "socket-check: without socket-check.sh the stage fails, naming Task 9" \
  "$(chain E17D_SOCKET_CHECK="$TMP/none.sh" -- --from socket-check --to socket-check)/$(grep -c "Task 9" "$T/e17d/socket-check.log")" "1/1"

# --- after the seal: N = 1 seeds, load rungs, squeeze, verdict ---------------------------------------------------
seal true
reset
check "seal seeds: sbx runs seeds from 11 until min_seeds (4) are evaluable" \
  "$(chain -- --from lat-pycache-l2-sbx-n1 --to lat-pycache-l2-sbx-n1)/$(grep -o 'seed=[0-9]*' "$CLOG" | tr '\n' ' ')/$(grep -c 'zero=1' "$CLOG")" \
  "0/seed=11 seed=12 seed=13 seed=14 /4"
reset
check "seal seeds: an empty_window seed is not evaluable, the next one runs" \
  "$(chain STUB_EMPTY_SEEDS=12 -- --from lat-pycache-l2-sbx-n1 --to lat-pycache-l2-sbx-n1)/$(grep -o 'seed=[0-9]*' "$CLOG" | tr '\n' ' ')" \
  "0/seed=11 seed=12 seed=13 seed=14 seed=15 "
reset
check "seal seeds: a lease arm runs past min_seeds until the warm minimum (20) is met (level2.py --warm-count)" \
  "$(chain WARM_PER_SEED=4 -- --from lat-pycache-l2-ship-300-l2-n1 --to lat-pycache-l2-ship-300-l2-n1)/$(grep -o 'seed=[0-9]*' "$CLOG" | tr '\n' ' ')/$(grep -c '^level2 --warm-count py_requery,py_refit' "$TMP/alog")" \
  "0/seed=11 seed=12 seed=13 seed=14 seed=15 /5"
reset
check "seal seeds: at most 8 seeds; short of the minimum the stage is DONE with a note (N = 1 not judged)" \
  "$(chain WARM_PER_SEED=1 -- --from lat-pycache-l2-ship-300-n1 --to lat-pycache-l2-ship-300-n1)/$(grep -c '^rung ' "$CLOG")/$(grep -c 'DONE.*8 seeds give 8 evaluable seed(s) and a warm minimum of 8.*not judged' "$TMP/c.out")" \
  "0/8/1"
reset
check "load rungs: each arm at the sealed n_load (96: N96-lat), tag lat" \
  "$(chain -- --from lat-pycache-l2-sbx-n128 --to lat-pycache-l2-ship-300-l2-n128)/$(calls)" \
  "0/rung sbx 96 pycache-l2;rung ship-300 96 pycache-l2;rung ship-300-l2 96 pycache-l2;"
check "load rungs: tag lat, so the verdict finds N96-lat" "$(grep -c 'tag=lat ' "$CLOG")/$([ -d "$T/runs/pycache-l2/ship-300-l2/N96-lat" ] && echo dir)" "3/dir"
check "gate: level2.py runs on the ship-300-l2 rung, paired with the same-named ship-300 rung; not on the others" \
  "$(grep '^level2 ' "$TMP/alog" | sed "s#$T/runs/##g")" "level2 pycache-l2/ship-300-l2/N96-lat --paired pycache-l2/ship-300/N96-lat"
check "gate: vm_age_lease.py gets the same-named sbx rung" "$(grep -c "^vm_age_lease .*ship-300-l2/N96-lat --sbx $T/runs/pycache-l2/sbx/N96-lat" "$TMP/alog")" "1"
seal true ', "n_load": 0'
reset
check "load rungs: a sealed file without a positive n_load fails the stage, naming it" \
  "$(chain -- --from lat-pycache-l2-sbx-n128 --to lat-pycache-l2-sbx-n128)/$(grep -c 'no positive integer "n_load"' "$T/e17d/lat-pycache-l2-sbx-n128.log")/$(grep -c . "$CLOG")" "1/1/0"
seal true
reset
check "squeeze: the baselines, then both lease arms climb at 24576 MiB" \
  "$(chain -- --from base-squeeze-l2-ship-300 --to squeeze-l2-ship-300-l2)/$(sed 's/ tag=[^ ]*//; s/ seed=[^ ]*//; s/ zero=[^ ]*//; s/ e17d=.*//' "$CLOG" | tr '\n' ';')" \
  "0/baseline squeeze-l2 ship-300 memmax=unset;baseline squeeze-l2 ship-300-l2 memmax=unset;ladder squeeze-l2 ship-300 memmax=24576;ladder squeeze-l2 ship-300-l2 memmax=24576;"
check "verdict: verdict_e17d.py over the runs at the pin, with the staged predictions, to e17d/verdict.json" \
  "$(chain -- --from verdict)/$(grep -c "^verdict_e17d $T/runs --moca-commit $PIN --predictions $PRED --out $T/e17d/verdict.json" "$TMP/alog")" "0/1"
check "a failing stage stops the chain with resume with --from" \
  "$(chain FAIL_ON=ladder -- --from squeeze-l2-ship-300)/$(grep -c 'squeeze-l2-ship-300 FAILED.*resume with --from squeeze-l2-ship-300' "$TMP/c.out")/$(grep -c 'verdict' "$TMP/alog")" "1/1/0"
check "preflight: a rung from another moca commit under the arm refuses the stage" \
  "$(mkdir -p "$T/runs/pycache-l2/sbx/N1-l99" && echo '{"moca_commit": "other"}' >"$T/runs/pycache-l2/sbx/N1-l99/params.json"; chain -- --from lat-pycache-l2-sbx-n1 --to lat-pycache-l2-sbx-n1)/$(grep -c 'is not from E17D_MOCA_PIN' "$T/e17d/lat-pycache-l2-sbx-n1.log")" "1/1"

echo
if [ "$fails" -eq 0 ]; then echo "chain-e17d.test.sh: all checks passed"; else echo "chain-e17d.test.sh: $fails FAILED"; fi
exit "$([ "$fails" -eq 0 ] && echo 0 || echo 1)"
