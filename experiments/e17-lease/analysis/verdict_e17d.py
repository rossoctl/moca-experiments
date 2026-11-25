#!/usr/bin/env python3
"""E17d verdict: L2a-L2d of SPEC §14.4 computed by code from the rung tree, and the readings §14.4 reports.

  python3 experiments/e17-lease/analysis/verdict_e17d.py RUNS_DIR [--moca-commit PIN] [--predictions FILE] [--out FILE]
      -> FILE (default RUNS_DIR/verdict.json), one summary line

RUNS_DIR is the rig's $E15_RUNS, read with verdict.py's (E17b) rung discovery and --moca-commit exclusion, and its
{value, inputs, missing, pass, why} shape. --predictions defaults to predictions-e17d.json beside this directory.

EVERY THRESHOLD AND MINIMUM COMES FROM THE SEALED PREDICTIONS, never from code ("criteria" in predictions-e17d.json):
  criteria.L2a  {class, gain_vs_sbx_min, gain_vs_l1_min}     criteria.L2b  {class, gain_vs_sbx_min}
  criteria.L2c  {server_lost_rate_max, oom_kills_max}         min_warm      the minimum warm count per warm set
  min_seeds     the minimum evaluable N = 1 seeds per arm     n_load        the load rung's N (128, or the largest N
                                                                            calibration found to fit, spec §14.5)
  n1_gated      false: N = 1 is "reported, not gated" (the seal said the warm minimum is not reachable in 8 seeds),
                and is left out of L2a and L2b (it is under `reported`)
Absent or unsealed predictions, or a missing field, leave every criterion null, the reason in `missing`.

The rungs (point pycache-l2; chain-e17d.sh's measured stages): the N = 1 seal seeds N1-l<k> that are evaluable
(record.json, reason not empty_window), pooled per arm, and N<n_load>-lat. Never the smoke, the calibration (cal-*,
memcheck) or the squeeze.
  L2a  At N = 1 (when gated) and N = n_load, for criteria.L2a.class: ship-300-l2's warm gain against sbx's all
       median >= gain_vs_sbx_min, and its warm-against-warm gain against ship-300 >= gain_vs_l1_min
       (latency_report: warm = a live lease and no restart). A warm set (ship-300-l2's, and ship-300's for the second
       gain) below min_warm makes the criterion null at that rung, with the reason, never a pass; so does a missing
       rung (not run) and an N = 1 arm with fewer than min_seeds evaluable seeds.
  L2b  The same rungs, criteria.L2b.class: ship-300-l2's gain against sbx >= gain_vs_sbx_min, the same warm minimum.
  L2c  At N = n_load, ship-300-l2 (level2.py): no more l2srv OOM kills than oom_kills_max at 1024 MiB guests
       (params guest_ram_mb; another guest RAM is null), and server-lost restarts over the re-queries that found
       their lease live <= server_lost_rate_max.
  L2d  Every gated ship-300-l2 rung: every judged end has exactly one notice naming l2srv and no lease end sync line
       (level2.py ends.pass). A rung with no judged end has no reading (null); the criterion is false on any false
       rung, null when no rung has a judged end.
Each criterion's value lists its evidence by rung. Top-level pass: true only when all four are true, null when any
is null, false otherwise.

Reported, never gated: N = 1 when n1_gated is false; per gated ship-300-l2 rung the level-2 charge (vm_fp at +45 s,
beside the paired ship-300 rung's), the restart costs and the lease-cold share beside ship-300's; py_short at
ship-300-l2 against ship-300 (gain_vs_l1); squeeze-l2: each arm's ladder.json squeeze summary, per rung the
memory-budget refusals by why (#1026) and the reclaims of a lease with a running server, and the first N of each.
"""
import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import verdict as V  # noqa: E402  (E17b's helpers)
import level2 as L2  # noqa: E402

LR = V.LR
DEFAULT_PREDICTIONS = os.path.join(os.path.dirname(HERE), "predictions-e17d.json")
GATED = ("L2a", "L2b", "L2c", "L2d")
POINT, SQUEEZE = "pycache-l2", "squeeze-l2"
L2_ARM, L1_ARM, BASE = "ship-300-l2", "ship-300", "sbx"
ARMS = (BASE, L1_ARM, L2_ARM)
N1_SEAL = re.compile(r"^N1-l[0-9]+$")
GUEST_RAM_MB = 1024
NEEDED = ("criteria", "min_warm", "min_seeds", "n_load", "n1_gated")


