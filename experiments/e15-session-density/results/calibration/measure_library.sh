#!/usr/bin/env bash
# e15/results/calibration/measure_library.sh -- SPEC §10.1 step 2, run on the rig after setup.sh.
#
# Runs every library invocation REPS times inside ONE E15 VM: the resident worker
# (E15_RESIDENT=1, IDLE_S=0) keeps the VM its first Exec acquired for the workspace key, so every
# rep is one Exec on the same 1024 MiB E15-snapshot VM over one seeded workspace (a reflink copy of
# /srv/e15/template/workspace.img). Order: rep-major (every invocation once, then again).
#
# Timing is taken inside the guest, so VM lifecycle and the relay hop are excluded: a python3
# wrapper runs `bash -c CMD` (cwd /workspace, as the guest agent runs it) with stdout/stderr into a
# pipe it drains, and reports
#   run_ms = wall time (time.perf_counter) around subprocess.run
#   cpu_ms = delta of resource.getrusage(RUSAGE_CHILDREN) utime+stime across the same call
#            (bash and every descendant it waited for)
# Output: one JSON line per rep in OUT (default /srv/e15/calibration/library-raw.jsonl).
set -euo pipefail
E15_PROG=measure_library.sh
. /srv/e15/src/e15/rig/lib.sh
REPS=${REPS:-5}
OUTDIR=${OUTDIR:-/srv/e15/calibration}
OUT=$OUTDIR/library-raw.jsonl
LIB=$E15_SRC/commands/library.json
KEY=e15-calib-lib
mkdir -p "$OUTDIR/worker"
: >"$OUT"

trap stop_rung_units EXIT
stop_rung_units
sudo -n rm -rf "$E15_WORKSPACES/$KEY"
sudo -n mkdir -m 0700 "$E15_WORKSPACES/$KEY"
sudo -n cp --reflink=always "$E15_TEMPLATE" "$E15_WORKSPACES/$KEY/workspace.img"
sudo -n chmod 0600 "$E15_WORKSPACES/$KEY/workspace.img"
start_worker resident-inf "$OUTDIR/worker"

WRAP=$(cat <<'PY'
import json, resource, subprocess, sys, time
cmd = sys.argv[1]
r0 = resource.getrusage(resource.RUSAGE_CHILDREN)
t0 = time.perf_counter()
p = subprocess.run(["bash", "-c", cmd], cwd="/workspace", stdout=subprocess.PIPE, stderr=subprocess.PIPE)
t1 = time.perf_counter()
r1 = resource.getrusage(resource.RUSAGE_CHILDREN)
cpu = (r1.ru_utime - r0.ru_utime) + (r1.ru_stime - r0.ru_stime)
print(json.dumps({"exit": p.returncode, "run_ms": (t1 - t0) * 1000.0, "cpu_ms": cpu * 1000.0,
                  "out_bytes": len(p.stdout), "err_tail": p.stderr[-200:].decode("utf-8", "replace")}))
PY
)

# Probe: guest facts recorded with the raw data.
gexec "$KEY" 'echo "time=$(command -v time; ls /usr/bin/time 2>&1)"; python3 --version; nproc; cat /proc/meminfo | head -2; pwd' >"$OUTDIR/guest-probe.txt" 2>&1 || true

mapfile -t ROWS < <(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
for c,l in d["classes"].items():
    for i in l: print(json.dumps({"class":c,"id":i["id"],"cmd":i["cmd"],"exit":i["exit"]}))' "$LIB")
for ((rep = 1; rep <= REPS; rep++)); do
  for row in "${ROWS[@]}"; do
    cmd=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["cmd"])' "$row")
    gcmd="python3 -c $(printf '%q' "$WRAP") $(printf '%q' "$cmd")"
    res=$(gexec "$KEY" "$gcmd" 2>/dev/null | tail -n 1) || res='{"exit":-1,"transport_error":true}'
    python3 -c 'import json,sys; row=json.loads(sys.argv[1]); res=json.loads(sys.argv[2]); row["expected_exit"]=row.pop("exit"); row["rep"]=int(sys.argv[3]); row.update(res); print(json.dumps(row))' \
      "$row" "$res" "$rep" >>"$OUT" || echo "{\"rep\":$rep,\"bad\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$res")}" >>"$OUT"
  done
  log "rep $rep done"
done
# The workspace after the run: project clean (the library's own invariant).
gexec "$KEY" 'cd project && git status --porcelain && echo CLEAN_CHECK_DONE' >"$OUTDIR/post-status.txt" 2>&1 || true
grep -c 'vmpool: restore phases' "$OUTDIR/worker/worker.log" >"$OUTDIR/vm-restores.txt" || true
