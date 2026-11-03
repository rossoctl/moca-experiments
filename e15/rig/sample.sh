#!/usr/bin/env bash
# e15/rig/sample.sh OUT ORIGIN_EPOCH DURATION_S -- the 1 Hz host sampler (SPEC §9.1, §9.2).
#
# Appends one JSON object per second to OUT (samples.jsonl) until ORIGIN_EPOCH + DURATION_S, or
# until SIGTERM. Schema (analysis/record.py; Task 6 ruling):
#
#   t                   seconds since ORIGIN_EPOCH (rung.sh passes the epoch taken just before it
#                       execs the driver; rung.sh re-bases t onto the driver's own t0_epoch after
#                       the run, keeping ts -- see rung.sh "time origin")
#   ts                  wall clock, epoch seconds
#   mem_available_kb    /proc/meminfo MemAvailable
#   page_cache_kb       /proc/meminfo Cached
#   host_cpu_busy_pct   whole host, /proc/stat delta since the previous sample (absent on the first)
#   slice_mem_bytes     memory.current of the worker slice (e15.slice/e15-vms.slice: worker + VMs)
#   slice_cpu_usec      cpu.stat usage_usec of the same slice (cumulative)
#   e15_mem_bytes       memory.current of e15.slice (worker slice + relay + null-responder)
#   e15_cpu_usec        cpu.stat usage_usec of e15.slice (cumulative)
#   psi_cpu_some_avg10, psi_mem_some_avg10, psi_mem_full_avg10   host /proc/pressure
#   slice_psi_mem_some_avg10                                     worker slice memory.pressure
#   disk_used_pct, disk_used_kb   the filesystem holding /srv/e15 (df)
#   disk_read_mbs       read throughput of the block device holding /srv/e15, MB/s (10^6 bytes),
#                       /proc/diskstats sectors-read delta since the previous sample (absent on the
#                       first sample, or when the device is not found)
#   disk_await_ms       mean time per completed I/O (reads + writes) over the same delta, ms
#                       (absent when no I/O completed)
#   procs               process count ($E15_PROC/<pid> directories)
#   vm_mem              {"<cgroup>": memory.current} for every VM cgroup in the worker slice that
#                       holds a process (the worker's own service cgroup and idle pool cgroups are
#                       left out, so a median over vm_mem is a median over live VMs)
#   worker              the worker's /stats JSON (SH_DIAG_STATS_ADDR), when it answers
#
# Environment: E15_SLICE_DIR (default /sys/fs/cgroup/e15.slice), E15_STATS_URL
# (default http://127.0.0.1:9646/stats), E15_DISK_PATH (default /srv/e15), E15_DISK_DEV (the
# diskstats device name; default: the device findmnt names for E15_DISK_PATH), E15_PROC (default
# /proc; tests point it at a fixture tree).
set -uo pipefail

