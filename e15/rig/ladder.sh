#!/usr/bin/env bash
# e15/rig/ladder.sh POINT ARM [START_N] -- run rung.sh up the ladder (SPEC §8, §10.2, §10.3).
#
# Ladder: 1 8 16 24 32 40 48 56 64 80 96 128, from START_N (default 1; it must be on the ladder).
# Each rung's record.json decides, in order:
#   rig errors (never a host verdict -- the ladder DIES, it records no stopped_at):
#     aborted=true, time_origin_mismatch=true, a rung.sh failure (incl. a missing N=1 baseline)
#     unseeded_sessions>0   -> rig_error: re-run once with K doubled (E15_K_MULT=2, tag k2);
#                              die if still unseeded
#   repeat_required=true  -> the rung is re-run ONCE with the warm-up doubled (tag repeat);
#                            the repeat's record is the one that counts
#   two verdicts per rung (record.json): holds (SPEC §8, condition 4 = 2x the N=1 p95) and
#   holds_abs (condition 4 = N=1 p95 + 250 ms). Each has its own ladder: n_max (primary) is the
#   largest N holding with every rung before it holding; n_max_abs likewise for holds_abs. The
#   ladder climbs while EITHER is still unbroken and stops at the first rung where both are. A rung below START_N is assumed held (SPEC §10.3: other points start two
# steps below the default N_max), and ladder.json says so.
#
# Writes /srv/e15/runs/POINT/ARM/ladder.json:
#   {point, arm, start_n, ladder, rungs: [{n, holds, holds_abs, repeated, rig_errors, dir}],
#    n_max, stopped_at, n_max_abs, stopped_at_abs}
# Environment passes through to rung.sh (E15_WARMUP_S, E15_WINDOW_S, ...). E15_RUNG overrides the
# rung command (tests only).
set -euo pipefail
E15_PROG=ladder.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

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

RUNG=${E15_RUNG:-$HERE/rung.sh}
WARMUP=${E15_WARMUP_S:-600}
OUTDIR=$E15_RUNS/$POINT/$ARM
mkdir -p "$OUTDIR"
rungs_json=$OUTDIR/ladder-rungs.jsonl
: >"$rungs_json"

# rec_field FILE KEY: true/false for booleans and null, the value otherwise; 0 for a missing number.
rec_field() {
  python3 -c '
import json, sys
v = json.load(open(sys.argv[1])).get(sys.argv[2])
print("true" if v is True else "false" if v in (False, None) else v)' "$1" "$2"
}

# run_rung N TAG [ENV...]: one rung.sh call; returns its directory on stdout. A rung.sh failure
# is a rig error.
run_rung() {
  local n=$1 tag=$2
  shift 2
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
  return 0
}
unseeded() { local v; v=$(rec_field "$1/record.json" unseeded_sessions); [ "$v" = false ] && v=0; printf '%s' "$v"; }

n_max=null stopped=null n_max_abs=null stopped_abs=null
alive=1 alive_abs=1
started=0
for n in "${E15_LADDER[@]}"; do
  if [ "$started" = 0 ]; then
    [ "$n" = "$START" ] || continue
    started=1
  fi
  kmult=()
  rig_errors=()
  dir=$(run_rung "$n" "")
  rig_check "$dir"
  if [ "$(unseeded "$dir")" != 0 ]; then
    rig_errors+=("unseeded_sessions=$(unseeded "$dir")")
    log "N=$n: rig_error: $(unseeded "$dir") unseeded session(s); re-running once with K doubled"
    kmult=(E15_K_MULT=2)
    dir=$(run_rung "$n" k2 "${kmult[@]}")
    rig_check "$dir"
    [ "$(unseeded "$dir")" = 0 ] || die "N=$n: still $(unseeded "$dir") unseeded session(s) with K doubled: rig error, ladder stopped"
  fi
  repeated=false
  if [ "$(rec_field "$dir/record.json" repeat_required)" = true ]; then
    log "N=$n: repeat_required (footprint drift > 10%); re-running once with warm-up $((WARMUP * 2)) s"
    dir=$(run_rung "$n" repeat E15_WARMUP_S=$((WARMUP * 2)) "${kmult[@]}")
    rig_check "$dir"
    [ "$(unseeded "$dir")" = 0 ] || die "N=$n (repeat): $(unseeded "$dir") unseeded session(s): rig error, ladder stopped"
    repeated=true
  fi
  holds=$(rec_field "$dir/record.json" holds)
  holds_abs=$(rec_field "$dir/record.json" holds_abs)
  errs=$(printf '"%s",' "${rig_errors[@]}")
  [ ${#rig_errors[@]} -gt 0 ] || errs=""
  printf '{"n":%s,"holds":%s,"holds_abs":%s,"repeated":%s,"rig_errors":[%s],"dir":"%s"}\n' \
    "$n" "$holds" "$holds_abs" "$repeated" "${errs%,}" "$dir" >>"$rungs_json"
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
  [ "$alive" = 1 ] || [ "$alive_abs" = 1 ] || break
done

python3 - "$OUTDIR/ladder.json" "$rungs_json" "$POINT" "$ARM" "$START" "$n_max" "$stopped" "$n_max_abs" "$stopped_abs" "${E15_LADDER[*]}" <<'PY'
import json, sys
out, rungs, point, arm, start, n_max, stopped, n_max_abs, stopped_abs, ladder = sys.argv[1:]
rows = [json.loads(l) for l in open(rungs) if l.strip()]
num = lambda v: None if v == "null" else int(v)
json.dump({"point": point, "arm": arm, "start_n": int(start), "ladder": [int(x) for x in ladder.split()],
           "rungs_below_start_assumed_held": int(start) > 1,
           "rungs": rows, "n_max": num(n_max), "stopped_at": num(stopped),
           "n_max_abs": num(n_max_abs), "stopped_at_abs": num(stopped_abs),
           "abs_rule": "condition 4 as p95_added <= baseline_p95_ms + 250 ms"},
          open(out, "w"), indent=2)
PY
rm -f "$rungs_json"
log "ladder $POINT/$ARM: N_max=$n_max (stopped at $stopped), N_max_abs=$n_max_abs (stopped at $stopped_abs); $OUTDIR/ladder.json"
