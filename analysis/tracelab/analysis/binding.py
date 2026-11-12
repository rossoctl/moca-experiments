#!/usr/bin/env python3
"""What binds before memory? (E15 metal and E16, SBX vs resident.)

For every counted ladder rung on the metal host (E15 default and mem512, E16
lowduty), each candidate limit is measured as a share of its own ceiling, so
they can be compared on one scale:

  latency     p95 excess ÷ the arm's primary limit (the sealed test)
  CPU         host CPU busy, window mean and p95 (% of 96 vCPU)
  CPU PSI     max cpu.pressure some avg10 in the window
  memory      1 − MemAvailable min ÷ MemTotal
  disk read   window p95 MB/s ÷ the volume's measured parallel read max
  admission   live VMs × 1,056 MiB ÷ host RAM (moca's default no-overcommit rule;
              E15/E16 set it never to bind)
  worker      peak concurrent Execs in the window (from calls.jsonl: send to End)
              ÷ 320, the worker's per-connection admission (WORKER_MAX_CONCURRENT 256
              + QueueCap 64, moca#705); the driver uses one connection. The run-end
              end-session burst is outside the window and reported in e16_end_sessions

Plus the per-call cost that sits under the latency test:
  cold start  SBX's added ms per call at N = 1 (VM resume + destroy), resident's
              (warm VM), and mem512's cold first scan
  slowdown    measured ÷ planned time of long calls (planned ≥ 30 s) at equal N
  perf        IPC, LLC miss rate, turbo (aperf/mperf), DRAM read, where sampled
              (E16 every rung; E15 metal from RESULTS-METAL.md's climb table)

Writes tables binding_by_rung, binding_at_limit, cold_start, slowdown_long,
perf_by_rung; figures binding_headroom, binding_slowdown.
"""
import gzip
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import (ARM_COLOR, ARM_LABEL, CAT, RESULTS, ROOT, setup_matplotlib, save_fig,
                    write_table, quantile)

METAL = os.path.join(RESULTS, "metal")
E16 = os.path.join(RESULTS, "e16")
VM_CHARGE_MIB = 1056
WORKER_SLOTS = 320


def lock():
    with open(os.path.join(ROOT, "data", "results-lock.json")) as f:
        return json.load(f)


def open_jsonl(path, name):
    gz = os.path.join(path, name + ".gz")
    return gzip.open(gz, "rt") if os.path.exists(gz) else open(os.path.join(path, name))


def r1(x, d=1):
    return None if x is None else round(x, d)


def counted_dirs(ladder_path):
    """[(N, dir name, holds)] of the runs a ladder.json counted (E15 `dir`, E16 seeds)."""
    L = json.load(open(ladder_path))
    out = []
    for r in L["rungs"]:
        if "seeds" in r:
            d = next((s["dir"] for s in r["seeds"] if s["holds"] == r["holds"]), r["seeds"][0]["dir"])
        else:
            d = r.get("dir") or ""
        out.append((r["n"], d.rstrip("/").split("/")[-1], r["holds"]))
    return out


def window(path):
    p = json.load(open(os.path.join(path, "params.json")))
    a, b = p["warmup_s"], p["warmup_s"] + p["window_s"]
    cpu, psi, avail, disk, vms, infl = [], [], [], [], [], []
    total = p.get("host_mem_total_kb")
    with open_jsonl(path, "samples.jsonl") as f:
        for line in f:
            if not line.strip():
                continue
            s = json.loads(line)
            if not (a <= s.get("t", -1) <= b):
                continue
            if "host_cpu_busy_pct" in s:
                cpu.append(s["host_cpu_busy_pct"])
            if s.get("psi_cpu_some_avg10") is not None:
                psi.append(s["psi_cpu_some_avg10"])
            if s.get("mem_available_kb"):
                avail.append(s["mem_available_kb"])
            if s.get("disk_read_mbs") is not None:
                disk.append(s["disk_read_mbs"])
            vms.append(len(s.get("vm_mem") or {}))
            w = s.get("worker") or {}
            if w.get("inFlight") is not None:
                infl.append(w["inFlight"])
    return dict(p=p, cpu_mean=sum(cpu) / len(cpu) if cpu else None, cpu_p95=quantile(cpu, 0.95),
                psi_max=max(psi) if psi else None, avail_min=min(avail) if avail else None,
                total=total, disk_p95=quantile(disk, 0.95), disk_max_cap=p.get("disk_read_max_mbs"),
                vms_max=max(vms) if vms else None, inflight_p95=quantile(infl, 0.95),
                inflight_max=max(infl) if infl else None)


