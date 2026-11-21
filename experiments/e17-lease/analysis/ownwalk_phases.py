#!/usr/bin/env python3
"""E17b/E17c ownership walk (spec §7.4, PLAN-E17B Task 11 fix round 1, PLAN-E17C Task 8): what the worker log shows of each ownwalk repeat.

  python3 experiments/e17-lease/analysis/ownwalk_phases.py RUNDIR   (RUNDIR/ownwalk.json and RUNDIR/worker.log)

`e15-driver ownwalk` measures A - B from the client. This reads the worker's side of the same calls and writes it
back into RUNDIR/ownwalk.json, per repeat (key):

  worker_phases     {"a": {...}, "b": {...}}: the SH_DIAG_PHASES=1 line (vmpool diag.go logPhases: acquire_us,
                    resume_us, vmresume_us, vsockdial_us, mount_us, run_us, destroy_us, cold) printed just before
                    A's and B's per-Exec audit line (runner.go: `vmpool: exec req=.. workspace_key="K" ...`). A key
                    has three audit lines, in order: the per-exec build, A, B.
  phase_corrected_walk_ms   A - B less the difference of the logged phases (acquire + resume + run + destroy):
                    the part of A - B no logged phase accounts for, i.e. the walk (normalise) and the lease start's
                    bookkeeping, without the cold-start or command variance the phases do record.
  lease_starts      the VMs of the key's `vmpool: lease start` lines: A's and B's, two different VMs. Fewer than
                    two means B did not start its own lease (not cold): the repeat is invalid.
  walk_observed     {"A", "B", "a_normalise_ms", "b_normalise_ms", "reason"}: whether A walked and B did not, from
                    the `normalise_us=` field on the phase line. From moca #966 the phase line carries it (the
                    lease start's ownership walk, 0 on an Exec that started no lease or needed no walk). The worker
                    at moca 8b787250 (E17b's pin) measures Phases.Normalise but logs it on no line, so on that
                    worker every value is null and `reason` says so (NO_FIELD); nothing is invalidated on a null.
                    When the field is there, a repeat whose A did not walk or whose B did is invalid.

Top level: phase_corrected_walk_median_ms, walk_observed_median_ms (the median of A's normalise phase, in ms, when
every repeat observed it). When any phase line carries normalise_us (moca #966 on), also the walk as the worker
itself timed it: normalise_us_median_a (the median of A's normalise_us over the repeats, null unless every A logged
it) and normalise_us_b_max (the largest of B's, which must be 0; null unless every B logged it), beside the A - B
inference (median_walk_ms, phase_corrected_walk_median_ms). Without the field neither key is written and the output
is what E17b's was. When this invalidates a repeat: valid false with the median_* fields and
normalise_us_median_a withheld (null), as the driver does; normalise_us_b_max stays. Exit 0, 1 when a repeat is invalid after this, 2 when an input is unreadable.
"""
import json
import os
import re
import sys

PHASES_RE = re.compile(r"vmpool: exec phases (?P<f>.*)$")
EXEC_RE = re.compile(r'vmpool: exec req=\d+ workspace_key="(?P<key>(?:[^"\\]|\\.)*)" ')
START_RE = re.compile(r'vmpool: lease start workspace_key="(?P<key>(?:[^"\\]|\\.)*)" vm=(?P<vm>\S+)')
FIELD_RE = re.compile(r'(\w+)=("[^"]*"|\S+)')
SUM = ("acquire_us", "resume_us", "run_us", "destroy_us")
NO_FIELD = ("the worker logs no normalise_us on its phase line (moca vmpool diag.go logPhases measures "
            "Phases.Normalise but prints it nowhere): not observed")


def median(v):
    s = sorted(v)
    n = len(s)
    return None if not n else (s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2)


def fields(text):
    out = {}
    for k, v in FIELD_RE.findall(text):
        if v.startswith('"'):
            out[k] = v[1:-1]
        else:
            try:
                out[k] = int(v)
            except ValueError:
                out[k] = v
    return out


def read_log(path):
    """{key: [phases dict or None per audit line]}, {key: [lease start VMs]}."""
    execs, starts, last = {}, {}, None
    with open(path, errors="replace") as f:
        for line in f:
            m = PHASES_RE.search(line)
            if m:
                last = fields(m.group("f"))
                continue
            m = EXEC_RE.search(line)
            if m:
                execs.setdefault(m.group("key"), []).append(last)
                last = None
                continue
            m = START_RE.search(line)
            if m:
                starts.setdefault(m.group("key"), []).append(m.group("vm"))
    return execs, starts


