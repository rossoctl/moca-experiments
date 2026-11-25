#!/usr/bin/env bash
# experiments/e17-lease/rig/gen_corpora.sh (laptop): generate E17's two pycache corpora with experiments/e17-lease/extract/pycache_corpus.py,
# where experiments/e17-lease/rig/sync.sh stages them from:
#   $E17_CORPORA/pycache/       --duty 0.095   (points pycache, pycache-d64, pycache-d768)
#   $E17_CORPORA/pycache-low/   --duty 0.015   (point pycache-low)
# each with --sessions 400 --seed 1 --min-turns 4 and the gaps of the E15 default corpus
# (E17_GAPS, default /tmp/kagenti/e16-corpus-default/corpus.jsonl, the rig's own by sha256).
# E17_CORPORA defaults to /tmp/kagenti/e17-corpora; E17_PYTHON (default python3) runs the generator.
# E17_TMPFS_SHARE (PLAN-E17B Task 10) is --tmpfs-share: that fraction of the sessions keeps its
# py_analyze/py_test caches in guest tmpfs, and every turn ends with a py_shmem reading. Its default follows the
# profile (final review M3): 0.5 under E17B=1 (the E17b corpora; E17C=1 implies E17B=1, PLAN-E17C Task 4), 0 with
# E17B and E17C unset, so the sealed command still
# writes the E17a corpora byte for byte (corpus_sha256 of results/corpus/*-report.json).
#
#   bash experiments/e17-lease/rig/gen_corpora.sh [--durations-from CAL.json] [--gate-256 GATE.json]
#
# --durations-from CAL.json: a JSON object, each of the five classes (py_analyze, py_test, py_import,
# py_grep, py_short; spec v0.4 §4.3) to its measured N=1 median run_ms (the calibration, PLAN Task 5
# step 4). The corpora then carry those as dur_ms/work_ms, not the 15000/60000/2000/2200/300
# placeholders (ruling: after calibration they must),
# and each corpus-report.json records them (durations_ms, durations_from). Without it the
# placeholders stay, and this script says so. Each corpus directory is replaced whole: written to
# a temporary sibling first, then moved over the old one.
#
# --gate-256 GATE.json (E17C=1 only; PLAN-E17C Task 10, SPEC §13.5 R45): a passing gate-256.json (the rig's
# $E15_RUNS/pycache-d64/gate-256.json, copied back). Also writes $E17_CORPORA/pycache-256/, the corpus of E17c's 256 MiB
# points (pycache-d64, squeeze-256): pycache's arguments, with the durations of --durations-from (or the placeholders)
# but py_analyze at the gate's py_analyze_ms (the chosen scale's sbx median), so it has its own corpus hash. The
# durations go in via a durations-256.json, which its corpus-report.json names. A gate that did not pass is refused
# (exit 1) before anything is written, and so is one whose chosen_scale is not the scale workload/library-256.json
# carries (the reviewed commit of the gate's scale, ruling R-x; the placeholder 0 included) or whose moca_commit is not
# E17C_MOCA_PIN (rig/e17c-pins.sh) (final review M5). pycache-256's corpus-report.json records the gate under
# "gate_256": the file's name and sha256, its chosen_scale and moca_commit. Under E17C=1 without it, no pycache-256 is
# written, and this script says so. E17C_PINS_FILE and E17_LIBRARY_256 override the pin file and the library (tests).
#
# E17d (E17D=1 only; PLAN-E17D Task 3, spec §14.2): also $E17_CORPORA/pycache-l2/, point pycache-l2's corpus:
# pycache_corpus.py --point pycache-l2 with pycache's arguments (--duty 0.095, so its sessions and gaps are pycache's;
# --tmpfs-share 0: no level-2 class keeps a tmpfs cache) and --gap-durations-from the --durations-from CAL.json (the
# durations pycache's own corpus is fitted with), so its gaps are exactly the pycache corpus's. Its own durations
# (py_requery, py_refit, py_short) come from --l2-durations-from L2CAL.json, the pycache-l2 calibration's N = 1 medians
# (else its placeholders, and this script says so). It has its own corpus hash. With E17D unset nothing changes.
set -euo pipefail
W="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PC=${E17_CORPORA:-/tmp/kagenti/e17-corpora}
GAPS=${E17_GAPS:-/tmp/kagenti/e16-corpus-default/corpus.jsonl}
PY=${E17_PYTHON:-python3}
PINS=${E17C_PINS_FILE:-$W/experiments/e17-lease/rig/e17c-pins.sh}
LIB256=${E17_LIBRARY_256:-$W/experiments/e17-lease/workload/library-256.json}
if [ "${E17B:-}" = 1 ] || [ "${E17C:-}" = 1 ]; then SHARE=${E17_TMPFS_SHARE:-0.5}; else SHARE=${E17_TMPFS_SHARE:-0}; fi
cal=()
gate=""
l2cal=()
while [ $# -gt 0 ]; do
  case "$1" in
  --durations-from)
    if [ $# -lt 2 ] || [ ! -f "$2" ]; then
      echo "gen_corpora.sh: --durations-from needs an existing CAL.json" >&2
      exit 2
    fi
    cal=(--durations-from "$2")
    shift 2
    ;;
  --gate-256)
    if [ "${E17C:-}" != 1 ]; then
      echo "gen_corpora.sh: --gate-256 is E17c's (E17C=1): the 256 MiB points' corpus" >&2
      exit 2
    fi
    if [ $# -lt 2 ] || [ ! -f "$2" ]; then
      echo "gen_corpora.sh: --gate-256 needs an existing GATE.json (gate-256.json)" >&2
      exit 2
    fi
    gate=$2
    shift 2
    ;;
  --l2-durations-from)
    if [ "${E17D:-}" != 1 ]; then
      echo "gen_corpora.sh: --l2-durations-from is E17d's (E17D=1): the pycache-l2 corpus" >&2
      exit 2
    fi
    if [ $# -lt 2 ] || [ ! -f "$2" ]; then
      echo "gen_corpora.sh: --l2-durations-from needs an existing L2CAL.json" >&2
      exit 2
    fi
    l2cal=(--durations-from "$2")
    shift 2
    ;;
  *)
    echo "usage: gen_corpora.sh [--durations-from CAL.json] [--gate-256 GATE.json] [--l2-durations-from L2CAL.json]" >&2
    exit 2
    ;;
  esac
