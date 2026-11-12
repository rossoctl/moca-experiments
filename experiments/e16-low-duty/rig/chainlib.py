"""chainlib.py -- the decisions e16/rig/chain.sh takes from records (E16 Task 6, review finding M4).

  python3 chainlib.py summary RECORD.json
      -> "holds holds_abs p95x limit reason repeat_required unseeded" (one line, booleans true/false,
         numbers rounded, "null" when absent)
  python3 chainlib.py row OUT.json N SEED DIR INVOCATION_JSON GRACE_RERUN FIRST_DIR
      -> writes one per-rung row (the counted record's verdicts) for the arm's assembled ladder
  python3 chainlib.py assemble ARM_DIR POINT ARM LADDER...
      -> writes ARM_DIR/ladder.json from ARM_DIR/e16/N*.json rows; prints
         "n_max stopped_at n_max_abs stopped_at_abs" (null when none)
  python3 chainlib.py bisect LO HI LADDER...
      -> the ladder rung strictly between LO and HI nearest their midpoint (lower on a tie), or nothing
  python3 chainlib.py deciding ARM_DIR
      -> "n_max stopped_at" of the assembled ladder.json (the rungs the second seed re-runs)

ladder.sh (E15_LADDER_RUNGS) writes ARM_DIR/ladder.json on every invocation, so chain.sh runs it one
rung at a time, moves each invocation's ladder.json aside to ARM_DIR/e16/ladder-N<n>[-sK].json, and
this file assembles the arm's ladder from the per-rung rows. Gap semantics: n_max is the largest run
rung that holds with every run rung below it holding; ladder rungs that were never run (below the
lowest run rung, or between run rungs, e.g. 320 between 256 and 384) are assumed held and listed in
rungs_not_run_assumed_held. Seeds: a rung's verdict is the majority over its seeds (s1, s2, s3);
with two seeds that disagree and no third, the seed-1 verdict stands and the rung is listed in
seeds_undecided.
"""
import glob
import json
import os
import re
import sys


def _b(v):
    return "true" if v is True else "false"


def _num(v, nd=1):
    if v is None:
        return "null"
    return ("%.*f" % (nd, v)) if isinstance(v, float) else str(v)


def reason_of(r):
    if r.get("reason"):
        return r["reason"]
    if r.get("holds") is True:
        return "none"
    bad = sorted(k for k, v in (r.get("conditions") or {}).items() if v is False)
    out = ",".join(bad) or "unknown"
    if r.get("binding") and r.get("binding") != "none":
        out += "/binding=" + r["binding"]
    return out


def summary(path):
    r = json.load(open(path))
    lim = r.get("excess_limit_ms")
    print(" ".join([_b(r.get("holds")), _b(r.get("holds_abs")), _num(r.get("p95_excess_ms"), 0),
                    _num(lim, 0), reason_of(r).replace(" ", "_"), _b(r.get("repeat_required")),
                    str(r.get("unseeded_sessions") or 0)]))


def row(out, n, seed, d, inv, grace, first):
    r = json.load(open(os.path.join(d, "record.json")))
    os.makedirs(os.path.dirname(out), exist_ok=True)
    json.dump({"n": int(n), "seed": int(seed), "holds": r.get("holds") is True,
               "holds_abs": r.get("holds_abs") is True, "p95_excess_ms": r.get("p95_excess_ms"),
               "excess_limit_ms": r.get("excess_limit_ms"), "reason": reason_of(r),
               "repeated": os.path.basename(d) != os.path.basename(first) and "repeat" in os.path.basename(d),
               "grace_artefact_rerun": grace == "true", "first_dir": first, "dir": d,
               "invocation_ladder_json": inv or None}, open(out, "w"), indent=2)


def _rows(arm_dir):
    rows = []
    for p in sorted(glob.glob(os.path.join(arm_dir, "e16", "N*.json"))):
        if re.search(r"/N\d+(-s\d+)?\.json$", p):
            rows.append(json.load(open(p)))
    return rows


