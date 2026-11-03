#!/usr/bin/env bash
# e15/rig/rung.sh ARM N POINT -- one rung (SPEC §10.2): fresh worker, fresh workspaces, driver,
# sampler, record.
#
#   ARM    sbx | resident-inf | resident-300 | control
#   N      session population (>= 1)
#   POINT  default | short | long | no-infra | no-chains | smoke | mem512   (points.sh: corpus
#          /srv/e15/corpora/<its corpus>, library, workspace template, image size)
#
# Environment (defaults are SPEC §10.2's):
#   E15_WARMUP_S 600   E15_WINDOW_S 900   E15_SPREAD_S 60   E15_GRACE_S 300   E15_SEED 1
#   E15_TAG            suffix for the rung directory (ladder.sh uses "repeat")
#   E15_CORPUS_OVERRIDE  a probe corpus.jsonl to replay instead of POINT's (classprobe.sh)
#   E15_START_ZERO     1: every session starts at its first call (probe runs)
#   E15_MAX_SESSIONS   start at most this many sessions, then end the run early (probe runs)
# The N=1 baseline is the pooled N1/baseline.json that baseline.sh writes (see "the N=1 baseline").
#
# Steps:
#   1. stop any rung units left over; wipe /srv/e15/workspaces and /srv/e15/jail (E15's own)
#   2. pre-create /srv/e15/workspaces/<key>/workspace.img by `cp --reflink=always` of the template
#      (or `cp --sparse=always` where setup.sh recorded state/workspace_copy=sparse: ext4, no reflink)
#      for key = e15-<run>-<slot>-<seq>, slot 0..N-1, seq 0..K-1,
#      K = max(16, ceil((warmup_s + window_s) / (corpus mean session span)) + 3) x K_MULT
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
# shellcheck source=points.sh
. "$HERE/points.sh"

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
e15_point "$POINT" || {
  echo "rung.sh: unknown POINT '$POINT'" >&2
  usage
}
case " $E15_P_ARMS " in *" $ARM "*) ;; *)
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

WINDOW=${E15_WINDOW_S:-900}
SPREAD=${E15_SPREAD_S:-60}
GRACE=${E15_GRACE_S:-300}
SEED=${E15_SEED:-1}
TAG=${E15_TAG:-}
CORPUS_DIR=$E15_CORPORA/$E15_P_CORPUS
CORPUS=$CORPUS_DIR/corpus.jsonl
# E15_CORPUS_OVERRIDE: a probe corpus.jsonl (classprobe.sh); its directory holds the matching
# corpus-report.json. E15_START_ZERO=1 makes every session start at call 0 (driver --start-at-zero).
if [ -n "${E15_CORPUS_OVERRIDE:-}" ]; then
  CORPUS=$E15_CORPUS_OVERRIDE
  CORPUS_DIR=$(dirname "$CORPUS")
fi
start_flag=()
[ "${E15_START_ZERO:-0}" = 1 ] && start_flag+=(--start-at-zero)
# mem512: the driver's once-per-call scan step (points.sh)
scan_flag=()
[ -z "$E15_P_SCAN_CMD" ] || scan_flag=(--scan-cmd "$E15_P_SCAN_CMD" --scan-classes "$E15_P_SCAN_CLASSES")
[ -n "${E15_MAX_SESSIONS:-}" ] && start_flag+=(--max-sessions "$E15_MAX_SESSIONS")
LIBRARY=$E15_P_LIBRARY
TEMPLATE=$E15_P_TEMPLATE
DRIVER=$E15_BIN/e15-driver
[ -f "$CORPUS" ] || die "no corpus $CORPUS"
[ -f "$LIBRARY" ] || die "no library $LIBRARY"
[ -x "$DRIVER" ] || die "no $DRIVER (run setup.sh)"

# --- the N=1 baseline (SPEC §8 condition 4) ----------------------------------------------------
# Condition 4 is class-matched: N > 1 needs the pooled N1/baseline.json that baseline.sh writes
# (per-class medians from the class probe). It is this point's, or -- only when this point has no
# pooled runs of its own -- the default point's. A baseline.json measured with another library or
# driver binary (or, for this point's own, another corpus) is stale: the rung dies with the reason.
# The point signature (points.sh e15_point_sig: point name, corpus, library, template, dataset and
# scan settings) is checked too: mem512 shares default's library and corpus, so only it keeps the
# two points' baselines apart. mem512 never falls back: it needs its own (baseline.sh mem512 ARM).
# A rung without a baseline is a rig error, not a rung that "holds" with condition 4 unevaluated.
# The control arm (null responder) is exempt at every N: it checks A2 and transport only.
baseline_path=null
baseline_src=none
if [ "$ARM" = control ]; then
  baseline_src="none (control: A2 and transport only)"
