#!/usr/bin/env bash
# e15/rig/fine.sh POINT ARM N... -- SUPPLEMENTARY rungs, outside the sealed procedure.
#
# User decision after the default ladders tied at n_max 8: extra rungs between ladder steps (e.g.
# 10 12 14). They never touch ladder.json, n_max/n_max_abs or a prediction verdict. Each N runs
# rung.sh exactly as a sealed rung (same baseline, warm-up, window, relay restart, attach check),
# with E15_TAG=fine, into /srv/e15/runs/POINT/ARM/N<N>-fine. Ascending, in the order given.
# Per rung, the sealed ladder's rules (ladder.sh):
#   rig errors die (aborted, time_origin_mismatch, offset_join_misses > 0, a rung.sh failure)
#   unseeded_sessions > 0  -> re-run once with K doubled (tag fine-k2); die if still unseeded
#   repeat_required        -> re-run once with the warm-up doubled (tag fine-repeat); that counts
#   E15_FINE_REPEAT_CHECK  -> optional command run with the counted rung dir (SPEC §12 shared-host
#                             check); exit 0 means "repeat": re-run once (tag fine-shared), that counts
# n_fine: the largest N holding with every earlier N holding; n_fine_abs likewise for holds_abs.
# Stops at the first N where both have failed. Writes /srv/e15/runs/POINT/ARM/fine.json.
# E15_RUNG overrides the rung command (tests only).
set -euo pipefail
E15_PROG=fine.sh
unset E15_MAX_SESSIONS E15_START_ZERO
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
# shellcheck source=points.sh
. "$HERE/points.sh"

usage() {
  echo "usage: fine.sh POINT ARM N...   (ARM: ${E15_ARMS[*]}; N ascending, > 1)" >&2
  exit 2
}
[ $# -ge 3 ] || usage
POINT=$1
ARM=$2
shift 2
e15_is_arm "$ARM" || usage
e15_point_arms "$POINT" >/dev/null || usage
prev=1
for n in "$@"; do
  [[ "$n" =~ ^[1-9][0-9]*$ ]] && [ "$n" -gt "$prev" ] || usage
  prev=$n
done

RUNG=${E15_RUNG:-$HERE/rung.sh}
WARMUP=${E15_WARMUP_S:-600}
OUTDIR=$E15_RUNS/$POINT/$ARM
mkdir -p "$OUTDIR"
rows=$OUTDIR/fine-rungs.jsonl
: >"$rows"

rec_field() {
  python3 -c '
import json, sys
v = json.load(open(sys.argv[1])).get(sys.argv[2])
print("true" if v is True else "false" if (v is False or v is None) else json.dumps(v))' "$1" "$2"
}
run_rung() {
  local n=$1 tag=$2
  shift 2
  env E15_TAG="$tag" "$@" bash "$RUNG" "$ARM" "$n" "$POINT" >&2 || die "rung.sh $ARM $n $POINT ($tag) failed: rig error"
  [ -f "$OUTDIR/N$n-$tag/record.json" ] || die "no $OUTDIR/N$n-$tag/record.json: rig error"
  printf '%s\n' "$OUTDIR/N$n-$tag"
}
rig_check() {
  local f=$1/record.json
  [ "$(rec_field "$f" aborted)" = true ] && die "$1: driver aborted: rig error"
  [ "$(rec_field "$f" time_origin_mismatch)" = true ] && die "$1: time_origin_mismatch: rig error"
  [ "$(rec_field "$f" offset_join_misses)" != 0 ] && [ "$(rec_field "$f" offset_join_misses)" != false ] &&
    die "$1: offset_join_misses: rig error"
  return 0
}
unseeded() { local v; v=$(rec_field "$1/record.json" unseeded_sessions); [ "$v" = false ] && v=0; printf '%s' "$v"; }

n_fine=null n_fine_abs=null stopped=null stopped_abs=null alive=1 alive_abs=1
for n in "$@"; do
  kmult=()
  notes=()
  dir=$(run_rung "$n" fine)
  rig_check "$dir"
  if [ "$(unseeded "$dir")" != 0 ]; then
    notes+=("k2")
    kmult=(E15_K_MULT=2)
    dir=$(run_rung "$n" fine-k2 "${kmult[@]}")
    rig_check "$dir"
    [ "$(unseeded "$dir")" = 0 ] || die "N=$n: still unseeded with K doubled: rig error"
  fi
  if [ "$(rec_field "$dir/record.json" repeat_required)" = true ]; then
    notes+=("repeat")
    dir=$(run_rung "$n" fine-repeat E15_WARMUP_S=$((WARMUP * 2)) "${kmult[@]}")
    rig_check "$dir"
  fi
  if [ -n "${E15_FINE_REPEAT_CHECK:-}" ] && $E15_FINE_REPEAT_CHECK "$dir" >&2; then
    notes+=("shared-host")
    dir=$(run_rung "$n" fine-shared "${kmult[@]}")
    rig_check "$dir"
  fi
  holds=$(rec_field "$dir/record.json" holds)
  holds_abs=$(rec_field "$dir/record.json" holds_abs)
  nj=$(printf '"%s",' "${notes[@]}")
  [ ${#notes[@]} -gt 0 ] || nj=""
  printf '{"n":%s,"holds":%s,"holds_abs":%s,"reruns":[%s],"dir":"%s"}\n' "$n" "$holds" "$holds_abs" "${nj%,}" "$dir" >>"$rows"
  if [ "$alive" = 1 ]; then
    if [ "$holds" = true ]; then n_fine=$n; else stopped=$n; alive=0; fi
  fi
  if [ "$alive_abs" = 1 ]; then
    if [ "$holds_abs" = true ]; then n_fine_abs=$n; else stopped_abs=$n; alive_abs=0; fi
  fi
  [ "$alive" = 1 ] || [ "$alive_abs" = 1 ] || break
done

python3 - "$OUTDIR/fine.json" "$rows" "$POINT" "$ARM" "$n_fine" "$stopped" "$n_fine_abs" "$stopped_abs" "$*" <<'PY'
import json, sys
out, rows, point, arm, nf, st, nfa, sta, steps = sys.argv[1:]
num = lambda v: None if v == "null" else int(v)
json.dump({"supplementary": True,
           "note": "NOT SEALED: supplementary rungs outside SPEC §10.2's ladder; they never change ladder.json or any prediction verdict",
           "point": point, "arm": arm, "steps": [int(x) for x in steps.split()],
           "rungs": [json.loads(l) for l in open(rows) if l.strip()],
           "n_fine": num(nf), "stopped_at": num(st), "n_fine_abs": num(nfa), "stopped_at_abs": num(sta)},
          open(out, "w"), indent=2)
PY
rm -f "$rows"
log "fine $POINT/$ARM: n_fine=$n_fine (stopped at $stopped), n_fine_abs=$n_fine_abs (stopped at $stopped_abs); $OUTDIR/fine.json"
