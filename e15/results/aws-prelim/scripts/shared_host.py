#!/usr/bin/env python3
"""SPEC §12 shared-host check for one rung dir: non-E15 CPU (% of host) over the measured window.
other = host_cpu_busy_pct - e15.slice CPU share - driver CPU share, per 1 s sample; spike = a 10 s
rolling mean above 10% of host CPU. Writes shared-host.json in the rung dir, prints repeat true/false."""
import json, os, sys
d = sys.argv[1]
ncpu = int(sys.argv[2]) if len(sys.argv) > 2 else 4
p = json.load(open(os.path.join(d, "params.json")))
warm, win = p["warmup_s"], p["window_s"]
rows = [json.loads(l) for l in open(os.path.join(d, "samples.jsonl")) if l.strip()]
drv = []
try:
    for l in open(os.path.join(d, "driver-cpu.jsonl")):
        r = json.loads(l)
        if not r.get("header"):
            drv.append(r)
except OSError:
    pass
def drv_pct(t0, t1):
    pts = [r for r in drv if "t" in r and ("cpu_usec" in r or "cpu_s" in r)]
    return None
other = []
prev = None
for r in rows:
    if prev is not None and "host_cpu_busy_pct" in r and warm <= r["t"] <= warm + win:
        dt = r["ts"] - prev["ts"]
        if dt > 0:
            e15 = (r["e15_cpu_usec"] - prev["e15_cpu_usec"]) / 1e6 / dt / ncpu * 100
            other.append((r["t"], r["host_cpu_busy_pct"] - e15, r["host_cpu_busy_pct"], e15))
    prev = r
vals = [o[1] for o in other]
roll = []
for i in range(len(vals)):
    w = vals[max(0, i - 9): i + 1]
    roll.append(sum(w) / len(w))
mx = max(roll) if roll else None
mean = sum(vals) / len(vals) if vals else None
srt = sorted(vals)
p95 = srt[int(0.95 * (len(srt) - 1))] if srt else None
host_mean = sum(o[2] for o in other) / len(other) if other else None
out = {"rule": "SPEC 12: repeat when non-E15 CPU (host busy - e15.slice share) has a 10 s rolling mean > 10% of host CPU inside the window",
       "samples": len(vals), "other_pct_mean": mean, "other_pct_p95": p95, "other_pct_roll10_max": mx,
       "host_busy_pct_mean": host_mean,
       "spike_t": other[roll.index(mx)][0] if roll else None, "repeat": bool(mx is not None and mx > 10)}
json.dump(out, open(os.path.join(d, "shared-host.json"), "w"), indent=2)
print(json.dumps(out))