done
[ -f "$GAPS" ] || {
  echo "gen_corpora.sh: no gap source $GAPS (E17_GAPS)" >&2
  exit 1
}
specs="pycache:0.095 pycache-low:0.015"
d256=""
if [ -n "$gate" ]; then
  # the gate first: a gate that did not pass writes nothing
  d256=$(mktemp -d)
  trap 'rm -rf -- "$d256"' EXIT
  [ -f "$PINS" ] || {
    echo "gen_corpora.sh: no $PINS (E17C_MOCA_PIN): --gate-256 checks the gate's moca_commit against it" >&2
    exit 1
  }
  pin=$(sed -n 's/^E17C_MOCA_PIN=\([0-9a-f]*\)$/\1/p' "$PINS")
  "$PY" - "$W/experiments/e17-lease/extract" "$gate" "${cal[1]:-}" "$d256/durations-256.json" \
    "$W/experiments/e17-lease/analysis" "$LIB256" "$pin" "$d256/gate-256-record.json" <<'PY' || exit 1
import hashlib, json, os, sys
sys.path.insert(0, sys.argv[1])
sys.path.insert(0, sys.argv[5])
import pycache_corpus as P  # noqa: E402
import gate256  # noqa: E402
gate, cal, out, _, lib, pin, rec = sys.argv[2:]
try:
    raw = open(gate, "rb").read()
    g = json.loads(raw)
except (OSError, ValueError) as e:
    sys.exit("gen_corpora.sh: %s is unreadable (%s)" % (gate, e))
ms = g.get("py_analyze_ms") if isinstance(g, dict) else None
if not isinstance(g, dict) or g.get("pass") is not True or not isinstance(ms, (int, float)) or ms <= 0:
    sys.exit("gen_corpora.sh: %s did not pass (%s): no pycache-256 corpus" % (gate, (g or {}).get("reason") if isinstance(g, dict) else "not an object"))
scale = g.get("chosen_scale")
if not isinstance(scale, int) or isinstance(scale, bool):
    sys.exit("gen_corpora.sh: %s has no integer chosen_scale (%s): no pycache-256 corpus" % (gate, json.dumps(scale)))
try:
    have = gate256.library_scale(lib)
except (OSError, ValueError, KeyError) as e:
    sys.exit("gen_corpora.sh: %s is unreadable (%s): no pycache-256 corpus" % (lib, e))
