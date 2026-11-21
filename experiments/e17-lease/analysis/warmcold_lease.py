#!/usr/bin/env python3
"""E17b warm/cold join on the SHIPPED lease worker's log (PLAN-E17B Task 6).

  python3 experiments/e17-lease/analysis/warmcold_lease.py RUNG_DIR -> RUNG_DIR/warmcold.jsonl, RUNG_DIR/warmcold-report.json

warmcold.py (E17a) cannot read the shipped worker: its exec line carries `kind=` and it has no
`e15 resident` lines. Lines read (moca remote-worker/internal/vmpool/runner.go, lease.go, lease_event.go):
  vmpool: exec req=<n> workspace_key="<k>" kind=<kind> vm=<vm> cold="<c>" exit=<n> err=<...>
  vmpool: lease start workspace_key="<k>" vm=<vm> mode=<mode>
  vmpool: lease end workspace_key="<k>" vm=<vm> mode=<mode> reason=<r> age=<d>[ processes=[...]]
(the `worker_restart` end has the same form). Everything else is ignored.

Per key, in log order (never re-ordered by timestamp):
  - a call is WARM when its first Exec ran on the same vm as the previous call's last Exec and no
    `lease end` for the key lies between the two exec lines, and it ran in a live lease (a `lease
    start` with no later end for the key). A start is logged before its Exec's own exec line.
  - COLD otherwise: first (the key's first call), the reason of the last end between (idle,
    memory_reclaim, ...), or vm-changed.
  - UNKNOWN, never guessed: an ok call with no live lease at its exec line or no vm, or the key's
    exec-line count differs from its calls' (exec-count), or a timestamp guard failure
    (warmcold.timestamp_mismatch).
  - FAILED_NO_VM (E17B-R35): a call whose status is not ok and that ran in no VM: a refusal (the worker
    logs its exec line with an empty vm=, runner.go:74; reason no-vm) or a call that left no exec line
    (queue-full, not started; reason not-started). It is not a warm/cold reading and not unknown: the
    chain gate stops on unknown, and these are judged by lease_ends' criterion-3 refusal check.
    They are counted by cause (failed_no_vm_by_cause: the driver's `refused` class, "other" when it recorded
    none). A CONFIGURATION refusal (E17B-R42: stale-mode, lease-unsupported, permission-denied, req-id-in-flight)
    in any row is counted apart (config_refusals): the rung's mode, lease support or token binding is wrong, and
    the chain gate stops on it. Load refusals (memory-budget, host-memory, max-runs, queue-full, relay-busy) are
    outcomes.
The driver's own events (calls.jsonl `lease_events`) are a SECOND source (E17B-R9): a call with any
event is cold, one with none is warm. A disagreement with the log is counted and listed, never
resolved: the log's verdict stands, and `countable` is false unless there are none.
Calls tagged `first_lease` (they include the first-lease ownership walk, Review Focus 6) are
reported separately and kept out of the warm/cold counts. So are reported-only calls (py_shmem, the
guest's Shmem reading, PLAN-E17B Task 10): they are joined like any call (their Execs are in the
log, so the alignment needs them, and they enter the disagreement check), but counted only under
`reported_only`, never in warm/cold/unknown. A `set_mode_failed` row is reported as
such, never classified, and makes `valid` false.

E17c (SPEC §13.3 criterion 2, ruling R-g): the warm split by the guest's page-cache drop. The threshold is the
rung's params.json `lease_cache_drop` (the moca worker banner's value, recorded by rung.sh under E17C=1 for
ship-* arms): a Go duration (`30s`, `1m0s`, `2m30s`, `1h0m0s`; h/m/s components). A warm row gets `cache`:
`after_drop` when the session's previous call (calls.jsonl, any class) ended strictly more than the threshold
before this call was sent, `kept` otherwise; a session's first call is never after_drop. The summary gains
`cache_drop_s` and `warm_by_cache` (gated warm rows by tag). `off`, an unparseable value or no field (sbx,
ship-300-nd, every E17b rung): nothing is tagged and both outputs are byte-identical to E17b's.
"""
import calendar
import json
import os
import re
import sys
import time

