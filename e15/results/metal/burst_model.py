"""Burst-aware N_max estimate for E15 (coordinator item 1, metal draft predictions).

  python3 burst_model.py CORPUS LIBRARY --vcpu V --core-s C [--life-s L] [--ns 8,16,...] [--seeds 3]
                         [--limit-ms X] [--host-over S] [--warmup 600 --window 900]

Why: on AWS (4 vCPU) the average-CPU model predicted SBX N_max in [40, 48]; every arm measured
n_max 8, failing condition 4 on the p95 tail at ~41% mean host CPU with 0 failed calls. A rung
fails when bursts of CPU-heavy calls overlap and stretch each other, long before the mean CPU
reaches the wall. This model replays that mechanism.

Model (deliberately small; every parameter is a measured calibration number or a stated
assumption):
  - N sessions replay the corpus as the driver does: each slot draws sessions (seeded), starts at
    a uniform index in [0, len-3], sends call k+1 at max(previous send + recorded offset, previous
    end); slots' first sessions spread over 60 s; a finished session is replaced at once.
  - Each call is one job with CPU demand d = work_ms x cpu/run(class) x S, where cpu/run is the
    library's measured ratio and S scales the total so that the mean demand per call equals the
    MEASURED slice core-s per call at N=8 (C, which includes guest kernel, VMM and, for SBX, the
    VM lifecycle). A call's wall time alone is max(dur_ms, d) (I/O-ish classes have d << dur).
  - Guests have 1 vCPU, so one call uses at most 1 core. The host has V cores; the jobs in
    service share them processor-sharing style: each gets min(1, V / active) cores.
  - The host also burns an idle overhead of `host_over` cores (standbys, worker, relay).
  - Added latency of a call = the stretch of its CPU part (CPU-time wall at the shared rate - d);
    its non-CPU time (dur - d) is uncontended. The next call waits for the stretched end. The rung's
    p95 excess is the p95 of added latency over the window calls (the N=1 class medians are
    ~0 in this model by construction, so excess == added). Holds when p95 <= limit_ms.
It ignores: memory, disk, the lifecycle's own serial phases, NUMA/HT effects (a 96-vCPU host is
48 cores x 2 threads; two busy guests on one core's threads each run at ~0.6x -- see --ht).
"""
import argparse
import heapq
import json
import math
import random


def load_corpus(p):
    out = []
    with open(p) as f:
        for line in f:
            s = json.loads(line)
            if len(s["calls"]) >= 3:
                out.append(s)
    return out


def class_ratio(lib):
    d = json.load(open(lib))
    r = {c: sum(i["cpu_ms"] for i in l) / float(sum(i["run_ms"] for i in l)) for c, l in d["classes"].items()}
    interp = r[d["standin"]["interpreter_class"]]
    r["_interp"] = interp
    r["_infra"] = (1 - d["standin"]["infra_sleep_frac"]) * interp
    return r


def demand_ms(call, ratio):
    cls = call["class"]
    if cls == "host_infra":
        k = ratio["_infra"]
    else:
        k = ratio.get(cls, ratio["_interp"])
    return call["work_ms"] * k


def mean_demand(corpus, ratio):
    tot = n = 0
    for s in corpus:
        for c in s["calls"]:
            tot += demand_ms(c, ratio)
            n += 1
    return tot / n


