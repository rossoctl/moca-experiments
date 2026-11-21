#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted $ here are stub bodies
# experiments/e17-lease/rig/tests/chain-e17c.test.sh
#
# Rig-free tests for chain-e17c.sh (PLAN-E17C Task 4): the stage list, its order and needs, the seal refusal
# (predictions-e17c.json), the refusal of E15_* stage knobs and of E17b's switches, the bring-up stages allowed before
# the seal, the gate stages that Tasks 9 and 10 build (listing, needs, seal only: ruling R-b), the cal stages (N = 1
# baselines from E15_START_ZERO=1, topped up to 4 seeds), the squeeze value, the 500 000-file walk's refusal (moca #907)
# and the verdict stage. The chain runs from a staged copy under a scratch root (/srv/e15/src layout); rung.sh,
# ladder.sh, baseline.sh, smoke.sh, ownwalk.sh and the analysis scripts are stubs that log their calls.
#
# Run: bash experiments/e17-lease/rig/tests/chain-e17c.test.sh      (SHELLCHECK=/path/to/shellcheck if not on PATH)
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
for s in chain-e17c.sh tests/chain-e17c.test.sh; do
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
PIN=2222222222222222222222222222222222222222
mkdir -p "$T/src/e15" "$T/src/e17" "$T/state" "$T/runs" "$TMP/stub" "$TMP/an"
cp -R "$E15RIG" "$T/src/e15/rig"
cp -R "$E15RIG/../analysis" "$T/src/e15/analysis" # the gate reads calls.jsonl through holds.py, as baseline.sh does
cp -R "$RIG" "$T/src/e17/rig"
# gate-256 (Task 10): the 256 MiB library, gate256.py, and the pycache corpus its probe draws py_analyze from
mkdir -p "$T/src/e17/workload" "$T/src/e17/analysis" "$T/corpora/pycache"
cp "$RIG/../workload/library-256.json" "$T/src/e17/workload/library-256.json"
cp "$RIG/../analysis/gate256.py" "$T/src/e17/analysis/gate256.py"
printf '{"session":"s","user":"u","provider":"p","calls":[{"i":0,"class":"py_analyze","skeleton":"x","dur_ms":15000,"work_ms":15000,"gap_ms":2000,"offset_ms":0,"out_bytes":0,"chain":false}]}\n' >"$T/corpora/pycache/corpus.jsonl"
CHAIN="$T/src/e17/rig/chain-e17c.sh"
PRED="$T/src/e17/predictions-e17c.json"
printf 'E17B_MOCA_PIN=%s\nE17C_MOCA_PIN=%s\n' 1111111111111111111111111111111111111111 "$PIN" >"$TMP/pins.sh"
printf '%s\n' "$PIN" >"$T/state/go-stock-e17b"
echo fresh-metal >"$T/state/host_profile"
CLOG="$TMP/calls.log"
printf '#!/usr/bin/env bash\ncase "$*" in *e15-worker.service*) [ -e "%s/worker-up" ] ;; *) exit 1 ;; esac\n' "$TMP" >"$TMP/stub/systemctl"
printf '#!/usr/bin/env bash\n[ "$1" = -n ] && shift\nexec "$@"\n' >"$TMP/stub/sudo"
chmod +x "$TMP/stub/systemctl" "$TMP/stub/sudo"
# a stage stub KIND: logs "KIND ARGS tag=<E15_TAG> seed=<E15_SEED> zero=<E15_START_ZERO> memmax=<...> e17c=<E17C>
# e17b=<E17B> ram=<E17B_GUEST_RAM_MB> win=<E15_WINDOW_S>"; fails when the logged call starts with $FAIL_ON. rung writes the
# rung's params.json, record.json (reason STUB_REASON) and calls.jsonl from STUB_CALLS ("class:in_window[:status],...";
# STUB_CALLS_<tag> overrides it for that tag, for every arm or, with STUB_LOW_ARM, that arm only); baseline writes
# seeds N1-s1..N1-s$STUB_SEEDS (default 3) and N1/baseline.json; ladder at a squeeze point a ladder.json with squeeze.stop_n 40 and the memmax it ran under.
mkstub() {
  cat >"$TMP/stub-$1.sh" <<SH
#!/usr/bin/env bash
line="$1 \$* tag=\${E15_TAG:-unset} seed=\${E15_SEED:-unset} zero=\${E15_START_ZERO:-unset} memmax=\${E15_SQUEEZE_MEMMAX_MB:-unset} e17c=\${E17C:-unset} e17b=\${E17B:-unset} ram=\${E17B_GUEST_RAM_MB:-unset} win=\${E15_WINDOW_S:-unset}"
echo "\$line" >>"$CLOG"
case "\$line" in "\${FAIL_ON:-NONE}"*) echo "stub failure: \$line" >&2; exit 1 ;; esac
rungdir() { # DIR ARM REASON
  mkdir -p "\$1"
  printf '{"arm": "%s", "n": 1, "moca_commit": "%s", "driver_exit": 0, "rung_failed": null, "memory_abort": null}\n' "\$2" "\${STUB_COMMIT:-$PIN}" >"\$1/params.json"
  printf '{"aborted": false, "holds": true, "reason": "%s"}\n' "\$3" >"\$1/record.json"
  local v=STUB_CALLS_\${E15_TAG:-none} spec=\${STUB_CALLS:-} i=0 c
  v=\${v//-/_} # a tag with a dash (g256-s8) is not a variable name
  if [ -n "\${!v+x}" ] && { [ -z "\${STUB_LOW_ARM:-}" ] || [ "\$STUB_LOW_ARM" = "\$2" ]; }; then spec=\${!v}; fi
  : >"\$1/calls.jsonl"
  for c in \${spec//,/ }; do
    IFS=: read -r cl w st <<<"\$c"
    printf '{"session": 0, "call": %d, "class": "%s", "in_window": %s, "status": "%s", "observed_ms": 100}\n' \
      "\$i" "\$cl" "\$([ "\$w" = 1 ] && echo true || echo false)" "\${st:-ok}" >>"\$1/calls.jsonl"
    i=\$((i + 1))
  done
}
# gate-256's rungs (E17C_GATE_LIBRARY set): 20 py_analyze rows; STUB_G256 "ARM/SCALE=RSS_MIB/OOMS ..." (default 100/0)
g256calls() { # DIR ARM
  echo "lib=\$(basename "\$E17C_GATE_LIBRARY") ovr=\${E15_CORPUS_OVERRIDE#"\$E15_ROOT"/} maxs=\${E15_MAX_SESSIONS:-unset} warm=\${E15_WARMUP_S:-unset} spread=\${E15_SPREAD_S:-unset}" >>"$TMP/g256.log"
  python3 - "\$1" "\$2" "\${E15_TAG#g256-s}" "\${E17B_GUEST_RAM_MB:-1024}" "\${STUB_G256:-}" <<'PYG'
import json, sys
d, arm, scale, ram, spec = sys.argv[1:]
rss, ooms = 100, 0
for e in spec.split():
    k, v = e.split("=")
    if k == arm + "/" + scale:
        rss, ooms = (int(x) for x in v.split("/"))
p = json.load(open(d + "/params.json"))
p["guest_ram_mb"] = int(ram)
json.dump(p, open(d + "/params.json", "w"))
with open(d + "/calls.jsonl", "w") as f:
    for i in range(20):
        r = {"session": 0, "call": i, "class": "py_analyze", "in_window": True, "observed_ms": 4000.0 + i}
        if i < ooms:
            r.update(status="err", cause="exit_mismatch", exit=90, failed_rc=137, stdout="")
        else:
            r.update(status="ok", exit=0, stdout="rows=1 peak_rss_kb=%d" % (rss * 1024))
        f.write(json.dumps(r).replace("rows=1 peak", "rows=1" + chr(92) + "npeak") + chr(10))
PYG
}
case "$1" in
rung)
  rungdir "\$E15_ROOT/runs/\$3/\$1/N\$2\${E15_TAG:+-\$E15_TAG}" "\$1" "\${STUB_REASON:-ok}"
  [ -z "\${E17C_GATE_LIBRARY:-}" ] || g256calls "\$E15_ROOT/runs/\$3/\$1/N\$2\${E15_TAG:+-\$E15_TAG}" "\$1" ;;
baseline)
  for s in \$(seq 1 "\${STUB_SEEDS:-3}"); do rungdir "\$E15_ROOT/runs/\$1/\$2/N1-s\$s" "\$2" ok; done
  mkdir -p "\$E15_ROOT/runs/\$1/\$2/N1"
  printf '{"class_medians": {"build": 1.0}}\n' >"\$E15_ROOT/runs/\$1/\$2/N1/baseline.json" ;;
