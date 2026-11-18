#!/usr/bin/env python3
"""E17b lease-end analysis: notice matching and reclaim order (PLAN-E17B Task 8; gate criteria 3 and 4).

  python3 experiments/e17-lease/analysis/lease_ends.py RUNG_DIR -> RUNG_DIR/lease_ends.json

Inputs (all in RUNG_DIR): worker.log[.gz], calls.jsonl, lease-tail.jsonl (driver, Task 3), and optionally
samples.jsonl and params.json (rig). Worker lines read (moca remote-worker/internal/vmpool/lease.go,
lease_event.go; the worker_restart end has the same form):
  vmpool: lease start workspace_key="<k>" vm=<vm> mode=<mode>
  vmpool: lease end   workspace_key="<k>" vm=<vm> mode=<mode> reason=<r> age=<d>
The timestamp is a whole second (the rig normalises Go's `log` stamp to ISO-8601 Z) and the line has no
at_unix_ms, so nothing here is matched by time except the reclaim-order check, and that one carries a 1 s
tolerance. Disagreements and anything unmatched are LISTED, never resolved (E17B-R9).

(a) Notice matching, per key and in order: the n-th `lease end` log line pairs with the n-th `end` notice
    the driver saw for that key (calls.jsonl `lease_events` in call order, failed calls included, then the
    key's `pending` from lease-tail.jsonl). The pair must agree on reason. A notice that repeats an earlier
    one (same at_unix_ms and reason) is listed as a duplicate and left out of the pairing, so it cannot
    shift every later pair. An end line with no earlier start line for its key and reason worker_restart is
    the PREVIOUS rung's lease, ended by this worker's start (lease_event.go): it is a carry-over, listed and
    kept out of the pairing. A key whose lease-tail state is active or expiring is live_at_stop: it has no
    end line in this rung's log (its worker_restart end is written by the NEXT worker's start) and no
    notice, so it takes no part in criterion 4 and is counted.
    ENDED AFTER THE SWEEP (E17B-R31): the driver's status sweep runs once every session has finished, not
    at the worker's stop, so a lease live at its status call can still end (idle, memory_reclaim) before the
    worker stops: that end line has no notice and no tail pending. An unmatched end line of a live_at_stop
    key whose whole-second time is at or after the floor of that key's lease-tail `swept_at_unix_ms` (the
    time the status call was sent; the key was live then, so the end came later, even within the same log
    second) is `ended_after_sweep`: counted, listed, excluded from criterion 4 like live_at_stop. A key not
    live at the sweep, an end before the sweep second, or a tail row without swept_at_unix_ms stays unmatched.
    ENDED BY THE RUN'S CUT (E17B-R54): at its end-of-run grace deadline the driver cuts the calls still running
    (cause cut_at_end) and exits; a cut aborts the Exec, the worker ends a lease whose Exec ended without the guest's
    answer as agent_dead (moca lease.go runLease), and no client is left to receive the notice. An unmatched end
    line whose key's LAST call is cut_at_end, at or after the whole second that call was sent, is
    `ended_by_run_cut`: counted, listed, excluded from criterion 4 like live_at_stop. Any other stays unmatched.
(b) Reclaim order. Reference time: for each `memory_reclaim` end, the idle time of every lease alive at
    that log line is T - (that key's last Exec end at or before T+1 s), T being the end line's own
    whole-second timestamp. The ranking does not depend on a common reference, and measuring from the
    reclaim itself (not from the end of the run) uses only the Execs that had finished by then: a key that
    ran again after the reclaim must not look recently active at it. Leases executing across T are not
    idle and are not candidates. POSSIBLY EXECUTING (E17B-R38): the worker skips every lease whose gate is
    held (reclaimLeasesLocked), which includes an Exec queued or sent within T's second, and the log does
    not say where in the second the reclaim fell; so a non-victim lease with a call sent in [T, T+1) is
    possibly_executing, listed, and not a candidate. For the victim itself, only a call in [T, T+1) that carries
    this reclaim's end notice (a lease_events end with reason memory_reclaim) came after the reclaim (it runs in
    the replacement lease) and is not one of its Exec ends; any other victim call there ran in the old lease and
    counts (PR #34 fix round 2). The victim must have the longest idle
    time; a victim within 1 s of a longer-idle lease is correct and reported as a tie. No reclaim at all
    leaves criterion3_order_pass null (vacuous, as criterion 4), never a pass (E17B-R39).
    A call's end is its `ts` + `observed_ms`.
(c) Refusals while an idle lease existed (E17B-R15: BOTH `memory-budget` and `host-memory`, reported and
    gated separately): /stats samples carry cumulative refusals[<reason>]; each
    increase between two consecutive samples counts when leaseVMs - leaseExecuting > 0 at either of the
    interval's samples. An increase it cannot classify (a sample without worker stats at either end) is
    listed as unclassified and fails the criterion.
(d) Guard events: memory_floor (params memory_abort), memory_high (delta of e15_mem_events.high), OOM kills
    (the larger of params oom_kills and the e15_mem_events.oom_kill delta), and host_memory: every host-memory
    refusal (the worker's physical backstop firing), whether or not a lease was idle (E17B-R39). The reading
    is `available` only when the samples carry e15_mem_events: params.json always exists and is no evidence
    that nothing fired. criterion3_guards_pass is false on any event counted, else true when available,
    else null.
Duplicates (E17B-R14): criterion 4 counts end -> notice AFTER the clients' own dedupe on at_unix_ms (lease spec
section 5), which the driver's fresh() applies before writing calls.jsonl, so a raw duplicate delivery is invisible
here and is not a missing notice. `duplicate_notices` lists only what the rows still show (a tail `pending` that
repeats a call's event, or rows written by a driver that did not dedupe). It is informational and does not fail
criterion 4: the worker re-tells an unacknowledged event, harmlessly (lease_event.go:124), and the duplicate is
left out of the pairing, so it cannot shift a later pair.
A reclaim victim that is itself executing across T gets verdict victim_executing (a worker bug: it reclaims idle
leases only), which fails criterion3_order_pass, distinct from unknown and wrong. Rows that ran no Exec (`execs`
0: deadline, token-mint failure, cut at the end) and set_mode_failed rows are not Exec spans.
criterion4_pass is false when `valid` is false, null when no lease ended in the rung (vacuous), else the
matching verdict. Task 11 treats gate 4 as met when no rung has it false, every measured rung is valid, and
at least one rung has it true; null rungs are reported, not counted as passes.
`valid` is false (reasons listed) on any set_mode_failed row, any lease-tail row with `error`, or a key
without a lease-tail row.
"""
import calendar
import json
import os
import sys
import time

