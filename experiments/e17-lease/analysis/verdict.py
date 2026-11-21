#!/usr/bin/env python3
"""E17b verdict inputs: the five gated criteria (SPEC §7.5) computed by code from the per-rung outputs
(final review M1), so that Task 15 applies the sealed thresholds to numbers nobody assembled by hand.

  python3 experiments/e17-lease/analysis/verdict.py RUNS_DIR [--moca-commit PIN] [--out FILE]
      -> FILE (default RUNS_DIR/verdict.json), one summary line

RUNS_DIR is the rig's $E15_RUNS (POINT/ARM/RUNG/...). A rung is a directory with params.json; moved-aside rungs
(`<rung>.prev-<UTC>`, rung.sh) are ignored, and with --moca-commit a rung of another commit is excluded and listed
(the chain's preflight already refuses mixed commits). Every criterion is {value, inputs, missing, pass, why}. A
missing input is null and listed under `missing`, never guessed.

PASS (E17B-R40). Criteria 1-4 apply SPEC §7.5's FIXED bars, which are the spec's, not prediction values: `pass` is
true or false, `why` lists each failure, and `pass` is null only when an input it needs is missing or unavailable
and nothing already fails. Criterion 5 keeps `pass` null until its thresholds are sealed (Task 13).
  1  ship-300 N_max >= sbx N_max at default.
  2  ship-300's warm gain against sbx at pycache, N=1 and N=128: py_short >= 0.50 and py_import >= 0.30
     (gain = 1 - warm median / sbx median, latency_report.py).
  3  At each squeeze point whose climb ran (squeeze is required; squeeze-256 is judged when it ran), over the
     climb's rungs: zero guard events (memory_floor, OOM kills and host_memory refusals: lease_ends guards total
     less memory_high, ruling E17B-R49; memory_high, the squeezed slice's memory.high, is reported, not judged), zero
     refusals while an idle lease
     existed (memory-budget and host-memory, none unclassified), no wrong / unknown / victim_executing reclaim, and
     at least one reclaim at the point (E17B-R39: else false, "no reclaim happened", when every rung of the climb
     was read and valid). A rung without lease_ends.json, invalid, or with its guard or refusal reading unavailable
     leaves it null, as does a climb with no rungs.
  4  R16 (r16_met).

  1 capacity   RUNS/default/{ship-300,sbx}/ladder.json n_max (n_max_abs reported): ship_300_n_max, sbx_n_max and
               their difference.
  2 latency    latency_report.build over the latency rungs (directory N1-lat or N128-lat: the chain's lat stages;
               at pycache N=1 also the baseline seeds N1-s<k>, E17B-R52) of sbx and every ship arm at pycache and
               pycache-low. `gated` is
               ship-300's warm py_short and py_import gain against sbx at pycache, N 1 and 128; `groups` has every
               arm, point and class (py_grep, py_analyze, py_test reported).
  3 reclaim    At squeeze and squeeze-256: the ship-300 climb's ladder.json squeeze {stop_n, stopped_by} and, for
               each rung of the climb (squeeze.rungs[].dir, resolved under RUNS when the path moved), its
               lease_ends.json guards, refusals with an idle lease (memory-budget and host-memory), reclaim order
               and their totals; the sbx rungs there (tag sq) with their params memory_abort / oom_kills.
  4 notices    Every ship-* rung's lease_ends.json criterion4_pass and valid, combined by ruling E17B-R16: r16_met
               when no rung is false, every rung is valid (a ship rung without lease_ends.json is not), and at
               least one rung is true. ended_after_sweep, ended_by_run_cut (E17B-R54) and live_at_stop totals reported
               (excluded by definition).
  5 memory     At pycache, every ship rung's vm_age_lease.json: first half the relative verdict (follows_true,
               follows_false, share_true, not_judged_low_growth; E17B-R29) and the absolute reading (pinned_share,
               pinned_share_of_judged, pinned_vm_share), per rung and pooled; second half each rung's
               replacement.ratio_to_sbx (vm_age_lease --sbx, which the chain's gate passes when the same-named sbx
               rung exists). The 256 MiB point pycache-d64 is reported apart, under `reported`, never pooled.
"""
import argparse
import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import latency_report as LR  # noqa: E402  (sets up the E15 analysis path)

