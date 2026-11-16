#!/usr/bin/env bash
# experiments/e15-session-density/rig/ladder.sh POINT ARM [START_N] -- run rung.sh up the ladder (SPEC §8, §10.2, §10.3).
#
# Ladder: 1 8 16 24 32 40 48 56 64 80 96 128 (fresh-metal: then 160 ... 1024, lib.sh E15_LADDER), from
# START_N (default 1; it must be on the ladder).
# Each rung's record.json decides, in order:
#   rig errors (never a host verdict -- the ladder DIES, it records no stopped_at):
#     aborted=true, time_origin_mismatch=true, offset_join_misses>0 (class pace could not join the
#     corpus), a rung.sh failure (incl. a missing N=1 baseline)
#     unseeded_sessions>0   -> rig_error: re-run once with K doubled (E15_K_MULT=2, tag k2);
#                              die if still unseeded
#   repeat_required=true  -> the rung is re-run ONCE with the warm-up doubled (tag repeat);
#                            the repeat's record is the one that counts
#   two verdicts per rung (record.json): holds (SPEC §8, condition 4 = p95 of class excess <=
#   max(3x the N=1 excess p95, 50 ms)) and holds_abs (condition 4 = p95(class excess) <= B + 250 ms,
#   B = the arm's N=1 within-class excess p95). Each has its own ladder: n_max (primary) is the
#   largest N holding with every rung before it holding; n_max_abs likewise for holds_abs. The
#   ladder climbs while EITHER is still unbroken and stops at the first rung where both are. A rung below START_N is assumed held (SPEC §10.3: other points start two
# steps below the default N_max), and ladder.json says so.
#
# Writes /srv/e15/runs/POINT/ARM/ladder.json:
#   {point, arm, start_n, ladder, rungs: [{n, holds, holds_abs, repeated, median_class_pace,
#    rig_errors, dir}], n_max, stopped_at, n_max_abs, stopped_at_abs, abs_rule, n1_overhead_ms,
#    n1_median_pace}
# Environment passes through to rung.sh (E15_WARMUP_S, E15_WINDOW_S, ...). E15_RUNG overrides the
# rung command (tests only).
#
# E16 (fresh-metal only): E15_LADDER_RUNGS="256 384 512" climbs exactly these N, ascending, each on
# E15_LADDER, with every rule above unchanged (it stops at the first rung where both verdicts are
# broken); START_N is then the first of them (a START_N argument is refused). ladder.json adds
# rungs_requested. A requested N not on the ladder: exit 2, nothing run. aws-prelim ignores the
# variable (the sealed procedure).
# E16 (fresh-metal only): E15_LADDER_TAG=s2 prefixes every rung directory's tag (N<n>-s2,
# N<n>-s2-repeat, N<n>-s2-k2, ...), so a second-seed run (E15_SEED=2) never moves the seed-1 rung
# aside. A tag must be [a-z0-9][a-z0-9-]* (e.g. s2, stag-s2); anything else exits 2. aws-prelim ignores it.
#
# E17b squeeze (POINT squeeze or squeeze-256, E17B=1, fresh-metal; experiments/e17-lease/PLAN-E17B.md Task 9): a ship arm only, and
# E15_SQUEEZE_MEMMAX_MB is required (every rung runs under it; rung.sh); the knob is refused at any other point.
# Every rule above still runs and holds/n_max are still recorded, but the climb stops on the squeeze rule instead
# of on condition 4: after each counted rung, experiments/e17-lease/analysis/squeeze_rule.py (staged at
# $E15_ROOT/src/e17/analysis) judges its window. The climb stops at the first rung with a memory-guard event
# (params.json memory_abort, the MemAvailable watchdog, or oom_kills > 0: stopped_by "guard"), else at the first
# rung where memory_reclaim rose in every whole minute of the window (stopped_by "reclaim_rate"); an undecidable
# rung (met null) is a rig error. ladder.json adds squeeze: {rule, memmax_mb, stop_n, stopped_by, rungs: [{n, met,
# min_per_minute, guard, dir}]}; stop_n is null and stopped_by "top_of_ladder" when no rung stopped it.
set -euo pipefail
E15_PROG=ladder.sh
# Probe-only knobs (classprobe.sh) must never reach a measured rung: rung.sh would start every
# session at call 0 or end the run after one session.
unset E15_MAX_SESSIONS E15_START_ZERO
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
# shellcheck source=points.sh
. "$HERE/points.sh"

