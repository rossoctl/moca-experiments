#!/usr/bin/env python3
"""E16 supplementary re-judge (user decision 2026-11-09; not voted): a rung judged without the calls
whose failure coincides with the worker's "egress wedged" relay reconnect.

  python3 experiments/e16-low-duty/analysis/nowedge.py [--baseline N1/baseline.json] RUNG_DIR...   -> writes RUNG_DIR/record_nowedge.json (never record.json)

Excluded: in-window calls with status err, cause exit_mismatch, exit -1, still in flight at a
`microvm-worker: stream ended (egress wedged...` line of worker.log: send <= T + 2 s and send +
observed >= T - 2 s (T = the line's timestamp, 1 s resolution; calls.jsonl `ts` is the send time).
Everything else is record.py unchanged: the rung's files are linked into a temporary directory, with
calls.jsonl rewritten without the excluded calls, and experiments/e15-session-density/analysis/record.py builds the record from
it with the rung's own params.json. The record carries `nowedge` (the rule, the wedge timestamps,
the excluded calls). A rung with no wedge line gets no file (prints "no wedge").
Reads plain or .gz files.
"""
import calendar
import datetime
import gzip
import json
import os
import re
import shutil
import sys
import tempfile
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "e15", "analysis"))
import record as R  # noqa: E402

WEDGE_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})Z microvm-worker: stream ended \(egress wedged")
TOL_S = 2.0
FILES = ("calls.jsonl", "sessions.jsonl", "samples.jsonl", "driver-cpu.jsonl", "worker.log")


def _open(d, name):
    p = os.path.join(d, name)
    if os.path.exists(p):
        return open(p)
    if os.path.exists(p + ".gz"):
        return gzip.open(p + ".gz", "rt")
    return None


def _send_epoch(c):
    return datetime.datetime.fromisoformat(c["ts"].replace("Z", "+00:00")[:26] + "+00:00").timestamp() \
        if "." in c["ts"] else calendar.timegm(time.strptime(c["ts"], "%Y-%m-%dT%H:%M:%SZ"))


def wedges(d):
    f = _open(d, "worker.log")
    if f is None:
        raise SystemExit("nowedge.py: no worker.log[.gz] in %s" % d)
    with f:
        return [float(calendar.timegm(time.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S")))
                for m in (WEDGE_RE.match(l) for l in f) if m]


def excluded(c, ws):
    if not (c.get("in_window") and c.get("status") == "err" and c.get("cause") == "exit_mismatch"
            and c.get("exit") == -1):
        return False
    s = _send_epoch(c)
    e = s + c.get("observed_ms", 0) / 1000.0
    return any(s <= w + TOL_S and e >= w - TOL_S for w in ws)


def main(d):
    ws = wedges(d)
    if not ws:
        print("no wedge")
        return None
    tmp = tempfile.mkdtemp(prefix="nowedge-")
    try:
        drop = []
        with _open(d, "calls.jsonl") as f, open(os.path.join(tmp, "calls.jsonl"), "w") as out:
            for line in f:
                if not line.strip():
                    continue
                c = json.loads(line)
                if excluded(c, ws):
                    drop.append({k: c.get(k) for k in ("session", "call", "class", "ts", "observed_ms", "planned_dur_ms", "cause", "exit")})
                    continue
                out.write(line if line.endswith("\n") else line + "\n")
        for name in FILES[1:]:
            f = _open(d, name)
            if f is None:
                continue
            with f, open(os.path.join(tmp, name), "w") as out:
                shutil.copyfileobj(f, out)
        params = json.load(open(os.path.join(d, "params.json")))
        if BASELINE:  # off the host: the pulled copy of the rung's N=1 baseline
            params["baseline_path"] = BASELINE
        rec = R.build(tmp, params)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    rec["nowedge"] = {"supplementary": True, "voted": False,
                      "rule": "excluded: in-window calls, cause exit_mismatch, exit -1, in flight at a worker "
                              "'stream ended (egress wedged...)' line +-%g s" % TOL_S,
                      "wedge_ts": ws, "excluded_calls": len(drop), "excluded": drop}
    out = os.path.join(d, "record_nowedge.json")
    with open(out, "w") as f:
        json.dump(rec, f, indent=2, sort_keys=True)
    print("%s holds=%s holds_abs=%s excluded=%d failed_calls=%s" % (out, rec["holds"], rec["holds_abs"], len(drop), rec["failed_calls"]))
    return rec


BASELINE = None

if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["--baseline"]:
        BASELINE, args = args[1], args[2:]
    for a in args:
        main(a)
