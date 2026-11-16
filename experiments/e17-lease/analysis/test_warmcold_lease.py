import json
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import latency_report as L  # noqa: E402
import warmcold_lease as WL  # noqa: E402
from test_warmcold import call, rung  # noqa: E402

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
