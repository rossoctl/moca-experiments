#!/usr/bin/env bash
# experiments/e17-lease/rig/chain-e17b.sh [--list] [--from STAGE] [--to STAGE] -- the E17b run list on the metal host
# (experiments/e17-lease/PLAN-E17B.md Task 12 Steps 3 and 5, Task 14), in order, one stage at a time.
#
# Run by the controller only, as the rig's login user, from the staged copy, after bring-up (the order is in
# experiments/e17-lease/rig/README.md, "E17b bring-up order": sealed setup.sh, E17B=1 setup.sh, the two
# snapshot-e17b.sh leaves, E17B=1 setup.sh again for its end-to-end check, E17B=1 bringup.sh):
#   bash /srv/e15/src/e17/rig/chain-e17b.sh               # from the first stage not done yet
#   bash /srv/e15/src/e17/rig/chain-e17b.sh --from lat-pycache-sbx-n128 [--to ladder-default-ship-300]
#   bash /srv/e15/src/e17/rig/chain-e17b.sh --list        # the stages, in order, with what each needs
#
# Every stage runs with E17B=1 (the profile: its own moca pin and checkout, the -e17b binaries), on fresh-metal,
# with the manifest at ~/e17-manifest.md (E15_MANIFEST overrides). The caller's environment cannot change a stage
# (E17B-R36): the per-rung knobs a stage sets itself (E15_TAG, E15_SEED, E15_WINDOW_S, ...) are unset below, and the
# chain REFUSES to start (exit 1, each named) while any other stage-changing knob is set, even to "": the list is
# STAGE_KNOBS below (everything lib.sh, rung.sh, ladder.sh, baseline.sh, classprobe.sh and sample.sh read from the
# environment that changes a measurement, e.g. E15_RUNG, E15_MAX_COMMITTED_MB, E15_LADDER_EXTRA, as an E16 shell
# leaves them). The operator's own inputs are E17B_OPTIONAL, E17B_RAM256, E17B_SQUEEZE_START_N (E17B-R51: resume a
# squeeze climb that a rig error stopped, at the rung that failed; its ladder.json is then assembled from both parts),
# E17B_SQUEEZE_MEMMAX_MB, E17B_SQUEEZE256_MEMMAX_MB,
# E17B_OVERHEAD_REF and E15_MANIFEST.
#
# THE SEAL. No measured rung runs before the predictions are sealed (spec §9): a stage marked "seal" runs only
# when experiments/e17-lease/predictions-e17b.json (staged beside this directory) exists, parses, and has
# "sealed": true (the JSON boolean). The chain refuses up front -- nothing runs -- when any selected stage needs
# the seal and the file does not say so, and checks again right before each such stage. The bring-up smoke and
# the calibration baselines (Task 12, "-") are allowed before the seal: the predictions are drafted from them.
#
# Each stage writes its own log, $L/<stage>.log (L = /srv/e15/e17b), and on success $L/<stage>.done. Without
# --from the chain starts at the first selected stage that has no .done; --from STAGE starts there whatever is done
# (a re-run rung is moved aside by rung.sh, never deleted); --to STAGE stops after it. The first failing stage stops
# the chain with "resume with --from <stage>". Optional stages ("opt") run only with E17B_OPTIONAL=1 (Task 14 Step 2:
# the ship-30/ship-120 ladders, if the rig time allows), else SKIP. The 256 MiB stages ("ram256") run only with
# E17B_RAM256=1, else SKIP (ruling E17B-R45: the workload's py_analyze is OOM-killed in a 256 MiB guest in both arms,
# so they are cut from the sealed E17b run; predictions-e17b.json calibration.smoke_256).
#
# Before a stage, its run directories ($E15_RUNS/POINT/ARM) must hold no params.json from another moca commit than
# E17B_MOCA_PIN (a result that mixes commits is not one arm; under E17B=1 nothing sealed is overwritten, E17B-R3).
# After a stage, every rung it wrote (every arm) is checked for its own failure: params.json rung_failed, record.json
# aborted, or a non-zero driver exit without a record.json (a memory-watchdog abort is a host verdict, not a failure);
# any stops the chain. Then every rung it wrote for a ship-* arm is analysed (Task 14 Step 5): warmcold_lease.py, lease_ends.py,
# freed_from_shmem.py (its shmem.json, E17B-R22) and vm_age_lease.py. The chain stops there for the user on: an unknown call (an ok
# call the join could not place; failed_no_vm calls -- refusals, queue-full -- are a NOTE naming their causes, E17B-R35), a
# configuration refusal in any row (stale-mode, lease-unsupported, permission-denied, req-id-in-flight; E17B-R42), a source disagreement, warmcold
# valid false, an unmatched lease end, lease_ends valid false or criterion4_pass false (null, no lease ended, does not
# stop), vm_age_lease mapping_valid false, or an analysis failure. After a measured stage (not "-"),
# latency_report.py runs over every rung the stage wrote, to $L/<stage>.latency/ (informational: not a stop).
#
# The squeeze stages (Task 14 Step 3) need E17B_SQUEEZE_MEMMAX_MB (MiB, above 8192; chosen from a first short climb):
# the ship-300 climb is ladder.sh squeeze ship-300 under it (its stop rule: experiments/e17-lease/analysis/squeeze_rule.py);
# sbx then runs once at the N that climb stopped at, under the same value, both read from its ladder.json. At the
# squeeze point every arm's committed budget is MemoryMax - 8192 MiB (E17B-R20, lib.sh worker_env), so the worker's
# budget-driven memory_reclaim fires; the host-MemAvailable reclaim trigger is not exercised by the squeeze (the host
# stays large).
# Guest RAM (E17B-R17): every stage runs on the snapshot leaf e17b-<pin8>-1024; the ram256-* stages set
# E17B_GUEST_RAM_MB=256 (leaf e17b-<pin8>-256) with D scaled to the same dataset-to-RAM ratio: pycache (D=256) runs as
# pycache-d64, and the squeeze as point squeeze-256 (D=768 scales to 192; ruling E17B-R21) under its own
# E17B_SQUEEZE256_MEMMAX_MB. The §7.4 probes (Task 11): probe-overhead runs probe-overhead.sh (baseline.sh default
# ship-300, then the comparison with the resident patch), ownwalk runs ownwalk.sh once per workspace size, each with its
# own worker. The probe-overhead stage runs the same commit preflight as a baseline stage (default ship-300) first.
# The last stage, verdict (needs the seal), runs analysis/verdict.py over $E15_RUNS at the pin to $L/verdict.json: each
# criterion's value, inputs and pass, computed by code: criteria 1-4 apply SPEC §7.5's fixed bars (E17B-R40), criterion 5's
# pass stays null until its thresholds are sealed (Task 13).
# A stage kind "blocked" fails naming what is missing (none is left).
#
# Output: "E17B <stage> START|DONE|FAILED|SKIP ..." lines. Exit 0 when every selected stage is done, 1 on a
# refusal or a failed stage, 2 on bad usage.
# Test hooks (rig.test.sh-style scratch roots only matter through lib.sh): E17B_RUNG, E17B_LADDER, E17B_BASELINE,
# E17B_SMOKE, E17B_OWNWALK replace rung.sh, ladder.sh, baseline.sh, smoke.sh, ownwalk.sh; E17B_ANALYSIS the analysis
# directory. probe-overhead.sh reads E17B_BASELINE too. They are honoured only with E17B_TEST_HARNESS=1 (set by
# tests/chain-e17b.test.sh); otherwise any of them set refuses the chain like a knob (E17B-R36).
set -uo pipefail
E15_PROG=chain-e17b.sh
# E17B-R36: refuse to start while a stage-changing knob, or (outside the test harness) a test hook, is set.
STAGE_KNOBS=(E15_RUNG E15_MAX_COMMITTED_MB E15_MAX_RUNS E15_LADDER_EXTRA E15_SPREAD_S E15_MEMAVAIL_FLOOR_MIB
  E15_END_SESSION_RATE E15_ATTACH_TIMEOUT_S E15_BASELINE_MAX_SEEDS E15_WS_DELTA_MB E15_CLASSPROBE E15_PROBE_CALLS
  E15_PROBE_SEED E15_MEMINFO E15_OS_RELEASE E15_SLICE_DIR E15_STATS_URL E15_PROC E15_DISK_DEV E15_DISK_PATH
  E15_SQUEEZE_ACTIVE E15_SQUEEZE_RESTORED E15_SQUEEZE_ORIG_MAX E15_SQUEEZE_ORIG_HIGH E15_SQUEEZE_MAX E15_SQUEEZE_HIGH)
