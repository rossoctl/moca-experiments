#!/usr/bin/env python3
"""E16 SPEC §6: resident VM memory against VM age, from rung samples and the worker's log.

samples.jsonl[.gz] rows carry `ts` (epoch s) and `vm_mem`, memory.current of every populated pool
cgroup by name (pool-<n>). moca's worker reuses those cgroups (vmpool cgroup_pool.go): a VM's
restore pops the most recently released name off a free list, or mints pool-<issued>; its destroy
pushes the name back. A cgroup name is therefore not a VM, and a memory drop does not reliably mark
a new one (fix round 1, I1). Identity comes from worker.log[.gz] instead: each
`vmpool: restore phases id=vm-N` line is one VM birth (age 0), each `vmpool: destroy phases
id=vm-N` its end; replaying them through the same LIFO free list gives each VM its cgroup name.
A sample of a name belongs to the VM holding it at that time (the last born there at or before
the sample; none if that VM was destroyed more than 1 s earlier -- the cgroup sat free). The log's
1 s resolution and the restore line being written after the cgroup is acquired can misplace a
handful of samples per rung around concurrent births; per_rung reports attributed and
unattributed sample counts.

Each VM gives one value per 5-minute age bin (the median of its samples in that bin); a bin's
median and p95 (nearest rank) are over the VMs observed in it. growth_20_60_pct = the median VM
memory at 60 min / at 20 min - 1, in %, over the VMs observed in both bins (60-64 and 20-24 min of
age); null when fewer than 20 VMs were. Informational extras: max_age_min, growth_20_to (bin 20 to
each later bin, over VMs seen at both, where at least 20 were) and growth_20_last (the last of them).

Usage: python3 vm_age.py RUNG_DIR... --out PREFIX     (writes PREFIX.json and PREFIX.md)
"""

import argparse
import bisect
import calendar
import gzip
import json
import math
import os
import re
import time

BIN_S = 300
MIN_VMS = 20
FREE_TOL_S = 1.0
EVENT_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})Z vmpool: (restore|destroy) phases id=(vm-\d+) ")


def _open(d, base):
    for name in (base + ".gz", base):
        p = os.path.join(d, name)
        if os.path.exists(p):
            return gzip.open(p, "rt") if name.endswith(".gz") else open(p)
    raise SystemExit("vm_age.py: no %s[.gz] in %s" % (base, d))


def read_samples(d):
    with _open(d, "samples.jsonl") as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    yield json.loads(line)
                except ValueError:
                    pass


