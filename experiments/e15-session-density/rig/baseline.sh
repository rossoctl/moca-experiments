#!/usr/bin/env bash
# experiments/e15-session-density/rig/baseline.sh POINT ARM -- the pooled N=1 baseline (SPEC §8 condition 4).
#
# Two parts. (1) Seeded session runs: `rung.sh ARM 1 POINT` with E15_SEED=1,2,3,... and
# E15_TAG=s1,s2,... (at most E15_BASELINE_MAX_SEEDS=12) until there are at least 3 EVALUABLE runs
# and at least 30 pooled in-window ok calls: a pace sanity check and evidence (baseline_p95_ms).
# (2) classprobe.sh: each command class alone, 20 calls, on an idle worker. analysis/baseline.py
# writes /srv/e15/runs/POINT/ARM/N1/baseline.json from both; the class medians and the excess p95
# (B) that condition 4 uses come from the probe only, which rung.sh reads for N > 1.
#
# A seeded run is NOT EVALUABLE (skipped, recorded, not a failure) when its record says
# reason=empty_window -- the single session had no window call to judge -- and it saw no failed
# call, no refusal, no abort and no time-origin mismatch. Every arm draws the same seed sequence,
# so the arms are baselined on the same sessions. Dies (exit 1, no baseline.json) on a rig error,
# on any evaluable run that does not hold, or after 12 seeds without enough.
# Other environment passes through to rung.sh; E15_RUNG overrides the rung command (tests).
set -euo pipefail
E15_PROG=baseline.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
# shellcheck source=points.sh
. "$HERE/points.sh"

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
e15_point "$POINT" || {
  echo "baseline.sh: unknown POINT '$POINT'" >&2
  usage
}

RUNG=${E15_RUNG:-$HERE/rung.sh}
OUTDIR=$E15_RUNS/$POINT/$ARM
OUT=$OUTDIR/N1/baseline.json
mkdir -p "$OUTDIR/N1"
rm -f "$OUT"
MAX_SEEDS=${E15_BASELINE_MAX_SEEDS:-12}
MIN_RUNS=3
MIN_CALLS=30
dirs=()
seeds=()
skipped=()
calls=0
s=0
while [ "${#dirs[@]}" -lt "$MIN_RUNS" ] || [ "$calls" -lt "$MIN_CALLS" ]; do
  [ "$s" -lt "$MAX_SEEDS" ] ||
    die "$MAX_SEEDS seeds gave ${#dirs[@]} evaluable runs and $calls pooled calls (need $MIN_RUNS and $MIN_CALLS): no baseline"
  s=$((s + 1))
  d=$OUTDIR/N1-s$s
  env E15_SEED=$s E15_TAG=s$s bash "$RUNG" "$ARM" 1 "$POINT" >&2 ||
    die "rung.sh $ARM 1 $POINT (seed $s) failed: rig error, no baseline"
  [ -f "$d/record.json" ] || die "no $d/record.json: rig error, no baseline"
  verdict=$(python3 -c '
import json, sys
r = json.load(open(sys.argv[1]))
clean = not r.get("failed_calls") and not r.get("refusals") and not r.get("aborted") \
    and not r.get("time_origin_mismatch")
if r.get("reason") == "empty_window" and clean:
    print("skip")
elif r.get("holds") is True:
    print("ok")
else:
    print("fail")' "$d/record.json")
  case "$verdict" in
  skip)
    log "baseline $ARM: seed $s (N1-s$s) not evaluable (empty_window); skipped"
    skipped+=("$s:s$s:empty_window")
    continue
    ;;
  ok) ;;
  *) die "N=1 run $d does not hold: no baseline from a host that cannot hold one session" ;;
  esac
  dirs+=("$d")
  seeds+=("$s")
  n=$(python3 -c 'import os,sys; sys.path.insert(0, sys.argv[1]); import holds as H; from record import read_jsonl
print(len(H.window_added_ms(read_jsonl(os.path.join(sys.argv[2], "calls.jsonl")))))' "$E15_SRC/analysis" "$d")
  calls=$((calls + n))
done
probe_out=$(bash "${E15_CLASSPROBE:-$HERE/classprobe.sh}" "$POINT" "$ARM") ||
  die "classprobe.sh $POINT $ARM failed: rig error, no baseline"
probes=()
while IFS= read -r line; do
  [ -z "$line" ] || probes+=("$line")
done <<<"$probe_out"
[ "${#probes[@]}" -gt 0 ] || die "classprobe.sh $POINT $ARM produced no probe runs"
p95=$(E15_BASELINE_CORPUS="$E15_CORPORA/$E15_P_CORPUS/corpus.jsonl" E15_BASELINE_ARM="$ARM" E15_BASELINE_SEEDS="${seeds[*]}" E15_BASELINE_SKIPPED="${skipped[*]}" \
  python3 "$E15_SRC/analysis/baseline.py" "$OUT" "${dirs[@]}" --probe "${probes[@]}") || die "baseline.py failed for ${dirs[*]}"
log "baseline $ARM probe_failed: $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["probe_failed"] or "none")' "$OUT")"
log "baseline $ARM point=$POINT: p95 added ${p95} ms over ${#dirs[@]} evaluable N=1 runs, $calls calls, ${#probes[@]} class probes (seeds ${seeds[*]}; skipped ${skipped[*]:-none}) ($OUT)"
