import json
import os
import sys
import time

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import latency_report as L  # noqa: E402
import warmcold_lease as WL  # noqa: E402
from test_warmcold import T_LOG, call, rung  # noqa: E402

TS = "2026-11-05T11:00:00Z"


def exec_line(key, vm, req=1, kind="command", cold="", err="<nil>", ts=TS):
    return '%s vmpool: exec req=%d workspace_key="%s" kind=%s vm=%s cold="%s" exit=0 err=%s\n' % (
        ts, req, key, kind, vm, cold, err)


def start_line(key, vm, mode="lease", ts=TS):
    return '%s vmpool: lease start workspace_key="%s" vm=%s mode=%s\n' % (ts, key, vm, mode)


def end_line(key, vm, reason="idle", mode="lease", age="5m0.001s", tail="", ts=TS):
    return '%s vmpool: lease end workspace_key="%s" vm=%s mode=%s reason=%s age=%s%s\n' % (
        ts, key, vm, mode, reason, age, tail)


def ev(state, reason="", mode="lease"):
    return {"state": state, "reason": reason, "at_unix_ms": 1, "age_ms": 0, "mode": mode}


def first(key="A", vm="vm-1"):
    return [start_line(key, vm), exec_line(key, vm)]


def tags(rows):
    return {(r["session"], r["call"]): (r["warm"], r["cold_reason"]) for r in rows}


def test_exec_line_with_kind(tmp_path):
    # Review Focus 2: the shipped worker's exec line has kind=, which E17a's regex rejects.
    line = exec_line("A", "vm-1", kind="process_start")
    assert WL.EXEC_RE.search(line)
    assert WL.EXEC_RE.search(line).group("vm") == "vm-1"
    rows, _ = WL.join(rung(tmp_path, [call("A", 1, first_lease=True, lease_events=[ev("start")])],
                           first()))
    assert rows[0]["warm"] is False and rows[0]["vm"] == "vm-1"


def test_tracked_suffix_does_not_break_end_regex():
    line = end_line("A", "vm-1", mode="lease_processes", tail=" processes=[p1:npm test:running p2:sleep 5:exited]")
    m = WL.END_RE.search(line)
    assert m and m.group("reason") == "idle" and m.group("vm") == "vm-1"
    m = WL.END_RE.search(end_line("A", "vm-1", reason="worker_restart"))
    assert m.group("reason") == "worker_restart"


def test_warm_when_same_vm_no_end(tmp_path):
    log = first() + [exec_line("A", "vm-1", req=2)]
    calls = [call("A", 1, first_lease=True, lease_events=[ev("start")]), call("A", 2)]
    rows, s = WL.join(rung(tmp_path, calls, log))
    assert tags(rows)[("A", 2)] == (True, None)
    assert s["disagreements"] == 0 and s["warm"] == 1


def test_cold_after_idle_end(tmp_path):
    log = first() + [end_line("A", "vm-1", "idle"), start_line("A", "vm-2"), exec_line("A", "vm-2", req=2)]
    calls = [call("A", 1, first_lease=True, lease_events=[ev("start")]),
             call("A", 2, lease_events=[ev("end", "idle")])]
    rows, s = WL.join(rung(tmp_path, calls, log))
    assert tags(rows)[("A", 2)] == (False, "idle")
    assert s["disagreements"] == 0


def test_cold_after_reclaim_end(tmp_path):
    log = first() + [end_line("A", "vm-1", "memory_reclaim"), start_line("A", "vm-2"),
                     exec_line("A", "vm-2", req=2)]
    calls = [call("A", 1, first_lease=True, lease_events=[ev("start")]),
             call("A", 2, lease_events=[ev("end", "memory_reclaim")])]
    rows, _ = WL.join(rung(tmp_path, calls, log))
    assert tags(rows)[("A", 2)] == (False, "memory_reclaim")