import warmcold as W

REPORTED_ONLY = ("py_shmem",)  # latency_report.REPORTED_ONLY: never in a latency gate or median

EXEC_RE = re.compile(r'vmpool: exec req=(?P<req>\d+) workspace_key="(?P<key>(?:[^"\\]|\\.)*)" '
                     r'kind=(?P<kind>\S*) vm=(?P<vm>\S*) cold="(?P<cold>(?:[^"\\]|\\.)*)" '
                     r'exit=(?P<exit>-?\d+) err=(?P<err>.*)$')
START_RE = re.compile(r'vmpool: lease start workspace_key="(?P<key>(?:[^"\\]|\\.)*)" vm=(?P<vm>\S*) mode=(?P<mode>\S+)')
END_RE = re.compile(r'vmpool: lease end workspace_key="(?P<key>(?:[^"\\]|\\.)*)" vm=(?P<vm>\S*) '
                    r'mode=(?P<mode>\S+) reason=(?P<reason>\S+)')
SET_MODE_FAILED = "set_mode_failed"
FAILED_NO_VM = "failed_no_vm"
# E17B-R54: a call the driver cut at its end-of-run grace deadline (cause cut_at_end) whose Exec line follows its
# lease's end: the cut aborted the Exec and the abort ended the lease (agent_dead). Not a warm/cold reading and not
# unknown: counted apart, like failed_no_vm.
CUT_AT_END = "cut_at_end"
# driver exec.go configRefusal (E17B-R42)
CONFIG_REFUSALS = ("stale-mode", "lease-unsupported", "permission-denied", "req-id-in-flight")
# E17c (ruling R-g): a Go duration as the worker banner prints it, h/m/s components only.
GO_DURATION_RE = re.compile(r"^(?:(?P<h>\d+)h)?(?:(?P<m>\d+)m)?(?:(?P<s>\d+(?:\.\d+)?)s)?$")
AFTER_DROP, KEPT = "after_drop", "kept"


def cache_drop_seconds(text):
    """params.json `lease_cache_drop` -> seconds, or None (off, missing, unparseable, or not above zero)."""
    m = GO_DURATION_RE.match(text) if isinstance(text, str) and text else None
    if not m or not any(m.groupdict().values()):
        return None
    secs = 3600 * int(m.group("h") or 0) + 60 * int(m.group("m") or 0) + float(m.group("s") or 0)
    return secs if secs > 0 else None


def read_cache_drop(d):
    p = os.path.join(d, "params.json")
    if not os.path.exists(p):
        return None
    with open(p) as f:
        return cache_drop_seconds(json.load(f).get("lease_cache_drop"))


def tag_cache(rows, calls, threshold):
    """Tags each warm row after_drop or kept by the gap since its session's previous call ended. A session's
    first call has no gap (kept). A gap that cannot be timed (either call's ts unparseable; the timestamp guard
    already rules this out for any call with an exec line) is never guessed: the row stays untagged."""
    prev_end, gap = {}, {}
    for c in sorted(calls, key=lambda c: (str(c.get("session")), c.get("call"))):
        start = W.call_epoch(c.get("ts"))
        k = c.get("session")
        if k not in prev_end:
            gap[(k, c.get("call"))] = 0.0
        elif start is not None and prev_end[k] is not None:
            gap[(k, c.get("call"))] = start - prev_end[k]
        prev_end[k] = None if start is None else start + float(c.get("observed_ms") or 0) / 1000.0
    for r in rows:
        g = gap.get((r["session"], r["call"]))
        if r["warm"] is True and g is not None:
            r["cache"] = AFTER_DROP if g > threshold else KEPT