LAT_NAMES = ("N1-lat", "N128-lat")
# E17B-R52 (user, 2026-11-18): a single N=1 session leaves N1-lat with one in-window call, so the N=1 half pools the
# pycache N=1 baseline seeds (baseline.sh N1-s<k>, the calibration the predictions were drafted from) with N1-lat.
N1_SEED = re.compile(r"^N1-s[0-9]+$")
LAT_POINTS = ("pycache", "pycache-low")
GATED_CLASSES = ("py_short", "py_import")
GAIN_BARS = {"py_short": 0.50, "py_import": 0.30}  # SPEC §7.5 criterion 2: at least 50% / 30% faster warm
SQUEEZE_POINTS = ("squeeze", "squeeze-256")
FPR_POINT = "pycache"
FPR_REPORTED = ("pycache-low", "pycache-d64")


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def find_rungs(root, moca_commit=None):
    """([{dir, point, arm, name, params}] sorted by point, arm, N, name; excluded [{rung, moca_commit}])."""
    rungs, excluded = [], []
    for p in glob.glob(os.path.join(root, "*", "*", "*", "params.json")):
        d = os.path.dirname(p)
        name = os.path.basename(d)
        if ".prev-" in name:
            continue
        params = load(p)
        if not isinstance(params, dict):
            excluded.append({"rung": d, "moca_commit": None, "why": "params.json unreadable"})
            continue
        if moca_commit and params.get("moca_commit") != moca_commit:
            excluded.append({"rung": d, "moca_commit": params.get("moca_commit")})
            continue
        point, arm = d.split(os.sep)[-3], d.split(os.sep)[-2]
        rungs.append({"dir": d, "point": point, "arm": arm, "name": name, "params": params})
    rungs.sort(key=lambda r: (r["point"], r["arm"], r["params"].get("n") or 0, r["name"]))
    excluded.sort(key=lambda e: e["rung"])
    return rungs, excluded


def is_ship(r):
    return str(r["arm"]).startswith("ship-")


def criterion(value, inputs, missing, passed=None, why=()):
    return {"value": value, "inputs": sorted(inputs), "missing": sorted(missing), "pass": passed, "why": list(why)}


def judged(fails, unknown):
    """pass from failure reasons and not-judgeable reasons: false on any failure, null on any unknown, else true."""
    return False if fails else (None if unknown else True)


def capacity(root):
    out, inputs, missing, abs_ = {}, [], [], {}
    for arm in ("ship-300", "sbx"):
        p = os.path.join(root, "default", arm, "ladder.json")
        lj = load(p)
        if lj is None:
            missing.append(p)
            out[arm] = None
            abs_[arm] = None
            continue
        inputs.append(p)
        out[arm], abs_[arm] = lj.get("n_max"), lj.get("n_max_abs")
    diff = out["ship-300"] - out["sbx"] if None not in (out["ship-300"], out["sbx"]) else None
    why = ["ship-300 N_max %s < sbx N_max %s at default" % (out["ship-300"], out["sbx"])] if diff is not None and diff < 0 else []
    return criterion({"ship_300_n_max": out["ship-300"], "sbx_n_max": out["sbx"], "ship_300_minus_sbx": diff,
                      "n_max_abs": abs_}, inputs, missing, judged(why, diff is None), why)


def latency(rungs, select=None):
    """Criterion 2 over the latency rungs: E17b's (LAT_NAMES and the pycache N1-s<k> seeds), or `select`'s
    (verdict_e17c.py passes the seal stages' rungs, ruling R-z2)."""
    dirs = [r["dir"] for r in rungs if (select(r) if select else (
            r["point"] in LAT_POINTS
            and (r["name"] in LAT_NAMES or (r["point"] == "pycache" and N1_SEED.match(r["name"])))
            and (r["arm"] == "sbx" or is_ship(r))))]
    gated = {str(n): {c: None for c in GATED_CLASSES} for n in (1, 128)}
    value = {"gated": gated, "gated_arm": "ship-300", "gated_point": "pycache", "groups": [], "error": None}
    if not dirs:
        return criterion(value, [], ["no latency rungs (N1-lat, N128-lat) at %s" % ", ".join(LAT_POINTS)])
    try:
        rep = LR.build(dirs, baseline_arm="sbx")
    except SystemExit as e:
        value["error"] = str(e)
        return criterion(value, dirs, ["latency_report.py: " + str(e)])
    missing = []
    for g in rep["groups"]:
        value["groups"].append({k: g.get(k) for k in ("point", "n", "arm", "classes", "countable", "excluded_rungs",
                                                      "warm_share", "first_lease")})
        if (g["point"], g["arm"]) == ("pycache", "ship-300") and str(g["n"]) in gated:
            for c in GATED_CLASSES:
                gated[str(g["n"])][c] = (g["classes"].get(c) or {}).get("gain")
    why = []
    for n, v in gated.items():
        for c, gain in v.items():
            if gain is None:
                missing.append("pycache N=%s ship-300 %s gain (no warm call, or no sbx baseline)" % (n, c))
            elif gain < GAIN_BARS[c]:
                why.append("pycache N=%s ship-300 warm %s gain %.3f < %.2f" % (n, c, gain, GAIN_BARS[c]))
    value["bars"] = dict(GAIN_BARS)
    return criterion(value, dirs, missing, judged(why, missing), why)


