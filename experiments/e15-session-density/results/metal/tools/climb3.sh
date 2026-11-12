#!/usr/bin/env bash
# climb3.sh: apply the measured-delta disk ruling (2026-11-06) mid-climb.
# 1. wait for the running climb's next "CLIMB resident-300 N=... holds_1s" line (its current rung, and any repeat,
#    done) or its end, then stop that climb between rungs.
# 2. climb.sh v3 for resident-inf (RESUME at N=384; rungs below keep their verdicts) then resident-300 (RESUME at
#    the next rung after the last one judged; RESUME at a rung already run judges it without re-running).
set -uo pipefail
O=/srv/e15/climb2.out
T=/srv/e15/calibration-metal/tools
base=$(grep -c "CLIMB resident-300 N=.* holds_1s" "$O")
until [ "$(grep -c "CLIMB resident-300 N=.* holds_1s" "$O")" -gt "$base" ] || grep -qE "CLIMB resident-300 (DONE|.*RIG_ERROR|.*DISK)|CLIMB ALL END|SENTINEL" "$O"; do sleep 5; done
for p in $(pgrep -f "^bash /srv/e15/calibration-metal/tools/climb.sh"); do kill "$p"; done
sleep 3
for p in $(pgrep -f "/srv/e15/src/e15/rig/rung.sh"); do kill "$p"; done
sleep 3
for p in $(pgrep -x e15-driver); do kill "$p"; done
for p in $(pgrep -f "calibration-metal/tools/perfsample.sh"); do kill "$p"; done
bash -c "export E15_HOST_PROFILE=fresh-metal; source /srv/e15/src/e15/rig/lib.sh; stop_rung_units" >/dev/null 2>&1
last=$(grep -oE "CLIMB resident-300 N=[0-9]+ holds_1s" "$O" | tail -1 | grep -oE "[0-9]+")
LAD=(1 8 16 24 32 40 48 56 64 80 96 128 160 192 256 320 384 448 512 576 640 704 768 896 1024)
r300=""
for x in "${LAD[@]}"; do [ "$x" -gt "${last:-160}" ] && { r300=$x; break; }; done
# a killed-in-flight rung dir (no record) is moved aside so the resumed climb re-runs it
for d in /srv/e15/runs/default/resident-300/N"$r300"-1s*; do [ -d "$d" ] && [ ! -f "$d/record.json" ] && mv "$d" "/srv/e15/runs/_aborted-climb3-$(basename "$d")"; done
echo "CLIMB3 old climb stopped after resident-300 N=${last:-none} $(date -u +%FT%TZ); resident-300 resumes at N=$r300"
cp "$T/climb.sh.v3" "$T/climb.sh"
ARMS="resident-inf resident-300" RESUME_resident_inf=384 RESUME_resident_300=$r300 exec bash "$T/climb.sh"
