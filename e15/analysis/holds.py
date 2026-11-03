"""The "holds N" test (SPEC section 8). Pure functions, stdlib only."""
import math

PACE_MAX = 0.10
P95_FACTOR = 3.0
EXCESS_FLOOR_MS = 50.0  # condition 4 limit never drops below this (class-matched, SPEC §8)
MIN_CLASS_CALLS = 5
ABS_ADDED_MS = 250  # holds_abs: condition 4 is p95(excess) <= B + 250 ms, B = the arm's N=1 excess p95
MIN_SESSION_CALLS = 3


def percentile(values, q):
    """Nearest-rank percentile (q in 0..100); None when empty."""
    if not values:
        return None
    s = sorted(values)
    k = max(1, int(math.ceil(q / 100.0 * len(s))))
    return s[k - 1]


def median(values):
    if not values:
        return None
    s = sorted(values)
    n = len(s)
    return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2.0


def added_ms(call):
    # tail_ms is 0 since one recorded call became one Exec (Task 8a): the chain's idle tail runs
    # inside the Exec, before End. Older runs slept it after End, so it is still subtracted.
    return call["observed_ms"] - (call["planned_dur_ms"] - call.get("tail_ms", 0))


def window_added_ms(calls):
    """Added latency of the in-window ok calls: the population condition 4's p95 is over, and
    the N=1 baseline pools (baseline.py)."""
    return [added_ms(c) for c in calls if c.get("in_window") and c.get("status") == "ok"]


def window_ok_calls(calls):
    return [c for c in calls if c.get("in_window") and c.get("status") == "ok"]


def class_medians(baseline_calls, min_n=MIN_CLASS_CALLS):
    """Per-class median added latency over the in-window ok calls; classes with fewer than min_n
    calls are omitted (they use the global median). Returns (medians, global_median)."""
    ok = window_ok_calls(baseline_calls)
    by = {}
    for c in ok:
        by.setdefault(c.get("class"), []).append(added_ms(c))
    medians = {k: median(v) for k, v in by.items() if len(v) >= min_n}
    return medians, median([added_ms(c) for c in ok])


def excess_ms(calls, medians, global_median):
    """Added latency of each in-window ok call minus its class's N=1 median (the global median
    for a class with no median). Returns (excess list, fallback_count)."""
    out, fb = [], 0
    for c in window_ok_calls(calls):
        m = medians.get(c.get("class"))
        if m is None:
            m, fb = global_median, fb + 1
        out.append(added_ms(c) - m)
    return out, fb


def _not_failure_cause(call):
    """Causes that end a call without the backend failing it: a call never started at the grace
    deadline, and one the run's end cut before its planned completion (cut_at_end). The driver
    records cut_at_end only for an Exec it sent, so one with no Exec is malformed: a failure."""
    cause = call.get("cause", "")
    return (cause == "deadline" and call.get("execs", 0) == 0) or _is_cut(call)


def _is_cut(call):
    return call.get("cause") == "cut_at_end" and call.get("execs", 0) >= 1


def _is_failure(call, arm):
    if call.get("status") != "err":
        return False
    cause = call.get("cause", "")
    if _not_failure_cause(call):
        return False
    if arm == "control" and cause == "exit_mismatch":
        return False
    return True


def counts_as_failure(call, arm="sbx"):
    return _is_failure(call, arm)


def _split(calls, key, arm):
    out = {}
    for c in calls:
        d = out.setdefault(str(c.get(key)), {"calls": 0, "failed": 0, "_add": []})
        d["calls"] += 1
        if _is_failure(c, arm):
            d["failed"] += 1
        elif c.get("status") == "ok":
            d["_add"].append(added_ms(c))
    for d in out.values():
        d["p95_added_ms"] = percentile(d.pop("_add"), 95)
    return out


