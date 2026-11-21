#!/usr/bin/env python3
"""E17c verdict: the four gated criteria of SPEC §13.4 computed by code from the rung tree, and what §13.4 reports.

  python3 experiments/e17-lease/analysis/verdict_e17c.py RUNS_DIR [--moca-commit PIN] [--out FILE]
      [--predictions FILE] [--gate-pycache-low FILE]
      -> FILE (default RUNS_DIR/verdict.json), one summary line

RUNS_DIR is the rig's $E15_RUNS (POINT/ARM/RUNG/...), read as verdict.py (E17b) reads it, whose helpers this reuses:
rung discovery and the --moca-commit exclusion, the {value, inputs, missing, pass, why} shape, criterion 2's latency
reading and criterion 3's reclaim reading, and criterion 5's replacement rows. A missing input is null and listed
under `missing`, never guessed. --predictions defaults to predictions-e17c.json beside this directory (where the
chain stages it); 5a' reads its "criterion5a_reading".

Gated (`criteria`), ruling R-z2 (SPEC §13.6: the N = 1 seeds run after the seal): every gated pool reads only the
seal stages' rungs at pycache, the fresh N = 1 seeds N1-l<k> (chain-e17c.sh's lat-pycache-ARM-n1: seeds 11..14, from
the first call) that are evaluable, and N128-lat (gated_rungs). Never the bring-up smoke (N1-smoke), the class probes
(N1-probe-*), the calibration seeds N1-s<k> (cal-*: the predictions are drafted from them), a gate rung (N1-g*) or an
empty_window seed. A seed is evaluable when its record.json exists and its reason is not empty_window (rig/
chain-e17c.sh's cal rule, R-l'); non-evaluable seeds are listed and not read; an unreadable record.json is missing.
  5a_prime  At pycache, ship-300 pooled over the gated rungs, by summing counts from each vm_age_lease.json's E17c
            fpr keys (never averaging shares): follow share = follows_fp_true /
            (follows_fp_true + follows_fp_false) >= 0.50, and pinned share <= 0.50 on the reading predictions-e17c.json
            names (ruling R-c): "plus45" -> fp_45s_pinned / fp_45s_readings, "idle_tail" -> fp_idle_tail_pinned /
            fp_idle_tail_readings, over ALL heavy readings (R-p). The *_of_judged variants and the +15 s reading are
            reported. Absent or unsealed predictions, or any other reading value: pass null, the reason in `missing`.
            A rung without vm_age_lease.json, with mapping_valid not true, or without the vm_fp keys: null.
  2_prime   E17b's criterion 2 (verdict.latency over the gated rungs) for ship-300 against sbx at pycache: warm
            py_short gain >= 0.50 and py_import >= 0.30 at N=1 (the evaluable N1-l<k> pooled; fewer than 4 evaluable
            per arm for sbx or ship-300 leaves the N=1 half null) and N=128 (N128-lat). As in E17b, a failing gain
            makes it false even when the other half is null. Gains are over all warm calls; Task 5's after_drop /
            kept split rides in `groups` (classes[].warm_by_cache), reported, not gated.
  5b_prime  Every gated ship-* rung at pycache (ship-300 and ship-300-nd): replacement-lease median first py_grep
            within 1.5x of sbx (vm_age_lease --sbx ratio_to_sbx; the seal stages give sbx the same N1-l<k> and
            N128-lat names, so the chain pairs each ship rung with its same-named sbx rung, R-z3). A rung with no
            replacement lease with a first py_grep has no reading (counted, not a failure); a rung with one but no
            sbx median, a ship rung without vm_age_lease.json, or an arm with no ratio at all leaves it null (ruling
            R-r, E17b's sealed rule: a half with no judged reading is null, not a pass).
  3_prime   E17b's criterion 3 (verdict.reclaim) at squeeze for the ship-300 climb only.

Top-level `pass`: true only when all four are true; null when any is null; false otherwise.

Reported, never gated (`reported`): ship-300-nd on every reading (5a's pooled readings and its warm gains, over the
same gated rungs); pycache-low
(its warm gains from its baseline seeds N1-s<k>, evaluable ones, and N128-lat, never the gate's calibration rungs
N1-g<k> (ruling R-v), and gate-pycache-low.json when the gate wrote one: --gate-pycache-low, else
RUNS/pycache-low/gate-pycache-low.json, else gate-pycache-low.json beside --out); the 256 MiB stages (pycache-d64:
5a's readings and warm gains, never gate-256's calibration rungs N1-g256-s<scale>, and RUNS/pycache-d64/gate-256.json's
pass, chosen_scale and reason; squeeze-256: criterion 3 there); the ownership walk (RUNS/ownwalk/ship-300/F<n>/
ownwalk.json, its top-level scalars per size).
"""
import argparse
import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import verdict as V  # noqa: E402  (E17b's helpers; it sets up latency_report and the E15 analysis path)

