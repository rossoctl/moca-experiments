#!/usr/bin/env bash
# e15/rig/rung.sh ARM N POINT -- one rung (SPEC §10.2): fresh worker, fresh workspaces, driver,
# sampler, record.
#
#   ARM    sbx | resident-inf | resident-300 | control
#   N      session population (>= 1)
#   POINT  default | short | long | no-infra | no-chains | smoke   (corpus /srv/e15/corpora/POINT)
#
# Environment (defaults are SPEC §10.2's):
#   E15_WARMUP_S 600   E15_WINDOW_S 900   E15_SPREAD_S 60   E15_GRACE_S 300   E15_SEED 1
#   E15_TAG            suffix for the rung directory (ladder.sh uses "repeat")
#   E15_BASELINE_P95_MS  override the N=1 baseline (otherwise read from the N1 rung's record.json:
#                      this point's, else the default point's)
#
# Steps:
#   1. stop any rung units left over; wipe /srv/e15/workspaces and /srv/e15/jail (E15's own)
#   2. pre-create /srv/e15/workspaces/<key>/workspace.img by `cp --reflink=always` of the template
#      for key = e15-<run>-<slot>-<seq>, slot 0..N-1, seq 0..K-1,
#      K = ceil((warmup_s + window_s) / (corpus mean session span)) + 3
#   3. start the arm's worker (e15-worker.service in e15-vms.slice; SPEC §7 env; lib.sh worker_env)
#      or, for control, the null-responder on 127.0.0.1:9645
#   4. start sample.sh and e15-driver together (sampler origin = the epoch just before the driver
#      is exec'd); after the run re-base samples.jsonl t onto the driver's t0_epoch, which becomes
#      rung_start_ts (see "time origin")
#   5. on driver exit: stop sampler and worker (SIGTERM; the pool destroys its VMs), kill any VM
#      cgroup left, normalise worker.log timestamps to ISO-8601 UTC (raw copy kept)
#   6. params.json (every parameter, hashes, commits; unseeded_sessions) and analysis/record.py
#
# Output: /srv/e15/runs/<POINT>/<ARM>/N<N>[-<TAG>]/ with calls.jsonl sessions.jsonl
# driver-cpu.jsonl samples.jsonl worker.log worker.env driver.log params.json record.json.
# Exit: 0 when record.json was written (whatever holds says), 1 on a rig error, 2 on bad usage.
set -euo pipefail
E15_PROG=rung.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

usage() {
  echo "usage: rung.sh ARM N POINT   (ARM: ${E15_ARMS[*]})" >&2
  exit 2
}
[ $# -eq 3 ] || usage
ARM=$1
N=$2
POINT=$3
e15_is_arm "$ARM" || {
  echo "rung.sh: unknown ARM '$ARM'" >&2
  usage
}
[[ "$N" =~ ^[1-9][0-9]*$ ]] || {
  echo "rung.sh: N must be a positive integer, got '$N'" >&2
  usage
}
arms=$(e15_point_arms "$POINT") || {
  echo "rung.sh: unknown POINT '$POINT'" >&2
  usage
}
case " $arms " in *" $ARM "*) ;; *)
  echo "rung.sh: POINT $POINT does not run ARM $ARM (SPEC §10.3)" >&2
  exit 2
  ;;
esac

WARMUP=${E15_WARMUP_S:-600}
K_MULT=${E15_K_MULT:-1}
[[ "$K_MULT" =~ ^[1-9][0-9]*$ ]] || {
  echo "rung.sh: E15_K_MULT must be a positive integer" >&2
  exit 2
}

# The N=1 baseline (SPEC §8 condition 4) is a prerequisite for N > 1, resolved before anything
# runs: E15_BASELINE_P95_MS, else this point's N1 record, else the default point's. A rung
# without one is a rig error, not a rung that "holds" with condition 4 unevaluated.
baseline=${E15_BASELINE_P95_MS:-}
baseline_src="env"
if [ "$N" = 1 ]; then
  baseline=null
  baseline_src=none
