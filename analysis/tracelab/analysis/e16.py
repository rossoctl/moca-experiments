#!/usr/bin/env python3
"""E16 (low duty cycle) and the duty-cycle comparison with E15 (PROMPT follow-up).

E16 replays the (1%, 2%] duty band of the E15 default corpus (point `lowduty`,
456 sessions) on the E15 metal host, SBX against resident ∞, with physical
memory as the only memory limit. Hypothesis (e16/SPEC.md §1, the user's): at
duty <= 2%, SBX holds more sessions than resident ∞. E16 is complete; every
E16 row carries the e16 results commit (final).

Reads data/results/e16 and data/results/metal (fetch first), and the default
corpus. Writes:
  e16_band            the band, rebuilt from data/corpora/default (sha256 checked
                      against the rig's lowduty corpus)
  e16_rungs           one row per run (seed, repeat), with replayed duty, live
                      VMs, summed VM memory, MemAvailable, host CPU
  e16_ladders         n_max per arm from ladder.json, seed votes
  duty_memory         per arm and duty point (E15 default 9.5%, E16 1.5%): n_max,
                      and at the n_max rung: live VMs, summed VM memory peak,
                      memory per session, MemAvailable min
  e16_readings        the hypothesis under the three readings: sealed, post-seal
                      SBX extension, supplementary staggered end-sessions
  e16_stag            supplementary staggered rungs (run-end burst removed), with
                      their validity checks
  e16_end_sessions    end-session Execs per rung: sent, ok, failed, N - 320 (the
                      worker's per-connection admission, moca#705)
  e16_vm_age          resident VM memory against VM age, E16 long rung (3 h) and
                      E15 metal ladder rungs
Figures:
  e16_ladder          p95 excess vs N, both arms, sealed and staggered runs
  e16_vm_age          resident VM memory against VM age (median and p95)
  duty_memory         how duty cycle moves memory and sessions, SBX vs resident
"""
import gzip
import hashlib
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import (ARM_COLOR, ARM_LABEL, RESULTS, ROOT, load_corpus, setup_matplotlib,
                    save_fig, write_table, quantile)
from sessions import session_stats

E16 = os.path.join(RESULTS, "e16")
METAL = os.path.join(RESULTS, "metal")
BAND = (0.01, 0.02)
BAND_SHA = "0790d748aff79df6fc0f60897b41bbaabb238131d6b1cafb84b6cffce36a0588"
HOST_GIB = 377.0
USABLE_GIB = 373.0  # e15.slice MemoryHigh: host RAM - 4 GiB (E15 metal guards)
GUEST_MIB = 1024


def lock():
    with open(os.path.join(ROOT, "data", "results-lock.json")) as f:
        return json.load(f)


def open_jsonl(path, name):
    gz = os.path.join(path, name + ".gz")
    return gzip.open(gz, "rt") if os.path.exists(gz) else open(os.path.join(path, name))


def window_memory(path):
    """Window peaks from 1 s samples: live VMs (vm_mem entries), summed VM memory GiB,
    e15.slice memory GiB, MemAvailable min GiB, host CPU mean/p95 %."""
    with open(os.path.join(path, "params.json")) as f:
        p = json.load(f)
    a, b = p["warmup_s"], p["warmup_s"] + p["window_s"]
    vms, vsum, slc, avail, cpu = [], [], [], [], []
    with open_jsonl(path, "samples.jsonl") as f:
        for line in f:
            if not line.strip():
                continue
            s = json.loads(line)
            if not (a <= s.get("t", -1) <= b):
                continue
            vm = s.get("vm_mem") or {}
            vms.append(len(vm))
            vsum.append(sum(vm.values()) / 2 ** 30)
            if s.get("e15_mem_bytes"):
                slc.append(s["e15_mem_bytes"] / 2 ** 30)
            if s.get("mem_available_kb"):
                avail.append(s["mem_available_kb"] / 2 ** 20)
            if "host_cpu_busy_pct" in s:
                cpu.append(s["host_cpu_busy_pct"])
    return dict(vms_max=max(vms) if vms else None, vms_mean=sum(vms) / len(vms) if vms else None,
                vm_gib_max=max(vsum) if vsum else None,
                vm_gib_mean=sum(vsum) / len(vsum) if vsum else None,
                slice_gib_max=max(slc) if slc else None,
                avail_gib_min=min(avail) if avail else None,
                cpu_mean=sum(cpu) / len(cpu) if cpu else None, cpu_p95=quantile(cpu, 0.95))