elif [ "$N" != 1 ]; then
  sha_of() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
  lib_sha=$(sha_of "$LIBRARY")
  drv_sha=$(sha_of "$DRIVER")
  corpus_sha=$(sha_of "$CORPUS")
  cand="$E15_RUNS/$POINT/$ARM/N1/baseline.json"
  want_corpus=$corpus_sha
  want_sig=$(e15_point_sig "$POINT")
  # Only a point with E15_P_FALLBACK=1 (points.sh) may borrow the default point's baseline; mem512
  # (same library and corpus as default, plus the scan) never does, and the point signature would
  # refuse it anyway.
  if [ ! -f "$cand" ] && [ "$E15_P_FALLBACK" = 1 ] &&
    [ -z "$(compgen -G "$E15_RUNS/$POINT/$ARM/N1-s*" || true)" ]; then
    cand="$E15_RUNS/default/$ARM/N1/baseline.json"
    want_corpus="" # the default point's baseline is a different corpus on purpose
    want_sig=$(e15_point_sig default)
  fi
  [ -f "$cand" ] || die "no N=1 baseline.json for $ARM matching point $POINT (run baseline.sh $POINT $ARM first)"
  stale=$(python3 -c '
import json, sys
cand, lib, drv, corpus, sig = sys.argv[1:6]
d = json.load(open(cand))
for k, want in (("library_sha256", lib), ("driver_bin_sha256", drv), ("corpus_sha256", corpus), ("point_sig", sig)):
    if want and d.get(k) != want:
        print("%s %s, this rung has %s" % (k, d.get(k), want))
        sys.exit(0)
for k in ("class_medians", "global_median_ms", "excess_p95_ms"):
    if k not in d:
        print("no %s (not a class-matched baseline)" % k)
        sys.exit(0)
if d.get("n1_median_pace") is None:
    print("n1_median_pace missing or null \u2014 re-run baseline.sh")
    sys.exit(0)' "$cand" "$lib_sha" "$drv_sha" "$want_corpus" "$want_sig")
  [ -z "$stale" ] || die "stale N=1 baseline $cand: $stale; re-run baseline.sh $POINT $ARM"
  baseline_path=\"$cand\"
  baseline_src=$cand
fi
# end baseline resolution
[ -f "$TEMPLATE" ] || die "no workspace template $TEMPLATE for point $POINT (run setup.sh)"
if [ "$ARM" != control ]; then
  unit_active "$E15_UNIT_RELAY" || die "$E15_UNIT_RELAY is not running (run setup.sh)"
fi

DIR=$E15_RUNS/$POINT/$ARM/N$N${TAG:+-$TAG}
prev_dir=""
if [ -e "$DIR" ]; then
  prev_dir="$DIR.prev-$(date -u +%Y%m%dT%H%M%SZ)"
  mv "$DIR" "$prev_dir"
fi
mkdir -p "$DIR"
# baseline.sh's pooled N1/baseline.json is not this rung's output: it stays where rung.sh reads it.
if [ -n "$prev_dir" ] && [ -f "$prev_dir/baseline.json" ]; then
  cp -p "$prev_dir/baseline.json" "$DIR/baseline.json"
fi
RUN_ID="$POINT-$ARM-n$N${TAG:+-$TAG}-$(date -u +%s)"
log "rung $ARM N=$N point=$POINT warmup=${WARMUP}s window=${WINDOW}s -> $DIR"

cleanup() {
  [ -n "${sampler_pid:-}" ] && kill "$sampler_pid" 2>/dev/null
  [ -n "${watchdog_pid:-}" ] && kill "$watchdog_pid" 2>/dev/null
  [ -n "${driver_pid:-}" ] && kill "$driver_pid" 2>/dev/null
  stop_rung_units
}
trap cleanup EXIT

# --- 1-2. fresh worker state and workspaces --------------------------------------------------
stop_rung_units
refuse_shared_paths "$E15_WORKSPACES" "$E15_JAIL"
sudo -n find "$E15_WORKSPACES" "$E15_JAIL" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
span_min=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["table"]["mean_span_min"])' "$CORPUS_DIR/corpus-report.json")
K=$(python3 -c 'import math,sys; w,s=float(sys.argv[1]),float(sys.argv[2])*60; print(max(16, (int(math.ceil(w/s))+3)*int(sys.argv[3])))' "$((WARMUP + WINDOW))" "$span_min" "$K_MULT")
WS_COPY=$(workspace_copy_mode)
if [ "$WS_COPY" = sparse ]; then
  # Sparse copies share nothing: each costs the template's allocated blocks now, and up to its
  # full image size if a guest writes it all. The operator checks the free space against this.
  tpl_kb=$(du -k "$TEMPLATE" | cut -f1)
  free_kb=$(df -Pk "$E15_WORKSPACES" | awk 'NR==2 {print $4}')
  est=$(workspace_disk_estimate "$N" "$K" "$E15_P_IMAGE_MB" "$tpl_kb" "$free_kb") ||
    die "not enough disk for $((N * K)) sparse workspaces: $est"
  log "workspaces (sparse): $est"
