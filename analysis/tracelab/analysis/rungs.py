#!/usr/bin/env python3
"""Results analysis over every measured rung (PROMPT §4).

Reads data/results/{aws,metal}/ (fetch first with scripts/fetch_results.sh) and
data/results-lock.json (each host's rows carry their results commit).

Outputs:
  rungs_all            one tidy row per rung (counted, repeat, k2, supplementary)
  ladders              n_max / n_max_abs per host, point, arm: as sealed
                       (ladder.json) and first-run-only (EXPERIMENTS §5)
  tail_by_tier         per rung, p95 excess by weight tier (light/medium/heavy
                       by planned work), recomputed from calls.jsonl.gz
  tail_by_class        per rung, p95 excess per class
  slowdown_ge1s        per rung, measured / planned time for calls planned >= 1 s
  aws_vs_metal         same point, arm and N on both hosts
  n1_overhead          per-call N=1 overhead per arm and host, from baseline.json
Figures:
  p95_excess_vs_n      one panel per host, one line per arm, limits as lines
  tail_by_tier_vs_n    p95 excess per tier vs N, SBX and resident ∞

Excess is recomputed exactly as holds.py defines it: added = observed_ms -
planned_dur_ms; excess = added - class_medians[class] (the arm's N=1 probe
median; an undercovered class uses global_median_ms). Window = in_window calls
with status ok. The recomputed all-call p95 is checked against record.json's
p95_excess_ms; disagreements are printed and kept in the table.
"""
import gzip
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import (ARM_COLOR, ARM_LABEL, CAT, RESULTS, ROOT, setup_matplotlib, save_fig,
                    write_table, quantile)

ARMS = ["sbx", "resident-inf", "resident-300", "control"]
TIER_CUTS = (1_000, 10_000)
TIERS = ["light", "medium", "heavy"]


def lock():
    with open(os.path.join(ROOT, "data", "results-lock.json")) as f:
        return json.load(f)


def tier_of(ms):
    return "light" if ms < TIER_CUTS[0] else ("medium" if ms <= TIER_CUTS[1] else "heavy")


def rung_dirs():
    """Yield (host, point, arm, n, kind, path) for every measured ladder rung."""
    pat_aws = re.compile(r"^(?P<point>[a-z0-9-]+)/(?P<arm>sbx|resident-inf|resident-300|control)/"
                         r"(?:(?P<supp>supplementary)/N)?(?P<n>\d+)(?:-(?P<kind>repeat|k2))?$")
    pat_metal = re.compile(r"^(?P<point>[a-z0-9-]+)/(?P<arm>sbx|resident-inf|resident-300|control)/"
                           r"(?:(?P<supp>supplementary)-1s/)?N(?P<n>\d+)(?:-1s)?"
                           r"(?:-(?P<kind>repeat-k2|repeat|k2))?(?P<g900>-g900)?$")
    for host, pat in (("aws", pat_aws), ("metal", pat_metal)):
        base = os.path.join(RESULTS, host)
        for dp, _, files in os.walk(base):
            if "record.json" not in files:
                continue
            rel = os.path.relpath(dp, base)
            if rel.startswith(("calibration", "baseline", "rungs")):
                continue
            m = pat.match(rel)
            if not m:
                continue
            d = m.groupdict()
            kind = d.get("kind") or "first"
            if d.get("g900"):
                kind += "-g900"
            if d.get("supp"):
                kind = "supplementary" + ("" if kind == "first" else "-" + kind)
            yield host, d["point"], d["arm"], int(d["n"]), kind, dp


def load_baseline(host, point, arm):
    if host == "aws":
        p = os.path.join(RESULTS, "aws", point, arm, "baseline", "baseline.json")
        if not os.path.exists(p):  # short/long/no-infra/no-chains borrow default's
            p = os.path.join(RESULTS, "aws", "default", arm, "baseline", "baseline.json")
    else:
        p = os.path.join(RESULTS, "metal", "baseline", point, arm, "N1", "baseline.json")
    if not os.path.exists(p):
        return None
    with open(p) as f:
        return json.load(f)