ladder)
  if [ "\${1#squeeze}" != "\$1" ]; then
    mkdir -p "\$E15_ROOT/runs/\$1/\$2"
    printf '{"squeeze": {"stop_n": 40, "memmax_mb": %s}}\n' "\$E15_SQUEEZE_MEMMAX_MB" >"\$E15_ROOT/runs/\$1/\$2/ladder.json"
  fi ;;
esac
exit 0
SH
  chmod +x "$TMP/stub-$1.sh"
}
for k in rung ladder baseline smoke ownwalk; do mkstub "$k"; done
# analysis stubs: every gate script passes (E17b's gate itself is tested in chain-e17b.test.sh; the code is the same)
cat >"$TMP/an/warmcold_lease.py" <<'PY'
import json, os, sys
json.dump({"unknown": 0, "disagreements": 0, "failed_no_vm": 0, "config_refusals": 0, "valid": True}, open(sys.argv[1] + "/warmcold-report.json", "w"))
open(os.environ["ALOG"], "a").write("warmcold_lease %s\n" % sys.argv[1])
PY
cat >"$TMP/an/lease_ends.py" <<'PY'
import json, os, sys
json.dump({"notices": {}, "valid": True, "criterion4_pass": True}, open(sys.argv[1] + "/lease_ends.json", "w"))
open(os.environ["ALOG"], "a").write("lease_ends %s\n" % sys.argv[1])
PY
cat >"$TMP/an/freed_from_shmem.py" <<'PY'
import json, os, sys
json.dump({}, open(sys.argv[1] + "/shmem.json", "w"))
PY
cat >"$TMP/an/vm_age_lease.py" <<'PY'
import json, os, sys
json.dump({"mapping_valid": True}, open(sys.argv[1] + "/vm_age_lease.json", "w"))
open(os.environ["ALOG"], "a").write("vm_age_lease %s\n" % " ".join(sys.argv[1:]))
PY
cat >"$TMP/an/latency_report.py" <<'PY'
import os, sys
a = sys.argv[1:]
os.makedirs(a[a.index("--out") + 1], exist_ok=True)
PY
VERDICT_STUB='import os, sys
a = sys.argv[1:]
open(os.environ["ALOG"], "a").write("verdict_e17c %s\n" % " ".join(a))
open(a[a.index("--out") + 1], "w").write("{}")'

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
  env -u E17B -u E17C E15_ROOT="$T" E15_TEST_ROOT="$T" E15_TEST_PINS="$TMP/pins.sh" E15_MANIFEST="$TMP/m.md" PATH="$TMP/stub:$PATH" \
    E17C_TEST_HARNESS=1 E17C_RUNG="$TMP/stub-rung.sh" E17C_LADDER="$TMP/stub-ladder.sh" E17C_BASELINE="$TMP/stub-baseline.sh" E17C_SMOKE="$TMP/stub-smoke.sh" \
    E17C_OWNWALK="$TMP/stub-ownwalk.sh" E17C_ANALYSIS="$TMP/an" ALOG="$TMP/alog" ${envs[@]+"${envs[@]}"} bash "$CHAIN" "$@" >"$TMP/c.out" 2>&1
  echo $?
}
calls() { sed 's/ *tag=.*//' "$CLOG" | tr '\n' ';'; }
LIB256="$T/src/e17/workload/library-256.json"
reset() { rm -rf "$T/e17c" "$T/runs" && mkdir -p "$T/runs" && cp "$RIG/../workload/library-256.json" "$LIB256" && : >"$TMP/g256.log"; }
GATE="$T/runs/pycache-low/gate-pycache-low.json"
gate_file() { # PASS REASON [COMMIT WINDOW START_ZERO]: a gate-pycache-low.json as the gate writes it
  mkdir -p "$T/runs/pycache-low"
  printf '{"stage": "gate-pycache-low", "pass": %s, "reason": "%s", "moca_commit": "%s", "window_s": %s, "start_zero": %s, "arms": {}}\n' \
    "$1" "$2" "${3:-$PIN}" "${4:-1800}" "${5:-true}" >"$GATE"
}
gq() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): v = v[int(k)] if isinstance(v, list) else v[k]
print(json.dumps(v, sort_keys=True))' "$GATE" "$1" 2>/dev/null || echo unreadable; }
G256="$T/runs/pycache-d64/gate-256.json"
g256_file() { # PASS SCALE [COMMIT]: a gate-256.json as the gate writes it (the fields the ram256 stages read)
  mkdir -p "$T/runs/pycache-d64"
  printf '{"stage": "gate-256", "pass": %s, "chosen_scale": %s, "reason": "scale 1: 3 OOM kill(s)", "moca_commit": "%s", "guest_ram_mb": 256}\n' \
    "$1" "$2" "${3:-$PIN}" >"$G256"
}
lib256() { # SCALE: the staged library-256.json with py_analyze at SCALE (the committed change the gate's scale needs)
  python3 -c 'import json,sys; sys.path.insert(0, sys.argv[4]); import gate256; l=json.load(open(sys.argv[1])); l["classes"]["py_analyze"][0]["cmd"]=gate256.analyze_cmd(int(sys.argv[2])); json.dump(l, open(sys.argv[3], "w"))' \
    "$RIG/../workload/library-256.json" "$1" "$LIB256" "$RIG/../analysis"
}
g2q() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): v = v[int(k)] if isinstance(v, list) else v[k]
print(json.dumps(v, sort_keys=True))' "$G256" "$1" 2>/dev/null || echo unreadable; }
listed() { sed -n '2,$p' "$TMP/c.out" | awk '{print $1 ":" $2}' | tr '\n' ' '; }

STAGES_WANT="smoke:- cal-pycache-sbx:- cal-pycache-ship-300:- cal-pycache-ship-300-nd:- gate-pycache-low:- gate-256:- \
lat-pycache-sbx-n1:seal lat-pycache-ship-300-n1:seal lat-pycache-ship-300-nd-n1:seal \
lat-pycache-sbx-n128:seal lat-pycache-ship-300-n128:seal lat-pycache-ship-300-nd-n128:seal \
base-pycache-low-sbx:seal base-pycache-low-ship-300:seal lat-pycache-low-sbx-n128:seal lat-pycache-low-ship-300-n128:seal \
base-squeeze-sbx:seal base-squeeze-ship-300:seal squeeze-ship-300:seal squeeze-sbx:seal ownwalk:seal \
ram256-pycache-sbx-n1:ram256 ram256-pycache-ship-300-n1:ram256 ram256-base-squeeze-sbx:ram256 ram256-base-squeeze-ship-300:ram256 \
ram256-squeeze-ship-300:ram256 ram256-squeeze-sbx:ram256 \
base-default-sbx:opt base-default-ship-300:opt ladder-default-sbx:opt ladder-default-ship-300:opt ownwalk-500k:opt verdict:seal "

