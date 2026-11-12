#!/usr/bin/env bash
# experiments/e17-lease/rig/smoke.sh -- E17's smoke and guest import check (PLAN Task 5 step 2) on the E15 metal host.
#
# Run by the controller only, as the rig's login user, after bringup.sh:
#   bash /srv/e15/src/e17/rig/smoke.sh
#
#   0. refuses to start while a rung's worker (e15-worker.service) is running: it never preempts one
#   1. one rung per arm at point pycache, N=1, a 60 s warm-up and a 120 s window, tag smoke, the
#      session starting at its first call (E15_START_ZERO, default 1 here: smoke is a bring-up
#      check, not a measured rung, and a drawn start index misses py_analyze about 35% of the time):
#        E15_WARMUP_S=60 E15_WINDOW_S=120 E15_TAG=smoke E15_START_ZERO=1 bash experiments/e15-session-density/rig/rung.sh ARM 1 pycache
#      for ARM in sbx resident-300 lease-30 lease-120 -> /srv/e15/runs/pycache/ARM/N1-smoke/
#      (other E15_* environment passes through to rung.sh; E15_RUNG overrides the rung command)
#   2. the sbx rung: every py_analyze call in calls.jsonl has status ok and exit 0, except a call
#      the run's end cut (cause cut_at_end: not a failure, experiments/e15-session-density/driver/exec.go), and at least one
#      completed (not cut) py_analyze call exists.
#   3. analyze's stdout: the driver keeps only an Exec's stderr tail (experiments/e15-session-density/driver/exec.go), so the
#      printed `sha256=` is checked with one more Exec, outside any rung, the way setup.sh's
#      end-to-end check does: the relay restarted (as rung.sh does), a stock sbx worker, one
#      reflinked copy of the D=256 template at workspaces/e17-smoke-analyze/workspace.img, and
#      lib.sh gexec of the library's py_analyze command through the relay (grpcurl). Its exit must
#      be 0 and its sha256= must equal template-pycache-d256/BUILD's dataset_sha256 (bringup.sh).
#      Log: /srv/e15/runs/pycache/sbx/N1-smoke/analyze-check.log (the worker's in analyze-check/);
#      the workspace copy is removed after, and the relay left running, as after a rung.
#   4. experiments/e17-lease/analysis/warmcold.py on each rung: its warm/cold/unknown counts, printed (and
#      warmcold.jsonl, warmcold-report.json in the rung directory). Run before step 3, so a rig
#      error there (lib.sh die: the worker does not attach) still leaves the counts printed.
# Exit 0 when every rung wrote its record and steps 2-3 pass; 1 otherwise.
set -euo pipefail
E15_PROG=smoke.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The staged copy on the rig has e15/ beside e17/ ($HERE/../../e15/rig); a checkout of this
# repo has it at $HERE/../../../experiments/e15-session-density/rig. Use whichever exists.
E15_RIG=$HERE/../../e15/rig
[ -f "$E15_RIG/lib.sh" ] || E15_RIG=$HERE/../../../experiments/e15-session-density/rig
# shellcheck source=SCRIPTDIR/../../experiments/e15-session-density/rig/lib.sh
. "$E15_RIG/lib.sh"
# shellcheck source=SCRIPTDIR/../../experiments/e15-session-density/rig/points.sh
. "$E15_RIG/points.sh"

