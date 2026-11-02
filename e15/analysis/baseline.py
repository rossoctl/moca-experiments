"""N=1 baseline pooling (SPEC §8 condition 4): `python3 baseline.py OUT_JSON RUN_DIR [RUN_DIR...]`.

Pools the in-window ok calls of the given N=1 rung directories (each with calls.jsonl) and writes
{"baseline_p95_ms", "calls", "runs": [{"dir", "calls", "p95_added_ms"}]} to OUT_JSON. Added latency
is holds.py's (window_added_ms); the p95 is its nearest-rank percentile over the pooled calls, so
several short N=1 runs give one baseline less noisy than any one of them.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import holds as H  # noqa: E402
from record import read_jsonl  # noqa: E402


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
    b = pool(dirs)
    if not b["calls"]:
        sys.exit("baseline.py: no in-window ok calls in %s" % " ".join(dirs))
    with open(out, "w") as f:
        json.dump(b, f, indent=2, sort_keys=True)
    print(b["baseline_p95_ms"])


if __name__ == "__main__":
    main()