elif [ -z "$baseline" ]; then
  # Most recent valid run first: ladder.sh's tags do not compose (a repeat after a K-doubled
  # re-run is still N1-repeat), so N1-repeat, then N1-k2, then N1.
  for cand in "$E15_RUNS/$POINT/$ARM"/N1{-repeat,-k2,}/record.json "$E15_RUNS/default/$ARM"/N1{-repeat,-k2,}/record.json; do
    if [ -f "$cand" ]; then
      baseline=$(python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get("p95_added_ms"); print("" if v is None else v)' "$cand")
      baseline_src=$cand
      break
    fi
  done
  [ -n "$baseline" ] || die "no N=1 baseline p95 for $ARM (point $POINT or default; or E15_BASELINE_P95_MS): run N=1 first"
fi
[ "$baseline" = null ] || python3 -c 'import sys; float(sys.argv[1])' "$baseline" 2>/dev/null ||
  die "baseline p95 '$baseline' is not a number"
WINDOW=${E15_WINDOW_S:-900}
SPREAD=${E15_SPREAD_S:-60}
GRACE=${E15_GRACE_S:-300}
SEED=${E15_SEED:-1}
TAG=${E15_TAG:-}
CORPUS_DIR=$E15_CORPORA/$POINT
CORPUS=$CORPUS_DIR/corpus.jsonl
LIBRARY=$E15_SRC/commands/library.json
[ -f "$CORPUS" ] || die "no corpus $CORPUS"
[ -f "$LIBRARY" ] || die "no library $LIBRARY"
[ -x "$E15_BIN/e15-driver" ] || die "no $E15_BIN/e15-driver (run setup.sh)"
[ -f "$E15_TEMPLATE" ] || die "no workspace template $E15_TEMPLATE (run setup.sh)"
if [ "$ARM" != control ]; then
  unit_active "$E15_UNIT_RELAY" || die "$E15_UNIT_RELAY is not running (run setup.sh)"
fi

DIR=$E15_RUNS/$POINT/$ARM/N$N${TAG:+-$TAG}
if [ -e "$DIR" ]; then
  mv "$DIR" "$DIR.prev-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$DIR"
RUN_ID="$POINT-$ARM-n$N${TAG:+-$TAG}-$(date -u +%s)"
log "rung $ARM N=$N point=$POINT warmup=${WARMUP}s window=${WINDOW}s -> $DIR"

cleanup() {
  [ -n "${sampler_pid:-}" ] && kill "$sampler_pid" 2>/dev/null
  [ -n "${driver_pid:-}" ] && kill "$driver_pid" 2>/dev/null
  stop_rung_units
}
trap cleanup EXIT

# --- 1-2. fresh worker state and workspaces --------------------------------------------------
stop_rung_units
refuse_shared_paths "$E15_WORKSPACES" "$E15_JAIL"
sudo -n find "$E15_WORKSPACES" "$E15_JAIL" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
span_min=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["table"]["mean_span_min"])' "$CORPUS_DIR/corpus-report.json")
K=$(python3 -c 'import math,sys; w,s=float(sys.argv[1]),float(sys.argv[2])*60; print((int(math.ceil(w/s))+3)*int(sys.argv[3]))' "$((WARMUP + WINDOW))" "$span_min" "$K_MULT")
log "pre-creating $((N * K)) reflink workspaces (K=$K, mean span ${span_min} min)"
sudo -n bash -c '
  set -e
  ws=$1 tpl=$2 run=$3 n=$4 k=$5
  for ((s = 0; s < n; s++)); do
    for ((q = 0; q < k; q++)); do
      d="$ws/e15-$run-$s-$q"
      mkdir -m 0700 "$d"
      cp --reflink=always "$tpl" "$d/workspace.img"
      chmod 0600 "$d/workspace.img"
    done
  done' _ "$E15_WORKSPACES" "$E15_TEMPLATE" "$RUN_ID" "$N" "$K"

# OOM kills anywhere in e15.slice over the rung (SPEC §7.2: an OOM kill fails the rung).
oom_count() { awk '$1=="oom_kill"{print $2; f=1} END{if(!f) print 0}' "$E15_CG/memory.events" 2>/dev/null || echo 0; }
oom_before=$(oom_count)