test_list() {
  reset
  rm -f "$PRED"
  check "list: exit 0, the predictions state (predictions-e17c.json) in the header" \
    "$(chain -- --list)/$(head -1 "$TMP/c.out" | grep -c '^E17C stages (predictions: missing (.*predictions-e17c.json))')" "0/1"
  check "list: the stages in order, each with its needs (- before the seal, seal, ram256, opt)" "$(listed)" "$STAGES_WANT"
  check "list: the header names E17C_OPTIONAL and E17C_RAM256" \
    "$(head -1 "$TMP/c.out" | grep -c 'opt (E17C_OPTIONAL=1), ram256 (E17C_RAM256=1)')" "1"
  check "list: the commands (smoke, cal at pycache, the gates, ownwalk 10000 100000, the 500k walk, verdict)" \
    "$(awk '$1 == "smoke" || $1 == "cal-pycache-ship-300-nd" || $1 == "gate-pycache-low" || $1 == "gate-256" || $1 == "ownwalk" || $1 == "ownwalk-500k" || $1 == "squeeze-ship-300" || $1 == "verdict" {print $1 "=" $4, $5, $6}' "$TMP/c.out" | sed 's/ *#.*//; s/ *$//' | tr '\n' ';')" \
    "smoke=smoke;cal-pycache-ship-300-nd=cal pycache ship-300-nd;gate-pycache-low=gate-pycache-low;gate-256=gate-256;squeeze-ship-300=squeeze-ladder squeeze ship-300;ownwalk=ownwalk 10000 100000;ownwalk-500k=ownwalk-big 500000;verdict=verdict;"
  check "list: the 500k walk's note names moca #907; the squeeze's names 24576" \
    "$(grep -c '^ownwalk-500k .*# .*moca #907' "$TMP/c.out")/$(grep -c '^squeeze-ship-300 .*# .*24576' "$TMP/c.out")" "1/1"
}

# Ruling R-h: the operator's E15_* knobs are refused, as chain-e17b.sh refuses them; E17b's switches are refused too.
test_refuses_knobs() {
  reset
  seal true
  local v out=""
  for v in E15_RUNG E15_MAX_COMMITTED_MB E15_MAX_RUNS E15_LADDER_EXTRA E15_SPREAD_S E15_MEMAVAIL_FLOOR_MIB E15_END_SESSION_RATE \
    E15_ATTACH_TIMEOUT_S E15_BASELINE_MAX_SEEDS E15_WS_DELTA_MB E15_CLASSPROBE E15_PROBE_CALLS E15_PROBE_SEED E15_MEMINFO \
    E15_OS_RELEASE E15_SLICE_DIR E15_STATS_URL E15_PROC E15_DISK_DEV E15_DISK_PATH E15_SQUEEZE_ACTIVE E15_SQUEEZE_RESTORED \
    E15_SQUEEZE_ORIG_MAX E15_SQUEEZE_ORIG_HIGH E15_SQUEEZE_MAX E15_SQUEEZE_HIGH; do
    out+="$v=$(chain "$v=1" -- --from lat-pycache-sbx-n128 --to lat-pycache-sbx-n128):$(grep -c "E17C REFUSED: .*$v" "$TMP/c.out"):$(grep -c . "$CLOG") "
  done
  check "knobs: each E15_* stage knob set in the environment refuses the chain (exit 1), naming it, nothing run" \
    "$(printf '%s' "$out" | tr ' ' '\n' | grep -vc '=1:1:0$')" "0"
  check "knobs: an empty value counts as set; --list is refused too" \
    "$(chain E15_LADDER_EXTRA= -- --from lat-pycache-sbx-n128 --to lat-pycache-sbx-n128)/$(grep -c . "$CLOG")/$(chain E15_RUNG=/tmp/x -- --list)" "1/0/1"
  out=""
  for v in E17B_OPTIONAL E17B_RAM256; do
    out+="$v=$(chain "$v=1" -- --list):$(grep -c "E17C REFUSED: .*$v.*E17C_" "$TMP/c.out") "
  done
  check "knobs: E17b's switches (E17B_OPTIONAL, E17B_RAM256) are refused, naming E17c's" "$out" "E17B_OPTIONAL=1:1 E17B_RAM256=1:1 "
  check "knobs: E17B_SQUEEZE_MEMMAX_MB other than 24576 is refused (spec §13.2); 24576 is accepted" \
    "$(chain E17B_SQUEEZE_MEMMAX_MB=16384 -- --list)/$(grep -c 'REFUSED: E17B_SQUEEZE_MEMMAX_MB=16384.*24576' "$TMP/c.out")/$(chain E17B_SQUEEZE_MEMMAX_MB=24576 -- --list)" "1/1/0"
  out=$(chain E17C_TEST_HARNESS= -- --from lat-pycache-sbx-n128 --to lat-pycache-sbx-n128)
  check "hooks: without E17C_TEST_HARNESS=1 the test hooks are refused, each named, nothing run" \
    "$out/$(for v in E17C_RUNG E17C_LADDER E17C_BASELINE E17C_SMOKE E17C_OWNWALK E17C_ANALYSIS; do grep -q "REFUSED: .*$v" "$TMP/c.out" && printf '%s ' "$v"; done)/$(grep -c . "$CLOG")" \
    "1/E17C_RUNG E17C_LADDER E17C_BASELINE E17C_SMOKE E17C_OWNWALK E17C_ANALYSIS /0"
  check "knobs: the operator's own inputs are not knobs (E17C_OPTIONAL, E17C_RAM256, E15_MANIFEST)" \
    "$(chain E17C_OPTIONAL=0 E17C_RAM256=0 -- --from lat-pycache-sbx-n128 --to lat-pycache-sbx-n128)/$(calls)" "0/rung sbx 128 pycache;"
}

test_refuses_unsealed() {
  local v
  for v in missing false '"true"' broken; do
    reset
    case "$v" in missing) rm -f "$PRED" ;; broken) printf '{"sealed": true,' >"$PRED" ;; *) seal "$v" ;; esac
    printf '%s:%s:%s:%s ' "$v" "$(chain)" "$(grep -c 'E17C REFUSED: predictions' "$TMP/c.out")" "$(grep -c . "$CLOG")"
  done >"$TMP/ref.out"
  check "seal: refused up front (exit 1, nothing run) unless predictions-e17c.json says \"sealed\": true (the boolean)" \
    "$(cat "$TMP/ref.out")" 'missing:1:1:0 false:1:1:0 "true":1:1:0 broken:1:1:0 '
  check "seal: the refusal names the stages that need it and how to stop before them" \
    "$(grep -c 'stages that need the seal: lat-pycache-sbx-n1 .* (stop before them with --to gate-256)' "$TMP/c.out")" "1"
  reset
  rm -f "$PRED"
  local st out=""
  for st in lat-pycache-ship-300-nd-n128 squeeze-ship-300 ownwalk verdict; do
    out+="$st=$(chain -- --from "$st" --to "$st"):$(grep -c . "$CLOG") "
  done
  check "seal: a seal stage alone is refused while unsealed, nothing run" "$out" "lat-pycache-ship-300-nd-n128=1:0 squeeze-ship-300=1:0 ownwalk=1:0 verdict=1:0 "
  check "seal: a ram256 or opt stage needs the seal too" \
    "$(chain E17C_RAM256=1 -- --from ram256-pycache-sbx-n1 --to ram256-pycache-sbx-n1)/$(chain E17C_OPTIONAL=1 -- --from ladder-default-sbx --to ladder-default-sbx)/$(grep -c . "$CLOG")" "1/1/0"
  check "seal: the gate stages run before the seal (not refused as needing it)" \
    "$(chain -- --from gate-pycache-low --to gate-pycache-low)/$(grep -c 'REFUSED' "$TMP/c.out")/$(grep -c 'E17C gate-pycache-low DONE' "$TMP/c.out")/$(chain -- --from gate-256 --to gate-256)/$(grep -c 'REFUSED' "$TMP/c.out")/$(grep -c 'E17C gate-256 DONE' "$TMP/c.out")" \
    "0/0/1/0/0/1"
}

