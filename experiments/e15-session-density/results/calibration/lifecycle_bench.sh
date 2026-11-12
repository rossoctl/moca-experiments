#!/usr/bin/env bash
# e15/results/calibration/lifecycle_bench.sh -- per-Exec lifecycle CPU on the SBX arm (stock
# worker, standby depth 2), idle host, one Exec at a time: COUNT Execs of `true` on one workspace
# key, slice CPU (e15-vms.slice cpu.stat usage_usec: worker + jailer + Firecracker) read before and
# after. The first WARM Execs (cold first-exec, standby fill) are excluded from both.
set -euo pipefail
E15_PROG=lifecycle_bench.sh
. /srv/e15/src/e15/rig/lib.sh
COUNT=${COUNT:-100}
WARM=${WARM:-5}
OUTDIR=${OUTDIR:-/srv/e15/calibration/lifecycle}
KEY=e15-calib-life
rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"
trap stop_rung_units EXIT
stop_rung_units
sudo -n rm -rf "$E15_WORKSPACES/$KEY"
sudo -n mkdir -m 0700 "$E15_WORKSPACES/$KEY"
sudo -n cp --reflink=always "$E15_TEMPLATE" "$E15_WORKSPACES/$KEY/workspace.img"
sudo -n chmod 0600 "$E15_WORKSPACES/$KEY/workspace.img"
start_worker sbx "$OUTDIR"
usage() { awk '$1=="usage_usec"{print $2}' "$E15_VMCG/cpu.stat"; }
for ((i = 0; i < WARM; i++)); do gexec "$KEY" true >/dev/null; done
sleep 3
before=$(usage)
t0=$(date +%s.%N)
for ((i = 0; i < COUNT; i++)); do gexec "$KEY" true >/dev/null; done
sleep 3
after=$(usage)
t1=$(date +%s.%N)
# idle slice CPU over the same span (worker idle + standbys parked): measured after, same length
idle_before=$(usage)
sleep "$(python3 -c "print(round($t1 - $t0, 1))")"
idle_after=$(usage)
python3 -c 'import json,sys; a=sys.argv; print(json.dumps({"execs": int(a[1]), "warm_skip": int(a[2]),
  "slice_cpu_usec_before": int(a[3]), "slice_cpu_usec_after": int(a[4]), "span_s": float(a[6]) - float(a[5]),
  "idle_cpu_usec_same_span": int(a[8]) - int(a[7]), "command": "true"}))' \
  "$COUNT" "$WARM" "$before" "$after" "$t0" "$t1" "$idle_before" "$idle_after" >"$OUTDIR/bench.json"
