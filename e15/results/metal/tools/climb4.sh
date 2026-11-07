#!/usr/bin/env bash
# climb4.sh: climb3's resume point for resident-300 came out empty (a grep matched the "300" in the arm name).
# Wait for "CLIMB resident-inf DONE" in climb3.out, stop that climb before it starts resident-300 (kill it the moment
# the DONE line appears; resident-300 then has at most just begun its sealed-rung re-judge), move aside the
# record-less N256-1s left by the killed-in-flight rung, and run resident-300 alone, resuming at N=256 (its N=192-1s
# row is kept from the earlier climb.jsonl).
set -uo pipefail
O=/srv/e15/climb3.out
T=/srv/e15/calibration-metal/tools
B=/srv/e15/runs/default/resident-300
cp "$B/supplementary-1s/climb.jsonl" "$B/supplementary-1s/climb.jsonl.climb2"
until grep -qE "CLIMB resident-inf DONE|CLIMB resident-inf .*(RIG_ERROR|DISK)|CLIMB ALL END|SENTINEL" "$O"; do sleep 2; done
for p in $(pgrep -f "^bash /srv/e15/calibration-metal/tools/climb.sh"); do kill "$p"; done
sleep 3
for p in $(pgrep -f "/srv/e15/src/e15/rig/rung.sh"); do kill "$p"; done
sleep 3
for p in $(pgrep -x e15-driver); do kill "$p"; done
for p in $(pgrep -f "calibration-metal/tools/perfsample.sh"); do kill "$p"; done
bash -c "export E15_HOST_PROFILE=fresh-metal; source /srv/e15/src/e15/rig/lib.sh; stop_rung_units" >/dev/null 2>&1
grep -q SENTINEL "$O" && { echo "CLIMB4 sentinel stop: not continuing"; exit 1; }
cp "$B/supplementary-1s/climb.jsonl.climb2" "$B/supplementary-1s/climb.jsonl"
for d in "$B"/N256-1s*; do [ -d "$d" ] && [ ! -f "$d/record.json" ] && mv "$d" "/srv/e15/runs/_aborted-climb3-resident-300-$(basename "$d")"; done
echo "CLIMB4 resident-300 resumes at N=256 $(date -u +%FT%TZ)"
ARMS=resident-300 RESUME_resident_300=256 exec bash "$T/climb.sh"