test_bringup_unsealed() {
  reset
  rm -f "$PRED"
  check "bring-up: --to cal-pycache-ship-300-nd runs without the seal: smoke, then the three cal stages" \
    "$(chain -- --to cal-pycache-ship-300-nd)/$(calls)" \
    "0/smoke;baseline pycache sbx;rung sbx 1 pycache;baseline pycache ship-300;rung ship-300 1 pycache;baseline pycache ship-300-nd;rung ship-300-nd 1 pycache;"
  check "bring-up: every stage ran with E17C=1 and E17B=1, its log and .done under \$E15_ROOT/e17c" \
    "$(grep -c 'e17c=1 e17b=1 ' "$CLOG")/$(find "$T/e17c" -name '*.log' | wc -l | tr -d ' ')/$(find "$T/e17c" -name '*.done' | wc -l | tr -d ' ')/$([ -e "$T/e17b" ] && echo e17b || echo none)" "7/4/4/none"
  check "cal: the baseline and the top-up seed run with E15_START_ZERO=1; the 4th seed is E15_SEED=4, tag s4" \
    "$(grep '^baseline pycache sbx\|^rung sbx 1 pycache' "$CLOG" | sed 's/ memmax=.*//' | tr '\n' ';')" \
    "baseline pycache sbx tag=unset seed=unset zero=1;rung sbx 1 pycache tag=s4 seed=4 zero=1;"
  reset
  check "cal: a baseline that ran 4 or more evaluable seeds is not topped up" \
    "$(chain STUB_SEEDS=5 -- --from cal-pycache-sbx --to cal-pycache-sbx)/$(calls)" "0/baseline pycache sbx;"
  reset
  check "cal: a top-up seed with an empty window does not count; the next seed runs" \
    "$(chain STUB_REASON=empty_window -- --from cal-pycache-sbx --to cal-pycache-sbx)/$(calls)" \
    "1/baseline pycache sbx;rung sbx 1 pycache;rung sbx 1 pycache;rung sbx 1 pycache;rung sbx 1 pycache;rung sbx 1 pycache;rung sbx 1 pycache;rung sbx 1 pycache;rung sbx 1 pycache;rung sbx 1 pycache;"
  check "cal: after 12 seeds without 4 evaluable ones the stage fails, naming it" "$(grep -c '12 seeds gave 3 evaluable' "$T/e17c/cal-pycache-sbx.log")" "1"
  reset
  # review fix 1: a corrupt record.json from before the stage (a --from resume) makes the seed count unreadable: the stage
  # fails, never "done" with fewer than 4 seeds (5 good seeds here: without the corrupt one it would not top up)
  mkdir -p "$T/runs/pycache/sbx/N1-s9"
  printf '{"reason": ' >"$T/runs/pycache/sbx/N1-s9/record.json"
  check "cal: a corrupt N1-s* record.json fails the stage (unreadable seeds), no .done, no top-up rung" \
    "$(chain STUB_SEEDS=5 -- --from cal-pycache-sbx --to cal-pycache-sbx)/$(grep -c 'seeds under .*pycache/sbx are unreadable' "$T/e17c/cal-pycache-sbx.log")/$([ -f "$T/e17c/cal-pycache-sbx.done" ] && echo "done" || echo open)/$(calls)" \
    "1/1/open/baseline pycache sbx;"
  reset
  check "smoke: the commit preflight covers E17c's three arms (another commit's ship-300-nd rung refuses the stage)" \
    "$(mkdir -p "$T/runs/pycache/ship-300-nd/N1-old"; printf '{"arm": "ship-300-nd", "moca_commit": "c13d55649777e69ec7649d6fa8c08f4acb1f4e2e"}\n' >"$T/runs/pycache/ship-300-nd/N1-old/params.json"; chain -- --from smoke --to smoke)/$(grep -c 'is not from E17C_MOCA_PIN' "$T/e17c/smoke.log")/$(grep -c . "$CLOG")" "1/1/0"
  reset
  check "bring-up: --to gate-256 runs smoke, the cal stages and both gates, every one before the seal" \
    "$(chain -- --to gate-256)/$(grep -c 'E17C gate-pycache-low DONE' "$TMP/c.out")/$(grep -c 'E17C gate-256 DONE' "$TMP/c.out")" "0/1/1"
}

test_sealed_stages() {
  reset
  seal true
  gate_file true "every seed passed"
  check "sealed: the pycache, pycache-low and squeeze stages in order; the squeeze climb at 24576 without any operator value" \
    "$(chain -- --from lat-pycache-sbx-n128 --to squeeze-sbx)/$(sed 's/ seed=.*memmax=/ memmax=/; s/ e17c=.*//' "$CLOG" | tr '\n' ';')" \
    "0/rung sbx 128 pycache tag=lat memmax=unset;rung ship-300 128 pycache tag=lat memmax=unset;rung ship-300-nd 128 pycache tag=lat memmax=unset;baseline pycache-low sbx tag=unset memmax=unset;baseline pycache-low ship-300 tag=unset memmax=unset;rung sbx 128 pycache-low tag=lat memmax=unset;rung ship-300 128 pycache-low tag=lat memmax=unset;baseline squeeze sbx tag=unset memmax=unset;baseline squeeze ship-300 tag=unset memmax=unset;ladder squeeze ship-300 tag=unset memmax=24576;rung sbx 40 squeeze tag=sq memmax=24576;"
  check "sealed: ship-300-nd rungs go through the analysis gate (a ship-* arm), with --sbx the same-named sbx rung" \
    "$(chain -- --from lat-pycache-ship-300-nd-n128 --to lat-pycache-ship-300-nd-n128)/$(grep '^vm_age_lease' "$TMP/alog" | sed "s#$T/runs/##g")" \
    "0/vm_age_lease pycache/ship-300-nd/N128-lat --sbx pycache/sbx/N128-lat"
  check "ownwalk: 10000 then 100000 files (the seal stage), under E17C=1" \
    "$(chain -- --from ownwalk --to ownwalk)/$(sed 's/ tag=.* e17c=/ e17c=/; s/ e17b=.*//' "$CLOG" | tr '\n' ';')" "0/ownwalk 10000 e17c=1;ownwalk 100000 e17c=1;"
  g256_file true 8
  lib256 8
  check "ram256: SKIP without E17C_RAM256=1; with it (and a passing gate-256 whose scale is committed) the pycache-d64 N=1 rungs at 256 MiB" \
    "$(chain -- --from ram256-pycache-sbx-n1 --to ram256-squeeze-sbx)/$(grep -c 'SKIP (ram256: E17C_RAM256=1 runs it)' "$TMP/c.out")/$(chain E17C_RAM256=1 -- --from ram256-pycache-sbx-n1 --to ram256-pycache-ship-300-n1)/$(sed 's/ seed=.* ram=/ ram=/; s/ win=.*//' "$CLOG" | tr '\n' ';')" \
    "0/6/0/rung sbx 1 pycache-d64 tag=ram256 ram=256;rung ship-300 1 pycache-d64 tag=ram256 ram=256;"
  check "opt (R-z4): each default ladder's baseline at the pin runs before the ladders (ladder.sh needs default/ARM/N1/baseline.json)" \
    "$(chain E17C_OPTIONAL=1 -- --from base-default-sbx --to ladder-default-ship-300)/$(calls)" \
    "0/baseline default sbx;baseline default ship-300;ladder default sbx 56;ladder default ship-300 80;"
  check "opt (R-z4): base-default-ARM comes before ladder-default-ARM in the stage order, for both arms" \
    "$(chain -- --list >/dev/null; for a in sbx ship-300; do b=$(awk -v s="base-default-$a" '$1 == s {print NR}' "$TMP/c.out"); l=$(awk -v s="ladder-default-$a" '$1 == s {print NR}' "$TMP/c.out"); [ -n "$b" ] && [ "$b" -lt "$l" ] && printf '%s ' "$a"; done)" \
    "sbx ship-300 "
  check "opt: SKIP without E17C_OPTIONAL=1; with it the default ladders run" \
    "$(chain -- --from ladder-default-sbx --to ladder-default-ship-300)/$(grep -c 'SKIP (optional: E17C_OPTIONAL=1 runs it)' "$TMP/c.out")/$(chain E17C_OPTIONAL=1 -- --from ladder-default-sbx --to ladder-default-ship-300)/$(calls)" \
    "0/2/0/ladder default sbx 56;ladder default ship-300 80;"
  mkdir -p "$T/snapshots/e17c-${PIN:0:8}-1024"
  printf '{"hash": "h", "guest_ram_mb": 1024, "features": ["lease-v1", "balloon-fpr-v1"]}\n' >"$T/snapshots/e17c-${PIN:0:8}-1024/manifest.json"
  # ruling R-n: a SKIP with its reason (exit 0), so a resume goes on to verdict; its .done and .log say skipped
  check "ownwalk-500k: SKIPPED with its reason (moca #907, the 4 GiB workspace drive), exit 0, nothing run" \
    "$(chain E17C_OPTIONAL=1 -- --from ownwalk-500k --to ownwalk-500k)/$(grep -c '^E17C ownwalk-500k SKIP (.*moca #907.*)' "$TMP/c.out")/$(grep -c 'skipped: .*4 GiB.*moca #907.*no workspace drive size' "$T/e17c/ownwalk-500k.log")/$(grep -c 'skipped: .*moca #907' "$T/e17c/ownwalk-500k.done")/$(grep -c . "$CLOG")" "0/1/1/1/0"
  printf '%s\n' "$VERDICT_STUB" >"$TMP/an/verdict_e17c.py"
  check "ownwalk-500k: a plain resume with E17C_OPTIONAL=1 goes through it to verdict" \
    "$(rm -f "$T/e17c/ownwalk-500k.done"; chain E17C_OPTIONAL=1 -- --from ownwalk-500k)/$(grep -c 'E17C ownwalk-500k SKIP' "$TMP/c.out")/$(grep -c 'E17C verdict DONE' "$TMP/c.out")" "0/1/1"
  rm -f "$TMP/an/verdict_e17c.py" "$T/e17c/verdict.json"
  check "verdict: no analysis/verdict_e17c.py yet -> a clear failure naming it (Task 7), not a crash" \
    "$(chain -- --from verdict)/$(grep -c 'no .*verdict_e17c.py (Task 7' "$T/e17c/verdict.log")/$([ -f "$T/e17c/verdict.done" ] && echo "done" || echo open)" "1/1/open"
  printf '%s\n' "$VERDICT_STUB" >"$TMP/an/verdict_e17c.py"
  check "verdict: verdict_e17c.py over the runs, at the E17C pin, to \$E15_ROOT/e17c/verdict.json" \
    "$(chain -- --from verdict)/$(sed "s#$T/##g" "$TMP/alog")/$([ -f "$T/e17c/verdict.json" ] && echo written)" \
    "0/verdict_e17c runs --moca-commit $PIN --out e17c/verdict.json/written"
  rm -f "$TMP/an/verdict_e17c.py"
}

