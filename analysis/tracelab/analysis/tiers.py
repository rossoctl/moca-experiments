#!/usr/bin/env python3
"""Weight tiers and class mix (PROMPT §3, second and third bullets).

Tiers by a call's work_ms (the CPU-carrying part; equals dur_ms except for
Codex polled chains): light < 1 s, medium 1-10 s, heavy > 10 s. The
sensitivity check moves the cuts to 0.5/5 s and 2/20 s.

Per tier: share of calls, share of total work, per class, per provider.
Class mix: share of calls and of work by class, by provider.
Default corpus unless --point is given (mem512 replays default).
"""
import argparse
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import (CAT, PROVIDERS, load_corpus, setup_matplotlib, save_fig, write_table, pct)

CUTS = {"main": (1_000, 10_000), "low": (500, 5_000), "high": (2_000, 20_000)}
TIERS = ["light", "medium", "heavy"]


def tier_of(work_ms, cuts):
    lo, hi = cuts
    if work_ms < lo:
        return "light"
    if work_ms <= hi:
        return "medium"
    return "heavy"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--point", default="default")
    a = ap.parse_args()
    suffix = "" if a.point == "default" else "_" + a.point.replace("-", "_")
    corpus = load_corpus(a.point)
    calls = [(s["provider"], c) for s in corpus for c in s["calls"]]
    n_all = len(calls)
    w_all = float(sum(c["work_ms"] for _, c in calls))

    # 1. Tier shares under each cut set, overall and per provider.
    rows = []
    for name, cuts in CUTS.items():
        for prov in ["all"] + PROVIDERS:
            sub = [c for p, c in calls if prov == "all" or p == prov]
            n = len(sub)
            w = float(sum(c["work_ms"] for c in sub))
            cnt = collections.Counter(tier_of(c["work_ms"], cuts) for c in sub)
            wk = collections.Counter()
            for c in sub:
                wk[tier_of(c["work_ms"], cuts)] += c["work_ms"]
            row = ["%s (%g/%g s)" % (name, cuts[0] / 1000.0, cuts[1] / 1000.0), prov, n]
            for t in TIERS:
                row += [pct(cnt[t] / n, 2), pct(wk[t] / w, 1)]
            rows.append(row)
    hdr = ["cuts", "provider", "calls"]
    for t in TIERS:
        hdr += ["%s calls %%" % t, "%s work %%" % t]
    write_table("tiers_sensitivity" + suffix, hdr, rows)

    # 2. Per class under the main cuts: calls, work, and tier split.
    cuts = CUTS["main"]
    by_cls = collections.defaultdict(list)
    for p, c in calls:
        by_cls[c["class"]].append((p, c))
    rows = []
    for cls in sorted(by_cls, key=lambda k: -sum(c["work_ms"] for _, c in by_cls[k])):
        sub = [c for _, c in by_cls[cls]]
        n = len(sub)
        w = float(sum(c["work_ms"] for c in sub))
        cnt = collections.Counter(tier_of(c["work_ms"], cuts) for c in sub)
        wk = collections.Counter()
        for c in sub:
            wk[tier_of(c["work_ms"], cuts)] += c["work_ms"]
        med = sorted(c["work_ms"] for c in sub)[n // 2]
        row = [cls, n, pct(n / n_all, 2), pct(w / w_all, 2), round(med / 1000.0, 2)]
        for t in TIERS:
            row += [pct(cnt[t] / n, 1), pct(wk[t] / w, 1) if w else None]
        rows.append(row)
    hdr = ["class", "calls", "calls % of all", "work % of all", "median work s"]
    for t in TIERS:
        hdr += ["%s calls %%" % t, "%s work %%" % t]
    write_table("tiers_by_class" + suffix, hdr, rows)

    # 3. Class mix by provider: share of that provider's calls and work.
    rows = []
    for cls in sorted(by_cls, key=lambda k: -sum(c["work_ms"] for _, c in by_cls[k])):
        row = [cls]
        for prov in PROVIDERS:
            pn = sum(1 for p, _ in calls if p == prov)
            pw = float(sum(c["work_ms"] for p, c in calls if p == prov))
            sub = [c for p, c in by_cls[cls] if p == prov]
            row += [pct(len(sub) / pn, 2), pct(sum(c["work_ms"] for c in sub) / pw, 2)]
        rows.append(row)
    write_table("class_mix_by_provider" + suffix,
                ["class", "claude calls %", "claude work %", "codex calls %", "codex work %"],
                rows)

    # 4. Heavy calls: count, share, and the heaviest classes by provider.
    rows = []
    for prov in PROVIDERS:
        heavy = [c for p, c in calls if p == prov and tier_of(c["work_ms"], cuts) == "heavy"]
        cc = collections.Counter(c["class"] for c in heavy)
        chain = sum(1 for c in heavy if c["chain"])
        rows.append([prov, len(heavy), chain,
                     ", ".join("%s %d" % (k, v) for k, v in cc.most_common(5))])
    write_table("tiers_heavy_by_provider" + suffix,
                ["provider", "heavy calls", "of which chains", "top classes (calls)"], rows)

    if a.point != "default":
        return
    # Figure: share of calls vs share of work per tier, per provider (grouped bars,
    # one panel per measure, same y axis 0-100 %).
    plt = setup_matplotlib()
    fig, axes = plt.subplots(1, 2, figsize=(6.6, 2.8), sharey=True)
    width = 0.38
    for k, (measure, title) in enumerate([("calls", "share of calls"), ("work", "share of work")]):
        ax = axes[k]
        for j, prov in enumerate(PROVIDERS):
            sub = [c for p, c in calls if p == prov]
            if measure == "calls":
                tot = float(len(sub))
                vals = [100 * sum(1 for c in sub if tier_of(c["work_ms"], cuts) == t) / tot
                        for t in TIERS]
            else:
                tot = float(sum(c["work_ms"] for c in sub))
                vals = [100 * sum(c["work_ms"] for c in sub if tier_of(c["work_ms"], cuts) == t)
                        / tot for t in TIERS]
            xs = [i + (j - 0.5) * (width + 0.02) for i in range(len(TIERS))]
            ax.bar(xs, vals, width=width, color=CAT[j], label=prov)
            for x, v in zip(xs, vals):
                ax.text(x, v + 1.5, "%.0f" % v, ha="center", va="bottom", fontsize=7,
                        color="#3d3d3a")
        ax.set_xticks(range(len(TIERS)))
        ax.set_xticklabels(["light\n< 1 s", "medium\n1–10 s", "heavy\n> 10 s"])
        ax.set_title(title)
        ax.set_ylim(0, 105)
        ax.grid(axis="x", visible=False)
    axes[0].set_ylabel("% of the provider's total")
    axes[1].legend(loc="upper center")
    fig.suptitle("Weight tiers by work_ms (default corpus)", fontsize=10, y=1.02)
    save_fig(plt, fig, "tiers_calls_vs_work")

    # Figure: class mix, share of work by class and provider (horizontal bars).
    top = sorted(by_cls, key=lambda k: -sum(c["work_ms"] for _, c in by_cls[k]))
    fig, ax = plt.subplots(figsize=(5.6, 4.2))
    ys = list(range(len(top)))[::-1]
    h = 0.38
    for j, prov in enumerate(PROVIDERS):
        pw = float(sum(c["work_ms"] for p, c in calls if p == prov))
        vals = [100 * sum(c["work_ms"] for p, c in by_cls[cls] if p == prov) / pw for cls in top]
        ax.barh([y + (0.5 - j) * (h + 0.02) for y in ys], vals, height=h, color=CAT[j],
                label=prov)
    ax.set_yticks(ys)
    ax.set_yticklabels(top)
    ax.set_xlabel("share of the provider's work (%)")
    ax.grid(axis="y", visible=False)
    ax.legend(loc="lower right")
    ax.set_title("Where the work is, by class (default corpus)")
    save_fig(plt, fig, "class_mix_work")


if __name__ == "__main__":
    main()
