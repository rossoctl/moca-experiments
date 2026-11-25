#!/usr/bin/env bash
# experiments/e17-lease/rig/chain-e17d.sh [--list] [--from STAGE] [--to STAGE] -- the E17d run list on the metal host
# (experiments/e17-lease/PLAN-E17D.md Task 7; SPEC §14.6), in order, one stage at a time. chain-e17c.sh's pattern: the
# same stage table, seal check, knob refusal, analysis gate and per-stage files, for E17d's stages.
#
# Run by the controller only, as the rig's login user, from the staged copy, after bring-up (E17D=1 setup.sh, the leaf
# e17d-<pin8>-1024 by E17D=1 snapshot-e17b.sh, E17D=1 setup.sh again, E17D=1 bringup.sh):
#   bash /srv/e15/src/e17/rig/chain-e17d.sh               # from the first stage not done yet
#   bash /srv/e15/src/e17/rig/chain-e17d.sh --from lat-pycache-l2-sbx-n1 [--to verdict]
#   bash /srv/e15/src/e17/rig/chain-e17d.sh --list        # the stages, in order, with what each needs
#
# Every stage runs with E17D=1 (the profile: E17C=1 and E17B=1 semantics with E17D_MOCA_PIN, the moca-e17d checkout and
# the e17d-<pin8>-1024 leaf), on fresh-metal, with the manifest at ~/e17-manifest.md (E15_MANIFEST overrides). The
# caller's environment cannot change a stage: the per-rung knobs a stage sets itself are unset below, and the chain
# REFUSES to start (exit 1, each named) while any other stage-changing knob is set, even to "" (STAGE_KNOBS,
# chain-e17c.sh's list), or E17b's or E17c's switches (E17B_OPTIONAL, E17B_RAM256, E17C_OPTIONAL, E17C_RAM256), or an
# E17B_SQUEEZE_MEMMAX_MB other than 24576 (E17b's squeeze, SPEC §14.2). The operator's own inputs are
# E17B_SQUEEZE_START_N (resume a climb at the rung that failed) and E15_MANIFEST.
#
# THE SEAL. No measured rung runs before the predictions are sealed (spec §9, §14.4): a stage that needs "seal" runs only
# when experiments/e17-lease/predictions-e17d.json (staged beside this directory) exists, parses and has "sealed": true
# (the JSON boolean). The chain refuses up front -- nothing runs -- when any selected stage needs the seal and the file
# does not say so, and checks again right before each such stage. The sealed file also gives the stages their numbers:
# n_load (the load rungs' N: 128, or the largest N calibration found to fit, spec §14.5), min_seeds and min_warm.
#
# Each stage writes $L/<stage>.log (L = /srv/e15/e17d) and on success $L/<stage>.done. Without --from the chain starts
# at the first stage without a .done; --from STAGE starts there whatever is done; --to STAGE stops after it. The first
# failing stage stops the chain with "resume with --from <stage>".
#
# The stages (SPEC §14.6):
#   before the seal ("-"):
#     smoke: smoke.sh under E17D=1 (sbx ship-300 ship-300-l2 at pycache-l2 N=1).
#     socket-check: socket-check.sh (Task 9, the bring-up on the built snapshot: a tracked l2srv.py and an Exec's
#       l2c.py ping over /workspace/.l2/l2.sock, then exit 3 on the stale socket); refused, naming Task 9, until it exists.
#     cal-pycache-l2-ARM: the N = 1 baseline at pycache-l2 from the first call (baseline.sh, E15_START_ZERO=1), topped
#       up to 4 evaluable seeds N1-s<k> (chain-e17c.sh's cal rule), at most 12.
#     memcheck-pycache-l2-ship-300-l2-n128: one ship-300-l2 rung at N = 128 (E15_TAG=memcheck): the per-lease charge
#       and the committed total against the budget, before the seal (spec §14.5).
#   after it ("seal"):
#     lat-pycache-l2-ARM-n1: fresh N = 1 seeds N1-l<k> from 11 (E15_START_ZERO=1), sbx first, until min_seeds are
#       evaluable and, at the lease arms, the pooled warm py_requery and py_refit counts (level2.py --warm-count) reach
#       min_warm; at most 8 seeds (11..18). Eight seeds short of the minimum end the stage DONE with a note, and the
#       verdict leaves N = 1 null (ruling E17D-B9).
#     lat-pycache-l2-ARM-n128: one rung per arm at N = n_load (E15_TAG=lat: N<n_load>-lat; the stage keeps its name).
#     base-squeeze-l2-ARM, squeeze-l2-ARM: the squeeze point's baselines, then each lease arm's climb at
#       E17B_SQUEEZE_MEMMAX_MB 24576 (fixed by the chain). Last, so they can be cut (spec §14.6).
#     verdict: analysis/verdict_e17d.py over $E15_RUNS at the pin to $L/verdict.json.
#
# Before a stage, its run directories must hold no params.json from another moca commit than E17D_MOCA_PIN. After a
# stage, chain-e17c.sh's gate: every rung it wrote is checked for its own failure, and every ship-* rung is analysed
# (warmcold_lease.py, lease_ends.py, freed_from_shmem.py, vm_age_lease.py --sbx the same-named sbx rung), and every
# ship-300-l2 rung also by level2.py (--paired the same-named ship-300 rung). After a measured stage, latency_report.py
# runs to $L/<stage>.latency/ (informational).
#
# Output: "E17D <stage> START|DONE|FAILED|SKIP ..." lines. Exit 0 when every selected stage is done, 1 on a refusal or
# a failed stage, 2 on bad usage.
# Test hooks: E17D_RUNG, E17D_LADDER, E17D_BASELINE, E17D_SMOKE, E17D_SOCKET_CHECK replace rung.sh, ladder.sh,
# baseline.sh, smoke.sh, socket-check.sh; E17D_ANALYSIS the analysis directory. They are honoured only with
# E17D_TEST_HARNESS=1 (tests/chain-e17d.test.sh); otherwise any of them set refuses the chain like a knob.
set -uo pipefail
E15_PROG=chain-e17d.sh
STAGE_KNOBS=(E15_RUNG E15_MAX_COMMITTED_MB E15_MAX_RUNS E15_LADDER_EXTRA E15_SPREAD_S E15_MEMAVAIL_FLOOR_MIB
  E15_END_SESSION_RATE E15_ATTACH_TIMEOUT_S E15_BASELINE_MAX_SEEDS E15_WS_DELTA_MB E15_CLASSPROBE E15_PROBE_CALLS
  E15_PROBE_SEED E15_MEMINFO E15_OS_RELEASE E15_SLICE_DIR E15_STATS_URL E15_PROC E15_DISK_DEV E15_DISK_PATH
  E15_SQUEEZE_ACTIVE E15_SQUEEZE_RESTORED E15_SQUEEZE_ORIG_MAX E15_SQUEEZE_ORIG_HIGH E15_SQUEEZE_MAX E15_SQUEEZE_HIGH
  E17C_GATE_LIBRARY)