# Task 9 (SPEC §13.5, R47): gate-pycache-low runs the N = 1 seeds at pycache-low from the first call (E15_START_ZERO=1)
# with an 1800 s window, 4 per arm (sbx, ship-300); it passes only when every seed has >= 3 in-window ok calls of
# py_short or py_import (criterion 2's classes). It writes $E15_RUNS/pycache-low/gate-pycache-low.json (ruling R-q)
# either way; on a fail the pycache-low stages are SKIPPED as cut (exit 0, the gate's reason) and the chain goes on.
GOOD="py_short:1,py_import:1,py_short:1,py_import:1,build:1,py_short:0" # 4 counted: 2 + 2 in the window; 8 + 8 pooled
test_gate_low() {
  reset
  rm -f "$PRED"
  check "gate: runs before the seal; 4 seeds per arm, sbx then ship-300, at pycache-low N=1, tags g1..g4" \
    "$(chain STUB_CALLS="$GOOD" -- --from gate-pycache-low --to gate-pycache-low)/$(calls)" \
    "0/rung sbx 1 pycache-low;rung sbx 1 pycache-low;rung sbx 1 pycache-low;rung sbx 1 pycache-low;rung ship-300 1 pycache-low;rung ship-300 1 pycache-low;rung ship-300 1 pycache-low;rung ship-300 1 pycache-low;"
  check "gate: every seed with E15_START_ZERO=1, E15_WINDOW_S=1800, E15_SEED=k, E15_TAG=gk, under E17C=1" \
    "$(sed 's/^rung [a-z0-9-]* 1 pycache-low //; s/ memmax=.* e17c=/ e17c=/; s/ e17b=.*win=/ win=/' "$CLOG" | sort -u | tr '\n' ';')" \
    "tag=g1 seed=1 zero=1 e17c=1 win=1800;tag=g2 seed=2 zero=1 e17c=1 win=1800;tag=g3 seed=3 zero=1 e17c=1 win=1800;tag=g4 seed=4 zero=1 e17c=1 win=1800;"
  check "gate: pass, written to \$E15_RUNS/pycache-low/gate-pycache-low.json with its settings" \
    "$(gq pass)/$(gq window_s)/$(gq start_zero)/$(gq seeds_per_arm)/$(gq min_calls)/$(gq classes)/$(gq moca_commit)" \
    "true/1800/true/4/3/[\"py_short\", \"py_import\"]/\"$PIN\""
  check "gate: per arm and seed the in-window ok counts by class (not the out-of-window py_short, not build)" \
    "$(gq arms.sbx.0)" \
    '{"calls": 4, "in_window": {"py_import": 2, "py_short": 2}, "pass": true, "reason": null, "record_reason": "ok", "rung": "pycache-low/sbx/N1-g1", "seed": 1}'
  check "gate: four seeds per arm recorded; the stage DONE line says it passed" \
    "$(python3 -c 'import json,sys; a=json.load(open(sys.argv[1]))["arms"]; print(sorted(a), [len(v) for _, v in sorted(a.items())])' "$GATE")/$(grep -c 'E17C gate-pycache-low DONE .*(gate-pycache-low: PASS' "$TMP/c.out")" \
    "['sbx', 'ship-300'] [4, 4]/1"
  reset
  check "gate: one seed of one arm short (ship-300 seed 3: 2 counted, a failed py_import does not count) -> fail, all 8 seeds still run, exit 0" \
    "$(chain STUB_CALLS="$GOOD" STUB_CALLS_g3="py_short:1,py_import:1,py_import:1:failed" STUB_LOW_ARM=ship-300 -- --from gate-pycache-low --to gate-pycache-low)/$(grep -c . "$CLOG")/$(gq pass)/$(gq arms.sbx.2.pass)/$(gq arms.ship-300.2.pass)/$(gq arms.ship-300.2.in_window)" \
    '0/8/false/true/false/{"py_import": 1, "py_short": 1}'
  check "gate: the fail reason names the arm, seed, rung and counts; the DONE line says pycache-low is cut" \
    "$(gq reason)/$(grep -c 'E17C gate-pycache-low DONE .*(gate-pycache-low: FAIL.*pycache-low is cut' "$TMP/c.out")" \
    '"ship-300 seed 3 (N1-g3): 2 in-window py_short/py_import call(s) (py_short 1, py_import 1), need 3 with at least 1 of each"/1'
  reset
  check "gate: an empty-window seed counts 0 calls and fails the gate (R47's case), reason recorded" \
    "$(chain STUB_REASON=empty_window -- --from gate-pycache-low --to gate-pycache-low)/$(gq arms.sbx.0.record_reason)/$(gq pass)/$(gq reason | grep -c 'sbx seed 1 (N1-g1): 0 in-window.*record reason empty_window.*need 3')" \
    '0/"empty_window"/false/1'
  reset
  check "gate (R-t): a one-class seed (sbx seed 2: 3 py_short, 0 py_import) fails the gate; the pooled counts still pass" \
    "$(chain STUB_CALLS="$GOOD" STUB_CALLS_g2="py_short:1,py_short:1,py_short:1" STUB_LOW_ARM=sbx -- --from gate-pycache-low --to gate-pycache-low)/$(gq pass)/$(gq arms.sbx.1.pass)/$(gq arms.sbx.1.calls)/$(gq pooled.sbx.pass)/$(gq reason)" \
    '0/false/false/3/true/"sbx seed 2 (N1-g2): 3 in-window py_short/py_import call(s) (py_short 3, py_import 0), need 3 with at least 1 of each"'
  reset
  check "gate (R-u): every seed passes, but ship-300 pools 4 py_import (< holds.MIN_CLASS_CALLS 5): the gate fails, pooled counts recorded" \
    "$(chain STUB_CALLS="$GOOD" STUB_CALLS_g1="py_short:1,py_short:1,py_import:1" STUB_CALLS_g2="py_short:1,py_short:1,py_import:1" STUB_CALLS_g3="py_short:1,py_short:1,py_import:1" STUB_CALLS_g4="py_short:1,py_short:1,py_import:1" STUB_LOW_ARM=ship-300 -- --from gate-pycache-low --to gate-pycache-low)/$(gq pass)/$(gq arms.ship-300.0.pass)/$(gq pooled.ship-300.in_window)/$(gq pooled.sbx.pass)/$(gq min_class_calls_pooled)/$(gq reason)" \
    '0/false/true/{"py_import": 4, "py_short": 8}/true/5/"ship-300 pooled over its 4 gate seeds: py_import 4, need 5 of each (holds.MIN_CLASS_CALLS: the N=128 rungs'"'"' class-matched baseline)"'
  reset
  gate_file true stale
  check "gate: a rung failure fails the stage (rig error, not a cut): no .done, the stale gate file removed" \
    "$(chain STUB_CALLS="$GOOD" FAIL_ON="rung ship-300 1 pycache-low tag=g2" -- --from gate-pycache-low --to gate-pycache-low)/$([ -f "$T/e17c/gate-pycache-low.done" ] && echo "done" || echo open)/$([ -f "$GATE" ] && echo gate || echo nogate)/$(grep -c 'rung.sh ship-300 1 pycache-low (seed 2) failed' "$T/e17c/gate-pycache-low.log")" \
    "1/open/nogate/1"
  reset
  mkdir -p "$T/runs/pycache-low/sbx/N1-old"
  printf '{"arm": "sbx", "moca_commit": "c13d55649777e69ec7649d6fa8c08f4acb1f4e2e"}\n' >"$T/runs/pycache-low/sbx/N1-old/params.json"
  gate_file true stale
  check "gate: the commit preflight covers pycache-low's arms; the old gate file is removed before it (R-w)" \
    "$(chain STUB_CALLS="$GOOD" -- --from gate-pycache-low --to gate-pycache-low)/$(grep -c 'is not from E17C_MOCA_PIN' "$T/e17c/gate-pycache-low.log")/$(grep -c . "$CLOG")/$([ -f "$GATE" ] && echo gate || echo nogate)" "1/1/0/nogate"

  # the pycache-low stages after the gate
  reset
  seal true
  local st out=""
  for st in base-pycache-low-sbx base-pycache-low-ship-300 lat-pycache-low-sbx-n128 lat-pycache-low-ship-300-n128; do
    out+="$st=$(chain -- --from "$st" --to "$st"):$(grep -c 'no .*gate-pycache-low.json.*run gate-pycache-low' "$T/e17c/$st.log"):$(grep -c . "$CLOG") "
  done
  check "pycache-low: each stage refuses without the gate's file, naming the gate, nothing run" "$out" \
    "base-pycache-low-sbx=1:1:0 base-pycache-low-ship-300=1:1:0 lat-pycache-low-sbx-n128=1:1:0 lat-pycache-low-ship-300-n128=1:1:0 "
  mkdir -p "$T/runs/pycache-low" && printf '{"pass": ' >"$GATE"
  check "pycache-low: an unreadable gate file refuses too" \
    "$(chain -- --from base-pycache-low-sbx --to base-pycache-low-sbx)/$(grep -c 'gate-pycache-low.json is unreadable' "$T/e17c/base-pycache-low-sbx.log")/$(grep -c . "$CLOG")" "1/1/0"
  out=""
  for v in "other:1111111111111111111111111111111111111111 1800 true:moca_commit" "window:$PIN 900 true:window_s" "zero:$PIN 1800 false:start_zero" "int:$PIN 1800 1:start_zero"; do
    read -r c w z <<<"$(printf '%s' "$v" | cut -d: -f2)"
    gate_file true ok "$c" "$w" "$z"
    out+="${v%%:*}=$(chain -- --from base-pycache-low-sbx --to base-pycache-low-sbx):$(grep -c "not this chain's gate (.*${v##*:} .*re-run gate-pycache-low" "$T/e17c/base-pycache-low-sbx.log"):$(grep -c . "$CLOG") "
  done
  check "pycache-low (R-w): a gate file from another moca_commit, window_s or start_zero (1 is not true) refuses, naming the field" \
    "$out" "other=1:1:0 window=1:1:0 zero=1:1:0 int=1:1:0 "
  gate_file false "ship-300 seed 3 (N1-g3): 2 in-window calls, need 3"
  check "pycache-low: after a failed gate the four stages are SKIPPED as cut, with the gate's reason, exit 0, nothing run; the chain goes on" \
    "$(chain -- --from base-pycache-low-sbx --to base-squeeze-sbx)/$(grep -c '^E17C [a-z0-9-]*pycache-low[a-z0-9-]* SKIP (pycache-low cut by gate-pycache-low: ship-300 seed 3 (N1-g3): 2 in-window calls, need 3' "$TMP/c.out")/$(cat "$T"/e17c/*pycache-low*.done | grep -c 'skipped: pycache-low cut')/$(calls)" \
    "0/4/4/baseline squeeze sbx;"
  gate_file true "every seed passed"
  check "pycache-low: after a passed gate they run; the baselines from the first call with the 1800 s window, the N=128 rungs as before" \
    "$(chain -- --from base-pycache-low-sbx --to lat-pycache-low-ship-300-n128)/$(sed 's/ tag=[^ ]* seed=[^ ]*//; s/ memmax=.* win=/ win=/' "$CLOG" | tr '\n' ';')" \
    "0/baseline pycache-low sbx zero=1 win=1800;baseline pycache-low ship-300 zero=1 win=1800;rung sbx 128 pycache-low zero=unset win=unset;rung ship-300 128 pycache-low zero=unset win=unset;"
}

