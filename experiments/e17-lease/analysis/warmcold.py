#!/usr/bin/env python3
"""E17 warm/cold join (SPEC §7.1, PLAN Task 4): tag every recorded call warm, cold or unknown from
the rung's worker.log.

  python3 experiments/e17-lease/analysis/warmcold.py RUNG_DIR      -> RUNG_DIR/warmcold.jsonl, RUNG_DIR/warmcold-report.json

A call is WARM when its first Exec ran on the same VM as the previous call's last Exec of the same
session key, with no `e15 resident {idle-destroy|retire|end-session}` line for that key between the
two in log order. The first call of a key is cold. The `cold=` field of the exec line is NOT the
signal: on the stock worker a standby pop logs cold="" with a new VM each time, and a resident reuse
also logs cold="". vm ids (vm-N, a per-worker counter) are never reused, so on the stock (sbx) arm
no call is ever warm.

Log lines read (everything else, including `vmpool: exec phases ...` and the attach probe's exec
line on key _e15-attach-probe, is ignored):
  stock   (remote-worker/internal/vmpool/runner.go):
          vmpool: exec req=<n> workspace_key="<k>" vm=<vm-N or empty> cold="<cause>" exit=<n> err=<...>
  patch   (experiments/e15-session-density/resident/resident.patch):
          vmpool: e15 resident idle-destroy workspace_key="<k>" vm=<vm-N> idle=<d>
          vmpool: e15 resident retire workspace_key="<k>" vm=<vm-N> reason=<r>
          vmpool: e15 resident end-session workspace_key="<k>" vm=<vm-N>

The join, per key (calls.jsonl `session` is the workspace key):
  1. the key's exec lines in log order (never re-ordered by timestamp: the log has 1 s resolution);
  2. drop the driver's end-session Exec (`: e15-end-session`, experiments/e15-session-density/driver/replay.go), which is never a
     recorded call but is logged as an ordinary exec line:
       a. the first exec line of the key after its `e15 resident end-session` line;
       b. an exec line with an empty vm and err=<nil>: the patch's answer to an end-session Exec when
          the key holds no VM (endResidentSession / execResident return Result{}, nil without a VM
          and without the end-session line). Every other Exec without a VM fails (err set);
       c. the key's LAST exec line when its vm is empty, its err is set, and the calls want exactly
          one Exec fewer than the log has: the end-session Exec (always a key's last) aborted at the
          run's teardown before endResidentSession ran (E16 resident-inf N1024: `err=vmpool:
          aborted`, no end-session line). Recorded as dropped_aborted_end_session.
     Each drop is recorded in the report;
  3. the key's calls in `call` order, each taking its Execs' lines: `execs`, except a call refused
     with `busy: queue full` (cause rpc_error) by the worker's session loop before the pool, which
     logs none and counts 0. A call with no line (never started, or refused) is unknown, and the
     next call compares with the last call that ran;
  4. a `retire` naming the vm of the exec line after it was logged inside that Exec (runResident
     retires the VM a command left unusable before the runner logs the command's exec line): it
     counts as lying after that Exec, so that call keeps its tag and the next call is cold;
  5. if the remaining lines and the calls' Exec count differ, every call of the key is unknown
     (exec-count). If they match but a paired line's stamp is more than 2 s from its call's
     ts + observed_ms, every call of the key is unknown too (timestamp_mismatch): two errors that
     cancel out in the count would otherwise shift every later call by one, silently. The guard
     only checks; it never re-places a line. A call whose first Exec has no vm (acquire failed) is
     unknown. Unknown is never guessed; the report counts it.
Reads plain or .gz calls.jsonl / worker.log.
"""
import calendar
import gzip
import json
import os
import re
import sys
import time

EXEC_RE = re.compile(r'vmpool: exec req=(?P<req>\d+) workspace_key="(?P<key>(?:[^"\\]|\\.)*)" '
                     r'vm=(?P<vm>\S*) cold="(?P<cold>(?:[^"\\]|\\.)*)" exit=(?P<exit>-?\d+) err=(?P<err>.*)$')
RESIDENT_RE = re.compile(r'vmpool: e15 resident (?P<kind>idle-destroy|retire|end-session) '
                         r'workspace_key="(?P<key>(?:[^"\\]|\\.)*)" vm=(?P<vm>\S*)')
PROBE_KEY = "_e15-attach-probe"  # experiments/e15-session-density/rig/rung.sh's relay attach check: never a session key
LOG_TS_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})Z ")
CALL_TS_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?Z$")
QUEUE_FULL = "busy: queue full"
TS_TOL_S = 2.0


