#!/usr/bin/env bash
# climb2.sh: apply the grace-artefact ruling (2026-11-06) mid-climb.
# 1. wait for the running climb's "CLIMB resident-inf N=192 ..." line (that rung, and any drift repeat, judged),
#    then stop that climb before it starts another rung.
# 2. resumed climb (climb.sh.v2): sbx from N=160 (the existing N160-1s is judged; a grace artefact is re-run with
#    grace 900 s; the climb continues if it holds), then resident-inf from N=192 (existing rung judged, not re-run),
#    then resident-300.
set -uo pipefail
O=/srv/e15/post-chain.out
until grep -qE "CLIMB resident-inf N=192 |CLIMB resident-inf .*RIG_ERROR|CLIMB resident-inf DONE" "$O"; do sleep 5; done
for p in $(pgrep -f "^bash /srv/e15/calibration-metal/tools/climb.sh"); do kill "$p"; done
sleep 3
for p in $(pgrep -f "/srv/e15/src/e15/rig/rung.sh"); do kill "$p"; done   # a just-started next rung, if any
sleep 3
for p in $(pgrep -x e15-driver); do kill "$p"; done
for p in $(pgrep -f "calibration-metal/tools/perfsample.sh"); do kill "$p"; done
bash -c "export E15_HOST_PROFILE=fresh-metal; source /srv/e15/src/e15/rig/lib.sh; stop_rung_units" >/dev/null 2>&1
echo "CLIMB2 old climb stopped after: $(grep -E 'CLIMB resident-inf N=192 ' "$O" | tail -1) $(date -u +%FT%TZ)"
cp /srv/e15/calibration-metal/tools/climb.sh.v2 /srv/e15/calibration-metal/tools/climb.sh
exec env RESUME_sbx=160 RESUME_resident_inf=192 bash /srv/e15/calibration-metal/tools/climb.sh
