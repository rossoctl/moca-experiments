#!/usr/bin/env python3
"""Expected concurrency of heavy calls when N sessions are replayed together
(PROMPT §3, fifth bullet).

Emulates the driver's draw (experiments/e15-session-density/driver/corpus.go Sampler, replay.go Run):
  - sessions with >= 3 calls, shuffled with a seeded PRNG, drawn without
    replacement (reshuffled on exhaustion);
  - per-user cap: a user already holding floor(0.15 * N) (min 1) live
    sessions is skipped;
  - each session starts at a uniform random call index in [0, len - 3];
  - slot k's first session starts at spread * k / (N - 1), spread = 60 s;
  - a slot draws its next session as soon as the current one ends;
  - closed loop inside a session, with no backend delay: a call is emitted at
    max(previous emit + offset_ms, previous end), and runs for dur_ms
    (driver runCall is synchronous, so overlapping recorded calls serialise).
A call's CPU-carrying part is [emit, emit + work_ms]. Heavy = work_ms > 10 s.

It does NOT reproduce Go's math/rand stream: the same seed does not give the
driver's exact sessions. It gives the distribution over 20 seeds, which is what
"expected" asks for. The measured window is [warm-up, warm-up + 900 s]; the
warm-up is 600 s (AWS) and 1200 s (metal, SPEC §13 2026-11-04 revision).
"""
import argparse
import math
import os
import random
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import CAT, load_corpus, setup_matplotlib, save_fig, write_table

HEAVY_MS = 10_000
USER_CAP = 0.15
SPREAD_MS = 60_000
WINDOW_MS = 900_000
NS = [8, 16, 80, 96]
SEEDS = list(range(1, 21))


class Sampler:
    def __init__(self, sessions, seed):
        self.sessions = [s for s in sessions if len(s["calls"]) >= 3]
        self.rng = random.Random(seed)
        self.pool = list(range(len(self.sessions)))
        self.rng.shuffle(self.pool)
        self.drawn = []

    def next(self, live, n):
        limit = max(1, int(math.floor(USER_CAP * n + 1e-9)))

        def pick():
            for p, idx in enumerate(self.pool):
                if live.get(self.sessions[idx]["user"], 0) < limit:
                    return p
            return -1
        p = pick()
        if p < 0:
            self.pool += self.drawn
            self.drawn = []
            self.rng.shuffle(self.pool)
            p = pick()
        idx = self.pool.pop(p)
        self.drawn.append(idx)
        s = self.sessions[idx]
        return s, self.rng.randrange(len(s["calls"]) - 3 + 1)


