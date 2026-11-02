#!/usr/bin/env bash
# e15/rig/ladder.sh POINT ARM [START_N] -- run rung.sh up the ladder (SPEC §8, §10.2, §10.3).
#
# Ladder: 1 8 16 24 32 40 48 56 64 80 96 128, from START_N (default 1; it must be on the ladder).
# Each rung's record.json decides:
#   repeat_required=true  -> the rung is re-run ONCE with the warm-up doubled (E15_TAG=repeat);
#                            the repeat's record is the one that counts
#   holds=true            -> next rung
#   holds=false           -> stop; this rung is the arm's first failure
# N_max = the largest N that held with every rung before it (from START_N) holding too; null when
# the first rung failed. A rung below START_N is assumed held (SPEC §10.3: other points start two
# steps below the default N_max), and ladder.json says so.
#
# Writes /srv/e15/runs/POINT/ARM/ladder.json:
#   {point, arm, start_n, ladder, rungs: [{n, holds, repeated, dir}], n_max, stopped_at}
# Environment passes through to rung.sh (E15_WARMUP_S, E15_WINDOW_S, ...).
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

WARMUP=${E15_WARMUP_S:-600}
OUTDIR=$E15_RUNS/$POINT/$ARM
mkdir -p "$OUTDIR"
rungs_json=$OUTDIR/ladder-rungs.jsonl
: >"$rungs_json"

rec_field() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print("true" if v is True else "false" if v in (False, None) else v)' "$1" "$2"; }

n_max=null
stopped=null
started=0
for n in "${E15_LADDER[@]}"; do
  if [ "$started" = 0 ]; then
    [ "$n" = "$START" ] || continue
    started=1
  fi
  dir=$OUTDIR/N$n
  E15_TAG="" bash "$HERE/rung.sh" "$ARM" "$n" "$POINT" || die "rung.sh $ARM $n $POINT failed (rig error)"
  repeated=false
  if [ "$(rec_field "$dir/record.json" repeat_required)" = true ]; then
    log "N=$n: repeat_required (footprint drift > 10%); re-running once with warm-up $((WARMUP * 2)) s"
    E15_TAG=repeat E15_WARMUP_S=$((WARMUP * 2)) bash "$HERE/rung.sh" "$ARM" "$n" "$POINT" ||
      die "rung.sh $ARM $n $POINT (repeat) failed (rig error)"
    dir=$OUTDIR/N$n-repeat
    repeated=true
  fi
  holds=$(rec_field "$dir/record.json" holds)
  printf '{"n":%s,"holds":%s,"repeated":%s,"dir":"%s"}\n' "$n" "$holds" "$repeated" "$dir" >>"$rungs_json"
  if [ "$holds" = true ]; then
    n_max=$n
  else
    stopped=$n
    break
  fi
done

python3 - "$OUTDIR/ladder.json" "$rungs_json" "$POINT" "$ARM" "$START" "$n_max" "$stopped" "${E15_LADDER[*]}" <<'PY'
import json, sys
out, rungs, point, arm, start, n_max, stopped, ladder = sys.argv[1:]
rows = [json.loads(l) for l in open(rungs) if l.strip()]
num = lambda v: None if v == "null" else int(v)
json.dump({"point": point, "arm": arm, "start_n": int(start), "ladder": [int(x) for x in ladder.split()],
           "rungs_below_start_assumed_held": int(start) > 1,
           "rungs": rows, "n_max": num(n_max), "stopped_at": num(stopped)},
          open(out, "w"), indent=2)
PY
rm -f "$rungs_json"
log "ladder $POINT/$ARM: N_max=$n_max (stopped at ${stopped}); $OUTDIR/ladder.json"