def open_jsonl(path, name):
    """<name>.gz when present, else <name> (some metal rungs were committed uncompressed)."""
    gz = os.path.join(path, name + ".gz")
    return gzip.open(gz, "rt") if os.path.exists(gz) else open(os.path.join(path, name))


def window_stats(path):
    """1 s samples in the window: host CPU mean/p95, MemAvailable min (MiB)."""
    with open(os.path.join(path, "params.json")) as f:
        p = json.load(f)
    a, b = p["warmup_s"], p["warmup_s"] + p["window_s"]
    cpu, mem = [], []
    with open_jsonl(path, "samples.jsonl") as f:
        for line in f:
            s = json.loads(line)
            if a <= s.get("t", -1) <= b:
                if "host_cpu_busy_pct" in s:
                    cpu.append(s["host_cpu_busy_pct"])
                if "mem_available_kb" in s:
                    mem.append(s["mem_available_kb"])
    return (sum(cpu) / len(cpu) if cpu else None, quantile(cpu, 0.95),
            min(mem) / 1024.0 if mem else None)


def window_calls(path):
    with open_jsonl(path, "calls.jsonl") as f:
        return [c for c in (json.loads(l) for l in f) if c.get("in_window") and c["status"] == "ok"]


def excess_of(c, base):
    med = base["class_medians"].get(c["class"])
    if med is None or c["class"] in (base.get("undercovered") or []):
        med = base["global_median_ms"]
    return c["observed_ms"] - c["planned_dur_ms"] - med


def r1(x):
    return None if x is None else round(x, 1)


def main():
    lk = lock()
    metal_sha = lk["metal"]["commit"][:7]
    rows, tier_rows, class_rows, slow_rows = [], [], [], []
    recs = {}
    for host, point, arm, n, kind, path in sorted(rung_dirs()):
        with open(os.path.join(path, "record.json")) as f:
            r = json.load(f)
        base = load_baseline(host, point, arm)
        cpu_mean, cpu_p95, mem_min = window_stats(path)
        drift = r.get("footprint_drift_pct")
        basis = r.get("footprint_drift_basis") or ("median" if drift is not None else None)
        src = "final @%s" % metal_sha if host == "metal" else "final"
        rows.append([host, point, arm, n, kind, r["holds"], r["holds_abs"],
                     r1(r.get("p95_excess_ms")), r1(r.get("excess_limit_ms")),
                     r1(r.get("p95_limit_abs_ms")), r["failed_calls"], r["refusals"],
                     round(100 * r["median_class_pace"], 2) if r.get("median_class_pace") is not None
                     else None, r["binding"], r1(cpu_mean), r1(cpu_p95),
                     round(mem_min) if mem_min else None, r1(drift), basis,
                     r["window_calls"], r.get("reason") or "", src])
        recs[(host, point, arm, n, kind)] = r
        if not base or arm == "control":
            continue
        calls = window_calls(path)
        # tier / class tails
        ex_all = []
        by_t = {t: [] for t in TIERS}
        by_c = {}
        slow = []
        for c in calls:
            e = excess_of(c, base)
            ex_all.append(e)
            # planned work: the call's planned_dur_ms (= work_ms except chains, whose
            # idle tail is in tail_ms); tier on dur - tail, the CPU-carrying part.
            work = c["planned_dur_ms"] - (c.get("tail_ms") or 0)
            by_t[tier_of(work)].append(e)
            by_c.setdefault(c["class"], []).append(e)
            if c["planned_dur_ms"] >= 1000:
                slow.append(c["observed_ms"] / c["planned_dur_ms"])
        p95 = quantile(ex_all, 0.95)
        rp = r.get("p95_excess_ms")
        if rp is not None and p95 is not None and abs(p95 - rp) > 1.0:
            print("WARN %s %s %s N=%d %s: recomputed p95 %.1f vs record %.1f"
                  % (host, point, arm, n, kind, p95, rp))
        tier_rows.append([host, point, arm, n, kind, len(ex_all), r1(p95)]
                         + sum([[len(by_t[t]), r1(quantile(by_t[t], 0.95))] for t in TIERS], []))
        for cls, ex in sorted(by_c.items()):
            class_rows.append([host, point, arm, n, kind, cls, len(ex), r1(quantile(ex, 0.50)),
                               r1(quantile(ex, 0.95))])
        slow_rows.append([host, point, arm, n, kind, len(slow),
                          round(quantile(slow, 0.50), 3) if slow else None,
                          round(quantile(slow, 0.95), 3) if slow else None,
                          round(max(slow), 2) if slow else None])

    write_table("rungs_all",
                ["host", "point", "arm", "N", "run", "holds", "holds_abs", "p95 excess ms",
                 "limit ms", "abs limit ms", "failed calls", "refusals", "median class pace %",
                 "binding", "host CPU mean %", "host CPU p95 %", "MemAvailable min MiB",
                 "footprint drift %", "drift basis", "window calls", "reason", "source"], rows)
    hdr = ["host", "point", "arm", "N", "run", "calls", "p95 excess ms (all)"]
    for t in TIERS:
        hdr += ["%s calls" % t, "%s p95 excess ms" % t]
    write_table("tail_by_tier", hdr, tier_rows)
    write_table("tail_by_class", ["host", "point", "arm", "N", "run", "class", "calls",
                                  "p50 excess ms", "p95 excess ms"], class_rows)
    write_table("slowdown_ge1s", ["host", "point", "arm", "N", "run", "calls planned >= 1 s",
                                  "p50 measured/planned", "p95 measured/planned", "max"], slow_rows)

    ladders(recs, metal_sha)
    supplementary_metal(rows, metal_sha)
    aws_vs_metal(rows)
    n1_overhead(metal_sha)
    figures(rows, tier_rows, metal_sha)


