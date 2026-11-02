#!/usr/bin/env bash
# e15/rig/classprobe.sh POINT ARM -- the per-class N=1 probe (SPEC §8 condition 4, §10.1 step 3).
#
# analysis/make_probe.py writes one single-session corpus per class (20 calls drawn from that
# class's distribution in POINT's corpus); this runs `rung.sh ARM 1 POINT` once per class,
# sequentially, with E15_CORPUS_OVERRIDE=<that corpus>, E15_START_ZERO=1, E15_TAG=probe-<class>,
# warm-up 0 and a window of the probe's planned span + 60 s, so each class is measured alone on an
# idle worker and all 20 calls are in the window. Prints the probe run directories (one per line)
# on stdout. A rung.sh failure is a rig error (exit 1); a probe whose calls fail is not -- the
# failures are in its calls.jsonl and baseline.py reports them. E15_RUNG overrides the rung command.
set -euo pipefail
E15_PROG=classprobe.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

usage() {
  echo "usage: classprobe.sh POINT ARM   (ARM: ${E15_ARMS[*]})" >&2
  exit 2
}
[ $# -eq 2 ] || usage
POINT=$1
ARM=$2
e15_is_arm "$ARM" || usage
e15_point_arms "$POINT" >/dev/null || usage

RUNG=${E15_RUNG:-$HERE/rung.sh}
PROBES=$E15_RUNS/$POINT/$ARM/probe-corpora
rm -rf "$PROBES"
python3 "$E15_SRC/analysis/make_probe.py" "$E15_CORPORA/$POINT/corpus.jsonl" "$E15_SRC/commands/library.json" "$PROBES" \
  --per-class "${E15_PROBE_CALLS:-20}" --seed "${E15_PROBE_SEED:-1}" >&2 ||
  die "make_probe.py failed"
while read -r cls; do
  [ -n "$cls" ] || continue
  window=$(python3 -c 'import json,math,sys; print(int(math.ceil(json.load(open(sys.argv[1]))["span_ms"] / 1000.0)) + 60)' "$PROBES/$cls/corpus-report.json")
  env E15_CORPUS_OVERRIDE="$PROBES/$cls/corpus.jsonl" E15_START_ZERO=1 E15_TAG="probe-$cls" \
    E15_WARMUP_S=0 E15_WINDOW_S="$window" E15_SPREAD_S=0 bash "$RUNG" "$ARM" 1 "$POINT" >&2 ||
    die "rung.sh $ARM 1 $POINT (probe $cls) failed: rig error"
  echo "$E15_RUNS/$POINT/$ARM/N1-probe-$cls"
done <"$PROBES/classes.txt"
