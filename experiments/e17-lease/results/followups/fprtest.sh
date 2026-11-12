#!/usr/bin/env bash
# E17 follow-up: does a RESTORED VM's free-page-reporting balloon return freed guest memory to the host?
# Control: snapshot e15 (no balloon). Test: e17-fpr. One resident-300 worker each, one workspace (the default
# 256 MiB template). The guest touches 700 MiB and exits; the host reads the VM cgroup's memory.current.
# Workspaces e17-fp-a/b removed by literal path.
set -euo pipefail
export E15_HOST_PROFILE=fresh-metal
E15_SRC=/srv/e15/src/e15
# shellcheck source=/dev/null
source "$E15_SRC/rig/lib.sh"
# shellcheck source=/dev/null
source "$E15_SRC/rig/points.sh"
e15_point default
PATH="$E15_BIN:$PATH"
if unit_active "$E15_UNIT_WORKER"; then echo "a rung worker is running; refusing"; exit 1; fi
OUT=/srv/e15/e17/fprtest
mkdir -p "$OUT"
stop_rung_units
stop_e15_unit "$E15_UNIT_RELAY"
start_relay
sleep 3
cleanup() { stop_rung_units; sudo -n rm -rf -- /srv/e15/workspaces/e17-fp-a /srv/e15/workspaces/e17-fp-b; }
trap cleanup EXIT
sudo -n rm -rf -- /srv/e15/workspaces/e17-fp-a /srv/e15/workspaces/e17-fp-b
for k in e17-fp-a e17-fp-b; do
  sudo -n mkdir -m 0700 "/srv/e15/workspaces/$k"
  sudo -n cp "$(workspace_cp_flag "$(workspace_copy_mode)")" "$E15_P_TEMPLATE" "/srv/e15/workspaces/$k/workspace.img"
  sudo -n chmod 0600 "/srv/e15/workspaces/$k/workspace.img"
done
vmcg() { # memory.current (MiB) and anon/file (MiB) of every firecracker's cgroup
  local p cg
  for p in $(pgrep -x firecracker || true); do
    cg=$(sed -n 's/^0:://p' "/proc/$p/cgroup")
    sudo -n awk -v cg="$cg" -v cur="$(sudo -n cat "/sys/fs/cgroup$cg/memory.current")" \
      '$1=="anon"{a=$2} $1=="file"{f=$2} END{printf "  %s cur=%.0f MiB anon=%.0f file=%.0f\n", cg, cur/1048576, a/1048576, f/1048576}' \
      "/sys/fs/cgroup$cg/memory.stat"
  done
}
ALLOC="python3 -c 'n=700<<20; b=bytearray(n); b[::4096]=b\"\\x01\"*(n//4096); print(\"touched\", n>>20, \"MiB\")'"
for pair in "e15 e17-fp-a" "e17-fpr e17-fp-b"; do
  set -- $pair; snap=$1; k=$2
  E15_SNAPIMG=$snap
  mkdir -p "$OUT/$snap"
  stop_rung_units
  start_worker resident-300 "$OUT/$snap" "$E15_P_IMAGE_MB"
  for _ in $(seq 30); do
    p=$(gexec _e15-attach-probe true 2>&1 || true)
    case "$p" in *"invalid-workspace-key: "*) break ;; esac
    sleep 2
  done
  echo "== snapshot $snap ($(grep -o 'SH_SNAPSHOT_IMAGE=.*' "$OUT/$snap/worker.env"))"
  echo "guest balloon: $(gexec "$k" 'ls /sys/bus/virtio/drivers/virtio_balloon/ 2>/dev/null | grep -c virtio || true; cat /sys/module/page_reporting/parameters/page_reporting_order 2>/dev/null || echo no-param' 2>&1 | tr '\n' ' ')"
  sleep 5; echo "before alloc:"; vmcg
  echo "alloc: $(gexec "$k" "$ALLOC" 2>&1 | tail -1)"
  for t in 0 5 15 30 60; do
    [ "$t" = 0 ] || sleep $((t - ${prev:-0}))
    prev=$t; echo "+${t}s after the process exited:"; vmcg
  done
  unset prev
  echo "guest: $(gexec "$k" "grep -E '^(MemFree|MemAvailable):' /proc/meminfo | tr -s ' ' | tr '\n' ' '" 2>&1)"
done