def test_sources_agree_or_flagged(tmp_path):
    # The log says warm (same vm, no end); the driver's call carries an end event: disagreement 1,
    # reported and not resolved: the log's verdict stands.
    log = first() + [exec_line("A", "vm-1", req=2)]
    calls = [call("A", 1, first_lease=True, lease_events=[ev("start")]),
             call("A", 2, lease_events=[ev("end", "idle")])]
    rows, s = WL.join(rung(tmp_path, calls, log))
    assert tags(rows)[("A", 2)][0] is True
    assert s["disagreements"] == 1
    assert s["disagreement_calls"] == [{"session": "A", "call": 2, "log": "warm", "driver": "cold"}]
    assert s["countable"] is False


def test_replacement_lease_call_carries_only_an_end(tmp_path):
    # The replacement lease's start is in the worker log only; the call's events hold just the end.
    log = first() + [end_line("A", "vm-1", "idle"), start_line("A", "vm-2"), exec_line("A", "vm-2", req=2),
                     exec_line("A", "vm-2", req=3)]
    calls = [call("A", 1, first_lease=True, lease_events=[ev("start")]),
             call("A", 2, lease_events=[ev("end", "idle")]), call("A", 3)]
    rows, s = WL.join(rung(tmp_path, calls, log))
    t = tags(rows)
    assert t[("A", 2)] == (False, "idle") and t[("A", 3)] == (True, None)
    assert {r["call"]: r["in_lease"] for r in rows} == {1: True, 2: True, 3: True}
    assert s["disagreements"] == 0 and s["unknown"] == 0


def test_call_outside_a_live_lease_is_unknown(tmp_path):
    # No lease start before the exec line (a per-exec Exec): never guessed warm or cold.
    rows, s = WL.join(rung(tmp_path, [call("A", 1)], [exec_line("A", "vm-1")]))
    assert rows[0]["warm"] == "unknown" and rows[0]["cold_reason"] == "no-live-lease"
    assert rows[0]["in_lease"] is False and s["unknown"] == 1


def test_first_lease_calls_excluded_from_gates(tmp_path):
    log = first() + [exec_line("A", "vm-1", req=2)]
    calls = [call("A", 1, ms=30000, first_lease=True, lease_events=[ev("start")]), call("A", 2, ms=5000)]
    rows, s = WL.join(rung(tmp_path, calls, log))
    r = {x["call"]: x for x in rows}
    assert r[1]["first_lease"] is True and r[2]["first_lease"] is False
    assert s["first_lease"] == 1 and s["warm"] == 1 and s["cold"] == 0  # the gates count the non-first only
    assert s["cold_by_reason"] == {}


def test_set_mode_failed_is_reported_and_invalidates(tmp_path):
    bad = call("B", 1, execs=0, status="err", cause="set_mode_failed", first_lease=True)
    log = first()
    rows, s = WL.join(rung(tmp_path, [call("A", 1, first_lease=True, lease_events=[ev("start")]), bad], log))
    assert tags(rows)[("B", 1)][0] == "set_mode_failed"
    assert s["set_mode_failed"] == 1 and s["valid"] is False and s["countable"] is False
    assert s["unknown"] == 0 and s["warm"] == 0 and s["cold"] == 0 and s["first_lease"] == 1


def test_exec_count_mismatch_is_unknown(tmp_path):
    rows, s = WL.join(rung(tmp_path, [call("A", 1), call("A", 2)], first()))
    assert all(r["warm"] == "unknown" and r["cold_reason"] == "exec-count" for r in rows)
    assert "A" in s["unknown_keys"]


def test_main_writes_outputs(tmp_path):
    d = rung(tmp_path, [call("A", 1, first_lease=True, lease_events=[ev("start")])], first())
    WL.main([d])
    assert json.loads(open(os.path.join(d, "warmcold.jsonl")).readline())["warm"] is False
    rep = json.load(open(os.path.join(d, "warmcold-report.json")))
    assert rep["valid"] is True and rep["countable"] is True


