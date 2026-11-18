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


def tail(key, state="none", pending=None, error=None, swept=None):
    r = {"key": key}
    if swept is not None:  # seconds after BASE: the driver's swept_at_unix_ms (E17B-R31)
        r["swept_at_unix_ms"] = int(round((BASE + swept) * 1000))
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
    # PR #34 nit (E17B-R41e, R14): a duplicate is informational -- the worker re-tells an event until it is
    # acknowledged, harmlessly (lease_event.go:124) -- so it does not fail criterion 4.
    assert r["criterion4_pass"] is True
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


# ---- E17B-R31: a live lease that ends after the status sweep ----

def after_sweep_rung(tmp_path, end_at, state="active", swept=100.4, name="rung"):
    """Key a: a lease live at the sweep (state), ending at log second end_at with no notice; key b: one
    paired end. The sweep (swept s after BASE) is in whole log second 100."""
    d = tmp_path / name
    d.mkdir()
    return rung(d, log=[start_line("a", "vm-1", ts=logts(0)), start_line("b", "vm-2", ts=logts(0)),
                        end_line("b", "vm-2", "idle", ts=logts(40)), end_line("a", "vm-1", "idle", ts=logts(end_at))],
                calls=[call("a", 1, 0), call("b", 1, 0)],
                tails=[tail("a", state, swept=swept),
                       tail("b", "none", {"state": "end", "reason": "idle", "at_unix_ms": 1}, swept=swept)])


def test_live_key_ending_after_the_sweep_is_ended_after_sweep(tmp_path):
    r = run(after_sweep_rung(tmp_path, end_at=130))
    n = r["notices"]
    assert n["ended_after_sweep"] == 1 and n["unmatched_ends"] == []
    assert n["ended_after_sweep_ends"] == [{"key": "a", "n": 1, "reason": "idle", "ts": BASE + 130}]
    assert n["live_at_stop"] == 1 and n["paired"] == 1 and n["ends_in_log"] == 2
    assert r["criterion4_pass"] is True and r["valid"]


def test_end_in_the_sweeps_own_second_counts_only_for_a_key_live_at_the_sweep(tmp_path):
    # whole-second log time 100 is the sweep's own second (sweep at 100.4): the key was live at the
    # sweep, so its end came after the status call.
    n = run(after_sweep_rung(tmp_path, end_at=100, name="same-second"))["notices"]
    assert n["ended_after_sweep"] == 1 and n["unmatched_ends"] == []
    # a second earlier: the status said active after this end was logged -> unmatched, not explained
    r = run(after_sweep_rung(tmp_path, end_at=99, name="before"))
    assert r["notices"]["ended_after_sweep"] == 0
    assert r["notices"]["unmatched_ends"] == [{"key": "a", "n": 1, "reason": "idle"}]
    assert r["criterion4_pass"] is False
    # a key NOT live at the sweep (state none, no pending): an end in or after the sweep second is unmatched
    for at, name in ((100, "none-same"), (130, "none-after")):
        r = run(after_sweep_rung(tmp_path, end_at=at, state="none", name=name))
        assert r["notices"]["ended_after_sweep"] == 0 and len(r["notices"]["unmatched_ends"]) == 1
        assert r["criterion4_pass"] is False
    # an expiring lease is live at the sweep too
    n = run(after_sweep_rung(tmp_path, end_at=130, state="expiring", name="expiring"))["notices"]
    assert n["ended_after_sweep"] == 1 and n["unmatched_ends"] == []


def test_tail_without_swept_at_keeps_the_end_unmatched(tmp_path):
    # a driver before E17B-R31 wrote no swept_at_unix_ms: nothing to compare with, so it stays unmatched
    r = run(after_sweep_rung(tmp_path, end_at=130, swept=None))
    assert r["notices"]["ended_after_sweep"] == 0 and len(r["notices"]["unmatched_ends"]) == 1
    assert r["criterion4_pass"] is False