TEST_HOOKS=(E17B_RUNG E17B_LADDER E17B_BASELINE E17B_SMOKE E17B_OWNWALK E17B_ANALYSIS)
knobs_set=()
for v in "${STAGE_KNOBS[@]}"; do [ -z "${!v+x}" ] || knobs_set+=("$v"); done
if [ "${E17B_TEST_HARNESS:-}" != 1 ]; then
  for v in "${TEST_HOOKS[@]}"; do [ -z "${!v+x}" ] || knobs_set+=("$v"); done
fi
if [ ${#knobs_set[@]} -gt 0 ]; then
  echo "E17B REFUSED: stage-changing variable(s) set in the environment: ${knobs_set[*]}; unset them (a leftover from an E16 or probe shell would change a sealed measurement silently; E17B_* hooks are for tests/chain-e17b.test.sh only)" >&2
  exit 1
fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export E17B=1
export E15_HOST_PROFILE=fresh-metal
export E15_MANIFEST=${E15_MANIFEST:-$HOME/e17-manifest.md}
SQUEEZE_MB=${E17B_SQUEEZE_MEMMAX_MB:-}
SQUEEZE256_MB=${E17B_SQUEEZE256_MEMMAX_MB:-}
unset E15_MAX_SESSIONS E15_START_ZERO E15_TAG E15_SEED E15_WARMUP_S E15_WINDOW_S E15_GRACE_S E15_LADDER_RUNGS \
  E15_LADDER_TAG E15_K_MULT E15_CORPUS_OVERRIDE E15_END_SESSION_DEFER E15_SQUEEZE_MEMMAX_MB E17B_GUEST_RAM_MB
E15_RIG=$HERE/../../e15/rig
[ -f "$E15_RIG/lib.sh" ] || {
  printf '%s: no %s/lib.sh: run the staged copy (/srv/e15/src/e17/rig/chain-e17b.sh)\n' "$E15_PROG" "$E15_RIG" >&2
  exit 1
}
# shellcheck source=SCRIPTDIR/../../e15-session-density/rig/lib.sh
. "$E15_RIG/lib.sh"
E17_SRC=$E15_ROOT/src/e17
case "$HERE" in "$E17_SRC"/rig) ;; *) die "run the staged copy: $E17_SRC/rig/chain-e17b.sh (not $HERE)" ;; esac
PREDICTIONS=$E17_SRC/predictions-e17b.json
RUNG=${E17B_RUNG:-$E15_SRC/rig/rung.sh}
LADDER=${E17B_LADDER:-$E15_SRC/rig/ladder.sh}
BASELINE=${E17B_BASELINE:-$E15_SRC/rig/baseline.sh}
SMOKE=${E17B_SMOKE:-$E17_SRC/rig/smoke.sh}
OWNWALK=${E17B_OWNWALK:-$E17_SRC/rig/ownwalk.sh}
ANALYSIS=${E17B_ANALYSIS:-$E17_SRC/analysis}
L=$E15_ROOT/e17b

