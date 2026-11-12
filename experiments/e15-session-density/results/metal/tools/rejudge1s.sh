#!/usr/bin/env bash
# rejudge1s.sh POINT ARM: holds_1s re-judge of every sealed ladder rung of POINT/ARM (record_1s.json beside record.json),
# using the 2cb8e30 analysis copied to /tmp/e15-analysis-1s; prints one line per rung.
set -euo pipefail
P=$1; A=$2
cd /srv/e15/runs/$P/$A
for d in N*; do
  case $d in N1-s*|N1-probe-*|*-cal|*-cal-repeat|N1.prev-*|probe-corpora|*-1s*) continue ;; esac
  [ -f "$d/record.json" ] && [ -f "$d/params.json" ] || continue
  python3 /tmp/e15-analysis-1s/record.py "$d" --params "$d/params.json" --p95-limit-ms 1000 --out "$d/record_1s.json" >/dev/null
  python3 -c 'import json,sys; r=json.load(open(sys.argv[1]+"/record_1s.json")); s=json.load(open(sys.argv[1]+"/record.json"))
print(sys.argv[1], "sealed", s["holds"], s["holds_abs"], "1s", r["holds"], "p95x", round(r["p95_excess_ms"] or -1), "pace", r.get("median_class_pace"), "fail", r["failed_calls"])' "$d"
done | sort -V
