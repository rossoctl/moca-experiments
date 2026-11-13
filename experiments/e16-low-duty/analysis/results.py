#!/usr/bin/env python3
"""Build experiments/e16-low-duty/results/summary.json and print the tables RESULTS.md uses, from the pulled rungs.

  python3 experiments/e16-low-duty/analysis/results.py            (reads experiments/e16-low-duty/results/{sbx,resident-inf,control}/, experiments/e16-low-duty/predictions.json)

Per arm: the assembled ladder.json (sealed primary verdicts, seeds by majority), n_max_abs, and the
supplementary re-judges (record_1s.json, record_cpu.json) of the same rungs -> n_max_1s, n_max_cpu
(largest run rung holding with every run rung below holding; censored at the top run rung). Per rung:
p95 excess, limit, window calls, class pace, failed calls, refusals, reason, host CPU mean/p95 over the
window, live VMs (window max), summed VM memory and slice memory (window max, GiB), MemAvailable min,
replayed duty, distinct-trace share, A2. Then each sealed prediction's verdict (rules in the code,
from predictions.json's metric/falsifiedBy) and the hypothesis verdict (SPEC §7.2).
"""
import glob
import gzip
import json
import os

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
if not os.path.isdir(os.path.join(ROOT, "e15", "analysis")):      # this repo: one level deeper
    ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
_E16 = os.path.join(ROOT, "experiments", "e16-low-duty")
if not os.path.isdir(_E16):
    _E16 = os.path.join(ROOT, "e16")  # the rig's staged layout (/srv/e15/src)
RES = os.path.join(_E16, "results")
LADDER = [1, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 128, 160, 192, 256, 320, 384, 448, 512, 576, 640, 704, 768, 896, 1024, 1280, 1536]
GiB = float(1 << 30)


def jl(p):
    return json.load(open(p))


def local(d):
    """A host path in a row -> the pulled directory."""
    if d.startswith(ROOT):
        return d
    arm = d.rstrip("/").split("/")[-2]
    return os.path.join(RES, arm, os.path.basename(d.rstrip("/")))


def window(d):
    p = jl(os.path.join(d, "params.json"))
    a, b = p["warmup_s"], p["warmup_s"] + p["window_s"]
    ws = []
    with gzip.open(os.path.join(d, "samples.jsonl.gz"), "rt") as f:
        for line in f:
            if line.strip():
                s = json.loads(line)
                if a <= s.get("t", -1) <= b:
                    ws.append(s)
    busy = sorted(s["host_cpu_busy_pct"] for s in ws if "host_cpu_busy_pct" in s)
    return {"host_cpu_mean": sum(busy) / len(busy) if busy else None,
            "host_cpu_p95": busy[int(0.95 * (len(busy) - 1))] if busy else None,
            "live_vms_max": max((len(s.get("vm_mem") or {}) for s in ws), default=0),
            "vm_mem_sum_gib": max(sum((s.get("vm_mem") or {}).values()) for s in ws) / GiB,
            "slice_mem_gib": max(s.get("slice_mem_bytes", 0) for s in ws) / GiB,
            "mem_available_min_gib": min(s["mem_available_kb"] for s in ws) / 1048576.0,
            "psi_cpu_max": max(s.get("psi_cpu_some_avg10", 0) for s in ws)}