usage() {
  echo "usage: ladder.sh POINT ARM [START_N]   (ARM: ${E15_ARMS[*]}; START_N on: ${E15_LADDER[*]})" >&2
  exit 2
}
[ $# -ge 2 ] && [ $# -le 3 ] || usage
POINT=$1
ARM=$2
START=${3:-1}
e15_is_arm "$ARM" || {
  echo "ladder.sh: unknown ARM '$ARM'" >&2
  usage
}
e15_point_arms "$POINT" >/dev/null || {
  echo "ladder.sh: unknown POINT '$POINT'" >&2
  usage
}
e15_on_ladder "$START" || {
  echo "ladder.sh: START_N $START is not on the ladder" >&2
  usage
}
# The rungs to climb: E15_LADDER from START_N, or (E16, fresh-metal) E15_LADDER_RUNGS.
CLIMB=()
REQUESTED=""
if [ "$E15_HOST_PROFILE" = fresh-metal ] && [ -n "${E15_LADDER_RUNGS:-}" ]; then
  [ $# -le 2 ] || {
    echo "ladder.sh: E15_LADDER_RUNGS and START_N are exclusive" >&2
    exit 2
  }
  prev=0
  for n in $E15_LADDER_RUNGS; do
    case "$n" in "" | *[!0-9]*)
      echo "ladder.sh: E15_LADDER_RUNGS: '$n' is not a number" >&2
      exit 2
      ;;
    esac
    e15_on_ladder "$n" || {
      echo "ladder.sh: E15_LADDER_RUNGS: N=$n is not on the ladder" >&2
      exit 2
    }
    [ "$n" -gt "$prev" ] || {
      echo "ladder.sh: E15_LADDER_RUNGS: N=$n does not ascend" >&2
      exit 2
    }
    prev=$n
    CLIMB+=("$n")
  done
  [ ${#CLIMB[@]} -gt 0 ] || {
    echo "ladder.sh: E15_LADDER_RUNGS names no rung" >&2
    exit 2
  }
  START=${CLIMB[0]}
  REQUESTED="${CLIMB[*]}"
else
  started=0
  for n in "${E15_LADDER[@]}"; do
    [ "$started" = 1 ] || [ "$n" = "$START" ] || continue
    started=1
    CLIMB+=("$n")
  done
fi

TAGP=""
if [ "$E15_HOST_PROFILE" = fresh-metal ] && [ -n "${E15_LADDER_TAG:-}" ]; then
  case "$E15_LADDER_TAG" in -* | *[!a-z0-9-]*)
    echo "ladder.sh: E15_LADDER_TAG '$E15_LADDER_TAG' is not [a-z0-9][a-z0-9-]*" >&2
    exit 2
    ;;
  esac
  TAGP=$E15_LADDER_TAG
fi

# E17b squeeze: the climb's own stop rule (see the header).
SQUEEZE=0
SQUEEZE_RULE=""
if e15_is_squeeze "$POINT"; then
  SQUEEZE=1
  e17b_lease_arm "$ARM" || {
    echo "ladder.sh: the squeeze climb is for a ship arm (its stop rule reads the worker's lease reclaims); sbx runs one rung.sh at the N the ship-300 climb stopped at" >&2
    exit 2
  }
  [[ "${E15_SQUEEZE_MEMMAX_MB:-}" =~ ^[1-9][0-9]*$ ]] && [ "$E15_SQUEEZE_MEMMAX_MB" -gt 8192 ] || {
    echo "ladder.sh: POINT squeeze needs E15_SQUEEZE_MEMMAX_MB (an integer above 8192: the e15.slice limit every rung runs under, its committed budget MemoryMax - 8192)" >&2
    exit 2
  }
  SQUEEZE_RULE=$E15_ROOT/src/e17/analysis/squeeze_rule.py
  [ -f "$SQUEEZE_RULE" ] || die "no $SQUEEZE_RULE (experiments/e17-lease/rig/sync.sh stages it)"