def session_paces(sessions):
    """Per-session pace = observed/planned - 1 for sessions with >= MIN_SESSION_CALLS window calls;
    returns (paces, excluded_count)."""
    paces, excluded = [], 0
    for s in sessions:
        if s.get("window_calls", 0) < MIN_SESSION_CALLS or not s.get("planned_ms"):
            excluded += 1
            continue
        paces.append(s["observed_ms"] / float(s["planned_ms"]) - 1)
    return paces, excluded


def expected_ms(window_calls, trace_offsets, medians, global_median, stats=None):
    """Expected first-send-to-last-End time of one session's window calls: the driver's schedule
    (replay.go runSession) with every call lengthened by its class's N=1 probe median. The first
    window call is sent at 0; end_k = send_k + planned_dur_ms_k + M[class_k]; the next call is sent
    at max(send_k + offset_{k+1}, end_k) -- runCall is synchronous, so a send never precedes the
    previous End and added latency is absorbed by the gap. offset_{k+1} is the corpus session's
    calls[i].offset_ms for the call's index i (trace_offsets: {i: offset_ms}); a call the corpus
    lacks falls back to the previous call's planned_dur_ms + planned_gap_ms. With every M = 0 and
    offsets equal to dur + gap this is the driver's planned_ms (first send to last End; the last
    gap is after the last End, so it is not in either).
    stats, a dict, gets "offset_join_misses" incremented for every call after the first whose offset
    the corpus did not supply (the fallback above was used)."""
    send = 0.0
    end = 0.0
    prev = None
    for c in window_calls:
        if prev is not None:
            off = trace_offsets.get(c.get("call"))
            if off is None:
                off = prev.get("planned_dur_ms", 0) + prev.get("planned_gap_ms", 0)
                if stats is not None:
                    stats["offset_join_misses"] = stats.get("offset_join_misses", 0) + 1
            send = max(send + off, end)
        m = medians.get(c.get("class"), global_median)
        end = send + c.get("planned_dur_ms", 0) + m
        prev = c
    return end


def class_paces(calls, sessions, medians, global_median, offsets=None, stats=None):
    """Class-matched pace per session (SPEC §8 condition 3). A session counts when it has >=
    MIN_SESSION_CALLS window calls and planned_ms > 0. Its window calls are the ones the driver put
    in the session's pace (record.go/replay.go: in_window and not cut_at_end, ok or failed, joined
    on the replay-instance id `session`); expected time is expected_ms() over them; pace =
    observed_ms / expected - 1. offsets: {trace: {call index: offset_ms}} from the corpus.
    Returns (paces, excluded, nonpositive): excluded as in session_paces; nonpositive = sessions
    whose expected time is <= 0 (strongly negative medians), dropped and counted. stats: see
    expected_ms (offset_join_misses, over the sessions that are evaluated)."""
    offsets = offsets or {}
    by = {}
    for c in calls:
        if c.get("in_window") and not _is_cut(c):
            by.setdefault(c.get("session"), []).append(c)
    paces, excluded, nonpos = [], 0, 0
    for s in sessions:
        if s.get("window_calls", 0) < MIN_SESSION_CALLS or not s.get("planned_ms"):
            excluded += 1
            continue
        wc = by.get(s.get("session"), [])
        trace = wc[0].get("trace") if wc else None
        expected = expected_ms(wc, offsets.get(trace, {}), medians, global_median, stats)
        if expected <= 0:
            nonpos += 1
            continue
        paces.append(s["observed_ms"] / float(expected) - 1)
    return paces, excluded, nonpos