def _majority(seeds, key):
    vals = [s[key] for s in sorted(seeds, key=lambda s: s["seed"])]
    if len(vals) == 1:
        return vals[0], False
    if len(vals) == 2:
        return vals[0], vals[0] != vals[1]
    return sum(vals[:3]) >= 2, False


def _nmax(verdicts):
    n = stop = None
    for k in sorted(verdicts):
        if verdicts[k]:
            n = k
        else:
            stop = k
            break
    return n, stop


def assemble(arm_dir, point, arm, ladder):
    rows = _rows(arm_dir)
    by_n = {}
    for r in rows:
        by_n.setdefault(r["n"], []).append(r)
    v, va, undecided, rungs = {}, {}, [], []
    for n in sorted(by_n):
        seeds = by_n[n]
        v[n], und = _majority(seeds, "holds")
        va[n], und_a = _majority(seeds, "holds_abs")
        if und or und_a:
            undecided.append(n)
        rungs.append({"n": n, "holds": v[n], "holds_abs": va[n],
                      "seeds": sorted(seeds, key=lambda s: s["seed"])})
    n_max, stop = _nmax(v)
    n_max_a, stop_a = _nmax(va)
    run = set(by_n)
    top = max([x for x in (n_max, n_max_a) if x is not None], default=None)
    gaps = [x for x in ladder if top is not None and x < top and x not in run]
    base = {}
    try:
        bj = json.load(open(os.path.join(arm_dir, "N1", "baseline.json")))
        base = {"n1_overhead_ms": bj.get("overhead_ms"), "n1_median_pace": bj.get("n1_median_pace"),
                "B_ms": bj.get("excess_p95_ms")}
    except (OSError, ValueError):
        pass
    out = dict({"point": point, "arm": arm, "assembled_by": "e16/rig/chain.sh (chainlib.py)",
                "ladder": ladder, "rungs_run": sorted(run), "rungs": rungs,
                "n_max": n_max, "stopped_at": stop, "n_max_abs": n_max_a, "stopped_at_abs": stop_a,
                "rungs_not_run_assumed_held": gaps, "seeds_undecided": undecided,
                "gap_rule": "n_max = largest run rung holding with every run rung below it holding; "
                            "ladder rungs never run below it are assumed held (listed)",
                "seed_rule": "verdict = majority of seeds s1..s3; two disagreeing seeds without a "
                             "third leave seed 1's verdict and list the rung in seeds_undecided"}, **base)
    lpath = os.path.join(arm_dir, "ladder.json")
    try:
        prev = json.load(open(lpath))
    except (OSError, ValueError):
        prev = {}
    if "post_seal_extension" in prev:  # a later stage's re-assembly keeps the label
        out["post_seal_extension"] = prev["post_seal_extension"]
    elif any(r.get("post_seal_extension") for r in rows):  # rows say so even if the label was lost
        out["post_seal_extension"] = {"rungs": sorted({r["n"] for r in rows if r.get("post_seal_extension")}),
                                      "sealed": False, "sealed_ladder": "ladder.sealed.json"}
    json.dump(out, open(lpath, "w"), indent=2)
    print(" ".join(_num(x) for x in (n_max, stop, n_max_a, stop_a)))


def bisect(lo, hi, ladder):
    mid = [x for x in ladder if lo < x < hi]
    if mid:
        c = (lo + hi) / 2.0
        print(min(mid, key=lambda x: (abs(x - c), x)))


def deciding(arm_dir):
    d = json.load(open(os.path.join(arm_dir, "ladder.json")))
    print(_num(d.get("n_max")), _num(d.get("stopped_at")))


def main(a):
    cmd = a[0]
    if cmd == "summary":
        summary(a[1])
    elif cmd == "row":
        row(*a[1:8])
    elif cmd == "assemble":
        assemble(a[1], a[2], a[3], [int(x) for x in a[4:]])
    elif cmd == "bisect":
        bisect(int(a[1]), int(a[2]), [int(x) for x in a[3:]])
    elif cmd == "deciding":
        deciding(a[1])
    else:
        raise SystemExit("chainlib.py: unknown command %s" % cmd)


if __name__ == "__main__":
    main(sys.argv[1:])
