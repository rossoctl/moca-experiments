"""N=1 baseline (SPEC §8 condition 4): `python3 baseline.py OUT_JSON RUN_DIR [RUN_DIR...] [--probe PROBE_DIR...]`.

Two kinds of N=1 run go in:
  * RUN_DIR: the seeded single-session runs (baseline.sh). Their in-window ok calls give
    "baseline_p95_ms" and "calls" -- evidence and a pace sanity check, NOT used for medians.
  * PROBE_DIR (after --probe): the per-class probe runs (classprobe.sh, one class alone on an idle
    worker, 20 calls). Their in-window ok calls give "class_medians" (per-class median added
    latency; a class with < 5 ok probe calls is omitted and listed in "undercovered"),
    "global_median_ms" (median over all probe calls) and "excess_p95_ms" (B: the p95 over the probe
    calls of added latency minus the call's own class median -- the within-class spread).
Also written: "class_counts" (ok probe calls per class), "probe_failed" ({class: failed calls}),
"probe_runs", "runs", the three hashes (from the RUN_DIRs' record.json, which must agree: rung.sh
refuses a baseline whose library or driver differs from the rung's own), and "evaluable" /
"skipped" (seed lists from baseline.sh via E15_BASELINE_SEEDS / E15_BASELINE_SKIPPED).
Added latency is holds.py's added_ms; percentiles are nearest-rank.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import holds as H  # noqa: E402
from record import read_jsonl  # noqa: E402


HASHES = ("library_sha256", "driver_bin_sha256", "corpus_sha256")


def run_hashes(dirs):
    """The HASHES shared by every run's record.json; sys.exit when one is unreadable or they differ."""
    seen = None
    for d in dirs:
        p = os.path.join(d, "record.json")
        try:
            with open(p) as f:
                rec = json.load(f)
        except (OSError, ValueError) as e:
            sys.exit("baseline.py: cannot read %s: %s" % (p, e))
        h = {k: rec.get(k) for k in HASHES}
        if seen is None:
            seen = (d, h)
        elif h != seen[1]:
            diff = [k for k in HASHES if h[k] != seen[1][k]]
            sys.exit("baseline.py: %s and %s differ in %s: not one baseline" % (seen[0], d, ", ".join(diff)))
    return seen[1]


def pool(dirs, probe_dirs=()):
    pooled, runs = [], []
    for d in dirs:
        added = H.window_added_ms(read_jsonl(os.path.join(d, "calls.jsonl")))
        runs.append({"dir": d, "calls": len(added), "p95_added_ms": H.percentile(added, 95)})
        pooled.extend(added)
    probe_calls, failed, probe_runs = [], {}, []
    for d in probe_dirs:
        cs = [c for c in read_jsonl(os.path.join(d, "calls.jsonl")) if c.get("in_window")]
        ok = H.window_ok_calls(cs)
        probe_runs.append({"dir": d, "ok": len(ok), "calls": len(cs)})
        probe_calls.extend(ok)
        for c in cs:
            if c.get("status") == "err" and H.counts_as_failure(c):
                failed[str(c.get("class"))] = failed.get(str(c.get("class")), 0) + 1
    medians, gmed = H.class_medians(probe_calls)
    exc, _ = H.excess_ms(probe_calls, medians, gmed)
    counts = {}
    for c in probe_calls:
        counts[str(c.get("class"))] = counts.get(str(c.get("class")), 0) + 1
    classes = {str(c.get("class")) for d in probe_dirs
               for c in read_jsonl(os.path.join(d, "calls.jsonl"))} | set(counts)
    return {"baseline_p95_ms": H.percentile(pooled, 95), "calls": len(pooled), "runs": runs,
            "probe_runs": probe_runs, "class_medians": medians, "global_median_ms": gmed,
            "excess_p95_ms": H.percentile(exc, 95), "class_counts": counts,
            "probe_failed": failed,
            "undercovered": sorted(k for k in classes if counts.get(k, 0) < H.MIN_CLASS_CALLS)}


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if "--probe" in argv:
        i = argv.index("--probe")
        argv, probes = argv[:i], argv[i + 1:]
    else:
        probes = []
    if len(argv) < 2:
        sys.exit("usage: baseline.py OUT_JSON RUN_DIR [RUN_DIR...] [--probe PROBE_DIR...]")
    out, dirs = argv[0], argv[1:]
    for d in dirs + probes:
        if not os.path.isfile(os.path.join(d, "calls.jsonl")):
            sys.exit("baseline.py: no %s" % os.path.join(d, "calls.jsonl"))
    hashes = run_hashes(dirs)
    b = pool(dirs, probes)
    b.update(hashes)
    # baseline.sh passes which seeds were pooled and which were skipped as not evaluable
    seeds = os.environ.get("E15_BASELINE_SEEDS", "").split()
    b["evaluable"] = [{"seed": int(s), "dir": d} for s, d in zip(seeds, dirs)] if len(seeds) == len(dirs) \
        else [{"seed": None, "dir": d} for d in dirs]
    b["skipped"] = []
    for item in os.environ.get("E15_BASELINE_SKIPPED", "").split():
        seed, tag, reason = item.split(":", 2)
        b["skipped"].append({"seed": int(seed), "tag": tag, "reason": reason})
    if not b["calls"]:
        sys.exit("baseline.py: no in-window ok calls in %s" % " ".join(dirs))
    if probes and b["excess_p95_ms"] is None:
        sys.exit("baseline.py: no in-window ok probe calls in %s" % " ".join(probes))
    with open(out, "w") as f:
        json.dump(b, f, indent=2, sort_keys=True)
    print(b["baseline_p95_ms"])


if __name__ == "__main__":
    main()