LR = V.LR
DEFAULT_PREDICTIONS = os.path.join(os.path.dirname(HERE), "predictions-e17c.json")
GATED = ("5a_prime", "2_prime", "5b_prime", "3_prime")
POINT = "pycache"
ARM = "ship-300"
ARM_ND = "ship-300-nd"
READINGS = {"plus45": "45s", "idle_tail": "idle_tail"}  # R-c: the sealed reading -> its fpr key infix
FOLLOW_MIN = 0.50
PINNED_MAX = 0.50
RATIO_MAX = 1.5  # SPEC §13.4 5b': within 1.5x of sbx
MIN_SEEDS = 4  # SPEC §13.4 2' / §13.5 (R52): at least 4 N=1 seeds per arm
N1_SEED = re.compile(r"^N1-s[0-9]+$")  # cal-*'s seeds (pycache) and pycache-low's baseline seeds
N1_SEAL = re.compile(r"^N1-l[0-9]+$")  # R-z2: the seal stages' fresh N=1 seeds at pycache (lat-pycache-ARM-n1)
N128 = "N128-lat"
GATE_LOW = "gate-pycache-low.json"
GATE_256 = "gate-256.json"
GATE_256_RUNG = re.compile(r"^N1-g256-s[0-9]+$")  # Task 10: gate-256's calibration rungs at pycache-d64


def ratio(n, d):
    return n / float(d) if d else None


def gains(groups, point, arm):
    """{n: {class: gain}} for one arm at one point, from latency_report groups."""
    out = {}
    for g in groups or []:
        if g.get("point") == point and g.get("arm") == arm:
            out[str(g.get("n"))] = {c: (s or {}).get("gain") for c, s in sorted((g.get("classes") or {}).items())}
    return out


# ---- 5a' -----------------------------------------------------------------------------------------------------------

def predictions_reading(path):
    """({path, sealed, criterion5a_reading}, reading or None, why-missing or None)."""
    info = {"path": path, "sealed": None, "criterion5a_reading": None}
    if not path:
        return info, None, "no predictions path: criterion5a_reading unknown"
    if not os.path.exists(path):
        return info, None, "predictions %s absent: criterion5a_reading unknown" % path
    p = V.load(path)
    if not isinstance(p, dict):
        return info, None, "predictions %s unreadable: criterion5a_reading unknown" % path
    info["sealed"], info["criterion5a_reading"] = p.get("sealed"), p.get("criterion5a_reading")
    if p.get("sealed") is not True:
        return info, None, "predictions %s not sealed: criterion5a_reading not binding" % path
    r = p.get("criterion5a_reading")
    if r not in READINGS:
        return info, None, "predictions %s criterion5a_reading %r is not plus45 or idle_tail" % (path, r)
    return info, r, None


