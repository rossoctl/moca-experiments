#!/usr/bin/env bash
# e15/rig/baseline.sh POINT ARM -- the pooled N=1 baseline (SPEC §8 condition 4).
#
# One short N=1 rung gives a noisy p95. This runs `rung.sh ARM 1 POINT` three times, with
# E15_SEED=1,2,3 and E15_TAG=s1,s2,s3, then analysis/baseline.py pools the three runs' in-window ok
# calls into /srv/e15/runs/POINT/ARM/N1/baseline.json, which rung.sh reads for N > 1 before any
# N1 record.json. Dies (exit 1, no baseline.json) if a rung fails or any of the three does not
# hold. Other environment passes through to rung.sh; E15_RUNG overrides the rung command (tests).
set -euo pipefail
E15_PROG=baseline.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

usage() {
  echo "usage: baseline.sh POINT ARM   (ARM: ${E15_ARMS[*]})" >&2
  exit 2
}
[ $# -eq 2 ] || usage
POINT=$1
ARM=$2
e15_is_arm "$ARM" || {
  echo "baseline.sh: unknown ARM '$ARM'" >&2
  usage
}
e15_point_arms "$POINT" >/dev/null || {
  echo "baseline.sh: unknown POINT '$POINT'" >&2
  usage
}

RUNG=${E15_RUNG:-$HERE/rung.sh}
OUTDIR=$E15_RUNS/$POINT/$ARM
OUT=$OUTDIR/N1/baseline.json
mkdir -p "$OUTDIR/N1"
rm -f "$OUT"
dirs=()
for s in 1 2 3; do
  d=$OUTDIR/N1-s$s
  env E15_SEED=$s E15_TAG=s$s bash "$RUNG" "$ARM" 1 "$POINT" >&2 ||
    die "rung.sh $ARM 1 $POINT (seed $s) failed: rig error, no baseline"
  [ -f "$d/record.json" ] || die "no $d/record.json: rig error, no baseline"
  holds=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("holds") is True)' "$d/record.json")
  [ "$holds" = True ] || die "N=1 run $d does not hold: no baseline from a host that cannot hold one session"
  dirs+=("$d")
done
p95=$(python3 "$E15_SRC/analysis/baseline.py" "$OUT" "${dirs[@]}") || die "baseline.py failed for ${dirs[*]}"
log "baseline $ARM point=$POINT: p95 added ${p95} ms over 3 seeded N=1 runs ($OUT)"