def r1(x, d=1):
    return None if x is None else round(x, d)


def band_table():
    band = []
    for s in load_corpus("default"):
        span, busy, *_ = session_stats(s["calls"])
        if span and BAND[0] < busy / span <= BAND[1]:
            band.append(s)
    blob = "".join(json.dumps(s, separators=(",", ":")) + "\n" for s in band).encode()
    sha = hashlib.sha256(blob).hexdigest()
    if sha != BAND_SHA:
        raise SystemExit("lowduty band sha256 %s != the rig's %s" % (sha, BAND_SHA))
    with open(os.path.join(E16, "corpus", "lowduty-report.json")) as f:
        rep = json.load(f)
    full = json.load(open(os.path.join(ROOT, "data", "corpora", "default", "corpus-report.json")))
    write_table("e16_band", ["corpus", "sessions", "users", "top user share %", "occupied %",
                             "work %", "calls/s per session", "mean span h", "sha256"], [
        ["E15 default", full["sessions"], "52", "", r1(full["table"]["occupied_pct"], 2),
         r1(full["table"]["work_pct"], 2), r1(full["table"]["calls_per_s"], 4),
         r1(full["table"]["mean_span_min"] / 60, 2), "24050ae8…"],
        ["E16 lowduty (1%, 2%]", rep["sessions"], rep["users"], r1(100 * rep["top_user_share"]),
         r1(rep["occupied_pct"], 2), r1(rep["work_pct"], 2),
         r1(rep["calls_per_s_per_session"], 4), r1(rep["mean_span_h"], 2), sha[:8] + "…"]])
    return rep


def e16_rows(sha):
    rows, recs = [], {}
    pat = re.compile(r"^N(?P<n>\d+)(?:-s(?P<seed>\d))?(?P<rep>-repeat)?$")  # sealed runs only
    for arm in ("sbx", "resident-inf"):
        base = os.path.join(E16, arm)
        for name in sorted(os.listdir(base)):
            m = pat.match(name)
            p = os.path.join(base, name)
            if not m or not os.path.exists(os.path.join(p, "record.json")):
                continue
            r = json.load(open(os.path.join(p, "record.json")))
            n, seed = int(m.group("n")), int(m.group("seed") or 1)
            kind = "repeat" if m.group("rep") else "first"
            w = window_memory(p)
            duty = r.get("replayed_duty") or {}
            rows.append([arm, n, seed, kind, r["holds"], r["holds_abs"], r1(r.get("p95_excess_ms")),
                         r1(r.get("excess_limit_ms")), r["failed_calls"], r["refusals"],
                         r.get("reason") or "", r["window_calls"],
                         r1(100 * duty["mean"], 2) if duty.get("mean") is not None else None,
                         r1(100 * duty["median"], 2) if duty.get("median") is not None else None,
                         r1(100 * r["distinct_trace_share"]) if r.get("distinct_trace_share") else None,
                         w["vms_max"], r1(w["vm_gib_max"]), r1(w["vm_gib_mean"]),
                         r1(w["avail_gib_min"]), r1(w["cpu_mean"]), r1(w["cpu_p95"]),
                         "final @%s" % sha])
            recs[(arm, n, seed, kind)] = (r, w)
    write_table("e16_rungs", ["arm", "N", "seed", "run", "holds", "holds_abs", "p95 excess ms",
                              "limit ms", "failed calls", "refusals", "reason", "window calls",
                              "replayed duty mean %", "replayed duty median %",
                              "distinct traces %", "live VMs max", "VM memory max GiB",
                              "VM memory mean GiB", "MemAvailable min GiB", "host CPU mean %",
                              "host CPU p95 %", "source"], rows)
    return rows, recs


STAG = re.compile(r"^N(?P<n>\d+)-(?P<tag>stag|postseal)(?:-s(?P<seed>\d))?(?P<rep>-repeat)?$")