def resolve(root, point, arm, d):
    if d and os.path.isdir(d):
        return d
    return os.path.join(root, point, arm, os.path.basename(str(d or "").rstrip("/")))


def reclaim(root, rungs, points=SQUEEZE_POINTS):
    """Criterion 3 over `points` (E17b: both squeeze points; verdict_e17c.py judges squeeze alone)."""
    value, inputs, missing, why, unknown = {}, [], [], [], []
    for point in points:
        lp = os.path.join(root, point, "ship-300", "ladder.json")
        lj = load(lp)
        sq = (lj or {}).get("squeeze")
        if not sq:
            value[point] = None
            missing.append("%s (no squeeze climb)" % lp)
            if point == "squeeze":  # the gated point; squeeze-256 is judged only when it ran
                unknown.append("no squeeze climb")
            continue
        inputs.append(lp)
        rows, unread = [], 0
        tot = {"guards": 0, "memory_high": 0, "refusals_with_idle_lease": 0, "host_memory_with_idle_lease": 0, "reclaims": 0,
               "wrong": 0, "unknown": 0, "victim_executing": 0}
        for sr in sq.get("rungs") or []:
            d = resolve(root, point, "ship-300", sr.get("dir"))
            ep = os.path.join(d, "lease_ends.json")
            e = load(ep)
            row = {"n": sr.get("n"), "dir": d, "met": sr.get("met"), "guard": sr.get("guard")}
            if e is None:
                missing.append(ep)
                unknown.append("%s: no lease_ends.json" % d)
                unread += 1
                rows.append(row)
                continue
            inputs.append(ep)
            ref, rec = e.get("refusals") or {}, e.get("reclaim") or {}
            g = e.get("guards") or {}
            # E17B-R49 (user, 2026-11-18): memory_high is the squeezed e15.slice's memory.high, reached by page cache
            # that destroyed VMs' cgroups leave in the slice (the worker's budget does not see it; production slices
            # are MemoryMax=infinity). Reported, not judged: the judged guards are total - memory_high.
            judged_guards = None if g.get("total") is None else int(g["total"]) - int(g.get("memory_high") or 0)
            guards_pass = None if not g.get("available") else judged_guards == 0
            row.update(guards=judged_guards, memory_high=g.get("memory_high"), guards_pass=guards_pass,
                       lease_ends_guards_pass=e.get("criterion3_guards_pass"),
                       refusals_with_idle_lease=ref.get("with_idle_lease"),
                       host_memory_with_idle_lease=ref.get("host_memory_with_idle_lease"),
                       refusals_unclassified=len(ref.get("unclassified") or []),
                       refusals_pass=e.get("criterion3_refusals_pass"), reclaims=rec.get("total"),
                       wrong=rec.get("wrong"), unknown=rec.get("unknown"), order_pass=e.get("criterion3_order_pass"),
                       valid=e.get("valid"))
            for k, src in (("guards", row["guards"]), ("memory_high", row["memory_high"]),
                           ("refusals_with_idle_lease", row["refusals_with_idle_lease"]),
                           ("host_memory_with_idle_lease", row["host_memory_with_idle_lease"]),
                           ("reclaims", rec.get("total")), ("wrong", rec.get("wrong")),
                           ("unknown", rec.get("unknown")), ("victim_executing", rec.get("victim_executing"))):
                tot[k] += int(src or 0)
            if row["guards_pass"] is False or (row["guards"] or 0) > 0:
                why.append("%s N=%s: %s memory-guard event(s)" % (point, row["n"], row["guards"]))
            elif row["guards_pass"] is None:
                unknown.append("%s N=%s: guard reading unavailable" % (point, row["n"]))
            if (row["refusals_with_idle_lease"] or 0) or (row["host_memory_with_idle_lease"] or 0) \
                    or row["refusals_unclassified"] or row["refusals_pass"] is False:
                why.append("%s N=%s: refusals while an idle lease existed (memory-budget %s, host-memory %s, "
                           "unclassified %s)" % (point, row["n"], row["refusals_with_idle_lease"],
                                                 row["host_memory_with_idle_lease"], row["refusals_unclassified"]))
            elif row["refusals_pass"] is None:
                unknown.append("%s N=%s: refusal reading unavailable" % (point, row["n"]))
            for k in ("wrong", "unknown", "victim_executing"):
                if rec.get(k):
                    why.append("%s N=%s: %s %s reclaim(s)" % (point, row["n"], rec.get(k), k))
            if e.get("valid") is not True:
                unknown.append("%s N=%s: lease_ends.json valid %s" % (point, row["n"], e.get("valid")))
                unread += 1
            rows.append(row)
        # "No reclaim happened" is known only when every rung of the climb was read and valid (fix round 2).
        if not tot["reclaims"]:
            if rows and not unread:
                why.append("%s: no reclaim happened" % point)
            else:
                unknown.append("%s: no reclaim counted, but %s" % (
                    point, "%d rung(s) unread or invalid" % unread if rows else "the climb lists no rungs"))
        sbx = [{"dir": r["dir"], "n": r["params"].get("n"), "memory_abort": r["params"].get("memory_abort"),
                "oom_kills": r["params"].get("oom_kills")}
               for r in rungs if r["point"] == point and r["arm"] == "sbx" and r["name"].endswith("-sq")]
        value[point] = {"stop_n": sq.get("stop_n"), "stopped_by": sq.get("stopped_by"),
                        "memmax_mb": sq.get("memmax_mb"), "rungs": rows, "totals": tot, "sbx_rungs": sbx}
    return criterion(value, inputs, missing, judged(why, unknown), why + ["not judged: " + u for u in unknown])


