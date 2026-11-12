#!/usr/bin/env python3
"""E16 SPEC §6 step 2: the long rung's VM memory against age, to session end.

  python3 long_rung.py RUNG_DIR --out PREFIX [--label-root DIR]   (writes PREFIX.json and PREFIX.md)

Builds on vm_age.py (VM identity from worker.log restore/destroy through moca's LIFO cgroup free
list; 5-min age bins, per-VM bin medians). Adds what the long rung is for:

- growth from 20 min of age to 60, 120 and 180 min (median over VMs seen at both ages), with the
  number of VMs; plus every later bin (vm_age's growth_20_to);
- each VM's life: born (restore) to destroy, its last replayed Exec (worker.log `vmpool: exec ...
  vm=<id>` lines, the end-session marker Exec excluded; the line is stamped at the Exec's end) and
  the session's end-session marker; the lag from last Exec to destroy is how long a kept-forever
  VM outlives its last call. VMs destroyed at the run's end (the driver ends every live session
  there, mid-gap) are censored and reported apart: fix round 1's "median ~12 min" lag on E15 came
  from exactly those (a session cut in an idle gap); sessions that end on their own are destroyed
  right after their last call;
- VM age at session end (destroy), median / p90 / max, over VMs whose session ended;
- the VM memory distribution at 2.5 h, two readings: (a) VMs aged 150 min (the 150-154 min bin),
  (b) every VM alive at rung time t = 2.5 h after t0 (the sample nearest it): count, median, p95, max,
  sum. Sum against the host is the physical-memory reading the predictions need.
"""
import argparse
import bisect
import calendar
import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vm_age as V  # noqa: E402

MiB = float(1 << 20)
EXEC_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})Z vmpool: exec req=\S+ workspace_key=\"([^\"]*)\" vm=(vm-\d+) ")
END_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})Z vmpool: e15 resident end-session workspace_key=\"([^\"]*)\" vm=(vm-\d+)")
SNAP_S = 9000  # 2.5 h
CUT_TOL_S = 5


def _ts(s):
    return float(calendar.timegm(time.strptime(s, "%Y-%m-%dT%H:%M:%S")))


def _q(xs, q):
    xs = sorted(xs)
    if not xs:
        return None
    return xs[min(len(xs) - 1, max(0, int(round(q * (len(xs) - 1)))))]


def lives(d):
    """[{id, born, end, last_exec, end_session}] from worker.log."""
    vms = V.vm_table(V.read_events(d))
    last, ends = {}, {}
    with V._open(d, "worker.log") as f:
        for line in f:
            m = EXEC_RE.match(line)
            if m:
                # the end-session marker is itself an Exec, logged after its end-session line
                if m.group(3) not in ends:
                    last[m.group(3)] = _ts(m.group(1))
                continue
            m = END_RE.match(line)
            if m:
                ends[m.group(3)] = _ts(m.group(1))
    for v in vms:
        v["last_exec"] = last.get(v["id"])
        v["end_session"] = ends.get(v["id"])
    return vms


def snapshot(d, t0, at_s):
    """vm_mem of every VM in the sample nearest t0 + at_s: (sample t, [MiB])."""
    best = None
    for r in V.read_samples(d):
        if r.get("ts") is None:
            continue
        dt = abs(r["ts"] - (t0 + at_s))
        if best is None or dt < best[0]:
            best = (dt, r)
    if best is None:
        return None, []
    r = best[1]
    return r["ts"] - t0, [v / MiB for v in (r.get("vm_mem") or {}).values() if v is not None]


def stats(xs):
    if not xs:
        return None
    return {"n": len(xs), "median": V._median(xs), "p95": V._p95(xs), "max": max(xs), "sum": sum(xs)}