def simulate(sessions, n, seed, warm_ms):
    """Per-ms counts over the window of running heavy work, and of any running call."""
    end_ms = warm_ms + WINDOW_MS
    smp = Sampler(sessions, seed)
    live = {}
    # Event list: (time, +1/-1) for heavy work and for any call's lifetime, window-clipped.
    heavy_ev = np.zeros(WINDOW_MS + 1, dtype=np.int32)
    any_ev = np.zeros(WINDOW_MS + 1, dtype=np.int32)
    heavy_calls = win_calls = 0
    # Slots run in parallel; they only interact through `live`. Process them in
    # time order of session starts so the user cap sees the right live set.
    import heapq
    heap = []  # (next session start time, slot, prev session or None)
    for k in range(n):
        at = SPREAD_MS * k // (n - 1) if n > 1 else 0
        heapq.heappush(heap, (at, k, None))
    while heap:
        t, k, prev = heapq.heappop(heap)
        if prev is not None:
            live[prev["user"]] -= 1
        if t >= end_ms:
            continue
        s, start = smp.next(live, n)
        live[s["user"]] = live.get(s["user"], 0) + 1
        emit = t
        prev_emit = prev_end = None
        cut = False
        for c in s["calls"][start:]:
            if prev_emit is not None:
                emit = max(prev_emit + c["offset_ms"], prev_end)
            if emit >= end_ms:
                cut = True  # the run ended inside this session: the slot is done
                break
            cend = emit + c["dur_ms"]
            wend = emit + c["work_ms"]
            for ev, a, b in ((any_ev, emit, cend), (heavy_ev, emit, wend) if c["work_ms"] > HEAVY_MS
                             else (None, 0, 0)):
                if ev is None:
                    continue
                a2, b2 = max(a, warm_ms) - warm_ms, min(b, end_ms) - warm_ms
                if b2 > a2:
                    ev[a2] += 1
                    ev[b2] -= 1
            if warm_ms <= emit < end_ms:
                win_calls += 1
                heavy_calls += c["work_ms"] > HEAVY_MS
            prev_emit, prev_end = emit, cend
        # The session ends at its last call's end; a session cut by the run's end
        # frees its slot at end_ms, so no successor is drawn (replay.go runSlot).
        nxt = end_ms if cut or prev_end is None else prev_end
        heapq.heappush(heap, (nxt, k, s))
    return np.cumsum(heavy_ev)[:-1], np.cumsum(any_ev)[:-1], heavy_calls, win_calls


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--point", default="default")
    a = ap.parse_args()
    sessions = load_corpus(a.point)
    rows = []
    curves = {}
    for host, warm in (("aws", 600_000), ("metal", 1_200_000)):
        for n in NS:
            means, p95s, maxs, anymean, frac_ge4, hcalls, wcalls = [], [], [], [], [], [], []
            hist = np.zeros(64)
            for seed in SEEDS:
                h, anyc, hc, wc = simulate(sessions, n, seed, warm)
                wcalls.append(wc)
                means.append(h.mean())
                p95s.append(np.percentile(h, 95))
                maxs.append(h.max())
                anymean.append(anyc.mean())
                frac_ge4.append((h >= 4).mean())
                hcalls.append(hc)
                hist += np.bincount(np.minimum(h, 63), minlength=64)[:64]
            curves[(host, n)] = hist / hist.sum()
            rows.append([host, n, len(SEEDS),
                         round(float(np.mean(means)), 2), round(float(np.mean(p95s)), 1),
                         round(float(np.mean(maxs)), 1), int(np.max(maxs)),
                         round(100 * float(np.mean(frac_ge4)), 1),
                         round(float(np.mean(anymean)), 2), round(float(np.mean(hcalls)), 1),
                         round(float(np.mean(wcalls)), 0),
                         "%d–%d" % (np.percentile(wcalls, 10), np.percentile(wcalls, 90))])
            print(host, n, rows[-1][3:])
    suffix = "" if a.point == "default" else "_" + a.point.replace("-", "_")
    write_table("overlap_heavy" + suffix,
                ["host warm-up", "N", "seeds", "mean heavy running", "p95 heavy running",
                 "max heavy (mean over seeds)", "max heavy (any seed)",
                 "time with >= 4 heavy %", "mean calls running", "heavy calls started in window",
                 "calls in window (mean)", "calls in window (p10–p90)"],
                rows)
    if a.point != "default":
        return
    plt = setup_matplotlib()
    fig, ax = plt.subplots(figsize=(5.4, 3.2))
    for i, n in enumerate(NS):
        p = curves[("aws", n)]
        ccdf = 1 - np.cumsum(p)
        xs = np.arange(len(p))
        keep = ccdf > 1e-5
        ax.step(xs[keep], 100 * ccdf[keep], where="post", color=CAT[i], lw=1.6, label="N = %d" % n)
    ax.axvline(4, color="#9a9a94", lw=0.8, ls=":")
    ax.text(4.2, 45, "4 vCPU\n(AWS)", fontsize=7, color="#5f5e5a")
    ax.set_xlabel("heavy calls (work > 10 s) running at once")
    ax.set_ylabel("share of window time with more (%)")
    ax.set_xlim(0, 20)
    ax.legend()
    ax.set_title("Heavy-call concurrency in the window (default corpus, 20 seeds)")
    save_fig(plt, fig, "overlap_heavy_ccdf")


if __name__ == "__main__":
    main()