def evaluate(calls, sessions, baseline, arm="sbx", refusals=0, offsets=None):
    """baseline: baseline.json's dict (class_medians, global_median_ms, excess_p95_ms, n1_median_pace)
    or None (N=1, and the control arm): conditions 3 and 4 are skipped, median_pace still reported.
    Condition 3 is the median class-matched pace (class_paces) <= 0.10."""
    win = [c for c in calls if c.get("in_window")]
    failed = [c for c in win if _is_failure(c, arm)]
    not_started = [c for c in win if c.get("status") == "err"
                   and c.get("cause") == "deadline" and c.get("execs", 0) == 0]
    cut = [c for c in win if c.get("status") == "err" and _is_cut(c)]
    causes = {}
    for c in win:
        if c.get("status") == "err":
            causes[c.get("cause", "")] = causes.get(c.get("cause", ""), 0) + 1

    added = window_added_ms(win)
    p95 = percentile(added, 95)

    paces, excluded = session_paces(sessions)
    med = median(paces)

    if baseline is None:
        exc, fb, p95_exc, exc_limit = [], 0, None, None
    else:
        exc, fb = excess_ms(win, baseline.get("class_medians", {}), baseline["global_median_ms"])
        p95_exc = percentile(exc, 95)
        exc_limit = max(P95_FACTOR * baseline["excess_p95_ms"], EXCESS_FLOOR_MS)
    c1 = len(failed) == 0
    c2 = refusals == 0
    # condition 3 is class-matched: median class pace <= PACE_MAX. N=1 and control (baseline None)
    # skip it. n1_median_pace and the raw median_pace are reported only.
    n1_pace = None if baseline is None else baseline.get("n1_median_pace")
    pace_excess = None if (med is None or n1_pace is None) else med - n1_pace
    cpaces, nonpos, misses = [], 0, 0
    if baseline is not None:
        # offsets=None: the caller has no corpus to join (unit tests); the join is not checked.
        # record.py always passes a dict, {} included, so a missing corpus counts as misses.
        jstats = {} if offsets is not None else None
        cpaces, _, nonpos = class_paces(win, sessions, baseline.get("class_medians", {}),
                                        baseline["global_median_ms"], offsets, jstats)
        misses = (jstats or {}).get("offset_join_misses", 0)
    med_class = median(cpaces)
    c3 = baseline is None or med_class is None or med_class <= PACE_MAX + 1e-9  # float slack at the inclusive boundary
    c4 = exc_limit is None or p95_exc is None or p95_exc <= exc_limit
    # holds_abs: the same conditions, but condition 4 is p95 excess at most B + ABS_ADDED_MS
    # (B = baseline["excess_p95_ms"]). N=1 skips it as before.
    p95_limit_abs = None if baseline is None else baseline["excess_p95_ms"] + ABS_ADDED_MS
    c4_abs = p95_limit_abs is None or p95_exc is None or p95_exc <= p95_limit_abs
    # every eligible session dropped as non-positive expected time: nothing to judge pace on
    empty = len(win) == 0 or len(paces) == 0 or (baseline is not None and not cpaces and nonpos > 0)
    out = {
        "holds": bool(c1 and c2 and c3 and c4) and not empty and not misses,
        "holds_abs": bool(c1 and c2 and c3 and c4_abs) and not empty and not misses,
        "offset_join_misses": misses,
        "conditions": {"no_failures": c1, "no_refusals": c2,
                       "pace": c3, "added_latency": c4},
        "conditions_abs": {"no_failures": c1, "no_refusals": c2,
                           "pace": c3, "added_latency": c4_abs},
        "p95_limit_abs_ms": p95_limit_abs,
        "window_calls": len(win),
        "failed_calls": len(failed),
        "not_started": len(not_started),
        "cut_at_end": len(cut),
        "refusals": refusals,
        "median_pace": med,
        "n1_median_pace": n1_pace,
        "pace_excess": pace_excess,
        "median_class_pace": med_class,
        "pace_excluded_nonpositive": nonpos,
        "p95_added_ms": p95,
        "p95_excess_ms": p95_exc,
        "excess_limit_ms": exc_limit,
        "fallback_calls": fb,
        "sessions_evaluated": len(paces),
        "sessions_excluded_lt3": excluded,
        "causes": causes,
        "by_provider": _split(win, "provider", arm),
        "by_class": _split(win, "class", arm),
    }
    if empty:
        out["reason"] = "empty_window"
    if misses:
        out["reason"] = "corpus_join_miss"
    return out
