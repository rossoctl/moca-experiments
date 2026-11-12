#!/usr/bin/env bash
# experiments/e17-lease/rig/gen_corpora.sh (laptop): generate E17's two pycache corpora with experiments/e17-lease/extract/pycache_corpus.py,
# where experiments/e17-lease/rig/sync.sh stages them from:
#   $E17_CORPORA/pycache/       --duty 0.095   (points pycache, pycache-d64, pycache-d768)
#   $E17_CORPORA/pycache-low/   --duty 0.015   (point pycache-low)
# each with --sessions 400 --seed 1 --min-turns 4 and the gaps of the E15 default corpus
# (E17_GAPS, default /tmp/kagenti/e16-corpus-default/corpus.jsonl, the rig's own by sha256).
# E17_CORPORA defaults to /tmp/kagenti/e17-corpora; E17_PYTHON (default python3) runs the generator.
#
#   bash experiments/e17-lease/rig/gen_corpora.sh [--durations-from CAL.json]
#
# --durations-from CAL.json: a JSON object, each of the five classes (py_analyze, py_test, py_import,
# py_grep, py_short; spec v0.4 §4.3) to its measured N=1 median run_ms (the calibration, PLAN Task 5
# step 4). The corpora then carry those as dur_ms/work_ms, not the 15000/60000/2000/2200/300
# placeholders (ruling: after calibration they must),
# and each corpus-report.json records them (durations_ms, durations_from). Without it the
# placeholders stay, and this script says so. Each corpus directory is replaced whole: written to
# a temporary sibling first, then moved over the old one.
set -euo pipefail
W="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PC=${E17_CORPORA:-/tmp/kagenti/e17-corpora}
GAPS=${E17_GAPS:-/tmp/kagenti/e16-corpus-default/corpus.jsonl}
PY=${E17_PYTHON:-python3}
cal=()
case "${1:-}" in
"") ;;
--durations-from)
  if [ $# -ne 2 ] || [ ! -f "$2" ]; then
    echo "gen_corpora.sh: --durations-from needs an existing CAL.json" >&2
    exit 2
  fi
  cal=(--durations-from "$2")
  ;;
*)
  echo "usage: gen_corpora.sh [--durations-from CAL.json]" >&2
  exit 2
  ;;
esac
[ -f "$GAPS" ] || {
  echo "gen_corpora.sh: no gap source $GAPS (E17_GAPS)" >&2
  exit 1
}
mkdir -p "$PC"
for spec in pycache:0.095 pycache-low:0.015; do
  p=${spec%%:*}
  duty=${spec#*:}
  tmp=$(mktemp -d "$PC/.$p.XXXXXX")
  if ! "$PY" "$W/experiments/e17-lease/extract/pycache_corpus.py" --gaps-from "$GAPS" --duty "$duty" --sessions 400 \
    --seed 1 --min-turns 4 "${cal[@]}" --out "$tmp"; then
    rm -rf -- "$tmp"
    echo "gen_corpora.sh: pycache_corpus.py failed for $p" >&2
    exit 1
  fi
  # Only the corpus directory itself is replaced: $PC/pycache or $PC/pycache-low, nothing above.
  rm -rf -- "${PC:?}/$p"
  mv "$tmp" "$PC/$p"
  "$PY" -c 'import json,sys; r=json.load(open(sys.argv[1])); print("%s: duty %.4f (target %s), %d sessions, durations_ms %s, corpus_sha256 %s" % (sys.argv[2], r["duty_achieved"]["mean"], r["duty_target"], r["sessions"], r["durations_ms"], r["corpus_sha256"]))' \
    "$PC/$p/corpus-report.json" "$p"
done
[ ${#cal[@]} -gt 0 ] || echo "gen_corpora.sh: note: placeholder durations (no --durations-from); re-run with the calibration's before the measured rungs" >&2