def notices(rungs):
    v = {"rungs": 0, "true": 0, "false": 0, "null": 0, "invalid": 0, "false_rungs": [], "invalid_rungs": [],
         "ended_after_sweep": 0, "ended_by_run_cut": 0, "live_at_stop": 0, "r16_met": False,
         "rule": "E17B-R16: met when no rung is false, every rung is valid, and at least one rung is true"}
    inputs, missing = [], []
    for r in rungs:
        if not is_ship(r):
            continue
        p = os.path.join(r["dir"], "lease_ends.json")
        e = load(p)
        if e is None:
            missing.append(p)
            continue
        inputs.append(p)
        v["rungs"] += 1
        c4 = e.get("criterion4_pass")
        v[{True: "true", False: "false", None: "null"}.get(c4, "null")] += 1
        if c4 is False:
            v["false_rungs"].append(r["dir"])
        if e.get("valid") is not True:
            v["invalid"] += 1
            v["invalid_rungs"].append(r["dir"])
        n = e.get("notices") or {}
        v["ended_after_sweep"] += int(n.get("ended_after_sweep") or 0)
        v["ended_by_run_cut"] += int(n.get("ended_by_run_cut") or 0)  # E17B-R54
        v["live_at_stop"] += int(n.get("live_at_stop") or 0)
    v["r16_met"] = v["false"] == 0 and v["invalid"] == 0 and not missing and v["true"] >= 1
    why = []
    if not v["r16_met"]:
        why = (["%d rung(s) criterion4_pass false" % v["false"]] if v["false"] else []) + \
              (["%d rung(s) not valid" % v["invalid"]] if v["invalid"] else []) + \
              (["%d ship rung(s) without lease_ends.json" % len(missing)] if missing else []) + \
              (["no rung with criterion4_pass true"] if v["true"] < 1 else [])
    return criterion(v, inputs, missing, v["r16_met"], why)


