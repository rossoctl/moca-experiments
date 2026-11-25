#!/usr/bin/env bash
# experiments/e15-session-density/rig/rung.sh ARM N POINT -- one rung (SPEC §10.2): fresh worker, fresh workspaces, driver,
# sampler, record.
#
#   ARM    sbx | resident-inf | resident-300 | control | lease-30 | lease-120   (lease-*: E17, fresh-metal)
#          | ship-30 | ship-120 | ship-300   (E17b: E17B=1, fresh-metal; the shipped lease at that idle timeout)
#          | ship-300-nd   (E17c: E17C=1, fresh-metal; ship-300 with the idle page-cache drop off)
#          | ship-300-l2   (E17d: E17D=1, fresh-metal; ship-300 at lease+processes, the level-2 restart rule, library-l2.json)
#   N      session population (>= 1)
#   POINT  default | short | long | no-infra | no-chains | smoke | mem512 | lowduty   (points.sh: corpus
#          /srv/e15/corpora/<its corpus>, library, workspace template, image size)
#          | pycache | pycache-low | pycache-d64 | pycache-d768   (E17, fresh-metal)
#          | squeeze | squeeze-256   (E17b: E17B=1, fresh-metal; arms ship-300 and sbx; 1024 and 256 MiB guests)
#          | pycache-l2 | squeeze-l2   (E17d: E17D=1, fresh-metal; sbx ship-300 ship-300-l2, and ship-300 ship-300-l2)
#
# Environment (defaults are SPEC §10.2's):
#   E15_WARMUP_S 600 (fresh-metal resident arms 1200; lib.sh e15_default_warmup)   E15_WINDOW_S 900   E15_SPREAD_S 60   E15_GRACE_S 300   E15_SEED 1
#   E15_TAG            suffix for the rung directory (ladder.sh uses "repeat")
#   E15_CORPUS_OVERRIDE  a probe corpus.jsonl to replay instead of POINT's (classprobe.sh)
#   E15_START_ZERO     1: every session starts at its first call (probe runs)
#   E15_MAX_SESSIONS   start at most this many sessions, then end the run early (probe runs)
#   E17C_GATE_LIBRARY  E17c's gate-256 only (experiments/e17-lease/rig/chain-e17c.sh; E17C=1, POINT pycache-d64, with
#                      E15_CORPUS_OVERRIDE): the gate library replayed instead of the point's, and py_analyze's stdout
#                      (its peak RSS line) recorded too
#   E15_SQUEEZE_MEMMAX_MB  POINT squeeze or squeeze-256 only (E17b): lower e15.slice to MemoryMax=MB MiB, MemoryHigh 1 GiB below,
#                      with `systemctl set-property --runtime` before the worker starts; the slice's own values
#                      (read with `systemctl show` first) are restored at the rung's end and on any error or signal
#                      (EXIT trap). One manifest line, its UNDO the restore. Recorded in params.json.
# The N=1 baseline is the pooled N1/baseline.json that baseline.sh writes (see "the N=1 baseline").
#
# Steps:
#   1. stop any rung units left over; wipe /srv/e15/workspaces and /srv/e15/jail (E15's own)
#   2. pre-create /srv/e15/workspaces/<key>/workspace.img by `cp --reflink=always` of the template
#      (or `cp --sparse=always` where state/workspace_copy=sparse; fresh-metal requires reflink and
#      refuses a rung whose N*K per-session deltas + 10% exceed the workspaces' free space)
#      for key = e15-<run>-<slot>-<seq>, slot 0..N-1, seq 0..K-1,
#      K = max(16, ceil((warmup_s + window_s) / (corpus mean session span)) + 3) x K_MULT
#      (not control) restart E15's relay (e15-relay.service), so no stale worker session from a
#      previous rung makes it refuse this rung's worker
#   3. start the arm's worker (e15-worker.service in e15-vms.slice; SPEC §7 env; lib.sh worker_env)
#      and require one probe Exec to reach it through the relay within E15_ATTACH_TIMEOUT_S (60;
#      else exit 1, a rig error) -- on a workspace_key the worker refuses, so it starts no VM; or,
#      for control, the null-responder on 127.0.0.1:9645
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
# E17d profile (E17D=1, which implies E17C=1 and E17B=1): the same for E17D_MOCA_PIN, first.
[ "${E17D:-}" != 1 ] || e17d_require_pin
# E17c profile (E17C=1, which implies E17B=1): the same for E17C_MOCA_PIN, before the E17b checks.
[ "${E17C:-}" != 1 ] || e17c_require_pin
# E17b profile: refuse the placeholder or a malformed E17B_MOCA_PIN before any host change.
[ "${E17B:-}" != 1 ] || { e17b_require_pin && e17b_require_build; }

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