def stag_rows(sha):
    """Supplementary runs: staggered end-sessions (resident) and the post-seal SBX
    extension. The counted run of a seed is its repeat when one exists."""
    rows = []
    for arm in ("sbx", "resident-inf"):
        base = os.path.join(E16, arm)
        for name in sorted(os.listdir(base)):
            m = STAG.match(name)
            p = os.path.join(base, name)
            if not m or not os.path.exists(os.path.join(p, "record.json")):
                continue
            r = json.load(open(os.path.join(p, "record.json")))
            v = os.path.join(p, "stag_valid.json")
            sv = json.load(open(v)) if os.path.exists(v) else {}
            foot = end_footer(p)
            rows.append([arm, int(m.group("n")), int(m.group("seed") or 1),
                         "repeat" if m.group("rep") else "first", m.group("tag"),
                         r["holds"], r["holds_abs"], r1(r.get("p95_excess_ms")),
                         r1(r.get("excess_limit_ms")), r["failed_calls"],
                         sv.get("valid") if sv else "(not counted)", foot.get("end_sessions_deferred"),
                         foot.get("end_sessions_failed"),
                         r1(100 * r["distinct_trace_share"]) if r.get("distinct_trace_share") else None,
                         "final @%s" % sha])
    rows.sort(key=lambda x: (x[0], x[1], x[2], x[3] != "first"))
    write_table("e16_stag", ["arm", "N", "seed", "run", "tag", "holds", "holds_abs",
                             "p95 excess ms", "limit ms", "failed calls", "valid (3 checks)",
                             "end-sessions deferred", "end-sessions failed", "distinct traces %",
                             "source"], rows)
    return rows


def end_footer(path):
    """The driver's last driver-cpu.jsonl line: end-session counts (resident arms)."""
    f = os.path.join(path, "driver-cpu.jsonl")
    if not os.path.exists(f):
        return {}
    last = None
    with open(f) as fh:
        for line in fh:
            if line.strip():
                last = line
    try:
        d = json.loads(last or "{}")
    except ValueError:
        return {}
    return d if d.get("footer") else {}


ADMIT = 256 + 64  # WORKER_MAX_CONCURRENT + session QueueCap: one relay connection (moca#705)


def end_sessions(rows, sha):
    """Sealed resident runs: run-end end-session Execs refused beyond 320 per connection."""
    out = []
    for r in rows:
        arm, n, seed, kind = r[0], r[1], r[2], r[3]
        if arm != "resident-inf":
            continue
        name = "N%d%s%s" % (n, "" if seed == 1 else "-s%d" % seed, "-repeat" if kind == "repeat" else "")
        f = end_footer(os.path.join(E16, arm, name))
        if not f:
            continue
        out.append([n, seed, kind, f["end_sessions_sent"], f["end_sessions_ok"],
                    f["end_sessions_failed"], max(0, n - ADMIT), r[8], r[4], "final @%s" % sha])
    out.sort(key=lambda x: (x[0], x[1], x[2] != "first"))
    write_table("e16_end_sessions", ["N", "seed", "run", "end-sessions sent", "ok", "failed",
                                     "N - 320", "failed window calls", "holds", "source"], out)
    return out


def readings(sha):
    """The hypothesis verdict under the three readings (RESULTS.md order)."""
    S = json.load(open(os.path.join(E16, "summary.json")))
    sealed_sbx = S["sbx_sealed_ladder_before_extension"]
    res = S["resident-inf"]
    sup = S["supplementary"]
    top = lambda d: max(int(k) for k, v in d["verdicts"].items() if v["holds"])
    rows = [
        ["sealed (SPEC §7.2)", "≥ %d" % sealed_sbx["n_max"], res["n_max"],
         "tie → FALSIFIED", "sealed ladders; SBX censored at its sealed top"],
        ["post-seal SBX extension", "≥ %d" % S["sbx"]["n_max"], res["n_max"],
         "SBX ahead — not a sealed verdict",
         "resident's limit is the run-end burst (moca#705); no-wedge re-judges hold"],
        ["supplementary, staggered end-sessions", "≥ %d" % top(sup["sbx"]),
         "≥ %d" % top(sup["resident-inf"]), "no separation",
         "run-end burst removed; every rung valid; both censored at 1536"],
    ]
    write_table("e16_readings", ["reading", "SBX n_max", "resident ∞ n_max", "verdict", "note",
                                 "source"], [x + ["final @%s" % sha] for x in rows])
    return rows