def read_events(d):
    """Per key, its exec / start / end events in log order."""
    events = {}
    with W.open_rung_file(d, "worker.log") as f:
        for line in f:
            m = EXEC_RE.search(line)
            if m:
                if m.group("key") == W.PROBE_KEY:
                    continue
                t = W.LOG_TS_RE.match(line)
                events.setdefault(m.group("key"), []).append(
                    {"kind": "exec", "req": int(m.group("req")), "vm": m.group("vm"),
                     "err": m.group("err").strip(),
                     "ts": calendar.timegm(time.strptime(t.group(1), "%Y-%m-%dT%H:%M:%S")) if t else None})
                continue
            m = START_RE.search(line)
            if m:
                events.setdefault(m.group("key"), []).append({"kind": "start", "vm": m.group("vm")})
                continue
            m = END_RE.search(line)
            if m:
                events.setdefault(m.group("key"), []).append(
                    {"kind": "end", "vm": m.group("vm"), "reason": m.group("reason")})
    return events


def exec_sequence(evs):
    """The key's Execs in log order, each with `ends` (end reasons since the previous Exec's line)
    and `live` (a start with no later end, as of its exec line)."""
    seq, ends, live = [], [], False
    for ev in evs:
        if ev["kind"] == "start":
            live = True
        elif ev["kind"] == "end":
            live = False
            ends.append(ev["reason"])
        else:
            seq.append(dict(ev, ends=ends, live=live))
            ends = []
    return seq


def driver_verdict(c):
    return "cold" if c.get("lease_events") else "warm"


def row(c, warm, vm, prev_vm, reason, in_lease=None):
    return {"session": c.get("session"), "call": c.get("call"), "class": c.get("class"),
            "observed_ms": c.get("observed_ms"), "status": c.get("status"),
            "in_window": bool(c.get("in_window")), "warm": warm, "vm": vm, "prev_vm": prev_vm,
            "cold_reason": reason, "in_lease": in_lease, "first_lease": bool(c.get("first_lease")),
            "driver": driver_verdict(c), "refused": c.get("refused") or None}


def tag_key(calls, seq):
    """Rows for one key's calls (call order). set_mode_failed calls ran no Exec and are set aside."""
    rows = [row(c, SET_MODE_FAILED, None, None, SET_MODE_FAILED) for c in calls if c.get("cause") == SET_MODE_FAILED]
    calls = [c for c in calls if c.get("cause") != SET_MODE_FAILED]
    want = sum(W.call_execs(c) for c in calls)
    if want != len(seq):
        rows += [row(c, "unknown", None, None, "exec-count") for c in calls]
        return rows, "calls want %d exec lines, the log has %d" % (want, len(seq))
    why = W.timestamp_mismatch(calls, seq)
    if why:
        rows += [row(c, "unknown", None, None, "timestamp_mismatch") for c in calls]
        return rows, "timestamp_mismatch: " + why
    i, prev_vm, between = 0, None, []
    for c in calls:
        n = W.call_execs(c)
        mine = seq[i:i + n]
        i += n
        failed = c.get("status") != "ok"
        if not mine:
            rows.append(row(c, FAILED_NO_VM if failed else "unknown", None, prev_vm, "not-started"))
            continue
        between = between + mine[0]["ends"]
        vm, live = mine[0]["vm"], mine[0]["live"]
        if not vm:
            rows.append(row(c, FAILED_NO_VM if failed else "unknown", None, prev_vm, "no-vm", live))
        elif not live and c.get("cause") == CUT_AT_END:
            rows.append(row(c, CUT_AT_END, vm, prev_vm, "cut-at-end", False))
        elif not live:
            rows.append(row(c, "unknown", vm, prev_vm, "no-live-lease", False))
        elif prev_vm is None:
            rows.append(row(c, False, vm, None, "first", True))
        elif between:
            rows.append(row(c, False, vm, prev_vm, between[-1], True))
        elif vm != prev_vm:
            rows.append(row(c, False, vm, prev_vm, "vm-changed", True))
        else:
            rows.append(row(c, True, vm, prev_vm, None, True))
        # Ends before a call's later Execs lie before its LAST Exec, not between it and the next call;
        # ends after the last Exec are carried by the next call's first Exec. With no vm to compare
        # against (no-vm), the ends before it carry over.
        between = between if not vm else []
        last_vm = next((e["vm"] for e in reversed(mine) if e["vm"]), None)
        if last_vm:
            prev_vm = last_vm
    return rows, None


