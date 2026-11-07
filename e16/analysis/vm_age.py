#!/usr/bin/env python3
"""E16 SPEC §6: resident VM memory against VM age, from rung samples.

Each rung's samples.jsonl[.gz] row carries `t` (s since the driver's t0) and `vm_mem`, the memory
of every live VM's pool cgroup by name. A VM is age 0 at the first sample that shows it. Pool
cgroup names are reused: a name starts a new VM when its memory drops by more than 50% between two
of its samples, or when it is absent for more than 60 s. Names are per rung.

Each VM gives one value per 5-minute age bin (the median of its samples in that bin); a bin's
median and p95 (nearest rank) are over the VMs observed in it. growth_20_60_pct = the median VM
memory at 60 min / at 20 min - 1, in %, over the VMs observed in both bins (60-64 and 20-24 min of
age); null when fewer than 20 VMs were. Informational extras: max_age_min, and growth_20_last
(bin 20 to the last bin with at least 20 VMs also seen at 20 min).

Usage: python3 vm_age.py RUNG_DIR... --out PREFIX     (writes PREFIX.json and PREFIX.md)
"""

import argparse
import gzip
import json
import math
import os

BIN_S = 300
DROP = 0.5
ABSENT_S = 60
MIN_VMS = 20


def read_samples(d):
    for name in ("samples.jsonl.gz", "samples.jsonl"):
        p = os.path.join(d, name)
        if os.path.exists(p):
            opener = gzip.open if name.endswith(".gz") else open
            with opener(p, "rt") as f:
                for line in f:
                    line = line.strip()
                    if line:
                        try:
                            yield json.loads(line)
                        except ValueError:
                            pass
            return
    raise SystemExit("vm_age.py: no samples.jsonl[.gz] in %s" % d)


def vms_of(d):
    """[[(age_s, bytes), ...] per VM] for one rung."""
    done, live = [], {}  # live: name -> {"t0", "last_t", "last_v", "obs"}
    for r in read_samples(d):
        t = r.get("t")
        if t is None:
            continue
        for name, v in (r.get("vm_mem") or {}).items():
            if v is None:
                continue
            cur = live.get(name)
            if cur is not None and (t - cur["last_t"] > ABSENT_S or v < DROP * cur["last_v"]):
                done.append(cur["obs"])
                cur = None
            if cur is None:
                cur = live[name] = {"t0": t, "obs": []}
            cur["obs"].append((t - cur["t0"], v))
            cur["last_t"], cur["last_v"] = t, v
    done.extend(c["obs"] for c in live.values())
    return done


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
    vms, per_rung = [], []
    for d in rung_dirs:
        rv = [per_bin(o) for o in vms_of(d) if o]
        vms.extend(rv)
        per_rung.append({"rung": d, "vms": len(rv),
                         "max_age_min": max((max(v) for v in rv), default=None)})
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
    return {"bins_min": bins, "median_mib": med, "p95_mib": p95, "vms_per_bin": count,
            "growth_20_60_pct": g, "vms_20_60": n2060, "vms": len(vms),
            "max_age_min": top if vms else None, "growth_20_last": last,
            "min_vms": min_vms, "rungs": list(rung_dirs), "per_rung": per_rung,
            "rules": {"bin_s": BIN_S, "new_vm_on_drop_gt": DROP, "new_vm_on_absence_gt_s": ABSENT_S}}


def fmt(x, nd=1):
    return "-" if x is None else ("%.*f" % (nd, x))


def markdown(r):
    out = ["# VM memory against VM age", "",
           "%d VMs from %d rungs; ages to %s min (5-min bins)." % (r["vms"], len(r["rungs"]), r["max_age_min"]),
           "",
           "growth_20_60_pct: **%s** (%d VMs seen at both 20 and 60 min; needs %d)."
           % (fmt(r["growth_20_60_pct"]), r["vms_20_60"], r["min_vms"])]
    gl = r["growth_20_last"]
    if gl:
        out.append("Informational: 20 to %d min, %s%% over %d VMs." % (gl["to_min"], fmt(gl["pct"]), gl["vms"]))
    out += ["", "| age (min) | VMs | median MiB | p95 MiB |", "|---|---|---|---|"]
    for b, n, m, p in zip(r["bins_min"], r["vms_per_bin"], r["median_mib"], r["p95_mib"]):
        out.append("| %d | %d | %s | %s |" % (b, n, fmt(m), fmt(p)))
    out += ["", "| rung | VMs | max age (min) |", "|---|---|---|"]
    for pr in r["per_rung"]:
        out.append("| %s | %d | %s |" % (pr["rung"], pr["vms"], pr["max_age_min"]))
    return "\n".join(out) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("rungs", nargs="+")
    ap.add_argument("--out", required=True, help="PREFIX: writes PREFIX.json and PREFIX.md")
    ap.add_argument("--label-root", default=None, help="record rung paths relative to this dir")
    a = ap.parse_args(argv)
    r = analyse(a.rungs)
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
        f.write(markdown(r))
    return r


if __name__ == "__main__":
    main()
