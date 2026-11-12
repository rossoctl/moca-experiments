#!/usr/bin/env python3
"""Per-session trace statistics for each corpus point (PROMPT §3, first bullet).

Per session: span, calls, calls/s, duty cycle (share of session time with at
least one command running, and work_ms / span), idle-gap distribution, and how
much of the span the H cap removed. Aggregated per point and provider; the
per-session rows for every point go to sessions_per_point.csv.

Timeline model (extract.py timeline()): each call runs [emit, emit + dur_ms],
emits placed by cumulative offset_ms from the previous emit. Session time runs
from the first emit to the last call's end. "Busy" is the union of running
intervals; "work" is the sum of work_ms. A gap capped at H reads exactly
H*1000 ms in gap_ms, so capped gaps are counted per session that way; the time
the cap removed is only known in total (corpus-report.json gap_capped_ms).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import (CAT, POINTS, PROVIDERS, load_corpus, load_report, setup_matplotlib,
                    save_fig, write_table, quantile, pct)

H_MS = {"default": 1_800_000, "short": 300_000, "long": 7_200_000,
        "no-infra": 1_800_000, "no-chains": 1_800_000}


def session_stats(calls):
    """(span_ms, busy_union_ms, work_ms, n_calls, n_capped_gaps) on the replay timeline."""
    emit, start, end, busy = 0, None, None, 0
    work = n_capped = 0
    H = None
    for c in calls:
        emit += c["offset_ms"]
        cend = emit + c["dur_ms"]
        if start is None:
            start, end = emit, cend
        elif emit > end:
            busy += end - start
            start, end = emit, cend
        else:
            end = max(end, cend)
        work += c["work_ms"]
    busy += end - start
    return end, busy, work, len(calls), n_capped


def main():
    plt = setup_matplotlib()
    per_session = []
    summary = []
    gap_samples = {}      # point -> list of gap_ms
    duty_by_point = {}    # point -> list of per-session duty cycle

    for point in POINTS:
        H = H_MS[point]
        report = load_report(point)
        corpus = load_corpus(point)
        # span on the recorded (H-capped) timeline, and the time the cap removed
        # in total; per-session removed time is not recoverable from the corpus.
        removed_ms = report["gap_capped_ms"]
        tot_span = tot_busy = tot_work = tot_calls = 0.0
        gaps, duty = [], []
        for s in corpus:
            span, busy, work, n, n_capped = session_stats(s["calls"])
            capped = sum(1 for c in s["calls"] if c["gap_ms"] >= H)
            per_session.append([point, s["provider"], s["session"], n,
                                round(span / 60000.0, 2), round(busy / span, 4) if span else None,
                                round(work / span, 4) if span else None,
                                capped])
            tot_span += span
            tot_busy += busy
            tot_work += work
            tot_calls += n
            gaps.extend(c["gap_ms"] for c in s["calls"])
            if span:
                duty.append(busy / span)
        gap_samples[point] = gaps
        duty_by_point[point] = duty
        span_wo_cap = tot_span + removed_ms
        summary.append([point, report["H_s"], len(corpus),
                        pct(sum(1 for s in corpus if s["provider"] == "claude") / len(corpus)),
                        round(tot_span / 60000.0 / len(corpus), 1),
                        pct(tot_busy / tot_span, 2), pct(tot_work / tot_span, 2),
                        round(tot_calls / (tot_span / 1000.0), 5),
                        report["gap_capped"],
                        round(removed_ms / 3_600_000.0, 1),
                        pct(removed_ms / span_wo_cap, 2),
                        round(quantile(gaps, 0.50) / 1000.0, 1),
                        round(quantile(gaps, 0.95) / 1000.0, 1),
                        round(report["table"]["held_t300_pct"], 1)])

        # per provider for this point
        for prov in PROVIDERS:
            ss = [s for s in corpus if s["provider"] == prov]
            if not ss:
                continue
            rows = [session_stats(s["calls"]) for s in ss]
            span = sum(r[0] for r in rows)
            busy = sum(r[1] for r in rows)
            work = sum(r[2] for r in rows)
            calls = sum(r[3] for r in rows)
            summary.append(["  %s / %s" % (point, prov), report["H_s"], len(ss), "",
                            round(span / 60000.0 / len(ss), 1),
                            pct(busy / span, 2) if span else None,
                            pct(work / span, 2) if span else None,
                            round(calls / (span / 1000.0), 5), "", "", "", "", "", ""])

    write_table("sessions_summary",
                ["point", "H_s", "sessions", "claude %", "mean span min", "duty cycle %",
                 "work % of span", "calls/s per session", "gaps capped",
                 "time removed by cap h", "removed % of uncapped span",
                 "gap p50 s", "gap p95 s", "held at T300 %"],
                summary)
    write_table("sessions_per_point",
                ["point", "provider", "session", "calls", "span_min", "duty_cycle",
                 "work_share", "capped_gaps"],
                per_session)

    # Figure 1: duty-cycle distribution per point (ECDF, x in %).
    fig, ax = plt.subplots(figsize=(5.2, 3.2))
    for i, point in enumerate(POINTS):
        d = sorted(100.0 * x for x in duty_by_point[point])
        ax.plot(d, [100.0 * (j + 1) / len(d) for j in range(len(d))],
                color=CAT[i], lw=1.6, label=point.replace("-", " "))
    ax.set_xlabel("duty cycle (% of session time a command runs)")
    ax.set_ylabel("sessions (%)")
    ax.set_xscale("log")
    ax.legend(loc="upper left")
    ax.set_title("Duty cycle per session, by point")
    save_fig(plt, fig, "sessions_duty_cycle")

    # Figure 2: idle-gap CCDF (log-log), per point.
    fig, ax = plt.subplots(figsize=(5.2, 3.2))
    for i, point in enumerate(POINTS):
        g = sorted(x / 1000.0 for x in gap_samples[point])
        ccdf = [1.0 - (j + 1) / len(g) for j in range(len(g))]
        ax.plot(g, ccdf, color=CAT[i], lw=1.6, label=point.replace("-", " "))
    for point in ("short", "default", "long"):
        ax.axvline(H_MS[point] / 1000.0, color="#9a9a94", lw=0.8, ls=":")
    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlabel("idle gap to next call (s, capped at H)")
    ax.set_ylabel("P(gap ≥ x)")
    ax.legend()
    ax.set_title("Idle-gap distribution, by point")
    save_fig(plt, fig, "sessions_gap_ccdf")
    print("done")


if __name__ == "__main__":
    main()