def analyse(d):
    base = V.analyse([d])
    base.pop("_raw", None)
    p = json.load(open(os.path.join(d, "params.json")))
    rec = json.load(open(os.path.join(d, "record.json")))
    t0 = rec.get("rung_start_ts") or p.get("rung_start_ts")
    run_end = t0 + p["warmup_s"] + p["window_s"]
    g = {}
    for b in (60, 120, 180):
        bins = [V.per_bin(o) for o in V.vms_of(d) if o]
        pct, n = V.growth(bins, 20, b, 1)
        both = [v for v in bins if 20 in v and b in v]
        g[str(b)] = {"pct": pct, "vms": n, "enough": n >= V.MIN_VMS,
                     # the paired VMs' own medians: long-lived sessions are lighter at 20 min than
                     # the population, so the paired % overstates the level they reach
                     "paired_median_mib_at_20": V._median([v[20] for v in both]) if both else None,
                     "paired_median_mib_at_age": V._median([v[b] for v in both]) if both else None}
    vs = lives(d)
    # The driver ends every live session at the run's end (warm-up + window), mid-gap: those VMs are
    # destroyed then, not by their session's own end, so they are censored (destroyed within
    # CUT_TOL_S of the run's end, or later, or never).
    ended = [v for v in vs if v["end"] is not None and v["end"] < run_end - CUT_TOL_S]
    censored = [v for v in vs if v not in ended]
    age_end = [(v["end"] - v["born"]) / 60.0 for v in ended]
    lag = [(v["end"] - v["last_exec"]) / 60.0 for v in ended if v["last_exec"] is not None]
    lag50 = [(v["end"] - v["last_exec"]) / 60.0 for v in ended
             if v["last_exec"] is not None and v["end"] - v["born"] >= 3000]
    lag_es = [(v["end_session"] - v["last_exec"]) / 60.0 for v in ended
              if v["last_exec"] is not None and v["end_session"] is not None]
    snap_t, snap = snapshot(d, t0, SNAP_S)
    bin150 = None
    i150 = base["bins_min"].index(150) if 150 in base["bins_min"] else None
    if i150 is not None:
        bin150 = {"vms": base["vms_per_bin"][i150], "median": base["median_mib"][i150], "p95": base["p95_mib"][i150]}
    old = [V.per_bin(o) for o in V.vms_of(d) if o]
    max150 = max((v[150] for v in old if 150 in v), default=None)
    return {
        "rung": d, "n": p["n"], "warmup_s": p["warmup_s"], "window_s": p["window_s"],
        "holds": rec.get("holds"), "holds_abs": rec.get("holds_abs"), "reason": rec.get("reason"),
        "p95_excess_ms": rec.get("p95_excess_ms"), "excess_limit_ms": rec.get("excess_limit_ms"),
        "vm_age": base,
        "growth_20_to_60_120_180": g,
        "median_mib_at_age_min": {str(b): base["median_mib"][base["bins_min"].index(b)]
                                  for b in (0, 20, 60, 120, 180) if b in base["bins_min"]},
        "max_vm_mib_any_age": max((m for m in base["p95_mib"] if m is not None), default=None),
        "lives": {"vms": len(vs), "ended_in_run": len(ended), "censored_at_run_end": len(censored),
                  "age_at_session_end_min": {"median": _q(age_end, 0.5), "p90": _q(age_end, 0.9),
                                             "max": max(age_end) if age_end else None},
                  "last_exec_to_destroy_min": {"median": _q(lag, 0.5), "p90": _q(lag, 0.9),
                                               "max": max(lag) if lag else None, "n": len(lag)},
                  "last_exec_to_destroy_min_vms_aged_50min": {"median": _q(lag50, 0.5), "p90": _q(lag50, 0.9),
                                                              "n": len(lag50)},
                  "last_exec_to_end_session_min": {"median": _q(lag_es, 0.5), "p90": _q(lag_es, 0.9),
                                                   "n": len(lag_es)},
                  "censored_age_at_run_end_min": {"median": _q([(run_end - v["born"]) / 60.0 for v in censored], 0.5),
                                                  "max": max([(run_end - v["born"]) / 60.0 for v in censored], default=None)}},
        "at_2_5h": {"age_bin_150_min": dict(bin150 or {}, max=max150),
                    "rung_time": dict({"t_s": snap_t}, **(stats(snap) or {}))},
    }


def _f(x, nd=1):
    return "-" if x is None else ("%.*f" % (nd, x))