def params(d, arm, n=1, point="pycache", **kw):
    with open(os.path.join(d, "params.json"), "w") as f:
        json.dump(dict({"arm": arm, "n": n, "point": point, "seed": 1}, **kw), f)
    return d


def test_latency_report_for_ship_arms(tmp_path):
    # ship-120: a first-lease call of 30 s (kept out), a warm py_analyze of 5 s and 7 s (median 6 s),
    # a cold one after an idle end of 20 s. sbx: analyzes of 9, 10, 11 s (median 10 s).
    log = first() + [exec_line("A", "vm-1", req=2), exec_line("A", "vm-1", req=3),
                     end_line("A", "vm-1"), start_line("A", "vm-2"), exec_line("A", "vm-2", req=4)]
    calls = [call("A", 1, ms=30000, first_lease=True, lease_events=[ev("start")]), call("A", 2, ms=5000),
             call("A", 3, ms=7000), call("A", 4, ms=20000, lease_events=[ev("end", "idle")])]
    ship = params(rung(tmp_path, calls, log, name="ship"), "ship-120")
    sbx_log = [exec_line("S", "vm-%d" % i) for i in range(1, 4)]
    sbx_calls = [call("S", 1, ms=9000), call("S", 2, ms=10000), call("S", 3, ms=11000)]
    sbx = params(rung(tmp_path, sbx_calls, sbx_log, name="sbx"), "sbx")
    rep = L.build([ship, sbx], baseline_arm="sbx")
    g = next(x for x in rep["groups"] if x["arm"] == "ship-120")
    pa = g["classes"]["py_analyze"]
    assert pa["warm"]["median_ms"] == 6000 and pa["warm"]["n"] == 2
    assert pa["cold"]["median_ms"] == 20000 and pa["cold"]["n"] == 1
    assert pa["baseline_median_ms"] == 10000 and pa["gain"] == pytest.approx(0.4)
    assert g["first_lease"]["all"]["n"] == 1 and g["first_lease"]["all"]["median_ms"] == 30000
    assert g["first_after_idle"]["all"]["n"] == 1
    assert g["counts"]["used"] == 3 and g["warm_share"] == pytest.approx(2 / 3.0)
    assert g["rungs"][0]["warmcold"]["failed_no_vm"] == 0  # E17B-R35: reported per ship rung


def test_latency_report_arms_filter(tmp_path):
    ship = params(rung(tmp_path, [call("A", 1, first_lease=True, lease_events=[ev("start")])], first(),
                       name="s30"), "ship-30")
    other = params(rung(tmp_path, [call("A", 1)], [exec_line("A", "vm-1")], name="old"), "lease-30")
    sbx = params(rung(tmp_path, [call("S", 1)], [exec_line("S", "vm-1")], name="sbx"), "sbx")
    out = tmp_path / "out"
    L.main([ship, other, sbx, "--baseline-arm", "sbx", "--arms", "ship-30,ship-120,ship-300",
            "--out", str(out)])
    rep = json.load(open(out / "latency.json"))
    assert sorted(g["arm"] for g in rep["groups"]) == ["sbx", "ship-30"]


# ---- fix round 1 ----

def test_multi_exec_call_end_between_its_execs_does_not_make_next_call_cold(tmp_path):
    # Call 2 is a retry: two Execs with a lease end between them (the second on the replacement vm).
    # The next call runs warm on that replacement vm: the end lies before call 2's last Exec.
    log = first() + [exec_line("A", "vm-1", req=2), end_line("A", "vm-1"), start_line("A", "vm-2"),
                     exec_line("A", "vm-2", req=3), exec_line("A", "vm-2", req=4)]
    calls = [call("A", 1, first_lease=True, lease_events=[ev("start")]),
             call("A", 2, execs=2, lease_events=[ev("end", "idle")]), call("A", 3)]
    rows, _ = WL.join(rung(tmp_path, calls, log))
    assert tags(rows)[("A", 3)] == (True, None)


