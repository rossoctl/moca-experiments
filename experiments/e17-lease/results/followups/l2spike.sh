#!/usr/bin/env bash
# E17 follow-up: size level 2 (a persistent process) against level 1 (warm VM, fresh process) and per-Exec.
# Point pycache (template d256). sbx worker for per-Exec, resident-300 (kills no process) for levels 1 and 2.
# The query scripts are written into each workspace root; workspaces e17-l2-a/b removed by literal path.
set -euo pipefail
export E15_HOST_PROFILE=fresh-metal
E15_SRC=/srv/e15/src/e15
# shellcheck source=/dev/null
source "$E15_SRC/rig/lib.sh"
# shellcheck source=/dev/null
source "$E15_SRC/rig/points.sh"
e15_point pycache
PATH="$E15_BIN:$PATH"
if unit_active "$E15_UNIT_WORKER"; then echo "a rung worker is running; refusing"; exit 1; fi
OUT=/srv/e15/e17/l2spike
mkdir -p "$OUT"
stop_rung_units
stop_e15_unit "$E15_UNIT_RELAY"
start_relay
sleep 3
cleanup() { stop_rung_units; sudo -n rm -rf -- /srv/e15/workspaces/e17-l2-a /srv/e15/workspaces/e17-l2-b; }
trap cleanup EXIT
sudo -n rm -rf -- /srv/e15/workspaces/e17-l2-a /srv/e15/workspaces/e17-l2-b
for k in e17-l2-a e17-l2-b; do
  sudo -n mkdir -m 0700 "/srv/e15/workspaces/$k"
  sudo -n cp "$(workspace_cp_flag "$(workspace_copy_mode)")" "$E15_P_TEMPLATE" "/srv/e15/workspaces/$k/workspace.img"
  sudo -n chmod 0600 "/srv/e15/workspaces/$k/workspace.img"
