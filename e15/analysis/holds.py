"""The "holds N" test (SPEC section 8). Pure functions, stdlib only."""
import math

PACE_MAX = 0.10
P95_FACTOR = 2.0
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
    # observed ends at the last Exec's End, before the chain's idle tail
    return call["observed_ms"] - (call["planned_dur_ms"] - call.get("tail_ms", 0))


def _is_failure(call, arm):
    if call.get("status") != "err":
        return False
    cause = call.get("cause", "")
    if cause == "deadline" and call.get("execs", 0) == 0:
        return False
    if arm == "control" and cause == "exit_mismatch":
        return False
    return True


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


def evaluate(calls, sessions, baseline_p95_ms, arm="sbx", refusals=0):
    win = [c for c in calls if c.get("in_window")]
    failed = [c for c in win if _is_failure(c, arm)]
    not_started = [c for c in win if c.get("status") == "err"
                   and c.get("cause") == "deadline" and c.get("execs", 0) == 0]
    causes = {}
    for c in win:
        if c.get("status") == "err":
            causes[c.get("cause", "")] = causes.get(c.get("cause", ""), 0) + 1

    added = [added_ms(c) for c in win if c.get("status") == "ok"]
    p95 = percentile(added, 95)

    paces, excluded = [], 0
    for s in sessions:
        if s.get("window_calls", 0) < MIN_SESSION_CALLS or not s.get("planned_ms"):
            excluded += 1
            continue
        paces.append(s["observed_ms"] / float(s["planned_ms"]) - 1)
    med = median(paces)

    p95_limit = None if baseline_p95_ms is None else P95_FACTOR * max(baseline_p95_ms, 1.0)
    c1 = len(failed) == 0
    c2 = refusals == 0
    c3 = med is None or med <= PACE_MAX + 1e-9  # float slack at the inclusive boundary
    c4 = p95_limit is None or p95 is None or p95 <= p95_limit
    empty = len(win) == 0 or len(paces) == 0
    out = {
        "holds": bool(c1 and c2 and c3 and c4) and not empty,
        "conditions": {"no_failures": c1, "no_refusals": c2,
                       "pace": c3, "added_latency": c4},
        "window_calls": len(win),
        "failed_calls": len(failed),
        "not_started": len(not_started),
        "refusals": refusals,
        "median_pace": med,
        "p95_added_ms": p95,
        "p95_limit_ms": p95_limit,
        "sessions_evaluated": len(paces),
        "sessions_excluded_lt3": excluded,
        "causes": causes,
        "by_provider": _split(win, "provider", arm),
        "by_class": _split(win, "class", arm),
    }
    if empty:
        out["reason"] = "empty_window"
    return out