def ladders(recs, metal_sha):
    """Sealed (ladder.json) and first-run-only n_max per host, point, arm."""
    out = []
    for host in ("aws", "metal"):
        base = os.path.join(RESULTS, host)
        for dp, _, files in sorted(os.walk(base)):
            if "ladder.json" not in files:
                continue
            rel = os.path.relpath(dp, base).split(os.sep)
            if len(rel) != 2:
                continue
            point, arm = rel
            with open(os.path.join(dp, "ladder.json")) as f:
                L = json.load(f)
            # first-run only: walk the first runs in ladder order (start_n up).
            firsts = sorted(n for (h, p, a, n, k) in recs if (h, p, a, k) == (host, point, arm, "first"))
            fr, fr_abs, broke, broke_abs = None, None, False, False
            for n in firsts:
                r = recs[(host, point, arm, n, "first")]
                if not broke:
                    if r["holds"]:
                        fr = n
                    else:
                        broke = True
                if not broke_abs:
                    if r["holds_abs"]:
                        fr_abs = n
                    else:
                        broke_abs = True
            # "≥" when the first run held at the last rung the ladder tested.
            ge = "≥ " if not broke and firsts else ""
            ge_abs = "≥ " if not broke_abs and firsts else ""
            reps = sum(1 for (h, p, a, n, k) in recs if (h, p, a) == (host, point, arm) and k == "repeat")
            out.append([host, point, arm, L.get("n_max"), L.get("n_max_abs"), L.get("stopped_at"),
                        "%s%s" % (ge, fr) if fr is not None else "none",
                        "%s%s" % (ge_abs, fr_abs) if fr_abs is not None else "none",
                        reps, len(firsts), L.get("note", ""),
                        "final @%s" % metal_sha if host == "metal" else "final"])
    write_table("ladders", ["host", "point", "arm", "n_max (sealed)", "n_max_abs (sealed)",
                            "stopped at", "n_max first-run only", "n_max_abs first-run only",
                            "rungs repeated", "first runs", "note", "source"], out)


