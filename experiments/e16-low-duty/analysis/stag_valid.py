#!/usr/bin/env python3
"""E16 supplementary stag rungs: validity checks (user decision 2026-11-09), written as
RUNG_DIR/stag_valid.json beside record.json (record.json untouched).

  python3 experiments/e16-low-duty/analysis/stag_valid.py [--no-end-sessions] RUNG_DIR   -> prints "valid" or "invalid <reasons>"
  (exit 0 either way; the verdict is in stag_valid.json). --no-end-sessions (SBX: the arm sends no
  end-session Execs) skips check (c).

(a) worker.log has zero "stream ended (egress wedged" lines;
(b) no "vmpool: exec ... err=vmpool: aborted" line stamped before the driver's graceEnd
    (t0 + warm-up + window + grace; worker.log has 1 s resolution, so a line in the second that
    contains graceEnd counts as after it);
(c) the driver-cpu.jsonl footer has end_sessions_sent == end_sessions_ok.
"""
import calendar
import gzip
import json
import os
import re
import sys
import time

AB_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})Z vmpool: exec .* err=vmpool: aborted")
WEDGE = "microvm-worker: stream ended (egress wedged"


def _open(d, name):
    p = os.path.join(d, name)
    if os.path.exists(p):
        return open(p, errors="replace")
    return gzip.open(p + ".gz", "rt", errors="replace")


def check(d, end_sessions=True):
    p = json.load(open(os.path.join(d, "params.json")))
    r = json.load(open(os.path.join(d, "record.json")))
    t0 = r["rung_start_ts"]
    grace_end = t0 + p["warmup_s"] + p["window_s"] + p["grace_s"]
    wedges, early = 0, []
    with _open(d, "worker.log") as f:
        for line in f:
            if WEDGE in line:
                wedges += 1
            m = AB_RE.match(line)
            if m:
                ts = calendar.timegm(time.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S"))
                if ts + 1 <= grace_end:
                    early.append(m.group(1))
    foot = {}
    with _open(d, "driver-cpu.jsonl") as f:
        for line in f:
            if '"footer"' in line:
                foot = json.loads(line)
    sent, ok = foot.get("end_sessions_sent"), foot.get("end_sessions_ok")
    reasons = []
    if wedges:
        reasons.append("egress_wedged=%d" % wedges)
    if early:
        reasons.append("aborted_before_grace_end=%d" % len(early))
    if end_sessions and (sent is None or sent != ok):
        reasons.append("end_sessions_sent=%s_ok=%s" % (sent, ok))
    out = {"supplementary": True, "valid": not reasons, "reasons": reasons,
           "checks": {"a_egress_wedged_lines": wedges, "b_aborted_before_grace_end": len(early),
                      "b_first_early_abort": early[0] if early else None,
                      "c_applies": end_sessions, "c_end_sessions_sent": sent, "c_end_sessions_ok": ok,
                      "c_end_sessions_deferred": foot.get("end_sessions_deferred")},
           "grace_end_epoch": grace_end,
           "rule": "user decision 2026-11-09: (a) no egress-wedged line; (b) no aborted Exec before "
                   "graceEnd; (c) end_sessions_sent == end_sessions_ok"}
    with open(os.path.join(d, "stag_valid.json"), "w") as f:
        json.dump(out, f, indent=2)
    return out


if __name__ == "__main__":
    a = sys.argv[1:]
    es = "--no-end-sessions" not in a
    a = [x for x in a if x != "--no-end-sessions"]
    o = check(a[0], es)
    print("valid" if o["valid"] else "invalid " + ",".join(o["reasons"]))
