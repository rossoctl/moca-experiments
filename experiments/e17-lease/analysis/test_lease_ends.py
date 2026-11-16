import datetime
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import lease_ends as LE  # noqa: E402
from test_warmcold_lease import end_line, start_line  # noqa: E402

BASE = datetime.datetime(2026, 11, 15, 10, 0, 0, tzinfo=datetime.timezone.utc).timestamp()


def iso(off, frac=False):
    t = datetime.datetime.fromtimestamp(BASE + off, datetime.timezone.utc)
    return t.strftime("%Y-%m-%dT%H:%M:%S") + (".%06dZ" % t.microsecond if frac else "Z")


def logts(off):
    return iso(int(off))


def call(key, n, start, dur=1.0, events=None, cause="", **kw):
    """A calls.jsonl row; start in seconds after BASE, dur in seconds."""
    r = {"session": key, "call": n, "ts": iso(start, True), "observed_ms": dur * 1000, "execs": 1,
         "status": "ok", "cause": cause}
    if events is not None:
        r["lease_events"] = events
    r.update(kw)
    return r


def end_ev(reason, at=1):
    return {"state": "end", "reason": reason, "at_unix_ms": at, "mode": "lease"}


def tail(key, state="none", pending=None, error=None):
    r = {"key": key}
    if error:
        r["error"] = error
    else:
        r["state"] = state
        if pending:
            r["pending"] = pending
    return r


def rung(tmp_path, log=(), calls=(), tails=(), samples=None, params=None):
    d = tmp_path / "rung"
    d.mkdir()
    (d / "worker.log").write_text("".join(log))
    (d / "calls.jsonl").write_text("".join(json.dumps(c) + "\n" for c in calls))
    (d / "lease-tail.jsonl").write_text("".join(json.dumps(t) + "\n" for t in tails))
    if samples is not None:
        (d / "samples.jsonl").write_text("".join(json.dumps(s) + "\n" for s in samples))
    if params is not None:
        (d / "params.json").write_text(json.dumps(params))
    return str(d)


def run(d):
    return LE.analyse(d)


# ---- (a) notice matching ----

def test_every_end_has_one_notice_in_order(tmp_path):
    d = rung(tmp_path,
             log=[start_line("a", "vm-1", ts=logts(0)), end_line("a", "vm-1", "idle", ts=logts(40)),
                  start_line("a", "vm-2", ts=logts(50)), end_line("a", "vm-2", "reset", ts=logts(90))],
             calls=[call("a", 1, 0), call("a", 2, 50, events=[end_ev("idle", 1)])],
             tails=[tail("a", "none", {"state": "end", "reason": "reset", "at_unix_ms": 2})])
    r = run(d)
    n = r["notices"]
    assert n["paired"] == 2 and n["ends_in_log"] == 2
    assert not n["unmatched_ends"] and not n["unmatched_notices"] and not n["reason_mismatches"]
    assert r["criterion4_pass"] and r["valid"]


def test_reason_mismatch_flagged(tmp_path):
    d = rung(tmp_path,
             log=[start_line("a", "vm-1", ts=logts(0)), end_line("a", "vm-1", "idle", ts=logts(40))],
             calls=[call("a", 1, 0), call("a", 2, 50, events=[end_ev("reset")])],
             tails=[tail("a")])
    r = run(d)
    assert r["notices"]["reason_mismatches"] == [{"key": "a", "n": 1, "log": "idle", "notice": "reset"}]
    assert not r["criterion4_pass"]


def test_notice_from_a_failed_call_counts(tmp_path):
    d = rung(tmp_path,
             log=[start_line("a", "vm-1", ts=logts(0)), end_line("a", "vm-1", "idle", ts=logts(40))],
             calls=[call("a", 1, 0), call("a", 2, 50, events=[end_ev("idle")], status="error", cause="timeout")],
             tails=[tail("a")])
    r = run(d)
    assert r["notices"]["paired"] == 1 and r["criterion4_pass"]