# E17b squeeze knob (points.sh squeeze): validated here, before any host change.
SQUEEZE_MB=${E15_SQUEEZE_MEMMAX_MB:-}
if [ -n "$SQUEEZE_MB" ]; then
  e15_is_squeeze "$POINT" || {
    echo "rung.sh: E15_SQUEEZE_MEMMAX_MB is for POINT squeeze or squeeze-256 only (got POINT $POINT)" >&2
    exit 2
  }
  [[ "$SQUEEZE_MB" =~ ^[1-9][0-9]*$ ]] && [ "$SQUEEZE_MB" -gt 8192 ] || {
    echo "rung.sh: E15_SQUEEZE_MEMMAX_MB must be an integer above 8192 (the committed budget is MemoryMax - 8192 MiB, E17B-R20), got '$SQUEEZE_MB'" >&2
    exit 2
  }
fi

# The squeeze points' D is for one guest RAM (E17B-R21): squeeze 1024 MiB (D=768), squeeze-256 256 MiB (D=192).
if e15_is_squeeze "$POINT"; then
  want_ram=1024
  [ "$POINT" != squeeze-256 ] || want_ram=256
  [ "$(worker_guest_ram_mb)" = "$want_ram" ] || {
    echo "rung.sh: POINT $POINT runs at E17B_GUEST_RAM_MB=$want_ram (its D keeps the dataset-to-RAM ratio), got ${E17B_GUEST_RAM_MB:-1024}" >&2
    exit 2
  }
fi
# E17c (PLAN-E17C Task 10): under E17C=1 pycache-d64 replays the 256 MiB library (points.sh), so it runs in 256 MiB
# guests only. gate-256's rungs replay a gate library (E17C_GATE_LIBRARY) there, from a probe corpus.
if [ "${E17C:-}" = 1 ] && [ "$POINT" = pycache-d64 ] && [ "$(worker_guest_ram_mb)" != 256 ]; then
  echo "rung.sh: POINT pycache-d64 runs at E17B_GUEST_RAM_MB=256 under E17C=1 (its library is library-256.json, SPEC §13.5), got ${E17B_GUEST_RAM_MB:-1024}" >&2
  exit 2
fi
if [ -n "${E17C_GATE_LIBRARY:-}" ] &&
  { [ "${E17C:-}" != 1 ] || [ "$POINT" != pycache-d64 ] || [ -z "${E15_CORPUS_OVERRIDE:-}" ]; }; then
  echo "rung.sh: E17C_GATE_LIBRARY is gate-256's (E17C=1, POINT pycache-d64, with E15_CORPUS_OVERRIDE): refusing" >&2
  exit 2
fi

WARMUP=${E15_WARMUP_S:-$(e15_default_warmup "$ARM")}
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
[ -z "${E17C_GATE_LIBRARY:-}" ] || LIBRARY=$E17C_GATE_LIBRARY # checked above: gate-256's rungs only
# E17d (E17D=1): ship-300-l2 replays library-l2.json (the level-2 client), every other arm the point's library.
[ "${E17D:-}" != 1 ] || LIBRARY=$(e17d_arm_library "$ARM" "$LIBRARY")
TEMPLATE=$E15_P_TEMPLATE
DRIVER=$E15_BIN/e15-driver
# E16 supplementary: E15_END_SESSION_DEFER=1 runs e15-driver-defer (the same source plus the opt-in
# --end-session-defer path, built beside it so the sealed e15-driver binary and its sha are never
# touched). The N=1 baseline is matched against the stock driver's sha: at N=1 the run-end
# deferral is the only difference and the baseline's runs never used it.
BASE_DRIVER=$DRIVER
if [ "$E15_HOST_PROFILE" = fresh-metal ] && [ "${E15_END_SESSION_DEFER:-0}" = 1 ]; then
  DRIVER=$E15_BIN/e15-driver-defer
fi
# E17b (E17B=1, ruling E17B-R4): every arm runs the -e17b driver binaries (setup.sh builds them); the sealed
# e15-driver and e15-driver-defer are never run, so their sha256 in the sealed records stay valid.
if [ "${E17B:-}" = 1 ]; then
  DRIVER=${DRIVER}-e17b
  BASE_DRIVER=${BASE_DRIVER}-e17b