def vm_age_table(sha):
    """Resident VM memory against VM age: E16 long rung and E15 metal ladder rungs."""
    L = json.load(open(os.path.join(E16, "vm-age", "long-rung.json")))["vm_age"]
    E = json.load(open(os.path.join(E16, "vm-age", "e15-metal.json")))
    rows = []
    for name, d in (("E16 long rung (N=256, 3 h, 1.5% duty)", L),
                    ("E15 metal ladder rungs (9.5% duty)", E)):
        for b, med, p95, nv in zip(d["bins_min"], d["median_mib"], d["p95_mib"], d["vms_per_bin"]):
            if med is None:
                continue
            rows.append([name, b, r1(med), r1(p95), nv, "final @%s" % sha])
    write_table("e16_vm_age", ["source", "VM age min", "median MiB", "p95 MiB", "VMs", "source commit"],
                rows)
    return L, E


def e16_ladders(sha):
    out = {}
    rows = []
    for arm in ("sbx", "resident-inf"):
        L = json.load(open(os.path.join(E16, arm, "ladder.json")))
        out[arm] = L
        votes = []
        for r in L["rungs"]:
            if len(r.get("seeds", [])) > 1:
                votes.append("N=%d: %s → %s" % (r["n"], "/".join(
                    "held" if s["holds"] else "failed" for s in r["seeds"]),
                    "held" if r["holds"] else "failed"))
        rows.append([arm, L.get("n_max"), L.get("n_max_abs"), L.get("stopped_at") or "none yet",
                     ", ".join(str(n) for n in L.get("rungs_run", [])), "; ".join(votes),
                     r1(L.get("B_ms")), r1(L.get("n1_overhead_ms")), "final @%s" % sha])
    write_table("e16_ladders", ["arm", "n_max", "n_max_abs", "first failed rung", "rungs run",
                                "seed votes", "B ms", "N=1 overhead ms/call", "source"], rows)
    return out


def counted_dir(ladder_path, n):
    L = json.load(open(ladder_path))
    for r in L["rungs"]:
        if r["n"] == n:
            if "seeds" in r:  # E16: the first seed whose verdict matches the vote
                for s in r["seeds"]:
                    if s["holds"] == r["holds"]:
                        return s["dir"].rstrip("/").split("/")[-1]
            return (r.get("dir") or "").rstrip("/").split("/")[-1]
    return None


def duty_memory(e16_lad, band_rep, sha_m, sha_e16):
    """Memory and sessions at each arm's n_max, at both duty points."""
    pts = []
    e15_occ = json.load(open(os.path.join(ROOT, "data", "corpora", "default",
                                          "corpus-report.json")))["table"]["occupied_pct"]
    for arm in ("sbx", "resident-inf"):
        lad = os.path.join(METAL, "default", arm, "ladder.json")
        L = json.load(open(lad))
        n = L["n_max"]
        w = window_memory(os.path.join(METAL, "default", arm, counted_dir(lad, n)))
        pts.append(("E15 default", e15_occ, arm, n, w, "final @%s" % sha_m))
        lad = os.path.join(E16, arm, "ladder.json")
        n = e16_lad[arm]["n_max"]
        w = window_memory(os.path.join(E16, arm, counted_dir(lad, n)))
        pts.append(("E16 lowduty", band_rep["occupied_pct"], arm, n, w, "final @%s" % sha_e16))
    rows = []
    for name, occ, arm, n, w, src in pts:
        per = w["vm_gib_mean"] * 1024 / n if w["vm_gib_mean"] is not None else None
        admit = w["vms_max"] * GUEST_MIB / 1024.0 if w["vms_max"] is not None else None
        ceil = int(USABLE_GIB * 1024 / per) if per else None
        rows.append([name, r1(occ, 2), arm, n, w["vms_max"], r1(w["vms_mean"]), r1(w["vm_gib_max"]),
                     r1(w["vm_gib_mean"]), r1(per), r1(100 * (w["vm_gib_max"] or 0) / HOST_GIB),
                     ceil, r1(admit), r1(w["avail_gib_min"]), r1(w["cpu_mean"]), src])
    write_table("duty_memory", ["corpus", "duty (occupied %)", "arm", "n_max", "live VMs max",
                                "live VMs mean", "VM memory max GiB", "VM memory mean GiB",
                                "VM MiB per session (mean)", "VM memory max % of host",
                                "memory ceiling, sessions (373 GiB / MiB per session)",
                                "admission charge at 1 GiB/VM, GiB", "MemAvailable min GiB",
                                "host CPU mean %", "source"], rows)
    return rows


