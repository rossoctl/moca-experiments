"""SBX vs resident relative slowdown by rung (supplementary, not sealed), with the climb's perf samples.

  python3 compare_slowdown.py METAL_DIR  -> markdown on stdout

Per default arm and N (the sealed ladder's counted rung, then the supplementary climb rungs): over window calls
planned >= 1 s, observed / planned median and p95; the same for calls planned >= 30 s ("long"); host CPU busy mean
(samples.jsonl.gz); and from perf.jsonl (climb rungs only) the mean IPC, LLC miss rate, aperf/mperf and DRAM read.
The hypothesis this tests: SBX's slowdown on CPU-heavy calls is per-VM cold state (a fresh guest page cache and
cold CPU caches per command), not host contention -- then SBX's long-call slowdown exceeds resident's at equal N
with the host's perf counters unsaturated.
"""
import gzip
import json
import math
import os
import statistics as st
import sys

M = sys.argv[1]


def q(v, p):
    v = sorted(v)
    return v[max(0, int(math.ceil(p / 100.0 * len(v))) - 1)] if v else None


def rows(arm):
    base = os.path.join(M, "default", arm)
    out = {}
    lj = json.load(open(os.path.join(base, "ladder.json")))
    for r in lj["rungs"]:
        out[r["n"]] = os.path.join(base, os.path.basename(r["dir"]))
    cj = os.path.join(base, "supplementary-1s", "climb.jsonl")
    if os.path.exists(cj):
        for line in open(cj):
            r = json.loads(line)
            if not r["sealed_rung"]:
                out[r["n"]] = os.path.join(base, "supplementary-1s", os.path.basename(r["dir"]))
    return out


def stats(d):
    if not os.path.exists(os.path.join(d, "calls.jsonl")):
        return None
    a, lng = [], []
    for line in open(os.path.join(d, "calls.jsonl")):
        c = json.loads(line)
        if c.get("in_window") and c.get("status") == "ok":
            pl = c["planned_dur_ms"] - c.get("tail_ms", 0)
            if pl >= 1000:
                a.append(c["observed_ms"] / pl)
            if pl >= 30000:
                lng.append(c["observed_ms"] / pl)
    cpu = None
    sp = os.path.join(d, "samples.jsonl.gz")
    if os.path.exists(sp):
        p = json.load(open(os.path.join(d, "params.json")))
        ws = [s for s in (json.loads(x) for x in gzip.open(sp, "rt"))
              if p["warmup_s"] <= s.get("t", -1) <= p["warmup_s"] + p["window_s"]]
        cpu = st.mean(s.get("host_cpu_busy_pct", 0) for s in ws) if ws else None
    perf = None
    pp = os.path.join(d, "perf.jsonl")
    if os.path.exists(pp):
        xs = [json.loads(x) for x in open(pp) if x.strip()]
        if xs:
            m = lambda k: st.mean(x[k] for x in xs if x.get(k) is not None)  # noqa: E731
            perf = (m("ipc"), m("llc_miss_rate"), m("aperf_mperf"), m("mem_read_mib_s"))
    return {"n_ge1": len(a), "med": q(a, 50), "p95": q(a, 95), "n_long": len(lng), "long_med": q(lng, 50),
            "long_p95": q(lng, 95), "cpu": cpu, "perf": perf}


f = lambda x, k="%.3f": "" if x is None else k % x  # noqa: E731
arms = ("sbx", "resident-inf", "resident-300")
R = {a: rows(a) for a in arms if os.path.exists(os.path.join(M, "default", a, "ladder.json"))}
ns = sorted({n for a in R for n in R[a]})
print("| N | arm | calls ≥ 1 s | slowdown median | p95 | calls ≥ 30 s | long median | long p95 | host CPU % | IPC | LLC miss | aperf/mperf | DRAM read MiB/s |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
for n in ns:
    for a in arms:
        if a not in R or n not in R[a]:
            continue
        s = stats(R[a][n])
        if not s:
            continue
        pf = s["perf"] or (None, None, None, None)
        print("| %d | %s | %d | %s | %s | %d | %s | %s | %s | %s | %s | %s | %s |" % (
            n, a, s["n_ge1"], f(s["med"]), f(s["p95"]), s["n_long"], f(s["long_med"]), f(s["long_p95"]),
            f(s["cpu"], "%.1f"), f(pf[0], "%.2f"), f(pf[1], "%.3f"), f(pf[2], "%.3f"), f(pf[3], "%.0f")))
