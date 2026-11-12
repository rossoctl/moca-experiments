"""Relative slowdown per rung (supplementary, not sealed): for calls of the measured window with a planned
run time >= 1 s (planned_dur_ms - tail_ms), observed / planned; median and nearest-rank p95, beside the
rung's p95 excess (record.json) and its 1 s / CPU-wall re-judges when present.

  python3 slowdown.py RUNG_DIR [RUNG_DIR ...]   -> one markdown table row per rung (stdout)
"""
import json
import math
import os
import sys


def q(v, p):
    v = sorted(v)
    return v[max(0, int(math.ceil(p / 100.0 * len(v))) - 1)] if v else None


def row(d):
    r = json.load(open(os.path.join(d, "record.json")))
    rat = []
    for line in open(os.path.join(d, "calls.jsonl")):
        c = json.loads(line)
        if not c.get("in_window") or c.get("status") != "ok":
            continue
        planned = c["planned_dur_ms"] - c.get("tail_ms", 0)
        if planned >= 1000:
            rat.append(c["observed_ms"] / planned)
    extra = []
    for name in ("record_1s.json", "record_cpu.json"):
        p = os.path.join(d, name)
        extra.append(str(json.load(open(p))["holds"]).lower() if os.path.exists(p) else "")
    f = lambda x: "" if x is None else "%.3f" % x  # noqa: E731
    pe = r.get("p95_excess_ms")
    return "| %s | %d | %s | %s | %d | %s | %s | %s / %s | %s | %s |" % (
        r["n"], r["window_calls"], "" if pe is None else "%.0f" % pe, "" if r.get("excess_limit_ms") is None else "%.0f" % r["excess_limit_ms"],
        len(rat), f(q(rat, 50)), f(q(rat, 95)), str(r["holds"]).lower(), str(r["holds_abs"]).lower(), extra[0], extra[1])


if __name__ == "__main__":
    print("| N | window calls | p95 excess (ms) | primary limit (ms) | calls ≥ 1 s | slowdown median | slowdown p95 | sealed holds / abs | holds_1s | holds_cpu |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for d in sys.argv[1:]:
        print(row(d))
