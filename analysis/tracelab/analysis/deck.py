#!/usr/bin/env python3
"""Summary deck: out/e15-tracelab-summary.pptx (one chart per slide, 16:9).

Reads only out/tables/*.csv (run the other analysis scripts first) and
data/results-lock.json. Charts are drawn with matplotlib at slide size
into out/deck/ and placed with python-pptx; each slide carries a
one-line takeaway title and a source footer. E15 and E16 are both final.
"""
import csv
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import ARM_COLOR, ARM_LABEL, CAT, OUT_TAB, ROOT, setup_matplotlib
from notes import NOTES

from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.util import Emu, Inches, Pt

OUT = os.path.join(ROOT, "out")
IMG = os.path.join(OUT, "deck")
INK, INK2, MUTED, RULE = "#1f1f1d", "#5f5e5a", "#8a8984", "#e6e6e3"
TIER_COL = {"light": "#9ec5f4", "medium": "#3987e5", "heavy": "#104281"}  # blue ramp 200/400/650
PROV = {"claude": "#6250d6", "codex": "#e87ba4"}                          # violet / magenta
W, H = 13.333, 7.5  # inches, 16:9


def table(name):
    with open(os.path.join(OUT_TAB, name + ".csv")) as f:
        return list(csv.DictReader(f))


def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def rgb(h):
    h = h.lstrip("#")
    return RGBColor(int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))


def style(ax):
    ax.tick_params(colors=INK2, labelsize=11)
    ax.xaxis.label.set_color(INK2)
    ax.yaxis.label.set_color(INK2)
    ax.xaxis.label.set_size(12)
    ax.yaxis.label.set_size(12)
    for s in ("left", "bottom"):
        ax.spines[s].set_color("#b5b4ae")


