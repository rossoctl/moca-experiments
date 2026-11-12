#!/usr/bin/env bash
# experiments/e16-low-duty/rig/rung-perf.sh ARM N POINT -- experiments/e15-session-density/rig/rung.sh with perfsample.sh in the rung's measured window
# (chain.sh passes it to ladder.sh as E15_RUNG, so ladder.sh's repeats and k2 re-runs are sampled at
# their own warm-up too). perf.jsonl lands in the rung directory. Same exit status as rung.sh.
# E16_RUNG_INNER replaces rung.sh (tests); E16_NO_PERF=1 skips the sampler.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC=${E16_SRC:-/srv/e15/src}
INNER=${E16_RUNG_INNER:-$SRC/e15/rig/rung.sh}
RUNS=${E16_RUNS:-/srv/e15/runs}
arm=$1 n=$2 point=$3
d=$RUNS/$point/$arm/N$n${E15_TAG:+-$E15_TAG}
wu=${E15_WARMUP_S:-1200}
win=${E15_WINDOW_S:-900}
pp=""
tmp=$RUNS/$point/$arm/.perf-N$n${E15_TAG:+-$E15_TAG}.jsonl
if [ "${E16_NO_PERF:-0}" != 1 ] && [ "$arm" != control ]; then
  mkdir -p "$(dirname "$tmp")"
  rm -f "$tmp"
  (bash "$HERE/perfsample.sh" "$tmp" $((wu + 30)) "$win") &
  pp=$!
fi
rc=0
bash "$INNER" "$@" || rc=$?
if [ -n "$pp" ]; then
  pkill -P "$pp" 2>/dev/null
  kill "$pp" 2>/dev/null
  wait "$pp" 2>/dev/null
  [ -d "$d" ] && [ -f "$tmp" ] && mv "$tmp" "$d/perf.jsonl"
fi
exit "$rc"