def test_only_ends_after_the_sweep_is_vacuous(tmp_path):
    d = rung(tmp_path, log=[start_line("a", "vm-1", ts=logts(0)), end_line("a", "vm-1", "idle", ts=logts(130))],
             calls=[call("a", 1, 0)], tails=[tail("a", "active", swept=100.4)])
    r = run(d)
    assert r["notices"]["ended_after_sweep"] == 1 and r["criterion4_pass"] is None


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


# ---- fix round 1 ----

def reclaim_calls(calls, victim="a", t=100, keys="abc"):
    log = [start_line(k, "vm-" + k, ts=logts(0)) for k in keys]
    log.append(end_line(victim, "vm-" + victim, "memory_reclaim", ts=logts(t)))
    tails = [tail(k, "active") if k != victim else
             tail(k, "none", {"state": "end", "reason": "memory_reclaim", "at_unix_ms": 1}) for k in keys]
    return rung_in(log, calls, tails)


def rung_in(log, calls, tails, **kw):
    import tempfile
    import pathlib
    d = pathlib.Path(tempfile.mkdtemp(prefix="le-"))
    return rung(d, log=log, calls=calls, tails=tails, **kw)


def test_reclaim_victim_that_resumes_after_the_reclaim_is_judged_on_its_pre_reclaim_idle():
    calls = [call("a", 1, 9), call("a", 2, 150), call("b", 1, 49), call("c", 1, 59)]
    r = run(reclaim_calls(calls))
    assert r["reclaim"]["details"][0]["verdict"] == "correct"


def test_reclaim_non_victim_with_a_post_reclaim_call_is_still_idle_at_the_reclaim():
    # b's last Exec by T ended at 10 (idle 90); a (the victim) ended at 50: the pick is wrong.
    calls = [call("a", 1, 49), call("b", 1, 9), call("b", 2, 150), call("c", 1, 59)]
    r = run(reclaim_calls(calls))
    d = r["reclaim"]["details"][0]
    assert d["verdict"] == "wrong" and d["longest_idle"] == "b"


def test_reclaim_tie_boundary_is_one_second():
    ok = run(reclaim_calls([call("a", 1, 9.1), call("b", 1, 8.2), call("c", 1, 59)]))
    assert ok["reclaim"]["details"][0]["verdict"] == "correct"
    assert ok["reclaim"]["details"][0]["tie_with"] == ["b"]
    # a ends 10.5 (idle 89.5), b ends 9.0 (idle 91.0): 1.5 s short -> wrong
    bad = run(reclaim_calls([call("a", 1, 9.5), call("b", 1, 8.0), call("c", 1, 59)]))
    assert bad["reclaim"]["details"][0]["verdict"] == "wrong"


def test_calls_are_ordered_by_call_number_not_file_order():
    d = rung(tempdir(),
             log=[start_line("a", "vm-1", ts=logts(0)), end_line("a", "vm-1", "reset", ts=logts(10)),
                  start_line("a", "vm-2", ts=logts(11)), end_line("a", "vm-2", "idle", ts=logts(50))],
             calls=[call("a", 2, 20, events=[end_ev("idle", 2)]), call("a", 1, 0, events=[end_ev("reset", 1)])],
             tails=[tail("a")])
    r = run(d)
    assert not r["notices"]["reason_mismatches"] and r["criterion4_pass"]


def tempdir():
    import tempfile
    import pathlib
    return pathlib.Path(tempfile.mkdtemp(prefix="le-"))


def test_expiring_lease_is_live_at_stop():
    r = run(rung(tempdir(), log=[start_line("a", "vm-1", ts=logts(0))], calls=[call("a", 1, 0)],
                 tails=[tail("a", "expiring")]))
    assert r["notices"]["live_at_stop"] == 1 and r["notices"]["live_at_stop_keys"] == ["a"]