# Task 10 (SPEC §13.5, R45): gate-256 runs py_analyze 20 times per candidate scale and arm in a 256 MiB guest, through a
# gate library that measures its peak RSS inside the command; the chosen scale is the largest with peak RSS <= 120 MiB and
# zero OOM kills in all 20 runs of both arms. It writes $E15_RUNS/pycache-d64/gate-256.json (ruling R-x) either way.
SCALES="32 16 8 4 2 1"
test_gate_256() {
  reset
  rm -f "$PRED"
  local s want=""
  for s in $SCALES; do want+="rung sbx 1 pycache-d64 tag=g256-s$s;rung ship-300 1 pycache-d64 tag=g256-s$s;"; done
  check "gate-256: runs before the seal; per candidate scale ($SCALES) sbx then ship-300, pycache-d64 N=1, tags g256-s<scale>" \
    "$(chain -- --from gate-256 --to gate-256)/$(sed 's/ seed=.*//' "$CLOG" | tr '\n' ';')" "0/$want"
  check "gate-256: every rung from the first call, at 256 MiB, a 3600 s window, under E17C=1" \
    "$(sed 's/.* seed=/seed=/; s/ memmax=[^ ]*//; s/ e17b=[^ ]*//' "$CLOG" | sort -u | tr '\n' ';')" "seed=unset zero=1 e17c=1 ram=256 win=3600;"
  check "gate-256: each rung replays the py_analyze probe corpus, one session, no warm-up or spread, with its scale's gate library" \
    "$(head -1 "$TMP/g256.log")/$(grep -c . "$TMP/g256.log")/$(sed 's/ .*//' "$TMP/g256.log" | LC_ALL=C sort -u | tr '\n' ' ')" \
    "lib=library-s32.json ovr=runs/pycache-d64/gate-256-inputs/probe/py_analyze/corpus.jsonl maxs=1 warm=0 spread=0/12/lib=library-s1.json lib=library-s16.json lib=library-s2.json lib=library-s32.json lib=library-s4.json lib=library-s8.json "
  check "gate-256: the gate library carries its scale and the RSS wrapper; the probe corpus has 20 py_analyze calls" \
    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["classes"]["py_analyze"][0]["cmd"][:57], "config.ANALYZE_WORK_SCALE = 8;" in json.load(open(sys.argv[1]))["classes"]["py_analyze"][0]["cmd"])' "$T/runs/pycache-d64/gate-256-inputs/library-s8.json")/$(python3 -c 'import json,sys; c=json.loads(open(sys.argv[1]).readline())["calls"]; print(len(c), sorted({x["class"] for x in c}))' "$T/runs/pycache-d64/gate-256-inputs/probe/py_analyze/corpus.jsonl")" \
    "cd project && ../venv/bin/python -c 'import resource, sub True/20 ['py_analyze']"
  check "gate-256: every scale passes here -> the largest (32); gate-256.json with its settings, the DONE line says PASS" \
    "$(g2q pass)/$(g2q chosen_scale)/$(g2q candidates)/$(g2q runs_per_arm)/$(g2q rss_max_mib)/$(g2q moca_commit)/$(grep -c 'E17C gate-256 DONE .*(gate-256: PASS: scale 32' "$TMP/c.out")" \
    "true/32/[32, 16, 8, 4, 2, 1]/20/120/\"$PIN\"/1"
  check "gate-256: its rungs are calibration only: no lease analysis is run on them" "$(grep -c . "$TMP/alog")" "0"
  reset
  check "gate-256: an OOM kill at 32 (sbx, 1 of 20) and 121 MiB at 16 (ship-300) -> scale 8" \
    "$(chain STUB_G256="sbx/32=100/1 ship-300/16=121/0" -- --from gate-256 --to gate-256)/$(g2q chosen_scale)/$(g2q results.32.sbx.oom_kills)/$(g2q results.32.ship-300.pass)/$(g2q results.16.ship-300.peak_rss_mib)/$(g2q results.16.ship-300.pass)/$(g2q results.8.sbx.runs)" \
    "0/8/1/true/121.0/false/20"
  reset
  check "gate-256: no scale passes -> pass false, chosen_scale null, the stage is DONE (exit 0) and says FAIL" \
    "$(chain STUB_G256="sbx/32=100/20 sbx/16=100/20 sbx/8=100/2 sbx/4=130/0 sbx/2=130/0 sbx/1=130/0" -- --from gate-256 --to gate-256)/$(g2q pass)/$(g2q chosen_scale)/$(grep -c 'E17C gate-256 DONE .*(gate-256: FAIL' "$TMP/c.out")" \
    "0/false/null/1"
  reset
  g256_file true 8
  check "gate-256: a rung failure fails the stage (a rig error): no .done, the old gate file removed first" \
    "$(chain FAIL_ON="rung ship-300 1 pycache-d64 tag=g256-s8" -- --from gate-256 --to gate-256)/$([ -f "$T/e17c/gate-256.done" ] && echo "done" || echo open)/$([ -f "$G256" ] && echo gate || echo nogate)/$(grep -c 'rung.sh ship-300 1 pycache-d64 (scale 8) failed' "$T/e17c/gate-256.log")" \
    "1/open/nogate/1"
  reset
  mkdir -p "$T/runs/pycache-d64/ship-300/N1-old"
  printf '{"arm": "ship-300", "moca_commit": "c13d55649777e69ec7649d6fa8c08f4acb1f4e2e"}\n' >"$T/runs/pycache-d64/ship-300/N1-old/params.json"
  g256_file true 8
  check "gate-256: the commit preflight covers pycache-d64's arms; the old gate file is removed before it" \
    "$(chain -- --from gate-256 --to gate-256)/$(grep -c 'is not from E17C_MOCA_PIN' "$T/e17c/gate-256.log")/$(grep -c . "$CLOG")/$([ -f "$G256" ] && echo gate || echo nogate)" "1/1/0/nogate"
  check "gate-256: E17C_GATE_LIBRARY in the caller's environment is refused like a knob (only the gate sets it)" \
    "$(chain E17C_GATE_LIBRARY=/tmp/x -- --list)/$(grep -c 'E17C REFUSED: .*E17C_GATE_LIBRARY' "$TMP/c.out")" "1/1"

  # the ram256 stages read gate-256.json and library-256.json first (ruling R-x)
  reset
  seal true
  local st out=""
  RAM256="ram256-pycache-sbx-n1 ram256-pycache-ship-300-n1 ram256-base-squeeze-sbx ram256-base-squeeze-ship-300 ram256-squeeze-ship-300 ram256-squeeze-sbx"
  for st in $RAM256; do
    out+="$st=$(chain E17C_RAM256=1 E17B_SQUEEZE256_MEMMAX_MB=16384 -- --from "$st" --to "$st"):$(grep -c 'no .*gate-256.json.*run gate-256' "$T/e17c/$st.log"):$(grep -c . "$CLOG") "
  done
  check "ram256: each stage refuses without gate-256.json, naming the gate, nothing run" "$out" \
    "$(for st in $RAM256; do printf '%s=1:1:0 ' "$st"; done)"
  lib256 8
  g256_file true 8 1111111111111111111111111111111111111111
  check "ram256: a gate-256.json from another moca_commit refuses" \
    "$(chain E17C_RAM256=1 -- --from ram256-pycache-sbx-n1 --to ram256-pycache-sbx-n1)/$(grep -c 'moca_commit .*re-run gate-256' "$T/e17c/ram256-pycache-sbx-n1.log")/$(grep -c . "$CLOG")" "1/1/0"
  g256_file false null
  check "ram256: a failed gate refuses, with the gate's reason" \
    "$(chain E17C_RAM256=1 -- --from ram256-pycache-sbx-n1 --to ram256-pycache-sbx-n1)/$(grep -c 'did not pass.*scale 1: 3 OOM kill' "$T/e17c/ram256-pycache-sbx-n1.log")/$(grep -c . "$CLOG")" "1/1/0"
  g256_file true 8
  lib256 0
  check "ram256: a passing gate while library-256.json still has the placeholder scale refuses (commit the gate's scale)" \
    "$(chain E17C_RAM256=1 -- --from ram256-pycache-sbx-n1 --to ram256-pycache-sbx-n1)/$(grep -c 'placeholder.*commit' "$T/e17c/ram256-pycache-sbx-n1.log")/$(grep -c . "$CLOG")" "1/1/0"
  lib256 16
  check "ram256: a library-256.json scale other than the gate's refuses" \
    "$(chain E17C_RAM256=1 -- --from ram256-pycache-sbx-n1 --to ram256-pycache-sbx-n1)/$(grep -c 'scale 16.*chose 8' "$T/e17c/ram256-pycache-sbx-n1.log")/$(grep -c . "$CLOG")" "1/1/0"
  lib256 8
  check "ram256: the gate passed at this pin and its scale is committed -> the stages run (the squeeze-256 climb too)" \
    "$(chain E17C_RAM256=1 E17B_SQUEEZE256_MEMMAX_MB=16384 -- --from ram256-pycache-sbx-n1 --to ram256-squeeze-ship-300)/$(sed 's/ tag=.*//' "$CLOG" | tr '\n' ';')" \
    "0/rung sbx 1 pycache-d64;rung ship-300 1 pycache-d64;baseline squeeze-256 sbx;baseline squeeze-256 ship-300;ladder squeeze-256 ship-300;"
}

