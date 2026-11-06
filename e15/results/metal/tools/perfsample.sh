#!/usr/bin/env bash
# perfsample.sh OUT START_DELAY_S WINDOW_S: after START_DELAY_S, take a 60 s system-wide perf stat sample every 300 s
# until WINDOW_S has passed; one JSON line per sample in OUT: cycles, instructions, LLC loads/misses, aperf/mperf,
# IMC CAS read/write (MiB), plus /proc/pressure cpu+memory and host busy %. Read-only (perf stat as root).
OUT=$1; DELAY=$2; WIN=$3
sleep "$DELAY"
end=$((SECONDS + WIN))
while [ $SECONDS -lt $end ]; do
  t0=$(date +%s)
  s1=$(awk '/^cpu /{print $2+$3+$4+$7+$8, $5+$6}' /proc/stat)
  csv=$(sudo -n perf stat -a -x, -e cycles,instructions,LLC-loads,LLC-load-misses,msr/aperf/,msr/mperf/,uncore_imc/cas_count_read/,uncore_imc/cas_count_write/ sleep 60 2>&1)
  s2=$(awk '/^cpu /{print $2+$3+$4+$7+$8, $5+$6}' /proc/stat)
  python3 - "$OUT" "$t0" "$s1" "$s2" "$csv" "$(cat /proc/pressure/cpu)" "$(cat /proc/pressure/memory)" <<'PY'
import json, sys
out, t0, s1, s2, csv, pc, pm = sys.argv[1:8]
v = {}
for line in csv.splitlines():
    f = line.split(",")
    if len(f) > 2:
        try:
            v[f[2]] = float(f[0])
        except ValueError:
            pass
b1, i1 = map(float, s1.split()); b2, i2 = map(float, s2.split())
busy = 100.0 * (b2 - b1) / max(1.0, (b2 - b1) + (i2 - i1))
cy, ins = v.get("cycles"), v.get("instructions")
r = {"t0": int(t0), "secs": 60, "host_busy_pct": busy,
     "ipc": ins / cy if cy else None,
     "llc_miss_rate": (v.get("LLC-load-misses") / v["LLC-loads"]) if v.get("LLC-loads") else None,
     "llc_misses_per_s": v.get("LLC-load-misses", 0) / 60.0,
     "aperf_mperf": (v["msr/aperf/"] / v["msr/mperf/"]) if v.get("msr/mperf/") else None,
     "mem_read_mib_s": v.get("uncore_imc/cas_count_read/", 0) / 60.0,
     "mem_write_mib_s": v.get("uncore_imc/cas_count_write/", 0) / 60.0,
     "psi_cpu": pc, "psi_memory": pm, "raw": v}
with open(out, "a") as f:
    f.write(json.dumps(r) + "\n")
PY
  sleep $((300 - ($(date +%s) - t0))) 2>/dev/null || true
done