def fp_pool(rungs, point, arm):
    """5a's readings at one point and arm, pooled by summing counts: (value, inputs, missing)."""
    rows, inputs, missing = [], [], []
    pool = {"follows_fp_true": 0, "follows_fp_false": 0, "follows_fp_null": 0, "not_judged_low_growth_fp": 0}
    for name in ("plus15", "plus45", "idle_tail"):
        pool[name] = {"readings": 0, "pinned": 0}
        if name != "idle_tail":
            pool[name].update(judged_readings=0, judged_pinned=0)
    for r in rungs:
        if r["point"] != point or r["arm"] != arm:
            continue
        p = os.path.join(r["dir"], "vm_age_lease.json")
        v = V.load(p)
        if v is None:
            missing.append(p)
            continue
        inputs.append(p)
        f = v.get("fpr") or {}
        row = {"rung": r["dir"], "n": r["params"].get("n"), "mapping_valid": v.get("mapping_valid"),
               "share_true_fp": f.get("share_true_fp"), "pinned_share_fp_15s": f.get("pinned_share_fp_15s"),
               "pinned_share_fp_45s": f.get("pinned_share_fp_45s"),
               "pinned_share_fp_45s_of_judged": f.get("pinned_share_fp_45s_of_judged"),
               "pinned_share_fp_idle_tail": f.get("pinned_share_fp_idle_tail"),
               "share_true_mem": f.get("share_true"),
               "pinned_share_mem_15s": (f.get("absolute") or {}).get("pinned_share")}
        rows.append(row)
        if v.get("mapping_valid") is not True:
            missing.append("%s: mapping_valid %s (no reading)" % (p, v.get("mapping_valid")))
            continue
        if "follows_fp_true" not in f or "fp_45s_readings" not in f:
            missing.append("%s: no vm_fp readings (an E17b-shaped fpr)" % p)
            continue
        for k in ("follows_fp_true", "follows_fp_false", "follows_fp_null", "not_judged_low_growth_fp"):
            pool[k] += int(f.get(k) or 0)
        for name, tag in (("plus15", "15s"), ("plus45", "45s")):
            n = int(f.get("fp_%s_readings" % tag) or 0)
            pool[name]["readings"] += n
            pool[name]["pinned"] += int(f.get("fp_%s_pinned" % tag) or 0)
            j = int(f.get("fp_%s_judged_readings" % tag) or 0)
            js = f.get("pinned_share_fp_%s_of_judged" % tag)
            pool[name]["judged_readings"] += j
            pool[name]["judged_pinned"] += int(round(js * j)) if js is not None else 0  # the module keeps no count
        pool["idle_tail"]["readings"] += int(f.get("fp_idle_tail_readings") or 0)
        pool["idle_tail"]["pinned"] += int(f.get("fp_idle_tail_pinned") or 0)
    for name in ("plus15", "plus45", "idle_tail"):
        pool[name]["pinned_share"] = ratio(pool[name]["pinned"], pool[name]["readings"])
        if "judged_readings" in pool[name]:
            pool[name]["pinned_share_of_judged"] = ratio(pool[name]["judged_pinned"], pool[name]["judged_readings"])
    follow = ratio(pool["follows_fp_true"], pool["follows_fp_true"] + pool["follows_fp_false"])
    return {"point": point, "arm": arm, "rungs": rows, "pooled": pool, "follow_share": follow}, inputs, missing


def c5a(g, preds_path):
    value, inputs, missing = fp_pool(g["rungs"], POINT, ARM)
    missing = missing + g["unreadable"]
    info, reading, why_pred = predictions_reading(preds_path)
    value.update(reading=reading, predictions=info,
                 bars={"follow_share_min": FOLLOW_MIN, "pinned_share_max": PINNED_MAX},
                 pinned_share=value["pooled"][reading]["pinned_share"] if reading else None)
    if not value["rungs"]:
        missing.append("no %s rung with vm_age_lease.json at %s" % (ARM, POINT))
    if why_pred:
        missing.append(why_pred)
    why = []
    if missing:
        return criterion("charge after a heavy command (Q5)", value, inputs, missing, None, [])
    if value["follow_share"] is None:
        missing.append("no judged heavy Exec (follows_fp true or false) at %s %s" % (POINT, ARM))
    elif value["follow_share"] < FOLLOW_MIN:
        why.append("follow share %.3f < %.2f" % (value["follow_share"], FOLLOW_MIN))
    if value["pinned_share"] is None:
        missing.append("no %s footprint reading at %s %s" % (reading, POINT, ARM))
    elif value["pinned_share"] > PINNED_MAX:
        why.append("pinned share (%s, >= 0.9 of guest RAM) %.3f > %.2f" % (reading, value["pinned_share"], PINNED_MAX))
    return criterion("charge after a heavy command (Q5)", value, inputs, missing, V.judged(why, missing), why)