[ "$E15_HOST_PROFILE" = fresh-metal ] || die "E15_HOST_PROFILE=$E15_HOST_PROFILE: E17 runs on fresh-metal only"
E17_SRC=$E15_ROOT/src/e17
case "$HERE" in "$E17_SRC"/rig) ;; *) die "run the staged copy: $E17_SRC/rig/smoke.sh (not $HERE)" ;; esac
POINT=pycache
ARMS=(sbx resident-300 lease-30 lease-120)
RUNG=${E15_RUNG:-$E15_SRC/rig/rung.sh}
START_ZERO=${E15_START_ZERO:-1}
# Never preempt a rung someone else started (each rung.sh and the analyze check below stop E15's
# rung units first).
refuse_running_rung() { if unit_active "$E15_UNIT_WORKER"; then die "a rung's worker ($E15_UNIT_WORKER) is running; refusing to preempt it"; fi; }
refuse_running_rung
e15_point "$POINT" || die "points.sh: no point $POINT"
BUILD=${E15_P_TEMPLATE%/*}/BUILD
want_sha=$(sed -n 's/^dataset_sha256: //p' "$BUILD" 2>/dev/null || true)
[[ "$want_sha" =~ ^[0-9a-f]{64}$ ]] || die "no dataset_sha256 in $BUILD (run bringup.sh)"
ANALYZE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["classes"]["py_analyze"][0]["cmd"])' "$E15_P_LIBRARY")

fails=()
dirs=()
for arm in "${ARMS[@]}"; do
  d=$E15_RUNS/$POINT/$arm/N1-smoke
  log "smoke: $arm N=1 $POINT (60 s warm-up, 120 s window) -> $d"
  if ! E15_WARMUP_S=60 E15_WINDOW_S=120 E15_TAG=smoke E15_START_ZERO=$START_ZERO bash "$RUNG" "$arm" 1 "$POINT"; then
    fails+=("$arm: rung.sh failed")
    continue
  fi
  [ -f "$d/record.json" ] || {
    fails+=("$arm: no $d/record.json")
    continue
  }
  dirs+=("$d")
done

# --- 2. the sbx rung's py_analyze calls ----------------------------------------------------------
SBX=$E15_RUNS/$POINT/sbx/N1-smoke
if [ -f "$SBX/calls.jsonl" ]; then
  if out=$(python3 - "$SBX/calls.jsonl" "$START_ZERO" <<'PY'
import json, sys
calls = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
an = [c for c in calls if c.get("class") == "py_analyze"]
# cut_at_end: cancelled at the grace deadline within its planned lifetime; the driver marks its
# status err, but it is not a failure (experiments/e15-session-density/driver/exec.go causeCutAtEnd).
cut = [c for c in an if c.get("cause") == "cut_at_end"]
done = [c for c in an if c.get("cause") != "cut_at_end"]
bad = [c for c in done if c.get("status") != "ok" or c.get("exit") != 0]
for c in bad:
    print("call %s: status %s cause %s exit %s %s" % (c.get("call"), c.get("status"), c.get("cause"),
                                                       c.get("exit"), c.get("msg", "")))
if not done:
    print("no completed py_analyze call among the rung's %d calls (%d cut at the end; "
          "E15_START_ZERO=%s)" % (len(calls), len(cut), sys.argv[2]))
    sys.exit(1)
print("%d py_analyze call(s), %d not ok/exit 0, %d cut at the end (not failures)" % (len(an), len(bad), len(cut)))
sys.exit(1 if bad else 0)
PY
  ); then
    log "sbx py_analyze: $out"
  else
    fails+=("sbx py_analyze: $out")
  fi
else
  fails+=("sbx: no $SBX/calls.jsonl")
fi

# --- 4. warm/cold per rung (before step 3, whose rig errors die) ---------------------------------
for d in "${dirs[@]}"; do
  wc_out=$(python3 "$E17_SRC/analysis/warmcold.py" "$d" 2>&1) || fails+=("warmcold.py failed on $d: $wc_out")
  holds=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("holds"))' "$d/record.json" 2>/dev/null || echo "?")
  printf 'smoke %s: %s (holds=%s)\n' "${d#"$E15_RUNS"/}" "$wc_out" "$holds"
done

# --- 3. analyze's printed sha256, through the relay ----------------------------------------------
KEY=e17-smoke-analyze
WS=$E15_WORKSPACES/$KEY
# The only removal here: this exact leaf, a key no rung uses (rung.sh keys are e15-<run>-...).
[ "$WS" = "$E15_ROOT/workspaces/e17-smoke-analyze" ] || die "refusing workspace path $WS"
refuse_outside_root "$WS"
alog=$SBX/analyze-check.log
if [ -d "$SBX" ]; then
  PATH="$E15_BIN:$PATH"
  command -v grpcurl >/dev/null 2>&1 || die "no grpcurl on PATH (bootstrap.sh's, in $E15_BIN)"
  refuse_running_rung
  stop_rung_units
  stop_e15_unit "$E15_UNIT_RELAY"
  start_relay
  sleep 3
  ! grep -qs 'redis client error' "$E15_LOGS/relay.log" ||
    die "the restarted relay cannot reach Redis on 127.0.0.1:$E15_PORT_REDIS; see $E15_LOGS/relay.log"
  sudo -n rm -rf -- "$WS"
  sudo -n mkdir -m 0700 "$WS"
  sudo -n cp "$(workspace_cp_flag "$(workspace_copy_mode)")" "$E15_P_TEMPLATE" "$WS/workspace.img"
  sudo -n chmod 0600 "$WS/workspace.img"
  cleanup() {
    stop_rung_units
    sudo -n rm -rf -- "$WS"
  }
  trap cleanup EXIT
  mkdir -p "$SBX/analyze-check"
  start_worker sbx "$SBX/analyze-check" "$E15_P_IMAGE_MB"
  # rung.sh's attach check: the worker's own refusal of an invalid key proves the relay reaches it.
  attached=0
  # (The output is captured first: gexec exits 98 on the refusal, which a pipe under pipefail
  # would report as the pipeline's status.)
  for _ in $(seq 30); do
    probe=$(gexec _e15-attach-probe true 2>&1 || true)
    case "$probe" in *"ExecError: invalid-workspace-key: "*)
      attached=1
      break
      ;;
    esac
    sleep 2
  done
  rc=0
  if [ "$attached" = 1 ]; then
    out=$(gexec "$KEY" "$ANALYZE" 2>&1) || rc=$?
  else
    out="the relay never reached the worker (attach check)"
    rc=99
  fi
  printf '$ %s\nexit %s\n%s\n' "$ANALYZE" "$rc" "$out" >>"$alog"
  cleanup
  trap - EXIT
  got_sha=$(printf '%s\n' "$out" | sed -n 's/.*sha256=\([0-9a-f]\{64\}\).*/\1/p' | tail -1)
  if [ "$rc" != 0 ]; then
    fails+=("analyze through the relay exited $rc (see $alog)")
  elif [ "$got_sha" != "$want_sha" ]; then
    fails+=("analyze printed sha256=${got_sha:-(none)}, $BUILD has dataset_sha256 $want_sha (see $alog)")
  else
    log "analyze: exit 0, sha256=$got_sha equals $BUILD's dataset_sha256"
  fi
else
  fails+=("no $SBX: the analyze check did not run")
fi

if [ ${#fails[@]} -gt 0 ]; then
  printf 'smoke FAILED: %s\n' "${fails[@]}" >&2
  exit 1
fi
echo "smoke passed: ${#dirs[@]} rungs; sbx py_analyze exit 0; analyze sha256 = BUILD dataset_sha256 ($want_sha)"