def join(rung_dir):
    """Returns (rows sorted by session then call, summary)."""
    calls = W.read_calls(rung_dir)
    events = read_events(rung_dir)
    by_key = {}
    for c in calls:
        by_key.setdefault(c.get("session"), []).append(c)
    rows, unknown_keys = [], {}
    for key in sorted(by_key):
        kc = sorted(by_key[key], key=lambda c: c.get("call"))
        kr, why = tag_key(kc, exec_sequence(events.get(key, [])))
        rows.extend(sorted(kr, key=lambda r: r["call"]))
        if why:
            unknown_keys[key] = why
    gated = [r for r in rows if not r["first_lease"] and r["warm"] != SET_MODE_FAILED
             and r["class"] not in REPORTED_ONLY]
    dis = [{"session": r["session"], "call": r["call"],
            "log": "warm" if r["warm"] is True else "cold", "driver": r["driver"]}
           for r in rows if r["warm"] in (True, False) and r["driver"] != ("warm" if r["warm"] else "cold")]
    n_smf = sum(r["warm"] == SET_MODE_FAILED for r in rows)
    summary = {
        "calls": len(rows),
        "warm": sum(r["warm"] is True for r in gated),
        "cold": sum(r["warm"] is False for r in gated),
        "unknown": sum(r["warm"] == "unknown" for r in gated),
        "first_lease": sum(r["first_lease"] for r in rows if r["warm"] != SET_MODE_FAILED),
        "set_mode_failed": n_smf,
        "reported_only": W.count_by(r["class"] for r in rows if r["class"] in REPORTED_ONLY
                                    and r["warm"] != SET_MODE_FAILED),
        "unknown_by_reason": W.count_by(r["cold_reason"] for r in gated if r["warm"] == "unknown"),
        "failed_no_vm": sum(r["warm"] == FAILED_NO_VM for r in gated),
        "cut_at_end": sum(r["warm"] == CUT_AT_END for r in gated),
        "failed_no_vm_by_reason": W.count_by(r["cold_reason"] for r in gated if r["warm"] == FAILED_NO_VM),
        "failed_no_vm_by_cause": W.count_by(r["refused"] or "other" for r in gated if r["warm"] == FAILED_NO_VM),
        "config_refusals": sum(r["refused"] in CONFIG_REFUSALS for r in rows),
        "config_refusals_by_cause": W.count_by(r["refused"] for r in rows if r["refused"] in CONFIG_REFUSALS),
        "cold_by_reason": W.count_by(r["cold_reason"] for r in gated if r["warm"] is False),
        "unknown_keys": unknown_keys,
        "disagreements": len(dis),
        "disagreement_calls": dis,
        "dropped_end_session_execs": [],
        "log_keys_without_calls": sorted(k for k in events if k not in by_key),
        "valid": n_smf == 0,
        "countable": n_smf == 0 and not dis,
    }
    threshold = read_cache_drop(rung_dir)
    if threshold is not None:  # E17c, ruling R-g: absent otherwise, so E17b's bytes are unchanged
        tag_cache(rows, calls, threshold)
        summary["cache_drop_s"] = threshold
        summary["warm_by_cache"] = {t: sum(r.get("cache") == t for r in gated) for t in (AFTER_DROP, KEPT)}
    return rows, summary


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1:
        raise SystemExit("usage: warmcold_lease.py RUNG_DIR")
    d = argv[0]
    rows, summary = join(d)
    with open(os.path.join(d, "warmcold.jsonl"), "w") as f:
        for r in rows:
            f.write(json.dumps(r, sort_keys=True) + "\n")
    with open(os.path.join(d, "warmcold-report.json"), "w") as f:
        json.dump(summary, f, indent=2, sort_keys=True)
    print("warm %d cold %d unknown %d failed_no_vm %d first_lease %d disagreements %d" % (
        summary["warm"], summary["cold"], summary["unknown"], summary["failed_no_vm"], summary["first_lease"],
        summary["disagreements"]))


if __name__ == "__main__":
    main()