def save(plt, fig, name):
    os.makedirs(IMG, exist_ok=True)
    p = os.path.join(IMG, name + ".png")
    fig.savefig(p, dpi=200, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    return p


# ---------------------------------------------------------------- charts

def chart_kpis(plt):
    """Slide 2 hero numbers: not a chart, a row of stat tiles."""
    return None


def chart_duty(plt):
    rows = [r for r in table("sessions_summary") if not r["point"].startswith(" ")]
    prov = {r["point"].strip(): r for r in table("sessions_summary") if r["point"].startswith(" ")}
    fig, ax = plt.subplots(figsize=(11.6, 4.6))
    pts = [r["point"] for r in rows]
    x = range(len(pts))
    w = 0.36
    for j, p in enumerate(("claude", "codex")):
        vals = [num(prov["%s / %s" % (pt, p)]["duty cycle %"]) for pt in pts]
        xs = [i + (j - 0.5) * (w + 0.03) for i in x]
        ax.bar(xs, vals, width=w, color=PROV[p], label=p.capitalize())
        for xx, v in zip(xs, vals):
            ax.text(xx, v + 0.5, "%.1f%%" % v, ha="center", va="bottom", fontsize=11, color=INK)
    ax.set_xticks(list(x))
    ax.set_xticklabels(["%s\nH = %s s\nall sessions %.1f%%" % (r["point"], r["H_s"],
                        num(r["duty cycle %"])) for r in rows], fontsize=11)
    ax.set_ylabel("share of session time a command runs (%)")
    ax.set_ylim(0, 36)
    ax.grid(axis="x", visible=False)
    ax.legend(loc="upper right", fontsize=11, ncol=2)
    style(ax)
    return save(plt, fig, "duty")


def chart_tiers(plt):
    rows = {(r["cuts"].split()[0], r["provider"]): r for r in table("tiers_sensitivity")}
    fig, axes = plt.subplots(1, 2, figsize=(11.6, 4.6), gridspec_kw={"width_ratios": [1.15, 1]})
    # left: calls vs work, 100% stacked, main cuts, per provider + all
    ax = axes[0]
    groups = [("all", "all calls"), ("claude", "Claude"), ("codex", "Codex")]
    ylab = []
    y = 0
    for key, lab in groups:
        r = rows[("main", key)]
        for measure in ("work", "calls"):
            left = 0
            for t in ("light", "medium", "heavy"):
                v = num(r["%s %s %%" % (t, measure)])
                ax.barh(y, v, left=left, color=TIER_COL[t], height=0.72,
                        edgecolor="white", linewidth=2,
                        label=t if (key == "all" and measure == "work") else None)
                if v >= 5:
                    ax.text(left + v / 2, y, "%.0f%%" % v, ha="center", va="center", fontsize=10.5,
                            color="white" if t != "light" else INK)
                left += v
            ylab.append("%s · %s" % (lab, "share of work" if measure == "work" else "share of calls"))
            y += 1
        y += 0.5
    ys = [0, 1, 2.5, 3.5, 5, 6]
    ax.set_yticks(ys)
    ax.set_yticklabels(ylab, fontsize=10.5)
    ax.invert_yaxis()
    ax.set_xlim(0, 100)
    ax.set_xlabel("%")
    ax.grid(axis="y", visible=False)
    ax.legend(ncol=3, loc="lower center", bbox_to_anchor=(0.45, 1.0), fontsize=10.5,
              title="tier by work_ms: light < 1 s · medium 1–10 s · heavy > 10 s",
              title_fontsize=10)
    style(ax)
    # right: sensitivity of the heavy share of work
    ax = axes[1]
    cuts = [("low", "0.5 / 5 s"), ("main", "1 / 10 s"), ("high", "2 / 20 s")]
    for j, (key, lab) in enumerate(groups):
        vals = [num(rows[(c, key)]["heavy work %"]) for c, _ in cuts]
        col = {"all": INK, "claude": PROV["claude"], "codex": PROV["codex"]}[key]
        ax.plot(range(3), vals, color=col, lw=2.2, marker="o", ms=7, label=lab)
        ax.text(2.08, vals[-1], "%s %.0f%%" % (lab, vals[-1]), va="center", fontsize=10.5, color=INK)
    ax.set_xticks(range(3))
    ax.set_xticklabels([l for _, l in cuts], fontsize=11)
    ax.set_xlim(-0.2, 2.9)
    ax.set_ylim(55, 100)
    ax.set_xlabel("tier cut points (light|medium, medium|heavy)")
    ax.set_ylabel("heavy calls' share of work (%)")
    ax.set_title("sensitivity: heavy share of work", fontsize=11.5, color=INK2)
    style(ax)
    fig.tight_layout(w_pad=3)
    return save(plt, fig, "tiers")


def chart_classes(plt):
    rows = table("tiers_by_class")[:10]
    fig, ax = plt.subplots(figsize=(11.6, 4.7))
    labels = [r["class"] for r in rows][::-1]
    work = [num(r["work % of all"]) for r in rows][::-1]
    calls = [num(r["calls % of all"]) for r in rows][::-1]
    y = range(len(labels))
    h = 0.38
    ax.barh([i + h / 2 + 0.01 for i in y], work, height=h, color="#104281", label="share of work")
    ax.barh([i - h / 2 - 0.01 for i in y], calls, height=h, color="#9ec5f4", label="share of calls")
    for i, (wv, cv) in enumerate(zip(work, calls)):
        ax.text(wv + 0.4, i + h / 2, "%.1f%%" % wv, va="center", fontsize=10, color=INK)
        ax.text(cv + 0.4, i - h / 2, "%.1f%%" % cv, va="center", fontsize=10, color=INK2)
    ax.set_yticks(list(y))
    ax.set_yticklabels(labels, fontsize=11)
    ax.set_xlabel("% of all replayed calls / work (default corpus)")
    ax.grid(axis="y", visible=False)
    ax.legend(loc="lower right", fontsize=11)
    ax.set_xlim(0, 46)
    style(ax)
    return save(plt, fig, "classes")


def chart_turns(plt):
    d = table("turns_size_distribution_corpus")
    t = {(r["scope"], r["provider"]): r for r in table("turns_shell_calls")}
    fig, axes = plt.subplots(1, 2, figsize=(11.6, 4.6), gridspec_kw={"width_ratios": [1.6, 1]})
    ax = axes[0]
    ks = list(range(1, 9))
    w = 0.38
    for j, p in enumerate(("claude", "codex")):
        tot = sum(num(r["calls"]) for r in d if r["provider"] == p)
        vals = [100 * sum(num(r["calls"]) for r in d if r["provider"] == p and int(r["shell calls in turn (8 = 8+)"]) == k) / tot for k in ks]
        xs = [k + (j - 0.5) * (w + 0.03) for k in ks]
        ax.bar(xs, vals, width=w, color=PROV[p], label=p.capitalize())
        for xx, v in zip(xs, vals):
            if v >= 1:
                ax.text(xx, v + 1, "%.0f" % v, ha="center", va="bottom", fontsize=10, color=INK)
    ax.set_xticks(ks)
    ax.set_xticklabels([str(k) for k in ks[:-1]] + ["8+"], fontsize=11)
    ax.set_xlabel("shell calls in the same LLM turn")
    ax.set_ylabel("share of the provider's shell calls (%)")
    ax.set_ylim(0, 100)
    ax.grid(axis="x", visible=False)
    ax.legend(fontsize=11)
    style(ax)
    # right: three key ratios as labelled dots
    ax = axes[1]
    metrics = [("calls per turn", "calls per turn", 1, "%.2f"),
               ("calls in turns with >= 2 %", "calls sharing a turn", 100, "%.0f%%"),
               ("same-turn overlap % of pairs", "same-turn pairs overlapping", 100, "%.0f%%")]
    for i, (col, lab, scale, fmt) in enumerate(metrics):
        for p in ("claude", "codex"):
            v = num(t[("corpus", p)][col])
            frac = (v - 1) / 1.0 if scale == 1 else v / 100.0
            ax.scatter([frac], [i], s=140, color=PROV[p], zorder=3, edgecolor="white", lw=1.5)
            ax.text(frac, i - 0.28, fmt % v, ha="center", fontsize=10.5, color=INK)
        ax.plot([0, 1], [i, i], color=RULE, lw=6, solid_capstyle="round", zorder=1)
    ax.set_yticks(range(3))
    ax.set_yticklabels([m[1] for m in metrics], fontsize=11)
    ax.set_ylim(2.6, -0.6)
    ax.set_xlim(-0.08, 1.08)
    ax.set_xticks([])
    ax.spines["bottom"].set_visible(False)
    ax.spines["left"].set_visible(False)
    ax.tick_params(left=False)
    ax.grid(False)
    ax.set_title("calls/turn on 1→2; shares on 0→100%", fontsize=10, color=MUTED)
    style(ax)
    fig.tight_layout(w_pad=3)
    return save(plt, fig, "turns")


def chart_overlap(plt):
    rows = [r for r in table("overlap_heavy") if r["host warm-up"] == "aws"]
    fig, ax = plt.subplots(figsize=(11.6, 4.6))
    ns = [int(r["N"]) for r in rows]
    x = range(len(ns))
    mean = [num(r["mean heavy running"]) for r in rows]
    p95 = [num(r["p95 heavy running"]) for r in rows]
    mx = [num(r["max heavy (mean over seeds)"]) for r in rows]
    w = 0.26
    for j, (vals, lab, col) in enumerate([(mean, "mean", "#9ec5f4"), (p95, "p95", "#3987e5"),
                                          (mx, "max (seed mean)", "#104281")]):
        xs = [i + (j - 1) * (w + 0.02) for i in x]
        ax.bar(xs, vals, width=w, color=col, label=lab)
        for xx, v in zip(xs, vals):
            ax.text(xx, v + 0.25, "%.1f" % v, ha="center", va="bottom", fontsize=10, color=INK)
    ax.axhline(4, color=CAT[7], lw=1.6, ls="--")
    ax.text(-0.45, 4.3, "AWS host: 4 vCPU", ha="left", va="bottom", fontsize=11, color=INK)
    ax.set_xticks(list(x))
    ax.set_xticklabels(["N = %d\n≥ 4 heavy for %s%%\nof the window" % (n, r["time with >= 4 heavy %"])
                        for n, r in zip(ns, rows)], fontsize=11)
    ax.set_ylim(0, 17)
    ax.legend(loc="upper left", bbox_to_anchor=(0.0, 0.92), fontsize=11)
    ax.set_ylabel("heavy calls (work > 10 s) running at once")
    ax.grid(axis="x", visible=False)
    style(ax)
    return save(plt, fig, "overlap")


def counted_rows():
    """{(host, arm, N): row} of rungs_all, default point, the run each ladder counted."""
    from rungs import ladder_kinds
    lk = ladder_kinds()
    rank = {"first": 0, "repeat": 1, "k2": 1, "repeat-k2": 2}
    by = {}
    for r in table("rungs_all"):
        if r["point"] != "default" or r["run"] not in rank:
            continue
        k = (r["host"], r["arm"], int(r["N"]))
        want = lk.get((r["host"], "default", r["arm"], int(r["N"])))
        if want is not None:
            if r["run"] == want:
                by[k] = r
        elif k not in by or rank[r["run"]] > rank[by[k]["run"]]:
            by[k] = r
    return by


def chart_ladder(plt, sha):
    by = counted_rows()
    fig, axes = plt.subplots(1, 2, figsize=(11.6, 4.7), gridspec_kw={"width_ratios": [1, 2.2]})
    for ax, host in zip(axes, ("aws", "metal")):
        for arm in ("sbx", "resident-inf", "resident-300"):
            pts = sorted((n, r) for (h, a, n), r in by.items() if h == host and a == arm
                         and num(r["p95 excess ms"]) is not None)
            if not pts:
                continue
            xs = [n for n, _ in pts]
            ys = [num(r["p95 excess ms"]) for _, r in pts]
            ax.plot(xs, ys, color=ARM_COLOR[arm], lw=2.2, marker="o", ms=6, label=ARM_LABEL[arm])
            fails = [(n, num(r["p95 excess ms"])) for n, r in pts
                     if r["holds"] == "False" and num(r["failed calls"]) == 0]
            if fails:
                ax.scatter([a for a, _ in fails], [b for _, b in fails], s=150, marker="X",
                           color=ARM_COLOR[arm], edgecolor="white", lw=1.2, zorder=4)
            lim = num(pts[-1][1]["limit ms"])
            ax.axhline(lim, color=ARM_COLOR[arm], lw=1.1, ls="--", alpha=0.85)
        ax.set_yscale("log")
        ax.set_xlabel("concurrent sessions N")
        ax.set_xticks([8, 16] if host == "aws" else [8, 32, 64, 96, 128, 160])
        ax.set_title("AWS · 4 vCPU nested" if host == "aws"
                     else "metal · 96 vCPU (final @%s)" % sha, fontsize=12, color=INK)
        style(ax)
    axes[0].set_ylabel("p95 excess latency (ms, log)")
    axes[0].set_ylim(40, 30000)
    axes[1].set_ylim(40, 30000)
    axes[1].legend(loc="upper left", fontsize=11)
    fig.text(0.5, -0.03, "Dashed: each arm's primary limit max(3B, 50 ms). ✕: first failed rung "
             "(every one failed on the latency tail, with 0 failed calls).",
             ha="center", fontsize=10.5, color=INK2)
    fig.tight_layout(w_pad=2)
    return save(plt, fig, "ladder")


def chart_nmax(plt, sha):
    lad = {(r["host"], r["point"], r["arm"]): r for r in table("ladders")}
    fig, axes = plt.subplots(1, 2, figsize=(11.6, 4.5), gridspec_kw={"width_ratios": [2.4, 1]})
    ax = axes[0]
    pts = ["default", "short", "long", "no-infra", "no-chains", "mem512"]
    arms = ["sbx", "resident-inf", "resident-300"]
    w = 0.26
    for j, arm in enumerate(arms):
        xs, vals, labels = [], [], []
        for i, p in enumerate(pts):
            r = lad.get(("aws", p, arm))
            if not r:
                continue
            xs.append(i + (j - 1) * (w + 0.02))
            vals.append(num(r["n_max (sealed)"]))
            labels.append(r["n_max first-run only"])
        ax.bar(xs, vals, width=w, color=ARM_COLOR[arm], label=ARM_LABEL[arm])
        for xx, v, fr in zip(xs, vals, labels):
            ax.text(xx, v + 0.4, "%d" % v, ha="center", va="bottom", fontsize=10.5, color=INK)
            fv = num(fr.replace("≥", "").strip())
            if fv is not None and fv != v:
                ax.scatter([xx], [fv], marker="D", s=80, facecolors="white",
                           edgecolors=INK, lw=1.6, zorder=5)
                ax.text(xx, fv + 1.1, ("≥ %d" if "≥" in fr else "%d") % fv, ha="center",
                        va="bottom", fontsize=10, color=INK, zorder=6,
                        bbox=dict(boxstyle="round,pad=0.15", fc="white", ec="none"))
    ax.scatter([], [], marker="D", s=80, facecolors="white", edgecolors=INK, lw=1.6,
               label="first run only, where it differs")
    ax.set_xticks(range(len(pts)))
    ax.set_xticklabels(pts, fontsize=11)
    ax.set_ylabel("n_max (sessions held, sealed)")
    ax.set_ylim(0, 31)
    ax.grid(axis="x", visible=False)
    ax.legend(loc="upper left", fontsize=10.5)
    ax.set_title("AWS preliminary · every point", fontsize=12, color=INK)
    style(ax)
    ax = axes[1]
    supp = {r["arm"]: r for r in table("metal_supplementary")}
    arms3 = ["sbx", "resident-inf", "resident-300"]
    for j, arm in enumerate(arms3):
        v = num(lad[("metal", "default", arm)]["n_max (sealed)"])
        ax.bar([j], [v], width=0.6, color=ARM_COLOR[arm])
        ax.text(j, v * 1.1, "%d" % v, ha="center", va="bottom", fontsize=11, color=INK)
        for key, mk, lab in (("n_max_1s (supp.)", "o", "1 s limit"),
                             ("n_max_cpu (supp.)", "^", "conditions 1–3 only")):
            sv = num(supp[arm][key])
            ax.scatter([j], [sv], marker=mk, s=70, facecolors="white", edgecolors=INK, lw=1.5,
                       zorder=4, label=lab if j == 0 else None)
            ax.text(j + 0.2, sv, "%d" % sv, va="center", fontsize=9.5, color=INK2)
    ax.set_yscale("log")
    ax.set_ylim(40, 900)
    ax.set_xticks(range(3))
    ax.set_xticklabels(["SBX", "resident ∞", "resident\n300 s"], fontsize=10.5)
    ax.grid(axis="x", visible=False)
    ax.legend(loc="upper left", fontsize=9, title="supplementary (not sealed)", title_fontsize=9)
    ax.set_title("metal · default (final @%s)" % sha, fontsize=12, color=INK)
    style(ax)
    fig.tight_layout(w_pad=3)
    return save(plt, fig, "nmax")


def chart_hosts(plt):
    rows = table("aws_vs_metal")
    ov = {(r["host"], r["point"], r["arm"]): r for r in table("n1_overhead")}
    fig, axes = plt.subplots(1, 2, figsize=(11.6, 4.5))
    ax = axes[0]
    sel = [r for r in rows if r["N"] in ("8", "16")]
    labels, a, m = [], [], []
    for r in sel:
        labels.append("%s\nN = %s" % (ARM_LABEL[r["arm"]], r["N"]))
        a.append(num(r["AWS p95 excess ms"]))
        m.append(num(r["metal p95 excess ms"]))
    x = range(len(sel))
    w = 0.38
    ax.bar([i - w / 2 - 0.01 for i in x], a, width=w, color="#86b6ef", label="AWS (nested)")
    ax.bar([i + w / 2 + 0.01 for i in x], m, width=w, color="#104281", label="metal")
    for i, (av, mv) in enumerate(zip(a, m)):
        ax.text(i - w / 2, av * 1.08, "%s" % format(int(round(av)), ","), ha="center", fontsize=10, color=INK)
        ax.text(i + w / 2, mv * 1.08, "%d" % mv, ha="center", fontsize=10, color=INK)
    ax.set_yscale("log")
    ax.set_ylim(50, 40000)
    ax.set_xticks(list(x))
    ax.set_xticklabels(labels, fontsize=10.5)
    ax.set_ylabel("p95 excess latency (ms, log)")
    ax.grid(axis="x", visible=False)
    ax.legend(loc="upper left", fontsize=10.5)
    ax.set_title("same rung, two hosts (default point)", fontsize=12, color=INK)
    style(ax)
    ax = axes[1]
    items = [("default", "sbx"), ("default", "resident-inf"), ("mem512", "sbx"), ("mem512", "resident-inf")]
    labels = ["SBX", "resident ∞", "SBX\nmem512", "resident ∞\nmem512"]
    x = range(len(items))
    for hj, (host, col) in enumerate((("aws", "#86b6ef"), ("metal", "#104281"))):
        vals = [num(ov[(host, p, arm)]["N=1 overhead ms/call"]) for p, arm in items]
        xs = [i + (hj - 0.5) * (w + 0.02) for i in x]
        ax.bar(xs, vals, width=w, color=col, label="AWS" if host == "aws" else "metal")
        for xx, v in zip(xs, vals):
            ax.text(xx, v + (40 if v >= 0 else -40), "%+.0f" % v, ha="center",
                    va="bottom" if v >= 0 else "top", fontsize=10, color=INK)
    ax.axhline(0, color="#b5b4ae", lw=1)
    ax.set_xticks(list(x))
    ax.set_xticklabels(labels, fontsize=10.5)
    ax.set_ylabel("added ms per call at N = 1")
    ax.set_ylim(-250, 1800)
    ax.grid(axis="x", visible=False)
    ax.set_title("per-call overhead at N = 1", fontsize=12, color=INK)
    style(ax)
    fig.tight_layout(w_pad=3)
    return save(plt, fig, "hosts")


def chart_e16_ladder(plt, sha):
    rows = table("e16_rungs")
    fig, ax = plt.subplots(figsize=(11.6, 4.6))
    for arm in ("sbx", "resident-inf"):
        s1 = {}
        for r in rows:
            if r["arm"] == arm and r["seed"] == "1":
                if int(r["N"]) not in s1 or r["run"] == "repeat":
                    s1[int(r["N"])] = r
        xs = sorted(s1)
        ax.plot(xs, [num(s1[n]["p95 excess ms"]) for n in xs], color=ARM_COLOR[arm], lw=2.4,
                marker="o", ms=7, label="%s, seed 1" % ARM_LABEL[arm])
        ex = [r for r in rows if r["arm"] == arm and r["seed"] != "1"]
        ok = [r for r in ex if r["holds"] == "True"]
        ax.scatter([int(r["N"]) for r in ok], [num(r["p95 excess ms"]) for r in ok], s=80,
                   facecolors="white", edgecolors=ARM_COLOR[arm], lw=2, zorder=4)
        bad = [r for r in rows if r["arm"] == arm and r["holds"] == "False"]
        ax.scatter([int(r["N"]) for r in bad], [num(r["p95 excess ms"]) for r in bad], s=90,
                   marker="s", facecolors="white", edgecolors=ARM_COLOR[arm], lw=2.2, zorder=5)
        lim = num(rows[[r["arm"] for r in rows].index(arm)]["limit ms"])
        ax.axhline(lim, color=ARM_COLOR[arm], lw=1.2, ls="--")
        ax.text(1575, lim + 6, "%s limit %.0f ms" % (ARM_LABEL[arm], lim), ha="right",
                va="bottom", fontsize=10, color=INK2)
    stag = table("e16_stag")
    for arm in ("sbx", "resident-inf"):
        st = {}
        for r in stag:
            if r["arm"] == arm and r["seed"] == "1":
                if int(r["N"]) not in st or r["run"] == "repeat":
                    st[int(r["N"])] = r
        if st:
            xs = sorted(st)
            ax.plot(xs, [num(st[n]["p95 excess ms"]) for n in xs], color=ARM_COLOR[arm], lw=1.8,
                    ls="--", marker="D", ms=6, mfc="white",
                    label="%s, %s" % (ARM_LABEL[arm], "staggered end-sessions" if arm ==
                                      "resident-inf" else "post-seal extension"))
    ax.scatter([], [], s=80, facecolors="white", edgecolors=INK2, lw=2, label="seed 2 / 3, held")
    ax.scatter([], [], s=90, marker="s", facecolors="white", edgecolors=INK2, lw=2.2,
               label="failed: calls cut by the run-end burst")
    ax.set_xticks([256, 512, 768, 1024, 1280, 1536])
    ax.set_xlim(220, 1580)
    ax.set_ylim(0, 450)
    ax.set_xlabel("concurrent sessions N")
    ax.set_ylabel("p95 excess latency (ms)")
    ax.legend(loc="lower right", fontsize=9.5, ncol=2)
    style(ax)
    return save(plt, fig, "e16_ladder")


def chart_duty_memory(plt):
    """Slide-size version of out/figures/duty_memory.png (analysis/e16.py)."""
    dm = table("duty_memory")
    br = table("duty_memory_by_rung")
    corp = ["E15 default", "E16 lowduty"]
    lab = {"E15 default": "9.5% duty\nE15", "E16 lowduty": "1.5% duty\nE16"}
    fig, axes = plt.subplots(1, 3, figsize=(12.4, 4.9), gridspec_kw={"width_ratios": [1, 1.45, 1.35]})
    w = 0.36
    ax = axes[0]
    for j, arm in enumerate(("sbx", "resident-inf")):
        for i, c in enumerate(corp):
            r = next(x for x in dm if x["corpus"] == c and x["arm"] == arm)
            v = num(r["n_max"])
            x = i + (j - 0.5) * (w + 0.03)
            cen = c == "E16 lowduty" and arm == "sbx"  # SBX never failed: a lower bound
            ax.bar([x], [v], width=w, color=ARM_COLOR[arm], hatch="///" if cen else None,
                   edgecolor="white", lw=0, label=ARM_LABEL[arm] if i == 0 else None)
            ax.text(x, v * 1.1, ("≥%s" % format(int(v), ",")) if cen else "%d" % v,
                    ha="center", va="bottom", fontsize=9.5 if cen else 10.5, color=INK)
    ax.set_yscale("log")
    ax.set_ylim(30, 40000)
    ax.set_xticks([0, 1])
    ax.set_xticklabels([lab[c] for c in corp], fontsize=10.5)
    ax.set_ylabel("sessions held, n_max (log)")
    ax.set_title("sessions held", fontsize=12, color=INK)
    ax.grid(axis="x", visible=False)
    from matplotlib.patches import Patch as _P
    h, l = ax.get_legend_handles_labels()
    h.append(_P(facecolor="white", edgecolor=INK2, hatch="///", lw=0.8))
    l.append("lower bound (SBX incl.\npost-seal rungs)")
    ax.legend(h, l, loc="upper left", fontsize=9.5)
    style(ax)
    ax = axes[1]
    for arm in ("sbx", "resident-inf"):
        for c, ls, dl in (("E15 default", "-", "9.5%"), ("E16 lowduty", "--", "1.5%")):
            pts = sorted((int(r["N"]), num(r["VM memory mean GiB"])) for r in br
                         if r["corpus"] == c and r["arm"] == arm)
            ax.plot([a for a, _ in pts], [b for _, b in pts], color=ARM_COLOR[arm], ls=ls, lw=2.2,
                    marker="o", ms=4.5, label="%s · %s duty" % (ARM_LABEL[arm], dl))
    ax.set_xlabel("concurrent sessions N")
    ax.set_ylabel("VM memory, window mean (GiB)")
    ax.set_title("VM memory grows with N for resident only", fontsize=12, color=INK)
    ax.set_xticks([0, 256, 512, 768, 1024, 1280, 1536])
    ax.legend(loc="upper left", fontsize=9.5)
    ax.text(0.98, 0.20, "host RAM 377 GiB\nresident at N = 1,024: 98 GiB (26%)",
            transform=ax.transAxes, ha="right", va="bottom", fontsize=9.5, color=INK2)
    style(ax)
    ax = axes[2]
    from matplotlib.patches import Patch
    short = {"sbx": "SBX", "resident-inf": "resident ∞"}
    ticks, ticklabels = [], []
    for j, arm in enumerate(("sbx", "resident-inf")):
        for i, c in enumerate(corp):
            r = next(x for x in dm if x["corpus"] == c and x["arm"] == arm)
            ceil = num(r["memory ceiling, sessions (373 GiB / MiB per session)"])
            per = num(r["VM MiB per session (mean)"])
            n = num(r["n_max"])
            x = i + (j - 0.5) * (w + 0.04)
            ticks.append(x)
            ticklabels.append(short[arm])
            ax.bar([x], [ceil], width=w, color=ARM_COLOR[arm], alpha=0.45)
            # the ceiling and the memory rate it comes from, above the bar
            ax.text(x, ceil * 1.12, "%s\n%.0f MiB/sess." % (
                format(int(round(ceil, -2)), ","), per), ha="center", va="bottom",
                fontsize=8.5, color=INK, linespacing=1.1)
            # measured n_max: a dark dash across the bar, its value just above
            ax.plot([x - w / 2, x + w / 2], [n, n], color=INK, lw=2.8, zorder=4)
            ax.text(x, n * 1.13, ("held\n≥%s" if c == "E16 lowduty" and arm == "sbx" else "held\n%s")
                    % format(int(n), ","), ha="center", va="bottom", fontsize=8.5, color=INK,
                    zorder=5, linespacing=1.05)
    ax.set_xticks(ticks)
    ax.set_xticklabels(ticklabels, fontsize=9.5)
    for i, c in enumerate(corp):
        ax.annotate(lab[c], xy=(i, 0), xycoords=("data", "axes fraction"), xytext=(0, -30),
                    textcoords="offset points", ha="center", va="top", fontsize=10.5,
                    color=INK2)
    ax.legend(handles=[
        Patch(facecolor="#9a9a94", alpha=0.45, label="memory ceiling\n= 373 GiB ÷ MiB per session"),
        plt.Line2D([], [], color=INK, lw=2.8, label="sessions actually held (n_max)")],
        loc="upper left", fontsize=8.5)
    ax.set_yscale("log")
    ax.set_ylim(50, 2000000)
    ax.set_ylabel("sessions (log)")
    ax.set_title("memory ceiling vs sessions held", fontsize=12, color=INK)
    ax.grid(axis="x", visible=False)
    style(ax)
    fig.tight_layout(w_pad=2.5)
    return save(plt, fig, "duty_memory")


def chart_binding(plt):
    """What binds before memory: each limit as % of its own ceiling at the last held rung."""
    rows = table("binding_by_rung")
    picks = []
    for exp, lab in (("E15 metal default", "9.5% duty"), ("E16 lowduty", "1.5% duty")):
        for arm in ("sbx", "resident-inf"):
            sub = sorted((r for r in rows if r["experiment"] == exp and r["arm"] == arm),
                         key=lambda r: int(r["N"]))
            last = None
            for r in sub:
                if r["holds"] != "True":
                    break
                last = r
            picks.append((exp, lab, arm, last))
    cands = [("latency: p95 excess % of limit", "latency tail\n(p95 ÷ limit)"),
             ("host CPU p95 %", "host CPU\n(p95 of 96 vCPU)"),
             ("memory used % (1 − MemAvailable min)", "memory\n(used of 377 GiB)"),
             ("disk read p95 % of max", "disk read\n(p95 ÷ 1,017 MB/s)"),
             ("Execs % of 320", "worker Execs\n(peak ÷ 320)")]
    fig, ax = plt.subplots(figsize=(11.8, 4.7))
    w = 0.19
    for j, (exp, lab, arm, r) in enumerate(picks):
        vals = [num(r[k]) or 0 for k, _ in cands]
        xs = [i + (j - 1.5) * (w + 0.012) for i in range(len(cands))]
        e15 = exp.startswith("E15")
        ax.bar(xs, vals, width=w, color=ARM_COLOR[arm], alpha=1.0 if e15 else 0.55,
               hatch=None if e15 else "///", edgecolor="white", lw=0,
               label="%s · %s · last hold N = %s" % (ARM_LABEL[arm], lab,
                                                     format(int(r["N"]), ",")))
        for x, v in zip(xs, vals):
            ax.text(x, v + 1.5, "%.0f" % v, ha="center", va="bottom", fontsize=9, color=INK)
    ax.axhline(100, color=INK, lw=1.4, ls="--")
    ax.text(4.55, 102, "ceiling (100%)", ha="right", va="bottom", fontsize=10, color=INK)
    ax.set_xticks(range(len(cands)))
    ax.set_xticklabels([c[1] for c in cands], fontsize=10.5)
    ax.set_ylabel("% of its own ceiling")
    ax.set_ylim(0, 112)
    ax.grid(axis="x", visible=False)
    ax.legend(fontsize=9.5, loc="upper center", bbox_to_anchor=(0.62, 0.9), ncol=2,
              frameon=True, facecolor="white", edgecolor="none")
    style(ax)
    return save(plt, fig, "binding")


def chart_coldstart(plt):
    """Cold start: per-call overhead at N = 1, and long-call slowdown at equal N."""
    cs = {(r["experiment"], r["arm"]): r for r in table("cold_start")}
    sl = table("slowdown_long")
    fig, axes = plt.subplots(1, 2, figsize=(11.8, 4.6), gridspec_kw={"width_ratios": [1, 1.25]})
    ax = axes[0]
    groups = [("E15 metal default", "9.5% duty"), ("E16 lowduty", "1.5% duty"),
              ("E15 metal mem512", "mem512\n(512 MiB dataset)")]
    w = 0.36
    for j, arm in enumerate(("sbx", "resident-inf")):
        xs, vals = [], []
        for i, (exp, _) in enumerate(groups):
            r = cs.get((exp, arm))
            if not r:
                continue
            xs.append(i + (j - 0.5) * (w + 0.03))
            vals.append(num(r["N=1 overhead ms/call"]))
        ax.bar(xs, vals, width=w, color=ARM_COLOR[arm], label=ARM_LABEL[arm])
        for x, v in zip(xs, vals):
            ax.text(x, v + (12 if v >= 0 else -12), "%+.0f" % v, ha="center",
                    va="bottom" if v >= 0 else "top", fontsize=10, color=INK)
    ax.axhline(0, color="#b5b4ae", lw=1)
    ax.set_xticks(range(len(groups)))
    ax.set_xticklabels([g[1] for g in groups], fontsize=10.5)
    ax.set_ylabel("added ms per call at N = 1")
    ax.set_ylim(-140, 460)
    ax.grid(axis="x", visible=False)
    ax.legend(loc="upper left", fontsize=10)
    ax.set_title("cold start: per-call overhead (metal)", fontsize=12, color=INK)
    style(ax)
    ax = axes[1]
    for arm in ("sbx", "resident-inf", "resident-300"):
        pts = sorted((int(r["N"]), num(r["slowdown p50"])) for r in sl
                     if r["experiment"] == "E15 metal default" and r["arm"] == arm)
        if pts:
            ax.plot([a for a, _ in pts], [100 * (b - 1) for _, b in pts], color=ARM_COLOR[arm],
                    lw=2.2, marker="o", ms=5, label=ARM_LABEL[arm])
    ax.axhline(0, color="#b5b4ae", lw=1)
    ax.set_xlabel("concurrent sessions N (E15 metal, 9.5% duty)")
    ax.set_ylabel("long calls (≥ 30 s): median slowdown (%)")
    ax.set_title("long calls run slower in SBX at equal N", fontsize=12, color=INK)
    ax.legend(loc="upper left", fontsize=10)
    style(ax)
    fig.tight_layout(w_pad=3)
    return save(plt, fig, "coldstart")


def chart_perf(plt):
    """Host counters at equal N on metal: SBX vs resident (E15 climb, RESULTS-METAL.md)."""
    pf = table("perf_e15_climb")
    fig, axes = plt.subplots(1, 3, figsize=(11.8, 4.2))
    specs = [("LLC miss %", "LLC miss rate (%)"), ("IPC", "instructions per cycle"),
             ("turbo", "clock vs base (aperf/mperf)")]
    for ax, (k, lab) in zip(axes, specs):
        for arm in ("sbx", "resident-inf", "resident-300"):
            pts = sorted((int(r["N"]), num(r[k])) for r in pf if r["arm"] == arm)
            if pts:
                ax.plot([a for a, _ in pts], [b for _, b in pts], color=ARM_COLOR[arm], lw=2.2,
                        marker="o", ms=5, label=ARM_LABEL[arm])
        ax.set_xlabel("sessions N (E15 metal climb rungs)")
        ax.set_title(lab, fontsize=12, color=INK)
        style(ax)
    axes[0].set_ylim(0, 12)
    axes[1].set_ylim(3, 5)
    axes[2].set_ylim(1.2, 1.6)
    axes[0].legend(loc="lower right", fontsize=9.5)
    fig.tight_layout(w_pad=2.5)
    return save(plt, fig, "perf")


def chart_summary(plt):
    """Everything learned: n_max per experiment and arm, with what stopped each."""
    lad = {(r["host"], r["point"], r["arm"]): r for r in table("ladders")}
    rd = table("e16_readings")
    sealed = rd[0]
    stag = rd[2]
    rows = [
        ("E15 · AWS nested · 9.5% duty", [("sbx", 8, ""), ("resident-inf", 8, ""),
                                          ("resident-300", 8, "")], "latency tail (4 vCPU queueing)"),
        ("E15 · metal · 9.5% duty", [("sbx", num(lad[("metal", "default", "sbx")]["n_max (sealed)"]), ""),
                                     ("resident-inf", num(lad[("metal", "default", "resident-inf")]["n_max (sealed)"]), ""),
                                     ("resident-300", num(lad[("metal", "default", "resident-300")]["n_max (sealed)"]), "")],
         "latency tail (long calls a few % slow)"),
        ("E15 · metal · mem512", [("sbx", num(lad[("metal", "mem512", "sbx")]["n_max (sealed)"]), ""),
                                  ("resident-inf", num(lad[("metal", "mem512", "resident-inf")]["n_max (sealed)"]), "")],
         "latency tail (cold first scans)"),
        ("E16 · metal · 1.5% duty (sealed)", [("sbx", 1024, "≥"), ("resident-inf", 1024, "")],
         "SBX censored; resident: run-end burst"),
        ("E16 · metal · 1.5% duty (staggered)", [("sbx", 1536, "≥"), ("resident-inf", 1536, "≥")],
         "both censored at the ladder top"),
    ]
    fig, ax = plt.subplots(figsize=(11.8, 4.8))
    y = 0
    yt, yl = [], []
    h = 0.24
    for name, arms, why in rows:
        k = len(arms)
        for j, (arm, v, mark) in enumerate(arms):
            yy = y + (j - (k - 1) / 2) * (h + 0.02)
            ax.barh(yy, v, height=h, color=ARM_COLOR[arm], alpha=0.55 if mark else 1.0,
                    hatch="///" if mark else None, edgecolor="white", lw=0,
                    label=ARM_LABEL[arm] if y == 0 else None)
            ax.text(v * 1.08, yy, "%s%s" % (mark, format(int(v), ",")), va="center",
                    fontsize=10, color=INK)
        ax.text(9000, y, why, va="center", ha="left", fontsize=10, color=INK2)
        yt.append(y)
        yl.append(name)
        y += 1
    ax.set_yticks(yt)
    ax.set_yticklabels(yl, fontsize=10.5)
    ax.invert_yaxis()
    ax.set_xscale("log")
    ax.set_xlim(1, 9000)
    ax.set_xlabel("sessions held, n_max (log; hatched = lower bound, no rung failed)")
    ax.grid(axis="y", visible=False)
    ax.legend(loc="lower left", bbox_to_anchor=(0.0, 1.01), fontsize=10, ncol=3, frameon=False)
    ax.text(9000, -0.75, "what stopped it", ha="left", fontsize=10.5, color=INK, fontweight="bold")
    style(ax)
    fig.subplots_adjust(right=0.72)
    return save(plt, fig, "summary")


def chart_vm_age(plt):
    """Resident VM memory against VM age (E16 long rung, 3 h window)."""
    rows = [r for r in table("e16_vm_age") if r["source"].startswith("E16 long rung")]
    rows.sort(key=lambda r: num(r["VM age min"]))
    xs = [num(r["VM age min"]) for r in rows]
    med = [num(r["median MiB"]) for r in rows]
    p95 = [num(r["p95 MiB"]) for r in rows]
    fig, ax = plt.subplots(figsize=(11.8, 4.5))
    ax.fill_between(xs, med, p95, color=ARM_COLOR["resident-inf"], alpha=0.18, lw=0,
                    label="median to p95")
    ax.plot(xs, med, color=ARM_COLOR["resident-inf"], lw=2.6, marker="o", ms=4,
            label="median VM")
    ax.plot(xs, p95, color=ARM_COLOR["resident-inf"], lw=1.2, ls="--", label="p95 VM")
    for x in (0, 20, 60, 120, 180):
        i = min(range(len(xs)), key=lambda k: abs(xs[k] - x))
        ax.annotate("%.0f MiB" % med[i], (xs[i], med[i]),
                    xytext=(14, -6) if x == 0 else (0, -20), textcoords="offset points",
                    ha="left" if x == 0 else "center", fontsize=10, color=INK)
    ax.set_xlabel("VM age (minutes)")
    ax.set_ylabel("VM memory (MiB)")
    ax.set_xlim(-3, 190)
    ax.set_ylim(0, 260)
    ax.set_xticks([0, 20, 40, 60, 90, 120, 150, 180])
    ax.legend(loc="lower right", fontsize=10.5)
    style(ax)
    return save(plt, fig, "vm_age")


def chart_rung(plt):
    """Timeline of one rung: spread, warm-up, measured window, grace."""
    fig, ax = plt.subplots(figsize=(11.8, 2.6))
    segs = [(0, 60, "spread\n60 s", "#cde2fb"), (60, 1200, "warm-up (not measured)\n"
            "600 s AWS · 1,200 s metal · 2,400 s on a drift repeat", "#9ec5f4"),
            (1200, 2100, "measured window\n900 s", "#2a78d6"),
            (2100, 2400, "grace\n300 s", "#e6e6e3")]
    for a, b, lab, col in segs:
        ax.barh(0, b - a, left=a, height=0.55, color=col, edgecolor="white", lw=2)
        ax.text((a + b) / 2, 0, lab, ha="center", va="center", fontsize=10,
                color="white" if col == "#2a78d6" else INK)
    for x, lab in ((0, "t0: N slots start, each at a random\ncall index of a drawn session"),
                   (1200, "sessions keep running;\nonly calls sent here are judged"),
                   (2100, "no new calls; in-flight calls\nfinish, end-sessions sent")):
        ax.annotate(lab, (x, 0.3), xytext=(x + 15, 0.62), fontsize=9.5, color=INK2,
                    arrowprops=dict(arrowstyle="-", color="#b5b4ae"))
    ax.set_xlim(-20, 2420)
    ax.set_ylim(-0.45, 1.1)
    ax.set_yticks([])
    ax.set_xlabel("seconds from the rung's start (metal timings)")
    for sp in ("left",):
        ax.spines[sp].set_visible(False)
    ax.grid(False)
    style(ax)
    return save(plt, fig, "rung")


# ---------------------------------------------------------------- slides

def add_text(slide, x, y, w, h, text, size, color=INK, bold=False):
    tb = slide.shapes.add_textbox(Inches(x), Inches(y), Inches(w), Inches(h))
    tf = tb.text_frame
    tf.word_wrap = True
    lines = text if isinstance(text, list) else [text]
    for i, line in enumerate(lines):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        p.text = line
        p.font.size = Pt(size)
        p.font.color.rgb = rgb(color)
        p.font.bold = bold
        p.font.name = "Helvetica Neue"
    return tb


def chart_slide(prs, title, sub, img, source, notes=None):
    s = prs.slides.add_slide(prs.slide_layouts[6])
    if notes:
        s.notes_slide.notes_text_frame.text = notes
    add_text(s, 0.6, 0.35, 12.1, 0.7, title, 26, INK, bold=True)
    add_text(s, 0.6, 1.02, 12.1, 0.5, sub, 14, INK2)
    pic = s.shapes.add_picture(img, Inches(0.6), Inches(1.65), width=Inches(12.1))
    if pic.height > Inches(5.15):  # keep the footer clear
        ratio = Inches(5.15) / pic.height
        pic.height = Inches(5.15)
        pic.width = Emu(int(pic.width * ratio))
        pic.left = Emu(int((Inches(W) - pic.width) / 2))
    add_text(s, 0.6, 6.95, 12.1, 0.35, source, 9.5, MUTED)
    return s


def text_slide(prs, title, sub, notes):
    s = prs.slides.add_slide(prs.slide_layouts[6])
    s.notes_slide.notes_text_frame.text = notes
    add_text(s, 0.6, 0.35, 12.1, 0.7, title, 26, INK, bold=True)
    if sub:
        add_text(s, 0.6, 1.02, 12.1, 0.5, sub, 14, INK2)
    return s


def tile(slide, x, y, value, label, note):
    box = slide.shapes.add_shape(1, Inches(x), Inches(y), Inches(2.85), Inches(2.3))
    box.fill.solid()
    box.fill.fore_color.rgb = rgb("#f4f4f1")
    box.line.fill.background()
    add_text(slide, x + 0.22, y + 0.2, 2.5, 0.9, value, 38, INK, bold=True)
    add_text(slide, x + 0.22, y + 1.1, 2.5, 0.5, label, 13, INK)
    add_text(slide, x + 0.22, y + 1.6, 2.5, 0.6, note, 10.5, INK2)


def main():
    with open(os.path.join(ROOT, "data", "results-lock.json")) as f:
        lk = json.load(f)
    sha_m, sha_a, sha_e = (lk["metal"]["commit"][:7], lk["aws"]["commit"][:7],
                           lk["e16"]["commit"][:7])
    plt = setup_matplotlib()
    plt.rcParams.update({"font.size": 11})
    trace_src = ("Source: TraceLab v0.0.2 (uw-syfi/TraceLab, CC BY 4.0) via the E15 replay corpora; "
                 "tracelab/out/tables/%s.csv")
    run_src = ("Source: rossoctl/moca-experiments experiments/e15-session-density/results — AWS @%s, metal @%s (both final); "
               "tracelab/out/tables/%%s.csv" % (sha_a, sha_m))
    e16_src = ("Source: rossoctl/moca-experiments experiments/e16-low-duty/results @%s (final) and "
               "experiments/e15-session-density/results metal @%s; tracelab/out/tables/%%s.csv" % (sha_e, sha_m))

    prs = Presentation()
    prs.slide_width, prs.slide_height = Inches(W), Inches(H)
    N = NOTES

    # ---- 1. title ----
    s = prs.slides.add_slide(prs.slide_layouts[6])
    s.notes_slide.notes_text_frame.text = N["title"]
    add_text(s, 0.8, 2.0, 11.7, 1.2, "E15 + E16 · Sessions per host on replayed coding-agent traces",
             32, INK, bold=True)
    add_text(s, 0.8, 3.3, 11.7, 1.2,
             ["SBX (fresh microVM per command) vs resident microVMs (one VM per session)",
              "Method, trace analysis, final E15 and E16 results, what binds, what we learned"],
             17, INK2)
    add_text(s, 0.8, 5.4, 11.7, 1.2,
             ["E15 · AWS m8i.xlarge (4 vCPU, nested), final @%s" % sha_a,
              "E15 · AWS m7i.metal-24xl (96 vCPU, bare metal), final @%s" % sha_m,
              "E16 · same metal host, 1.5%% duty-cycle sessions, final @%s" % sha_e],
             12, MUTED)

    # ---- 2. headline ----
    sess = {r["point"]: r for r in table("sessions_summary")}
    tiers = {(r["cuts"].split()[0], r["provider"]): r for r in table("tiers_sensitivity")}
    lad = {(r["host"], r["point"], r["arm"]): r for r in table("ladders")}
    ov = {(r["host"], r["point"], r["arm"]): r for r in table("n1_overhead")}
    s = text_slide(prs, "Resident is never behind SBX; the latency tail binds first",
                   "Four numbers that frame the results", N["headline"])
    tile(s, 0.6, 1.9, "%s%%" % sess["default"]["duty cycle %"], "of session time busy",
         "full corpus (gaps ≤ 30 min); Claude 3.8%, Codex 19.2%")
    tile(s, 3.65, 1.9, "%.1f%%" % num(tiers[("main", "all")]["heavy calls %"]),
         "of calls are heavy (> 10 s)",
         "they carry %s%% of all work" % tiers[("main", "all")]["heavy work %"])
    tile(s, 6.7, 1.9, "%s / %s" % (lad[("metal", "default", "sbx")]["n_max (sealed)"],
                                   lad[("metal", "default", "resident-inf")]["n_max (sealed)"]),
         "E15 metal n_max (SBX / res. ∞)", "9.5% duty; AWS nested tied 8 / 8")
    tile(s, 9.75, 1.9, "≥1,024", "E16 n_max, both arms", "1.5% duty; ≥ 1,536 with the "
         "run-end burst removed")
    add_text(s, 0.6, 4.65, 12.1, 2.0, [
        "• Every E15 first failure was the p95 latency tail, with 0 failed calls and the host "
        "≤ 13% busy.",
        "• SBX per-call overhead at N = 1: %+.0f ms (AWS nested) → %+.0f ms (metal)."
        % (num(ov[("aws", "default", "sbx")]["N=1 overhead ms/call"]),
           num(ov[("metal", "default", "sbx")]["N=1 overhead ms/call"])),
        "• At 1.5% duty the arms do not separate; memory never binds up to 1,536 sessions."],
        14, INK)
    add_text(s, 0.6, 6.95, 12.1, 0.35, "Source: tracelab/out/tables (sessions_summary, "
             "tiers_sensitivity, ladders, n1_overhead, e16_ladders, e16_readings).", 9.5, MUTED)

    # ---- 3–5. methodology ----
    s = text_slide(prs, "Method · a real workload, replayed without an LLM",
                   "TraceLab v0.0.2 sessions → replay corpus → Go driver → three sandbox arms",
                   N["method_overview"])
    add_text(s, 0.6, 1.75, 5.9, 4.9, [
        "Workload",
        "• TraceLab v0.0.2: 8,058 Claude Code and Codex sessions, 52 developers (CC BY 4.0).",
        "• Extractor keeps the shell-type calls: class, recorded run time, idle gap to the next "
        "call. Gaps capped at H = 30 min; Codex polled commands collapsed into one call.",
        "• Sessions with < 20 calls dropped → 4,147 sessions (E15 default corpus).",
        "",
        "Driver (no model, no agent)",
        "• Closed loop per session: send a call, wait for it, sleep the recorded gap.",
        "• Each call runs a real command of its class (pytest, python, git, grep…) sized to the "
        "recorded duration.",
        "• Same seed → same command stream."], 13, INK)
    add_text(s, 6.9, 1.75, 5.8, 4.9, [
        "Arms (same Firecracker build, guest image, 1 GiB guest RAM)",
        "• SBX: stock moca, a fresh microVM per command (2 warm standbys).",
        "• resident ∞: one VM per session, for its whole life.",
        "• resident 300 s: VM reclaimed after 5 idle minutes (E15 only).",
        "• control: no sandbox, measures the driver (< 1% of host CPU).",
        "",
        "Hosts",
        "• AWS m8i.xlarge: 4 vCPU, 15.7 GiB, nested KVM (preliminary).",
        "• AWS m7i.metal-24xl: 96 vCPU, 377 GiB, bare metal (E15 metal, E16).",
        "• moca's memory admission set never to bind: the host is measured, not the policy."],
        13, INK)
    add_text(s, 0.6, 6.95, 12.1, 0.35, "Source: experiments/e15-session-density/SPEC.md §3–§7, experiments/e16-low-duty/SPEC.md §4–§5 "
             "(rossoctl/moca-experiments).", 9.5, MUTED)

    s = text_slide(prs, "Method · calibrate, then seal the predictions before any rung",
                   "Calibration fixes each arm's latency limit; predictions are committed before "
                   "the first measured rung and never edited", N["method_calibration"])
    add_text(s, 0.6, 1.75, 5.9, 4.9, [
        "Calibration (once per host)",
        "• Time every command of the library 5× inside a VM.",
        "• Each arm at N = 1 over several seeds: per-call overhead, pace.",
        "• Per-class probe: each class alone, 20 calls → its median added latency.",
        "• B = p95 of each call's excess over its class median at N = 1.",
        "• Limit = max(3 × B, 50 ms); absolute verdict B + 250 ms.",
        "• Control at N = 128: driver < 1% of host CPU."], 13, INK)
    add_text(s, 6.9, 1.75, 5.8, 4.9, [
        "Sealed predictions",
        "• Written from calibration, each with what would falsify it.",
        "• Committed before the first rung: E15 AWS 708d62f, E15 metal 3d653a2, E16 d7271aa.",
        "• Never changed afterwards; results are reported against them.",
        "",
        "Supplementary readings",
        "• Anything decided after seeing data: the 1 s limit, conditions 1–3 only, the "
        "post-seal SBX extension, staggered end-sessions, no-wedge re-judges.",
        "• Reported beside the verdict, never as the verdict."], 13, INK)
    add_text(s, 0.6, 6.95, 12.1, 0.35, "Source: experiments/e15-session-density/SPEC.md §8, §10.1, §11; "
             "experiments/e15-session-density/predictions*.json; experiments/e16-low-duty/predictions.json.", 9.5, MUTED)

    chart_slide(prs, "Method · how one rung runs",
                "N slots, warm-up, a 15-minute measured window, four conditions; the ladder "
                "stops at the first failed rung",
                chart_rung(plt), "Source: experiments/e15-session-density/SPEC.md §5.7, §8, §10.2, §13; experiments/e16-low-duty/SPEC.md §8. "
                "Holds = no failed call · no refusal · class pace ≤ 10% · p95 excess ≤ limit.",
                notes=N["method_rung"])

    # ---- trace analysis ----
    chart_slide(prs, "Commands run in under a tenth of session time",
                "Busy share per corpus variant; Codex sessions are ~5× busier than Claude's",
                chart_duty(plt), trace_src % "sessions_summary", notes=N["duty"])
    chart_slide(prs, "7% of calls carry 87% of the work",
                "Weight tiers by work_ms; the concentration holds under 0.5/5 s and 2/20 s cuts",
                chart_tiers(plt), trace_src % "tiers_sensitivity", notes=N["tiers"])
    chart_slide(prs, "Interpreter and shell-read calls dominate",
                "Top 10 classes by work share; read and write are frequent but light",
                chart_classes(plt), trace_src % "tiers_by_class", notes=N["classes"])
    chart_slide(prs, "At 16 sessions, 4+ heavy calls overlap 2.5% of the time",
                "Replay model of the driver's draw (20 seeds, AWS warm-up); enough to queue on 4 vCPUs",
                chart_overlap(plt), trace_src % "overlap_heavy", notes=N["overlap"])

    # ---- E15 results ----
    chart_slide(prs, "E15 · metal moves the knee from 8–16 to 80 (SBX) and 128 (resident)",
                "p95 excess latency per rung, default point, the run each ladder counted",
                chart_ladder(plt, sha_m), run_src % "rungs_all", notes=N["ladder"])
    chart_slide(prs, "E15 · no host or point shows SBX ahead of a resident arm",
                "Sealed n_max per point and arm (◇ first-run reading where the drift repeat changed it); "
                "metal adds the supplementary 1 s and conditions 1–3 readings",
                chart_nmax(plt, sha_m), run_src % "ladders", notes=N["nmax"])
    chart_slide(prs, "E15 · metal cuts the tail 5–140× and SBX's overhead 5.5×",
                "Same N on both hosts, and per-call overhead from each arm's N = 1 baseline",
                chart_hosts(plt), run_src % "aws_vs_metal + n1_overhead", notes=N["hosts"])

    # ---- E16 ----
    band = {r["corpus"]: r for r in table("e16_band")}
    lb = band["E16 lowduty (1%, 2%]"]
    s = text_slide(prs, "E16 · does SBX win when sessions are mostly idle?",
                   "Hypothesis (the user's): at a duty cycle of 2% or less, SBX holds more "
                   "concurrent sessions than resident VMs", N["e16_hypothesis"])
    add_text(s, 0.6, 1.75, 5.9, 4.9, [
        "Why it could be true",
        "• A resident VM holds memory for the whole session, busy or idle.",
        "• SBX holds a VM only while a command runs.",
        "• Lower duty raises both latency limits about as 1/duty; resident's memory per "
        "session does not fall.",
        "",
        "How E16 tests it (sealed 2026-11-08)",
        "• E15's metal host and instrument; SBX vs resident ∞ (kept forever).",
        "• Physical memory is the only memory limit (admission 4 TiB, 4,096 runs).",
        "• Ladder 256 → 1,536; deciding rungs re-run with seeds 2 and 3, majority decides.",
        "• Holds only if SBX's n_max is ≥ one ladder step above resident's."], 13, INK)
    add_text(s, 6.9, 1.75, 5.8, 4.9, [
        "Workload: the (1%, 2%] duty band of the E15 corpus",
        "• %s sessions from %s users (E15: 4,147 from 52)." % (lb["sessions"], lb["users"]),
        "• Busy %s%% of session time (E15: %s%%)." % (lb["occupied %"],
                                                     band["E15 default"]["occupied %"]),
        "• %s calls/s per session; mean span %s h." % (lb["calls/s per session"],
                                                        lb["mean span h"]),
        "• Rebuilt here; byte-identical to the rig's corpus (sha256 %s)." % lb["sha256"],
        "",
        "Sealed predictions",
        "• 1. Hypothesis falsified: SBX [576, 768], resident ∞ [768, 1024].",
        "• 2. Both arms fail on the latency tail, host CPU < 25%.",
        "• 3. Resident's VM memory at its n_max < 189 GiB, in [109, 163].",
        "• 4. Driver < 1% of host CPU."], 13, INK)
    add_text(s, 0.6, 6.95, 12.1, 0.35, e16_src % "e16_band" + "; experiments/e16-low-duty/SPEC.md, experiments/e16-low-duty/predictions.json",
             9.5, MUTED)

    chart_slide(prs, "E16 · neither arm fails on latency up to 1,536 sessions",
                "p95 excess per rung at 1.5% duty: sealed (solid) and staggered / post-seal "
                "(dashed). Resident's sealed failures are calls cut by the run-end burst",
                chart_e16_ladder(plt, sha_e), e16_src % "e16_rungs + e16_stag + e16_ladders",
                notes=N["e16_ladder"])
    chart_slide(prs, "E16 · low duty cuts SBX's memory per session, not resident's",
                "At each arm's n_max: sessions held, VM memory against N, and the memory ceiling "
                "(373 GiB ÷ MiB per session)",
                chart_duty_memory(plt), e16_src % "duty_memory + duty_memory_by_rung",
                notes=N["duty_memory"])
    chart_slide(prs, "E16 · a resident VM levels off near 150 MiB after an hour",
                "Resident ∞ VM memory against VM age: one long rung, N = 256, 3-hour window",
                chart_vm_age(plt), e16_src % "e16_vm_age", notes=N["e16_vm_age"])

    rd = table("e16_readings")
    s = text_slide(prs, "E16 verdict: the hypothesis is falsified",
                   "At 1.5% duty SBX does not hold more sessions than resident ∞. Three "
                   "readings, in experiments/e16-low-duty/RESULTS.md's order", N["e16_verdict"])
    add_text(s, 0.6, 1.75, 12.1, 2.6, [
        "• %s: SBX %s vs resident ∞ %s → %s." % (rd[0]["reading"], rd[0]["SBX n_max"],
                                                 rd[0]["resident ∞ n_max"], rd[0]["verdict"]),
        "• %s: SBX %s vs resident ∞ %s → %s. Resident's limit is the run-end burst, "
        "not the host." % (rd[1]["reading"], rd[1]["SBX n_max"], rd[1]["resident ∞ n_max"],
                           rd[1]["verdict"]),
        "• %s: SBX %s vs resident ∞ %s → %s." % (rd[2]["reading"], rd[2]["SBX n_max"],
                                                 rd[2]["resident ∞ n_max"], rd[2]["verdict"])],
        14, INK)
    add_text(s, 0.6, 4.3, 12.1, 2.5, [
        "Sealed predictions",
        "• 1. Direction held (a tie falsifies the hypothesis); SBX's range [576, 768] missed.",
        "• 2. Falsified: resident's first failure was condition 1 (calls cut), not the latency tail.",
        "• 3. Held: resident's VM memory at n_max 106 GiB, below 189 GiB; no memory verdict.",
        "• 4. Held: driver ≤ 0.10% of host CPU."], 13.5, INK)
    add_text(s, 0.6, 6.95, 12.1, 0.35, e16_src % "e16_readings + e16_ladders", 9.5, MUTED)

    es = table("e16_end_sessions")
    s = text_slide(prs, "E16 · what failed the resident runs: a moca worker limit",
                   "The run-end burst of end-session Execs hits the worker's per-connection "
                   "admission — rossoctl/moca#705", N["e16_worker"])
    rows = [r for r in es if r["run"] == "first" and r["seed"] == "1"]
    add_text(s, 0.6, 1.75, 5.8, 4.9, ["Refused end-sessions = N − 320 on every sealed rung"] + [
        "• N = %s: %s refused (N − 320 = %s)" % (r["N"], r["failed"], r["N - 320"]) for r in rows
        if int(r["N"]) <= 896], 13, INK)
    add_text(s, 6.6, 1.75, 6.1, 4.9, [
        "Why",
        "• A worker connection admits 320 Execs: 256 running + 64 queued.",
        "• The rest get \"busy: queue full\", which the worker does not log.",
        "• From N ≈ 900 the refusals and aborts overflow the 16-slot terminal-frame reserve in one "
        "second. The worker drops the connection and 9–24 in-flight calls fail.",
        "• SBX sends no end-sessions, so only resident is hit.",
        "",
        "With end-sessions paced at 50/s after the window: 0 refused, 0 wedges, every rung "
        "holds to 1,536."], 13, INK)
    add_text(s, 0.6, 6.95, 12.1, 0.35, e16_src % "e16_end_sessions", 9.5, MUTED)

    # ---- what binds before memory ----
    bsrc = ("Source: experiments/e15-session-density/results metal @%s and experiments/e16-low-duty/results @%s; tracelab/out/tables/%%s.csv "
            "(analysis/binding.py)" % (sha_m, sha_e))
    chart_slide(prs, "What binds before memory? The latency tail, in both arms",
                "Each limit as % of its own ceiling, at each arm's last held rung on metal",
                chart_binding(plt), bsrc % "binding_by_rung + binding_at_limit",
                notes=N["binding"])
    chart_slide(prs, "Cold start binds SBX through slower long calls, not lifecycle time",
                "Left: per-call overhead at N = 1. Right: long-call slowdown at equal N "
                "(E15 metal, 9.5% duty)",
                chart_coldstart(plt), bsrc % "cold_start + slowdown_long", notes=N["coldstart"])
    chart_slide(prs, "The counters point to cold caches and lower clocks, not saturation",
                "perf on the E15 metal climb rungs (60 s every 5 min): LLC misses, IPC, turbo",
                chart_perf(plt), "Source: experiments/e15-session-density/results/metal/RESULTS-METAL.md @%s; "
                "tracelab/out/tables/perf_e15_climb.csv" % sha_m, notes=N["perf"])

    # ---- summary ----
    chart_slide(prs, "What we learned: resident ≥ SBX everywhere; latency, not memory, decides",
                "n_max per experiment and arm (log), and what stopped each",
                chart_summary(plt), "Source: tracelab/out/tables (ladders, e16_readings, "
                "binding_at_limit); E15 AWS @%s, metal @%s; E16 @%s" % (sha_a, sha_m, sha_e),
                notes=N["summary"])

    # ---- appendix ----
    chart_slide(prs, "Appendix · per-turn bundling has much more to gain on Codex",
                "Shell calls per LLM turn in the E15 corpus sessions (E15b input)",
                chart_turns(plt),
                "Source: TraceLab v0.0.2 DuckDB (CC BY 4.0), copied history removed; "
                "tracelab/out/tables/turns_shell_calls.csv", notes=N["turns"])

    s = text_slide(prs, "Open questions", None, N["open"])
    add_text(s, 0.6, 1.3, 12.1, 5.0, [
        "• E16 is censored at 1,536: neither arm's real limit on this host is known. Above "
        "N ≈ 900 the 456-session band replays each trace 2–3 times (distinct-trace share "
        "0.30–0.49, below SPEC §9's 60%).",
        "• moca#705: log refusals, and keep a refusal burst from dropping unrelated Execs.",
        "• E15b (per-turn bundling) targets SBX's per-command cold state; approved, not run.",
        "• Under moca's default admission (1 GiB per VM) SBX would hold more than resident — a "
        "policy result, not a host result.",
        "• E15b §1.2 absolute turn counts cannot be rebuilt from the DuckDB; the shares agree.",
        "• The overlap model matches measured window call counts within its spread, not Go's "
        "exact draw."], 16, INK)
    add_text(s, 0.6, 6.95, 12.1, 0.35, "Full write-up: tracelab/REPORT.md", 9.5, MUTED)

    path = os.path.join(OUT, "e15-e16-tracelab-summary.pptx")
    prs.save(path)
    print(path, len(prs.slides._sldIdLst), "slides")


if __name__ == "__main__":
    main()