TEST_HOOKS=(E17D_RUNG E17D_LADDER E17D_BASELINE E17D_SMOKE E17D_SOCKET_CHECK E17D_ANALYSIS)
SQUEEZE_MB=24576 # SPEC §14.2: E17b's squeeze
knobs_set=()
for v in "${STAGE_KNOBS[@]}"; do [ -z "${!v+x}" ] || knobs_set+=("$v"); done
if [ "${E17D_TEST_HARNESS:-}" != 1 ]; then
  for v in "${TEST_HOOKS[@]}"; do [ -z "${!v+x}" ] || knobs_set+=("$v"); done
fi
if [ ${#knobs_set[@]} -gt 0 ]; then
  echo "E17D REFUSED: stage-changing variable(s) set in the environment: ${knobs_set[*]}; unset them (a leftover from another shell would change a sealed measurement silently; E17D_* hooks are for tests/chain-e17d.test.sh only)" >&2
  exit 1
fi
sw_set=()
for v in E17B_OPTIONAL E17B_RAM256 E17C_OPTIONAL E17C_RAM256; do [ -z "${!v+x}" ] || sw_set+=("$v"); done
if [ ${#sw_set[@]} -gt 0 ]; then
  echo "E17D REFUSED: E17b's or E17c's switch(es) set in the environment: ${sw_set[*]}; E17d has none" >&2
  exit 1
fi
if [ -n "${E17B_SQUEEZE_MEMMAX_MB+x}" ] && [ "$E17B_SQUEEZE_MEMMAX_MB" != "$SQUEEZE_MB" ]; then
  echo "E17D REFUSED: E17B_SQUEEZE_MEMMAX_MB=$E17B_SQUEEZE_MEMMAX_MB; E17d's squeeze runs at $SQUEEZE_MB MiB (SPEC §14.2), set by the chain: unset it" >&2
  exit 1
fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export E17D=1 E17C=1 E17B=1
export E15_HOST_PROFILE=fresh-metal
export E15_MANIFEST=${E15_MANIFEST:-$HOME/e17-manifest.md}
unset E15_MAX_SESSIONS E15_START_ZERO E15_TAG E15_SEED E15_WARMUP_S E15_WINDOW_S E15_GRACE_S E15_LADDER_RUNGS \
  E15_LADDER_TAG E15_K_MULT E15_CORPUS_OVERRIDE E15_END_SESSION_DEFER E15_SQUEEZE_MEMMAX_MB E17B_GUEST_RAM_MB
E15_RIG=$HERE/../../e15/rig
[ -f "$E15_RIG/lib.sh" ] || {
  printf '%s: no %s/lib.sh: run the staged copy (/srv/e15/src/e17/rig/chain-e17d.sh)\n' "$E15_PROG" "$E15_RIG" >&2
  exit 1
}
# shellcheck source=SCRIPTDIR/../../e15-session-density/rig/lib.sh
. "$E15_RIG/lib.sh"
E17_SRC=$E15_ROOT/src/e17
case "$HERE" in "$E17_SRC"/rig) ;; *) die "run the staged copy: $E17_SRC/rig/chain-e17d.sh (not $HERE)" ;; esac
PREDICTIONS=$E17_SRC/predictions-e17d.json
RUNG=${E17D_RUNG:-$E15_SRC/rig/rung.sh}
LADDER=${E17D_LADDER:-$E15_SRC/rig/ladder.sh}
BASELINE=${E17D_BASELINE:-$E15_SRC/rig/baseline.sh}
SMOKE=${E17D_SMOKE:-$E17_SRC/rig/smoke.sh}
SOCKET_CHECK=${E17D_SOCKET_CHECK:-$E17_SRC/rig/socket-check.sh}
ANALYSIS=${E17D_ANALYSIS:-$E17_SRC/analysis}
L=$E15_ROOT/e17d
CAL_SEEDS=4      # chain-e17c.sh's cal rule
CAL_MAX_SEEDS=12 # baseline.sh's own cap
SEAL_SEED_FIRST=11
SEAL_SEED_MAX=8 # PLAN-E17D Task 7: at most 8 N = 1 seeds
WARM_CLASSES=py_requery,py_refit
POINT=pycache-l2
SQ_POINT=squeeze-l2
NOTE_MARK="E17D-NOTE:"

# name|needs|command[|note]: needs is "-" (allowed before the seal) or "seal".
STAGES=(
  "smoke|-|smoke"
  "socket-check|-|socket-check|Task 9: a tracked l2srv and an Exec's l2c.py over /workspace/.l2/l2.sock; exit 3 on the stale socket"
  "cal-pycache-l2-sbx|-|cal $POINT sbx"
  "cal-pycache-l2-ship-300|-|cal $POINT ship-300"
  "cal-pycache-l2-ship-300-l2|-|cal $POINT ship-300-l2"
  "memcheck-pycache-l2-ship-300-l2-n128|-|memcheck $POINT ship-300-l2 128|the per-lease charge and the committed total against the budget (spec §14.5)"
  "lat-pycache-l2-sbx-n1|seal|seal-seeds $POINT sbx|seeds from 11 until min_seeds evaluable, at most 8 (N1-l<k>), E15_START_ZERO=1"
  "lat-pycache-l2-ship-300-n1|seal|seal-seeds $POINT ship-300|seeds from 11 until min_seeds and min_warm (py_requery, py_refit), at most 8"
  "lat-pycache-l2-ship-300-l2-n1|seal|seal-seeds $POINT ship-300-l2|seeds from 11 until min_seeds and min_warm (py_requery, py_refit), at most 8"
  "lat-pycache-l2-sbx-n128|seal|rung-load sbx $POINT|N = predictions n_load (N<n_load>-lat)"
  "lat-pycache-l2-ship-300-n128|seal|rung-load ship-300 $POINT|N = predictions n_load (N<n_load>-lat)"
  "lat-pycache-l2-ship-300-l2-n128|seal|rung-load ship-300-l2 $POINT|N = predictions n_load (N<n_load>-lat)"
  "base-squeeze-l2-ship-300|seal|baseline $SQ_POINT ship-300"
  "base-squeeze-l2-ship-300-l2|seal|baseline $SQ_POINT ship-300-l2"
  "squeeze-l2-ship-300|seal|squeeze-ladder $SQ_POINT ship-300|E17B_SQUEEZE_MEMMAX_MB 24576, fixed by the chain; may be cut (spec §14.6)"
  "squeeze-l2-ship-300-l2|seal|squeeze-ladder $SQ_POINT ship-300-l2|E17B_SQUEEZE_MEMMAX_MB 24576, fixed by the chain; may be cut (spec §14.6)"
  "verdict|seal|verdict|analysis/verdict_e17d.py over the runs (Task 6)"
)

usage() {
  echo "usage: chain-e17d.sh [--list] [--from STAGE] [--to STAGE]" >&2
  exit 2
}
s_name() { printf '%s' "${1%%|*}"; }
s_needs() {
  local r=${1#*|}
  printf '%s' "${r%%|*}"
}
s_cmd() {
  local r=${1#*|}
  r=${r#*|}
  printf '%s' "${r%%|*}"
}
s_note() {
  local r=${1#*|}
  r=${r#*|}
  case "$r" in *"|"*) printf '%s' "${r#*|}" ;; esac
}
stage_index() {
  local i
  for i in "${!STAGES[@]}"; do [ "$(s_name "${STAGES[$i]}")" = "$1" ] && echo "$i" && return 0; done
  return 1
}
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
# pred KEY: a positive integer of the sealed predictions (n_load, min_seeds, min_warm); dies when absent or not one.
pred() {
  local v
  v=$(python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print(v if isinstance(v, int) and not isinstance(v, bool) and v > 0 else "")' "$PREDICTIONS" "$1" 2>/dev/null)
  [ -n "$v" ] || die "$PREDICTIONS has no positive integer \"$1\" (the seal fixes it, PLAN-E17D Task 10)"
  echo "$v"
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
  echo "chain-e17d.sh: no stage '$FROM' (--list shows them)" >&2
  exit 2
}; fi
if [ -n "$TO" ]; then stage_index "$TO" >/dev/null || {
  echo "chain-e17d.sh: no stage '$TO' (--list shows them)" >&2
  exit 2
}; fi

if [ "$LIST" = 1 ]; then
  echo "E17D stages (predictions: $(seal_state)); needs: - before the seal, seal"
  for st in "${STAGES[@]}"; do
    n=$(s_name "$st")
    printf '%-40s %-5s %-5s %s%s\n' "$n" "$(s_needs "$st")" "$([ -f "$L/$n.done" ] && echo "done" || echo -)" "$(s_cmd "$st")" "$(n2=$(s_note "$st"); [ -n "$n2" ] && printf '  # %s' "$n2")"
  done
  exit 0
fi

last=$((${#STAGES[@]} - 1))
[ -z "$TO" ] || last=$(stage_index "$TO")
if [ -n "$FROM" ]; then
  first=$(stage_index "$FROM")
else
  first=""
  for i in $(seq 0 "$last"); do
    if [ ! -f "$L/$(s_name "${STAGES[$i]}").done" ]; then
      first=$i
      break
    fi
  done
  if [ -z "$first" ]; then
    echo "E17D every stage up to $(s_name "${STAGES[$last]}") is done ($L/*.done)"
    exit 0
  fi
  echo "E17D resuming at $(s_name "${STAGES[$first]}") (the first stage without $L/<stage>.done)"
fi
[ "$first" -le "$last" ] || {
  echo "chain-e17d.sh: --from $(s_name "${STAGES[$first]}") comes after --to $(s_name "${STAGES[$last]}")" >&2
  exit 2
}

need_seal=()
for i in $(seq "$first" "$last"); do
  [ "$(s_needs "${STAGES[$i]}")" = - ] || need_seal+=("$(s_name "${STAGES[$i]}")")
done
if [ ${#need_seal[@]} -gt 0 ] && ! sealed; then
  echo "E17D REFUSED: predictions $(seal_state); no measured rung runs before the predictions are sealed (spec §9)." >&2
  echo "E17D REFUSED: stages that need the seal: ${need_seal[*]} (stop before them with --to memcheck-pycache-l2-ship-300-l2-n128)" >&2
  exit 1
fi
e17d_require_pin
e17c_require_pin
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
  [ -z "$bad" ] || die "$bad is not from E17D_MOCA_PIN $E15_MOCA_PIN: a result that mixes commits is not one arm; move that arm's runs aside first"
}

# rung_flags DIR: why the rung itself failed, "" when it did not (chain-e17c.sh's).
rung_flags() {
  python3 - "$1" <<'PY'
import json, os, sys
d = sys.argv[1]
p = json.load(open(os.path.join(d, "params.json")))
rp = os.path.join(d, "record.json")
r = json.load(open(rp)) if os.path.exists(rp) else None
why = []
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

# gate MARKER: chain-e17c.sh's gate, plus level2.py on every ship-300-l2 rung; 1 when the chain must stop.
gate() {
  local marker=$1 rc=0 d arm f out sbxd l1d extra
  while IFS= read -r f; do
    d=$(dirname "$f")
    out=$(rung_flags "$d" 2>/dev/null) || out="the rung flags are unreadable ($f)"
    if [ -n "$out" ]; then
      echo "E17D $STAGE STOP ${d#"$E15_RUNS"/}: $out (the rung failed: goes to the user)"
      rc=1
      continue
    fi
    arm=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("arm", ""))' "$f" 2>/dev/null)
    case "$arm" in ship-*) ;; *) continue ;; esac
    sbxd=$(dirname "$(dirname "$d")")/sbx/$(basename "$d")
    l1d=$(dirname "$(dirname "$d")")/ship-300/$(basename "$d")
    for a in warmcold_lease.py lease_ends.py freed_from_shmem.py vm_age_lease.py level2.py; do
      extra=()
      [ "$a" != vm_age_lease.py ] || [ ! -f "$sbxd/params.json" ] || extra=(--sbx "$sbxd")
      if [ "$a" = level2.py ]; then
        [ "$arm" = ship-300-l2 ] || continue
        [ ! -f "$l1d/params.json" ] || extra=(--paired "$l1d")
      fi
      out=$(python3 "$ANALYSIS/$a" "$d" ${extra[@]+"${extra[@]}"} 2>&1) || {
        echo "E17D $STAGE ANALYSIS $a failed on $d: $(printf '%s' "$out" | tail -1)"
        rc=1
        continue 2
      }
      echo "E17D $STAGE $a ${d#"$E15_RUNS"/}: $out"
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
if w.get("config_refusals"):
    why.append("%d configuration refusal(s) %s" % (w["config_refusals"], json.dumps(w.get("config_refusals_by_cause") or {}, sort_keys=True)))
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
      echo "E17D $STAGE STOP ${d#"$E15_RUNS"/}: $out (goes to the user)"
      rc=1
    fi
  done < <(find "$E15_RUNS" -name params.json -newer "$marker" 2>/dev/null | sort)
  return "$rc"
}

latency() {
  local dirs=() f out
  while IFS= read -r f; do dirs+=("$(dirname "$f")"); done < <(find "$E15_RUNS" -name params.json -newer "$1" 2>/dev/null | sort)
  [ ${#dirs[@]} -gt 0 ] || return 0
  if out=$(python3 "$ANALYSIS/latency_report.py" "${dirs[@]}" --out "$2" 2>&1); then
    echo "E17D $STAGE latency_report.py: $2"
  else
    echo "E17D $STAGE latency_report.py FAILED (not a stop): $(printf '%s' "$out" | tail -1)"
  fi
}

# seeds POINT ARM PREFIX: "<evaluable> <highest k> <evaluable dirs...>" over $E15_RUNS/POINT/ARM/N1-<PREFIX><k>
# (evaluable: record.json, reason not empty_window). An unreadable record.json exits non-zero.
seeds() {
  python3 - "$E15_RUNS/$1/$2" "$3" <<'PY'
import json, os, re, sys
root, pre, ok, top, dirs = sys.argv[1], sys.argv[2], 0, 0, []
for n in sorted(os.listdir(root)) if os.path.isdir(root) else []:
    m = re.fullmatch(r"N1-" + re.escape(pre) + r"([0-9]+)", n)
    if not m:
        continue
    top = max(top, int(m.group(1)))
    rp = os.path.join(root, n, "record.json")
    if os.path.exists(rp) and json.load(open(rp)).get("reason") != "empty_window":
        ok += 1
        dirs.append(os.path.join(root, n))
print(ok, top, *dirs)
PY
}

run_cmd() {
  local kind=$1 n ok top out dirs warm min_seeds min_warm ran
  shift
  export E15_WS_DELTA_MB=8 # E17B-R51: 8 MiB per workspace at the pycache family and the squeeze points
  case "$kind" in
  smoke)
    preflight "$POINT" sbx ship-300 ship-300-l2
    bash "$SMOKE"
    ;;
  socket-check)
    [ -f "$SOCKET_CHECK" ] || die "no $SOCKET_CHECK: the socket check is Task 9's (bring-up on the built snapshot), not built yet"
    bash "$SOCKET_CHECK"
    ;;
  cal) # POINT ARM: chain-e17c.sh's cal
    preflight "$1" "$2"
    E15_START_ZERO=1 bash "$BASELINE" "$1" "$2" || die "baseline.sh $1 $2 failed"
    while :; do
      out=$(seeds "$1" "$2" s) || die "the seeds under $E15_RUNS/$1/$2 are unreadable: no calibration"
      read -r ok top _ <<<"$out"
      [[ ${ok:-} =~ ^[0-9]+$ && ${top:-} =~ ^[0-9]+$ ]] || die "the seeds under $E15_RUNS/$1/$2 are unreadable (seed count '${out}')"
      [ "$ok" -lt "$CAL_SEEDS" ] || break
      [ "$top" -lt "$CAL_MAX_SEEDS" ] || die "$CAL_MAX_SEEDS seeds gave $ok evaluable N=1 runs at $1 $2 (need $CAL_SEEDS): no calibration"
      n=$((top + 1))
      echo "cal: $2 at $1 has $ok evaluable seed(s); seed $n (E15_START_ZERO=1)"
      E15_START_ZERO=1 E15_SEED=$n E15_TAG=s$n bash "$RUNG" "$2" 1 "$1" || die "rung.sh $2 1 $1 (seed $n) failed"
    done
    ;;
  memcheck) # POINT ARM N: the calibration's memory check (before the seal)
    preflight "$1" "$2"
    E15_TAG=memcheck bash "$RUNG" "$2" "$3" "$1"
    ;;
  seal-seeds) # POINT ARM: N = 1 seeds from 11 until min_seeds (and, at a lease arm, min_warm), at most 8
    preflight "$1" "$2"
    min_seeds=$(pred min_seeds) || exit 1
    min_warm=$(pred min_warm) || exit 1
    ran=0
    while :; do
      out=$(seeds "$1" "$2" l) || die "the seeds under $E15_RUNS/$1/$2 are unreadable (a corrupt N1-l*/record.json?): no seal seeds"
      read -r ok top dirs <<<"$out"
      [[ ${ok:-} =~ ^[0-9]+$ && ${top:-} =~ ^[0-9]+$ ]] || die "the seeds under $E15_RUNS/$1/$2 are unreadable (seed count '${out}')"
      warm=""
      if [ "$2" != sbx ] && [ "$ok" -gt 0 ]; then
        # shellcheck disable=SC2086 # dirs is a word list of rung directories (no spaces under $E15_RUNS)
        warm=$(python3 "$ANALYSIS/level2.py" --warm-count "$WARM_CLASSES" $dirs) || die "level2.py --warm-count failed on $dirs"
        warm=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["min"])' "$warm") || die "unreadable warm count"
      fi
      if [ "$ok" -ge "$min_seeds" ] && { [ "$2" = sbx ] || [ "${warm:-0}" -ge "$min_warm" ]; }; then
        echo "seal-seeds: $2 at $1 has $ok evaluable seed(s) (need $min_seeds)${warm:+, warm minimum $warm (need $min_warm)}"
        break
      fi
      n=$((top < SEAL_SEED_FIRST ? SEAL_SEED_FIRST : top + 1))
      if [ "$n" -ge $((SEAL_SEED_FIRST + SEAL_SEED_MAX)) ]; then
        echo "$NOTE_MARK $2 at $1: $SEAL_SEED_MAX seeds give $ok evaluable seed(s)${warm:+ and a warm minimum of $warm} (need $min_seeds and $min_warm): N = 1 is not judged (verdict null)"
        break
      fi
      echo "seal-seeds: $2 at $1 has $ok evaluable seed(s)${warm:+, warm minimum $warm}; seed $n (E15_START_ZERO=1, tag l$n)"
      E15_START_ZERO=1 E15_SEED=$n E15_TAG=l$n bash "$RUNG" "$2" 1 "$1" || die "rung.sh $2 1 $1 (seed $n) failed"
      ran=$((ran + 1))
    done
    ;;
  rung-load) # ARM POINT: one rung at the sealed n_load
    n=$(pred n_load) || exit 1
    preflight "$2" "$1"
    echo "rung-load: $1 at $2, N=$n (predictions n_load)"
    E15_TAG=lat bash "$RUNG" "$1" "$n" "$2"
    ;;
  baseline)
    preflight "$1" "$2"
    bash "$BASELINE" "$1" "$2"
    ;;
  squeeze-ladder) # POINT ARM
    preflight "$1" "$2"
    E15_SQUEEZE_MEMMAX_MB="$SQUEEZE_MB" bash "$LADDER" "$1" "$2" ${E17B_SQUEEZE_START_N:+"$E17B_SQUEEZE_START_N"}
    ;;
  verdict)
    [ -f "$ANALYSIS/verdict_e17d.py" ] || die "no $ANALYSIS/verdict_e17d.py (Task 6 writes it): no verdict"
    python3 "$ANALYSIS/verdict_e17d.py" "$E15_RUNS" --moca-commit "$E15_MOCA_PIN" --predictions "$PREDICTIONS" --out "$L/verdict.json"
    ;;
  *) die "unknown stage kind $kind" ;;
  esac
}

