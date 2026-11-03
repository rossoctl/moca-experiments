#!/usr/bin/env bash
# e15/rig/classprobe.sh POINT ARM -- the per-class N=1 probe (SPEC §8 condition 4, §10.1 step 3).
#
# analysis/make_probe.py writes one single-session corpus per class (20 calls drawn from that
# class's distribution in POINT's corpus, POINT's library per points.sh); this runs `rung.sh ARM 1 POINT` once per class,
# sequentially, with E15_CORPUS_OVERRIDE=<that corpus>, E15_START_ZERO=1, E15_TAG=probe-<class>,
# warm-up 0 and a window of 2 x the probe's planned span + 120 s and one session (E15_MAX_SESSIONS=1, so it never repeats), so each class is measured alone on an
# idle worker and all 20 calls are in the window. Prints the probe run directories (one per line)
# on stdout. A rung.sh failure is a rig error (exit 1); a probe whose calls fail is not -- the
# failures are in its calls.jsonl and baseline.py reports them. E15_RUNG overrides the rung command.
set -euo pipefail
E15_PROG=classprobe.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
# shellcheck source=points.sh
. "$HERE/points.sh"

usage() {
  echo "usage: classprobe.sh POINT ARM   (ARM: ${E15_ARMS[*]})" >&2
  exit 2
}
[ $# -eq 2 ] || usage
POINT=$1
ARM=$2
e15_is_arm "$ARM" || usage
e15_point "$POINT" || usage

RUNG=${E15_RUNG:-$HERE/rung.sh}
PROBES=$E15_RUNS/$POINT/$ARM/probe-corpora
rm -rf "$PROBES"
# The point's own corpus and library (points.sh): at mem512 the probe draws from the default corpus,
# and its rungs run at mem512 (rung.sh: the mem512 template and the driver's scan flags), so the
# per-class medians include the once-per-call data.bin scan.
python3 "$E15_SRC/analysis/make_probe.py" "$E15_CORPORA/$E15_P_CORPUS/corpus.jsonl" "$E15_P_LIBRARY" "$PROBES" \
  --per-class "${E15_PROBE_CALLS:-20}" --seed "${E15_PROBE_SEED:-1}" >&2 ||
  die "make_probe.py failed"
PER=${E15_PROBE_CALLS:-20}
python3 - "$PROBES" <<'PY' >&2
import json, os, sys
d, tot = sys.argv[1], 0
for cls in open(os.path.join(d, "classes.txt")).read().split():
    sp = json.load(open(os.path.join(d, cls, "corpus-report.json")))["span_ms"] / 1000.0
    tot += sp
    print("classprobe: %-12s planned span %7.1f s" % (cls, sp))
print("classprobe: total planned span %.1f s (windows are 2x + 120 s each)" % tot)
PY
while read -r cls; do
  [ -n "$cls" ] || continue
  window=$(python3 -c 'import json,math,sys; print(2 * int(math.ceil(json.load(open(sys.argv[1]))["span_ms"] / 1000.0)) + 120)' "$PROBES/$cls/corpus-report.json")
  env E15_CORPUS_OVERRIDE="$PROBES/$cls/corpus.jsonl" E15_START_ZERO=1 E15_MAX_SESSIONS=1 E15_TAG="probe-$cls" \
    E15_WARMUP_S=0 E15_WINDOW_S="$window" E15_SPREAD_S=0 bash "$RUNG" "$ARM" 1 "$POINT" >&2 ||
    die "rung.sh $ARM 1 $POINT (probe $cls) failed: rig error"
  dir=$E15_RUNS/$POINT/$ARM/N1-probe-$cls
  got=$(python3 -c 'import json,sys
n = 0
for line in open(sys.argv[1]):
    if line.strip() and json.loads(line).get("in_window"):
        n += 1
print(n)' "$dir/calls.jsonl" 2>/dev/null || echo 0)
  [ "$got" = "$PER" ] || die "probe $cls: $got in-window calls in $dir/calls.jsonl, expected exactly $PER"
  echo "$dir"
done <"$PROBES/classes.txt"