def test_set_mode_failed_row_is_not_an_exec_in_the_reclaim_spans():
    # b's real Exec ended at 10; a set_mode_failed row at 95 ran no Exec and must not make b look active.
    calls = [call("a", 1, 49), call("b", 1, 9), call("b", 2, 94, dur=0.1, cause="set_mode_failed", status="err"),
             call("c", 1, 59)]
    d = reclaim_calls(calls)
    assert run(d)["reclaim"]["details"][0]["verdict"] == "wrong"


def test_row_that_never_ran_an_exec_is_not_a_span():
    calls = [call("a", 1, 49), call("b", 1, 9), call("b", 2, 94, dur=0.1, cause="deadline", status="err", execs=0),
             call("c", 1, 59)]
    assert run(reclaim_calls(calls))["reclaim"]["details"][0]["verdict"] == "wrong"


def test_reclaim_victim_executing_across_the_reclaim_is_its_own_verdict():
    calls = [call("a", 1, 95, dur=20), call("b", 1, 9), call("c", 1, 59)]
    r = run(reclaim_calls(calls))
    assert r["reclaim"]["details"][0]["verdict"] == "victim_executing"
    assert r["reclaim"]["victim_executing"] == 1 and r["reclaim"]["unknown"] == 0 and r["reclaim"]["wrong"] == 0
    assert not r["criterion3_order_pass"]


def test_refusal_counts_when_only_the_earlier_sample_has_an_idle_lease():
    s = [sample(0, vms=3, executing=1), sample(1, budget=2, vms=3, executing=3)]
    r = run(rung(tempdir(), calls=[call("a", 1, 0)], tails=[tail("a")], samples=s))
    assert r["refusals"]["with_idle_lease"] == 2


def test_refusal_counts_when_only_the_later_sample_has_an_idle_lease():
    s = [sample(0, vms=3, executing=3), sample(1, budget=2, vms=3, executing=1)]
    r = run(rung(tempdir(), calls=[call("a", 1, 0)], tails=[tail("a")], samples=s))
    assert r["refusals"]["with_idle_lease"] == 2


def test_refusal_counter_reset_counts_the_new_value():
    s = [sample(0, budget=5, vms=2, executing=1), sample(1, budget=2, vms=2, executing=1)]
    r = run(rung(tempdir(), calls=[call("a", 1, 0)], tails=[tail("a")], samples=s))
    f = r["refusals"]
    assert f["counter_resets"] == 1 and f["memory_budget_total"] == 2 and f["with_idle_lease"] == 2


def host_sample(t, host=0, vms=0, executing=0):
    s = sample(t, vms=vms, executing=executing)
    if host:
        s["worker"]["refusals"]["host-memory"] = host
    return s


def test_host_memory_refusal_with_idle_lease_is_counted_and_gated_separately():
    s = [host_sample(0, vms=2, executing=1), host_sample(1, host=3, vms=2, executing=1)]
    r = run(rung(tempdir(), calls=[call("a", 1, 0)], tails=[tail("a")], samples=s))
    f = r["refusals"]
    assert f["host_memory_total"] == 3 and f["host_memory_with_idle_lease"] == 3
    assert f["memory_budget_total"] == 0 and f["with_idle_lease"] == 0
    assert not r["criterion3_refusals_pass"]


def test_host_memory_refusal_with_all_leases_executing_passes():
    s = [host_sample(0, vms=2, executing=2), host_sample(1, host=3, vms=2, executing=2)]
    r = run(rung(tempdir(), calls=[call("a", 1, 0)], tails=[tail("a")], samples=s))
    assert r["refusals"]["host_memory_total"] == 3 and r["criterion3_refusals_pass"]


def test_criterion4_is_null_when_no_lease_ended():
    r = run(rung(tempdir(), log=[start_line("a", "vm-1", ts=logts(0))], calls=[call("a", 1, 0)],
                 tails=[tail("a", "active")]))
    assert r["valid"] and r["criterion4_pass"] is None