rc=0
echo "E17D chain START $(date -u +%FT%TZ) src $(cat "$E15_ROOT/src/COMMIT" 2>/dev/null || echo unknown) pin $E15_MOCA_PIN predictions $(seal_state)"
for i in $(seq "$first" "$last"); do
  st=${STAGES[$i]}
  STAGE=$(s_name "$st")
  if [ "$(s_needs "$st")" != - ] && ! sealed; then
    echo "E17D $STAGE REFUSED: predictions $(seal_state)"
    rc=1
    break
  fi
  echo "E17D $STAGE START $(date -u +%FT%TZ) :: $(s_cmd "$st")"
  rm -f "$L/$STAGE.done"
  : >"$L/$STAGE.start"
  read -r -a words <<<"$(s_cmd "$st")"
  (run_cmd "${words[@]}") >"$L/$STAGE.log" 2>&1
  src=$?
  if [ "$src" != 0 ]; then
    echo "E17D $STAGE FAILED rc=$src $(tail -1 "$L/$STAGE.log" | cut -c1-300) (log $L/$STAGE.log); resume with --from $STAGE"
    rc=1
    break
  fi
  if ! gate "$L/$STAGE.start"; then
    echo "E17D $STAGE FAILED its analysis (above); resume with --from $STAGE after the user decides"
    rc=1
    break
  fi
  [ "$(s_needs "$st")" = - ] || latency "$L/$STAGE.start" "$L/$STAGE.latency"
  date -u +%FT%TZ >"$L/$STAGE.done"
  note=$(grep -m1 "^$NOTE_MARK" "$L/$STAGE.log")
  echo "E17D $STAGE DONE $(date -u +%FT%TZ)${note:+ (${note#"$NOTE_MARK" })}"
done
echo "E17D chain END rc=$rc $(date -u +%FT%TZ)"
exit "$rc"