def memory_by_rung(e16_lad, sha_m, sha_e):
    """Summed VM memory and live VMs at every counted rung: E15 metal default and E16."""
    out = []
    for arm in ("sbx", "resident-inf"):
        lad = os.path.join(METAL, "default", arm, "ladder.json")
        for r in json.load(open(lad))["rungs"]:
            if r["n"] < 8:
                continue
            w = window_memory(os.path.join(METAL, "default", arm, counted_dir(lad, r["n"])))
            out.append(["E15 default", arm, r["n"], r["holds"], w["vms_mean"], w["vm_gib_mean"],
                        w["vm_gib_max"], "final @%s" % sha_m])
        lad = os.path.join(E16, arm, "ladder.json")
        for r in e16_lad[arm]["rungs"]:
            w = window_memory(os.path.join(E16, arm, counted_dir(lad, r["n"])))
            out.append(["E16 lowduty", arm, r["n"], r["holds"], w["vms_mean"], w["vm_gib_mean"],
                        w["vm_gib_max"], "final @%s" % sha_e])
    write_table("duty_memory_by_rung", ["corpus", "arm", "N", "holds", "live VMs mean",
                                        "VM memory mean GiB", "VM memory max GiB", "source"],
                [[a, b, c, d, r1(e), r1(f, 2), r1(g, 2), h] for a, b, c, d, e, f, g, h in out])
    return out