def read_events(d):
    """[(epoch s, "restore"|"destroy", vm id)] in log order. Only the matched fields are kept."""
    out = []
    with _open(d, "worker.log") as f:
        for line in f:
            m = EVENT_RE.match(line)
            if m:
                ts = calendar.timegm(time.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S"))
                out.append((float(ts), m.group(2), m.group(3)))
    if not any(k == "restore" for _, k, _ in out):
        raise SystemExit("vm_age.py: no 'restore phases' lines in %s's worker.log "
                         "(SH_DIAG_PHASES=1 is needed)" % d)
    return out


def vm_table(events):
    """Replay the events through moca's LIFO cgroup free list: [{id, name, born, end}]."""
    free, issued, live, vms = [], 0, {}, []
    for ts, kind, vid in events:
        if kind == "restore":
            if free:
                name = free.pop()
            else:
                name, issued = "pool-%d" % issued, issued + 1
            v = {"id": vid, "name": name, "born": ts, "end": None}
            live[vid] = v
            vms.append(v)
        else:
            v = live.pop(vid, None)
            if v is not None:
                v["end"] = ts
                free.append(v["name"])
    return vms


def vms_of(d, stats=None):
    """[[(age_s, bytes), ...] per VM] for one rung, VM identity from worker.log."""
    events = read_events(d)
    vms = vm_table(events)
    by_name = {}
    for v in vms:
        by_name.setdefault(v["name"], []).append(v)
    borns = {k: [v["born"] for v in vs] for k, vs in by_name.items()}
    obs = {v["id"]: [] for v in vms}
    att = unatt = 0
    for r in read_samples(d):
        ts = r.get("ts")
        if ts is None:
            continue
        for name, val in (r.get("vm_mem") or {}).items():
            if val is None:
                continue
            i = bisect.bisect_right(borns.get(name, []), ts) - 1
            v = by_name[name][i] if i >= 0 else None
            if v is None or (v["end"] is not None and ts > v["end"] + FREE_TOL_S):
                unatt += 1
                continue
            att += 1
            obs[v["id"]].append((ts - v["born"], val))
    if stats is not None:
        stats.update(births=len(vms), attributed_samples=att, unattributed_samples=unatt,
                     events=events)
    return [obs[v["id"]] for v in vms]


def _median(xs):
    xs = sorted(xs)
    n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0


def _p95(xs):
    xs = sorted(xs)
    return xs[max(0, int(math.ceil(0.95 * len(xs))) - 1)]


def per_bin(obs):
    """{bin start min: median MiB} for one VM."""
    b = {}
    for age, v in obs:
        b.setdefault(int(age // BIN_S) * BIN_S // 60, []).append(v / float(1 << 20))
    return {k: _median(vs) for k, vs in b.items()}


def growth(vms, a, b, min_vms):
    both = [v for v in vms if a in v and b in v]
    if len(both) < min_vms:
        return None, len(both)
    return 100.0 * (_median([v[b] for v in both]) / _median([v[a] for v in both]) - 1), len(both)


def analyse(rung_dirs, min_vms=MIN_VMS):
    vms, per_rung, raw = [], [], []
    for d in rung_dirs:
        st = {}
        rv = [per_bin(o) for o in vms_of(d, st) if o]
        vms.extend(rv)
        raw.append({"rung": d, "events": st.pop("events")})
        per_rung.append(dict({"rung": d, "vms": len(rv),
                              "max_age_min": max((max(v) for v in rv), default=None)}, **st))
    top = max((max(v) for v in vms), default=-5)
    bins = list(range(0, top + 5, 5))
    med, p95, count = [], [], []
    for b in bins:
        xs = [v[b] for v in vms if b in v]
        med.append(_median(xs) if xs else None)
        p95.append(_p95(xs) if xs else None)
        count.append(len(xs))
    g, n2060 = growth(vms, 20, 60, min_vms)
    last = None
    for b in reversed(bins):
        if b <= 20:
            break
        gl, nl = growth(vms, 20, b, min_vms)
        if gl is not None:
            last = {"to_min": b, "pct": gl, "vms": nl}
            break
    growth_20_to = {}
    for b in bins:
        if b > 20:
            gb, nb = growth(vms, 20, b, min_vms)
            if gb is not None:
                growth_20_to[str(b)] = {"pct": gb, "vms": nb}
    return {"bins_min": bins, "median_mib": med, "p95_mib": p95, "vms_per_bin": count,
            "growth_20_to": growth_20_to,
            "growth_20_60_pct": g, "vms_20_60": n2060, "vms": len(vms),
            "max_age_min": top if vms else None, "growth_20_last": last,
            "births": sum(p["births"] for p in per_rung),
            "min_vms": min_vms, "rungs": list(rung_dirs), "per_rung": per_rung,
            "rules": {"bin_s": BIN_S, "identity": "worker.log restore/destroy phases through "
                      "moca's LIFO cgroup free list", "free_tolerance_s": FREE_TOL_S},
            "decision": decision(g), "_raw": raw}


def fmt(x, nd=1):
    return "-" if x is None else ("%.*f" % (nd, x))


def decision(g):
    """SPEC §6 step 2: the long rung runs when growth_20_60_pct > 10 or is null."""
    if g is None:
        return "run the long rung (growth_20_60_pct is null: too few VMs observed at 60 min)"
    return ("run the long rung (growth_20_60_pct %.1f%% > 10%%)" % g if g > 10
            else "skip the long rung (growth_20_60_pct %.1f%% <= 10%%)" % g)


def markdown(r, label=None):
    out = ["# VM memory against VM age" + (" -- " + label if label else ""), "",
           "%d VMs (%d restores in worker.log) from %d rungs; ages to %s min (5-min bins). VM identity "
           "from worker.log restore/destroy events (fix round 1, I1)."
           % (r["vms"], r["births"], len(r["rungs"]), r["max_age_min"]),
           "",
           "growth_20_60_pct: **%s** (%d VMs seen at both 20 and 60 min; needs %d)."
           % (fmt(r["growth_20_60_pct"]), r["vms_20_60"], r["min_vms"]),
           "SPEC §6 decision on these rungs: %s." % decision(r["growth_20_60_pct"])]
    for b in ("50", "55"):
        g = r["growth_20_to"].get(b)
        if g:
            out.append("Informational (not the SPEC §6 metric): 20 to %s min, %s%% over %d VMs seen at both."
                       % (b, fmt(g["pct"]), g["vms"]))
    out += ["", "| age (min) | VMs | median MiB | p95 MiB |", "|---|---|---|---|"]
    for b, n, m, p in zip(r["bins_min"], r["vms_per_bin"], r["median_mib"], r["p95_mib"]):
        out.append("| %d | %d | %s | %s |" % (b, n, fmt(m), fmt(p)))
    out += ["", "| rung | restores | VMs sampled | max age (min) | samples attributed | unattributed |",
            "|---|---|---|---|---|---|"]
    for pr in r["per_rung"]:
        out.append("| %s | %d | %d | %s | %d | %d |" % (pr["rung"], pr["births"], pr["vms"], pr["max_age_min"],
                                                    pr["attributed_samples"], pr["unattributed_samples"]))
    return "\n".join(out) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("rungs", nargs="+")
    ap.add_argument("--out", required=True, help="PREFIX: writes PREFIX.json and PREFIX.md")
    ap.add_argument("--label-root", default=None, help="record rung paths relative to this dir")
    ap.add_argument("--label", default=None, help="a heading suffix for PREFIX.md")
    a = ap.parse_args(argv)
    r = analyse(a.rungs)
    r.pop("_raw", None)
    if a.label_root:
        rel = lambda p: os.path.relpath(p, a.label_root)
        r["rungs"] = [rel(p) for p in r["rungs"]]
        for pr in r["per_rung"]:
            pr["rung"] = rel(pr["rung"])
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out + ".json", "w") as f:
        json.dump(r, f, indent=2)
        f.write("\n")
    with open(a.out + ".md", "w") as f:
        f.write(markdown(r, a.label))
    return r


if __name__ == "__main__":
    main()