fi
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
  drv_sha=$(sha_of "$BASE_DRIVER")
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
  # E17b (E17B-R17): the arm's snapshot leaf must exist before anything is stopped, wiped or restarted.
  e17b_require_snapshot
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

# rung_host_restore: undo this rung's own host state once its worker is stopped -- the squeezed e15.slice
# (E15_SQUEEZE_MEMMAX_MB) and the per-rung token key directory (E17b lease arms). Idempotent; never dies. Returns 1
# only when the slice could not be restored (a rig error at the rung's end); a key directory left with an unexpected
# file is logged (its token.key is removed first) and does not fail the rung.
#
# The key directory needs no manifest line: it is created and removed by this rung on every exit path (the end,
# die, a signal: the EXIT trap), inside $E15_ROOT/secrets (0700, the login user's), like the rung's workspaces,
# which rung.sh also creates and wipes without one. A rung killed with SIGKILL leaves it under $E15_SECRETS, which
# teardown.sh --purge removes with $E15_ROOT. relay-lease.env (the public keyset only) stays for the relay.
TOKEN_DIR=""
# Never from the caller's environment: only e15_slice_squeeze in this rung marks the slice squeezed.
E15_SQUEEZE_ACTIVE=0
E15_SQUEEZE_RESTORED=0
unset E15_SQUEEZE_ORIG_MAX E15_SQUEEZE_ORIG_HIGH E15_SQUEEZE_MAX E15_SQUEEZE_HIGH
rung_host_restore() {
  local rc=0
  e15_slice_unsqueeze || rc=1
  if [ -n "$TOKEN_DIR" ]; then
    e17b_token_dir_remove "$TOKEN_DIR" || true
    TOKEN_DIR=""
  fi
  return "$rc"
}
# The trap runs under set -e: a kill of a process that already exited, or a failing stop, must not end it before
# rung_host_restore (each step is guarded).
cleanup() {
  [ -z "${sampler_pid:-}" ] || kill "$sampler_pid" 2>/dev/null || true
  [ -z "${watchdog_pid:-}" ] || kill "$watchdog_pid" 2>/dev/null || true
  [ -z "${driver_pid:-}" ] || kill "$driver_pid" 2>/dev/null || true
  stop_rung_units || true
  rung_host_restore || true
}
trap cleanup EXIT

# The attach probe's workspace_key: one the worker's checkKey refuses ([A-Za-z0-9] must come first),
# so ExecPhased answers before it creates a run or a VM, on every arm (stock and resident). The
# reply, an in-stream "invalid-workspace-key" ExecError, can only come from a live, attached worker:
# with none, the relay itself fails the call ("no live worker for sandbox"). So the probe proves the
# relay routes to this rung's worker and leaves no VM, standby or run behind.
E15_PROBE_KEY=_e15-attach-probe
# relay_attach_probe TIMEOUT_S: 0 when one probe Exec gets the worker's invalid-workspace-key
# refusal within TIMEOUT_S (retried every 2 s); 2 when the worker ran it instead (the key was
# accepted: it would have cost a VM); 1 otherwise. The last attempt's output: $DIR/attach-probe.log.
relay_attach_probe() {
  local deadline=$((SECONDS + $1)) pid rc
  while [ "$SECONDS" -lt "$deadline" ]; do
    gexec "$E15_PROBE_KEY" true >"$DIR/attach-probe.log" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.5; done
    if kill -0 "$pid" 2>/dev/null; then
      pkill -P "$pid" 2>/dev/null || true
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 1
    fi
    rc=0
    wait "$pid" || rc=$?
    grep -q '^ExecError: invalid-workspace-key: ' "$DIR/attach-probe.log" && return 0
    [ "$rc" != 0 ] || return 2
    sleep 2
  done
  return 1
}