def fig_duty(plt, dm, by_rung, sha_e):
    """How duty cycle moves memory and sessions, SBX vs resident ∞ (3 panels)."""
    fig, axes = plt.subplots(1, 4, figsize=(13.4, 3.5),
                             gridspec_kw={"width_ratios": [1, 1.5, 1, 1]})
    duty_lab = {"E15 default": "9.5% duty\n(E15 default)",
                "E16 lowduty": "1.5% duty\n(E16; SBX incl. post-seal)"}
    corp = ["E15 default", "E16 lowduty"]
    w = 0.36
    # (a) sessions held
    ax = axes[0]
    for j, arm in enumerate(("sbx", "resident-inf")):
        for i, c in enumerate(corp):
            r = next(x for x in dm if x[0] == c and x[2] == arm)
            x = i + (j - 0.5) * (w + 0.03)
            censored = c == "E16 lowduty" and arm == "sbx"  # SBX never failed: a lower bound
            ax.bar([x], [r[3]], width=w, color=ARM_COLOR[arm], hatch="///" if censored else None,
                   edgecolor="white", lw=0, label=ARM_LABEL[arm] if i == 0 else None)
            ax.text(x, r[3] * 1.08, ("≥ %d" if censored else "%d") % r[3], ha="center",
                    va="bottom", fontsize=8)
    ax.set_yscale("log")
    ax.set_ylim(30, 4000)
    ax.set_xticks([0, 1])
    ax.set_xticklabels([duty_lab[c] for c in corp], fontsize=8)
    ax.set_ylabel("sessions held, n_max (log)")
    ax.set_title("(a) sessions held", fontsize=9.5)
    ax.grid(axis="x", visible=False)
    ax.legend(loc="upper left", fontsize=7.5)
    # (b) summed VM memory vs N
    ax = axes[1]
    for arm in ("sbx", "resident-inf"):
        for c, ls in (("E15 default", "-"), ("E16 lowduty", "--")):
            pts = sorted((r[2], r[5]) for r in by_rung if r[0] == c and r[1] == arm)
            ax.plot([a for a, _ in pts], [b for _, b in pts], color=ARM_COLOR[arm], ls=ls, lw=1.8,
                    marker="o", ms=3.5,
                    label="%s, %s" % (ARM_LABEL[arm], "9.5%" if c == "E15 default" else "1.5%"))
            fails = [(r[2], r[5]) for r in by_rung if r[0] == c and r[1] == arm and not r[3]]
            ax.scatter([a for a, _ in fails], [b for _, b in fails], marker="X", s=55,
                       color=ARM_COLOR[arm], edgecolor="white", lw=0.8, zorder=4)
    ax.set_xlabel("concurrent sessions N")
    ax.set_ylabel("VM memory, window mean (GiB)")
    ax.set_title("(b) VM memory vs sessions", fontsize=9.5)
    ax.set_xticks([0, 256, 512, 768, 1024])
    ax.legend(loc="upper left", fontsize=7)
    ax.text(0.98, 0.04, "host RAM: 377 GiB", transform=ax.transAxes, ha="right", fontsize=7.5,
            color="#5f5e5a")
    # (c) memory per session at n_max
    ax = axes[2]
    for j, arm in enumerate(("sbx", "resident-inf")):
        for i, c in enumerate(corp):
            r = next(x for x in dm if x[0] == c and x[2] == arm)
            x = i + (j - 0.5) * (w + 0.03)
            ax.bar([x], [r[8]], width=w, color=ARM_COLOR[arm])
            ax.text(x, r[8] + 2, "%.0f" % r[8], ha="center", va="bottom", fontsize=8)
    ax.set_xticks([0, 1])
    ax.set_xticklabels([duty_lab[c] for c in corp], fontsize=8)
    ax.set_ylabel("VM MiB per session at n_max")
    ax.set_ylim(0, 140)
    ax.set_title("(c) memory per session", fontsize=9.5)
    ax.grid(axis="x", visible=False)
    # (d) calculated memory ceiling: usable host memory / MiB per session
    ax = axes[3]
    for j, arm in enumerate(("sbx", "resident-inf")):
        for i, c in enumerate(corp):
            r = next(x for x in dm if x[0] == c and x[2] == arm)
            ceil = USABLE_GIB * 1024 / r[8]
            x = i + (j - 0.5) * (w + 0.03)
            ax.bar([x], [ceil], width=w, color=ARM_COLOR[arm], alpha=0.55)
            ax.scatter([x], [r[3]], marker="_", s=260, color="#1f1f1d", lw=2, zorder=4)
            ax.text(x, ceil * 1.1, "%s" % format(int(round(ceil, -2)), ","), ha="center",
                    va="bottom", fontsize=8)
    ax.scatter([], [], marker="_", s=200, color="#1f1f1d", lw=2, label="measured n_max")
    ax.set_yscale("log")
    ax.set_ylim(50, 200000)
    ax.set_xticks([0, 1])
    ax.set_xticklabels([duty_lab[c] for c in corp], fontsize=8)
    ax.set_ylabel("sessions (log)")
    ax.set_title("(d) memory ceiling (calculated)", fontsize=9.5)
    ax.grid(axis="x", visible=False)
    ax.legend(loc="upper left", fontsize=7.5)
    fig.tight_layout(w_pad=2.0)
    save_fig(plt, fig, "duty_memory")