def test_end_after_last_exec_makes_next_call_cold_with_its_reason(tmp_path):
    log = first() + [exec_line("A", "vm-1", req=2), end_line("A", "vm-1", "memory_reclaim"),
                     start_line("A", "vm-2"), exec_line("A", "vm-2", req=3)]
    calls = [call("A", 1, first_lease=True, lease_events=[ev("start")]), call("A", 2),
             call("A", 3, lease_events=[ev("end", "memory_reclaim")])]
    rows, _ = WL.join(rung(tmp_path, calls, log))
    assert tags(rows)[("A", 3)] == (False, "memory_reclaim")


def test_two_keys_interleaved_and_ending_in_the_same_second(tmp_path):
    log = [start_line("A", "vm-1"), start_line("B", "vm-2"), exec_line("A", "vm-1", req=1),
           exec_line("B", "vm-2", req=2),
           end_line("B", "vm-2", "idle"), end_line("A", "vm-1", "memory_reclaim"),
           start_line("A", "vm-3"), exec_line("A", "vm-3", req=3),
           exec_line("B", "vm-2", req=4)]  # B has no live lease again: no start after its end
    calls = [call("A", 1, first_lease=True, lease_events=[ev("start")]),
             call("B", 1, first_lease=True, lease_events=[ev("start")]),
             call("A", 2, lease_events=[ev("end", "memory_reclaim")]),
             call("B", 2, lease_events=[ev("end", "idle")])]
    rows, _ = WL.join(rung(tmp_path, calls, log))
    t = tags(rows)
    assert t[("A", 2)] == (False, "memory_reclaim")
    assert t[("B", 2)] == ("unknown", "no-live-lease")


def test_worker_restart_end_makes_next_call_cold(tmp_path):
    log = first() + [end_line("A", "vm-1", "worker_restart", age="2m0s"), start_line("A", "vm-9"),
                     exec_line("A", "vm-9", req=2)]
    calls = [call("A", 1, first_lease=True, lease_events=[ev("start")]),
             call("A", 2, lease_events=[ev("end", "worker_restart")])]
    rows, s = WL.join(rung(tmp_path, calls, log))
    assert tags(rows)[("A", 2)] == (False, "worker_restart") and s["disagreements"] == 0


def test_driver_field_names_match_the_task3_driver():
    # record.go json tags and lease.go leaseEvent / causeSetMode, as the Task 3 driver writes them.
    drv = os.path.join(HERE, "..", "..", "e15-session-density", "driver")
    rec = open(os.path.join(drv, "record.go")).read()
    lease = open(os.path.join(drv, "lease.go")).read()
    assert 'json:"lease_events,omitempty"' in rec and 'json:"first_lease,omitempty"' in rec
    assert 'causeSetMode      = "%s"' % WL.SET_MODE_FAILED in lease
    assert 'State == "start"' in lease


def lease_ship_dirs(tmp_path, bad=None):
    """Two clean ship-120 rungs and, optionally, a third one with a defect."""
    out = []
    for i in range(2):
        log = [start_line("A", "vm-1"), exec_line("A", "vm-1"), exec_line("A", "vm-1", req=2)]
        calls = [call("A", 1, ms=30000, first_lease=True, lease_events=[ev("start")]), call("A", 2, ms=5000 + i * 2000)]
        out.append(params(rung(tmp_path, calls, log, name="ok%d" % i), "ship-120"))
    if bad == "disagree":
        log = first() + [exec_line("A", "vm-1", req=2)]
        calls = [call("A", 1, first_lease=True, lease_events=[ev("start")]),
                 call("A", 2, ms=99000, lease_events=[ev("end", "idle")])]
        out.append(params(rung(tmp_path, calls, log, name="bad"), "ship-120"))
    if bad == "set_mode":
        log = first() + [exec_line("A", "vm-1", req=2)]
        calls = [call("A", 1, first_lease=True, lease_events=[ev("start")]), call("A", 2, ms=99000),
                 call("B", 1, execs=0, status="err", cause="set_mode_failed", first_lease=True)]
        out.append(params(rung(tmp_path, calls, log, name="bad"), "ship-120"))
    sbx = params(rung(tmp_path, [call("S", 1, ms=10000)], [exec_line("S", "vm-1")], name="sbx"), "sbx")
    return out, sbx


