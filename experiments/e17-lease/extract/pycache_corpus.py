#!/usr/bin/env python3
"""E17 pycache corpus generator: synthetic cache-heavy Python sessions in E15's corpus schema.

E17 SPEC §4.2 and §4.3 (v0.4). A session is a loop of turns, each a fixed sequence of calls:
  py_analyze, py_test, py_import, py_grep, py_short x k (2 <= k <= 5, drawn per turn), py_analyze.
Every session has at least --min-turns turns (default 4), so a lease is tested across turns and not
only inside one; the duty fit below adds turns only above that floor.
dur_ms = work_ms are the N = 1 planned durations (py_analyze 15 s, py_test 60 s, py_import 2 s,
py_grep 2.2 s, py_short 300 ms); the library's real commands decide the actual time. py_import and
py_grep are the §1.1 feasibility probe's cold N = 1 times. All five are placeholders until
calibration: --durations-from CAL.json (a JSON object, each class to its measured N = 1 median
run_ms, e.g. {"py_analyze": 17250, "py_test": 58100, "py_import": 1980, "py_grep": 2160,
"py_short": 410}; every class, nothing else, each > 0) replaces them, rounded to whole ms, so the
busy time, the duty fit and the offsets use the measured durations. The report records the
durations used (durations_ms) and the file's name and sha256 (durations_from, null without one).
Users pyc-u00 .. pyc-u39 round-robin (so the driver's 15% per-user cap never binds); provider
"synthetic"; out_bytes 0 (the driver never reads it).

Gaps are drawn (seeded) from the gap source's gap_ms values. Each source session's last call is
left out: E15 writes 0 there as a terminator, not as a gap. The draws are then scaled to the
session's duty target, as in PLAN Task 1 step 3:
  1. start from --min-turns turns; draw one gap per call boundary;
  2. B = sum of dur_ms;
  3. scale the draws by s = (B (1 - duty) / duty) / sum(draws);
  4. clip each gap to H = 1 800 000 ms;
  5. re-measure the duty. If it is more than 20% above target, add a whole turn (at most 50 extra)
     and go back to 1 for the new boundaries. If it still misses, fail.
Steps 3-4 are repeated on the gaps no scaling has clipped yet, until none newly clips, so the
time a clip removes moves to the unclipped gaps (fit()). That makes no difference when nothing
clips. Without it, scaling once loses the clipped excess for good: at 1.5% a session stays near 4.5% duty whatever
its length, and adding turns cannot fix that. A drawn 0 stays 0, because it is a back-to-back call.

Duty (corpus-report.json duty_achieved) is E15's: occupied time / span on the replay timeline
(experiments/e15-session-density/extract/extract.py:timeline, as in experiments/e16-low-duty/extract/duty_band.py). The calls here never overlap,
so that is sum(dur_ms) / (sum(dur_ms) + sum(gap_ms)). offset_ms is the time from the previous
call's emit (the previous call's dur_ms + gap_ms), 0 on the first call; the driver and timeline()
add the offsets up.

Usage: python3 pycache_corpus.py --gaps-from CORPUS.jsonl --duty 0.095 --sessions 400 --seed 1
                                 --out DIR [--min-turns 4] [--durations-from CAL.json]
"""

import argparse
import collections
import hashlib
import json
import math
import os
import random
import statistics
import sys
import types

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..",
                                 "experiments", "e15-session-density", "extract"))
try:
    import duckdb  # noqa: F401  (extract.py imports it at module level; timeline() never uses it)
except ImportError:
    sys.modules["duckdb"] = types.ModuleType("duckdb")
from extract import timeline  # noqa: E402

H_MS = 1_800_000
DUTY_TOL = 0.2          # relative: a session more than 20% above its target is extended
MAX_EXTRA_TURNS = 50
MIN_TURNS = 4
USERS = 40
PROVIDER = "synthetic"
DUR_MS = {"py_analyze": 15_000, "py_test": 60_000, "py_import": 2_000, "py_grep": 2_200,
          "py_short": 300}
# Skeletons are descriptive only: the driver runs the library's command for the class.
SKELETON = {"py_analyze": "python analyze.py", "py_test": "python -m pytest -x -q tests",
            "py_import": "python -c 'import numpy, pandas, scipy, sklearn'",
            "py_grep": "grep -rc def venv"}