def criterion(name, value, inputs, missing, passed, why):
    return dict(name=name, **V.criterion(value, inputs, missing, passed, why))


# ---- 2' -------------------------------------------------------------------------------------------------------------

def seed_state(r):
    """R-l': a seed is evaluable when its record.json exists and its reason is not empty_window (the chain's cal
    stage rule). -> "evaluable", "empty_window", "no_record" or "unreadable"."""
    p = os.path.join(r["dir"], "record.json")
    if not os.path.exists(p):
        return "no_record"
    rec = V.load(p)
    if not isinstance(rec, dict):
        return "unreadable"
    return "empty_window" if rec.get("reason") == "empty_window" else "evaluable"


def gated_rungs(rungs):
    """R-z2/R-z3: the rungs every gated pool reads: at pycache, sbx and the ship-* arms, N128-lat and the evaluable
    seal seeds N1-l<k>. -> {"rungs", "seeds" (evaluable N1-l<k> per gated arm), "not_evaluable", "unreadable"}."""
    keep, seeds, not_eval, unreadable = [], {"sbx": 0, ARM: 0}, [], []
    for r in rungs:
        if r["point"] != POINT or not (r["arm"] == "sbx" or V.is_ship(r)):
            continue
        if r["name"] == N128:
            keep.append(r)
        elif N1_SEAL.match(r["name"]):
            st = seed_state(r)
            if st == "evaluable":
                keep.append(r)
                if r["arm"] in seeds:
                    seeds[r["arm"]] += 1
                continue
            not_eval.append({"rung": r["dir"], "state": st})
            if st == "unreadable":
                unreadable.append("%s/record.json unreadable" % r["dir"])
    return {"rungs": keep, "seeds": seeds, "not_evaluable": sorted(not_eval, key=lambda x: x["rung"]),
            "unreadable": unreadable}


def c2(g):
    seeds, unreadable = g["seeds"], g["unreadable"]
    c = V.latency(g["rungs"], select=lambda r: True)
    gated = c["value"]["gated"]
    short = ["pycache N=1 %s has %d evaluable seed(s) N1-l<k> (record.json, reason not empty_window; need %d): "
             "the N=1 half is not judged" % (a, n, MIN_SEEDS) for a, n in sorted(seeds.items()) if n < MIN_SEEDS]
    c["value"].update(seeds=seeds, min_seeds=MIN_SEEDS, seeds_not_evaluable=g["not_evaluable"],
                      n1_judged=not short)
    fails = []
    for n, v in sorted(gated.items()):
        if n == "1" and short:
            continue
        for cl, gain in sorted(v.items()):
            if gain is not None and gain < V.GAIN_BARS[cl]:
                fails.append("pycache N=%s ship-300 warm %s gain %.3f < %.2f" % (n, cl, gain, V.GAIN_BARS[cl]))
    missing = sorted(set(c["missing"] + short + unreadable))
    c["missing"] = missing
    c["pass"] = V.judged(fails, missing)
    c["why"] = fails + ["not judged: " + m for m in short + unreadable]
    return dict(name="warm latency at the new pin (Q6)", **c)


# ---- 5b' ------------------------------------------------------------------------------------------------------------