# --- 3. the arm's backend --------------------------------------------------------------------
if [ "$ARM" = control ]; then
  start_null "$DIR"
  TARGET=127.0.0.1:$E15_PORT_NULL
else
  start_worker "$ARM" "$DIR"
  TARGET=127.0.0.1:$E15_PORT_EXEC
fi

# --- 4. driver + sampler ---------------------------------------------------------------------
end_flag=()
case "$ARM" in resident-inf | resident-300) end_flag=(--end-session-exec) ;; esac
launch_ts=$(date +%s.%N)
# The sampler starts with the driver, its origin the epoch just before the driver is exec'd
# (rung_start_ts as first taken). See "time origin" below for the re-base onto the driver's t0.
bash "$HERE/sample.sh" "$DIR/samples.jsonl" "$launch_ts" "$((WARMUP + WINDOW + 120))" &
sampler_pid=$!
MOCA_RELAY_EXEC_TOKEN=$(cat "$E15_SECRETS/exec.token") "$E15_BIN/e15-driver" \
  --corpus "$CORPUS" --library "$LIBRARY" --seed "$SEED" --n "$N" \
  --warmup-s "$WARMUP" --window-s "$WINDOW" --spread-s "$SPREAD" --grace-s "$GRACE" \
  --target "$TARGET" --sandbox-id e15 --run-id "$RUN_ID" --out "$DIR" "${end_flag[@]}" \
  >"$DIR/driver.log" 2>&1 &
driver_pid=$!
driver_exit=0
wait "$driver_pid" || driver_exit=$?
driver_pid=""
kill "$sampler_pid" 2>/dev/null || true
wait "$sampler_pid" 2>/dev/null || true
sampler_pid=""

# Time origin. The driver loads and validates the corpus and library (seconds for a full corpus)
# before t0, so the pre-exec epoch is NOT within record.py's 2 s of t0. The driver's header
# t0_epoch is the contract's origin: samples.jsonl t is re-based onto it (each sample keeps its
# wall-clock ts, and t_launch, its t from the launch epoch), and rung_start_ts is t0_epoch, provided
# t0_epoch falls between the launch and launch + 120 s. Otherwise rung_start_ts stays the launch
# epoch, so record.py's mismatch check fires and the rung cannot hold.
rung_start_ts=$(python3 - "$DIR" "$launch_ts" <<'PY'
import json, os, sys
d, launch = sys.argv[1], float(sys.argv[2])
t0 = None
try:
    with open(os.path.join(d, "driver-cpu.jsonl")) as f:
        first = json.loads(f.readline())
        t0 = first.get("t0_epoch") if first.get("header") else None
except (OSError, ValueError):
    pass
if t0 is None or not (launch <= t0 <= launch + 120):
    print(repr(launch))
    sys.exit(0)
p = os.path.join(d, "samples.jsonl")
rows = []
if os.path.exists(p):
    for line in open(p):
        try:
            r = json.loads(line)
        except ValueError:
            continue
        r["t_launch"] = r["t"]
        r["t"] = round(r["ts"] - t0, 3)
        rows.append(r)
    with open(p, "w") as f:
        for r in rows:
            f.write(json.dumps(r, separators=(",", ":")) + "\n")
print(repr(t0))
PY
)
log "driver exit $driver_exit"

# --- 5. stop the backend, normalise the log --------------------------------------------------
oom_after=$(oom_count)
stop_rung_units
trap - EXIT
if [ -f "$DIR/worker.log" ]; then
  sudo -n chown "$(id -un):$(id -gn)" "$DIR/worker.log"
  cp "$DIR/worker.log" "$DIR/worker.raw.log"
  # Go's log prefix "2026/11/01 23:16:40 " (the unit runs with TZ=UTC) -> ISO-8601 with Z, so
  # record.py can scope refusals to the measured window.
  sed -E -i 's#^([0-9]{4})/([0-9]{2})/([0-9]{2}) ([0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?) #\1-\2-\3T\4Z #' "$DIR/worker.log"
fi