import warmcold as W
import warmcold_lease as WL

TIE_S = 1.0
MEMORY_RECLAIM = "memory_reclaim"
WORKER_RESTART = "worker_restart"
BUDGET = "memory-budget"
HOST_MEMORY = "host-memory"  # vmpool errors.go RefuseHostMemory (#644's host backstop): gated like memory-budget


def _ts(line):
    t = W.LOG_TS_RE.match(line)
    return calendar.timegm(time.strptime(t.group(1), "%Y-%m-%dT%H:%M:%S")) if t else None


def call_span(c):
    """(start, end) epoch seconds of a calls.jsonl row, or None when its ts does not parse."""
    m = W.CALL_TS_RE.match(c.get("ts") or "")
    if not m:
        return None
    start = calendar.timegm(time.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S")) + float(m.group(2) or 0)
    return start, start + float(c.get("observed_ms") or 0) / 1000.0


def read_log(d):
    """Lease start/end lines in log order: {"kind", "key", "vm", "reason", "ts"}."""
    out = []
    with W.open_rung_file(d, "worker.log") as f:
        for line in f:
            m = WL.START_RE.search(line)
            if m:
                out.append({"kind": "start", "key": m.group("key"), "vm": m.group("vm"), "ts": _ts(line)})
                continue
            m = WL.END_RE.search(line)
            if m:
                out.append({"kind": "end", "key": m.group("key"), "vm": m.group("vm"),
                            "reason": m.group("reason"), "ts": _ts(line)})
    return out


def read_jsonl(path):
    rows = []
    if os.path.exists(path):
        with open(path, errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    continue
    return rows


def split_log(log):
    """(ends per key in order, carry-over ends, end line times per key in the same order). A carry-over is
    a worker_restart end with no earlier start."""
    ends, carry, started, times = {}, [], set(), {}
    for ev in log:
        if ev["kind"] == "start":
            started.add(ev["key"])
        elif ev["reason"] == WORKER_RESTART and ev["key"] not in started:
            carry.append({"key": ev["key"], "reason": WORKER_RESTART})
        else:
            ends.setdefault(ev["key"], []).append(ev["reason"])
            times.setdefault(ev["key"], []).append(ev["ts"])
    return ends, carry, times


def sweep_second(tail_row):
    """The whole second of the key's status call (swept_at_unix_ms), or None when the row has none."""
    ms = (tail_row or {}).get("swept_at_unix_ms")
    return None if not isinstance(ms, (int, float)) or isinstance(ms, bool) or ms <= 0 else ms // 1000


def key_notices(rows, tail_row):
    """(`end` notices in order, duplicates) for one key: its calls' lease_events, then the tail's pending."""
    seen, notes, dups = set(), [], []
    evs = []
    for c in sorted(rows, key=lambda c: c.get("call", 0)):
        evs += c.get("lease_events") or []
    pend = (tail_row or {}).get("pending")
    if pend:
        evs.append(pend)
    for e in evs:
        if e.get("state") != "end":
            continue
        sig = (e.get("at_unix_ms"), e.get("reason"))
        if e.get("at_unix_ms") and sig in seen:
            dups.append({"key": None, "reason": e.get("reason"), "at_unix_ms": e.get("at_unix_ms")})
            continue
        seen.add(sig)
        notes.append(e.get("reason"))
    return notes, dups


def match_notices(log, calls, tails):
    by_key = {}
    for c in calls:
        by_key.setdefault(c.get("session"), []).append(c)
    tail_by_key = {t.get("key"): t for t in tails}
    ends, carry, times = split_log(log)
    live = sorted(k for k, t in tail_by_key.items() if t.get("state") in ("active", "expiring"))
    out = {"ends_in_log": sum(len(v) for v in ends.values()), "paired": 0, "notices_seen": 0,
           "unmatched_ends": [], "unmatched_notices": [], "reason_mismatches": [], "duplicate_notices": [],
           "carryover_ends": carry, "live_at_stop": len(live), "live_at_stop_keys": live,
           "ended_after_sweep": 0, "ended_after_sweep_ends": [], "ended_by_run_cut": 0, "ended_by_run_cut_ends": []}
    for key in sorted(set(ends) | set(by_key) | set(tail_by_key)):
        notes, dups = key_notices(by_key.get(key, []), tail_by_key.get(key))
        for dd in dups:
            dd["key"] = key
            out["duplicate_notices"].append(dd)
        lines = ends.get(key, [])
        out["notices_seen"] += len(notes)
        for i in range(min(len(lines), len(notes))):
            out["paired"] += 1
            if lines[i] != notes[i]:
                out["reason_mismatches"].append({"key": key, "n": i + 1, "log": lines[i], "notice": notes[i]})
        swept = sweep_second(tail_by_key.get(key)) if key in live else None
        cut = run_cut_second(by_key.get(key, []))
        for i in range(len(notes), len(lines)):
            ts = times[key][i]
            if cut is not None and i == len(lines) - 1 and ts is not None and ts >= cut:
                out["ended_by_run_cut_ends"].append({"key": key, "n": i + 1, "reason": lines[i], "ts": ts})
            elif swept is not None and ts is not None and ts >= swept:
                out["ended_after_sweep_ends"].append({"key": key, "n": i + 1, "reason": lines[i], "ts": ts})
            else:
                out["unmatched_ends"].append({"key": key, "n": i + 1, "reason": lines[i]})
        out["unmatched_notices"] += [{"key": key, "n": i + 1, "reason": notes[i]} for i in range(len(lines), len(notes))]
    out["ended_after_sweep"] = len(out["ended_after_sweep_ends"])
    out["ended_by_run_cut"] = len(out["ended_by_run_cut_ends"])
    return out


def run_cut_second(calls):
    """The whole-second send time of a key's LAST call when the driver cut it at the end of the run (cause
    cut_at_end), else None (E17B-R54)."""
    if not calls:
        return None
    last = max(calls, key=lambda c: c.get("call") or 0)
    if last.get("cause") != "cut_at_end" or not last.get("ts"):
        return None
    return float(calendar.timegm(time.strptime(last["ts"][:19], "%Y-%m-%dT%H:%M:%S")))


def idle_times(candidates, spans, t, victim=None):
    """({key: idle seconds at t, or None when it has no Exec end by then}, executing keys, possibly executing
    keys). spans are (start, end, carries a memory_reclaim end notice). A non-victim key with a call sent in
    [t, t+1) is possibly executing (E17B-R38); the victim's call sent in [t, t+1) that carries the reclaim's end
    notice is its replacement lease's, not an Exec end before the reclaim."""
    idle, executing, possibly = {}, set(), set()
    for k in candidates:
        sp = spans.get(k, [])
        if any(s <= t and e >= t + 1 for s, e, _ in sp):
            executing.add(k)
            continue
        if k != victim and any(t <= s < t + 1 for s, e, _ in sp):
            possibly.add(k)
            continue
        ends = [e for s, e, notice in sp if e <= t + 1 and not (k == victim and notice and t <= s < t + 1)]
        idle[k] = t - max(ends) if ends else None
    return idle, executing, possibly


def reclaim_order(log, calls):
    spans = {}
    for c in calls:
        sp = call_span(c)
        if sp and c.get("cause") != WL.SET_MODE_FAILED and int(c.get("execs") or 0) > 0:
            notice = any(e.get("state") == "end" and e.get("reason") == MEMORY_RECLAIM for e in c.get("lease_events") or [])
            spans.setdefault(c.get("session"), []).append(sp + (notice,))
    alive, details = set(), []
    for ev in log:
        if ev["kind"] == "start":
            alive.add(ev["key"])
            continue
        if ev["reason"] == MEMORY_RECLAIM and ev["ts"] is not None:
            idle, executing, possibly = idle_times(alive | {ev["key"]}, spans, ev["ts"], victim=ev["key"])
            row = judge(ev["key"], ev["ts"], idle, executing)
            row["possibly_executing"] = sorted(possibly)
            details.append(row)
        alive.discard(ev["key"])
    return {"total": len(details), "correct": sum(x["verdict"] == "correct" for x in details),
            "ties": sum(bool(x.get("tie_with")) for x in details),
            "wrong": sum(x["verdict"] == "wrong" for x in details),
            "unknown": sum(x["verdict"] == "unknown" for x in details),
            "victim_executing": sum(x["verdict"] == "victim_executing" for x in details),
            "possibly_executing": sum(len(x["possibly_executing"]) for x in details), "details": details,
            "reference": "the reclaim end line's own whole-second timestamp T; idle = T - the key's last Exec end by T+1 s"}


def judge(victim, t, idle, executing=frozenset()):
    row = {"victim": victim, "at": t, "idle_s": {k: (None if v is None else round(v, 3)) for k, v in sorted(idle.items())}}
    if victim in executing:  # the worker reclaims idle leases only: a worker bug, not an unknown
        row["verdict"] = "victim_executing"
        return row
    mine = idle.get(victim)
    others = {k: v for k, v in idle.items() if k != victim}
    unknown = sorted(k for k, v in idle.items() if v is None)
    if mine is None or unknown:
        row.update(verdict="unknown", unknown_idle=unknown)
        return row
    if not others:
        row.update(verdict="correct", sole=True)
        return row
    top_key, top = max(others.items(), key=lambda kv: kv[1])
    if mine >= top:
        row["verdict"] = "correct"
    elif mine >= top - TIE_S:
        row.update(verdict="correct", tie_with=sorted(k for k, v in others.items() if v > mine))
    else:
        row.update(verdict="wrong", longest_idle=top_key)
    return row


def refusals_with_idle(samples):
    """memory-budget and host-memory refusals, each total and the part with an idle lease alive (see (c))."""
    out = {"memory_budget_total": 0, "with_idle_lease": 0, "host_memory_total": 0, "host_memory_with_idle_lease": 0,
           "unclassified": [], "counter_resets": 0, "available": False}
    names = ((BUDGET, "memory_budget_total", "with_idle_lease"),
             (HOST_MEMORY, "host_memory_total", "host_memory_with_idle_lease"))
    prev, gap = None, False
    for s in samples:
        w = s.get("worker")
        if not isinstance(w, dict):
            gap = gap or prev is not None
            continue
        out["available"] = True
        if prev is not None:
            idle = any(max(int(x.get("leaseVMs", 0)) - int(x.get("leaseExecuting", 0)), 0) > 0
                       for x in (prev["worker"], w))
            for reason, total_key, idle_key in names:
                pn = int((prev["worker"].get("refusals") or {}).get(reason, 0))
                n = int((w.get("refusals") or {}).get(reason, 0))
                if n < pn:
                    out["counter_resets"] += 1
                    delta = n
                else:
                    delta = n - pn
                if not delta:
                    continue
                out[total_key] += delta
                if gap:
                    out["unclassified"].append({"t": s.get("t"), "reason": reason, "refusals": delta,
                                                "why": "sample without worker stats"})
                elif idle:
                    out[idle_key] += delta
        prev, gap = s, False
    return out


def guard_events(samples, params, refusals):
    ev = [s["e15_mem_events"] for s in samples if isinstance(s.get("e15_mem_events"), dict)]

    def delta(k):
        a, b = (ev[0].get(k), ev[-1].get(k)) if ev else (None, None)
        return b - a if isinstance(a, int) and isinstance(b, int) else 0
    floor = 1 if params.get("memory_abort") else 0
    high = delta("high")
    oom = max(int(params.get("oom_kills") or 0), delta("oom_kill"))
    host = int(refusals.get("host_memory_total") or 0)
    return {"memory_floor": floor, "memory_high": high, "oom_kills": oom, "host_memory": host,
            "total": floor + high + oom + host, "available": bool(ev)}


def stats_lease_ends(samples, log):
    last = next((s["worker"]["leaseEnds"] for s in reversed(samples)
                 if isinstance(s.get("worker"), dict) and s["worker"].get("leaseEnds")), None)
    counts = {}
    for ev in log:
        if ev["kind"] == "end":
            counts[ev["reason"]] = counts.get(ev["reason"], 0) + 1
    if last is None:
        return {"available": False, "disagreements": []}
    dis = [{"reason": r, "stats": int(last.get(r, 0)), "log": counts.get(r, 0)}
           for r in sorted(set(last) | set(counts)) if int(last.get(r, 0)) != counts.get(r, 0)]
    return {"available": True, "stats": last, "log": counts, "disagreements": dis}


def analyse(d):
    calls = W.read_calls(d)
    tails = read_jsonl(os.path.join(d, "lease-tail.jsonl"))
    samples = read_jsonl(os.path.join(d, "samples.jsonl"))
    pp = os.path.join(d, "params.json")
    params = json.load(open(pp)) if os.path.exists(pp) else {}
    log = read_log(d)

    why = []
    smf = sorted({c.get("session") for c in calls if c.get("cause") == WL.SET_MODE_FAILED})
    if smf:
        why.append("set_mode_failed on %d session(s): %s" % (len(smf), ", ".join(smf)))
    for t in tails:
        if t.get("error"):
            why.append("lease-tail error for %s: %s" % (t.get("key"), t["error"]))
    tail_keys = {t.get("key") for t in tails}
    no_tail = sorted(k for k in {c.get("session") for c in calls} if k not in tail_keys)
    if no_tail:
        why.append("no lease-tail row for %d key(s)" % len(no_tail))

    notices = match_notices(log, calls, tails)
    reclaim = reclaim_order(log, calls)
    refusals = refusals_with_idle(samples)
    guards = guard_events(samples, params, refusals)
    if why:
        c4 = False
    elif notices["ends_in_log"] - notices["ended_after_sweep"] - notices["ended_by_run_cut"] == 0 \
            and notices["notices_seen"] == 0:
        c4 = None  # vacuous: no lease ended in this rung
    else:
        c4 = not (notices["unmatched_ends"] or notices["unmatched_notices"] or notices["reason_mismatches"])
    return {
        "valid": not why, "invalid_reasons": why, "keys_without_tail": no_tail,
        "notices": notices, "criterion4_pass": c4,
        "reclaim": reclaim,
        "criterion3_order_pass": (reclaim["wrong"] == 0 and reclaim["unknown"] == 0 and reclaim["victim_executing"] == 0)
        if reclaim["total"] else None,
        "refusals": refusals,
        "criterion3_refusals_pass": (refusals["with_idle_lease"] == 0 and refusals["host_memory_with_idle_lease"] == 0
                                    and not refusals["unclassified"]) if refusals["available"] else None,
        "guards": guards,
        "criterion3_guards_pass": False if guards["total"] else (True if guards["available"] else None),
        "stats_lease_ends": stats_lease_ends(samples, log),
    }


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1:
        raise SystemExit("usage: lease_ends.py RUNG_DIR")
    r = analyse(argv[0])
    with open(os.path.join(argv[0], "lease_ends.json"), "w") as f:
        json.dump(r, f, indent=2, sort_keys=True)
    n = r["notices"]
    print("valid %s; ends %d paired %d unmatched %d+%d mismatched %d dup %d live_at_stop %d ended_after_sweep %d "
          "ended_by_run_cut %d; reclaim %d wrong %d unknown %d" % (
        r["valid"], n["ends_in_log"], n["paired"], len(n["unmatched_ends"]), len(n["unmatched_notices"]),
        len(n["reason_mismatches"]), len(n["duplicate_notices"]), n["live_at_stop"], n["ended_after_sweep"],
        n["ended_by_run_cut"],
        r["reclaim"]["total"], r["reclaim"]["wrong"], r["reclaim"]["unknown"]))


if __name__ == "__main__":
    main()