def c5b(g):
    fv, inputs, missing = V.fpr_point(g["rungs"], POINT)
    missing = missing + g["unreadable"]
    rows = fv["second_half"]["rungs"]
    why, unknown, none = [], [], 0
    arms = {}
    for x in rows:
        arms.setdefault(x["arm"], 0)
        if x["ratio_to_sbx"] is not None:
            arms[x["arm"]] += 1
            if x["ratio_to_sbx"] > RATIO_MAX:
                why.append("%s: replacement first py_grep %.3gx sbx > %.1fx"
                           % (x["rung"], x["ratio_to_sbx"], RATIO_MAX))
        elif x["median_first_py_grep_ms"] is not None:
            unknown.append("%s: a replacement first py_grep but no sbx median py_grep (vm_age_lease --sbx)" % x["rung"])
        else:
            none += 1
    for a in (ARM, ARM_ND):
        if not arms.get(a):
            unknown.append("%s at %s: no rung with a replacement ratio_to_sbx" % (a, POINT))
    missing = missing + unknown
    ratios = [x["ratio_to_sbx"] for x in rows if x["ratio_to_sbx"] is not None]
    value = {"point": POINT, "bar": RATIO_MAX, "rungs": rows, "ratio_to_sbx_max": max(ratios) if ratios else None,
             "ratio_to_sbx_min": min(ratios) if ratios else None, "rungs_without_replacement": none,
             "rungs_with_ratio": arms}
    return criterion("replacement reads (5b)", value, inputs, missing, V.judged(why, missing), why)


# ---- 3' -------------------------------------------------------------------------------------------------------------

def c3(root, rungs):
    return dict(name="squeeze reclaim (ship-300)", **V.reclaim(root, rungs, points=("squeeze",)))


# ---- reported ------------------------------------------------------------------------------------------------------

def gate_low(root, path, out):
    cands = [path] if path else [os.path.join(root, "pycache-low", GATE_LOW)] + (
        [os.path.join(os.path.dirname(os.path.abspath(out)), GATE_LOW)] if out else [])
    for p in cands:
        if os.path.exists(p):
            return {"path": p, "value": V.load(p)}
    return None


def gate_256(root):
    """Task 10: gate-256.json's verdict (RUNS/pycache-d64/gate-256.json), or None when the gate wrote none."""
    p = os.path.join(root, "pycache-d64", GATE_256)
    v = V.load(p) if os.path.exists(p) else None
    if not isinstance(v, dict):
        return None
    return {"path": p, "pass": v.get("pass"), "chosen_scale": v.get("chosen_scale"), "reason": v.get("reason")}


def ownwalk(root):
    sizes = {}
    for p in sorted(glob.glob(os.path.join(root, "ownwalk", ARM, "F*", "ownwalk.json"))):
        n = os.path.basename(os.path.dirname(p))[1:]
        v = V.load(p)
        sizes[n] = None if not isinstance(v, dict) else \
            {k: x for k, x in sorted(v.items()) if not isinstance(x, (dict, list))}
        if sizes[n] is not None:
            sizes[n]["path"] = p
    return {"sizes": sizes}


def low_lat(rungs):
    """R-v: pycache-low's reported gains from its baseline seeds N1-s<k> (evaluable ones, the cal rule) and N128-lat
    (N1-lat too, E17b's name); the gate's N1-g<k> rungs are calibration only and never read."""
    dirs = [r["dir"] for r in rungs if r["point"] == "pycache-low" and (r["arm"] == "sbx" or V.is_ship(r))
            and (r["name"] in V.LAT_NAMES or (N1_SEED.match(r["name"]) and seed_state(r) == "evaluable"))]
    if not dirs:
        return {"groups": [], "error": None, "inputs": []}
    try:
        rep = LR.build(dirs, baseline_arm="sbx")
    except SystemExit as e:
        return {"groups": [], "error": str(e), "inputs": sorted(dirs)}
    return {"groups": rep["groups"], "error": None, "inputs": sorted(dirs)}


def lat_point(rungs, point):
    dirs = [r["dir"] for r in rungs if r["point"] == point and (r["arm"] == "sbx" or V.is_ship(r))]
    if not dirs:
        return {"groups": [], "error": None}
    try:
        rep = LR.build(dirs, baseline_arm="sbx")
    except SystemExit as e:
        return {"groups": [], "error": str(e)}
    return {"groups": rep["groups"], "error": None}