if have != scale:
    sys.exit("gen_corpora.sh: %s carries scale %d, but %s chose %d: commit the gate's scale first (ruling R-x); "
             "no pycache-256 corpus" % (lib, have, gate, scale))
if g.get("moca_commit") != pin:
    sys.exit("gen_corpora.sh: %s has moca_commit %s, not E17C_MOCA_PIN %s: no pycache-256 corpus"
             % (gate, json.dumps(g.get("moca_commit")), pin or "(none)"))
dur = dict(json.load(open(cal))) if cal else dict(P.DUR_MS)
dur["py_analyze"] = ms
json.dump(dur, open(out, "w"), sort_keys=True)
json.dump({"file": os.path.basename(gate), "sha256": hashlib.sha256(raw).hexdigest(), "chosen_scale": scale,
           "moca_commit": pin}, open(rec, "w"), sort_keys=True)
PY
  specs+=" pycache-256:0.095"
fi
# E17d (E17D=1): pycache-l2, pycache's sessions and gaps with level-2 turns
[ "${E17D:-}" != 1 ] || specs+=" pycache-l2:0.095"
mkdir -p "$PC"
for spec in $specs; do
  p=${spec%%:*}
  duty=${spec#*:}
  args=(${cal[@]+"${cal[@]}"})
  share=$SHARE
  [ "$p" != pycache-256 ] || args=(--durations-from "$d256/durations-256.json")
  if [ "$p" = pycache-l2 ]; then
    args=(--point pycache-l2 ${cal[1]:+--gap-durations-from "${cal[1]}"} ${l2cal[@]+"${l2cal[@]}"})
    share=0
  fi
  tmp=$(mktemp -d "$PC/.$p.XXXXXX")
  if ! "$PY" "$W/experiments/e17-lease/extract/pycache_corpus.py" --gaps-from "$GAPS" --duty "$duty" --sessions 400 \
    --seed 1 --min-turns 4 ${args[@]+"${args[@]}"} --tmpfs-share "$share" --out "$tmp"; then
    rm -rf -- "$tmp"
    echo "gen_corpora.sh: pycache_corpus.py failed for $p" >&2
    exit 1
  fi
  # pycache-256's report names the gate it was built from (final review M5); corpus_sha256 covers corpus.jsonl only
  if [ "$p" = pycache-256 ]; then
    if ! "$PY" -c 'import json,sys; r=json.load(open(sys.argv[1])); r["gate_256"]=json.load(open(sys.argv[2]))
f = open(sys.argv[1] + ".tmp", "w"); f.write(json.dumps(r, indent=2) + "\n"); f.close()' \
      "$tmp/corpus-report.json" "$d256/gate-256-record.json" || ! mv "$tmp/corpus-report.json.tmp" "$tmp/corpus-report.json"; then
      rm -rf -- "$tmp"
      echo "gen_corpora.sh: could not record the gate in $p's corpus-report.json" >&2
      exit 1
    fi
  fi
  # Only the corpus directory itself is replaced: $PC/pycache, $PC/pycache-low, $PC/pycache-256 or $PC/pycache-l2.
  rm -rf -- "${PC:?}/$p"
  mv "$tmp" "$PC/$p"
  "$PY" -c 'import json,sys; r=json.load(open(sys.argv[1])); print("%s: duty %.4f (target %s), %d sessions (%d tmpfs, share %s), durations_ms %s, corpus_sha256 %s" % (sys.argv[2], r["duty_achieved"]["mean"], r["duty_target"], r["sessions"], r["tmpfs_sessions"], r["tmpfs_share"], r["durations_ms"], r["corpus_sha256"]))' \
    "$PC/$p/corpus-report.json" "$p"
done
if [ "${E17C:-}" = 1 ] && [ -z "$gate" ]; then
  echo "gen_corpora.sh: note: no pycache-256 corpus (E17c's 256 MiB points): re-run with --gate-256 GATE.json once gate-256 passed" >&2
fi
if [ "${E17D:-}" = 1 ] && [ ${#l2cal[@]} -eq 0 ]; then
  echo "gen_corpora.sh: note: pycache-l2 has placeholder durations (no --l2-durations-from); re-run with its calibration's before the measured rungs" >&2
fi
[ ${#cal[@]} -gt 0 ] || echo "gen_corpora.sh: note: placeholder durations (no --durations-from); re-run with the calibration's before the measured rungs" >&2
