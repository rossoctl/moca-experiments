#!/usr/bin/env bash
# E17 follow-up (user decision 2026-11-12: one golden snapshot with the balloon): per-Exec latency with the
# reporting balloon (e17-fpr) against without (e15). sbx worker, N=1 sequential Execs, rounds e15, e17-fpr,
# e15, e17-fpr. Workspace e17-pb-a removed by literal path.
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
OUT=/srv/e15/e17/perexec-balloon
mkdir -p "$OUT"
stop_rung_units
stop_e15_unit "$E15_UNIT_RELAY"
start_relay
sleep 3
cleanup() { stop_rung_units; sudo -n rm -rf -- /srv/e15/workspaces/e17-pb-a; }
trap cleanup EXIT
sudo -n rm -rf -- /srv/e15/workspaces/e17-pb-a
for k in e17-pb-a; do
  sudo -n mkdir -m 0700 "/srv/e15/workspaces/$k"
  sudo -n cp "$(workspace_cp_flag "$(workspace_copy_mode)")" "$E15_P_TEMPLATE" "/srv/e15/workspaces/$k/workspace.img"
  sudo -n chmod 0600 "/srv/e15/workspaces/$k/workspace.img"
done
K=e17-pb-a
TOUCH="python3 -c 'n=256<<20; b=bytearray(n); b[::4096]=b\"\\x01\"*(n//4096)'"
timeit() { # name count cmd -> one line per call: snap name ms rc
  local name=$1 n=$2 cmd=$3 i t0 t1 rc
  for i in $(seq "$n"); do
    rc=0; t0=$(date +%s%N); gexec "$K" "$cmd" >/dev/null 2>&1 || rc=$?; t1=$(date +%s%N)
    echo "$snap $name $(( (t1 - t0) / 1000000 )) $rc" >> "$OUT/calls.txt"
  done
}
: > "$OUT/calls.txt"
r=0
for snap in e15 e17-fpr e15 e17-fpr; do
  r=$((r + 1)); E15_SNAPIMG=$snap
  mkdir -p "$OUT/r$r-$snap"
  stop_rung_units
  start_worker sbx "$OUT/r$r-$snap" "$E15_P_IMAGE_MB"
  for _ in $(seq 30); do
    p=$(gexec _e15-attach-probe true 2>&1 || true)
    case "$p" in *"invalid-workspace-key: "*) break ;; esac
    sleep 2
  done
  echo "== round $r $snap ($(grep -o 'SH_SNAPSHOT_IMAGE=.*' "$OUT/r$r-$snap/worker.env"))"
  gexec "$K" true >/dev/null 2>&1 || true   # first Exec on the workspace, not timed
  sleep 5
  timeit true 40 true
  timeit pypass 20 "python3 -c pass"
  timeit touch256 10 "$TOUCH"
done
python3 - "$OUT/calls.txt" <<'PY'
import sys, statistics as st, collections
d=collections.defaultdict(list); bad=0
for l in open(sys.argv[1]):
    snap,name,ms,rc=l.split(); d[(name,snap)].append(int(ms)); bad+= rc!="0"
def p95(v): v=sorted(v); return v[min(len(v)-1, int(0.95*len(v)))]
for name in ("true","pypass","touch256"):
    a,b=d[(name,"e15")], d[(name,"e17-fpr")]
    print("%-9s e15 n=%d median %d p95 %d | e17-fpr n=%d median %d p95 %d | delta median %+d ms" % (name,len(a),st.median(a),p95(a),len(b),st.median(b),p95(b),st.median(b)-st.median(a)))
print("non-zero exits:", bad)
PY