def criterion(name, value, inputs, missing, passed, why):
    return dict(name=name, **V.criterion(value, inputs, missing, passed, why))


def predictions(path):
    """(info, preds or None, why-missing or None)."""
    info = {"path": path, "sealed": None}
    p = V.load(path) if path and os.path.exists(path) else None
    if not isinstance(p, dict):
        return info, None, "predictions %s absent or unreadable: no threshold to judge against" % path
    info["sealed"] = p.get("sealed")
    if p.get("sealed") is not True:
        return info, None, "predictions %s not sealed: its thresholds are not binding" % path
    lack = [k for k in NEEDED if k not in p]
    c = p.get("criteria") or {}
    lack += ["criteria.%s.%s" % (k, f) for k, fs in (("L2a", ("class", "gain_vs_sbx_min", "gain_vs_l1_min")),
                                                     ("L2b", ("class", "gain_vs_sbx_min")),
                                                     ("L2c", ("server_lost_rate_max", "oom_kills_max")))
             for f in fs if f not in (c.get(k) or {})]
    if lack:
        return info, None, "predictions %s lacks %s" % (path, ", ".join(lack))
    return info, p, None


def seed_state(r):
    rec = V.load(os.path.join(r["dir"], "record.json"))
    if rec is None:
        return "no_record" if not os.path.exists(os.path.join(r["dir"], "record.json")) else "unreadable"
    return "empty_window" if rec.get("reason") == "empty_window" else "evaluable"


def gated(rungs, n_load):
    """{"n1": {arm: [rungs]}, "load": {arm: rung or None}, "not_evaluable": [...]}."""
    n1, load, bad = {a: [] for a in ARMS}, {a: None for a in ARMS}, []
    for r in rungs:
        if r["point"] != POINT or r["arm"] not in ARMS:
            continue
        if N1_SEAL.match(r["name"]):
            st = seed_state(r)
            if st == "evaluable":
                n1[r["arm"]].append(r)
            else:
                bad.append({"rung": r["dir"], "state": st})
        elif r["name"] == "N%d-lat" % n_load:
            load[r["arm"]] = r
    return {"n1": n1, "load": load, "not_evaluable": sorted(bad, key=lambda b: b["rung"])}


def latency_at(dirs):
    """latency_report over one N's rungs (every arm): {arm: group}."""
    rep = LR.build(dirs) if dirs else {"groups": []}
    return {g["arm"]: g for g in rep["groups"]}


def halves(g, p):
    """The N's to judge, each with its rung dirs per arm and why it cannot be judged (or None)."""
    out = {}
    if p["n1_gated"]:
        short = [a for a in ARMS if len(g["n1"][a]) < p["min_seeds"]]
        out["1"] = {"dirs": [r["dir"] for a in ARMS for r in g["n1"][a]],
                    "missing": ["N=1 %s has %d evaluable seed(s) N1-l<k> (need %d)" % (a, len(g["n1"][a]), p["min_seeds"])
                                for a in short]}
    nl = str(p["n_load"])
    gone = [a for a in ARMS if g["load"][a] is None]
    out[nl] = {"dirs": [g["load"][a]["dir"] for a in ARMS if g["load"][a]],
               "missing": ["N=%s %s: no N%s-lat rung (not run)" % (nl, a, nl) for a in gone]}
    return out


