#!/usr/bin/env bash
# waitstep.sh N: wait until chain.out has more than N finished-step lines (DONE/FAILED/ALL DONE), print them.
n=$1
while :; do
  out=$(ssh -o ConnectTimeout=20 -o BatchMode=yes -i /Users/paolo/.ssh/id_ed25519 ubuntu@3.218.223.125 'grep -E "CHAIN .* (DONE|FAILED)" /srv/e15/calibration-metal/chain.out; pgrep -f calibration-metal/tools/chain.sh >/dev/null && echo RUNNING || echo STOPPED' 2>/dev/null) || { sleep 60; continue; }
  c=$(printf '%s\n' "$out" | grep -c 'CHAIN')
  if [ "$c" -gt "$n" ] || printf '%s\n' "$out" | grep -q STOPPED; then printf '%s\n' "$out"; exit 0; fi
  sleep 60
done