def test_duplicate_notice_flagged(tmp_path):
    d = rung(tmp_path,
             log=[start_line("a", "vm-1", ts=logts(0)), end_line("a", "vm-1", "idle", ts=logts(40))],
             calls=[call("a", 1, 0), call("a", 2, 50, events=[end_ev("idle", 7)]),
                    call("a", 3, 60, events=[end_ev("idle", 7)])],
             tails=[tail("a")])
    r = run(d)
    dup = r["notices"]["duplicate_notices"]
    assert len(dup) == 1 and dup[0]["key"] == "a" and dup[0]["reason"] == "idle"
    assert not r["criterion4_pass"]
    assert r["notices"]["paired"] == 1  # the duplicate does not cascade into an unmatched notice


def test_trailing_end_matched_by_status_sweep(tmp_path):
    d = rung(tmp_path,
             log=[start_line("a", "vm-1", ts=logts(0)), end_line("a", "vm-1", "idle", ts=logts(40))],
             calls=[call("a", 1, 0)],
             tails=[tail("a", "none", {"state": "end", "reason": "idle", "at_unix_ms": 3})])
    r = run(d)
    assert r["notices"]["paired"] == 1 and r["criterion4_pass"]


def test_unmatched_end_and_notice_listed(tmp_path):
    d = rung(tmp_path,
             log=[start_line("a", "vm-1", ts=logts(0)), end_line("a", "vm-1", "idle", ts=logts(40)),
                  start_line("b", "vm-2", ts=logts(0)), end_line("b", "vm-2", "idle", ts=logts(40))],
             calls=[call("a", 1, 0), call("b", 1, 0, events=[end_ev("idle", 1), end_ev("reset", 2)])],
             tails=[tail("a"), tail("b")])
    r = run(d)
    assert r["notices"]["unmatched_ends"] == [{"key": "a", "n": 1, "reason": "idle"}]
    assert r["notices"]["unmatched_notices"] == [{"key": "b", "n": 2, "reason": "reset"}]
    assert not r["criterion4_pass"]


def test_live_at_stop_excluded_and_counted(tmp_path):
    d = rung(tmp_path,
             log=[start_line("a", "vm-1", ts=logts(0)), start_line("b", "vm-2", ts=logts(0)),
                  end_line("b", "vm-2", "idle", ts=logts(40))],
             calls=[call("a", 1, 0), call("b", 1, 0)],
             tails=[tail("a", "active"), tail("b", "none", {"state": "end", "reason": "idle", "at_unix_ms": 1})])
    r = run(d)
    assert r["notices"]["live_at_stop"] == 1 and r["notices"]["live_at_stop_keys"] == ["a"]
    assert r["notices"]["paired"] == 1 and r["criterion4_pass"] and r["valid"]


def test_log_with_no_at_unix_ms_and_whole_second_timestamps(tmp_path):
    # two ends of different keys in the same second, notices in the opposite order across keys
    d = rung(tmp_path,
             log=[start_line("a", "vm-1", ts=logts(0)), start_line("b", "vm-2", ts=logts(0)),
                  end_line("a", "vm-1", "memory_reclaim", ts=logts(30)),
                  end_line("b", "vm-2", "idle", ts=logts(30))],
             calls=[call("b", 1, 0, events=[end_ev("idle", 5)]), call("a", 1, 0, events=[end_ev("memory_reclaim", 6)])],
             tails=[tail("a"), tail("b")])
    r = run(d)
    assert r["notices"]["paired"] == 2 and r["criterion4_pass"]


def test_worker_restart_end_before_any_start_is_a_carryover(tmp_path):
    d = rung(tmp_path,
             log=[end_line("a", "vm-0", "worker_restart", ts=logts(0)),
                  start_line("a", "vm-1", ts=logts(1)), end_line("a", "vm-1", "idle", ts=logts(40))],
             calls=[call("a", 1, 1)],
             tails=[tail("a", "none", {"state": "end", "reason": "idle", "at_unix_ms": 1})])
    r = run(d)
    assert r["notices"]["carryover_ends"] == [{"key": "a", "reason": "worker_restart"}]
    assert r["notices"]["paired"] == 1 and r["criterion4_pass"]


def test_set_mode_failed_and_tail_error_make_it_invalid(tmp_path):
    d = rung(tmp_path,
             calls=[call("a", 1, 0, cause="set_mode_failed", status="error"), call("b", 1, 0)],
             tails=[tail("a"), tail("b", error="rpc deadline")])
    r = run(d)
    assert not r["valid"]
    why = " ".join(r["invalid_reasons"])
    assert "set_mode_failed" in why and "rpc deadline" in why