TURN_HEAD = ("py_analyze", "py_test", "py_import", "py_grep")
SHORT_SKELETONS = ("grep", "read", "edit")


def load_gaps(path):
    """The gap pool (every call's gap_ms but each session's last) and the file's sha256."""
    h, pool = hashlib.sha256(), []
    with open(path, "rb") as f:
        for line in f:
            h.update(line)
            if line.strip():
                pool.extend(c["gap_ms"] for c in json.loads(line)["calls"][:-1])
    return pool, h.hexdigest()


def turn(rng):
    """One turn's (class, skeleton) pairs."""
    k = rng.randint(2, 5)
    return ([(cls, SKELETON[cls]) for cls in TURN_HEAD]
            + [("py_short", rng.choice(SHORT_SKELETONS)) for _ in range(k)]
            + [("py_analyze", SKELETON["py_analyze"])])


def fit(draws, target_ms):
    """Scale draws toward a target sum, clipping at H; repeat on the gaps not yet clipped. A gap is
    frozen only once a scaling clips it (a drawn gap already at H is scaled like any other)."""
    gaps, clipped = [float(g) for g in draws], set()
    while True:
        free = [i for i in range(len(gaps)) if i not in clipped]
        free_sum = sum(gaps[i] for i in free)
        need = target_ms - len(clipped) * H_MS
        if free_sum <= 0 or need <= 0:
            break
        s = need / free_sum
        for i in free:
            gaps[i] *= s
            if gaps[i] > H_MS:
                gaps[i] = H_MS
                clipped.add(i)
        if len(free) == len(gaps) - len(clipped):
            break
    return [min(H_MS, int(round(g))) for g in gaps]


def load_durations(path):
    """--durations-from: {class: measured N = 1 median run_ms} for exactly DUR_MS's classes, each a
    positive number, rounded to whole ms. Returns (durations, file sha256); exits 1 on a bad file."""
    def bad(why):
        sys.stderr.write("pycache_corpus.py: --durations-from %s: %s\n" % (path, why))
        sys.exit(1)
    try:
        with open(path, "rb") as f:
            raw = f.read()
        cal = json.loads(raw)
    except (OSError, ValueError) as e:
        bad("cannot read it as JSON (%s)" % e)
    if not isinstance(cal, dict):
        bad("not a JSON object of class -> run_ms")
    if set(cal) != set(DUR_MS):
        bad("its classes %s are not exactly %s" % (sorted(cal), sorted(DUR_MS)))
    out = {}
    for cls in DUR_MS:
        v = cal[cls]
        if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) or v <= 0:
            bad("%s is %r, not a positive number of ms" % (cls, v))
        out[cls] = max(1, int(round(v)))
    return out, hashlib.sha256(raw).hexdigest()


def build_calls(steps, gaps, dur=DUR_MS):
    calls, offset = [], 0
    for i, ((cls, skel), gap) in enumerate(zip(steps, gaps + [0])):
        calls.append(dict(i=i, **{"class": cls}, skeleton=skel, dur_ms=dur[cls],
                          work_ms=dur[cls], gap_ms=gap, offset_ms=offset, out_bytes=0,
                          chain=False))
        offset = dur[cls] + gap
    return calls


def duty_of(calls):
    span, busy, _, _ = timeline(calls)
    return busy / span