def calls_stats(path, min_ms=30_000):
    """Long-call slowdown (median, p95 of measured ÷ planned, in-window ok calls planned
    ≥ 30 s) and the peak number of Execs in flight at once, inside the window."""
    p = json.load(open(os.path.join(path, "params.json")))
    a, b = 1000.0 * p["warmup_s"], 1000.0 * (p["warmup_s"] + p["window_s"])
    xs, ev = [], []
    with open_jsonl(path, "calls.jsonl") as f:
        for line in f:
            c = json.loads(line)
            if c.get("in_window") and c["status"] == "ok" and c["planned_dur_ms"] >= min_ms:
                xs.append(c["observed_ms"] / c["planned_dur_ms"])
            s0, s1 = c["t_ms"], c["t_ms"] + (c.get("observed_ms") or 0)
            if s1 > a and s0 < b:
                ev.append((max(s0, a), 1))
                ev.append((min(s1, b), -1))
    ev.sort()
    cur = peak = 0
    for _, d in ev:
        cur += d
        peak = max(peak, cur)
    return len(xs), quantile(xs, 0.50), quantile(xs, 0.95), peak


def perf(path):
    p = os.path.join(path, "perf.jsonl")
    if not os.path.exists(p):
        return None
    rows = [json.loads(l) for l in open(p) if l.strip()]
    if not rows:
        return None
    m = lambda k: sum(r[k] for r in rows) / len(rows)
    return dict(ipc=m("ipc"), llc=m("llc_miss_rate"), turbo=m("aperf_mperf"),
                dram=m("mem_read_mib_s"), n=len(rows))


def rungs(sha_m, sha_e):
    sources = []
    for point in ("default", "mem512"):
        for arm in ("sbx", "resident-inf", "resident-300"):
            lad = os.path.join(METAL, point, arm, "ladder.json")
            if os.path.exists(lad):
                sources.append(("E15 metal " + point, arm, os.path.join(METAL, point, arm), lad,
                                "final @%s" % sha_m))
    for arm in ("sbx", "resident-inf"):
        sources.append(("E16 lowduty", arm, os.path.join(E16, arm),
                        os.path.join(E16, arm, "ladder.json"), "final @%s" % sha_e))
    rows = []
    for exp, arm, base, lad, src in sources:
        for n, d, holds in counted_dirs(lad):
            path = os.path.join(base, d)
            if n < 8 or not os.path.exists(os.path.join(path, "record.json")):
                continue
            r = json.load(open(os.path.join(path, "record.json")))
            w = window(path)
            lim = r.get("excess_limit_ms")
            nl, sl50, sl95, peak = calls_stats(path)
            pf = perf(path)
            rows.append(dict(
                exp=exp, arm=arm, n=n, run=d, holds=holds, failed=r["failed_calls"],
                latency=(r["p95_excess_ms"] / lim) if lim and r.get("p95_excess_ms") is not None else None,
                cpu_mean=w["cpu_mean"], cpu_p95=w["cpu_p95"], psi=w["psi_max"],
                mem=(1 - w["avail_min"] / w["total"]) if w["avail_min"] and w["total"] else None,
                disk=(w["disk_p95"] / w["disk_max_cap"]) if w["disk_p95"] is not None and w["disk_max_cap"] else None,
                admit=(w["vms_max"] * VM_CHARGE_MIB / (w["total"] / 1024.0)) if w["vms_max"] is not None and w["total"] else None,
                worker=peak / WORKER_SLOTS, execs_peak=peak,
                vms=w["vms_max"], long_n=nl, long50=sl50, long95=sl95, perf=pf, src=src))
    return rows


def pct(x):
    return None if x is None else round(100 * x, 1)