elif [ -n "${E15_SQUEEZE_MEMMAX_MB:-}" ]; then
  echo "ladder.sh: E15_SQUEEZE_MEMMAX_MB is for POINT squeeze or squeeze-256 only" >&2
  exit 2
fi

RUNG=${E15_RUNG:-$HERE/rung.sh}
WARMUP=${E15_WARMUP_S:-$(e15_default_warmup "$ARM")}
OUTDIR=$E15_RUNS/$POINT/$ARM
mkdir -p "$OUTDIR"
rungs_json=$OUTDIR/ladder-rungs.jsonl
: >"$rungs_json"
squeeze_json=$OUTDIR/ladder-squeeze.jsonl
[ "$SQUEEZE" = 0 ] || : >"$squeeze_json"
sq_stop=null sq_by=top_of_ladder

# rec_field FILE KEY: true/false for booleans and null, the value otherwise; 0 for a missing number.
rec_field() {
  python3 -c '
import json, sys
v = json.load(open(sys.argv[1])).get(sys.argv[2])
print("true" if v is True else "false" if (v is False or v is None) else json.dumps(v))' "$1" "$2"
}

# run_rung N TAG [ENV...]: one rung.sh call; returns its directory on stdout. A rung.sh failure
# is a rig error.
run_rung() {
  local n=$1 tag=$2
  shift 2
  [ -z "$TAGP" ] || tag=$TAGP${tag:+-$tag}
  env E15_TAG="$tag" "$@" bash "$RUNG" "$ARM" "$n" "$POINT" >&2 || die "rung.sh $ARM $n $POINT${tag:+ ($tag)} failed: rig error, ladder stopped"
  local d=$OUTDIR/N$n${tag:+-$tag}
  [ -f "$d/record.json" ] || die "no $d/record.json: rig error, ladder stopped"
  printf '%s\n' "$d"
}

# rig_check DIR: die on a record that is a rig error, not a host verdict.
rig_check() {
  local f=$1/record.json
  [ "$(rec_field "$f" aborted)" = true ] && die "$1: driver aborted (driver_exit != 0): rig error, ladder stopped"
  [ "$(rec_field "$f" time_origin_mismatch)" = true ] && die "$1: time_origin_mismatch: rig error, ladder stopped"
  [ "$(rec_field "$f" offset_join_misses)" != 0 ] && [ "$(rec_field "$f" offset_join_misses)" != false ] &&
    die "$1: offset_join_misses=$(rec_field "$f" offset_join_misses): the corpus did not supply the offsets class pace needs: rig error, ladder stopped"
  return 0
}
unseeded() { local v; v=$(rec_field "$1/record.json" unseeded_sessions); [ "$v" = false ] && v=0; printf '%s' "$v"; }