def gain_crit(name, g, p, key, want_l1):
    spec = p["criteria"][key]
    cls, value, inputs, missing, fails = spec["class"], {}, [], [], []
    for n, h in halves(g, p).items():
        inputs += h["dirs"]
        ev = {"rungs": sorted(h["dirs"]), "class": cls}
        value["N=%s" % n] = ev
        if h["missing"]:
            missing += h["missing"]
            continue
        groups = latency_at(h["dirs"])
        c2 = ((groups.get(L2_ARM) or {}).get("classes") or {}).get(cls) or {}
        c1 = ((groups.get(L1_ARM) or {}).get("classes") or {}).get(cls) or {}
        ev.update(gain_vs_sbx=c2.get("gain"), gain_n=c2.get("gain_n"), l2_warm_n=(c2.get("warm") or {}).get("n", 0),
                  l2_warm_median_ms=(c2.get("warm") or {}).get("median_ms"))
        if want_l1:
            ev.update(gain_vs_l1=c2.get("gain_vs_l1"), gain_vs_l1_n=c2.get("gain_vs_l1_n"),
                      l1_warm_n=(c1.get("warm") or {}).get("n", 0))
        low = [("%s's warm %s set has %d call(s) at N=%s (need %d)" % (a, cls, ev[k], n, p["min_warm"]))
               for a, k in ((L2_ARM, "l2_warm_n"),) + (((L1_ARM, "l1_warm_n"),) if want_l1 else ())
               if ev[k] < p["min_warm"]]
        if low:
            missing += low
            continue
        for gk, mk in (("gain_vs_sbx", "gain_vs_sbx_min"),) + ((("gain_vs_l1", "gain_vs_l1_min"),) if want_l1 else ()):
            if ev[gk] is None:
                missing.append("N=%s: no %s for %s" % (n, gk, cls))
            elif ev[gk] < spec[mk]:
                fails.append("N=%s ship-300-l2 %s %s %.3f < %.2f" % (n, cls, gk, ev[gk], spec[mk]))
    return criterion(name, value, inputs, missing, V.judged(fails, missing), fails + ["not judged: " + m for m in missing])


def l2c(g, p):
    spec, nl = p["criteria"]["L2c"], p["n_load"]
    r = g["load"][L2_ARM]
    if r is None:
        return criterion("level-2 server at load", {"rung": None}, [], ["N=%d ship-300-l2: no N%d-lat rung (not run)" % (nl, nl)],
                         None, ["not judged: not run"])
    a = L2.analyse(r["dir"])
    ram = r["params"].get("guest_ram_mb") or r["params"].get("snapshot_guest_ram_mb")
    sl = a["server_lost_rate"]
    value = {"rung": r["dir"], "guest_ram_mb": ram, "oom_kills_l2srv": a["oom_kills_l2srv"], "oom_kills": a["oom_kills"],
             "server_lost_rate": sl, "lease_cold_restarts": a["restarts"]["by_kind"]["lease_cold"]["n"]}
    missing, fails = [], []
    if ram != GUEST_RAM_MB:
        missing.append("%s runs %s MiB guests, not %d" % (r["dir"], ram, GUEST_RAM_MB))
    if sl["rate"] is None:
        missing.append("%s has no in-window re-query that found its lease live" % r["dir"])
    if not missing:
        if a["oom_kills_l2srv"] > spec["oom_kills_max"]:
            fails.append("%d OOM kill(s) of l2srv > %d" % (a["oom_kills_l2srv"], spec["oom_kills_max"]))
        if sl["rate"] > spec["server_lost_rate_max"]:
            fails.append("server-lost restarts %d of %d live re-queries = %.4f > %.4f" % (
                sl["server_lost"], sl["live_requeries"], sl["rate"], spec["server_lost_rate_max"]))
    return criterion("level-2 server at load", value, [r["dir"]], missing, V.judged(fails, missing),
                     fails + ["not judged: " + m for m in missing])


def l2d(g, p):
    rs = [r for r in g["n1"][L2_ARM] if p["n1_gated"]] + ([g["load"][L2_ARM]] if g["load"][L2_ARM] else [])
    by, fails = {}, []
    for r in rs:
        e = L2.analyse(r["dir"])["ends"]
        by[r["dir"]] = {"judged": len(e["judged"]), "pass": e["pass"], "with_sync_line": e["with_sync_line"],
                        "excluded": e["excluded"], "failing": [j for j in e["judged"] if not j["pass"]]}
        if e["pass"] is False:
            fails.append("%s: %d judged end(s) without one notice naming l2srv or with a sync line" % (
                r["dir"], len(by[r["dir"]]["failing"])))
    missing = [] if any(v["pass"] is not None for v in by.values()) else ["no gated ship-300-l2 rung has a judged end"]
    if not rs:
        missing = ["no gated ship-300-l2 rung (not run)"]
    return criterion("level-2 ends", {"by_rung": by}, [r["dir"] for r in rs], missing, V.judged(fails, missing),
                     fails + ["not judged: " + m for m in missing])