test_guards() {
  reset
  seal true
  touch "$TMP/worker-up"
  check "guard: a rung's worker running -> refused before any stage" "$(chain -- --from smoke --to smoke)/$(grep -c 'refusing to preempt it' "$TMP/c.out")/$(grep -c . "$CLOG")" "1/1/0"
  rm -f "$TMP/worker-up"
  printf 'E17B_MOCA_PIN=%s\nE17C_MOCA_PIN=%s\n' 1111111111111111111111111111111111111111 0000000000000000000000000000000000000000 >"$TMP/pins0.sh"
  check "guard: the placeholder E17C pin is refused before any stage" \
    "$(chain E15_TEST_PINS="$TMP/pins0.sh" -- --from smoke --to smoke)/$(grep -c 'E17C_MOCA_PIN is still the placeholder' "$TMP/c.out")/$(grep -c . "$CLOG")" "1/1/0"
  check "guard: only the staged copy runs" \
    "$(env E15_ROOT="$T" E15_TEST_ROOT="$T" E15_TEST_PINS="$TMP/pins.sh" PATH="$TMP/stub:$PATH" bash "$RIG/chain-e17c.sh" --list >"$TMP/c.out" 2>&1; echo $?)/$(grep -c 'run the staged copy' "$TMP/c.out")" "1/1"
  check "usage: an unknown stage, or --from after --to, is exit 2, nothing run" \
    "$(chain -- --from nowhere)/$(chain -- --from verdict --to smoke)/$(chain -- --bogus)/$(grep -c . "$CLOG")" "2/2/2/0"
}

