#!/usr/bin/env python3
"""E17b level-1 overhead (spec §7.4, PLAN-E17B Task 11): ship-300 against the E17a resident patch at N = 1.

  python3 experiments/e17-lease/analysis/overhead_compare.py SHIP_BASELINE [REFERENCE] [--out OUT.json]

Both inputs are baseline.json files from e15/rig/baseline.sh at the `default` point. Their class_medians are
each default probe class's median added latency (observed - planned) over its 20 probe calls on an idle
worker (classprobe.sh), so for the same corpus (the probe corpora are drawn from it with the same seed) the
difference of two arms' medians is the per-call latency one arm adds over the other. Here:

    added_ms = ship-300's class median - the reference's

the cost of the lease's end-of-Exec kill, fresh shell and privilege drop (lease spec §3.1-3.3), which the
resident patch does not pay. REFERENCE defaults to the resident patch's own N = 1 default probe,
e15-session-density/results/metal/baseline/default/resident-300/N1/baseline.json: E17a reused E15's metal
ladders at the default point (E17A-REPORT §1, the same patch 1d0ce8b1), and its own calibration under
results/calibration/ is at the pycache point only. The rig does not have it (sync.sh excludes results/):
probe-overhead.sh runs this on the rig only when a reference is staged, else the controller runs it here.

Writes OUT (default: none) with the per-class table, the classes only one side has, the weighted overhead
(overhead_ms) and global median of each side and their differences, the median of the per-class
differences, the hashes of both sides, and `comparable`: both sides carry the corpus and library hashes and
they agree (`comparable_reasons` says which check failed; a different corpus is computed anyway and flagged). Prints the table. Exit 1 when an input is unreadable or has no
class_medians.
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
# Relative to experiments/.
DEFAULT_REFERENCE = os.path.join("e15-session-density", "results", "metal", "baseline", "default", "resident-300",
                                 "N1", "baseline.json")
HASHES = ("corpus_sha256", "library_sha256", "point_sig", "driver_bin_sha256")


def r3(v):
    return None if v is None else round(v, 3)


def diff(a, b):
    return None if a is None or b is None else r3(a - b)


def median(v):
    s = sorted(v)
    n = len(s)
    if not n:
        return None
    return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2


def load(path):
    try:
        with open(path) as f:
            b = json.load(f)
    except (OSError, ValueError) as e:
        sys.exit("overhead_compare.py: cannot read %s: %s" % (path, e))
    if not isinstance(b, dict) or not isinstance(b.get("class_medians"), dict) or not b["class_medians"]:
        sys.exit("overhead_compare.py: %s has no class_medians (not a baseline.sh baseline.json)" % path)
    return b


def compare(ship_path, ref_path):
    ship, ref = load(ship_path), load(ref_path)
    sm, rm = ship["class_medians"], ref["class_medians"]
    sc, rc = ship.get("class_counts") or {}, ref.get("class_counts") or {}
    classes = {}
    for c in sorted(set(sm) & set(rm)):
        classes[c] = {"ship_ms": r3(sm[c]), "reference_ms": r3(rm[c]), "added_ms": diff(sm[c], rm[c]),
                      "ship_n": sc.get(c), "reference_n": rc.get(c)}
    same = {k: ship.get(k) is not None and ship.get(k) == ref.get(k) for k in HASHES}
    # comparable needs both hashes present on both sides and equal: two absent hashes prove nothing.
    reasons = []
    for k in ("corpus_sha256", "library_sha256"):
        missing = [side for side, b in (("ship", ship), ("reference", ref)) if not b.get(k)]
        if len(missing) == 2:
            reasons.append("%s missing on both sides" % k)
        elif missing:
            reasons.append("%s missing on the %s" % (k, missing[0]))
        elif ship[k] != ref[k]:
            reasons.append("%s differs" % k)
    return {
        "ship": dict({"path": ship_path}, **{k: ship.get(k) for k in HASHES}),
        "reference": dict({"path": ref_path}, **{k: ref.get(k) for k in HASHES}),
        "same_corpus": same["corpus_sha256"], "same_library": same["library_sha256"],
        "same_point_sig": same["point_sig"],
        "comparable": not reasons, "comparable_reasons": reasons,
        "classes": classes,
        "only_ship": sorted(set(sm) - set(rm)), "only_reference": sorted(set(rm) - set(sm)),
        "median_added_ms": r3(median([v["added_ms"] for v in classes.values()])),
        "overhead_ms": {"ship": r3(ship.get("overhead_ms")), "reference": r3(ref.get("overhead_ms")),
                        "added": diff(ship.get("overhead_ms"), ref.get("overhead_ms"))},
        "global_median_ms": {"ship": r3(ship.get("global_median_ms")), "reference": r3(ref.get("global_median_ms")),
                             "added": diff(ship.get("global_median_ms"), ref.get("global_median_ms"))},
        "probe_failed": {"ship": ship.get("probe_failed"), "reference": ref.get("probe_failed")},
        "note": "class medians: median added latency (observed - planned) of each class's probe calls at N=1; "
                "added_ms = ship - reference",
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("ship")
    ap.add_argument("reference", nargs="?", default=os.path.join(HERE, "..", "..", DEFAULT_REFERENCE))
    ap.add_argument("--out")
    a = ap.parse_args(argv)
    r = compare(a.ship, a.reference)
    print("%-12s %10s %10s %10s" % ("class", "ship_ms", "ref_ms", "added_ms"))
    for c, v in r["classes"].items():
        print("%-12s %10.1f %10.1f %10.1f" % (c, v["ship_ms"], v["reference_ms"], v["added_ms"]))
    o = r["overhead_ms"]
    if o["added"] is not None:
        print("%-12s %10.1f %10.1f %10.1f" % ("overhead", o["ship"], o["reference"], o["added"]))
    if r["median_added_ms"] is not None:
        print("median of the per-class added latency: %.1f ms over %d classes" % (r["median_added_ms"], len(r["classes"])))
    for side in ("only_ship", "only_reference"):
        if r[side]:
            print("%s: %s" % (side, " ".join(r[side])))
    if not r["comparable"]:
        print("WARNING: not comparable: %s (the probe calls may differ)" % "; ".join(r["comparable_reasons"]))
    if a.out:
        with open(a.out + ".tmp", "w") as f:
            json.dump(r, f, indent=2, sort_keys=True)
            f.write("\n")
        os.replace(a.out + ".tmp", a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