def simulate(corpus, ratio, scale, life_ms, n, vcpu, seed, warmup, window, host_over, ht, scan_ms=0.0, scan_cls=()):
    rng = random.Random(seed)
    order = list(range(len(corpus)))
    rng.shuffle(order)
    pos = [0]

    def draw():
        i = order[pos[0] % len(order)]
        pos[0] += 1
        s = corpus[i]
        return s, rng.randint(0, len(s["calls"]) - 3)

    end_t = (warmup + window) * 1000.0
    # events: (time, kind, slot); arrivals pushed when the previous call ends
    arrivals = []
    slots = []
    for k in range(n):
        s, st = draw()
        t0 = 60000.0 * k / max(1, n - 1)
        slots.append({"s": s, "i": st, "prev_send": None})
        heapq.heappush(arrivals, (t0, k))
    active = {}  # job id -> dict(rem, slot, send, base, cls)
    jid = 0
    t = 0.0
    added = []
    cap = vcpu - host_over

    def rate():
        a = len(active)
        if a == 0:
            return 0.0
        eff = cap
        if ht and a > vcpu / 2.0:
            # SMT: beyond one job per physical core, extra threads add ~25% each core
            phys = vcpu / 2.0
            eff = min(cap, phys + 0.25 * (min(a, vcpu) - phys))
        return min(1.0, eff / a)

    while True:
        r = rate()
        # next completion
        nxt_done = None
        if active:
            j = min(active, key=lambda x: active[x]["rem"])
            nxt_done = t + active[j]["rem"] / r
        nxt_arr = arrivals[0][0] if arrivals else None
        if nxt_arr is None and nxt_done is None:
            break
        if nxt_done is not None and (nxt_arr is None or nxt_done <= nxt_arr):
            dt = nxt_done - t
            for x in active.values():
                x["rem"] -= dt * r
            t = nxt_done
            done = [x for x in active if active[x]["rem"] <= 1e-6]
            for x in done:
                job = active.pop(x)
                stretch = (t - job["send"]) - job["d"]   # the CPU part's slowdown
                end = job["send"] + job["dur"] + max(0.0, stretch)
                if warmup * 1000.0 <= job["send"] <= end_t:
                    added.append(stretch)
                sl = slots[job["slot"]]
                # schedule the slot's next call
                sl["i"] += 1
                if sl["i"] >= len(sl["s"]["calls"]):
                    s, _ = draw()
                    sl["s"], sl["i"], sl["prev_send"] = s, rng.randint(0, len(s["calls"]) - 3), None
                    nt = end
                else:
                    off = sl["s"]["calls"][sl["i"]]["offset_ms"]
                    nt = max(job["send"] + off, end)
                if nt <= end_t:
                    heapq.heappush(arrivals, (nt, job["slot"]))
        else:
            dt = nxt_arr - t
            for x in active.values():
                x["rem"] -= dt * r
            t, k = heapq.heappop(arrivals)
            sl = slots[k]
            c = sl["s"]["calls"][sl["i"]]
            d = demand_ms(c, ratio) * scale + life_ms + (scan_ms if c["class"] in scan_cls else 0.0)
            # the job's CPU demand d runs processor-shared; its non-CPU time (dur - d) is not
            # contended. Added latency = the CPU part's stretch.
            active[jid] = {"rem": max(d, 1e-3), "slot": k, "send": t, "d": max(d, 1e-3),
                           "dur": max(float(c["dur_ms"]), d)}
            jid += 1
    added.sort()
    if not added:
        return None, 0
    k = max(0, int(math.ceil(0.95 * len(added))) - 1)
    return added[k], len(added)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("corpus")
    ap.add_argument("library")
    ap.add_argument("--vcpu", type=float, required=True)
    ap.add_argument("--core-s", type=float, required=True, help="measured slice core-s per call at N=8")
    ap.add_argument("--life-s", type=float, default=0.0, help="per-call lifecycle core-s (part of core-s)")
    ap.add_argument("--ns", default="1,8,16,24,32,40,48")
    ap.add_argument("--seeds", type=int, default=3)
    ap.add_argument("--limit-ms", type=float, default=None)
    ap.add_argument("--host-over", type=float, default=0.0)
    ap.add_argument("--ht", action="store_true")
    ap.add_argument("--scan-s", type=float, default=0.0, help="mem512: fixed CPU s per call of a scanning class")
    ap.add_argument("--scan-classes", default="read,shell_read,search,test,interpreter,lint_check")
    ap.add_argument("--ladder", default=None, help="comma list: report n_max per seed on this ladder (needs --limit-ms)")
    ap.add_argument("--warmup", type=float, default=600)
    ap.add_argument("--window", type=float, default=900)
    a = ap.parse_args()
    corpus = load_corpus(a.corpus)
    ratio = class_ratio(a.library)
    md = mean_demand(corpus, ratio)
    scls = set(a.scan_classes.split(",")) if a.scan_s else set()
    share = (sum(1 for s in corpus for c in s["calls"] if c["class"] in scls) /
             float(sum(len(s["calls"]) for s in corpus))) if scls else 0.0
    scale = (a.core_s * 1000.0 - a.life_s * 1000.0 - share * a.scan_s * 1000.0) / md
    out = {"mean_lib_demand_ms": md, "scale": scale, "scan_share": share, "rows": []}
    for n in [int(x) for x in a.ns.split(",")]:
        p = []
        for s in range(1, a.seeds + 1):
            v, cnt = simulate(corpus, ratio, scale, a.life_s * 1000.0, n, a.vcpu, s, a.warmup, a.window, a.host_over, a.ht,
                              a.scan_s * 1000.0, scls)
            p.append(v)
        row = {"n": n, "p95_added_ms": p, "median": sorted(p)[len(p) // 2]}
        if a.limit_ms is not None:
            row["holds_median"] = row["median"] <= a.limit_ms
        out["rows"].append(row)
        print(json.dumps(row), flush=True)
    print(json.dumps({k: v for k, v in out.items() if k != "rows"}))


if __name__ == "__main__":
    main()