def markdown(r, label=None):
    a = r["vm_age"]
    L = r["lives"]
    s = r["at_2_5h"]["rung_time"]
    b = r["at_2_5h"]["age_bin_150_min"]
    out = ["# E16 long rung: VM memory against age" + (" -- " + label if label else ""), "",
           "resident-inf, lowduty, N=%d, warm-up %d s, window %d s. Verdict (information, not a ladder rung): "
           "holds=%s holds_abs=%s, p95 excess %s ms vs limit %s ms." % (
               r["n"], r["warmup_s"], r["window_s"], r["holds"], r["holds_abs"],
               _f(r["p95_excess_ms"], 0), _f(r["excess_limit_ms"], 0)), "",
           "%d VMs; ages to %s min. Median VM memory by age: %s." % (
               a["vms"], a["max_age_min"], ", ".join("%s min %s MiB" % (k, _f(v)) for k, v in r["median_mib_at_age_min"].items())),
           "", "Growth of the median VM from 20 min of age (VMs seen at both ages; < %d VMs is too few):" % V.MIN_VMS, ""]
    for k, g in r["growth_20_to_60_120_180"].items():
        out.append("- 20 to %s min: %s%% over %d VMs%s (those VMs' median %s MiB at 20 min, %s MiB at %s min)" % (
            k, _f(g["pct"]), g["vms"], "" if g["enough"] else " (too few)",
            _f(g.get("paired_median_mib_at_20")), _f(g.get("paired_median_mib_at_age")), k))
    out.append("Population medians (every VM seen in the bin) are the level reading; the paired %% is "
               "inflated because long-lived VMs are lighter at 20 min than the population.")
    out += ["", "VM life (worker.log): %d VMs, %d destroyed in the run, %d alive at its end." % (
        L["vms"], L["ended_in_run"], L["censored_at_run_end"]),
        "- age at session end: median %s min, p90 %s, max %s" % tuple(_f(L["age_at_session_end_min"][k]) for k in ("median", "p90", "max")),
        "- last Exec to destroy: median %s min, p90 %s, max %s (n=%d)" % (
            _f(L["last_exec_to_destroy_min"]["median"]), _f(L["last_exec_to_destroy_min"]["p90"]),
            _f(L["last_exec_to_destroy_min"]["max"]), L["last_exec_to_destroy_min"]["n"]),
        "- last Exec to destroy, VMs that reached 50 min of age: median %s min, p90 %s (n=%d)" % (
            _f(L["last_exec_to_destroy_min_vms_aged_50min"]["median"]), _f(L["last_exec_to_destroy_min_vms_aged_50min"]["p90"]),
            L["last_exec_to_destroy_min_vms_aged_50min"]["n"]),
        "- alive at run end: age median %s min, max %s" % (
            _f(L["censored_age_at_run_end_min"]["median"]), _f(L["censored_age_at_run_end_min"]["max"])),
        "", "VM memory at 2.5 h:",
        "- VMs aged 150 min: %s VMs, median %s MiB, p95 %s, max %s" % (b.get("vms", "-"), _f(b.get("median")), _f(b.get("p95")), _f(b.get("max"))),
        "- all VMs alive at rung time 2.5 h (t=%s s): %s VMs, median %s MiB, p95 %s, max %s, sum %s GiB" % (
            _f(s.get("t_s"), 0), s.get("n", "-"), _f(s.get("median")), _f(s.get("p95")), _f(s.get("max")),
            _f((s.get("sum") or 0) / 1024.0)),
        "", "| age (min) | VMs | median MiB | p95 MiB |", "|---|---|---|---|"]
    for bn, n, m, p in zip(a["bins_min"], a["vms_per_bin"], a["median_mib"], a["p95_mib"]):
        out.append("| %d | %d | %s | %s |" % (bn, n, _f(m), _f(p)))
    return "\n".join(out) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("rung")
    ap.add_argument("--out", required=True)
    ap.add_argument("--label-root", default=None)
    ap.add_argument("--label", default=None)
    a = ap.parse_args(argv)
    r = analyse(a.rung)
    if a.label_root:
        r["rung"] = os.path.relpath(r["rung"], a.label_root)
        r["vm_age"]["rungs"] = [r["rung"]]
        for pr in r["vm_age"]["per_rung"]:
            pr["rung"] = r["rung"]
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out + ".json", "w") as f:
        json.dump(r, f, indent=2)
        f.write("\n")
    with open(a.out + ".md", "w") as f:
        f.write(markdown(r, a.label))
    return r


if __name__ == "__main__":
    main()