def rung(d):
    r = jl(os.path.join(d, "record.json"))
    out = {"dir": os.path.relpath(d, ROOT), "n": r["n"], "holds": r["holds"], "holds_abs": r["holds_abs"],
           "p95_excess_ms": r.get("p95_excess_ms"), "limit_ms": r.get("excess_limit_ms"),
           "limit_abs_ms": r.get("p95_limit_abs_ms"), "window_calls": r.get("window_calls"),
           "median_class_pace": r.get("median_class_pace"), "failed_calls": r.get("failed_calls"),
           "refusals": r.get("refusals"), "reason": r.get("reason"), "binding": r.get("binding"),
           "conditions": r.get("conditions"), "oom_kills": r.get("oom_kills"), "memory_abort": r.get("memory_abort"),
           "memory_events_window": r.get("memory_events_window"),
           "footprint_drift_pct": r.get("footprint_drift_pct"), "repeat_required": r.get("repeat_required"),
           "replayed_duty": r.get("replayed_duty"), "distinct_trace_share": r.get("distinct_trace_share"),
           "a2_pct": (r.get("driver") or {}).get("a2_pct_of_host"), "seed": r.get("seed")}
    for k in ("1s", "cpu"):
        f = os.path.join(d, "record_%s.json" % k)
        out["holds_" + k] = jl(f)["holds"] if os.path.exists(f) else None
    f = os.path.join(d, "record_nowedge.json")
    out["nowedge"] = ({"holds": jl(f)["holds"], "holds_abs": jl(f)["holds_abs"],
                       "excluded": jl(f)["nowedge"]["excluded_calls"]} if os.path.exists(f) else None)
    f = os.path.join(d, "stag_valid.json")
    out["stag_valid"] = jl(f) if os.path.exists(f) else None
    foot = [json.loads(l) for l in open(os.path.join(d, "driver-cpu.jsonl")) if '"footer"' in l]
    out["end_sessions"] = foot[-1] if foot else None
    wl = os.path.join(d, "worker.log.gz")
    out["egress_wedged"] = None
    if os.path.exists(wl):  # control has no worker
        with gzip.open(wl, "rt", errors="replace") as wf:
            out["egress_wedged"] = sum("stream ended (egress wedged" in l for l in wf)
    out.update(window(d))
    return out


def nmax(rows, key):
    n = stop = None
    for r in sorted(rows, key=lambda x: x["n"]):
        if r[key]:
            n = r["n"]
        else:
            stop = r["n"]
            break
    return n, stop


def arm(a):
    lj = jl(os.path.join(RES, a, "ladder.json"))
    rungs = []
    for rr in lj["rungs"]:
        seeds = []
        for s in rr["seeds"]:
            x = rung(local(s["dir"]))
            x["seed"] = s["seed"]
            x["grace_artefact_rerun"] = s.get("grace_artefact_rerun")
            x["first_dir"] = os.path.relpath(local(s["first_dir"]), ROOT) if s.get("first_dir") else None
            seeds.append(x)
        def maj(k):  # same seed rule as the sealed verdict (chainlib._majority)
            v = [x[k] for x in sorted(seeds, key=lambda x: x["seed"])]
            return v[0] if len(v) <= 2 else sum(bool(y) for y in v[:3]) >= 2
        rungs.append({"n": rr["n"], "holds": rr["holds"], "holds_abs": rr["holds_abs"],
                      # supplementary readings, decided by the same seed majority as the sealed verdict
                      "holds_1s": maj("holds_1s"), "holds_cpu": maj("holds_cpu"), "seeds": seeds})
    n1s, s1s = nmax(rungs, "holds_1s")
    ncpu, scpu = nmax(rungs, "holds_cpu")
    return {"arm": a, "n_max": lj["n_max"], "stopped_at": lj["stopped_at"], "n_max_abs": lj["n_max_abs"],
            "stopped_at_abs": lj["stopped_at_abs"], "n_max_1s": n1s, "stopped_at_1s": s1s,
            "n_max_cpu": ncpu, "stopped_at_cpu": scpu, "top_run": max(r["n"] for r in rungs),
            "rungs_not_run_assumed_held": lj.get("rungs_not_run_assumed_held"),
            "seeds_undecided": lj.get("seeds_undecided"), "rungs": rungs}


def step_index(n):
    return LADDER.index(n) if n in LADDER else None