def fpr_point(rungs, point):
    first, second, inputs, missing = [], [], [], []
    pool = {"follows_true": 0, "follows_false": 0, "not_judged_low_growth": 0, "absolute_readings": 0,
            "absolute_pinned": 0, "judged_readings": 0}
    for r in rungs:
        if r["point"] != point or not is_ship(r):
            continue
        p = os.path.join(r["dir"], "vm_age_lease.json")
        v = load(p)
        if v is None:
            missing.append(p)
            continue
        inputs.append(p)
        f = v.get("fpr") or {}
        a = f.get("absolute") or {}
        first.append({"rung": r["dir"], "arm": r["arm"], "n": r["params"].get("n"),
                      "mapping_valid": v.get("mapping_valid"), "share_true": f.get("share_true"),
                      "follows_true": f.get("follows_true"), "follows_false": f.get("follows_false"),
                      "not_judged_low_growth": f.get("not_judged_low_growth"),
                      "pinned_share": a.get("pinned_share"), "pinned_share_of_judged": a.get("pinned_share_of_judged"),
                      "pinned_vm_share": a.get("pinned_vm_share")})
        if v.get("mapping_valid") and f:
            pool["follows_true"] += int(f.get("follows_true") or 0)
            pool["follows_false"] += int(f.get("follows_false") or 0)
            pool["not_judged_low_growth"] += int(f.get("not_judged_low_growth") or 0)
            pool["absolute_readings"] += int(a.get("readings") or 0)
            pool["absolute_pinned"] += int(a.get("pinned") or 0)
            pool["judged_readings"] += int(a.get("judged_readings") or 0)
        rep = v.get("replacement") or {}
        second.append({"rung": r["dir"], "arm": r["arm"], "n": r["params"].get("n"),
                       "replacement_leases": rep.get("replacement_leases"),
                       "median_first_py_grep_ms": rep.get("median_first_py_grep_ms"),
                       "sbx_median_py_grep_ms": rep.get("sbx_median_py_grep_ms"),
                       "ratio_to_sbx": rep.get("ratio_to_sbx")})
    judged = pool["follows_true"] + pool["follows_false"]
    pool["share_true"] = pool["follows_true"] / float(judged) if judged else None
    pool["pinned_share"] = (pool["absolute_pinned"] / float(pool["absolute_readings"])
                            if pool["absolute_readings"] else None)
    ratios = [x["ratio_to_sbx"] for x in second if x["ratio_to_sbx"] is not None]
    return ({"first_half": {"rungs": first, "pooled": pool},
             "second_half": {"rungs": second, "ratio_to_sbx_max": max(ratios) if ratios else None,
                             "ratio_to_sbx_min": min(ratios) if ratios else None,
                             "rungs_without_sbx": sum(x["ratio_to_sbx"] is None for x in second)}},
            inputs, missing)


def memory(rungs):
    value, inputs, missing = fpr_point(rungs, FPR_POINT)
    value["point"] = FPR_POINT
    value["reported"] = {}
    for p in FPR_REPORTED:
        v, i, _ = fpr_point(rungs, p)
        if i:
            value["reported"][p] = v
            inputs += i
    if not value["first_half"]["rungs"]:
        missing.append("no ship rung with vm_age_lease.json at %s" % FPR_POINT)
    return criterion(value, inputs, missing)


def verdict(root, moca_commit=None):
    rungs, excluded = find_rungs(root, moca_commit)
    return {"runs": root, "moca_commit": moca_commit, "excluded_rungs": excluded,
            "note": "criteria 1-4 apply SPEC 7.5's fixed bars (E17B-R40); criterion 5's pass stays null until its "
                    "thresholds are sealed (Task 13)",
            "criteria": {"1": dict(name="capacity", **capacity(root)), "2": dict(name="latency", **latency(rungs)),
                         "3": dict(name="reclaim", **reclaim(root, rungs)), "4": dict(name="notices", **notices(rungs)),
                         "5": dict(name="memory returns and the workspace stays cached", **memory(rungs))}}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("runs")
    ap.add_argument("--moca-commit", default=None)
    ap.add_argument("--out", default=None)
    a = ap.parse_args(argv)
    r = verdict(a.runs, a.moca_commit)
    out = a.out or os.path.join(a.runs, "verdict.json")
    with open(out, "w") as f:
        json.dump(r, f, indent=2, sort_keys=True)
        f.write("\n")
    c = r["criteria"]
    print("%s: pass c1 %s c2 %s c3 %s c4 %s c5 %s; c1 ship-300 %s sbx %s; c2 %s; c4 r16_met %s; c5 share_true %s "
          "pinned_share %s; missing %d; excluded %d"
          % (out, c["1"]["pass"], c["2"]["pass"], c["3"]["pass"], c["4"]["pass"], c["5"]["pass"],
             c["1"]["value"]["ship_300_n_max"], c["1"]["value"]["sbx_n_max"], c["2"]["value"]["gated"],
             c["4"]["value"]["r16_met"], c["5"]["value"]["first_half"]["pooled"]["share_true"],
             c["5"]["value"]["first_half"]["pooled"]["pinned_share"],
             sum(len(x["missing"]) for x in c.values()), len(r["excluded_rungs"])))
    return r


if __name__ == "__main__":
    main()