def test_criterion4_is_false_when_the_rung_is_invalid():
    r = run(rung(tempdir(), log=[start_line("a", "vm-1", ts=logts(0)), end_line("a", "vm-1", "idle", ts=logts(9))],
                 calls=[call("a", 1, 0, cause="set_mode_failed", status="err")],
                 tails=[tail("a", "none", {"state": "end", "reason": "idle", "at_unix_ms": 1})]))
    assert not r["valid"] and r["criterion4_pass"] is False


# ---- PR #34 review ----

def test_reclaim_skips_a_lease_whose_call_was_sent_in_the_reclaim_second():
    # E17B-R38, the reviewer's example: K1 is the longest-idle lease, but its next call is sent at T+0.3 and the
    # reclaim fires at T+0.6 (logged at the whole second T). The worker skips K1 (its gate is held) and correctly
    # reclaims K2. K1 is possibly_executing: not a candidate, so the pick reads correct.
    calls = [call("k1", 1, 9), call("k1", 2, 100.3, dur=5), call("k2", 1, 49), call("k3", 1, 79)]
    r = run(reclaim_calls(calls, victim="k2", keys=("k1", "k2", "k3")))
    d = r["reclaim"]["details"][0]
    assert d["verdict"] == "correct" and d["possibly_executing"] == ["k1"] and "k1" not in d["idle_s"]
    assert r["reclaim"]["wrong"] == 0 and r["criterion3_order_pass"] is True


def test_reclaim_call_sent_just_before_the_reclaim_second_is_not_possibly_executing():
    # A call sent at T-0.2 that ended at T-0.1 is an ordinary Exec end: k1 is idle 0.1 s, k3 is the longest idle.
    calls = [call("k1", 1, 99.8, dur=0.1), call("k2", 1, 49), call("k3", 1, 9)]
    d = run(reclaim_calls(calls, victim="k2", keys=("k1", "k2", "k3")))["reclaim"]["details"][0]
    assert d["verdict"] == "wrong" and d["longest_idle"] == "k3" and d["possibly_executing"] == []


def test_reclaim_victim_call_carrying_this_reclaims_notice_is_its_replacement_lease():
    # The victim's call sent in [T, T+1) that carries THIS reclaim's end notice came after the reclaim (it runs in the
    # replacement lease): it is not the victim's last Exec end before the reclaim (fix round 2, minor 1).
    calls = [call("a", 1, 9), call("a", 2, 100.4, dur=0.3, events=[end_ev("memory_reclaim")]), call("b", 1, 49),
             call("c", 1, 59)]
    d = run(reclaim_calls(calls))["reclaim"]["details"][0]
    assert d["verdict"] == "correct" and d["idle_s"]["a"] == 90.0


def test_reclaim_victim_short_call_in_the_old_lease_just_before_the_reclaim_still_counts():
    # A victim call sent at T+0.2 that ended at T+0.5, before the reclaim at T+0.6, with no end notice ran in the
    # reclaimed lease: the worker reclaimed a lease idle 0.1 s, a real wrong pick, and it must read wrong.
    calls = [call("a", 1, 9), call("a", 2, 100.2, dur=0.3), call("b", 1, 49), call("c", 1, 59)]
    d = run(reclaim_calls(calls))["reclaim"]["details"][0]
    assert d["verdict"] == "wrong" and d["longest_idle"] == "b"


def test_order_pass_is_null_without_a_reclaim():
    # E17B-R39: no reclaim at all is vacuous, as criterion 4 is: null, never a pass.
    r = run(rung(tempdir(), log=[start_line("a", "vm-1", ts=logts(0)), end_line("a", "vm-1", "idle", ts=logts(40))],
                 calls=[call("a", 1, 0)], tails=[tail("a", "none", {"state": "end", "reason": "idle", "at_unix_ms": 1})]))
    assert r["reclaim"]["total"] == 0 and r["criterion3_order_pass"] is None


