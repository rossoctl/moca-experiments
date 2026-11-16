#!/usr/bin/env python3
"""E17b: the guest-tmpfs growth of each heavy call, from the py_shmem readings (PLAN-E17B Task 10, ruling E17B-R22).

  python3 experiments/e17-lease/analysis/freed_from_shmem.py RUNDIR -> RUNDIR/shmem.json

A py_shmem call prints the guest's /proc/meminfo Shmem (kB): the driver records it under
--record-stdout py_shmem as calls.jsonl `stdout`. The pycache corpus sends one at the end of every turn,
right after the turn's last py_analyze. vm_age_lease.py reads shmem.json and computes, per heavy call on a
lease VM,

    freed = max(0, peak - start - dShmem)

(peak and start: the VM's memory.current, the maximum within the Exec and the last sample at or before its
start), then the verdict value_15s <= peak - freed/2. Shmem is guest RAM tmpfs holds until the VM goes:
growth there is not freed and is not counted as such.

shmem.json = {"session:call": dShmem bytes or null}, one key per heavy call (HEAVY_CLASSES, the same as
vm_age_lease.py's), per session (calls.jsonl `session`, the workspace key) in call order:
  - the readings that BRACKET heavy call h: `before`, the session's last py_shmem before h (the end of the
    previous turn), and `after`, its first py_shmem after h (the end of h's turn). dShmem = 1024 *
    (after - before) kB.
  - null when there is more than one heavy call between `before` (or the session's first recorded call)
    and `after`: the growth cannot be given to one of them;
  - null when there is no `after`, or a reading used is not an ok call whose stdout is one integer;
  - a new lease is marked by a call that carries lease_events (a start, or the end notice a replacement
    lease's first call carries) or first_lease. One after h, up to and including `after`, puts `after` on
    another VM: null. One after `before`, up to and including h, means the lease began in this turn: then
    `before` is the lease's start, Shmem 0. With no `before` and no such mark (the recorded calls begin
    inside a lease): null;
  - null on a rung that is not a lease arm (params.json arm not ship-*; without params.json, a rung with no
    first_lease row): a per-Exec reading is another VM's.
Rows with cause set_mode_failed ran no Exec and are skipped. A null dShmem makes freed null and the verdict
null, never false.
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
KB_RE = re.compile(r"^\s*(\d+)\s*$")


def reading(c):
    """The bytes a py_shmem call read, or None when it is not an ok call printing one integer (kB)."""
    m = KB_RE.match(c.get("stdout") or "")
    if c.get("status") != "ok" or not m:
        return None
    return int(m.group(1)) * 1024


def new_lease(c):
    return bool(c.get("lease_events")) or bool(c.get("first_lease"))


def session_deltas(calls):
    """{call: dShmem bytes or None} for one session's heavy calls (calls sorted by call)."""
    out = {}
    marks = [i for i, c in enumerate(calls) if c.get("class") == READING_CLASS]
    for h, c in enumerate(calls):
        if c.get("class") not in HEAVY_CLASSES:
            continue
        out[c.get("call")] = None
        before = max((i for i in marks if i < h), default=None)
        after = min((i for i in marks if i > h), default=None)
        lo = -1 if before is None else before
        if after is None or reading(calls[after]) is None:
            continue
        if sum(calls[i].get("class") in HEAVY_CLASSES for i in range(lo + 1, after)) != 1:
            continue
        if any(new_lease(calls[i]) for i in range(h + 1, after + 1)):
            continue
        if any(new_lease(calls[i]) for i in range(lo + 1, h + 1)):
            base = 0
        elif before is None:
            continue
        else:
            base = reading(calls[before])
            if base is None:
                continue
        out[c.get("call")] = reading(calls[after]) - base
    return out


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
    out = {}
    for key in sorted(by_key, key=str):
        cs = sorted(by_key[key], key=lambda c: c.get("call"))
        for call, delta in session_deltas(cs).items():
            out["%s:%s" % (key, call)] = delta if lease else None
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
    print("heavy %d with_delta %d null %d" % (len(out), sum(v is not None for v in out.values()),
                                             sum(v is None for v in out.values())))
    return out


if __name__ == "__main__":
    main()
