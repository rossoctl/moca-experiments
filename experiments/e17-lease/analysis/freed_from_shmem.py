#!/usr/bin/env python3
"""E17b: the guest-tmpfs growth behind each heavy call, from the py_shmem readings (PLAN-E17B Task 10, ruling E17B-R23).

  python3 experiments/e17-lease/analysis/freed_from_shmem.py RUNDIR -> RUNDIR/shmem.json

A py_shmem call prints the guest's /proc/meminfo Shmem (kB); the driver records it under --record-stdout
py_shmem as calls.jsonl `stdout`. The pycache corpus sends one at the end of every turn, after the turn's
last py_analyze, so a turn has three heavy calls (py_analyze, py_test, py_analyze) between two readings and
the growth cannot be split among them. vm_age_lease.py reads shmem.json `calls` and computes, per heavy call
on a lease VM,

    freed = max(0, peak - start - dShmem)

(peak and start: the VM's memory.current, the maximum within the Exec and the last sample at or before its
start), then the verdict value_15s <= peak - freed/2. Tmpfs is guest RAM held until the VM goes: growth
there is not freed.

TURNS. Per session (calls.jsonl `session`, the workspace key) in call order, a turn is the calls after one
py_shmem up to and including the next; its id is that closing py_shmem's call number ("session:turn" keys
below), and it is incomplete (no reading) when the run ended inside it. Its measured delta is the closing
reading minus the base:
  - the base is the previous reading (the end of the previous turn);
  - a new lease inside the turn (a call carrying lease_events, or first_lease) restarts it: the base is
    then the new lease's start, Shmem 0, and only the heavy calls at or after that call can be judged
    (the earlier ones ran on a VM whose last reading is unknown: null);
  - no previous reading and no new lease inside the turn (the recorded calls begin mid-lease): null;
  - a reading that is not an ok call printing one integer is no reading: its turn and the next are null.
The delta is in bytes (1024 * kB).

PER CALL (shmem.json `calls`, {"session:call": dShmem bytes or null}, one key per heavy call, HEAVY_CLASSES
the same as vm_age_lease.py's):
  - session with tmpfs false (rows without `tmpfs`: none of its commands writes to guest tmpfs): when the
    turn's delta is within SHMEM_TOL_BYTES (|delta| <= 1 MiB), every judged heavy call of the turn gets
    dShmem 0; otherwise all of them get null, and the turn is listed under `unexpected_turns` with its
    delta (tmpfs growth the workload does not explain);
  - session with tmpfs true (the driver writes `tmpfs: true` on its rows): every heavy call is null, the
    per-call verdict is not judged there; each turn's delta is reported under `turns` (the §7.3 tmpfs cost);
  - a rung that is not a lease arm (params.json arm not ship-*; without params.json, a rung with no
    first_lease row): every call null and no turn reported, because a per-Exec reading is another VM's.
Rows with cause set_mode_failed ran no Exec and are skipped. A null dShmem makes freed null and the verdict
null, never false.

shmem.json = {"calls": {...}, "turns": {"session:turn": bytes or null}, "unexpected_turns": {"session:turn":
bytes}, "tolerance_bytes": 1048576}.
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import warmcold as W  # noqa: E402

HEAVY_CLASSES = ("py_analyze", "py_test")  # vm_age_lease.HEAVY_CLASSES (a test pins that they agree)
READING_CLASS = "py_shmem"
SHMEM_TOL_BYTES = 1 << 20
KB_RE = re.compile(r"^\s*(\d+)\s*$")


def reading(c):
    """The bytes a py_shmem call read, or None when it is not an ok call printing one integer (kB)."""
    m = KB_RE.match(c.get("stdout") or "")
    if c.get("status") != "ok" or not m:
        return None
    return int(m.group(1)) * 1024


def new_lease(c):
    return bool(c.get("lease_events")) or bool(c.get("first_lease"))


def turns_of(calls):
    """[(turn calls, closing reading index or None, base bytes or None, first judged index)] for one
    session's calls (sorted by call). `first judged` is the index of the turn's last new-lease mark, or
    the turn's first index when it has none."""
    out, lo, prev = [], 0, None  # prev: the index of the previous turn's closing reading
    for i, c in enumerate(calls + [None]):
        closing = c is not None and c.get("class") == READING_CLASS
        if not closing and c is not None:
            continue
        idx = list(range(lo, i + 1 if closing else i))
        marks = [j for j in idx if new_lease(calls[j])]
        if marks:
            base, first = 0, marks[-1]
        else:
            base = reading(calls[prev]) if prev is not None else None
            first = lo
        out.append((idx, i if closing else None, base, first))
        lo, prev = i + 1, (i if closing else prev)
    return out


def session_result(calls, judged):
    """({call: dShmem or None} for the heavy calls, [(turn id, delta or None)]) for one session."""
    per_call, turns = {}, []
    for idx, closing, base, first in turns_of(calls):
        heavy = [j for j in idx if calls[j].get("class") in HEAVY_CLASSES]
        if closing is None:  # the run ended inside this turn
            per_call.update((calls[j].get("call"), None) for j in heavy)
            continue
        after = reading(calls[closing])
        delta = after - base if after is not None and base is not None else None
        turns.append((calls[closing].get("call"), delta))
        ok = judged and delta is not None and abs(delta) <= SHMEM_TOL_BYTES
        per_call.update((calls[j].get("call"), 0 if ok and j >= first else None) for j in heavy)
    return per_call, turns


def is_lease_rung(d, calls):
    p = os.path.join(d, "params.json")
    if os.path.exists(p):
        with open(p) as f:
            return str(json.load(f).get("arm", "")).startswith("ship-")
    return any(c.get("first_lease") for c in calls)


def shmem_deltas(d):
    calls = [c for c in W.read_calls(d) if c.get("cause") != "set_mode_failed"]
    by_key = {}
    for c in calls:
        by_key.setdefault(c.get("session"), []).append(c)
    lease = is_lease_rung(d, calls)
    out = {"calls": {}, "turns": {}, "unexpected_turns": {}, "tolerance_bytes": SHMEM_TOL_BYTES}
    for key in sorted(by_key, key=str):
        cs = sorted(by_key[key], key=lambda c: c.get("call"))
        tmpfs = any(c.get("tmpfs") for c in cs)
        per_call, turns = session_result(cs, judged=lease and not tmpfs)
        out["calls"].update(("%s:%s" % (key, call), v) for call, v in per_call.items())
        if not lease:
            continue
        for turn, delta in turns:
            if tmpfs:
                out["turns"]["%s:%s" % (key, turn)] = delta
            elif delta is not None and abs(delta) > SHMEM_TOL_BYTES:
                out["unexpected_turns"]["%s:%s" % (key, turn)] = delta
    return out


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1:
        raise SystemExit("usage: freed_from_shmem.py RUNDIR")
    d = argv[0]
    out = shmem_deltas(d)
    with open(os.path.join(d, "shmem.json"), "w") as f:
        json.dump(out, f, indent=2, sort_keys=True)
        f.write("\n")
    v = out["calls"].values()
    print("heavy %d with_delta %d null %d; tmpfs turns %d; unexpected turns %d" % (
        len(out["calls"]), sum(x is not None for x in v), sum(x is None for x in v), len(out["turns"]),
        len(out["unexpected_turns"])))
    return out


if __name__ == "__main__":
    main()
