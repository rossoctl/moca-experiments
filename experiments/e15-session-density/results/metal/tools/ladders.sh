#!/usr/bin/env bash
# ladders.sh -- E15 metal ladders (sealed 3d653a2): default sbx, resident-inf, resident-300; mem512 sbx, resident-inf.
# One ladder at a time. Emits "LADDER <point> <arm> START|DONE|FAILED ..." lines. A sentinel stops everything on a
# global OOM (kernel "Out of memory: Killed process", not the memcg variant) or /srv/e15 free < 10 GiB.
set -uo pipefail
export E15_HOST_PROFILE=fresh-metal PATH=/srv/e15/bin:$PATH
unset E15_MAX_SESSIONS E15_START_ZERO E15_TAG E15_SEED E15_WARMUP_S E15_WINDOW_S
R=/srv/e15/src/e15/rig
L=/srv/e15/ladders-metal
mkdir -p "$L"; rm -f "$L/STOP"
LADDERS=${LADDERS:-"default:sbx default:resident-inf default:resident-300 mem512:sbx mem512:resident-inf"}
since=$(date '+%Y-%m-%d %H:%M:%S')
sentinel() {
  while :; do
    if journalctl -k --since "$since" --no-pager 2>/dev/null | grep 'Out of memory: Killed process' | grep -qv 'Memory cgroup'; then
      echo "global_oom $(date -u +%FT%TZ)" >"$L/STOP"
    fi
    free_kb=$(df -k --output=avail /srv/e15 | tail -1)
    [ "$free_kb" -lt $((10 * 1024 * 1024)) ] && echo "disk_free_${free_kb}kB $(date -u +%FT%TZ)" >"$L/STOP"
    if [ -s "$L/STOP" ]; then
      pkill -f "$R/ladder.sh" ; pkill -f "$R/rung.sh"; pkill -x e15-driver
      bash -c "source $R/lib.sh; stop_rung_units" >/dev/null 2>&1
      echo "LADDER SENTINEL STOP $(cat "$L/STOP")"
      return
    fi
    sleep 20
  done
}
sentinel &
spid=$!
for pa in $LADDERS; do
  p=${pa%%:*}; a=${pa#*:}
  [ -s "$L/STOP" ] && break
  echo "LADDER $p $a START $(date -u +%FT%TZ)"
  rc=0
  bash "$R/ladder.sh" "$p" "$a" >"$L/$p-$a.log" 2>&1 || rc=$?
  [ -s "$L/STOP" ] && { echo "LADDER $p $a STOPPED $(cat "$L/STOP")"; break; }
  if [ $rc -ne 0 ]; then
    echo "LADDER $p $a FAILED rc=$rc $(date -u +%FT%TZ) :: $(tail -2 "$L/$p-$a.log" | tr '\n' ' ' | cut -c1-300)"
    continue
  fi
  res=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps({k: d.get(k) for k in ("n_max","stopped_at","n_max_abs","stopped_at_abs")}))' "/srv/e15/runs/$p/$a/ladder.json")
  echo "LADDER $p $a DONE $(date -u +%FT%TZ) :: $res"
done
kill "$spid" 2>/dev/null
echo "LADDER ALL END $(date -u +%FT%TZ)"