def test_missing_tail_row_listed(tmp_path):
    d = rung(tmp_path, calls=[call("a", 1, 0)], tails=[])
    r = run(d)
    assert not r["valid"] and r["keys_without_tail"] == ["a"]


# ---- (b) reclaim order ----

def reclaim_rung(tmp_path, last_ends, victim="a", t=100, mid=None):
    """Keys alive from t=0, one call each ending at last_ends[key]; victim reclaimed at log second t."""
    log, calls, tails = [], [], []
    for k, e in last_ends.items():
        log.append(start_line(k, "vm-" + k, ts=logts(0)))
        calls.append(call(k, 1, e - 1, dur=1.0))
        tails.append(tail(k, "active" if k != victim else "none",
                          {"state": "end", "reason": "memory_reclaim", "at_unix_ms": 1} if k == victim else None))
    log.append(end_line(victim, "vm-" + victim, "memory_reclaim", ts=logts(t)))
    return rung(tmp_path, log=log, calls=calls, tails=tails)


def test_reclaim_picks_idle_longest(tmp_path):
    r = run(reclaim_rung(tmp_path, {"a": 10, "b": 50, "c": 60}))
    rc = r["reclaim"]
    assert rc["total"] == 1 and rc["correct"] == 1 and rc["ties"] == 0 and rc["wrong"] == 0
    assert r["criterion3_order_pass"]


def test_reclaim_tie_within_a_second_reported(tmp_path):
    r = run(reclaim_rung(tmp_path, {"a": 10.6, "b": 10.0, "c": 60}))
    rc = r["reclaim"]
    assert rc["correct"] == 1 and rc["ties"] == 1 and rc["wrong"] == 0
    assert rc["details"][0]["tie_with"] == ["b"]
    assert r["criterion3_order_pass"]


def test_reclaim_wrong_pick_flagged(tmp_path):
    r = run(reclaim_rung(tmp_path, {"a": 50, "b": 10, "c": 60}))
    rc = r["reclaim"]
    assert rc["wrong"] == 1 and rc["correct"] == 0
    d = rc["details"][0]
    assert d["verdict"] == "wrong" and d["victim"] == "a" and d["longest_idle"] == "b"
    assert not r["criterion3_order_pass"]


def test_reclaim_ignores_an_executing_lease_and_uses_exec_ends_before_the_reclaim(tmp_path):
    # b is executing across the reclaim (its older call ended long ago) and must not count as idle-longest;
    # c ran again AFTER the reclaim, which must not make it look recently active at the reclaim.
    log = [start_line(k, "vm-" + k, ts=logts(0)) for k in "abc"]
    log.append(end_line("a", "vm-a", "memory_reclaim", ts=logts(100)))
    calls = [call("a", 1, 9), call("b", 1, 1), call("b", 2, 95, dur=20), call("c", 1, 49), call("c", 2, 150)]
    tails = [tail("a", "none", {"state": "end", "reason": "memory_reclaim", "at_unix_ms": 1}),
             tail("b", "active"), tail("c", "active")]
    r = run(rung(tmp_path, log=log, calls=calls, tails=tails))
    assert r["reclaim"]["correct"] == 1 and r["reclaim"]["wrong"] == 0


def test_reclaim_unknown_idle_is_listed_not_resolved(tmp_path):
    log = [start_line("a", "vm-a", ts=logts(0)), start_line("b", "vm-b", ts=logts(0)),
           end_line("a", "vm-a", "memory_reclaim", ts=logts(100))]
    calls = [call("a", 1, 9)]  # b has no call at all
    tails = [tail("a", "none", {"state": "end", "reason": "memory_reclaim", "at_unix_ms": 1}), tail("b", "active")]
    r = run(rung(tmp_path, log=log, calls=calls, tails=tails))
    assert r["reclaim"]["unknown"] == 1 and not r["criterion3_order_pass"]


# ---- (c) refusals, (d) guards ----

def sample(t, budget=0, vms=0, executing=0, high=0, oom=0, ends=None):
    w = {"refusals": {"memory-budget": budget} if budget else {}}
    if vms:
        w["leaseVMs"] = vms
    if executing:
        w["leaseExecuting"] = executing
    if ends:
        w["leaseEnds"] = ends
    return {"t": t, "ts": BASE + t, "mem_available_kb": 9000000, "worker": w,
            "e15_mem_events": {"high": high, "max": 0, "oom_kill": oom}}