def fig_ladder(plt, rows, stag, sha):
    """p95 excess vs N: sealed runs (solid, filled) and staggered / post-seal runs (dashed,
    open). Sealed resident failures are calls cut by the run-end burst (squares)."""
    fig, ax = plt.subplots(figsize=(6.4, 3.6))
    for arm in ("sbx", "resident-inf"):
        sub = sorted((r for r in rows if r[0] == arm and r[2] == 1), key=lambda r: (r[1], r[3]))
        last = {}
        for r in sub:  # counted first seed: the repeat when one exists
            last[r[1]] = r
        xs = sorted(last)
        ax.plot(xs, [last[n][6] for n in xs], color=ARM_COLOR[arm], lw=1.8, marker="o", ms=4,
                label="%s, sealed" % ARM_LABEL[arm])
        ex = [r for r in rows if r[0] == arm and r[2] > 1]
        ax.scatter([r[1] for r in ex], [r[6] for r in ex], s=24, facecolors="white",
                   edgecolors=ARM_COLOR[arm], lw=1.2, zorder=3)
        fcalls = [r for r in rows if r[0] == arm and not r[4] and r[8] > 0]
        ax.scatter([r[1] for r in fcalls], [r[6] for r in fcalls], s=52, marker="s",
                   facecolors="white", edgecolors=ARM_COLOR[arm], lw=1.6, zorder=4)
        st = {}
        for r in sorted((r for r in stag if r[0] == arm and r[2] == 1), key=lambda r: (r[1], r[3])):
            st[r[1]] = r
        if st:
            xs2 = sorted(st)
            lab = "staggered end-sessions" if arm == "resident-inf" else "post-seal extension"
            ax.plot(xs2, [st[n][7] for n in xs2], color=ARM_COLOR[arm], lw=1.4, ls="--",
                    marker="D", ms=4, mfc="white", label="%s, %s" % (ARM_LABEL[arm], lab))
        ax.axhline(sub[0][7], color=ARM_COLOR[arm], lw=0.9, ls=":")
    ax.set_xlabel("sessions N")
    ax.set_ylabel("p95 excess latency (ms)")
    ax.set_xticks([256, 512, 768, 1024, 1280, 1536])
    ax.set_ylim(0, 450)
    ax.scatter([], [], s=24, facecolors="white", edgecolors="#5f5e5a", lw=1.2, label="seed 2 / 3")
    ax.scatter([], [], s=52, marker="s", facecolors="white", edgecolors="#5f5e5a", lw=1.6,
               label="failed: calls cut by run-end burst")
    ax.legend(loc="lower right", fontsize=6.8, ncol=1)
    ax.set_title("E16 lowduty, 1.5%% duty (final @%s); dotted: each arm's limit" % sha, fontsize=9)
    save_fig(plt, fig, "e16_ladder")


def fig_vm_age(plt, L, E, sha):
    """Resident VM memory against VM age: it levels off near 150 MiB, far from 1 GiB."""
    fig, ax = plt.subplots(figsize=(5.8, 3.3))
    col = ARM_COLOR["resident-inf"]
    for d, ls, lab in ((L, "-", "E16 long rung, N=256, 3 h"), (E, "--", "E15 metal ladder rungs")):
        pts = [(b, m, q) for b, m, q in zip(d["bins_min"], d["median_mib"], d["p95_mib"])
               if m is not None]
        ax.plot([b for b, _, _ in pts], [m for _, m, _ in pts], color=col, ls=ls, lw=1.8,
                label="%s, median" % lab)
        if ls == "-":
            ax.fill_between([b for b, _, _ in pts], [m for _, m, _ in pts],
                            [q for _, _, q in pts], color=col, alpha=0.15, lw=0,
                            label="E16 long rung, median to p95")
    ax.axhline(GUEST_MIB, color="#5f5e5a", lw=0.9, ls=":")
    ax.text(185, GUEST_MIB * 0.93, "guest RAM 1024 MiB", ha="right", va="top", fontsize=7.5,
            color="#5f5e5a")
    ax.set_xlabel("VM age (min)")
    ax.set_ylabel("VM memory (MiB)")
    ax.set_ylim(0, 1100)
    ax.set_xlim(0, 190)
    ax.legend(loc="center right", fontsize=7.5)
    ax.set_title("Resident VM memory vs age (final @%s)" % sha, fontsize=9.5)
    save_fig(plt, fig, "e16_vm_age")


def main():
    lk = lock()
    sha_m, sha_e = lk["metal"]["commit"][:7], lk["e16"]["commit"][:7]
    rep = band_table()
    rows, _ = e16_rows(sha_e)
    stag = stag_rows(sha_e)
    end_sessions(rows, sha_e)
    readings(sha_e)
    L, E = vm_age_table(sha_e)
    lad = e16_ladders(sha_e)
    dm = duty_memory(lad, rep, sha_m, sha_e)
    by_rung = memory_by_rung(lad, sha_m, sha_e)
    plt = setup_matplotlib()
    fig_ladder(plt, rows, stag, sha_e)
    fig_vm_age(plt, L, E, sha_e)
    fig_duty(plt, dm, by_rung, sha_e)


if __name__ == "__main__":
    main()
