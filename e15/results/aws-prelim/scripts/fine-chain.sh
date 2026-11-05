#!/usr/bin/env bash
# ~/e15-run/t9/fine-chain.sh: after the sealed chain completes, supplementary rungs N=10 12 14 at
# the default point for sbx, resident-inf, resident-300 (fine.sh; not sealed). Same OOM stop.
set -u
T=~/e15-run/t9
LOG=$T/chain.log
export PATH=/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin
say() { echo "$(date -u +%FT%TZ) $*" >>"$LOG"; }
while [ ! -e $T/chain.complete ]; do [ -e $T/STOP ] && exit 1; sleep 60; done
SINCE=$(date -u '+%Y-%m-%d %H:%M:%S')
( while sleep 20; do
    if sudo -n journalctl -k --since "$SINCE" --no-pager 2>/dev/null | grep -q "Out of memory: Killed process"; then
      echo "GLOBAL OOM (fine) $(date -u +%FT%TZ)" >$T/STOP
      pkill -f "rig/fine.sh"; pkill -f "rig/rung.sh"; pkill -f e15-driver
      bash -c '. /srv/e15/src/e15/rig/lib.sh; stop_rung_units' >>$LOG 2>&1
      exit 0
    fi
  done ) &
SENT=$!
trap 'kill $SENT 2>/dev/null' EXIT
shared_repeat() { python3 ~/e15-run/t9/shared_host.py "$1" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["repeat"] else 1)'; }
export -f shared_repeat
for a in sbx resident-inf resident-300; do
  [ -e $T/STOP ] && exit 1
  say "fine default $a 10 12 14 (SUPPLEMENTARY)"
  E15_FINE_REPEAT_CHECK=shared_repeat bash /srv/e15/src/e15/rig/fine.sh default "$a" 10 12 14 >$T/fine-default-$a.log 2>&1
  rc=$?
  say "FINE DONE default $a exit $rc: $(tail -1 $T/fine-default-$a.log)"
  echo "default $a $rc" >>$T/fine-done
done
say "FINE COMPLETE"
echo complete >$T/fine.complete