# Ruling R-z2 (SPEC §13.6): the gated N = 1 seeds run after the seal, 4 fresh ones per arm (11..14, N1-l<k>), from the
# first call, sbx first; R-z3: each ship rung's vm_age_lease.py gets --sbx the same-named sbx rung.
test_seal_seeds() {
  reset
  rm -f "$PRED"
  check "seal seeds: refused while unsealed, nothing run" \
    "$(chain -- --from lat-pycache-sbx-n1 --to lat-pycache-sbx-n1)/$(grep -c 'stages that need the seal: lat-pycache-sbx-n1 (stop before' "$TMP/c.out")/$(grep -c . "$CLOG")" "1/1/0"
  seal true
  local want="" a k
  for a in sbx ship-300 ship-300-nd; do for k in 11 12 13 14; do want+="rung $a 1 pycache tag=l$k seed=$k zero=1;"; done; done
  check "seal seeds: sbx, ship-300, ship-300-nd at pycache N=1, seeds 11..14, tags l<k>, E15_START_ZERO=1, set by the chain" \
    "$(chain -- --from lat-pycache-sbx-n1 --to lat-pycache-ship-300-nd-n1)/$(sed 's/ memmax=.*//' "$CLOG" | tr '\n' ';')" "0/$want"
  check "seal seeds: they write N1-l11..N1-l14 per arm, under E17C=1" \
    "$(cd "$T/runs/pycache" && find . -mindepth 2 -maxdepth 2 -name 'N1-l*' | sed 's#^\./##' | LC_ALL=C sort | tr '\n' ' ')/$(grep -vc 'e17c=1 e17b=1 ' "$CLOG")" \
    "sbx/N1-l11 sbx/N1-l12 sbx/N1-l13 sbx/N1-l14 ship-300-nd/N1-l11 ship-300-nd/N1-l12 ship-300-nd/N1-l13 ship-300-nd/N1-l14 ship-300/N1-l11 ship-300/N1-l12 ship-300/N1-l13 ship-300/N1-l14 /0"
  want=""
  for a in ship-300 ship-300-nd; do for k in 11 12 13 14; do want+="vm_age_lease pycache/$a/N1-l$k --sbx pycache/sbx/N1-l$k;"; done; done
  check "seal seeds (R-z3): every gated ship rung is analysed with --sbx its same-named sbx rung" \
    "$(grep '^vm_age_lease' "$TMP/alog" | sed "s#$T/runs/##g" | tr '\n' ';')" "$want"
  reset
  check "seal seeds: exactly 4 per arm, never topped up (an empty_window seed is the verdict's to drop, not the chain's)" \
    "$(chain STUB_REASON=empty_window -- --from lat-pycache-sbx-n1 --to lat-pycache-sbx-n1)/$(grep -c . "$CLOG")" "0/4"
  reset
  check "seal seeds: the commit preflight runs first (another commit's sbx rung refuses the stage, nothing run)" \
    "$(mkdir -p "$T/runs/pycache/sbx/N1-old"; printf '{"arm": "sbx", "moca_commit": "c13d55649777e69ec7649d6fa8c08f4acb1f4e2e"}\n' >"$T/runs/pycache/sbx/N1-old/params.json"; chain -- --from lat-pycache-sbx-n1 --to lat-pycache-sbx-n1)/$(grep -c . "$CLOG")" "1/0"
}

# Final review M1: gate-256's inputs directory is a checked leaf; an earlier one is moved aside (timestamped), never
# deleted (the earlier gate rungs' params.json name its libraries and probe corpus).
test_gate256_inputs_aside() {
  reset
  rm -f "$PRED"
  local gin="$T/runs/pycache-d64/gate-256-inputs"
  chain -- --from gate-256 --to gate-256 >/dev/null
  printf 'earlier\n' >"$gin/marker"
  check "gate-256 inputs: a second run moves the first run's inputs aside to gate-256-inputs.prev-<ts>, with its files" \
    "$(chain -- --from gate-256 --to gate-256)/$(find "$T/runs/pycache-d64" -maxdepth 1 -name 'gate-256-inputs.prev-*' | wc -l | tr -d ' ')/$(cat "$gin".prev-*/marker)/$(find "$T/runs/pycache-d64" -path '*/gate-256-inputs.prev-*/library-s8.json' | wc -l | tr -d ' ')/$([ -e "$gin/marker" ] && echo stale || echo fresh)/$(grep -c 'earlier gate inputs moved aside to .*gate-256-inputs.prev-' "$T/e17c/gate-256.log")" \
    "0/1/earlier/1/fresh/1"
  reset
  mkdir -p "$TMP/outside" "$T/runs/pycache-d64"
  printf 'keep\n' >"$TMP/outside/keep"
  ln -s "$TMP/outside" "$gin"
  check "gate-256 inputs: a leaf that leads outside \$E15_ROOT (a symlink) refuses the stage; nothing there is touched, no rung runs" \
    "$(chain -- --from gate-256 --to gate-256)/$(grep -c 'outside' "$T/e17c/gate-256.log")/$(cat "$TMP/outside/keep")/$([ -L "$gin" ] && echo link)/$(grep -c . "$CLOG")" \
    "1/1/keep/link/0"
  rm -f "$gin"
}

test_list
test_seal_seeds
test_gate256_inputs_aside
test_refuses_knobs
test_refuses_unsealed
test_bringup_unsealed
test_sealed_stages
test_gate_low
test_gate_256
test_guards

echo
if [ "$fails" -eq 0 ]; then echo "chain-e17c.test.sh: all checks passed"; else echo "chain-e17c.test.sh: $fails FAILED"; fi
exit "$([ "$fails" -eq 0 ] && echo 0 || echo 1)"
