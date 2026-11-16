#!/usr/bin/env python3
"""E17b squeeze ladder stop rule (PLAN-E17B Task 9): does the rung's measurement window see lease reclaim at
least once a minute, every minute?

  python3 experiments/e17-lease/analysis/squeeze_rule.py RUNG_DIR -> RUNG_DIR/squeeze-rule.json, one summary line

Inputs (RUNG_DIR): params.json (warmup_s, window_s) and samples.jsonl (rung.sh; sample.sh's 1 Hz rows, `t` on
the driver's t0). The worker's /stats JSON is each row's `worker` field; `worker.leaseEnds.memory_reclaim` is
the cumulative count of leases the worker ended by memory reclaim (moca remote-worker/internal/vmpool/stats.go).

The window is [warmup_s, warmup_s + window_s), cut into whole minutes from its start; a trailing part shorter
than a minute is not judged. A minute [a, b] counts C(last) - C(first) reclaims: first is the first row with worker
stats at t >= a, last the last one at t <= b. The bound is conservative (no tolerance): a reclaim between a and the
first row is not counted in that minute. A row with worker stats but no leaseEnds (sbx) counts 0.

  met = true    every judged minute has >= 1 reclaim: the ladder stops at this N and records it
  met = false   at least one minute had none (`why` names the first)
  met = null    undecidable, never guessed: a minute with no worker stats inside it, the counter went down (the
                worker restarted), or a window shorter than a minute. ladder.sh treats it as a rig error.

Exit 0 when squeeze-rule.json was written (whatever met says); 1 when the inputs are missing or unreadable.
"""
import json
import os
import sys

RULE = ("climb until /stats leaseEnds.memory_reclaim rises by >= 1 in every whole minute of the measurement "
        "window [warmup_s, warmup_s + window_s); a trailing part under a minute is not judged")
REASON = "memory_reclaim"
MINUTE = 60


def num(x):
    return int(x) if float(x).is_integer() else x


def read_samples(path):
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except ValueError:
                continue
    return rows


def stats_points(rows):
    """[(t, count)] for the rows with worker stats, in t order."""
    pts = []
    for r in rows:
        w = r.get("worker")
        t = r.get("t")
        if not isinstance(w, dict) or not isinstance(t, (int, float)):
            continue
        ends = w.get("leaseEnds")
        pts.append((float(t), int((ends if isinstance(ends, dict) else {}).get(REASON, 0))))
    pts.sort(key=lambda p: p[0])
    return pts


def minute_count(pts, a, b):
    """C(last) - C(first) over the stats rows with a <= t <= b, or None when no stats row lies in the minute."""
    inside = [c for t, c in pts if a <= t <= b]
    if not inside:
        return None
    return inside[-1] - inside[0]


def judge(params, rows):
    w0 = float(params["warmup_s"])
    win = float(params["window_s"])
    out = {"rule": RULE, "reason": REASON, "bound": "first row at or after the minute's start, last at or before its end",
           "window": [num(w0), num(w0 + win)], "bins": [],
           "min_per_minute": None, "met": None, "why": None}
    k = int(win // MINUTE)
    if k < 1:
        out["why"] = "window of %g s is shorter than a minute" % win
        return out
    pts = stats_points(rows)
    for i in range(1, len(pts)):
        if pts[i][1] < pts[i - 1][1]:
            out["why"] = "%s counter went down at t=%g (%d -> %d): the worker restarted" % (
                REASON, pts[i][0], pts[i - 1][1], pts[i][1])
            return out
    bounds = [w0 + MINUTE * i for i in range(k + 1)]
    rows_out = []
    for i in range(k):
        n = minute_count(pts, bounds[i], bounds[i + 1])
        if n is None:
            out["why"] = "no worker stats inside minute [%s, %s)" % (num(bounds[i]), num(bounds[i + 1]))
            return out
        rows_out.append((i, n))
    first_bad = None
    for i, n in rows_out:
        row = {"start": num(bounds[i]), "end": num(bounds[i + 1]), REASON: n}
        out["bins"].append(row)
        if n < 1 and first_bad is None:
            first_bad = row
    out["min_per_minute"] = min(b[REASON] for b in out["bins"])
    out["met"] = first_bad is None
    if first_bad is not None:
        out["why"] = "minute [%s, %s) had 0 %s lease ends" % (first_bad["start"], first_bad["end"], REASON)
    return out


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1:
        sys.stderr.write("usage: squeeze_rule.py RUNG_DIR\n")
        return 2
    d = argv[0]
    try:
        params = json.load(open(os.path.join(d, "params.json")))
        rows = read_samples(os.path.join(d, "samples.jsonl"))
        float(params["warmup_s"]) + float(params["window_s"])  # both present and numbers
    except (OSError, ValueError, KeyError, TypeError) as e:
        sys.stderr.write("squeeze_rule.py: %s: %s\n" % (d, e))
        return 1
    r = judge(params, rows)
    with open(os.path.join(d, "squeeze-rule.json"), "w") as f:
        json.dump(r, f, indent=2, sort_keys=True)
    print("met %s; min %s per minute over %d minute(s)%s" % (
        json.dumps(r["met"]), r["min_per_minute"], len(r["bins"]), "; " + r["why"] if r["why"] else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
