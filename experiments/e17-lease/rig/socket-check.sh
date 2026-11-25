#!/usr/bin/env bash
# experiments/e17-lease/rig/socket-check.sh -- E17d's bring-up socket check (PLAN-E17D Task 9, ruling
# E17D-B11) on the E15 metal host.
#
# Run by the controller only, as the rig's login user, from the staged copy, after setup.sh and the
# chain's smoke stage:
#   E17D=1 E15_HOST_PROFILE=fresh-metal bash /srv/e15/src/e17/rig/socket-check.sh
#
# It answers the one question that would otherwise surface only after calibration: does a client in
# an Exec's shell reach the tracked level-2 server over the workspace socket, and does a dead server
# leave a stale socket that the client reports as "no server" (exit 3)?
#
#   1. the positive half, from the smoke rung at point pycache-l2, arm ship-300-l2
#      ($E15_RUNS/pycache-l2/ship-300-l2/N1-smoke): params.json's lease_mode is lease+processes, at
#      least one call restarted the server (restart true: a process_start answered), and every
#      py_requery call exited 0 (the client reached the socket from a fresh Exec shell). The rung is
#      the smoke stage's; this script never starts a rung of its own.
#   2. the negative half, two Execs in one workspace through the relay (lib.sh gexec):
#        a. `cd project && (nohup ../venv/bin/python l2srv.py >/tmp/l2srv.log 2>&1 &) ; sleep 3; ls
#           /workspace/.l2/l2.sock`: the Exec ends, its server with it, and the socket file stays.
#        b. `cd project && ../venv/bin/python l2c.py ping`: exit 3, the stale socket read as no server.
#
# Exit 0 when both halves hold, 1 otherwise, naming what failed. Logs under $E15_RUNS/socket-check/.
set -uo pipefail
E15_PROG=socket-check.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$HERE/../../e15/rig/lib.sh" ]; then E15RIG="$HERE/../../e15/rig"; else E15RIG="$HERE/../../../experiments/e15-session-density/rig"; fi
# shellcheck source=SCRIPTDIR/../../e15-session-density/rig/lib.sh
. "$E15RIG/lib.sh"
# shellcheck source=SCRIPTDIR/../../e15-session-density/rig/points.sh
. "$E15RIG/points.sh"
[ "${E17D:-}" = 1 ] || die "E17D=1 is required (this is E17d's socket check; spec §14.2)"

L="$E15_RUNS/socket-check"
mkdir -p "$L"
RUN="$E15_RUNS/pycache-l2/ship-300-l2/N1-smoke"
fail=0
say() { printf 'socket-check: %s\n' "$*"; }

# 1. the positive half, from the smoke rung.
if [ ! -f "$RUN/params.json" ]; then
  say "FAIL: no smoke rung at $RUN: run the chain's smoke stage first (chain-e17d.sh smoke)"
  exit 1
fi
python3 - "$RUN" <<'PY' || fail=1
import json, os, sys
run = sys.argv[1]
p = json.load(open(os.path.join(run, "params.json")))
if p.get("lease_mode") != "lease+processes":
    print("socket-check: FAIL: %s ran lease_mode=%r, not lease+processes" % (run, p.get("lease_mode")))
    sys.exit(1)
calls = [json.loads(l) for l in open(os.path.join(run, "calls.jsonl")) if l.strip()]
req = [c for c in calls if c.get("class") == "py_requery"]
restarts = [c for c in req if c.get("restart")]
bad = [c for c in req if c.get("status") != "ok" or int(c.get("exit") or 0) != 0]
if not restarts:
    print("socket-check: FAIL: %s has no py_requery that restarted a server (no process_start answered)" % run)
    sys.exit(1)
if bad:
    print("socket-check: FAIL: %s has %d py_requery calls that failed: %s" %
          (run, len(bad), ", ".join("%s exit=%s status=%s" % (c.get("trace"), c.get("exit"), c.get("status")) for c in bad[:5])))
    sys.exit(1)
print("socket-check: positive half ok: %d restarts, %d warm py_requery, all exit 0" % (len(restarts), len(req) - len(restarts)))
PY

# 2. the negative half: a stale socket reads as no server. It needs a worker of its own (a rung
# leaves none), as smoke.sh's analyze check starts one: a stock sbx worker on a reflinked copy of
# the point's template.
e15_point "${E17D_POINT:-pycache-l2}" || die "points.sh: no point ${E17D_POINT:-pycache-l2}"
WS="$E15_ROOT/workspaces/socket-check"
sudo -n rm -rf -- "$WS"
sudo -n mkdir -m 0700 "$WS"
sudo -n cp "$(workspace_cp_flag "$(workspace_copy_mode)")" "$E15_P_TEMPLATE" "$WS/workspace.img"
sudo -n chmod 0600 "$WS/workspace.img"
cleanup() { stop_rung_units; sudo -n rm -rf -- "$WS"; }
trap cleanup EXIT
start_worker sbx "$L" "$E15_P_IMAGE_MB"
KEY=socket-check
for _ in $(seq 30); do
  probe=$(gexec _e15-attach-probe true 2>&1 || true)
  case "$probe" in *"ExecError: invalid-workspace-key: "*) break ;; esac
  sleep 1
done
out="$(gexec "$KEY" 'cd project && (nohup ../venv/bin/python l2srv.py >/tmp/l2srv.log 2>&1 &) ; sleep 3; ls /workspace/.l2/l2.sock' 2>&1)" || true
printf '%s\n' "$out" | grep -q '/workspace/.l2/l2.sock' || {
  say "FAIL: the server left no /workspace/.l2/l2.sock: $out"
  fail=1
}
(code=0; gexec "$KEY" 'cd project && ../venv/bin/python l2c.py ping' >"$L/stale.out" 2>&1) || code=$?
if [ "$code" -ne 3 ]; then
  say "FAIL: l2c.py on a stale socket exited $code, want 3: $(head -3 "$L/stale.out")"
  fail=1
else
  say "negative half ok: l2c.py exited 3 on the stale socket"
fi

[ "$fail" -eq 0 ] && say "ok" || say "FAILED"
exit "$fail"
