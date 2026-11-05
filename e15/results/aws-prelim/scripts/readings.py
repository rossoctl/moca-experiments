#!/usr/bin/env python3
"""readings.py RUNS_DIR: per point/arm ladder, the sealed reading (ladder.json: repeat counts)
and a first-run-only reading (each rung's first run, N<n>[-k2], ignoring -repeat), plus the
rungs where the footprint-drift repeat flipped a verdict. JSON on stdout. Read-only."""
import glob, json, os, sys
runs = sys.argv[1]
out = []
for lj in sorted(glob.glob(os.path.join(runs, "*", "*", "ladder.json"))):
    pa = os.path.dirname(lj)
    point, arm = pa.split("/")[-2:]
    if point.startswith("_") or point == "smoke" or arm == "control":
        continue
    L = json.load(open(lj))
    rows = []
    for r in L["rungs"]:
        n = r["n"]
        first_dir = None
        for cand in ("N%d-k2" % n, "N%d" % n):
            if os.path.exists(os.path.join(pa, cand, "record.json")):
                first_dir = os.path.join(pa, cand); break
        fr = json.load(open(os.path.join(first_dir, "record.json"))) if first_dir else {}
        cr = json.load(open(os.path.join(r["dir"], "record.json"))) if os.path.exists(os.path.join(r["dir"], "record.json")) else {}
        rows.append({"n": n, "repeated": r["repeated"],
                     "first": {"holds": fr.get("holds"), "holds_abs": fr.get("holds_abs"),
                               "p95_excess_ms": fr.get("p95_excess_ms"), "drift_pct": fr.get("footprint_drift_pct"),
                               "reason": fr.get("reason")},
                     "counted": {"holds": r["holds"], "holds_abs": r["holds_abs"],
                                 "p95_excess_ms": cr.get("p95_excess_ms"), "drift_pct": cr.get("footprint_drift_pct"),
                                 "reason": cr.get("reason")}})
    def walk(key, which):
        nm = None
        for x in rows:
            if x[which][key]:
                nm = x["n"]
            else:
                return nm, x["n"]
        return nm, None
    flips = [x["n"] for x in rows if x["repeated"] and
             (x["first"]["holds"] != x["counted"]["holds"] or x["first"]["holds_abs"] != x["counted"]["holds_abs"])]
    fo, fo_st = walk("holds", "first"); foa, foa_st = walk("holds_abs", "first")
    # first-run reading may stop earlier than the sealed ladder; it never extends past the rungs run
    out.append({"point": point, "arm": arm, "start_n": L["start_n"],
                "sealed": {"n_max": L["n_max"], "n_max_abs": L["n_max_abs"]},
                "first_run_only": {"n_max": fo, "stopped_at": fo_st, "n_max_abs": foa, "stopped_at_abs": foa_st,
                                   "censored": fo_st is None or foa_st is None},
                "rungs_repeated": sum(x["repeated"] for x in rows), "rungs_run": len(rows),
                "flipped": flips,
                "flipped_to_hold": [x["n"] for x in rows if x["repeated"] and not x["first"]["holds"] and x["counted"]["holds"]],
                "flipped_to_fail": [x["n"] for x in rows if x["repeated"] and x["first"]["holds"] and not x["counted"]["holds"]],
                "rungs": rows})
json.dump(out, sys.stdout, indent=1)