# --- 1-2. fresh worker state and workspaces --------------------------------------------------
stop_rung_units
refuse_shared_paths "$E15_WORKSPACES" "$E15_JAIL"
sudo -n find "$E15_WORKSPACES" "$E15_JAIL" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
span_min=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["table"]["mean_span_min"])' "$CORPUS_DIR/corpus-report.json")
K=$(python3 -c 'import math,sys; w,s=float(sys.argv[1]),float(sys.argv[2])*60; print(max(16, (int(math.ceil(w/s))+3)*int(sys.argv[3])))' "$((WARMUP + WINDOW))" "$span_min" "$K_MULT")
# fresh-metal: K_MULT multiplies the floored K (above, at the 123-min mean span the floor of 16 wins for
# any K_MULT <= 4, so doubling did nothing); aws-prelim keeps the sealed formula above.
[ "$E15_HOST_PROFILE" != fresh-metal ] ||
  K=$(python3 -c 'import math,sys; w,s=float(sys.argv[1]),float(sys.argv[2])*60; print(max(16, int(math.ceil(w / s)) + 3) * int(sys.argv[3]))' "$((WARMUP + WINDOW))" "$span_min" "$K_MULT")
WS_COPY=$(workspace_copy_mode)
if [ "$E15_HOST_PROFILE" = fresh-metal ]; then
  # Reflink is required there (setup.sh probes it on every run; no sparse fallback). Each copy is
  # estimated at the per-session delta (lib.sh workspace_delta_kb); the N*K copies + 10% must fit.
  [ "$WS_COPY" = reflink ] && [ -s "$E15_STATE/workspace_copy" ] ||
    die "fresh-metal: state/workspace_copy is not reflink (run setup.sh; reflink is required)"
  delta_kb=$(workspace_delta_kb "$TEMPLATE" "$E15_P_DATASET_MIB")
  free_kb=$(df -Pk "$E15_WORKSPACES" | awk 'NR==2 {print $4}')
  est=$(workspace_disk_estimate "$N" "$K" "$E15_P_IMAGE_MB" "$delta_kb" "$free_kb") ||
    die "not enough disk for $((N * K)) reflinked workspaces ($((delta_kb / 1024)) MiB delta each, +10%): $est"
  log "workspaces (reflink, $((delta_kb / 1024)) MiB delta each): $est"
elif [ "$WS_COPY" = sparse ]; then
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
# Relay hygiene: a worker that wedged mid-rung can leave the relay holding a stale session for
# sandbox "e15"; the relay refuses a duplicate worker Hello (sandbox-relay relay.ts sessions.has),
# so the next worker gets EOF on every call. Restart E15's own relay (e15-relay.service only; never
# an sh-* unit) after step 1 stopped the previous rung's units, before this rung's worker starts. Its
# log so far is kept in the rung directory.
if [ "$ARM" != control ]; then
  # The attach check below needs grpcurl (lib.sh gexec): resolve it before the relay is touched.
  # fresh-metal: bootstrap.sh's, in /srv/e15/bin. aws-prelim: whatever the ladder's PATH holds.
  [ "$E15_HOST_PROFILE" != fresh-metal ] || PATH="$E15_BIN:$PATH"
  command -v grpcurl >/dev/null 2>&1 ||
    die "no grpcurl on PATH ($PATH): rung.sh's relay attach check needs it (fresh-metal: run bootstrap.sh; aws-prelim: start the ladder with grpcurl on PATH); the relay was not touched"
  [ -f "$E15_LOGS/relay.log" ] && sudo -n cp "$E15_LOGS/relay.log" "$DIR/relay.before-restart.log"
  stop_e15_unit "$E15_UNIT_RELAY"
  # E17b lease arms: a fresh Ed25519 key per rung, minted by the -e17b driver; its public keyset and the fixed issuer
  # go to the relay in a per-rung env file, the private key stays in $E15_SECRETS for the driver's --token-key.
  relay_extra=""
  if e17b_lease_arm "$ARM"; then
    e17b_token_dir_ok "$E15_SECRETS/token-$RUN_ID" ||
      die "the key directory $E15_SECRETS/token-$RUN_ID is not a token-<run> leaf of $E15_SECRETS (E15_TAG '$TAG'?); nothing minted"
    TOKEN_DIR=$E15_SECRETS/token-$RUN_ID # removed by rung_host_restore at the rung's end or on any exit
    (umask 077 && "$DRIVER" mint-key --out "$TOKEN_DIR") >"$DIR/mint-key.log" 2>&1 ||
      die "e15-driver mint-key --out $TOKEN_DIR failed; see $DIR/mint-key.log"
    [ -s "$TOKEN_DIR/token.key" ] && [ -s "$TOKEN_DIR/token.pub" ] || die "mint-key left no token.key/token.pub in $TOKEN_DIR"
    relay_extra=$E15_SECRETS/relay-lease.env
    (umask 077 && printf 'SH_SANDBOX_TOKEN_PUBLIC_KEYS=%s\nSH_SANDBOX_TOKEN_ISSUER=%s\n' "$(cat "$TOKEN_DIR/token.pub")" "$(e17b_token_iss)" >"$relay_extra")
    log "lease token key minted for this rung ($TOKEN_DIR); relay trusts it (issuer $(e17b_token_iss))"
  fi
  start_relay "$relay_extra"
  sleep 3
  if grep -qs 'redis client error' "$E15_LOGS/relay.log"; then
    die "the restarted relay cannot reach Redis on 127.0.0.1:$E15_PORT_REDIS; see $E15_LOGS/relay.log"
  fi
  log "relay restarted ($E15_UNIT_RELAY)"