def reported(root, rungs, g, c2v, gate_path, out):
    groups = c2v["value"]["groups"]
    nd5a = fp_pool(g["rungs"], POINT, ARM_ND)[0]
    # Task 10: gate-256's calibration rungs (N1-g256-s<scale>: a probe corpus, a gate library) are never read here
    r256 = [r for r in rungs if not (r["point"] == "pycache-d64" and GATE_256_RUNG.match(r["name"]))]
    d64 = lat_point(r256, "pycache-d64")
    d64_arms = sorted({r["arm"] for r in r256 if r["point"] == "pycache-d64" and V.is_ship(r)})
    low_arms = sorted({r["arm"] for r in rungs if r["point"] == "pycache-low" and V.is_ship(r)})
    low = low_lat(rungs)
    s256 = V.reclaim(root, rungs, points=("squeeze-256",))
    return {
        "ship-300-nd": {"5a": nd5a, "latency": gains(groups, POINT, ARM_ND)},
        "pycache-low": {"latency": {a: gains(low["groups"], "pycache-low", a) for a in low_arms},
                        "latency_error": low["error"], "inputs": low["inputs"], "gate": gate_low(root, gate_path, out)},
        "ram256": {"pycache-d64": {"latency": {a: gains(d64["groups"], "pycache-d64", a) for a in d64_arms},
                                   "latency_error": d64["error"],
                                   "5a": {a: fp_pool(r256, "pycache-d64", a)[0] for a in d64_arms},
                                   "gate": gate_256(root)},
                   "squeeze-256": dict(name="squeeze reclaim at 256 MiB (reported)", **s256)},
        "ownwalk": ownwalk(root),
        "note": "SPEC 13.4: reported, not gated",
    }


def verdict(root, moca_commit=None, predictions=None, gate_pycache_low=None, out=None):
    rungs, excluded = V.find_rungs(root, moca_commit)
    g = gated_rungs(rungs)
    c2v = c2(g)
    crit = {"5a_prime": c5a(g, predictions), "2_prime": c2v, "5b_prime": c5b(g), "3_prime": c3(root, rungs)}
    ps = [crit[k]["pass"] for k in GATED]
    top = True if all(p is True for p in ps) else (None if any(p is None for p in ps) else False)
    why = ["%s: %s" % (k, "not judged" if crit[k]["pass"] is None else "failed") for k in GATED
           if crit[k]["pass"] is not True]
    return {"runs": root, "moca_commit": moca_commit, "excluded_rungs": excluded,
            "predictions": predictions_reading(predictions)[0], "pass": top, "why": why,
            "note": "SPEC 13.4: pass is true only when 5a', 2', 5b' and 3' all hold, null when any is null",
            "criteria": crit, "reported": reported(root, rungs, g, c2v, gate_pycache_low, out)}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("runs")
    ap.add_argument("--moca-commit", default=None)
    ap.add_argument("--out", default=None)
    ap.add_argument("--predictions", default=DEFAULT_PREDICTIONS)
    ap.add_argument("--gate-pycache-low", default=None)
    a = ap.parse_args(argv)
    out = a.out or os.path.join(a.runs, "verdict.json")
    r = verdict(a.runs, a.moca_commit, a.predictions, a.gate_pycache_low, out)
    with open(out, "w") as f:
        json.dump(r, f, indent=2, sort_keys=True)
        f.write("\n")
    c = r["criteria"]
    v5 = c["5a_prime"]["value"]
    print("%s: pass %s; 5a' %s (reading %s, follow %s, pinned %s) 2' %s %s 5b' %s (max %s) 3' %s; missing %d; "
          "excluded %d" % (out, r["pass"], c["5a_prime"]["pass"], v5["reading"], v5["follow_share"],
                           v5["pinned_share"], c["2_prime"]["pass"], c["2_prime"]["value"]["gated"],
                           c["5b_prime"]["pass"], c["5b_prime"]["value"]["ratio_to_sbx_max"], c["3_prime"]["pass"],
                           sum(len(x["missing"]) for x in c.values()), len(r["excluded_rungs"])))
    return r


if __name__ == "__main__":
    main()
