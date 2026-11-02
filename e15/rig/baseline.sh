#!/usr/bin/env bash
# e15/rig/baseline.sh POINT ARM -- the pooled N=1 baseline (SPEC §8 condition 4).
#
# One short N=1 rung gives a noisy p95. This runs `rung.sh ARM 1 POINT` with E15_SEED=1,2,3,...
# and E15_TAG=s1,s2,... (at most E15_BASELINE_MAX_SEEDS=30) until it has at least 3 EVALUABLE runs
# and at least 30 pooled in-window ok calls and every COVERED class (>= 1% of the point's corpus
# calls) has >= 5 pooled calls, then analysis/baseline.py pools the evaluable runs
# into /srv/e15/runs/POINT/ARM/N1/baseline.json, which rung.sh reads for N > 1.
#
# A run is NOT EVALUABLE (skipped, recorded, not a failure) when its record says
# reason=empty_window -- the single session had no window call to judge -- and it saw no failed
# call, no refusal, no abort and no time-origin mismatch. Every arm draws the same seed sequence,
# so the arms are baselined on the same sessions. Dies (exit 1, no baseline.json) on a rig error,
# on any evaluable run that does not hold, or after 30 seeds without 3 runs and 30 calls. At the
# cap, covered classes still under 5 calls are recorded as "undercovered" (not a failure).
# Other environment passes through to rung.sh; E15_RUNG overrides the rung command (tests).
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
MAX_SEEDS=${E15_BASELINE_MAX_SEEDS:-30}
MIN_RUNS=3
MIN_CALLS=30
# covered classes: >= 1% of the calls in the point's corpus.jsonl (the report has no per-class counts)
COVERED=$(python3 -c '
import json, sys
n, by = 0, {}
for line in open(sys.argv[1]):
    if line.strip():
        for c in json.loads(line)["calls"]:
            n += 1
            by[c["class"]] = by.get(c["class"], 0) + 1
print(*sorted(k for k, v in by.items() if v * 100 >= n))' "$E15_CORPORA/$POINT/corpus.jsonl") ||
  die "cannot compute covered classes from $E15_CORPORA/$POINT/corpus.jsonl"
dirs=()
seeds=()
skipped=()
calls=0
s=0
# under: covered classes with < MIN_CLASS pooled calls so far (space separated)
under=$COVERED
while [ "${#dirs[@]}" -lt "$MIN_RUNS" ] || [ "$calls" -lt "$MIN_CALLS" ] || [ -n "$under" ]; do
  if [ "$s" -ge "$MAX_SEEDS" ]; then
    if [ "${#dirs[@]}" -ge "$MIN_RUNS" ] && [ "$calls" -ge "$MIN_CALLS" ]; then
      log "baseline $ARM: cap of $MAX_SEEDS seeds; undercovered classes: $under"
      break
    fi
    die "$MAX_SEEDS seeds gave ${#dirs[@]} evaluable runs and $calls pooled calls (need $MIN_RUNS and $MIN_CALLS): no baseline"
  fi
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
  under=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import holds as H; from record import read_jsonl
import os
cov = sys.argv[2].split()
cnt = {}
for d in sys.argv[3:]:
    for c in H.window_ok_calls(read_jsonl(os.path.join(d, "calls.jsonl"))):
        cnt[c.get("class")] = cnt.get(c.get("class"), 0) + 1
print(*[k for k in cov if cnt.get(k, 0) < H.MIN_CLASS_CALLS])' "$E15_SRC/analysis" "$COVERED" "${dirs[@]}")
done
p95=$(E15_BASELINE_COVERED="$COVERED" E15_BASELINE_SEEDS="${seeds[*]}" E15_BASELINE_SKIPPED="${skipped[*]}" \
  python3 "$E15_SRC/analysis/baseline.py" "$OUT" "${dirs[@]}") || die "baseline.py failed for ${dirs[*]}"
log "baseline $ARM point=$POINT: p95 added ${p95} ms over ${#dirs[@]} evaluable N=1 runs, $calls calls (seeds ${seeds[*]}; skipped ${skipped[*]:-none}) ($OUT)"