fi
# E17c (E17C=1, ship-* arms): the worker banner's lease_cache_drop= value, recorded in params.json (below).
lease_cache_drop=""
lease_cache_drop_rec=0
if [ "$ARM" = control ]; then
  start_null "$DIR"
  TARGET=127.0.0.1:$E15_PORT_NULL
else
  [ -z "$SQUEEZE_MB" ] || e15_slice_squeeze "$SQUEEZE_MB" "squeeze rung $RUN_ID"
  start_worker "$ARM" "$DIR" "$E15_P_IMAGE_MB"
  TARGET=127.0.0.1:$E15_PORT_EXEC
  # E17b (E17B=1): every arm runs on the lease-v1 snapshot at the pin (the ship arms need it; sbx must run on the
  # same one). The worker's startup banner (moca remote-worker/cmd/microvm-worker/main.go, leaseBanner) says lease=on
  # only when the snapshot advertises lease-v1 under firecracker, lease=off otherwise. Checked before the attach
  # probe and the driver, so a rung on the wrong snapshot measures nothing.
  if [ "${E17B:-}" = 1 ]; then
    banner=$(grep -m1 'microvm-worker: relay=' "$DIR/worker.log" || true)
    [ -n "$banner" ] || die "no startup banner ('microvm-worker: relay=...') in $DIR/worker.log: lease=on cannot be confirmed (E17B=1); the driver was not started"
    case " $banner " in
    *" lease=on "*) log "worker banner: lease=on (${banner#*lease=on})" ;;
    *" lease=off "*) die "the worker's banner says lease=off: the snapshot $E15_SNAPDIR/$(worker_snapimg) does not advertise lease-v1 (or the VMM is not firecracker); E17b arms need the snapshot-e17b.sh leaf. The driver was not started. Banner: $banner" ;;
    *) die "the worker's banner has no lease= field (a worker without lease mode?): $banner; the driver was not started" ;;
    esac
    # E17c (E17C=1, ruling R-a): a ship arm's banner must carry lease_cache_drop= (moca #974) and match the arm:
    # ship-300-nd needs off (SH_LEASE_CACHE_DROP_S=0), ship-300 exactly 30s (the worker's default: 5a's +45 s reading,
    # R-o, assumes it; final review M3), any other ship arm a drop that is on.
    if [ "${E17C:-}" = 1 ] && e17b_lease_arm "$ARM"; then
      case " $banner " in
      *" lease_cache_drop="*)
        lease_cache_drop=${banner#* lease_cache_drop=}
        lease_cache_drop=${lease_cache_drop%% *}
        ;;
      esac
      [ -n "$lease_cache_drop" ] ||
        die "the worker's banner has no lease_cache_drop= field (a worker before moca #974?): $banner; E17c arm $ARM cannot be confirmed. The driver was not started"
      if [ "$ARM" = ship-300-nd ]; then
        [ "$lease_cache_drop" = off ] ||
          die "the worker's banner says lease_cache_drop=$lease_cache_drop but $ARM needs off (SH_LEASE_CACHE_DROP_S=0 in $DIR/worker.env). The driver was not started. Banner: $banner"
      else
        [ "$lease_cache_drop" != off ] ||
          die "the worker's banner says lease_cache_drop=off but $ARM needs the drop on (SH_LEASE_CACHE_DROP_S unset: the worker's default). The driver was not started. Banner: $banner"
        # E17d's ship-300-l2 keeps the default too (spec §14.2: every arm keeps SH_LEASE_CACHE_DROP_S at 30 s)
        case "$ARM" in ship-300 | ship-300-l2) [ "$lease_cache_drop" = 30s ] ;; *) true ;; esac ||
          die "the worker's banner says lease_cache_drop=$lease_cache_drop but $ARM needs exactly 30s (the default 5a's +45 s reading assumes; SH_LEASE_CACHE_DROP_S unset). The driver was not started. Banner: $banner"
      fi
      lease_cache_drop_rec=1
      log "worker banner: lease_cache_drop=$lease_cache_drop ($ARM)"
    fi
  fi
  # Attach check: the worker's own "attached" line is not enough (a refused duplicate Hello still
  # logs it). One probe Exec through the relay must reach this worker within E15_ATTACH_TIMEOUT_S
  # (60) before the driver starts; otherwise this is a rig error (exit 1, no record), not a
  # measured failure. The probe starts no VM (E15_PROBE_KEY above).
  probe_rc=0
  relay_attach_probe "${E15_ATTACH_TIMEOUT_S:-60}" || probe_rc=$?
  [ "$probe_rc" != 2 ] ||
    die "relay attach check: the worker ran the probe on workspace_key $E15_PROBE_KEY instead of refusing it (it would have cost a VM); see $DIR/attach-probe.log"
  [ "$probe_rc" = 0 ] ||
    die "relay attach check failed: no Exec through $E15_UNIT_RELAY reached the worker within ${E15_ATTACH_TIMEOUT_S:-60} s (rig error, not a measured result); see $DIR/attach-probe.log, $DIR/worker.log, $E15_LOGS/relay.log"
  log "relay attach check passed (the worker refused the probe key $E15_PROBE_KEY: no VM started)"
