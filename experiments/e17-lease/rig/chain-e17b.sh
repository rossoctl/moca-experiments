#!/usr/bin/env bash
# experiments/e17-lease/rig/chain-e17b.sh [--list] [--from STAGE] [--to STAGE] -- the E17b run list on the metal host
# (experiments/e17-lease/PLAN-E17B.md Task 12 Steps 3 and 5, Task 14), in order, one stage at a time.
#
# Run by the controller only, as the rig's login user, from the staged copy, after bring-up (setup.sh and
# bringup.sh with E17B=1, the snapshot-e17b.sh leaves):
#   bash /srv/e15/src/e17/rig/chain-e17b.sh               # from the first stage not done yet
#   bash /srv/e15/src/e17/rig/chain-e17b.sh --from lat-pycache-sbx-n128 [--to ladder-default-ship-300]
#   bash /srv/e15/src/e17/rig/chain-e17b.sh --list        # the stages, in order, with what each needs
#
# Every stage runs with E17B=1 (the profile: its own moca pin and checkout, the -e17b binaries), on fresh-metal,
# with the manifest at ~/e17-manifest.md (E15_MANIFEST overrides). Probe-only and per-rung knobs from the caller's
# environment never reach a stage (unset below); the stage sets what it needs.
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
# the ship-30/ship-120 ladders, if the rig time allows), else SKIP.
#
# Before a stage, its run directories ($E15_RUNS/POINT/ARM) must hold no params.json from another moca commit than
# E17B_MOCA_PIN (a result that mixes commits is not one arm; under E17B=1 nothing sealed is overwritten, E17B-R3).
# After a stage, every rung it wrote for a ship-* arm is analysed (Task 14 Step 5): warmcold_lease.py, lease_ends.py
# and vm_age_lease.py; an unknown call, a source disagreement, an unmatched lease end, or an analysis failure stops
# the chain there for the user. latency_report.py is the report's, over all rungs (Task 15).
#
# The squeeze stages (Task 14 Step 3) need E17B_SQUEEZE_MEMMAX_MB (MiB; chosen from a first short climb): the
# ship-300 climb is ladder.sh squeeze ship-300 under it (its stop rule: experiments/e17-lease/analysis/squeeze_rule.py);
# sbx then runs once at the N that climb stopped at, under the same value, both read from its ladder.json.
# Stages that cannot run yet are "blocked" and fail naming what is missing: the 256 MiB guest runs (no guest-RAM or
# snapshot selection is wired into worker_env yet) and the ownership-walk runner (Task 11).
#
# Output: "E17B <stage> START|DONE|FAILED|SKIP ..." lines. Exit 0 when every selected stage is done, 1 on a
# refusal or a failed stage, 2 on bad usage.
# Test hooks (rig.test.sh-style scratch roots only matter through lib.sh): E17B_RUNG, E17B_LADDER, E17B_BASELINE,
# E17B_SMOKE replace rung.sh, ladder.sh, baseline.sh, smoke.sh; E17B_ANALYSIS the analysis directory.
set -uo pipefail
E15_PROG=chain-e17b.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export E17B=1
export E15_HOST_PROFILE=fresh-metal
export E15_MANIFEST=${E15_MANIFEST:-$HOME/e17-manifest.md}
SQUEEZE_MB=${E17B_SQUEEZE_MEMMAX_MB:-}
unset E15_MAX_SESSIONS E15_START_ZERO E15_TAG E15_SEED E15_WARMUP_S E15_WINDOW_S E15_GRACE_S E15_LADDER_RUNGS \
  E15_LADDER_TAG E15_K_MULT E15_CORPUS_OVERRIDE E15_END_SESSION_DEFER E15_SQUEEZE_MEMMAX_MB
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
ANALYSIS=${E17B_ANALYSIS:-$E17_SRC/analysis}
L=$E15_ROOT/e17b
SQUEEZE_LADDER=$E15_RUNS/squeeze/ship-300/ladder.json