def reported(root, rungs, g, p):
    out = {"n1_not_gated": None, "by_rung": {}, "py_short_vs_l1": {}, "squeeze_l2": {}}
    if p and not p["n1_gated"]:
        dirs = [r["dir"] for a in ARMS for r in g["n1"][a]]
        out["n1_not_gated"] = {"rungs": sorted(dirs), "groups": latency_at(dirs) if dirs else {}}
    if p:
        for n, h in halves(g, dict(p, n1_gated=True)).items():
            groups = latency_at(h["dirs"]) if h["dirs"] else {}
            out["py_short_vs_l1"]["N=%s" % n] = (((groups.get(L2_ARM) or {}).get("classes") or {}).get("py_short") or {}).get("gain_vs_l1")
            for r in [x for x in g["n1"][L2_ARM]] + ([g["load"][L2_ARM]] if g["load"][L2_ARM] else []):
                if r["dir"] in out["by_rung"]:
                    continue
                pair = next((x for x in rungs if x["point"] == POINT and x["arm"] == L1_ARM and x["name"] == r["name"]), None)
                a = L2.analyse(r["dir"], pair["dir"] if pair else None)
                out["by_rung"][r["dir"]] = {k: a[k] for k in ("charge", "restarts", "lease_cold_share",
                                                               "paired_lease_cold_share", "refusals")}
    for arm in (L1_ARM, L2_ARM):
        lj = V.load(os.path.join(root, SQUEEZE, arm, "ladder.json"))
        per = {}
        for r in rungs:
            if r["point"] == SQUEEZE and r["arm"] == arm:
                a = L2.analyse(r["dir"])
                per[r["name"]] = {"n": r["params"].get("n"), "refusals_by_why": a["refusals"]["by_why"],
                                  "reclaims_of_a_running_server": sum(
                                      1 for j in a["ends"]["judged"] if j["reason"] == "memory_reclaim")}
        ns = lambda f: min((v["n"] for v in per.values() if f(v) and v["n"] is not None), default=None)  # noqa: E731
        out["squeeze_l2"][arm] = {"ladder": (lj or {}).get("squeeze") if lj else None, "rungs": per,
                                  "first_refusal_n": ns(lambda v: sum(v["refusals_by_why"].values()) > 0),
                                  "first_reclaim_of_a_running_server_n": ns(lambda v: v["reclaims_of_a_running_server"] > 0)}
    return out


def verdict(root, moca_commit=None, preds_path=DEFAULT_PREDICTIONS):
    rungs, excluded = V.find_rungs(root, moca_commit)
    info, p, why = predictions(preds_path)
    if p is None:
        crit = {k: criterion(k, None, [], [why], None, ["not judged: " + why]) for k in GATED}
        g = None
    else:
        g = gated(rungs, p["n_load"])
        crit = {"L2a": gain_crit("level-2 re-query latency", g, p, "L2a", True),
                "L2b": gain_crit("level-2 recompute latency", g, p, "L2b", False),
                "L2c": l2c(g, p), "L2d": l2d(g, p)}
    ps = [crit[k]["pass"] for k in GATED]
    top = True if all(x is True for x in ps) else (None if any(x is None for x in ps) else False)
    return {"runs": root, "moca_commit": moca_commit, "excluded_rungs": excluded, "predictions": info,
            "pass": top, "why": ["%s: %s" % (k, "not judged" if crit[k]["pass"] is None else "failed")
                                 for k in GATED if crit[k]["pass"] is not True],
            "note": "SPEC 14.4: pass is true only when L2a, L2b, L2c and L2d all hold, null when any is null",
            "seeds_not_evaluable": g["not_evaluable"] if g else [],
            "criteria": crit, "reported": reported(root, rungs, g, p) if g else None}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("runs")
    ap.add_argument("--moca-commit", default=None)
    ap.add_argument("--predictions", default=DEFAULT_PREDICTIONS)
    ap.add_argument("--out", default=None)
    a = ap.parse_args(argv)
    out = a.out or os.path.join(a.runs, "verdict.json")
    r = verdict(a.runs, a.moca_commit, a.predictions)
    with open(out, "w") as f:
        json.dump(r, f, indent=2, sort_keys=True)
        f.write("\n")
    c = r["criteria"]
    print("%s: pass %s; L2a %s L2b %s L2c %s L2d %s; missing %d; excluded %d" % (
        out, r["pass"], c["L2a"]["pass"], c["L2b"]["pass"], c["L2c"]["pass"], c["L2d"]["pass"],
        sum(len(x["missing"]) for x in c.values()), len(r["excluded_rungs"])))
    return r


if __name__ == "__main__":
    main()