fi

# --- 4. driver + sampler ---------------------------------------------------------------------
end_flag=()
case "$ARM" in resident-inf | resident-300 | lease-30 | lease-120) end_flag=(--end-session-exec) ;; esac
# E16 supplementary (fresh-metal only, default off): E15_END_SESSION_DEFER=1 sends the end-session
# Execs of sessions the run's end stopped after the grace deadline, paced (driver
# --end-session-defer, --end-session-rate E15_END_SESSION_RATE, default 50/s). Natural ends unchanged.
END_DEFER=0
if [ "$E15_HOST_PROFILE" = fresh-metal ] && [ "${E15_END_SESSION_DEFER:-0}" = 1 ] && [ ${#end_flag[@]} -gt 0 ]; then
  END_DEFER=1
  end_flag+=(--end-session-defer --end-session-rate "${E15_END_SESSION_RATE:-50}")
fi
# E17b lease arms: the driver authenticates with per-session sandbox tokens signed by this rung's key and runs the
# shipped lease at the arm's idle timeout (non-keepalive; leases end by idle timeout, reclaim or the worker's stop).
lease_flag=()
if e17b_lease_arm "$ARM"; then
  IDLE_S=$(e17b_idle_timeout_s "$ARM")
  lease_flag=(--lease-mode --token-key "$TOKEN_DIR/token.key" --idle-timeout-s "$IDLE_S" --token-wrk e15 --token-iss "$(e17b_token_iss)")
  # E17d (E17D=1; ruling E17D-B1): the mode is named, the arm's (--lease-mode=lease, or lease+processes and the level-2
  # restart rule at ship-300-l2); with E17D unset the bare --lease-mode above (lease) is unchanged.
  if [ "${E17D:-}" = 1 ]; then
    read -r -a mode_flags <<<"$(e17d_lease_flags "$ARM")"
    lease_flag=("${mode_flags[@]}" "${lease_flag[@]:1}")
  fi
fi
# E17b (E17B-R22): every E17b rung (ship-* and sbx) records py_shmem's stdout, the guest's Shmem in kB, for
# freed_from_shmem.py; a point whose library has no py_shmem simply records nothing. The sealed driver never gets it.
stdout_flag=()
if [ "${E17B:-}" = 1 ]; then
  stdout_flag=(--record-stdout py_shmem)
  # gate-256 (E17c Task 10): py_analyze's stdout carries the gate library's peak_rss_kb line
  [ -z "${E17C_GATE_LIBRARY:-}" ] || stdout_flag=(--record-stdout "py_shmem,py_analyze")
fi
launch_ts=$(date +%s.%N)
# The sampler starts with the driver, its origin the epoch just before the driver is exec'd
# (rung_start_ts as first taken). See "time origin" below for the re-base onto the driver's t0.
# fresh-metal: disk_used/disk_read_mbs of the device holding the workspaces (the guests' reads).
if [ "$E15_HOST_PROFILE" = fresh-metal ]; then export E15_DISK_PATH=${E15_DISK_PATH:-$E15_WORKSPACES}; fi
bash "$HERE/sample.sh" "$DIR/samples.jsonl" "$launch_ts" "$((WARMUP + WINDOW + 120))" &
sampler_pid=$!
MOCA_RELAY_EXEC_TOKEN=$(cat "$E15_SECRETS/exec.token") "$DRIVER" \
  --corpus "$CORPUS" --library "$LIBRARY" --seed "$SEED" --n "$N" \
  --warmup-s "$WARMUP" --window-s "$WINDOW" --spread-s "$SPREAD" --grace-s "$GRACE" \
  --target "$TARGET" --sandbox-id e15 --run-id "$RUN_ID" --out "$DIR" "${end_flag[@]}" "${start_flag[@]}" "${scan_flag[@]}" "${lease_flag[@]}" "${stdout_flag[@]}" \
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
# E17b lease arms: the rung fails if the driver exited non-zero (a session ran outside a lease, or any other driver
# failure) or any call failed on set_mode (the driver exits 0 for those). A failed rung is recorded as a driver exit
# that is not 0, which record.py reads as aborted (a rig error: the ladder stops).
rung_failed=null
set_mode_failed=0
if e17b_lease_arm "$ARM"; then
  set_mode_failed=$(python3 - "$DIR/calls.jsonl" <<'PY'
import json, sys
n = 0
try:
    for line in open(sys.argv[1]):
        try:
            if json.loads(line).get("cause") == "set_mode_failed":
                n += 1
        except ValueError:
            pass
except OSError:
    pass
print(n)
PY
  )
  # A memory-watchdog abort killed the driver: that is the host's verdict (record.py: not aborted), not a failure.
  if [ "$driver_exit" != 0 ] && [ "$memory_abort" = null ]; then
    rung_failed=\"driver_exit=$driver_exit\"
    log "$ARM rung failed: driver exit $driver_exit"
  elif [ "$set_mode_failed" != 0 ]; then
    rung_failed=\"set_mode_failed=$set_mode_failed\"
    driver_exit=1
    log "$ARM rung failed: $set_mode_failed call(s) with cause set_mode_failed (the driver exited 0 for them)"
  fi
fi

# --- 5. stop the backend, normalise the log --------------------------------------------------
oom_after=$(oom_count)
stop_rung_units
restore_failed=0
rung_host_restore || restore_failed=1
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
# The ship-* entries of params.json's worker map (PR #34): resolved only under E17B=1, so a sealed rung (E17B unset)
# never calls worker_bin for an arm it does not have (no stderr lines; its params.json is unchanged).
ship_wbin=""
[ "${E17B:-}" != 1 ] || ship_wbin="\"ship-30\": \"$(worker_bin ship-30)\", \"ship-120\": \"$(worker_bin ship-120)\", \"ship-300\": \"$(worker_bin ship-300)\","
# E17c: ship-300-nd's entry, resolved only under E17C=1 (an E17b rung's params.json is unchanged).
[ "${E17C:-}" != 1 ] || ship_wbin+=" \"ship-300-nd\": \"$(worker_bin ship-300-nd)\","
# E17d: ship-300-l2's entry, resolved only under E17D=1.
[ "${E17D:-}" != 1 ] || ship_wbin+=" \"ship-300-l2\": \"$(worker_bin ship-300-l2)\","
# E17d (E17D=1): the rung's lease mode and restart rule, and whether its snapshot advertises lease-processes-v1.
e17d_rec=0 e17d_mode="" e17d_lp=0
if [ "${E17D:-}" = 1 ]; then
  e17d_rec=1
  e17d_mode=$(e17d_lease_mode "$ARM")
  ! e17d_snapshot_lease_processes "$E15_SNAPDIR/$(worker_snapimg)/manifest.json" || e17d_lp=1
fi
E15_LEASE_BANNER=$(grep -m1 'microvm-worker: relay=' "$DIR/worker.log" 2>/dev/null || true) E15_LEASE_CACHE_DROP=$lease_cache_drop \
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
    snap = json.load(open("$E15_SNAPDIR/$(worker_snapimg)/manifest.json"))
except (OSError, ValueError):
    pass
arm = "$ARM"
# PR #34: the ship-* arms' worker paths come from the shell (ship_wbin), resolved only under E17B=1.
wbin = {"sbx": "$(worker_bin sbx)", "resident-inf": "$E15_BIN/microvm-worker-resident",
        "resident-300": "$E15_BIN/microvm-worker-resident",
        "lease-30": "$E15_BIN/microvm-worker-resident", "lease-120": "$E15_BIN/microvm-worker-resident",
        $ship_wbin}.get(arm)
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
    "drift_basis": "$E15_DRIFT_BASIS",
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
    # E17c (Task 10): which library the rung ran, by name beside its path and library_sha256 (a 256 MiB rung's is
    # library-256.json; a gate-256 rung's its gate library)
    **({"library_name": os.path.basename("$LIBRARY")} if "${E17C:-}" == "1" else {}),
    "moca_commit": "$E15_MOCA_PIN",
    "moca_experiments_commit": readf("$commit_file"),
    "resident_patch_sha256": sha("$E15_SRC/resident/resident.patch") if arm.startswith(("resident", "lease-")) else None,
    "worker_bin_sha256": sha(wbin) if wbin else None,
    "driver_bin_sha256": sha("$DRIVER"),
    **({"baseline_driver_bin_sha256": sha("$BASE_DRIVER"), "driver_bin": "$DRIVER"} if "$DRIVER" != "$BASE_DRIVER" else {}),
    "snapshot_hash": snap and snap.get("hash"), "snapshot_guest_ram_mb": snap and snap.get("guest_ram_mb"),
    "worker_env": env,
    "end_session_exec": arm in ("resident-inf", "resident-300", "lease-30", "lease-120"),
    **({"end_session_defer": True, "end_session_rate": int("${E15_END_SESSION_RATE:-50}"),
        "end_session_defer_note": "E16 supplementary (not the sealed procedure): run-end end-session Execs sent after end+grace, paced"}
       if "$END_DEFER" == "1" else {}),
    **({"idle_timeout_s": int("${IDLE_S:-0}"), "lease_banner": os.environ.get("E15_LEASE_BANNER") or None,
        "set_mode_failed_calls": int("$set_mode_failed"), "rung_failed": json.loads('$rung_failed'),
        "token_issuer": "$(e17b_lease_arm "$ARM" && e17b_token_iss)"}
       if arm.startswith("ship-") else {}),
    # E17c (E17C=1, ship-* arms; ruling R-a): the banner's lease_cache_drop= value as printed (the rung checked it).
    **({"lease_cache_drop": os.environ.get("E15_LEASE_CACHE_DROP")} if "$lease_cache_drop_rec" == "1" else {}),
    **({"snapshot_image": "$(worker_snapimg)", "guest_ram_mb": int("$(worker_guest_ram_mb)")} if "${E17B:-}" == "1" else {}),
    # E17d (E17D=1; PLAN-E17D global constraints): the arm's mode (the tokens' claim), the level-2 restart rule, and
    # whether the snapshot advertises lease-processes-v1 (the moca commit, the snapshot hash and the idle timeout are
    # recorded above)
    **({"lease_mode": "$e17d_mode", "l2_restart": "$e17d_mode" == "lease+processes",
        "snapshot_lease_processes": "$e17d_lp" == "1"} if "$e17d_rec" == "1" else {}),
    **({"squeeze_memmax_mb": int("$SQUEEZE_MB"), "committed_mb": int(env.get("SH_MAX_COMMITTED_MB", "0")),
        "squeeze_slice": {"MemoryMax": int("${E15_SQUEEZE_MAX:-0}"), "MemoryHigh": int("${E15_SQUEEZE_HIGH:-0}"),
                          "original_MemoryMax": "${E15_SQUEEZE_ORIG_MAX:-}", "original_MemoryHigh": "${E15_SQUEEZE_ORIG_HIGH:-}",
                          "restored": "${E15_SQUEEZE_RESTORED:-0}" == "1"}}
       if "$SQUEEZE_MB" else {}),
    "host_mem_total_kb": int([l.split()[1] for l in open("$E15_MEMINFO") if l.startswith("MemTotal:")][0]),
    "slice_memory_max": readf("$E15_CG/memory.max"),
}
json.dump(p, open(os.path.join(d, "params.json"), "w"), indent=2, sort_keys=True)
PY
[ "$restore_failed" = 0 ] ||
  die "e15.slice was not restored (see the WARNING above; params.json written, no record): rig error"
holds=$(python3 "$E15_SRC/analysis/record.py" "$DIR" --params "$DIR/params.json") ||
  die "record.py failed for $DIR"
log "rung $ARM N=$N: holds=$holds ($DIR/record.json)"