# name|needs|command: needs is "-" (allowed before the seal), "seal", "opt" (seal, and E17B_OPTIONAL=1) or "ram256"
# (seal, and E17B_RAM256=1; E17B-R45).
STAGES=(
  # Task 12 Step 3: the smoke (sbx + the ship arms at pycache N=1, smoke.sh under E17B=1)
  "smoke|-|smoke"
  # Task 12 Step 5: N=1 baselines and class probes, the calibration the predictions are drafted from
  "cal-default-sbx|-|baseline default sbx"
  "cal-default-ship-300|-|baseline default ship-300"
  "cal-pycache-sbx|-|baseline pycache sbx"
  "cal-pycache-ship-300|-|baseline pycache ship-300"
  # Task 14 Step 1: latency and FPR at pycache; the N=128 rungs need these points' and arms' baselines first
  "base-pycache-low-sbx|seal|baseline pycache-low sbx"
  "base-pycache-low-ship-300|seal|baseline pycache-low ship-300"
  "base-pycache-ship-30|seal|baseline pycache ship-30"
  "base-pycache-ship-120|seal|baseline pycache ship-120"
  "lat-pycache-sbx-n1|seal|rung sbx 1 pycache"
  "lat-pycache-ship-300-n1|seal|rung ship-300 1 pycache"
  "lat-pycache-low-sbx-n1|seal|rung sbx 1 pycache-low"
  "lat-pycache-low-ship-300-n1|seal|rung ship-300 1 pycache-low"
  "lat-pycache-sbx-n128|seal|rung sbx 128 pycache"
  "lat-pycache-ship-300-n128|seal|rung ship-300 128 pycache"
  "lat-pycache-low-sbx-n128|seal|rung sbx 128 pycache-low"
  "lat-pycache-low-ship-300-n128|seal|rung ship-300 128 pycache-low"
  "lat-pycache-ship-30-n128|seal|rung ship-30 128 pycache"
  "lat-pycache-ship-120-n128|seal|rung ship-120 128 pycache"
  # Task 14 Step 2: capacity ladders at default, both arms at the new pin
  # E17B-R50 (user, 2026-11-18): each starts two ladder steps below E15 metal's default N_max (sbx 80, resident-300
  # 128), as E15 SPEC 10.3 does for its other points; the rungs below are assumed held (ladder.json says so)
  "ladder-default-sbx|seal|ladder default sbx 56"
  "ladder-default-ship-300|seal|ladder default ship-300 80"
  # Task 14 Step 3: squeeze (its own baselines, then the ship-300 climb, then sbx at its stop N). Every arm's committed
  # budget there is MemoryMax - 8192 (E17B-R20); the host-MemAvailable reclaim trigger is not exercised by the squeeze.
  "base-squeeze-sbx|seal|baseline squeeze sbx"
  "base-squeeze-ship-300|seal|baseline squeeze ship-300"
  "squeeze-ship-300|seal|squeeze-ladder squeeze ship-300|budget = MemoryMax - 8192 (E17B-R20); the host-MemAvailable reclaim trigger is not exercised by the squeeze"
  "squeeze-sbx|seal|squeeze-rung squeeze sbx"
  # Task 14 Step 4: the §7.4 probes (Task 11)
  "probe-overhead|seal|probe-overhead"
  "ownwalk|seal|ownwalk 10000 100000 500000|the walk is A - B per size, 5 repeats (ownwalk.json under runs/ownwalk/ship-300/F<files>)"
  # Task 14 Step 2, optional: the ship-30 and ship-120 ladders at default (the user may cut them)
  "base-default-ship-30|opt|baseline default ship-30"
  "base-default-ship-120|opt|baseline default ship-120"
  "ladder-default-ship-30|opt|ladder default ship-30"
  "ladder-default-ship-120|opt|ladder default ship-120"
  # Task 14 Steps 1 and 3 at 256 MiB guests (spec §5), D scaled to the same dataset-to-RAM ratio
  "ram256-pycache-sbx-n1|ram256|rung256 sbx 1 pycache-d64"
  "ram256-pycache-ship-300-n1|ram256|rung256 ship-300 1 pycache-d64"
  # the 256 MiB squeeze (E17B-R21): point squeeze-256 (D = 768 x 256/1024 = 192), its own baselines and its own
  # MemoryMax (E17B_SQUEEZE256_MEMMAX_MB, from its own short climb), sbx at its climb's stop N
  "ram256-base-squeeze-sbx|ram256|baseline256 squeeze-256 sbx"
  "ram256-base-squeeze-ship-300|ram256|baseline256 squeeze-256 ship-300"
  "ram256-squeeze-ship-300|ram256|squeeze-ladder squeeze-256 ship-300|budget = MemoryMax - 8192 (its own E17B_SQUEEZE256_MEMMAX_MB)"
  "ram256-squeeze-sbx|ram256|squeeze-rung squeeze-256 sbx"
  # the criteria's inputs, computed by code from every rung (final review M1): $L/verdict.json, pass null per criterion
  "verdict|seal|verdict|analysis/verdict.py over the runs: criteria 1-5 values and inputs; 1-4 judged on SPEC 7.5's fixed bars, 5 after Task 13 seals it"
)

