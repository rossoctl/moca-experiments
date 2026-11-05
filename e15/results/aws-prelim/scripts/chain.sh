#!/usr/bin/env bash
# ~/e15-run/t9/chain.sh -- Task 9 chain on the rig (detached). Waits for default-sbx (already running),
# then default resident-inf, resident-300, then the sensitivity points (SPEC §10.3), each from two
# ladder steps below that arm's default n_max. After each ladder: SPEC §12 shared-host check per rung
# (shared_host.py); a flagged rung -> the ladder is re-run from that rung once (ladder.first.json kept).
# Start rung failing the primary verdict -> descend one ladder step and re-run, until a rung holds.
# OOM sentinel: any new kernel "Out of memory: Killed process" line -> STOP file, chain killed, units stopped.
set -u
T=~/e15-run/t9
RUNS=/srv/e15/runs
LOG=$T/chain.log
export PATH=/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin
say() { echo "$(date -u +%FT%TZ) $*" >>"$LOG"; }
SINCE=$(date -u '+%Y-%m-%d %H:%M:%S')
echo "$SINCE" >$T/chain.since
LADDER=(1 8 16 24 32 40 48 56 64 80 96 128)
idx() { local i; for i in "${!LADDER[@]}"; do [ "${LADDER[$i]}" = "$1" ] && { echo "$i"; return; }; done; echo -1; }

# OOM sentinel
CHAIN_PID=$$
(
  while sleep 20; do
    if sudo -n journalctl -k --since "$SINCE" --no-pager 2>/dev/null | grep -q "Out of memory: Killed process"; then
      echo "GLOBAL OOM $(date -u +%FT%TZ)" >$T/STOP
      sudo -n journalctl -k --since "$SINCE" --no-pager | grep -E "Out of memory|invoked oom-killer" >$T/oom-lines.txt
      pkill -f "e15-run/t9/run-ladder.sh"; pkill -f "rig/ladder.sh"; pkill -f "rig/rung.sh"; pkill -f e15-driver
      bash -c '. /srv/e15/src/e15/rig/lib.sh; stop_rung_units' >>$T/chain.log 2>&1
      kill "$CHAIN_PID" 2>/dev/null
      exit 0
    fi
  done
) &
SENT=$!
trap 'kill $SENT 2>/dev/null' EXIT

nmax() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))["n_max"]; print("null" if v is None else v)' "$RUNS/$1/$2/ladder.json"; }

ladder_once() { # POINT ARM START
  [ -e $T/STOP ] && exit 1
  say "ladder $1 $2 from $3"
  ~/e15-run/t9/run-ladder.sh "$1" "$2" "$3"
  local rc; rc=$(cat $T/$1-$2.done)
  cp $T/$1-$2.log $T/$1-$2.from$3.log
  say "ladder $1 $2 from $3 exit $rc: $(tail -2 $T/$1-$2.log | head -1)"
  [ -e $T/STOP ] && exit 1
  return "$rc"
}

shared_check() { # POINT ARM -> echoes the smallest N flagged, or nothing
  python3 - "$RUNS/$1/$2/ladder.json" <<'PY'
import json, subprocess, sys, os
lj = json.load(open(sys.argv[1]))
flag = []
for r in lj["rungs"]:
    out = subprocess.run(["python3", os.path.expanduser("~/e15-run/t9/shared_host.py"), r["dir"]], capture_output=True, text=True).stdout
    try:
        if json.loads(out)["repeat"]: flag.append(r["n"])
    except Exception:
        pass
print(min(flag) if flag else "")
PY
}

run_point() { # POINT ARM START
  local p=$1 a=$2 s=$3 rc
  while :; do
    ladder_once "$p" "$a" "$s"; rc=$?
    if [ "$rc" != 0 ]; then say "RIG ERROR ladder $p $a (exit $rc); continuing with next"; echo "$p $a $s" >>$T/rig-errors; return 1; fi
    local nm; nm=$(nmax "$p" "$a")
    if [ "$nm" = null ] && [ "$s" != 1 ]; then
      local i; i=$(idx "$s"); s=${LADDER[$((i - 1))]}
      cp "$RUNS/$p/$a/ladder.json" "$RUNS/$p/$a/ladder.failstart-$3-$(date +%s).json"
      say "start rung failed primary at $p $a; descending to $s"
      continue
    fi
    break
  done
  local f; f=$(shared_check "$p" "$a")
  if [ -n "$f" ] && [ ! -e "$RUNS/$p/$a/ladder.first.json" ]; then
    cp "$RUNS/$p/$a/ladder.json" "$RUNS/$p/$a/ladder.first.json"
    say "shared-host spike at $p $a N=$f: re-running the ladder from $f (SPEC §12)"
    ladder_once "$p" "$a" "$f" || { echo "$p $a $f" >>$T/rig-errors; return 1; }
  fi
  say "DONE $p $a n_max=$(nmax "$p" "$a")"
  echo "$p $a" >>$T/ladders-done
}

start_for() { # ARM -> two ladder steps below default n_max (primary); 1 if n_max null or <= 8
  local nm; nm=$(nmax default "$1")
  [ "$nm" = null ] && { echo 1; return; }
  local i; i=$(idx "$nm"); i=$((i - 2)); [ $i -lt 0 ] && i=0
  echo "${LADDER[$i]}"
}

# default sbx is already running under run-ladder.sh
while [ ! -e $T/default-sbx.done ]; do sleep 30; done
cp $T/default-sbx.log $T/default-sbx.from1.log
f=$(shared_check default sbx)
if [ -n "$f" ]; then cp $RUNS/default/sbx/ladder.json $RUNS/default/sbx/ladder.first.json; say "shared-host spike default sbx N=$f; re-run"; ladder_once default sbx "$f"; fi
say "DONE default sbx n_max=$(nmax default sbx)"; echo "default sbx" >>$T/ladders-done
run_point default resident-inf 1
run_point default resident-300 1
for p in short long no-infra no-chains; do
  for a in sbx resident-inf resident-300; do
    case "$p:$a" in short:resident-300) continue ;; esac
    [ -f $RUNS/default/$a/ladder.json ] || continue
    run_point "$p" "$a" "$(start_for "$a")"
  done
done
run_point mem512 sbx "$(start_for sbx)"
run_point mem512 resident-inf "$(start_for resident-inf)"
say "CHAIN COMPLETE"
echo complete >$T/chain.complete