@pytest.mark.parametrize("bad,reason", [("disagree", "disagreements"), ("set_mode", "set_mode_failed")])
def test_uncountable_ship_rung_excluded_from_pool(tmp_path, bad, reason):
    ships, sbx = lease_ship_dirs(tmp_path, bad)
    rep = L.build(ships + [sbx], baseline_arm="sbx")
    g = next(x for x in rep["groups"] if x["arm"] == "ship-120")
    assert g["countable"] is False
    assert [e["dir"] for e in g["excluded_rungs"]] == [ships[2]]
    assert reason in g["excluded_rungs"][0]["reason"]
    pa = g["classes"]["py_analyze"]
    assert pa["warm"]["n"] == 2 and pa["warm"]["median_ms"] == 6000  # the bad rung's 99 s is not pooled
    assert pa["gain"] == pytest.approx(0.4)
    assert len(g["rungs"]) == 2


def test_clean_ship_group_is_countable_and_has_no_excluded_rungs(tmp_path):
    ships, sbx = lease_ship_dirs(tmp_path)
    g = next(x for x in L.build(ships + [sbx])["groups"] if x["arm"] == "ship-120")
    assert g["countable"] is True and g["excluded_rungs"] == []
    r = g["rungs"][0]["warmcold"]
    assert r["valid"] is True and r["countable"] is True and r["disagreements"] == 0 and r["set_mode_failed"] == 0


def test_non_lease_arm_summary_has_no_first_lease_key_and_old_group_shape(tmp_path):
    # Keeps a regenerated E17a latency.json byte-identical: no new keys for non-ship arms.
    d = params(rung(tmp_path, [call("S", 1)], [exec_line("S", "vm-1")], name="old"), "lease-120")
    g = L.build([d])["groups"][0]
    assert "first_lease" not in g and "countable" not in g and "excluded_rungs" not in g
    assert sorted(g["rungs"][0]["warmcold"]) == ["cold", "dropped_end_session_execs", "unknown",
                                                 "unknown_keys", "warm"]


def test_set_mode_failed_rows_not_in_counts(tmp_path):
    rows = [{"session": "B", "call": 1, "class": "x", "observed_ms": 1, "status": "ok", "in_window": True,
             "warm": "set_mode_failed", "cold_reason": "set_mode_failed", "first_lease": False}]
    s = L.summarize(rows)
    assert s["counts"]["calls"] == 0 and s["counts"]["used"] == 0 and s["classes"] == {}


def test_py_shmem_excluded_from_gates(tmp_path):
    # The join still aligns py_shmem's Exec (a call like any other), but its rows never enter the
    # warm/cold counts the latency gates are read with, nor the ship rung's latency classes.
    log = first() + [exec_line("A", "vm-1", req=2), exec_line("A", "vm-1", req=3)]
    calls = [call("A", 1, first_lease=True, lease_events=[ev("start")]), call("A", 2, cls="py_shmem", ms=40),
             call("A", 3)]
    d = rung(tmp_path, calls, log)
    rows, s = WL.join(d)
    assert tags(rows)[("A", 2)] == (True, None) and tags(rows)[("A", 3)] == (True, None)
    assert (s["warm"], s["cold"], s["unknown"], s["reported_only"]) == (1, 0, 0, {"py_shmem": 1})
    with open(os.path.join(d, "params.json"), "w") as f:
        json.dump({"arm": "ship-300", "n": 1, "point": "pycache", "seed": 1}, f)
    g = L.build([d])["groups"][0]
    assert set(g["classes"]) == {"py_analyze"} and g["counts"]["used"] == 1
    assert g["reported_only"]["py_shmem"]["all"]["n"] == 1