usage() {
  echo "usage: chain-e17b.sh [--list] [--from STAGE] [--to STAGE]" >&2
  exit 2
}
s_name() { printf '%s' "${1%%|*}"; }
s_needs() {
  local r=${1#*|}
  printf '%s' "${r%%|*}"
}
s_cmd() { # the third field: the command (an optional fourth field is a note, never part of the command)
  local r=${1#*|}
  r=${r#*|}
  printf '%s' "${r%%|*}"
}
s_note() { # the optional fourth field, shown by --list only
  local r=${1#*|}
  r=${r#*|}
  case "$r" in *"|"*) printf '%s' "${r#*|}" ;; esac
}
stage_index() { # NAME -> its index, or return 1
  local i
  for i in "${!STAGES[@]}"; do [ "$(s_name "${STAGES[$i]}")" = "$1" ] && echo "$i" && return 0; done
  return 1
}

# sealed: predictions-e17b.json parses and says "sealed": true (the boolean).
sealed() {
  python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("sealed") is True else 1)' "$PREDICTIONS" 2>/dev/null
}
seal_state() {
  if [ ! -f "$PREDICTIONS" ]; then
    echo "missing ($PREDICTIONS)"
  elif sealed; then
    echo sealed
  else
    echo "not sealed ($PREDICTIONS has no \"sealed\": true)"
  fi
}

LIST=0 FROM="" TO=""
while [ $# -gt 0 ]; do
  case "$1" in
  --list) LIST=1 ;;
  --from)
    [ $# -ge 2 ] || usage
    FROM=$2
    shift
    ;;
  --to)
    [ $# -ge 2 ] || usage
    TO=$2
    shift
    ;;
  *) usage ;;
  esac
  shift
done
if [ -n "$FROM" ]; then stage_index "$FROM" >/dev/null || {
  echo "chain-e17b.sh: no stage '$FROM' (--list shows them)" >&2
  exit 2
}; fi
if [ -n "$TO" ]; then stage_index "$TO" >/dev/null || {
  echo "chain-e17b.sh: no stage '$TO' (--list shows them)" >&2
  exit 2
}; fi

if [ "$LIST" = 1 ]; then
  echo "E17B stages (predictions: $(seal_state)); needs: - before the seal, seal, opt (E17B_OPTIONAL=1), ram256 (E17B_RAM256=1)"
  for st in "${STAGES[@]}"; do
    n=$(s_name "$st")
    printf '%-32s %-5s %-5s %s%s\n' "$n" "$(s_needs "$st")" "$([ -f "$L/$n.done" ] && echo "done" || echo -)" "$(s_cmd "$st")" "$(n2=$(s_note "$st"); [ -n "$n2" ] && printf '  # %s' "$n2")"
  done
  exit 0
fi

# --- the selection: [first, last], optional stages only with E17B_OPTIONAL=1 -------------------------------------
last=$((${#STAGES[@]} - 1))
[ -z "$TO" ] || last=$(stage_index "$TO")
selected() {
  case "$(s_needs "${STAGES[$1]}")" in
  opt) [ "${E17B_OPTIONAL:-0}" = 1 ] ;;
  ram256) [ "${E17B_RAM256:-0}" = 1 ] ;;
  *) true ;;
  esac
}
if [ -n "$FROM" ]; then
  first=$(stage_index "$FROM")
else
  first=""
  for i in $(seq 0 "$last"); do
    if selected "$i" && [ ! -f "$L/$(s_name "${STAGES[$i]}").done" ]; then
      first=$i
      break
    fi
  done
  if [ -z "$first" ]; then
    echo "E17B every selected stage up to $(s_name "${STAGES[$last]}") is done ($L/*.done)"
    exit 0
  fi
  echo "E17B resuming at $(s_name "${STAGES[$first]}") (the first selected stage without $L/<stage>.done)"
fi
[ "$first" -le "$last" ] || {
  echo "chain-e17b.sh: --from $(s_name "${STAGES[$first]}") comes after --to $(s_name "${STAGES[$last]}")" >&2
  exit 2
}

# --- refusals before anything runs -------------------------------------------------------------------------------
need_seal=()
for i in $(seq "$first" "$last"); do
  selected "$i" || continue
  [ "$(s_needs "${STAGES[$i]}")" = - ] || need_seal+=("$(s_name "${STAGES[$i]}")")
done
if [ ${#need_seal[@]} -gt 0 ] && ! sealed; then
  echo "E17B REFUSED: predictions $(seal_state); no measured rung runs before the predictions are sealed (spec §9)." >&2
  echo "E17B REFUSED: stages that need the seal: ${need_seal[*]} (stop before them with --to cal-pycache-ship-300)" >&2
  exit 1
fi
e17b_require_pin
e17b_require_build
refuse_outside_root "$L"
mkdir -p "$L"
if unit_active "$E15_UNIT_WORKER"; then die "a rung's worker ($E15_UNIT_WORKER) is running; refusing to preempt it"; fi

# preflight POINT ARM...: no params.json under $E15_RUNS/POINT/ARM from another moca commit.
preflight() {
  local point=$1 bad
  shift
  bad=$(python3 - "$E15_RUNS/$point" "$E15_MOCA_PIN" "$@" <<'PY'
import glob, json, os, sys
root, pin, arms = sys.argv[1], sys.argv[2], sys.argv[3:]
for arm in arms:
    for p in sorted(glob.glob(os.path.join(root, arm, "*", "params.json"))):
        try:
            c = json.load(open(p)).get("moca_commit")
        except (OSError, ValueError):
            c = "unreadable"
        if c != pin:
            print("%s (moca_commit %s)" % (p, c))
            sys.exit(0)
PY
  ) || die "preflight check failed under $E15_RUNS/$point (${bad:-no output}): refusing, not passing"
  [ -z "$bad" ] || die "$bad is not from E17B_MOCA_PIN $E15_MOCA_PIN: a result that mixes commits is not one arm; move that arm's runs aside first"
}

# rung_flags DIR: why the rung itself failed, "" when it did not (I3; every arm). rung.sh exits 0 after record.py even
# when the driver failed, so the flags are read here: params.json rung_failed (a driver exit or set_mode_failed rows on
# a lease arm), record.json aborted (driver_exit != 0 without a memory-watchdog abort: a rig error, never a host
# verdict), and, when there is no record.json, the driver exit itself. A memory-watchdog abort is a host verdict
# (holds false, binding memory_floor), not a failure -- but set_mode_failed rows still are (independent failures).
# Unreadable flags exit non-zero: the caller stops.
rung_flags() {
  python3 - "$1" <<'PY'
import json, os, sys
d = sys.argv[1]
p = json.load(open(os.path.join(d, "params.json")))
rp = os.path.join(d, "record.json")
r = json.load(open(rp)) if os.path.exists(rp) else None
why = []
# A set_mode failure is independent of a memory abort: it stops the stage whatever the host's verdict was.
rf = p.get("rung_failed")
if rf is not None and (not p.get("memory_abort") or str(rf).startswith("set_mode_failed")):
    why.append("rung_failed %s" % rf)
de = p.get("driver_exit") or 0
if r is not None and r.get("aborted") is True:
    why.append("record.json aborted (driver_exit %s)" % de)
elif r is None and de != 0 and not p.get("memory_abort"):
    why.append("driver_exit %s (no memory abort)" % de)
print("; ".join(why))
PY
}

# gate MARKER: check every rung written since MARKER for its own failure flags (every arm), then analyse each ship-*
# rung (Task 14 Step 5); 1 when the chain must stop.
gate() {
  local marker=$1 rc=0 d arm f out sbxd extra note
  while IFS= read -r f; do
    d=$(dirname "$f")
    out=$(rung_flags "$d" 2>/dev/null) || out="the rung flags are unreadable ($f)"
    if [ -n "$out" ]; then
      echo "E17B $STAGE STOP ${d#"$E15_RUNS"/}: $out (the rung failed; Task 14 Step 5: goes to the user)"
      rc=1
      continue
    fi
    arm=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("arm", ""))' "$f" 2>/dev/null)
    case "$arm" in ship-*) ;; *) continue ;; esac
    # freed_from_shmem.py writes the shmem.json vm_age_lease.py reads (E17B-R22), so it runs first. vm_age_lease.py gets
    # --sbx when the same-named sbx rung exists (RUNS/POINT/sbx/<rung>): criterion 5's second half (M1).
    sbxd=$(dirname "$(dirname "$d")")/sbx/$(basename "$d")
    for a in warmcold_lease.py lease_ends.py freed_from_shmem.py vm_age_lease.py; do
      extra=()
      [ "$a" != vm_age_lease.py ] || [ ! -f "$sbxd/params.json" ] || extra=(--sbx "$sbxd")
      out=$(python3 "$ANALYSIS/$a" "$d" ${extra[@]+"${extra[@]}"} 2>&1) || {
        echo "E17B $STAGE ANALYSIS $a failed on $d: $(printf '%s' "$out" | tail -1)"
        rc=1
        continue 2
      }
      echo "E17B $STAGE $a ${d#"$E15_RUNS"/}: $out"
    done
    out=$(python3 - "$d" <<'PY'
import json, sys
d = sys.argv[1]
w = json.load(open(d + "/warmcold-report.json"))
e = json.load(open(d + "/lease_ends.json"))
v = json.load(open(d + "/vm_age_lease.json"))
why = []
if w.get("unknown"):
    why.append("%d unknown call(s)" % w["unknown"])
if w.get("disagreements"):
    why.append("%d source disagreement(s)" % w["disagreements"])
if w.get("config_refusals"):  # E17B-R42: the rung's mode, lease support or token binding is wrong, not its load
    why.append("%d configuration refusal(s) %s" % (w["config_refusals"],
                                                    json.dumps(w.get("config_refusals_by_cause") or {}, sort_keys=True)))
if w.get("valid") is False:
    why.append("warmcold-report valid false")
un = (e.get("notices") or {}).get("unmatched_ends") or []
if un:
    why.append("%d unmatched lease end(s)" % len(un))
if e.get("valid") is False:
    why.append("lease_ends.json valid false (%s)" % "; ".join(e.get("invalid_reasons") or []))
if e.get("criterion4_pass") is False:
    why.append("criterion 4 failed")
if v.get("mapping_valid") is False:
    why.append("vm_age_lease mapping_valid false (%s)" % "; ".join(v.get("mapping_reasons") or []))
print("; ".join(why))
PY
    ) || out="the analysis outputs are unreadable"
    if [ -n "$out" ]; then
      echo "E17B $STAGE STOP ${d#"$E15_RUNS"/}: $out (Task 14 Step 5: goes to the user)"
      rc=1
    fi
    # E17B-R35: failed calls that ran in no VM (refusals, queue-full, not started) are reported, not a stop: lease_ends'
    # criterion-3 refusal check judges them (a refusal while an idle lease existed fails criterion 3 there).
    note=$(python3 -c 'import json,sys; w=json.load(open(sys.argv[1] + "/warmcold-report.json")); n=w.get("failed_no_vm") or 0
print("%d failed_no_vm call(s) %s by cause %s" % (n, json.dumps(w.get("failed_no_vm_by_reason") or {}, sort_keys=True),
                                                  json.dumps(w.get("failed_no_vm_by_cause") or {}, sort_keys=True)) if n else "")' "$d" 2>/dev/null) || note=""
    [ -z "$note" ] || echo "E17B $STAGE NOTE ${d#"$E15_RUNS"/}: $note (reported, not a stop: criterion 3's refusal check judges them)"
  done < <(find "$E15_RUNS" -name params.json -newer "$marker" 2>/dev/null | sort)
  return "$rc"
}

# latency MARKER OUT: latency_report.py over every rung written since MARKER (every arm), to OUT (Task 14 Step 5).
# Informational: a failure is reported, not a stop.
latency() {
  local dirs=() f out
  while IFS= read -r f; do dirs+=("$(dirname "$f")"); done < <(find "$E15_RUNS" -name params.json -newer "$1" 2>/dev/null | sort)
  [ ${#dirs[@]} -gt 0 ] || return 0
  if out=$(python3 "$ANALYSIS/latency_report.py" "${dirs[@]}" --out "$2" 2>&1); then
    echo "E17B $STAGE latency_report.py: $2"
  else
    echo "E17B $STAGE latency_report.py FAILED (not a stop): $(printf '%s' "$out" | tail -1)"
  fi
}

# sq_point POINT: the squeeze point's MemoryMax (sq_mb, from the variable sq_var) and guest RAM (sq_ram; empty: 1024).
sq_point() {
  case "$1" in
  squeeze) sq_var=E17B_SQUEEZE_MEMMAX_MB sq_mb=$SQUEEZE_MB sq_ram="" ;;
  squeeze-256) sq_var=E17B_SQUEEZE256_MEMMAX_MB sq_mb=$SQUEEZE256_MB sq_ram=256 ;;
  *) die "sq_point: $1 is not a squeeze point" ;;
  esac
}

# run_cmd KIND ARGS...: one stage's work (its output goes to the stage log).
run_cmd() {
  local kind=$1 n mm
  shift
  # E17B-R51: the disk preflight's per-workspace estimate (lib.sh workspace_delta_kb: the template's allocated size
  # less the dataset, 388 MiB at pycache-d768) refuses a squeeze N=24 repeat and the N=128 pycache rungs on this
  # host's 300 GB; the measured cost is < 1 MiB per workspace (512 squeeze workspaces added 0.2 GiB; E17a: ~2 MiB).
  # The chain sets 8 MiB for the pycache family and the squeeze points, as E17a's rungs ran. The operator still
  # cannot set it (STAGE_KNOBS); run_cmd runs in a subshell, so the export is this stage's only.
  case " $* " in *" pycache"* | *" squeeze"*) export E15_WS_DELTA_MB=8 ;; esac
  case "$kind" in
  smoke)
    preflight pycache sbx ship-30 ship-120 ship-300
    bash "$SMOKE"
    ;;
  baseline)
    preflight "$1" "$2"
    bash "$BASELINE" "$1" "$2"
    ;;
  rung)
    preflight "$3" "$1"
    E15_TAG=lat bash "$RUNG" "$1" "$2" "$3"
    ;;
  rung256)
    preflight "$3" "$1"
    E17B_GUEST_RAM_MB=256 E15_TAG=ram256 bash "$RUNG" "$1" "$2" "$3"
    ;;
  ladder) # POINT ARM [START_N]
    preflight "$1" "$2"
    bash "$LADDER" "$1" "$2" ${3:+"$3"}
    ;;
  baseline256)
    preflight "$1" "$2"
    E17B_GUEST_RAM_MB=256 bash "$BASELINE" "$1" "$2"
    ;;
  squeeze-ladder) # POINT ARM
    sq_point "$1"
    [ -n "$sq_mb" ] || die "the $1 climb needs $sq_var (MiB, from a first short climb: Task 14 Step 3)"
    preflight "$1" "$2"
    env ${sq_ram:+E17B_GUEST_RAM_MB=$sq_ram} E15_SQUEEZE_MEMMAX_MB="$sq_mb" bash "$LADDER" "$1" "$2" ${E17B_SQUEEZE_START_N:+"$E17B_SQUEEZE_START_N"}
    ;;
  squeeze-rung) # POINT ARM
    sq_point "$1"
    local lj=$E15_RUNS/$1/ship-300/ladder.json
    [ -f "$lj" ] || die "no $lj: run the $1 ship-300 climb first"
    n=$(python3 -c 'import json,sys; s=json.load(open(sys.argv[1])).get("squeeze") or {}; print(s.get("stop_n") or "null", s.get("memmax_mb") or "null")' "$lj") ||
      die "$lj is unreadable: refusing (no N or MemoryMax to run $2 at)"
    read -r n mm <<<"$n"
    [ -n "$n" ] && [ -n "${mm:-}" ] || die "$lj is unreadable (no stop_n/memmax_mb): refusing"
    [ "$n" != null ] || die "the ship-300 $1 climb stopped at no N ($lj): nothing to run $2 at"
    [ "$mm" != null ] || die "$lj records no memmax_mb"
    [ -z "$sq_mb" ] || [ "$sq_mb" = "$mm" ] ||
      die "$sq_var=$sq_mb, but the ship-300 climb ran under $mm: $2 runs under the climb's value"
    preflight "$1" "$2"
    echo "squeeze: $2 at N=$n on $1 (the ship-300 climb's stop), E15_SQUEEZE_MEMMAX_MB=$mm${sq_ram:+, E17B_GUEST_RAM_MB=$sq_ram}"
    env ${sq_ram:+E17B_GUEST_RAM_MB=$sq_ram} E15_SQUEEZE_MEMMAX_MB="$mm" E15_TAG=sq bash "$RUNG" "$2" "$n" "$1"
    ;;
  script)
    n=$1
    shift
    [ -f "$E17_SRC/rig/$n" ] || die "no $E17_SRC/rig/$n (Task 11 provides it)"
    bash "$E17_SRC/rig/$n" "$@"
    ;;
  probe-overhead) # probe-overhead.sh runs baseline.sh default ship-300: the same commit preflight as a baseline stage
    preflight default ship-300
    [ -f "$E17_SRC/rig/probe-overhead.sh" ] || die "no $E17_SRC/rig/probe-overhead.sh"
    bash "$E17_SRC/rig/probe-overhead.sh"
    ;;
  ownwalk) # FILES...: the ownership-walk probe, one ownwalk.sh (its own worker cycle) per workspace size, in order
    for n in "$@"; do
      bash "$OWNWALK" "$n" || die "ownwalk.sh $n failed (its ownwalk.json and driver.log: $E15_RUNS/ownwalk/ship-300/F$n)"
    done
    ;;
  verdict) # the criteria from every rung at the pin (final review M1); 1-4 judged on fixed bars, 5 null until Task 13
    python3 "$ANALYSIS/verdict.py" "$E15_RUNS" --moca-commit "$E15_MOCA_PIN" --out "$L/verdict.json"
    ;;
  blocked) die "not wired: $*" ;;
  *) die "unknown stage kind $kind" ;;
  esac
}