[ $# -eq 3 ] || {
  echo "usage: sample.sh OUT ORIGIN_EPOCH DURATION_S" >&2
  exit 2
}
OUT=$1
ORIGIN=$2
DURATION=$3
E15_DIR=${E15_SLICE_DIR:-/sys/fs/cgroup/e15.slice}
VMS_DIR=$E15_DIR/e15-vms.slice
STATS_URL=${E15_STATS_URL:-http://127.0.0.1:9646/stats}
DISK_PATH=${E15_DISK_PATH:-/srv/e15}
PROC=${E15_PROC:-/proc}
# The block device behind DISK_PATH, by name as /proc/diskstats lists it.
DISK_DEV=${E15_DISK_DEV:-}
if [ -z "$DISK_DEV" ] && command -v findmnt >/dev/null 2>&1; then
  majmin=$(findmnt -no MAJ:MIN -T "$DISK_PATH" 2>/dev/null | head -1 | tr -d ' ')
  [ -n "$majmin" ] && DISK_DEV=$(awk -v mm="$majmin" '$1":"$2==mm{print $3; exit}' "$PROC/diskstats" 2>/dev/null)
fi

stop=0
trap 'stop=1' TERM INT

# now: epoch seconds with microseconds, from bash itself (no fork).
now() { printf '%s' "${EPOCHREALTIME:-$(date +%s.%N)}"; }

# file_val FILE: first line of FILE, or empty.
file_val() {
  local v=""
  [ -r "$1" ] && read -r v <"$1"
  printf '%s' "$v"
}

# cpu_usec DIR: usage_usec from DIR/cpu.stat.
cpu_usec() {
  local k v
  [ -r "$1/cpu.stat" ] || return 0
  while read -r k v; do
    if [ "$k" = usage_usec ]; then
      printf '%s' "$v"
      return 0
    fi
  done <"$1/cpu.stat"
}

# psi FILE KIND: avg10 of the "some" or "full" line.
psi() {
  local kind f rest
  [ -r "$1" ] || return 0
  while read -r kind f rest; do
    if [ "$kind" = "$2" ]; then
      printf '%s' "${f#avg10=}"
      return 0
    fi
  done <"$1"
}

num() { [ -n "$1" ] && printf '%s' "$1" || printf 'null'; }

prev_total=""
prev_idle=""
prev_dts=""
prev_sect=""
prev_ios=""
prev_ioms=""

while [ "$stop" -eq 0 ]; do
  ts=$(now)
  t=$(awk -v a="$ts" -v b="$ORIGIN" 'BEGIN{printf "%.3f", a-b}')
  if awk -v t="$t" -v d="$DURATION" 'BEGIN{exit !(t>d)}'; then
    break
  fi

  memavail="" cached=""
  while read -r k v _; do
    case "$k" in
    MemAvailable:) memavail=$v ;;
    Cached:) cached=$v ;;
    esac
  done <"$PROC/meminfo"

  read -r _ u n s i w q sq st _ <"$PROC/stat"
  total=$((u + n + s + i + w + q + sq + st))
  idle=$((i + w))
  busy_field=""
  if [ -n "$prev_total" ] && [ "$total" -gt "$prev_total" ]; then
    busy_field=$(awk -v dt=$((total - prev_total)) -v di=$((idle - prev_idle)) \
      'BEGIN{printf "%.2f", (dt-di)*100.0/dt}')
  fi
  prev_total=$total
  prev_idle=$idle

  vm_json=""
  if [ -d "$VMS_DIR" ]; then
    for d in "$VMS_DIR"/*/; do
      d=${d%/}
      name=${d##*/}
      case "$name" in *.service | *.scope | '*') continue ;; esac
      procs=$(file_val "$d/cgroup.procs")
      [ -n "$procs" ] || continue
      m=$(file_val "$d/memory.current")
      [ -n "$m" ] || continue
      vm_json+="${vm_json:+,}\"$name\":$m"
    done
  fi

  pids=("$PROC"/[0-9]*)
  procs_n=${#pids[@]}

  disk=$(df -Pk "$DISK_PATH" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5" "$3}')
  disk_pct=${disk% *}
  disk_kb=${disk#* }

  # /proc/diskstats: 4 reads completed, 6 sectors read, 7 ms reading, 8 writes completed, 11 ms writing
  dread_field="" dawait_field=""
  if [ -n "$DISK_DEV" ]; then
    ds=$(awk -v d="$DISK_DEV" '$3==d{print $4+$8, $6, $7+$11; exit}' "$PROC/diskstats" 2>/dev/null)
    if [ -n "$ds" ]; then
      read -r ios sect ioms <<<"$ds"
      if [ -n "$prev_dts" ]; then
        dread_field=$(awk -v ds=$((sect - prev_sect)) -v a="$ts" -v b="$prev_dts" \
          'BEGIN{dt=a-b; if (dt>0) printf "%.3f", ds*512/1e6/dt}')
        [ $((ios - prev_ios)) -gt 0 ] && dawait_field=$(awk -v m=$((ioms - prev_ioms)) -v n=$((ios - prev_ios)) 'BEGIN{printf "%.3f", m/n}')
      fi
      prev_dts=$ts prev_sect=$sect prev_ios=$ios prev_ioms=$ioms
    fi
  fi

  stats=""
  if command -v curl >/dev/null 2>&1; then
    stats=$(curl -s -m 0.5 "$STATS_URL" 2>/dev/null | tr -d '\n')
    case "$stats" in "{"*"}") ;; *) stats="" ;; esac
  fi

  line="{\"t\":$t,\"ts\":$ts,\"mem_available_kb\":$(num "$memavail"),\"page_cache_kb\":$(num "$cached")"
  [ -n "$busy_field" ] && line+=",\"host_cpu_busy_pct\":$busy_field"
  line+=",\"slice_mem_bytes\":$(num "$(file_val "$VMS_DIR/memory.current")")"
  line+=",\"slice_cpu_usec\":$(num "$(cpu_usec "$VMS_DIR")")"
  line+=",\"e15_mem_bytes\":$(num "$(file_val "$E15_DIR/memory.current")")"
  line+=",\"e15_cpu_usec\":$(num "$(cpu_usec "$E15_DIR")")"
  line+=",\"psi_cpu_some_avg10\":$(num "$(psi "$PROC/pressure/cpu" some)")"
  line+=",\"psi_mem_some_avg10\":$(num "$(psi "$PROC/pressure/memory" some)")"
  line+=",\"psi_mem_full_avg10\":$(num "$(psi "$PROC/pressure/memory" full)")"
  line+=",\"slice_psi_mem_some_avg10\":$(num "$(psi "$VMS_DIR/memory.pressure" some)")"
  line+=",\"disk_used_pct\":$(num "$disk_pct"),\"disk_used_kb\":$(num "$disk_kb")"
  [ -n "$dread_field" ] && line+=",\"disk_read_mbs\":$dread_field"
  [ -n "$dawait_field" ] && line+=",\"disk_await_ms\":$dawait_field"
  line+=",\"procs\":$procs_n,\"vm_mem\":{$vm_json}"
  [ -n "$stats" ] && line+=",\"worker\":$stats"
  line+="}"
  printf '%s\n' "$line" >>"$OUT"

  # Sleep to the next whole second after ORIGIN, so samples sit near integer t.
  frac=$(awk -v t="$t" 'BEGIN{f=t-int(t); s=1-f; if (s<0.05) s+=1; printf "%.3f", s}')
  sleep "$frac" &
  wait $! 2>/dev/null || true
done