def supplementary_metal(rows, metal_sha):
    """E15 metal supplementary climb (not sealed): n_max under the 1 s limit and under
    conditions 1-3 only (the CPU-wall reading), from the climb rungs' record_1s/record_cpu
    files, as RESULTS-METAL.md defines them."""
    out = []
    base = os.path.join(RESULTS, "metal", "default")
    for arm in ("sbx", "resident-inf", "resident-300"):
        d = os.path.join(base, arm, "supplementary-1s")
        if not os.path.isdir(d):
            continue
        by_n = {}
        for name in sorted(os.listdir(d)):
            m = re.match(r"^N(\d+)-1s(-repeat)?(-g900)?$", name)
            if not m:
                continue
            n = int(m.group(1))
            rank = (1 if m.group(2) else 0) + (2 if m.group(3) else 0)
            if n not in by_n or rank > by_n[n][0]:
                by_n[n] = (rank, os.path.join(d, name))
        steps = []
        for n in sorted(by_n):
            p = by_n[n][1]
            def rd(fn):
                q = os.path.join(p, fn)
                return json.load(open(q)) if os.path.exists(q) else None
            r1s, rcpu, rec = rd("record_1s.json"), rd("record_cpu.json"), rd("record.json")
            steps.append((n, r1s and r1s.get("holds"), rcpu and rcpu.get("holds"),
                          rec and rec.get("p95_excess_ms")))
        n1s = ncpu = None
        b1 = bc = False
        for n, h1, hc, _ in steps:
            if not b1:
                if h1:
                    n1s = n
                elif h1 is False:
                    b1 = True
            if not bc:
                if hc:
                    ncpu = n
                elif hc is False:
                    bc = True
        out.append([arm, n1s, ncpu, ", ".join("%d%s" % (n, "" if hc else "✕") for n, _, hc, _ in steps),
                    "final @%s (supplementary, not sealed)" % metal_sha])
    write_table("metal_supplementary", ["arm", "n_max_1s (supp.)", "n_max_cpu (supp.)",
                                        "climb rungs (✕ = fails conditions 1-3)", "source"], out)


def aws_vs_metal(rows):
    idx = counted(rows)
    out = []
    for (h, p, a, n), ar in sorted(idx.items()):
        if h != "aws" or (("metal", p, a, n) not in idx):
            continue
        mr = idx[("metal", p, a, n)]
        out.append([p, a, n, ar[5], mr[5], ar[7], mr[7], ar[8], mr[8], ar[14], mr[14], ar[19], mr[19]])
    write_table("aws_vs_metal", ["point", "arm", "N", "AWS holds", "metal holds",
                                 "AWS p95 excess ms", "metal p95 excess ms", "AWS limit ms",
                                 "metal limit ms", "AWS host CPU %", "metal host CPU %",
                                 "AWS window calls", "metal window calls"], out)


def n1_overhead(metal_sha):
    out = []
    for host in ("aws", "metal"):
        for point in ("default", "mem512"):
            for arm in ("sbx", "resident-inf", "resident-300"):
                b = load_baseline(host, point, arm)
                if not b:
                    continue
                if host == "aws" and point == "mem512" and not os.path.exists(
                        os.path.join(RESULTS, "aws", "mem512", arm, "baseline", "baseline.json")):
                    continue
                out.append([host, point, arm, r1(b.get("overhead_ms")), r1(b.get("excess_p95_ms")),
                            r1(b.get("global_median_ms")), b.get("calls"),
                            "final @%s" % metal_sha if host == "metal" else "final"])
    write_table("n1_overhead", ["host", "point", "arm", "N=1 overhead ms/call",
                                "B: N=1 excess p95 ms", "global median added ms", "probe calls",
                                "source"], out)


def ladder_kinds():
    """{(host, point, arm, N): kind} of the run each ladder.json counted (its `dir`)."""
    out = {}
    for host in ("aws", "metal"):
        base = os.path.join(RESULTS, host)
        for point in sorted(os.listdir(base)) if os.path.isdir(base) else []:
            for arm in ARMS:
                p = os.path.join(base, point, arm, "ladder.json")
                if not os.path.exists(p):
                    continue
                with open(p) as f:
                    L = json.load(f)
                for r in L.get("rungs", []):
                    tail = (r.get("dir") or "").rstrip("/").split("/")[-1]
                    m = re.match(r"^N?\d+(?:-(?P<k>repeat-k2|repeat|k2))?$", tail)
                    out[(host, point, arm, r["n"])] = (m.group("k") if m and m.group("k") else "first")
    return out


def counted(rows):
    """The counted run per (host, point, arm, N): the one ladder.json names, else the
    latest of first < repeat < repeat-k2."""
    lk = ladder_kinds()
    rank = {"first": 0, "repeat": 1, "k2": 1, "repeat-k2": 2}
    by = {}
    for r in rows:
        if r[4] not in rank:
            continue
        k = (r[0], r[1], r[2], r[3])
        want = lk.get(k)
        if want is not None:
            if r[4] == want:
                by[k] = r
            continue
        if k not in by or rank[r[4]] > rank[by[k][4]]:
            by[k] = r
    return by