def tables(rows):
    write_table("binding_by_rung", [
        "experiment", "arm", "N", "counted run", "holds", "failed calls",
        "latency: p95 excess % of limit", "host CPU mean %", "host CPU p95 %", "CPU PSI max",
        "memory used % (1 − MemAvailable min)", "disk read p95 % of max",
        "admission at 1,056 MiB/VM % of RAM", "peak concurrent Execs", "Execs % of 320",
        "live VMs max",
        "long calls (≥ 30 s)", "long slowdown p50", "long slowdown p95", "source"],
        [[r["exp"], r["arm"], r["n"], r["run"], r["holds"], r["failed"], pct(r["latency"]),
          r1(r["cpu_mean"]), r1(r["cpu_p95"]), r1(r["psi"], 2), pct(r["mem"]), pct(r["disk"]),
          pct(r["admit"]), r["execs_peak"], pct(r["worker"]), r["vms"], r["long_n"],
          r1(r["long50"], 3),
          r1(r["long95"], 3), r["src"]] for r in rows])
    # at each arm's limit: the last held rung and the first failed rung
    out = []
    for key in sorted({(r["exp"], r["arm"]) for r in rows}):
        sub = sorted((r for r in rows if (r["exp"], r["arm"]) == key), key=lambda r: r["n"])
        last = None
        first_fail = None
        for r in sub:
            if r["holds"] and first_fail is None:
                last = r
            elif not r["holds"] and first_fail is None:
                first_fail = r
        for tag, r in (("last hold", last), ("first failure", first_fail)):
            if r is None:
                continue
            # admission is a policy E15/E16 set never to bind: reported, not a candidate
            cands = {"latency": r["latency"], "CPU (p95)": (r["cpu_p95"] or 0) / 100,
                     "memory": r["mem"], "disk read": r["disk"], "worker Execs": r["worker"]}
            top = max((k for k in cands if cands[k] is not None), key=lambda k: cands[k])
            why = ("failed calls (%d)" % r["failed"]) if (r["failed"] and not r["holds"]) else (
                "latency tail" if r["latency"] and r["latency"] > 1 and not r["holds"] else "")
            out.append([key[0], key[1], tag, r["n"], pct(r["latency"]), r1(r["cpu_p95"]),
                        pct(r["mem"]), pct(r["disk"]), pct(r["admit"]), pct(r["worker"]), top,
                        why, r["src"]])
    write_table("binding_at_limit", [
        "experiment", "arm", "rung", "N", "latency % of limit", "host CPU p95 %", "memory used %",
        "disk read % of max", "admission % of RAM (default rule, not binding)",
        "concurrent Execs % of 320",
        "closest to its ceiling", "why it failed", "source"], out)
    return out


def cold_start(sha_m, sha_e):
    """Per-call overhead at N = 1, from each arm's baseline, and the lifecycle bench."""
    out = []
    for exp, base in (("E15 metal default", os.path.join(METAL, "baseline", "default")),
                      ("E15 metal mem512", os.path.join(METAL, "baseline", "mem512")),
                      ("E16 lowduty", os.path.join(E16, "calibration", "baseline"))):
        for arm in ("sbx", "resident-inf", "resident-300"):
            p = os.path.join(base, arm, "N1", "baseline.json")
            if not os.path.exists(p):
                continue
            b = json.load(open(p))
            out.append([exp, arm, r1(b.get("overhead_ms")), r1(b.get("excess_p95_ms")),
                        r1((b.get("class_medians") or {}).get("read")),
                        r1((b.get("class_medians") or {}).get("shell_read")),
                        "final @%s" % (sha_e if exp.startswith("E16") else sha_m)])
    write_table("cold_start", ["experiment", "arm", "N=1 overhead ms/call", "B: N=1 excess p95 ms",
                               "read class median added ms", "shell_read class median added ms",
                               "source"], out)
    return out


def slowdown_table(rows):
    out = []
    for r in rows:
        if r["long_n"] >= 20:
            pf = r["perf"] or {}
            out.append([r["exp"], r["arm"], r["n"], r["long_n"], r1(r["long50"], 3),
                        r1(r["long95"], 3), r1(r["cpu_mean"]), r1(pf.get("ipc"), 2),
                        pct(pf.get("llc")), r1(pf.get("turbo"), 2), r1(pf.get("dram"), 0),
                        r["src"]])
    write_table("slowdown_long", ["experiment", "arm", "N", "long calls (≥ 30 s)",
                                  "slowdown p50", "slowdown p95", "host CPU mean %", "IPC",
                                  "LLC miss %", "turbo (aperf/mperf)", "DRAM read MiB/s",
                                  "source"], out)


def e15_perf_table():
    """RESULTS-METAL.md's climb-rung perf table (E15 metal; perf.jsonl not fetched)."""
    md = os.path.join(METAL, "RESULTS-METAL.md")
    if not os.path.exists(md):
        return []
    rows, on = [], False
    for line in open(md):
        if line.startswith("### SBX vs resident: relative slowdown"):
            on = True
            continue
        if on and line.startswith("Reading."):
            break
        if on and line.startswith("| ") and not line.startswith("| N ") and "---" not in line:
            c = [x.strip() for x in line.strip().strip("|").split("|")]
            if len(c) >= 13 and c[9]:
                rows.append(dict(n=int(c[0]), arm=c[1], ipc=float(c[9]), llc=float(c[10]),
                                 turbo=float(c[11]), dram=float(c[12]),
                                 long50=float(c[6]) if c[6] else None, cpu=float(c[8])))
    return rows


