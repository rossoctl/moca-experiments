"""N=1 baseline pooling (SPEC §8 condition 4): `python3 baseline.py OUT_JSON RUN_DIR [RUN_DIR...]`.

Pools the in-window ok calls of the given N=1 rung directories (each with calls.jsonl) and writes
{"baseline_p95_ms", "calls", "runs": [{"dir", "calls", "p95_added_ms"}], "library_sha256",
"driver_bin_sha256", "corpus_sha256"} to OUT_JSON. The three hashes come from each run's
record.json and must agree across the runs (else it dies, writing nothing): rung.sh refuses a
baseline whose library or driver differs from the rung's own. Added latency
is holds.py's (window_added_ms); the p95 is its nearest-rank percentile over the pooled calls, so
several short N=1 runs give one baseline less noisy than any one of them.
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


def pool(dirs):
    pooled, runs = [], []
    for d in dirs:
        added = H.window_added_ms(read_jsonl(os.path.join(d, "calls.jsonl")))
        runs.append({"dir": d, "calls": len(added), "p95_added_ms": H.percentile(added, 95)})
        pooled.extend(added)
    return {"baseline_p95_ms": H.percentile(pooled, 95), "calls": len(pooled), "runs": runs}


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) < 2:
        sys.exit("usage: baseline.py OUT_JSON RUN_DIR [RUN_DIR...]")
    out, dirs = argv[0], argv[1:]
    for d in dirs:
        if not os.path.isfile(os.path.join(d, "calls.jsonl")):
            sys.exit("baseline.py: no %s" % os.path.join(d, "calls.jsonl"))
    hashes = run_hashes(dirs)
    b = pool(dirs)
    b.update(hashes)
    if not b["calls"]:
        sys.exit("baseline.py: no in-window ok calls in %s" % " ".join(dirs))
    with open(out, "w") as f:
        json.dump(b, f, indent=2, sort_keys=True)
    print(b["baseline_p95_ms"])


if __name__ == "__main__":
    main()