# E17B-R35 (PR #34 #4587041739): a call that failed with no vm ran nothing in a VM (a refusal: the
# worker logs its exec line with vm= empty, runner.go:74; or a queue-full call the pool never saw:
# no exec line). It is failed_no_vm, apart from unknown, which keeps meaning an ok call the join
# could not place. The chain gate stops on unknown, not on failed_no_vm.
def test_refused_call_with_no_vm_is_failed_no_vm(tmp_path):
    log = first() + [exec_line("A", "", req=2, err="memory-budget: committing 1280 MiB would exceed"),
                     exec_line("A", "vm-1", req=3)]
    calls = [call("A", 1, first_lease=True, lease_events=[ev("start")]),
             call("A", 2, status="err", cause="exec_error", msg="memory-budget: committing 1280 MiB would exceed"),
             call("A", 3)]
    rows, s = WL.join(rung(tmp_path, calls, log))
    assert tags(rows)[("A", 2)] == ("failed_no_vm", "no-vm")
    assert tags(rows)[("A", 3)] == (True, None)  # the refusal does not break the warm chain
    assert s["unknown"] == 0 and s["unknown_by_reason"] == {}
    assert s["failed_no_vm"] == 1 and s["failed_no_vm_by_reason"] == {"no-vm": 1}
    assert s["warm"] == 1 and s["valid"] is True and s["countable"] is True


def test_queue_full_call_is_failed_no_vm_not_started(tmp_path):
    log = first() + [exec_line("A", "vm-1", req=3)]
    calls = [call("A", 1, first_lease=True, lease_events=[ev("start")]),
             call("A", 2, status="err", cause="rpc_error", msg="busy: queue full"),
             call("A", 3)]
    rows, s = WL.join(rung(tmp_path, calls, log))
    assert tags(rows)[("A", 2)] == ("failed_no_vm", "not-started")
    assert s["unknown"] == 0 and s["failed_no_vm_by_reason"] == {"not-started": 1}


def test_ok_call_with_no_vm_stays_unknown(tmp_path):
    log = first() + [exec_line("A", "", req=2)]
    calls = [call("A", 1, first_lease=True, lease_events=[ev("start")]), call("A", 2)]
    rows, s = WL.join(rung(tmp_path, calls, log))
    assert tags(rows)[("A", 2)] == ("unknown", "no-vm")
    assert s["unknown"] == 1 and s["failed_no_vm"] == 0


# E17B-R42 (PR #34 fix round 2): the driver records each refused call's class (`refused`). failed_no_vm rows are
# counted by that cause; a configuration cause (stale-mode, lease-unsupported, permission-denied, req-id-in-flight)
# in any row is counted apart, and the chain gate stops on it. Load causes stay outcomes.
def test_failed_no_vm_rows_are_counted_by_refusal_cause(tmp_path):
    log = first() + [exec_line("A", "", req=2, err="memory-budget: x"), exec_line("A", "", req=3, err="stale-mode: x"),
                     exec_line("A", "vm-1", req=4)]
    calls = [call("A", 1, first_lease=True, lease_events=[ev("start")]),
             call("A", 2, status="err", cause="exec_error", msg="memory-budget: x", refused="memory-budget"),
             call("A", 3, status="err", cause="exec_error", msg="stale-mode: x", refused="stale-mode"),
             call("A", 4)]
    rows, s = WL.join(rung(tmp_path, calls, log))
    assert s["failed_no_vm"] == 2 and s["failed_no_vm_by_cause"] == {"memory-budget": 1, "stale-mode": 1}
    assert s["config_refusals"] == 1 and s["config_refusals_by_cause"] == {"stale-mode": 1}
    assert {r["call"]: r["refused"] for r in rows} == {1: None, 2: "memory-budget", 3: "stale-mode", 4: None}