def verdicts(sbx, res, ctl, pred):
    out = {}
    ns, nr = sbx["n_max"], res["n_max"]
    rng = {}
    for p in pred["predictions"]:
        if p["id"] == 1:
            import re
            m = re.findall(r"\[(\d+), (\d+)\]", p["claim"])
            rng = {"sbx": tuple(map(int, m[0])), "resident-inf": tuple(map(int, m[1]))}
    # SPEC §7.2: holds iff n_max(sbx) >= one ladder step above n_max(resident)
    if ns is None or nr is None:
        hyp = "holds" if (ns is not None and nr is None) else "falsified"
    else:
        hyp = "holds" if step_index(ns) >= step_index(nr) + 1 else "falsified"
    in_s = ns is not None and rng["sbx"][0] <= ns <= rng["sbx"][1]
    in_r = nr is not None and rng["resident-inf"][0] <= nr <= rng["resident-inf"][1]
    out[1] = {"hypothesis": hyp, "direction": "HOLDS" if hyp == "falsified" else "FALSIFIED",
              "sbx_in_range": in_s, "resident_in_range": in_r,
              "numeric": "HOLDS" if (in_s and in_r) else "FALSIFIED",
              "observed": {"sbx": ns, "resident-inf": nr}, "ranges": rng}
    # 2: first failed rung of each arm
    p2 = {}
    for a in (sbx, res):
        st = a["stopped_at"]
        if st is None:
            p2[a["arm"]] = {"tested": False}
            continue
        rr = [r for r in a["rungs"] if r["n"] == st][0]
        s1 = [x for x in rr["seeds"] if x["seed"] == 1][0]
        c = s1["conditions"] or {}
        mem = (s1["reason"] in ("memory_floor", "memory_high") or (s1["binding"] or "none") != "none"
               or (s1["oom_kills"] or 0) > 0 or s1["memory_abort"])
        ok = (c.get("added_latency") is False and c.get("no_failures") and c.get("no_refusals") and c.get("pace")
              and s1["failed_calls"] == 0 and not s1["refusals"] and not mem and (s1["host_cpu_mean"] or 0) < 25)
        p2[a["arm"]] = {"tested": True, "n": st, "conditions": c, "failed_calls": s1["failed_calls"],
                        "refusals": s1["refusals"], "binding": s1["binding"], "reason": s1["reason"],
                        "host_cpu_mean": s1["host_cpu_mean"], "holds": bool(ok)}
    tested = [v for v in p2.values() if v["tested"]]
    out[2] = {"per_arm": p2, "verdict": ("FALSIFIED" if any(not v["holds"] for v in tested) else
                                         "HOLDS" if len(tested) == 2 else "HOLDS (one arm untested)" if tested else "NOT TESTED")}
    # 3: resident memory at its N_max
    nm = [r for r in res["rungs"] if r["n"] == nr]
    if nm:
        s1 = [x for x in nm[0]["seeds"] if x["seed"] == 1][0]
        anymem = any((x["reason"] in ("memory_floor", "memory_high")) or (x["binding"] or "none") != "none"
                     or (x["oom_kills"] or 0) > 0 or x["memory_abort"] for r in res["rungs"] for x in r["seeds"])
        out[3] = {"n": nr, "vm_mem_sum_gib": s1["vm_mem_sum_gib"], "slice_mem_gib": s1["slice_mem_gib"],
                  "any_memory_verdict": anymem, "claimed_band_gib": [109, 163],
                  "in_band": 109 <= s1["vm_mem_sum_gib"] <= 163,
                  "verdict": "FALSIFIED" if (s1["vm_mem_sum_gib"] >= 189 or anymem) else "HOLDS"}
    else:
        out[3] = {"verdict": "NOT TESTED"}
    a2 = [x["a2_pct"] for a in (sbx, res) for r in a["rungs"] for x in r["seeds"] if x["a2_pct"] is not None]
    if ctl:
        a2 += [c["a2_pct"] for c in ctl if c["a2_pct"] is not None]
    out[4] = {"max_a2_pct": max(a2), "rungs": len(a2), "verdict": "HOLDS" if max(a2) < 1 else "FALSIFIED"}
    return out