done
COMMON_B64=aW1wb3J0IGhhc2hsaWIsIG9zLCBzeXMsIHRpbWUKc3lzLnBhdGguaW5zZXJ0KDAsICJzcmMiKQpUMCA9IHRpbWUudGltZSgpCmZyb20gcHljIGltcG9ydCBjb25maWcsIGRhdGEsIG1vZGVsICAjIG5vcWE6IEU0MDIKaW1wb3J0IHBhbmRhcyBhcyBwZCAgIyBub3FhOiBFNDAyClYgPSBsaXN0KGNvbmZpZy5WQUxVRV9DT0xVTU5TKQpkZWYgbG9hZCgpOgogICAgcGF0aHMgPSBkYXRhLnNoYXJkX3BhdGhzKGNvbmZpZy5EQVRBX0RJUikKICAgIHNhbXBsZXIgPSBtb2RlbC5TYW1wbGVyKGRhdGEuZXN0aW1hdGVkX3Jvd3MocGF0aHMpKQogICAgZnJhbWVzID0gW10KICAgIGZvciBmIGluIGRhdGEuaXRlcl9zaGFyZHMocGF0aHMsIGhhc2hsaWIuc2hhMjU2KCkpOgogICAgICAgIGZyYW1lcy5hcHBlbmQoZikKICAgICAgICBzYW1wbGVyLmFkZChmKQogICAgcmV0dXJuIHBkLmNvbmNhdChmcmFtZXMsIGlnbm9yZV9pbmRleD1UcnVlKSwgc2FtcGxlci5zYW1wbGUoKQpkZWYgcV9saWdodChkZiwgeCk6CiAgICBtID0gZGYuZ3JvdXBieSgiZyIpW1ZdLm1lYW4oKQogICAgcmV0dXJuICJsaWdodCBncm91cHM9JWQgbWVkaWFuX3gwPSUuM2YiICUgKGxlbihtKSwgZGZbIngwIl0ubWVkaWFuKCkpCmRlZiBxX2ZpdChkZiwgeCk6CiAgICByZXR1cm4gImZpdCBpbmVydGlhPSUuM2YiICUgbW9kZWwuaW5lcnRpYShtb2RlbC5maXRfcmVwZWF0ZWQoeCwgY29uZmlnLkFOQUxZWkVfV09SS19TQ0FMRSkpClEgPSB7ImxpZ2h0IjogcV9saWdodCwgImZpdCI6IHFfZml0LCAicGluZyI6IGxhbWJkYSBkZiwgeDogInBvbmcifQo=
Q_B64=IyBGcm9tIHNjcmF0Y2g6IGltcG9ydCwgbG9hZCwgb25lIHF1ZXJ5LCBleGl0IChwZXItRXhlYyBhbmQgbGV2ZWwgMSkuCmltcG9ydCBzeXMsIHRpbWUKZXhlYyhvcGVuKCIuLi9sMmNvbW1vbi5weSIpLnJlYWQoKSkKZGYsIHggPSBsb2FkKCkKdCA9IHRpbWUudGltZSgpCnIgPSBRW3N5cy5hcmd2WzFdXShkZiwgeCkKcHJpbnQoIiVzIHF1ZXJ5X21zPSUuMGYgdG90YWxfbXM9JS4wZiIgJSAociwgKHRpbWUudGltZSgpIC0gdCkgKiAxMDAwLCAodGltZS50aW1lKCkgLSBUMCkgKiAxMDAwKSkK
SRV_B64=IyBMZXZlbCAyIHN0YW5kLWluOiBsb2FkIG9uY2UsIHRoZW4gc2VydmUgcXVlcmllcyBvbiBhIHVuaXggc29ja2V0LgppbXBvcnQgb3MsIHNvY2tldCwgdGltZQpleGVjKG9wZW4oIi4uL2wyY29tbW9uLnB5IikucmVhZCgpKQpkZiwgeCA9IGxvYWQoKQpsb2FkX21zID0gKHRpbWUudGltZSgpIC0gVDApICogMTAwMAp0cnk6CiAgICBvcy51bmxpbmsoIi90bXAvbDIuc29jayIpCmV4Y2VwdCBGaWxlTm90Rm91bmRFcnJvcjoKICAgIHBhc3MKcyA9IHNvY2tldC5zb2NrZXQoc29ja2V0LkFGX1VOSVgpCnMuYmluZCgiL3RtcC9sMi5zb2NrLnRtcCIpCnMubGlzdGVuKDQpCm9zLnJlbmFtZSgiL3RtcC9sMi5zb2NrLnRtcCIsICIvdG1wL2wyLnNvY2siKQpwcmludCgicmVhZHkgbG9hZF9tcz0lLjBmIHJvd3M9JWQiICUgKGxvYWRfbXMsIGxlbihkZikpLCBmbHVzaD1UcnVlKQp3aGlsZSBUcnVlOgogICAgYywgXyA9IHMuYWNjZXB0KCkKICAgIG5hbWUgPSBjLnJlY3YoNjQpLmRlY29kZSgpLnN0cmlwKCkKICAgIHQgPSB0aW1lLnRpbWUoKQogICAgciA9IFFbbmFtZV0oZGYsIHgpCiAgICBjLnNlbmRhbGwoKCIlcyBzZXJ2ZXJfbXM9JS4wZlxuIiAlIChyLCAodGltZS50aW1lKCkgLSB0KSAqIDEwMDApKS5lbmNvZGUoKSkKICAgIGMuY2xvc2UoKQo=
put() { # workspace file b64
  gexec "$1" "python3 -c \"import base64; open('/workspace/$2','wb').write(base64.b64decode('$3'))\"" >/dev/null
}
run() { # label key cmd
  local rc=0 t0 t1 out
  t0=$(date +%s%N); out=$(gexec "$2" "$3" 2>&1) || rc=$?; t1=$(date +%s%N)
  printf '%-22s rc=%s wall_ms=%6d  %s\n' "$1" "$rc" $(( (t1 - t0) / 1000000 )) "$(printf '%s' "$out" | tail -1 | cut -c1-110)"
}
CLIENT="python3 -c \"import socket,sys; s=socket.socket(socket.AF_UNIX); s.connect('/tmp/l2.sock'); s.sendall(sys.argv[1].encode()); print(s.recv(4096).decode().strip())\""
waitready() { gexec "$1" 'for i in $(seq 600); do [ -S /tmp/l2.sock ] && exit 0; sleep 0.1; done; cat /tmp/l2srv.log; exit 1'; }
start_ws() { # arm key
  stop_rung_units
  mkdir -p "$OUT/$1"
  start_worker "$1" "$OUT/$1" "$E15_P_IMAGE_MB"
  for _ in $(seq 30); do
    p=$(gexec _e15-attach-probe true 2>&1 || true)
    case "$p" in *"invalid-workspace-key: "*) break ;; esac
    sleep 2
  done
  put "$2" l2common.py "$COMMON_B64"; put "$2" l2q.py "$Q_B64"; put "$2" l2srv.py "$SRV_B64"
}
echo "== per-Exec (sbx): fresh VM and process each time"
start_ws sbx e17-l2-a
run warmup-first-touch e17-l2-a "cd project && ../venv/bin/python ../l2q.py ping"
for i in 1 2 3 4; do run "light (fresh VM)" e17-l2-a "cd project && ../venv/bin/python ../l2q.py light"; done
for i in 1 2; do run "fit (fresh VM)" e17-l2-a "cd project && ../venv/bin/python ../l2q.py fit"; done
echo "== level 1 (resident-300): warm VM, fresh process each time"
start_ws resident-300 e17-l2-b
run warmup-first-touch e17-l2-b "cd project && ../venv/bin/python ../l2q.py ping"
for i in 1 2 3 4; do run "light (warm VM)" e17-l2-b "cd project && ../venv/bin/python ../l2q.py light"; done
for i in 1 2; do run "fit (warm VM)" e17-l2-b "cd project && ../venv/bin/python ../l2q.py fit"; done
echo "== level 2 (same VM): one persistent process"
t0=$(date +%s%N)
gexec e17-l2-b "cd project && setsid nohup ../venv/bin/python ../l2srv.py >/tmp/l2srv.log 2>&1 </dev/null & echo started" >/dev/null
waitready e17-l2-b
echo "server start to ready: $(( ($(date +%s%N) - t0) / 1000000 )) ms; $(gexec e17-l2-b 'cat /tmp/l2srv.log' 2>&1 | tail -1)"
for i in 1 2 3 4 5; do run "ping (server)" e17-l2-b "$CLIENT ping"; done
for i in 1 2 3 4 5 6 7 8; do run "light (server)" e17-l2-b "$CLIENT light"; done
for i in 1 2 3; do run "fit (server)" e17-l2-b "$CLIENT fit"; done
echo "guest after: $(gexec e17-l2-b "grep -E '^(MemAvailable):' /proc/meminfo | tr -s ' '; for p in /proc/[0-9]*; do grep -q l2srv \$p/cmdline 2>/dev/null && grep VmRSS \$p/status; done" 2>&1 | tr '\n' ' ')"
