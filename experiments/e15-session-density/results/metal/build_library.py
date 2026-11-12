"""Build the metal-measured command library (SPEC §10.1 step 2).

  python3 build_library.py BASE_LIBRARY RAW_JSONL OUT_LIBRARY

BASE_LIBRARY is the committed library.json (AWS-measured, 7c2bdc4b): its invocations, expected exits,
nominal times and stand-in block are kept unchanged. run_ms/cpu_ms are replaced by the metal medians
of the 5 in-guest reps in RAW_JSONL (measure_library.sh output), as integers, minimum 1 -- the same
rule Task 8 used on AWS. Refuses (exit 1) on any transport error, any exit-code mismatch, or any
invocation without exactly 5 reps. Prints a per-class comparison with the AWS values on stderr.
"""
import json
import statistics as st
import sys
from collections import defaultdict


def main(base_p, raw_p, out_p):
    base = json.load(open(base_p))
    reps = defaultdict(list)
    bad = []
    for line in open(raw_p):
        r = json.loads(line)
        if "bad" in r or r.get("transport_error") or "run_ms" not in r:
            bad.append(r)
            continue
        if r["exit"] != r["expected_exit"]:
            bad.append(r)
            continue
        reps[(r["class"], r["id"])].append(r)
    if bad:
        sys.exit("build_library: %d bad rows, first: %s" % (len(bad), json.dumps(bad[0])[:300]))
    out = json.loads(json.dumps(base))
    for cls, invs in out["classes"].items():
        aws_run = sum(i["run_ms"] for i in invs)
        for inv in invs:
            rs = reps.get((cls, inv["id"]), [])
            if len(rs) != 5:
                sys.exit("build_library: %s/%s has %d reps, want 5" % (cls, inv["id"], len(rs)))
            inv["run_ms"] = max(1, int(round(st.median(x["run_ms"] for x in rs))))
            inv["cpu_ms"] = max(1, int(round(st.median(x["cpu_ms"] for x in rs))))
        met_run = sum(i["run_ms"] for i in invs)
        cpu = sum(i["cpu_ms"] for i in invs)
        sys.stderr.write("%-12s n=%d distinct=%d run %s..%s  sum metal/aws=%.2f cpu/run=%.0f%%\n" % (
            cls, len(invs), len({i["run_ms"] for i in invs}), min(i["run_ms"] for i in invs),
            max(i["run_ms"] for i in invs), met_run / float(aws_run), 100.0 * cpu / met_run))
    with open(out_p, "w") as f:
        json.dump(out, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main(*sys.argv[1:4])