def supp(a):
    f = os.path.join(RES, a, "ladder-supp.json")
    if not os.path.exists(f):
        return None
    d = jl(f)
    rows = []
    for r in d["rows"]:
        x = rung(local(r["dir"]))
        x.update(seed=r["seed"], tag=r.get("supplementary"), valid=r.get("valid"))
        rows.append(x)
    return {"verdicts": d["verdicts"], "rows": rows}


def main():
    pred = jl(os.path.join(_E16, "predictions.json"))
    sbx, res = arm("sbx"), arm("resident-inf")
    ctl = [rung(d) for d in sorted(glob.glob(os.path.join(RES, "control", "N*"))) if os.path.exists(os.path.join(d, "record.json"))]
    # The sealed verdict (SPEC 7.2) uses the sealed ladders only: SBX's rungs above 1024 are the
    # post-seal extension (ladder.sealed.json holds SBX's sealed assembly).
    sbx_sealed = dict(sbx, rungs=[r for r in sbx["rungs"] if r["n"] <= 1024])
    f = os.path.join(RES, "sbx", "ladder.sealed.json")
    if os.path.exists(f):
        x = jl(f)
        sbx_sealed.update({k: x.get(k) for k in ("n_max", "stopped_at", "n_max_abs", "stopped_at_abs")})
    v = verdicts(sbx_sealed, res, ctl, pred)
    v["post_seal"] = verdicts(sbx, res, ctl, pred)[1]
    sealed_sbx = None
    f = os.path.join(RES, "sbx", "ladder.sealed.json")
    if os.path.exists(f):
        x = jl(f)
        sealed_sbx = {k: x.get(k) for k in ("n_max", "stopped_at", "n_max_abs", "stopped_at_abs")}
    out = {"sbx": sbx, "resident-inf": res, "control": ctl, "verdicts": v,
           "sbx_sealed_ladder_before_extension": sealed_sbx,
           "supplementary": {"resident-inf": supp("resident-inf"), "sbx": supp("sbx")}}
    with open(os.path.join(RES, "summary.json"), "w") as f:
        json.dump(out, f, indent=1, ensure_ascii=False)
        f.write("\n")
    for a in (sbx, res):
        print("== %s n_max=%s stop=%s abs=%s/%s 1s=%s/%s cpu=%s/%s top=%s undecided=%s" % (
            a["arm"], a["n_max"], a["stopped_at"], a["n_max_abs"], a["stopped_at_abs"], a["n_max_1s"],
            a["stopped_at_1s"], a["n_max_cpu"], a["stopped_at_cpu"], a["top_run"], a["seeds_undecided"]))
        for r in a["rungs"]:
            for x in r["seeds"]:
                print("  N=%d s%d holds=%s abs=%s 1s=%s cpu=%s p95x=%s lim=%s calls=%s pace=%.5f fail=%s ref=%s reason=%s cpu=%.1f/%.1f live=%d vmsum=%.1f slice=%.1f avail=%.0f duty=%s dts=%s drift=%s grace=%s dir=%s" % (
                    r["n"], x["seed"], x["holds"], x["holds_abs"], x["holds_1s"], x["holds_cpu"],
                    x["p95_excess_ms"] and round(x["p95_excess_ms"]), x["limit_ms"] and round(x["limit_ms"]),
                    x["window_calls"], x["median_class_pace"] or 0, x["failed_calls"], x["refusals"], x["reason"],
                    x["host_cpu_mean"] or 0, x["host_cpu_p95"] or 0, x["live_vms_max"], x["vm_mem_sum_gib"],
                    x["slice_mem_gib"], x["mem_available_min_gib"],
                    x["replayed_duty"] and round(x["replayed_duty"]["median"], 4), x["distinct_trace_share"],
                    x["footprint_drift_pct"] and round(x["footprint_drift_pct"], 1), x["grace_artefact_rerun"],
                    os.path.basename(x["dir"])))
    for c in ctl:
        print("== control", c["n"], c["holds"], c["a2_pct"], c["window_calls"])
    print(json.dumps(v, indent=1, default=str))


if __name__ == "__main__":
    main()
