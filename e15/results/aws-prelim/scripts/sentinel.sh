#!/usr/bin/env bash
# ~/e15-run/t9/sentinel.sh: standalone OOM sentinel (replaces the chain's, killed 01:12Z)
T=~/e15-run/t9
SINCE=$(cat $T/chain.since)
while true; do
  if sudo -n journalctl -k --since "$SINCE" --no-pager 2>/dev/null | grep -q "Out of memory: Killed process"; then
    echo "GLOBAL OOM $(date -u +%FT%TZ)" >$T/STOP
    sudo -n journalctl -k --since "$SINCE" --no-pager | grep -E "Out of memory|invoked oom-killer" >$T/oom-lines.txt
    for p in $(pgrep -f "e15-run/t9/(chain|post-chain|run-ladder).sh|rig/(ladder|fine|rung).sh|e15-driver"); do kill "$p" 2>/dev/null; done
    bash -c '. /srv/e15/src/e15/rig/lib.sh; stop_rung_units' >>$T/chain.log 2>&1
    exit 0
  fi
  [ -e $T/fine.complete ] && exit 0
  sleep 20 || true
done
