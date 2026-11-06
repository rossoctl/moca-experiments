#!/usr/bin/env bash
# post-chain.sh: after the sealed 5-ladder chain ends: resume default resident-inf (N=56) and resident-300 (N=96)
# with the sealed unseeded rule (resume-generic.sh), then the supplementary climb (climb.sh). Sequential.
set -uo pipefail
T=/srv/e15/calibration-metal/tools
[ -s /srv/e15/ladders-metal/STOP ] && { echo "POST NOT STARTED: STOP"; exit 1; }
# the host's src is ca6fa27 (rung.sh K fix, ladder.sh repeat K x2); the sealed chain ran 3d653a2
echo "POST v2 start $(date -u +%FT%TZ) src $(cat /srv/e15/src/COMMIT)"
L=/srv/e15/ladders-metal; R=/srv/e15/src/e15/rig
since=$(date '+%Y-%m-%d %H:%M:%S')
( while :; do
    if journalctl -k --since "$since" --no-pager 2>/dev/null | grep 'Out of memory: Killed process' | grep -qv 'Memory cgroup'; then
      echo "global_oom $(date -u +%FT%TZ)" >"$L/STOP"; fi
    free_kb=$(df -k --output=avail /srv/e15 | tail -1)
    [ "$free_kb" -lt $((10 * 1024 * 1024)) ] && echo "disk_free_${free_kb}kB $(date -u +%FT%TZ)" >"$L/STOP"
    if [ -s "$L/STOP" ]; then
      pkill -f "$R/ladder.sh"; pkill -f "$R/rung.sh"; pkill -x e15-driver
      bash -c "export E15_HOST_PROFILE=fresh-metal; source $R/lib.sh; stop_rung_units" >/dev/null 2>&1
      echo "POST SENTINEL STOP $(cat "$L/STOP")"; exit 0; fi
    sleep 20
  done ) &
spid=$!
bash "$T/resume-generic.sh" resident-inf 56
[ -s /srv/e15/ladders-metal/STOP ] && exit 1
bash "$T/resume-generic.sh" resident-300 96
[ -s /srv/e15/ladders-metal/STOP ] && exit 1
echo "POST climb start $(date -u +%FT%TZ)"
kill "$spid" 2>/dev/null   # climb.sh runs its own sentinel
exec bash "$T/climb.sh"