def figures(rows, tier_rows, metal_sha):
    plt = setup_matplotlib()
    cr = counted(rows)
    fr = {(r[0], r[1], r[2], r[3]): r for r in rows if r[4] == "first"}
    fig, axes = plt.subplots(1, 2, figsize=(7.4, 3.2))
    for ax, host in zip(axes, ("aws", "metal")):
        for arm in ("sbx", "resident-inf", "resident-300"):
            pts = sorted((k[3], v) for k, v in cr.items()
                         if k[0] == host and k[1] == "default" and k[2] == arm and v[7] is not None)
            if not pts:
                continue
            xs = [n for n, _ in pts]
            ax.plot(xs, [v[7] for _, v in pts], color=ARM_COLOR[arm], lw=1.8, marker="o", ms=4,
                    label=ARM_LABEL[arm])
            # first-run points where a repeat was counted, hollow
            fx = [(n, fr[(host, "default", arm, n)][7]) for n, v in pts
                  if v[4] != "first" and (host, "default", arm, n) in fr]
            if fx:
                ax.scatter([a for a, _ in fx], [b for _, b in fx], s=22, facecolors="none",
                           edgecolors=ARM_COLOR[arm], lw=1.2, zorder=3)
            lim = pts[-1][1][8]
            ax.axhline(lim, color=ARM_COLOR[arm], lw=0.9, ls="--", alpha=0.8)
        ax.set_yscale("log")
        ax.set_xlabel("sessions N")
        ax.set_title("AWS m8i.xlarge, 4 vCPU nested" if host == "aws"
                     else "metal m7i.metal-24xl, 96 vCPU (@%s)" % metal_sha)
        ax.set_xticks([1, 8, 16] if host == "aws" else [1, 32, 64, 96, 128, 160])
    axes[0].set_ylabel("p95 excess latency (ms)")
    axes[0].legend(loc="upper left", fontsize=7)
    fig.text(0.5, -0.04, "Default point. Solid: counted run. Hollow: first run when a drift repeat "
             "was counted. Dashed: the arm's primary limit max(3B, 50 ms).", ha="center", fontsize=7,
             color="#5f5e5a")
    save_fig(plt, fig, "p95_excess_vs_n")

    # Tier tails vs N on each host, SBX and resident ∞, counted runs.
    want = {k: v[4] for k, v in cr.items()}
    tr = {}
    for t in tier_rows:
        k = (t[0], t[1], t[2], t[3])
        if want.get(k) == t[4]:
            tr[k] = t
    fig, axes = plt.subplots(1, 2, figsize=(7.4, 3.2), sharey=True)
    styles = {"sbx": "-", "resident-inf": "--"}
    for ax, host in zip(axes, ("aws", "metal")):
        for j, tier in enumerate(TIERS):
            col = 8 + 2 * j
            for arm in ("sbx", "resident-inf"):
                pts = sorted((k[3], v[col]) for k, v in tr.items()
                             if k[0] == host and k[1] == "default" and k[2] == arm
                             and v[col] is not None and v[col] > 0)
                if not pts:
                    continue
                ax.plot([a for a, _ in pts], [b for _, b in pts], color=CAT[[4, 6, 7][j]],
                        ls=styles[arm], lw=1.6, marker="o", ms=3,
                        label="%s, %s" % (tier, ARM_LABEL[arm]))
        ax.set_yscale("log")
        ax.set_xlabel("sessions N")
        ax.set_title("AWS, 4 vCPU nested" if host == "aws"
                     else "metal, 96 vCPU (@%s)" % metal_sha)
        ax.set_xticks([1, 8, 16] if host == "aws" else [1, 32, 64, 96, 128, 160])
    axes[0].set_ylabel("p95 excess latency (ms)")
    axes[1].legend(fontsize=6.5, loc="upper left")
    save_fig(plt, fig, "tail_by_tier_vs_n")


if __name__ == "__main__":
    main()