def test_config_refusal_on_a_first_refused_row_counts(tmp_path):
    # a session refused on every call (no exec line with a vm): every row failed_no_vm, all of them config refusals
    log = [exec_line("B", "", req=i, err="lease-unsupported: x") for i in (1, 2)]
    calls = [call("B", i, status="err", cause="exec_error", msg="lease-unsupported: x", refused="lease-unsupported",
                  first_refused=True) for i in (1, 2)]
    _, s = WL.join(rung(tmp_path, calls, log))
    assert s["config_refusals"] == 2 and s["failed_no_vm_by_cause"] == {"lease-unsupported": 2}
    assert s["unknown"] == 0


def test_failed_no_vm_without_a_recorded_cause_is_other(tmp_path):
    log = first() + [exec_line("A", "", req=2, err="spawn-failure: x")]
    calls = [call("A", 1, first_lease=True, lease_events=[ev("start")]),
             call("A", 2, status="err", cause="exec_error", msg="spawn-failure: x")]
    _, s = WL.join(rung(tmp_path, calls, log))
    assert s["failed_no_vm_by_cause"] == {"other": 1} and s["config_refusals"] == 0


def test_call_cut_at_the_run_end_after_its_lease_ended_is_cut_at_end_not_unknown(tmp_path):
    # E17B-R54: the driver cut call 2 at its end-of-run deadline; the abort ended the lease (agent_dead) before the
    # Exec's own line. Counted apart, never warm/cold, and not unknown (the gate stops on unknown).
    log = first() + [exec_line("A", "vm-1", req=2), end_line("A", "vm-1", "agent_dead"),
                     exec_line("A", "vm-1", req=3, err="vmpool: aborted")]
    calls = [call("A", 1, first_lease=True, lease_events=[ev("start")]), call("A", 2),
             call("A", 3, status="err", cause="cut_at_end")]
    rows, s = WL.join(rung(tmp_path, calls, log))
    t = tags(rows)
    assert t[("A", 3)] == ("cut_at_end", "cut-at-end")
    assert s["unknown"] == 0 and s["cut_at_end"] == 1
    # the same call without the driver's cut cause stays unknown
    calls[2] = call("A", 3, status="err")
    (tmp_path / "x").mkdir()
    rows, s = WL.join(rung(tmp_path / "x", calls, log))
    assert tags(rows)[("A", 3)] == ("unknown", "no-live-lease") and s["unknown"] == 1


# ---- E17c Task 5: the warm split by the guest's page-cache drop (ruling R-g) ----

def stamp(off):
    """The log's whole-second stamp at T_LOG + off."""
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(T_LOG + off))


def drop_rung(tmp_path, drop="30s", name="ship-300", arm="ship-300"):
    """Session A, every call ending at T_LOG + off + 0.5 (exec line stamped T_LOG + off):
      1 first_lease (ends 0.5)
      2 py_analyze 5 s, starts 41.5: 41 s after call 1 ended -> after_drop
      3 py_analyze 7 s, starts 53.5: 7 s after -> kept
      4 py_analyze 9 s, starts 90.5: exactly 30 s after -> kept (strictly greater is a drop)
      5 py_analyze 15 s, starts 130.5: 31 s after -> after_drop
      6 py_short 1 s, cold after an idle end (vm-2): never tagged
      7 py_short 0.5 s, starts 241.5: 40 s after -> after_drop
    `drop` is params.json's lease_cache_drop (None: the field is absent)."""
    log = [start_line("A", "vm-1"), exec_line("A", "vm-1", ts=stamp(0)),
           exec_line("A", "vm-1", req=2, ts=stamp(46)), exec_line("A", "vm-1", req=3, ts=stamp(60)),
           exec_line("A", "vm-1", req=4, ts=stamp(99)), exec_line("A", "vm-1", req=5, ts=stamp(145)),
           end_line("A", "vm-1"), start_line("A", "vm-2"), exec_line("A", "vm-2", req=6, ts=stamp(201)),
           exec_line("A", "vm-2", req=7, ts=stamp(241))]
    calls = [call("A", 1, ms=1000, end=T_LOG + 0.5, first_lease=True, lease_events=[ev("start")]),
             call("A", 2, ms=5000, end=T_LOG + 46.5), call("A", 3, ms=7000, end=T_LOG + 60.5),
             call("A", 4, ms=9000, end=T_LOG + 99.5), call("A", 5, ms=15000, end=T_LOG + 145.5),
             call("A", 6, cls="py_short", ms=1000, end=T_LOG + 201.5, lease_events=[ev("end", "idle")]),
             call("A", 7, cls="py_short", ms=500, end=T_LOG + 242.0)]
    extra = {} if drop is None else {"lease_cache_drop": drop}
    return params(rung(tmp_path, calls, log, name=name), arm, **extra)