# name|needs|command: needs is "-" (allowed before the seal), "seal", or "opt" (seal, and E17B_OPTIONAL=1).
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
  "ladder-default-sbx|seal|ladder default sbx"
  "ladder-default-ship-300|seal|ladder default ship-300"
  # Task 14 Step 3: squeeze (its own baselines, then the ship-300 climb, then sbx at its stop N)
  "base-squeeze-sbx|seal|baseline squeeze sbx"
  "base-squeeze-ship-300|seal|baseline squeeze ship-300"
  "squeeze-ship-300|seal|squeeze-ladder ship-300"
  "squeeze-sbx|seal|squeeze-rung sbx"
  # Task 14 Step 4: the §7.4 probes (Task 11)
  "probe-overhead|seal|script probe-overhead.sh"
  "ownwalk|seal|blocked the ownership-walk runner (Task 11: driver subcommand ownwalk at 10000, 100000, 500000 files)"
  # Task 14 Step 2, optional: the ship-30 and ship-120 ladders at default (the user may cut them)
  "base-default-ship-30|opt|baseline default ship-30"
  "base-default-ship-120|opt|baseline default ship-120"
  "ladder-default-ship-30|opt|ladder default ship-30"
  "ladder-default-ship-120|opt|ladder default ship-120"
  # Task 14 Steps 1 and 3 at 256 MiB guests (spec §5): not wired yet
  "ram256-pycache-sbx-n1|seal|blocked a 256 MiB guest-RAM and snapshot selection for the rung's worker (lib.sh worker_env writes SH_GUEST_RAM_MB=1024 and SH_SNAPSHOT_IMAGE=\$E15_SNAPIMG)"
  "ram256-pycache-ship-300-n1|seal|blocked a 256 MiB guest-RAM and snapshot selection (see ram256-pycache-sbx-n1)"
  "ram256-squeeze|seal|blocked a 256 MiB guest-RAM and snapshot selection, and D scaled to the dataset-to-RAM ratio"
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
s_cmd() {
  local r=${1#*|}
  printf '%s' "${r#*|}"
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
  echo "E17B stages (predictions: $(seal_state)); needs: - before the seal, seal, opt (E17B_OPTIONAL=1)"
  for st in "${STAGES[@]}"; do
    n=$(s_name "$st")
    printf '%-32s %-5s %-5s %s\n' "$n" "$(s_needs "$st")" "$([ -f "$L/$n.done" ] && echo "done" || echo -)" "$(s_cmd "$st")"
  done
  exit 0
fi

# --- the selection: [first, last], optional stages only with E17B_OPTIONAL=1 -------------------------------------
last=$((${#STAGES[@]} - 1))
[ -z "$TO" ] || last=$(stage_index "$TO")
selected() { [ "$(s_needs "${STAGES[$1]}")" != opt ] || [ "${E17B_OPTIONAL:-0}" = 1 ]; }
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
  )
  [ -z "$bad" ] || die "$bad is not from E17B_MOCA_PIN $E15_MOCA_PIN: a result that mixes commits is not one arm; move that arm's runs aside first"
}

# gate MARKER: analyse every ship-* rung written since MARKER (Task 14 Step 5); 1 when the chain must stop.
gate() {
  local marker=$1 rc=0 d arm f out
  while IFS= read -r f; do
    d=$(dirname "$f")
    arm=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("arm", ""))' "$f" 2>/dev/null)
    case "$arm" in ship-*) ;; *) continue ;; esac
    for a in warmcold_lease.py lease_ends.py vm_age_lease.py; do
      out=$(python3 "$ANALYSIS/$a" "$d" 2>&1) || {
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
why = []
if w.get("unknown"):
    why.append("%d unknown call(s)" % w["unknown"])
if w.get("disagreements"):
    why.append("%d source disagreement(s)" % w["disagreements"])
un = (e.get("notices") or {}).get("unmatched_ends") or []
if un:
    why.append("%d unmatched lease end(s)" % len(un))
print("; ".join(why))
PY
    ) || out="the analysis outputs are unreadable"
    if [ -n "$out" ]; then
      echo "E17B $STAGE STOP ${d#"$E15_RUNS"/}: $out (Task 14 Step 5: goes to the user)"
      rc=1
    fi
  done < <(find "$E15_RUNS" -name params.json -newer "$marker" 2>/dev/null | sort)
  return "$rc"
}

# run_cmd KIND ARGS...: one stage's work (its output goes to the stage log).
run_cmd() {
  local kind=$1 n mm
  shift
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
  ladder)
    preflight "$1" "$2"
    bash "$LADDER" "$1" "$2"
    ;;
  squeeze-ladder)
    [ -n "$SQUEEZE_MB" ] || die "the squeeze climb needs E17B_SQUEEZE_MEMMAX_MB (MiB, from a first short climb: Task 14 Step 3)"
    preflight squeeze "$1"
    E15_SQUEEZE_MEMMAX_MB=$SQUEEZE_MB bash "$LADDER" squeeze "$1"
    ;;
  squeeze-rung)
    [ -f "$SQUEEZE_LADDER" ] || die "no $SQUEEZE_LADDER: run squeeze-ship-300 first"
    read -r n mm < <(python3 -c 'import json,sys; s=json.load(open(sys.argv[1])).get("squeeze") or {}; print(s.get("stop_n") or "null", s.get("memmax_mb") or "null")' "$SQUEEZE_LADDER")
    [ "$n" != null ] || die "the ship-300 squeeze climb stopped at no N ($SQUEEZE_LADDER): nothing to run $1 at"
    [ "$mm" != null ] || die "$SQUEEZE_LADDER records no memmax_mb"
    [ -z "$SQUEEZE_MB" ] || [ "$SQUEEZE_MB" = "$mm" ] ||
      die "E17B_SQUEEZE_MEMMAX_MB=$SQUEEZE_MB, but the ship-300 climb ran under $mm: $1 runs under the climb's value"
    preflight squeeze "$1"
    echo "squeeze: $1 at N=$n (the ship-300 climb's stop), E15_SQUEEZE_MEMMAX_MB=$mm"
    E15_SQUEEZE_MEMMAX_MB=$mm E15_TAG=sq bash "$RUNG" "$1" "$n" squeeze
    ;;
  script)
    n=$1
    shift
    [ -f "$E17_SRC/rig/$n" ] || die "no $E17_SRC/rig/$n (Task 11 provides it)"
    bash "$E17_SRC/rig/$n" "$@"
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
    echo "E17B $STAGE SKIP (optional: E17B_OPTIONAL=1 runs it)"
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
  date -u +%FT%TZ >"$L/$STAGE.done"
  echo "E17B $STAGE DONE $(date -u +%FT%TZ)"
done
echo "E17B chain END rc=$rc $(date -u +%FT%TZ)"
exit "$rc"
