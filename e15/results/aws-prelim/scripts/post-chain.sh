#!/usr/bin/env bash
# ~/e15-run/t9/post-chain.sh: after the sealed chain completes: (1) any ladder that stopped at N=1
# with the counted N=1 record reason=empty_window (an instrument artefact, not a host verdict) is
# re-run from N=8 (rungs below the start are assumed held; first ladder.json kept as
# ladder.emptywindow.json); (2) then the supplementary chain (fine-chain.sh logic).
set -u
T=~/e15-run/t9
RUNS=/srv/e15/runs
LOG=$T/chain.log
export PATH=/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin
say() { echo "$(date -u +%FT%TZ) $*" >>"$LOG"; }
while [ ! -e $T/chain.complete ]; do [ -e $T/STOP ] && exit 1; sleep 60; done
SINCE=$(date -u '+%Y-%m-%d %H:%M:%S')
( while sleep 20; do
    if sudo -n journalctl -k --since "$SINCE" --no-pager 2>/dev/null | grep -q "Out of memory: Killed process"; then
      echo "GLOBAL OOM (post) $(date -u +%FT%TZ)" >$T/STOP
      pkill -f "e15-run/t9/run-ladder.sh"; pkill -f "rig/ladder.sh"; pkill -f "rig/fine.sh"; pkill -f "rig/rung.sh"; pkill -f e15-driver
      bash -c '. /srv/e15/src/e15/rig/lib.sh; stop_rung_units' >>$LOG 2>&1
      exit 0
    fi
  done ) &
SENT=$!
trap 'kill $SENT 2>/dev/null' EXIT
for lj in $RUNS/*/*/ladder.json; do
  pa=${lj%/ladder.json}; case "$pa" in */_*|*/smoke/*|*/control) continue ;; esac
  ew=$(python3 - "$lj" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
r = [x for x in d["rungs"] if x["n"] == 1]
if d.get("stopped_at") == 1 and r:
    rec = json.load(open(r[0]["dir"] + "/record.json"))
    print("yes" if rec.get("reason") == "empty_window" else "no")
else:
    print("no")
PY
)
  [ "$ew" = yes ] || continue
  p=$(basename "$(dirname "$pa")"); a=$(basename "$pa")
  cp "$lj" "$pa/ladder.emptywindow.json"
  say "N=1 empty_window at $p $a (instrument artefact): re-running the ladder from 8"
  ~/e15-run/t9/run-ladder.sh "$p" "$a" 8
  cp $T/$p-$a.log $T/$p-$a.from8.log
  say "DONE $p $a (from 8) $(tail -2 $T/$p-$a.log | head -1)"
  echo "$p $a from8" >>$T/ladders-done
done
[ -e $T/STOP ] && exit 1
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