def figures(rows, sha_m, sha_e, e15perf):
    plt = setup_matplotlib()
    # Figure 1: headroom at each arm's last held rung, per candidate limit.
    cands = [("latency", "latency\n(p95 ÷ limit)"), ("cpu_p95", "host CPU\n(p95)"),
             ("mem", "memory\n(used)"), ("disk", "disk read\n(p95 ÷ max)"),
             ("worker", "worker Execs\n(peak ÷ 320)")]
    groups = []
    for exp in ("E15 metal default", "E16 lowduty"):
        for arm in ("sbx", "resident-inf"):
            sub = sorted((r for r in rows if r["exp"] == exp and r["arm"] == arm),
                         key=lambda r: r["n"])
            last = None
            for r in sub:
                if not r["holds"]:
                    break
                last = r
            if last:
                groups.append((exp, arm, last))
    fig, ax = plt.subplots(figsize=(7.4, 3.4))
    w = 0.19
    for j, (exp, arm, r) in enumerate(groups):
        vals = []
        for k, _ in cands:
            v = r[k] if k != "cpu_p95" else (r["cpu_p95"] or 0) / 100
            vals.append(100 * (v or 0))
        xs = [i + (j - 1.5) * (w + 0.01) for i in range(len(cands))]
        ax.bar(xs, vals, width=w, color=ARM_COLOR[arm],
               alpha=1.0 if exp.startswith("E15") else 0.55,
               hatch=None if exp.startswith("E15") else "///", edgecolor="white", lw=0,
               label="%s · %s · N=%d" % (ARM_LABEL[arm], "9.5% duty" if exp.startswith("E15")
                                         else "1.5% duty", r["n"]))
    ax.axhline(100, color="#1f1f1d", lw=1, ls="--")
    ax.set_xticks(range(len(cands)))
    ax.set_xticklabels([c[1] for c in cands], fontsize=8)
    ax.set_ylabel("% of its own ceiling")
    ax.set_ylim(0, 160)
    ax.legend(fontsize=7, loc="upper right")
    ax.set_title("How close each limit was, at each arm's last held rung")
    save_fig(plt, fig, "binding_headroom")
    # Figure 2: long-call slowdown vs N at equal N, E15 metal default (all arms).
    fig, ax = plt.subplots(figsize=(6.0, 3.2))
    for arm in ("sbx", "resident-inf", "resident-300"):
        pts = sorted((r["n"], r["long50"]) for r in rows
                     if r["exp"] == "E15 metal default" and r["arm"] == arm and r["long50"]
                     and r["long_n"] >= 20)
        if pts:
            ax.plot([a for a, _ in pts], [100 * (b - 1) for _, b in pts], color=ARM_COLOR[arm],
                    lw=1.8, marker="o", ms=4, label=ARM_LABEL[arm])
    ax.axhline(0, color="#9a9a94", lw=0.8)
    ax.set_xlabel("sessions N (E15 metal, 9.5% duty)")
    ax.set_ylabel("long calls: median slowdown (%)")
    ax.legend()
    ax.set_title("Long calls (≥ 30 s) run slower in SBX at equal N")
    save_fig(plt, fig, "binding_slowdown")


def main():
    lk = lock()
    sha_m, sha_e = lk["metal"]["commit"][:7], lk["e16"]["commit"][:7]
    rows = rungs(sha_m, sha_e)
    tables(rows)
    cold_start(sha_m, sha_e)
    slowdown_table(rows)
    e15perf = e15_perf_table()
    write_table("perf_e15_climb", ["arm", "N", "host CPU %", "IPC", "LLC miss %", "turbo",
                                   "DRAM read MiB/s", "long slowdown p50", "source"],
                [[p["arm"], p["n"], p["cpu"], p["ipc"], round(100 * p["llc"], 1), p["turbo"],
                  p["dram"], p["long50"], "RESULTS-METAL.md @%s" % sha_m] for p in e15perf])
    figures(rows, sha_m, sha_e, e15perf)


if __name__ == "__main__":
    main()