rc=0
echo "E17B chain START $(date -u +%FT%TZ) src $(cat "$E15_ROOT/src/COMMIT" 2>/dev/null || echo unknown) pin $E15_MOCA_PIN predictions $(seal_state)"
for i in $(seq "$first" "$last"); do
  st=${STAGES[$i]}
  STAGE=$(s_name "$st")
  if ! selected "$i"; then
    case "$(s_needs "$st")" in
    ram256) echo "E17B $STAGE SKIP (cut, E17B-R45: E17B_RAM256=1 runs it)" ;;
    *) echo "E17B $STAGE SKIP (optional: E17B_OPTIONAL=1 runs it)" ;;
    esac
    continue
  fi
  if [ "$(s_needs "$st")" != - ] && ! sealed; then
    echo "E17B $STAGE REFUSED: predictions $(seal_state)"
    rc=1
    break
  fi
  echo "E17B $STAGE START $(date -u +%FT%TZ) :: $(s_cmd "$st")"
  rm -f "$L/$STAGE.done"
  : >"$L/$STAGE.start"
  read -r -a words <<<"$(s_cmd "$st")" # the command's words (split, never globbed)
  (run_cmd "${words[@]}") >"$L/$STAGE.log" 2>&1
  src=$?
  if [ "$src" != 0 ]; then
    echo "E17B $STAGE FAILED rc=$src $(tail -1 "$L/$STAGE.log" | cut -c1-300) (log $L/$STAGE.log); resume with --from $STAGE"
    rc=1
    break
  fi
  if ! gate "$L/$STAGE.start"; then
    echo "E17B $STAGE FAILED its analysis (above); resume with --from $STAGE after the user decides"
    rc=1
    break
  fi
  [ "$(s_needs "$st")" = - ] || latency "$L/$STAGE.start" "$L/$STAGE.latency"
  date -u +%FT%TZ >"$L/$STAGE.done"
  echo "E17B $STAGE DONE $(date -u +%FT%TZ)"
done
echo "E17B chain END rc=$rc $(date -u +%FT%TZ)"
exit "$rc"