# KBASE: the caller's E15_K_MULT (E16 chain.sh sets 2; E15 never set it, so 1): the k2 re-run and
# the repeat double from it.
KBASE=${E15_K_MULT:-1}
[[ "$KBASE" =~ ^[1-9][0-9]*$ ]] || {
  echo "ladder.sh: E15_K_MULT must be a positive integer" >&2
  exit 2
}
n_max=null stopped=null n_max_abs=null stopped_abs=null
alive=1 alive_abs=1
for n in "${CLIMB[@]}"; do
  kmult=()
  rig_errors=()
  dir=$(run_rung "$n" "")
  rig_check "$dir"
  if [ "$(unseeded "$dir")" != 0 ]; then
    rig_errors+=("unseeded_sessions=$(unseeded "$dir")")
    log "N=$n: rig_error: $(unseeded "$dir") unseeded session(s); re-running once with K doubled"
    kmult=(E15_K_MULT=$((KBASE * 2)))
    dir=$(run_rung "$n" k2 "${kmult[@]}")
    rig_check "$dir"
    [ "$(unseeded "$dir")" = 0 ] || die "N=$n: still $(unseeded "$dir") unseeded session(s) with K doubled: rig error, ladder stopped"
  fi
  repeated=false
  if [ "$(rec_field "$dir/record.json" repeat_required)" = true ]; then
    log "N=$n: repeat_required (footprint drift > 10%); re-running once with warm-up $((WARMUP * 2)) s"
    # fresh-metal: the repeat's doubled warm-up cycles each slot through more sessions than K covers
    # (K uses the mean span; sessions start at a random call index), so its K is doubled from the
    # start; the pool size is never measured, so verdicts do not change. aws-prelim: as sealed.
    rk=$KBASE
    [ "${#kmult[@]}" -eq 0 ] || rk=${kmult[0]#E15_K_MULT=}
    [ "$E15_HOST_PROFILE" != fresh-metal ] || rk=$((rk * 2))
    dir=$(run_rung "$n" repeat E15_WARMUP_S=$((WARMUP * 2)) E15_K_MULT="$rk")
    rig_check "$dir"
    if [ "$(unseeded "$dir")" != 0 ] && [ "$E15_HOST_PROFILE" = fresh-metal ]; then
      # the sealed unseeded rule: once more with K doubled
      rig_errors+=("repeat unseeded_sessions=$(unseeded "$dir")")
      log "N=$n (repeat): rig_error: $(unseeded "$dir") unseeded session(s); re-running once with K doubled ($((rk * 2)))"
      dir=$(run_rung "$n" repeat-k2 E15_WARMUP_S=$((WARMUP * 2)) E15_K_MULT=$((rk * 2)))
      rig_check "$dir"
    fi
    [ "$(unseeded "$dir")" = 0 ] || die "N=$n (repeat): $(unseeded "$dir") unseeded session(s): rig error, ladder stopped"
    repeated=true
  fi
  holds=$(rec_field "$dir/record.json" holds)
  holds_abs=$(rec_field "$dir/record.json" holds_abs)
  cpace=$(rec_field "$dir/record.json" median_class_pace)
  [ "$cpace" = false ] && cpace=null # rec_field prints null/missing as false; 0.0 prints as 0.0
  [ -n "$cpace" ] || cpace=null
  errs=$(printf '"%s",' "${rig_errors[@]}")
  [ ${#rig_errors[@]} -gt 0 ] || errs=""
  printf '{"n":%s,"holds":%s,"holds_abs":%s,"repeated":%s,"median_class_pace":%s,"rig_errors":[%s],"dir":"%s"}\n' \
    "$n" "$holds" "$holds_abs" "$repeated" "$cpace" "${errs%,}" "$dir" >>"$rungs_json"
  if [ "$alive" = 1 ]; then
    if [ "$holds" = true ]; then n_max=$n; else
      stopped=$n
      alive=0
    fi
  fi
  if [ "$alive_abs" = 1 ]; then
    if [ "$holds_abs" = true ]; then n_max_abs=$n; else
      stopped_abs=$n
      alive_abs=0
    fi
  fi
  if [ "$SQUEEZE" = 1 ]; then
    python3 "$SQUEEZE_RULE" "$dir" >&2 || die "squeeze_rule.py failed on $dir: rig error, ladder stopped"
    read -r met mpm guard why < <(python3 - "$dir" <<'PY'
import json, sys
d = sys.argv[1]
r = json.load(open(d + "/squeeze-rule.json"))
p = json.load(open(d + "/params.json"))
guard = bool(p.get("memory_abort")) or int(p.get("oom_kills") or 0) > 0
print(json.dumps(r["met"]), json.dumps(r.get("min_per_minute")), json.dumps(guard), r.get("why") or "-")
PY
    )
    printf '{"n":%s,"met":%s,"min_per_minute":%s,"guard":%s,"dir":"%s"}\n' "$n" "$met" "$mpm" "$guard" "$dir" >>"$squeeze_json"
    if [ "$guard" = true ]; then
      sq_stop=$n sq_by=guard
      log "N=$n: squeeze: a memory-guard event (memory_abort or an OOM kill); the climb stops here"
      break
    fi
    [ "$met" != null ] || die "N=$n: squeeze stop rule undecidable at N=$n ($why): rig error, ladder stopped"
    if [ "$met" = true ]; then
      sq_stop=$n sq_by=reclaim_rate
      log "N=$n: squeeze: memory_reclaim in every minute of the window (min $mpm per minute); the climb stops here"
      break
    fi
    continue
  fi
  [ "$alive" = 1 ] || [ "$alive_abs" = 1 ] || break
done

SQ_ARGS=()
[ "$SQUEEZE" = 0 ] || SQ_ARGS=("$squeeze_json" "$E15_SQUEEZE_MEMMAX_MB" "$sq_stop" "$sq_by")
python3 - "$OUTDIR/ladder.json" "$rungs_json" "$POINT" "$ARM" "$START" "$n_max" "$stopped" "$n_max_abs" "$stopped_abs" "${E15_LADDER[*]}" "$REQUESTED" ${SQ_ARGS[@]+"${SQ_ARGS[@]}"} <<'PY'
import json, sys
out, rungs, point, arm, start, n_max, stopped, n_max_abs, stopped_abs, ladder, requested = sys.argv[1:12]
rows = [json.loads(l) for l in open(rungs) if l.strip()]
squeeze = None
if len(sys.argv) > 12:  # E17b squeeze (see the header)
    sq_rows, memmax, sq_stop, sq_by = sys.argv[12:16]
    squeeze = {"rule": "stop at the first rung with a memory-guard event (memory_abort, oom_kills > 0), else at the first "
                       "whose /stats leaseEnds.memory_reclaim rose by >= 1 in every whole minute of the window "
                       "(experiments/e17-lease/analysis/squeeze_rule.py); n_max above is condition 4's, not the stop",
               "memmax_mb": int(memmax), "stop_n": None if sq_stop == "null" else int(sq_stop), "stopped_by": sq_by,
               "rungs": [json.loads(l) for l in open(sq_rows) if l.strip()]}
overhead = n1_pace = None
try:
    bj = json.load(open(out.rsplit("/", 1)[0] + "/N1/baseline.json"))
    overhead, n1_pace = bj.get("overhead_ms"), bj.get("n1_median_pace")
except (OSError, ValueError):
    pass
num = lambda v: None if v == "null" else int(v)
json.dump({"point": point, "arm": arm, "start_n": int(start), "ladder": [int(x) for x in ladder.split()],
           "rungs_below_start_assumed_held": int(start) > 1,
           "rungs": rows, "n_max": num(n_max), "stopped_at": num(stopped),
           "n_max_abs": num(n_max_abs), "stopped_at_abs": num(stopped_abs),
           "abs_rule": "condition 4 as p95(class excess) <= B + 250 ms (B = the arm's N=1 within-class excess p95; excess = added latency minus the per-class N=1 probe median)",
           "n1_overhead_ms": overhead, "n1_median_pace": n1_pace,
           # E16: present only when E15_LADDER_RUNGS chose the rungs (fresh-metal)
           **({"rungs_requested": [int(x) for x in requested.split()]} if requested else {}),
           # E17b: present only at POINT squeeze
           **({"squeeze": squeeze} if squeeze else {})},
          open(out, "w"), indent=2)
PY
rm -f "$rungs_json"
[ "$SQUEEZE" = 0 ] || {
  rm -f "$squeeze_json"
  log "ladder $POINT/$ARM: squeeze stop at N=$sq_stop ($sq_by), E15_SQUEEZE_MEMMAX_MB=$E15_SQUEEZE_MEMMAX_MB"
}
log "ladder $POINT/$ARM: N_max=$n_max (stopped at $stopped), N_max_abs=$n_max_abs (stopped at $stopped_abs); $OUTDIR/ladder.json"