def open_rung_file(d, name):
    p = os.path.join(d, name)
    if os.path.exists(p):
        return open(p, errors="replace")
    if os.path.exists(p + ".gz"):
        return gzip.open(p + ".gz", "rt", errors="replace")
    raise SystemExit("warmcold.py: no %s[.gz] in %s" % (name, d))


def read_calls(d):
    out = []
    with open_rung_file(d, "calls.jsonl") as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(json.loads(line))
    return out


def read_events(d):
    """Per key, its exec and teardown events in log order:
    {"kind": "exec", "req", "vm", "err", "ts"} / {"kind": <teardown>, "vm"}."""
    events = {}
    with open_rung_file(d, "worker.log") as f:
        for line in f:
            m = EXEC_RE.search(line)
            if m and m.group("key") == PROBE_KEY:
                continue
            if m:
                t = LOG_TS_RE.match(line)
                events.setdefault(m.group("key"), []).append(
                    {"kind": "exec", "req": int(m.group("req")), "vm": m.group("vm"),
                     "err": m.group("err").strip(),
                     "ts": calendar.timegm(time.strptime(t.group(1), "%Y-%m-%dT%H:%M:%S")) if t else None})
                continue
            m = RESIDENT_RE.search(line)
            if m:
                events.setdefault(m.group("key"), []).append({"kind": m.group("kind"), "vm": m.group("vm")})
    return events