def observe(run, execs, starts):
    key = run.get("key")
    lines = execs.get(key, [])
    run["lease_starts"] = starts.get(key, [])
    wo = {"A": None, "B": None, "a_normalise_ms": None, "b_normalise_ms": None, "reason": None}
    run["walk_observed"], run["worker_phases"], run["phase_corrected_walk_ms"] = wo, None, None
    bad = []
    if len(lines) != 3 or lines[1] is None or lines[2] is None:
        wo["reason"] = "%d exec line%s with phases for %s in worker.log, want 3 (build, A, B)" % (
            len(lines), "" if len(lines) == 1 else "s", key)
        bad.append(wo["reason"])
    else:
        a, b = lines[1], lines[2]
        run["worker_phases"] = {"a": a, "b": b}
        if run.get("walk_ms") is not None and all(isinstance(p.get(k), int) for p in (a, b) for k in SUM):
            d_us = sum(a[k] for k in SUM) - sum(b[k] for k in SUM)
            run["phase_corrected_walk_ms"] = round(run["walk_ms"] - d_us / 1000.0, 3)
        if isinstance(a.get("normalise_us"), int) and isinstance(b.get("normalise_us"), int):
            wo["a_normalise_ms"], wo["b_normalise_ms"] = a["normalise_us"] / 1000.0, b["normalise_us"] / 1000.0
            wo["A"], wo["B"] = a["normalise_us"] > 0, b["normalise_us"] > 0
            if not wo["A"]:
                bad.append("A did not walk (normalise_us 0): the walk was not measured")
            if wo["B"]:
                bad.append("B walked (normalise_us %d): A - B is not the walk" % b["normalise_us"])
        else:
            wo["reason"] = NO_FIELD
        if len(run["lease_starts"]) != 2 or len(set(run["lease_starts"])) != 2:
            bad.append("%d lease starts in %d VM(s) for %s, want 2 lease starts in 2 VMs (A's and B's): B is not "
                       "known to be cold" % (len(run["lease_starts"]), len(set(run["lease_starts"])), key))
    if bad:
        run["valid"] = False
        run["invalid_reasons"] = (run.get("invalid_reasons") or []) + ["worker log: " + b_ for b_ in bad]


def normalise_us(run):
    """(A's, B's) normalise_us from the run's phase lines, each None when not logged."""
    wp = run.get("worker_phases") or {}
    return tuple(p.get("normalise_us") if isinstance((p or {}).get("normalise_us"), int) else None
                 for p in (wp.get("a"), wp.get("b")))


def annotate(rundir):
    with open(os.path.join(rundir, "ownwalk.json")) as f:
        rep = json.load(f)
    execs, starts = read_log(os.path.join(rundir, "worker.log"))
    runs = rep.get("runs") or []
    for run in runs:
        observe(run, execs, starts)
    pc = [r["phase_corrected_walk_ms"] for r in runs if r.get("phase_corrected_walk_ms") is not None]
    rep["phase_corrected_walk_median_ms"] = median(pc) if pc and len(pc) == len(runs) else None
    an = [r["walk_observed"]["a_normalise_ms"] for r in runs]
    rep["walk_observed_median_ms"] = median(an) if runs and None not in an else None
    nus = [normalise_us(r) for r in runs]
    if any(a is not None or b is not None for a, b in nus):  # moca #966 on; absent, the report is as before
        a_us, b_us = [a for a, _ in nus], [b for _, b in nus if b is not None]
        rep["normalise_us_median_a"] = median(a_us) if None not in a_us else None
        rep["normalise_us_b_max"] = max(b_us) if len(b_us) == len(runs) else None
    newly = ["repeat %s: %s" % (r.get("rep"), "; ".join(x for x in r["invalid_reasons"] if x.startswith("worker log: ")))
             for r in runs if any(x.startswith("worker log: ") for x in r.get("invalid_reasons") or [])]
    if newly:
        rep["valid"] = False
        rep["invalid_reasons"] = (rep.get("invalid_reasons") or []) + newly
        for k in ("median_a_ms", "median_b_ms", "median_walk_ms", "walk_observed_median_ms"):
            rep[k] = None
        if "normalise_us_median_a" in rep:
            rep["normalise_us_median_a"] = None
    return rep


def main(argv):
    if len(argv) != 1:
        sys.stderr.write("usage: ownwalk_phases.py RUNDIR\n")
        return 2
    try:
        rep = annotate(argv[0])
    except (OSError, ValueError) as e:
        sys.stderr.write("ownwalk_phases.py: %s\n" % e)
        return 2
    out = os.path.join(argv[0], "ownwalk.json")
    with open(out + ".tmp", "w") as f:
        json.dump(rep, f, indent=2)
        f.write("\n")
    os.replace(out + ".tmp", out)
    for r in rep.get("runs") or []:
        wo = r["walk_observed"]
        print("repeat %s %s: A-B %s ms, phase-corrected %s ms, normalise A %s B %s ms, lease starts %d, valid %s" % (
            r.get("rep"), r.get("key"), r.get("walk_ms"), r.get("phase_corrected_walk_ms"), wo["a_normalise_ms"],
            wo["b_normalise_ms"], len(r["lease_starts"]), r.get("valid")))
    if any(r["walk_observed"]["reason"] == NO_FIELD for r in rep.get("runs") or []):
        print("walk_observed: %s" % NO_FIELD)
    return 0 if rep.get("valid") else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