fi
log "pre-creating $((N * K)) $WS_COPY workspaces (K=$K, mean span ${span_min} min)"
sudo -n bash -c '
  set -e
  ws=$1 tpl=$2 run=$3 n=$4 k=$5 cpf=$6
  for ((s = 0; s < n; s++)); do
    for ((q = 0; q < k; q++)); do
      d="$ws/e15-$run-$s-$q"
      mkdir -m 0700 "$d"
      cp "$cpf" "$tpl" "$d/workspace.img"
      chmod 0600 "$d/workspace.img"
    done
  done' _ "$E15_WORKSPACES" "$TEMPLATE" "$RUN_ID" "$N" "$K" "$(workspace_cp_flag "$WS_COPY")"

# OOM kills anywhere in e15.slice over the rung (SPEC §7.2: an OOM kill fails the rung).
oom_count() { awk '$1=="oom_kill"{print $2; f=1} END{if(!f) print 0}' "$E15_CG/memory.events" 2>/dev/null || echo 0; }
oom_before=$(oom_count)

# --- 3. the arm's backend --------------------------------------------------------------------
if [ "$ARM" = control ]; then
  start_null "$DIR"
  TARGET=127.0.0.1:$E15_PORT_NULL
else
  start_worker "$ARM" "$DIR" "$E15_P_IMAGE_MB"
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
  --target "$TARGET" --sandbox-id e15 --run-id "$RUN_ID" --out "$DIR" "${end_flag[@]}" "${start_flag[@]}" "${scan_flag[@]}" \
  >"$DIR/driver.log" 2>&1 &
driver_pid=$!
# Memory watchdog (Task 8 mem512 OOM incident): host MemAvailable below E15_MEMAVAIL_FLOOR_MIB
# (default 1024) for 3 consecutive 1 s samples kills every E15 VM and aborts the rung before the
# host's global OOM killer can reach processes outside e15.slice. The rung then records
# memory_abort and record.py reports holds=false, binding memory_floor.
memabort_marker=$DIR/memory-abort
rm -f "$memabort_marker"
(memavail_watchdog "$memabort_marker" && kill "$driver_pid" 2>/dev/null) &
watchdog_pid=$!
driver_exit=0
wait "$driver_pid" || driver_exit=$?
driver_pid=""
kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true
watchdog_pid=""
memory_abort=null
if [ -s "$memabort_marker" ]; then
  memory_abort=$(python3 -c 'import json,sys; w=open(sys.argv[1]).read().split(); print(json.dumps({"reason": w[0], "at": w[1], "mem_available_kb": int(w[2]), "floor_mib": int(sys.argv[2])}))' "$memabort_marker" "${E15_MEMAVAIL_FLOOR_MIB:-1024}")
  log "memory watchdog tripped: $(cat "$memabort_marker"); E15 VMs killed, rung aborted"
fi
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
baseline_path = json.loads('$baseline_path')
p = {
    "arm": arm, "n": $N, "point": "$POINT", "seed": $SEED, "run_id": run,
    "warmup_s": $WARMUP, "window_s": $WINDOW, "spread_s": $SPREAD, "grace_s": $GRACE,
    "floor_mb": $E15_FLOOR_MB, "driver_exit": $driver_exit,
    "rung_start_ts": float("$rung_start_ts"), "launch_ts": float("$launch_ts"),
    "driver_load_s": float("$rung_start_ts") - float("$launch_ts"),
    "baseline_path": baseline_path, "baseline_source": "$baseline_src",
    "workspaces_per_slot": $K, "workspaces_k_mult": $K_MULT, "workspaces_precreated": len(pre),
    "oom_kills": $oom_after - $oom_before,
    "memory_abort": json.loads("""$memory_abort"""),
    "unseeded_sessions": len(keys - pre), "sessions_started": len(keys),
    "workspace_seeding": "cp $(workspace_cp_flag "$WS_COPY") of the template per key before t0",
    "workspace_copy": "$WS_COPY", "host_profile": "$E15_HOST_PROFILE",
    "corpus": "$CORPUS", "corpus_sha256": sha("$CORPUS"), "H_s": report.get("H_s"),
    "corpus_exclude": report.get("exclude"), "corpus_mean_span_min": report["table"]["mean_span_min"],
    "library_sha256": sha("$LIBRARY"),
    "template_sha256": readf("$E15_STATE/$E15_P_TEMPLATE_STAMP"),
    "template": "$TEMPLATE", "workspace_image_mb": $E15_P_IMAGE_MB,
    "dataset_mib": $E15_P_DATASET_MIB, "dataset_seed": $E15_P_DATASET_SEED,
    "scan_classes": [c for c in "$E15_P_SCAN_CLASSES".split(",") if c], "scan_cmd": "$E15_P_SCAN_CMD",
    "point_sig": "$(e15_point_sig "$POINT")", "point_settings": "$E15_P_SETTINGS",
    "disk_read_max_mbs": (lambda v: float(v) if v else None)(readf("$E15_STATE/disk_read_max_mbs")),
    "disk_read_single_mbs": (lambda v: float(v) if v else None)(readf("$E15_STATE/disk_read_single_mbs")),
    "library": "$LIBRARY",
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