def call_epoch(ts):
    """calls.jsonl `ts` (RFC 3339, up to nanoseconds, Z) -> epoch seconds; None if unparseable."""
    m = CALL_TS_RE.match(ts or "")
    if not m:
        return None
    return calendar.timegm(time.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S")) + float("0" + (m.group(2) or ""))


def call_execs(c):
    """The exec lines a call left in the log: its `execs`, except a call the worker's session loop
    refused with `busy: queue full` before it reached the pool (moca remote-worker/internal/session/
    loop.go), which the driver records with execs 1 but which logs no exec line."""
    if c.get("cause") == "rpc_error" and QUEUE_FULL in (c.get("msg") or ""):
        return 0
    return int(c.get("execs") or 0)


def exec_sequence(key, evs, dropped):
    """The key's call Execs in log order, each the exec event plus "teardowns" (kinds since the
    previous kept Exec), dropping the end-session Execs logged after an end-session line or with
    no vm and no error (appended to `dropped`)."""
    seq, since, after_end = [], [], False
    for ev in evs:
        if ev["kind"] != "exec":
            since.append(ev)
            after_end = after_end or ev["kind"] == "end-session"
            continue
        vm = ev["vm"]
        if after_end or (vm == "" and ev["err"] == "<nil>"):
            dropped.append({"session": key, "req": ev["req"], "vm": vm or None,
                            "reason": "after-end-session-line" if after_end else "no-vm-no-error"})
            after_end = False
            continue
        # runResident retires a VM the command left unusable inside that command's Exec, so the
        # retire line precedes the Exec's own exec line. vm ids are never reused: a retire naming
        # this Exec's vm came after this Exec ran on it, and lies before the NEXT Exec.
        own = [t for t in since if t["kind"] == "retire" and vm and t["vm"] == vm]
        seq.append(dict(ev, teardowns=[t["kind"] for t in since if t not in own]))
        since = own
    return seq


def timestamp_mismatch(calls, seq):
    """The paired exec lines against the calls' times (a check only; it never re-places a line).
    The runner logs an Exec's line when the Exec ends; the log's stamp is whole seconds. A call's
    last line must lie within TS_TOL_S of ts + observed_ms, any earlier line (a chain call) within
    [ts - TS_TOL_S, ts + observed_ms + TS_TOL_S]. Returns a reason string, or None."""
    i = 0
    for c in calls:
        n = call_execs(c)
        mine = seq[i:i + n]
        i += n
        if not mine:
            continue
        start = call_epoch(c.get("ts"))
        if start is None or any(e["ts"] is None for e in mine):
            return "call %s: no timestamp to check its exec line against" % c.get("call")
        end = start + float(c.get("observed_ms") or 0) / 1000.0
        if abs(mine[-1]["ts"] - end) > TS_TOL_S or any(
                not (start - TS_TOL_S <= e["ts"] <= end + TS_TOL_S) for e in mine[:-1]):
            return "call %s ends %.1f s from its exec line (req %d), more than %.0f s" % (
                c.get("call"), mine[-1]["ts"] - end, mine[-1]["req"], TS_TOL_S)
    return None


def tag_key(key, calls, seq, dropped_aborted):
    """Rows for one key's calls (in call order) against its Exec sequence."""
    want = sum(call_execs(c) for c in calls)
    rows = []
    # The end-session Exec is always the key's last (experiments/e02-e05-harness/e15-session-density/driver/replay.go runSlot). Aborted at the
    # run's teardown before endResidentSession ran, it has no vm, an error and no end-session line.
    if len(seq) == want + 1 and seq[-1]["vm"] == "" and seq[-1]["err"] != "<nil>":
        dropped_aborted.append({"session": key, "req": seq[-1]["req"], "err": seq[-1]["err"]})
        seq = seq[:-1]
    if want != len(seq):
        for c in calls:
            rows.append(row(c, "unknown", None, None, "exec-count"))
        return rows, "calls want %d exec lines, the log has %d" % (want, len(seq))
    why = timestamp_mismatch(calls, seq)
    if why:
        for c in calls:
            rows.append(row(c, "unknown", None, None, "timestamp_mismatch"))
        return rows, "timestamp_mismatch: " + why
    i, prev_vm, between = 0, None, []
    for c in calls:
        n = call_execs(c)
        mine = seq[i:i + n]
        i += n
        if not mine:
            rows.append(row(c, "unknown", None, prev_vm, "queue-full" if int(c.get("execs") or 0) else "not-started"))
            continue
        between = between + mine[0]["teardowns"]
        vm = mine[0]["vm"]
        if not vm:
            rows.append(row(c, "unknown", None, prev_vm, "no-vm"))
        elif prev_vm is None:
            rows.append(row(c, False, vm, None, "first"))
        elif between:
            rows.append(row(c, False, vm, prev_vm, between[-1]))
        elif vm != prev_vm:
            rows.append(row(c, False, vm, prev_vm, "vm-changed"))
        else:
            rows.append(row(c, True, vm, prev_vm, None))
        # Teardowns inside a chain call's later Execs still lie before the next call's first Exec;
        # with no vm to compare against (no-vm), the ones before it carry over as well.
        between = (between if not vm else []) + [t for e in mine[1:] for t in e["teardowns"]]
        last_vm = next((e["vm"] for e in reversed(mine) if e["vm"]), None)
        if last_vm:
            prev_vm = last_vm
    return rows, None


def row(c, warm, vm, prev_vm, cold_reason):
    return {"session": c.get("session"), "call": c.get("call"), "class": c.get("class"),
            "observed_ms": c.get("observed_ms"), "status": c.get("status"),
            "in_window": bool(c.get("in_window")), "warm": warm, "vm": vm, "prev_vm": prev_vm,
            "cold_reason": cold_reason}


def join(rung_dir):
    """Returns (rows sorted by session then call, summary)."""
    calls = read_calls(rung_dir)
    events = read_events(rung_dir)
    by_key = {}
    for c in calls:
        by_key.setdefault(c.get("session"), []).append(c)
    rows, dropped, aborted, unknown_keys = [], [], [], {}
    for key in sorted(by_key):
        kc = sorted(by_key[key], key=lambda c: c.get("call"))
        seq = exec_sequence(key, events.get(key, []), dropped)
        kr, why = tag_key(key, kc, seq, aborted)
        rows.extend(kr)
        if why:
            unknown_keys[key] = why
    summary = {
        "calls": len(rows),
        "warm": sum(r["warm"] is True for r in rows),
        "cold": sum(r["warm"] is False for r in rows),
        "unknown": sum(r["warm"] == "unknown" for r in rows),
        "unknown_by_reason": count_by(r["cold_reason"] for r in rows if r["warm"] == "unknown"),
        "cold_by_reason": count_by(r["cold_reason"] for r in rows if r["warm"] is False),
        "unknown_keys": unknown_keys,
        "dropped_end_session_execs": dropped,
        "dropped_aborted_end_session": aborted,
        "log_keys_without_calls": sorted(k for k in events if k not in by_key),
    }
    return rows, summary


def count_by(xs):
    out = {}
    for x in xs:
        out[x] = out.get(x, 0) + 1
    return out


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1:
        raise SystemExit("usage: warmcold.py RUNG_DIR")
    d = argv[0]
    rows, summary = join(d)
    with open(os.path.join(d, "warmcold.jsonl"), "w") as f:
        for r in rows:
            f.write(json.dumps(r, sort_keys=True) + "\n")
    with open(os.path.join(d, "warmcold-report.json"), "w") as f:
        json.dump(summary, f, indent=2, sort_keys=True)
    print("warm %d cold %d unknown %d" % (summary["warm"], summary["cold"], summary["unknown"]))


if __name__ == "__main__":
    main()