def test_refusal_with_idle_lease_counted(tmp_path):
    s = [sample(0), sample(1, vms=3, executing=3), sample(2, budget=1, vms=3, executing=3),   # all busy: fine
         sample(3, budget=1, vms=3, executing=1), sample(4, budget=3, vms=3, executing=1)]    # 2 refusals, idle
    r = run(rung(tmp_path, calls=[call("a", 1, 0)], tails=[tail("a")], samples=s))
    f = r["refusals"]
    assert f["memory_budget_total"] == 3
    assert f["with_idle_lease"] == 2
    assert not r["criterion3_refusals_pass"]


def test_refusal_while_all_leases_executing_is_not_counted(tmp_path):
    s = [sample(0, vms=3, executing=3), sample(1, budget=2, vms=3, executing=3)]
    r = run(rung(tmp_path, calls=[call("a", 1, 0)], tails=[tail("a")], samples=s))
    assert r["refusals"]["memory_budget_total"] == 2 and r["refusals"]["with_idle_lease"] == 0
    assert r["criterion3_refusals_pass"]


def test_refusals_without_worker_stats_are_unclassified(tmp_path):
    s = [sample(0), {"t": 1, "ts": BASE + 1}, sample(2, budget=1)]
    r = run(rung(tmp_path, calls=[call("a", 1, 0)], tails=[tail("a")], samples=s))
    assert r["refusals"]["unclassified"] and not r["criterion3_refusals_pass"]


def test_guard_events_counted(tmp_path):
    s = [sample(0, high=5, oom=0), sample(1, high=9, oom=1), sample(2, high=12, oom=2)]
    p = {"oom_kills": 2, "memory_abort": {"reason": "memory_floor", "at": "x", "mem_available_kb": 1, "floor_mib": 1024}}
    r = run(rung(tmp_path, calls=[call("a", 1, 0)], tails=[tail("a")], samples=s, params=p))
    g = r["guards"]
    assert g["memory_high"] == 7 and g["oom_kills"] == 2 and g["memory_floor"] == 1
    assert g["total"] == 10 and not r["criterion3_guards_pass"]


def test_no_guard_events_passes(tmp_path):
    s = [sample(0), sample(1)]
    r = run(rung(tmp_path, calls=[call("a", 1, 0)], tails=[tail("a")], samples=s, params={"oom_kills": 0, "memory_abort": None}))
    assert r["guards"]["total"] == 0 and r["criterion3_guards_pass"]


def test_stats_lease_ends_disagreement_listed(tmp_path):
    s = [sample(0), sample(1, ends={"idle": 2})]
    d = rung(tmp_path, log=[start_line("a", "vm-1", ts=logts(0)), end_line("a", "vm-1", "idle", ts=logts(40))],
             calls=[call("a", 1, 0)], tails=[tail("a", "none", {"state": "end", "reason": "idle", "at_unix_ms": 1})], samples=s)
    r = run(d)
    assert r["stats_lease_ends"]["disagreements"] == [{"reason": "idle", "stats": 2, "log": 1}]


def test_main_writes_lease_ends_json(tmp_path, capsys):
    d = rung(tmp_path, log=[start_line("a", "vm-1", ts=logts(0)), end_line("a", "vm-1", "idle", ts=logts(40))],
             calls=[call("a", 1, 0)], tails=[tail("a", "none", {"state": "end", "reason": "idle", "at_unix_ms": 1})])
    LE.main([d])
    out = json.load(open(os.path.join(d, "lease_ends.json")))
    assert out["criterion4_pass"] is True


def test_fixture_ship_300_squeeze_slice():
    r = LE.analyse(os.path.join(HERE, "testdata", "ship-300-squeeze-slice"))
    assert r["valid"] and r["criterion4_pass"] and r["criterion3_order_pass"]
    assert r["notices"]["paired"] == 2 and r["notices"]["live_at_stop"] == 1
    d = r["reclaim"]["details"][0]
    assert d["victim"] == "s1" and d["verdict"] == "correct" and not d.get("tie_with")