def test_warm_calls_split_by_the_gap_since_the_sessions_previous_call(tmp_path):
    rows, s = WL.join(drop_rung(tmp_path))
    cache = {r["call"]: r.get("cache") for r in rows}
    assert cache == {1: None, 2: "after_drop", 3: "kept", 4: "kept", 5: "after_drop", 6: None, 7: "after_drop"}
    assert "cache" not in rows[0] and "cache" not in rows[5]  # only warm rows carry the tag
    assert s["warm"] == 5 and s["cold"] == 1  # the warm/cold counts are unchanged
    assert s["cache_drop_s"] == 30.0
    assert s["warm_by_cache"] == {"after_drop": 3, "kept": 2}


def test_the_gap_counts_from_the_previous_call_whatever_its_class(tmp_path):
    # Call 7's previous call is call 6 (py_short, cold): 40 s after it ended. A 45 s threshold keeps it,
    # and call 2 (41 s after call 1) too; call 5 (31 s) is kept as well.
    rows, s = WL.join(drop_rung(tmp_path, drop="45s"))
    assert {r["call"]: r.get("cache") for r in rows if r["warm"] is True} == {
        2: "kept", 3: "kept", 4: "kept", 5: "kept", 7: "kept"}
    assert s["warm_by_cache"] == {"after_drop": 0, "kept": 5}


@pytest.mark.parametrize("text,secs", [("30s", 30.0), ("1m0s", 60.0), ("2m30s", 150.0), ("1h0m0s", 3600.0),
                                       ("1m30.5s", 90.5), ("off", None), ("", None), (None, None),
                                       ("thirty", None), ("500ms", None), ("30", None)])
def test_cache_drop_threshold_parses_the_banners_duration(text, secs):
    assert WL.cache_drop_seconds(text) == secs


@pytest.mark.parametrize("drop", ["off", None, "bogus"])
def test_no_drop_tags_nothing_and_writes_todays_bytes(tmp_path, drop):
    # ship-300-nd (off), a rung with no lease_cache_drop field (sbx, every E17b rung) or an unparseable value:
    # no call is tagged, and warmcold.jsonl / warmcold-report.json are byte-identical to a rung with no params.json.
    d = drop_rung(tmp_path, drop=drop, name="nd", arm="ship-300-nd")
    rows, s = WL.join(d)
    assert not any("cache" in r for r in rows)
    assert "warm_by_cache" not in s and "cache_drop_s" not in s
    (tmp_path / "plain").mkdir()
    p = drop_rung(tmp_path / "plain", drop=None, name="p")
    os.remove(os.path.join(p, "params.json"))
    WL.main([d])
    WL.main([p])
    for f in ("warmcold.jsonl", "warmcold-report.json"):
        assert open(os.path.join(d, f)).read() == open(os.path.join(p, f)).read()