# --- 6. params + record ----------------------------------------------------------------------

commit_file=$E15_ROOT/src/COMMIT
python3 - "$DIR" <<PY
import hashlib, json, os, sys
d = sys.argv[1]
def sha(p):
    try:
        with open(p, "rb") as f:
            h = hashlib.sha256()
            for b in iter(lambda: f.read(1 << 20), b""):
                h.update(b)
        return h.hexdigest()
    except OSError:
        return None
def readf(p):
    try:
        return open(p).read().strip()
    except OSError:
        return None
pre = set()
ws = "$E15_WORKSPACES"
run = "$RUN_ID"
for s in range($N):
    for q in range($K):
        pre.add("e15-%s-%d-%d" % (run, s, q))
keys = set()
try:
    for line in open(os.path.join(d, "calls.jsonl")):
        try:
            keys.add(json.loads(line)["session"])
        except (ValueError, KeyError):
            pass
except OSError:
    pass
env = {}
for line in (readf(os.path.join(d, "worker.env")) or "").splitlines():
    if "=" in line:
        k, v = line.split("=", 1)
        env[k] = v
report = json.load(open("$CORPUS_DIR/corpus-report.json"))
snap = None
try:
    snap = json.load(open("$E15_SNAPDIR/$E15_SNAPIMG/manifest.json"))
except (OSError, ValueError):
    pass
arm = "$ARM"
wbin = {"sbx": "$E15_BIN/microvm-worker", "resident-inf": "$E15_BIN/microvm-worker-resident",
        "resident-300": "$E15_BIN/microvm-worker-resident"}.get(arm)
baseline = json.loads("$baseline")
p = {
    "arm": arm, "n": $N, "point": "$POINT", "seed": $SEED, "run_id": run,
    "warmup_s": $WARMUP, "window_s": $WINDOW, "spread_s": $SPREAD, "grace_s": $GRACE,
    "floor_mb": $E15_FLOOR_MB, "driver_exit": $driver_exit,
    "rung_start_ts": float("$rung_start_ts"), "launch_ts": float("$launch_ts"),
    "driver_load_s": float("$rung_start_ts") - float("$launch_ts"),
    "baseline_p95_ms": baseline, "baseline_source": "$baseline_src",
    "workspaces_per_slot": $K, "workspaces_k_mult": $K_MULT, "workspaces_precreated": len(pre),
    "oom_kills": $oom_after - $oom_before,
    "unseeded_sessions": len(keys - pre), "sessions_started": len(keys),
    "workspace_seeding": "cp --reflink=always of the template per key before t0",
    "corpus": "$CORPUS", "corpus_sha256": sha("$CORPUS"), "H_s": report.get("H_s"),
    "corpus_exclude": report.get("exclude"), "corpus_mean_span_min": report["table"]["mean_span_min"],
    "library_sha256": sha("$LIBRARY"),
    "template_sha256": readf("$E15_STATE/template"),
    "moca_commit": "$E15_MOCA_PIN",
    "moca_experiments_commit": readf("$commit_file"),
    "resident_patch_sha256": sha("$E15_SRC/resident/resident.patch") if arm.startswith("resident") else None,
    "worker_bin_sha256": sha(wbin) if wbin else None,
    "driver_bin_sha256": sha("$E15_BIN/e15-driver"),
    "snapshot_hash": snap and snap.get("hash"), "snapshot_guest_ram_mb": snap and snap.get("guest_ram_mb"),
    "worker_env": env,
    "end_session_exec": arm in ("resident-inf", "resident-300"),
    "host_mem_total_kb": int([l.split()[1] for l in open("/proc/meminfo") if l.startswith("MemTotal:")][0]),
    "slice_memory_max": readf("$E15_CG/memory.max"),
}
json.dump(p, open(os.path.join(d, "params.json"), "w"), indent=2, sort_keys=True)
PY
holds=$(python3 "$E15_SRC/analysis/record.py" "$DIR" --params "$DIR/params.json") ||
  die "record.py failed for $DIR"
log "rung $ARM N=$N: holds=$holds ($DIR/record.json)"