def session(rng, pool, duty, min_turns, dur=DUR_MS):
    """(calls, achieved duty, extra turns) for one session, or None when the target is missed."""
    steps, draws = [], []
    for _ in range(min_turns):
        steps += turn(rng)
    for extra in range(MAX_EXTRA_TURNS + 1):
        if extra:
            steps += turn(rng)
        draws += [rng.choice(pool) for _ in range(len(steps) - 1 - len(draws))]
        busy = sum(dur[c] for c, _ in steps)
        calls = build_calls(steps, fit(draws, busy * (1 - duty) / duty), dur)
        d = duty_of(calls)
        if d <= duty * (1 + DUTY_TOL):
            return calls, d, extra
    return None


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--gaps-from", required=True, help="an E15 corpus.jsonl (its gap_ms values)")
    p.add_argument("--duty", type=float, required=True, help="per-session duty target, (0, 1)")
    p.add_argument("--sessions", type=int, required=True)
    p.add_argument("--seed", type=int, required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--min-turns", type=int, default=MIN_TURNS,
                   help="turns per session before the duty fit adds any (default %d)" % MIN_TURNS)
    p.add_argument("--durations-from", metavar="CAL.json",
                   help="JSON object: each class's measured N=1 median run_ms, replacing the "
                        "placeholder dur_ms/work_ms")
    args = p.parse_args(argv)
    if not 0 < args.duty < 1:
        p.error("--duty must be in (0, 1)")
    if args.sessions < 1:
        p.error("--sessions must be at least 1")
    if args.min_turns < 1:
        p.error("--min-turns must be at least 1")
    dur, dur_src = dict(DUR_MS), None
    if args.durations_from:
        dur, dur_sha = load_durations(args.durations_from)
        dur_src = dict(file=os.path.basename(args.durations_from), sha256=dur_sha)
    pool, gap_sha = load_gaps(args.gaps_from)
    if not any(pool):
        sys.stderr.write("pycache_corpus.py: %s has no non-zero gap_ms\n" % args.gaps_from)
        sys.exit(1)

    rng = random.Random(args.seed)
    lines, duties, per_class = [], [], collections.Counter()
    extended, turns, spans, busy = 0, [], [], 0
    for n in range(args.sessions):
        got = session(rng, pool, args.duty, args.min_turns, dur)
        if got is None:
            sys.stderr.write(
                "pycache_corpus.py: session %d cannot meet duty %g (within %d%% above) even with %d "
                "extra turns over %d: the gap source's gaps, clipped at %d s, are too short\n"
                % (n, args.duty, DUTY_TOL * 100, MAX_EXTRA_TURNS, args.min_turns, H_MS // 1000))
            sys.exit(1)
        calls, d, extra = got
        s = dict(session="pycache:%d:%04d" % (args.seed, n), user="pyc-u%02d" % (n % USERS),
                 provider=PROVIDER, calls=calls)
        lines.append((json.dumps(s, separators=(",", ":")) + "\n").encode())
        duties.append(d)
        per_class.update(c["class"] for c in calls)
        extended += extra > 0
        turns.append(sum(c["class"] == "py_test" for c in calls))
        span, b, _, _ = timeline(calls)
        spans.append(span)
        busy += b

    data = b"".join(lines)
    report = dict(
        sessions=args.sessions, seed=args.seed, duty_target=args.duty,
        duty_achieved=dict(mean=statistics.fmean(duties), median=statistics.median(duties),
                           min=min(duties), max=max(duties)),
        duty_definition="occupied / span on the replay timeline (experiments/e15-session-density/extract/extract.py:timeline)",
        calls_per_class=dict(sorted(per_class.items())),
        min_turns=args.min_turns,
        durations_ms=dur, durations_from=dur_src,
        turns=dict(mean=statistics.fmean(turns), max=max(turns), sessions_extended=extended),
        turns_per_session=dict(min=min(turns), median=statistics.median(turns), max=max(turns)),
        span_min=dict(min=min(spans) / 60_000, median=statistics.median(spans) / 60_000,
                      max=max(spans) / 60_000),
        gap_source=os.path.basename(args.gaps_from), gap_source_sha256=gap_sha, gap_pool=len(pool),
        # The fields the E15 rig reads from a point's corpus-report.json (rung.sh: K from
        # table.mean_span_min, H_s and exclude into params.json; setup.sh: corpus_sha256).
        H_s=H_MS // 1000, exclude=None, corpus_sha256=hashlib.sha256(data).hexdigest(),
        # occupied_pct is E15's table figure: all sessions' occupied time over all their span.
        table=dict(occupied_pct=100 * busy / sum(spans),
                   mean_span_min=sum(spans) / 60_000 / len(spans)))
    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "corpus.jsonl"), "wb") as f:
        f.write(data)
    with open(os.path.join(args.out, "corpus-report.json"), "w") as f:
        json.dump(report, f, indent=2)
        f.write("\n")
    return report


if __name__ == "__main__":
    main()
