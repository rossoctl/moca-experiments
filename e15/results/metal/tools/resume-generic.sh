#!/usr/bin/env bash
# resume-generic.sh ARM N: the sealed unseeded rule for a repeat that died on unseeded sessions: re-run N's repeat
# once with K doubled (tag repeat-k2, warm-up 2400 s); if it holds either verdict, resume ladder.sh from the next
# ladder N; then assemble ladder.json from the part-1 rung list + that rung + ladder.part2.json.
set -uo pipefail
export E15_HOST_PROFILE=fresh-metal PATH=/srv/e15/bin:$PATH
unset E15_MAX_SESSIONS E15_START_ZERO E15_TAG E15_SEED E15_WARMUP_S E15_WINDOW_S
ARM=$1; N=$2
R=/srv/e15/src/e15/rig; B=/srv/e15/runs/default/$ARM; L=/srv/e15/ladders-metal
LADDER=(1 8 16 24 32 40 48 56 64 80 96 128 160 192 256 320 384 448 512 576 640 704 768 896 1024)
[ -f "$B/ladder-rungs.part1.jsonl" ] || cp "$B/ladder-rungs.jsonl" "$B/ladder-rungs.part1.jsonl"
[ -f "$L/default-$ARM.part1.log" ] || cp "$L/default-$ARM.log" "$L/default-$ARM.part1.log"
echo "RESUME $ARM start N=$N $(date -u +%FT%TZ)"
# ca6fa27: K_MULT now multiplies the floored K (K=32 at x2, 64 at x4)
tag=repeat-k2
for km in 2 4; do
  E15_TAG=$tag E15_K_MULT=$km E15_WARMUP_S=2400 bash "$R/rung.sh" "$ARM" "$N" default >"$L/default-$ARM.resume-N$N-$tag.log" 2>&1 ||
    { echo "RESUME $ARM N$N $tag RIG_ERROR"; exit 1; }
  d=$B/N$N-$tag
  read -r h ha un < <(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(str(r["holds"]).lower(), str(r["holds_abs"]).lower(), r.get("unseeded_sessions") or 0)' "$d/record.json")
  echo "RESUME $ARM N$N $tag (K x$km, K=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["workspaces_per_slot"])' "$d/params.json")) holds=$h holds_abs=$ha unseeded=$un"
  [ "$un" = 0 ] && break
  tag=repeat-k4
done
[ "$un" = 0 ] || { echo "RESUME $ARM N$N still unseeded at K x4: rig error"; exit 1; }
p1=$L/$ARM-part1.jsonl
cp "$B/ladder-rungs.part1.jsonl" "$p1"
printf '{"n":%s,"holds":%s,"holds_abs":%s,"repeated":true,"median_class_pace":null,"rig_errors":["repeat unseeded (N%s-repeat, and N%s-repeat-k2 at K=16: K_MULT was a no-op before ca6fa27, moved to runs/_aborted-*-kfloor); re-run with K doubled after ca6fa27"],"dir":"%s"}\n' "$N" "$h" "$ha" "$N" "$N" "$d" >>"$p1"
next=""
for x in "${LADDER[@]}"; do [ "$x" -gt "$N" ] && { next=$x; break; }; done
if { [ "$h" = true ] || [ "$ha" = true ]; } && [ -n "$next" ]; then
  bash "$R/ladder.sh" default "$ARM" "$next" >"$L/default-$ARM.resume.log" 2>&1 || echo "RESUME $ARM ladder from $next FAILED rc=$?"
  mv "$B/ladder.json" "$B/ladder.part2.json" 2>/dev/null
fi
python3 - "$B" "$p1" "$ARM" "$N" <<'PY'
import json, os, sys
b, p1, arm, n0 = sys.argv[1:5]
rungs = [json.loads(l) for l in open(p1) if l.strip()]
p2 = os.path.join(b, "ladder.part2.json")
if os.path.exists(p2):
    rungs += json.load(open(p2))["rungs"]
def nmax(key):
    n = stop = None
    for r in rungs:
        if r[key]: n = r["n"]
        else: stop = r["n"]; break
    return n, stop
n, s = nmax("holds"); na, sa = nmax("holds_abs")
bl = json.load(open(os.path.join(b, "N1", "baseline.json")))
json.dump({"point": "default", "arm": arm, "start_n": 1,
           "ladder": [1, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 128, 160, 192, 256, 320, 384, 448, 512, 576, 640, 704, 768, 896, 1024],
           "rungs": rungs, "n_max": n, "stopped_at": s, "n_max_abs": na, "stopped_at_abs": sa,
           "n1_overhead_ms": bl.get("overhead_ms"), "n1_median_pace": bl.get("n1_median_pace"),
           "abs_rule": "condition 4 = p95(class excess) <= B + 250 ms",
           "assembled": "sealed chain to N=%s; its repeat hit unseeded sessions (rig error); re-run once with K doubled (the sealed unseeded rule) counts; resumed from the next rung (ladder.part2.json)" % n0},
          open(os.path.join(b, "ladder.json"), "w"), indent=2)
print("RESUME %s DONE n_max=%s stopped_at=%s n_max_abs=%s stopped_at_abs=%s" % (arm, n, s, na, sa))
PY
