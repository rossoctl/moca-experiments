#!/usr/bin/env bash
# climb.sh -- supplementary (NOT sealed) continuation for the metal DEFAULT arms (user decisions 2026-11-04/05).
# Per arm: from the sealed ladder's stopped_at rung (re-judged, not re-run) up the metal ladder (<= 1024), each new
# rung run by rung.sh with E15_TAG=1s (its record.json is the sealed-rule record), then re-judged twice with the
# 2cb8e30/d37e53e analysis copy in /tmp/e15-analysis-1s: record_1s.json (flat 1000 ms condition 4) and
# record_cpu.json (conditions 1-3 only). A rung whose sum-basis drift needs a repeat is re-run once with tag
# 1s-repeat at warm-up 2400 s; the repeat counts. Climb stops at the first rung failing record_cpu (conditions 1-3).
# n_max_1s = largest N with record_1s holding and every lower rung holding it; n_max_cpu likewise for record_cpu.
# perfsample.sh runs inside each new rung's measured window. Sentinel as in ladders.sh. Emits "CLIMB ..." lines.
set -uo pipefail
export E15_HOST_PROFILE=fresh-metal PATH=/srv/e15/bin:$PATH
unset E15_MAX_SESSIONS E15_START_ZERO E15_TAG E15_SEED E15_WARMUP_S E15_WINDOW_S
R=/srv/e15/src/e15/rig
AN=/tmp/e15-analysis-1s
T=/srv/e15/calibration-metal/tools
L=/srv/e15/ladders-metal
mkdir -p "$L"; rm -f "$L/STOP"
ARMS=${ARMS:-"sbx resident-inf resident-300"}
LADDER=(1 8 16 24 32 40 48 56 64 80 96 128 160 192 256 320 384 448 512 576 640 704 768 896 1024)
since=$(date '+%Y-%m-%d %H:%M:%S')
sentinel() {
  while :; do
    if journalctl -k --since "$since" --no-pager 2>/dev/null | grep 'Out of memory: Killed process' | grep -qv 'Memory cgroup'; then
      echo "global_oom $(date -u +%FT%TZ)" >"$L/STOP"; fi
    free_kb=$(df -k --output=avail /srv/e15 | tail -1)
    [ "$free_kb" -lt $((10 * 1024 * 1024)) ] && echo "disk_free_${free_kb}kB $(date -u +%FT%TZ)" >"$L/STOP"
    if [ -s "$L/STOP" ]; then
      pkill -f "$R/rung.sh"; pkill -x e15-driver; pkill -f perfsample.sh
      bash -c "source $R/lib.sh; stop_rung_units" >/dev/null 2>&1
      echo "CLIMB SENTINEL STOP $(cat "$L/STOP")"; return; fi
    sleep 20
  done
}
sentinel &
spid=$!
judge() { # judge DIR -> "1s cpu" booleans
  python3 "$AN/record.py" "$1" --params "$1/params.json" --p95-limit-ms 1000 --out "$1/record_1s.json" >/dev/null &&
    python3 "$AN/record.py" "$1" --params "$1/params.json" --ignore-c4 --out "$1/record_cpu.json" >/dev/null &&
    python3 -c 'import json,sys; d=sys.argv[1]; a=json.load(open(d+"/record_1s.json")); b=json.load(open(d+"/record_cpu.json"))
print("true" if a["holds"] else "false", "true" if b["holds"] else "false", "true" if b.get("repeat_required") else "false")' "$1"
}
for arm in $ARMS; do
  [ -s "$L/STOP" ] && break
  base=/srv/e15/runs/default/$arm
  start=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["stopped_at"] or "")' "$base/ladder.json")
  [ -n "$start" ] || { echo "CLIMB $arm SKIP no stopped_at"; continue; }
  sup=$base/supplementary-1s
  mkdir -p "$sup"; : >"$sup/climb.jsonl"
  # the sealed ladder's own rungs, re-judged (no re-run)
  n_1s=null n_cpu=null alive_1s=1 alive_cpu=1 stop_1s=null stop_cpu=null
  for n in "${LADDER[@]}"; do
    [ "$n" -le "$start" ] || break
    d=$base/N$n; [ -f "$d/record.json" ] || continue
    read -r h1 hc _ < <(judge "$d")
    [ "$alive_1s" = 1 ] && { if [ "$h1" = true ]; then n_1s=$n; else alive_1s=0; stop_1s=$n; fi; }
    [ "$alive_cpu" = 1 ] && { if [ "$hc" = true ]; then n_cpu=$n; else alive_cpu=0; stop_cpu=$n; fi; }
    printf '{"n":%s,"dir":"%s","sealed_rung":true,"holds_1s":%s,"holds_cpu":%s}\n' "$n" "$d" "$h1" "$hc" >>"$sup/climb.jsonl"
  done
  echo "CLIMB $arm START from=$start (re-judged sealed rungs: n_max_1s=$n_1s n_max_cpu=$n_cpu) $(date -u +%FT%TZ)"
  for n in "${LADDER[@]}"; do
    [ "$n" -gt "$start" ] || continue
    [ "$alive_cpu" = 1 ] || break
    [ -s "$L/STOP" ] && break
    if [ "$n" -gt 128 ]; then # disk headroom at K x2 (a repeat's K): the refusal estimate scales with K
      km=2; [ "$arm" = sbx ] && km=1   # sbx has no footprint repeat
      need=$(python3 -c 'import sys; print(int(int(sys.argv[1]) * 16 * int(sys.argv[2]) * 22 * 1.1 * 1024))' "$n" "$km")
      free_kb=$(df -k --output=avail /srv/e15 | tail -1)
      [ "$need" -lt "$free_kb" ] || { echo "CLIMB $arm N=$n DISK need ${need}kB free ${free_kb}kB at K x$km: stop"; break; }
    fi
    ( bash "$T/perfsample.sh" "$base/N$n-1s.perf.jsonl" 1230 900 ) &
    ppid=$!
    E15_TAG=1s bash "$R/rung.sh" "$arm" "$n" default >"$L/climb-$arm-N$n.log" 2>&1 || { kill $ppid 2>/dev/null; echo "CLIMB $arm N=$n RIG_ERROR $(tail -1 "$L/climb-$arm-N$n.log")"; break; }
    kill $ppid 2>/dev/null; wait $ppid 2>/dev/null
    d=$base/N$n-1s; mv "$base/N$n-1s.perf.jsonl" "$d/perf.jsonl" 2>/dev/null
    if [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("unseeded_sessions") or 0)' "$d/record.json")" != 0 ]; then
      echo "CLIMB $arm N=$n first run unseeded: re-run with K x2 (tag 1s-k2)"
      E15_TAG=1s-k2 E15_K_MULT=2 bash "$R/rung.sh" "$arm" "$n" default >"$L/climb-$arm-N$n-k2.log" 2>&1 || { echo "CLIMB $arm N=$n k2 RIG_ERROR"; break; }
      d=$base/N$n-1s-k2
    fi
    read -r h1 hc rep < <(judge "$d")
    if [ "$rep" = true ]; then
      ( bash "$T/perfsample.sh" "$base/N$n-1s-repeat.perf.jsonl" 2430 900 ) &
      ppid=$!
      E15_TAG=1s-repeat E15_WARMUP_S=2400 E15_K_MULT=2 bash "$R/rung.sh" "$arm" "$n" default >"$L/climb-$arm-N$n-repeat.log" 2>&1 || { kill $ppid 2>/dev/null; echo "CLIMB $arm N=$n repeat RIG_ERROR"; break; }
      kill $ppid 2>/dev/null; wait $ppid 2>/dev/null
      d=$base/N$n-1s-repeat; mv "$base/N$n-1s-repeat.perf.jsonl" "$d/perf.jsonl" 2>/dev/null
      read -r h1 hc rep < <(judge "$d")
    fi
    [ "$alive_1s" = 1 ] && { if [ "$h1" = true ]; then n_1s=$n; else alive_1s=0; stop_1s=$n; fi; }
    if [ "$hc" = true ]; then n_cpu=$n; else alive_cpu=0; stop_cpu=$n; fi
    printf '{"n":%s,"dir":"%s","sealed_rung":false,"holds_1s":%s,"holds_cpu":%s}\n' "$n" "$d" "$h1" "$hc" >>"$sup/climb.jsonl"
    echo "CLIMB $arm N=$n holds_1s=$h1 holds_cpu=$hc $(date -u +%FT%TZ)"
  done
  printf '{"arm":"%s","start_n":%s,"n_max_1s":%s,"stopped_at_1s":%s,"n_max_cpu":%s,"stopped_at_cpu":%s,"ladder_top":1024}\n' \
    "$arm" "$start" "$n_1s" "$stop_1s" "$n_cpu" "$stop_cpu" >"$sup/climb.json"
  echo "CLIMB $arm DONE n_max_1s=$n_1s stop_1s=$stop_1s n_max_cpu=$n_cpu stop_cpu=$stop_cpu $(date -u +%FT%TZ)"
done
kill "$spid" 2>/dev/null
echo "CLIMB ALL END $(date -u +%FT%TZ)"