def test_guards_are_unavailable_without_mem_events():
    # E17B-R39: params.json always exists, so it is no evidence that no guard fired: without e15_mem_events in
    # the samples the reading is unavailable and the check null.
    s = [{"t": 0, "ts": BASE, "worker": {"refusals": {}}}, {"t": 1, "ts": BASE + 1, "worker": {"refusals": {}}}]
    r = run(rung(tempdir(), calls=[call("a", 1, 0)], tails=[tail("a")], samples=s,
                 params={"oom_kills": 0, "memory_abort": None}))
    assert r["guards"]["available"] is False and r["criterion3_guards_pass"] is None
    r = run(rung(tempdir(), calls=[call("a", 1, 0)], tails=[tail("a")], params={"oom_kills": 0}))
    assert r["guards"]["available"] is False and r["criterion3_guards_pass"] is None


def test_a_guard_event_in_params_fails_even_without_mem_events():
    # A recorded event is evidence of an event: a memory abort or an OOM kill in params fails the check.
    r = run(rung(tempdir(), calls=[call("a", 1, 0)], tails=[tail("a")], params={"oom_kills": 1}))
    assert r["guards"]["available"] is False and r["guards"]["total"] == 1 and r["criterion3_guards_pass"] is False


def test_host_memory_refusals_are_guard_events_whether_or_not_a_lease_was_idle():
    # E17B-R39: a host-memory refusal is the worker's physical backstop firing: a guard event at any time.
    s = [host_sample(0, vms=2, executing=2), host_sample(1, host=3, vms=2, executing=2)]
    r = run(rung(tempdir(), calls=[call("a", 1, 0)], tails=[tail("a")], samples=s))
    g = r["guards"]
    assert g["host_memory"] == 3 and g["total"] == 3 and r["criterion3_guards_pass"] is False
    assert r["criterion3_refusals_pass"] is True  # no idle lease: the refusal check itself passes


# ---- E17B-R54: a lease ended by the driver's end-of-run cut ----

def run_cut_rung(tmp_path, end_at, cut_at=100.2, last_cause="cut_at_end", name="cut"):
    """Key a: its last call (sent cut_at s after BASE) is cut at the run's end; the lease ends agent_dead at log
    second end_at with no notice. Key b: one paired idle end."""
    d = tmp_path / name
    d.mkdir()
    return rung(d, log=[start_line("a", "vm-1", ts=logts(0)), start_line("b", "vm-2", ts=logts(0)),
                        end_line("b", "vm-2", "idle", ts=logts(40)), end_line("a", "vm-1", "agent_dead", ts=logts(end_at))],
                calls=[call("a", 1, 0), call("a", 2, cut_at, status="err", cause=last_cause), call("b", 1, 0)],
                tails=[tail("a"), tail("b", "none", {"state": "end", "reason": "idle", "at_unix_ms": 1})])


def test_end_after_the_run_cut_is_ended_by_run_cut(tmp_path):
    r = run(run_cut_rung(tmp_path, end_at=730))
    n = r["notices"]
    assert n["ended_by_run_cut"] == 1 and n["unmatched_ends"] == []
    assert n["ended_by_run_cut_ends"] == [{"key": "a", "n": 1, "reason": "agent_dead", "ts": BASE + 730}]
    assert r["criterion4_pass"] is True and r["valid"]


def test_end_before_the_cut_or_without_a_cut_stays_unmatched(tmp_path):
    for name, kw in (("before", dict(end_at=99, cut_at=100.2)), ("nocut", dict(end_at=730, last_cause=""))):
        r = run(run_cut_rung(tmp_path, name=name, **kw))
        assert r["notices"]["ended_by_run_cut"] == 0, name
        assert r["notices"]["unmatched_ends"] == [{"key": "a", "n": 1, "reason": "agent_dead"}], name
        assert r["criterion4_pass"] is False, name
