"""E17d's level-2 readings (PLAN-E17D Task 5, spec §14.3): latency_report's warm/restart split and the level-2 gain,
and level2.py's restarts, charge, judged ends, OOM kills and refusal reasons."""
import datetime
import json
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "e16-low-duty", "analysis"))

import latency_report as LR  # noqa: E402
import level2 as L2  # noqa: E402
from test_warmcold import call  # noqa: E402
from test_warmcold_lease import end_line, exec_line, start_line  # noqa: E402

MIB = 1 << 20
L2SRV = [{"id": "1", "name": "l2srv", "pid": 42, "state": "running", "code": 0, "age_ms": 1, "memory_bytes": 500 * MIB}]


def ev(state, reason="", at=1, mode="lease+processes"):
    return {"state": state, "reason": reason, "at_unix_ms": at, "age_ms": 0, "mode": mode}


def pev(state, reason, at, names=("l2srv",)):
    return {"state": state, "reason": reason, "at_unix_ms": at,
            "processes": ["%s (pid 42)" % n for n in names], "tracked": [dict(L2SRV[0], name=n) for n in names]}


def write_rung(tmp_path, name, arm, log, calls, tail=(), point="pycache-l2", n=1, samples=None, **params):
    d = tmp_path / name
    d.mkdir()
    (d / "worker.log").write_text("microvm-worker: attached, serving execs\n" + "".join(log))
    (d / "calls.jsonl").write_text("".join(json.dumps(c) + "\n" for c in calls))
    (d / "lease-tail.jsonl").write_text("".join(json.dumps(t) + "\n" for t in tail))
    if samples is not None:
        (d / "samples.jsonl").write_text("".join(json.dumps(s) + "\n" for s in samples))
    (d / "params.json").write_text(json.dumps(dict({"arm": arm, "n": n, "point": point, "seed": 1}, **params)))
    return str(d)


def l2_rung(tmp_path, name="l2"):
    """Key A at ship-300-l2: a lease-cold restart (its first call: client, start, client), two warm re-queries of 200
    and 300 ms and a warm refit of 11 s; a server-lost restart of 6 s (client, list, start, client); then the lease
    ends idle with l2srv running, and a lease-cold restart of 7 s whose call carries that end's notice."""
    sl = start_line("A", "vm-1", mode="lease+processes")
    log = [sl] + [exec_line("A", "vm-1")] * 3 + [exec_line("A", "vm-1")] * 3 + [exec_line("A", "vm-1")] * 4 + [
        end_line("A", "vm-1", mode="lease+processes", tail=" processes=[1:l2srv:running]"),
        start_line("A", "vm-2", mode="lease+processes")] + [exec_line("A", "vm-2")] * 3
    calls = [
        call("A", 1, cls="py_requery", ms=6500, execs=3, lease_events=[ev("start", at=1)], first_lease=True,
             restart=True, restart_kind="lease_cold", start_ms=40.0),
        call("A", 2, cls="py_requery", ms=200),
        call("A", 3, cls="py_requery", ms=300),
        call("A", 4, cls="py_refit", ms=11000),
        call("A", 5, cls="py_requery", ms=6000, execs=4, restart=True, restart_kind="server_lost", start_ms=50.0,
             process_list=json.dumps([dict(L2SRV[0], state="killed", code=9)])),
        call("A", 6, cls="py_requery", ms=7000, execs=3, restart=True, restart_kind="lease_cold", start_ms=45.0,
             lease_events=[ev("end", "idle", at=5000), ev("start", at=6000)],
             process_events=[pev("end", "idle", 5000)]),
    ]
    return write_rung(tmp_path, name, "ship-300-l2", log, calls,
                      tail=[{"key": "A", "state": "active", "swept_at_unix_ms": 9e12,
                             "processes": [dict(L2SRV[0], id="2")]}])


def l1_rung(tmp_path, name="l1"):
    """Key A at ship-300: a cold first re-query of 6 s, warm re-queries of 5000 and 5400 ms, a warm refit of 16 s."""
    log = [start_line("A", "vm-1")] + [exec_line("A", "vm-1")] * 4
    calls = [call("A", 1, cls="py_requery", ms=6000, lease_events=[ev("start", mode="lease")], first_lease=True),
             call("A", 2, cls="py_requery", ms=5000), call("A", 3, cls="py_requery", ms=5400),
             call("A", 4, cls="py_refit", ms=16000)]
    return write_rung(tmp_path, name, "ship-300", log, calls, tail=[{"key": "A", "state": "active", "swept_at_unix_ms": 9e12}])


def sbx_rung(tmp_path, name="sbx"):
    log = [exec_line("S", "vm-%d" % i) for i in range(1, 5)]
    calls = [call("S", 1, cls="py_requery", ms=6400), call("S", 2, cls="py_requery", ms=6500),
             call("S", 3, cls="py_requery", ms=6600), call("S", 4, cls="py_refit", ms=17400)]
    return write_rung(tmp_path, name, "sbx", log, calls)


def group(rep, arm):
    return next(g for g in rep["groups"] if g["arm"] == arm)


# --- latency_report (reading 1) ---------------------------------------------------------------------------------

def test_warm_means_a_live_lease_and_no_restart(tmp_path):
    rep = LR.build([l2_rung(tmp_path), l1_rung(tmp_path), sbx_rung(tmp_path)])
    rq = group(rep, "ship-300-l2")["classes"]["py_requery"]
    assert (rq["warm"]["n"], rq["warm"]["median_ms"]) == (2, 250)  # the server-lost restart is not warm
    assert rq["restart"]["server_lost"]["n"] == 1 and rq["restart"]["server_lost"]["median_ms"] == 6000
    # the lease-cold restarts: the session's first call is first_lease (reported apart), the other one is cold
    assert rq["restart"]["lease_cold"]["n"] == 1 and rq["cold"]["n"] == 1
    assert rq["restart"]["all"]["n"] == 2


def test_sbx_gives_only_its_all_call_median(tmp_path):
    rep = LR.build([l2_rung(tmp_path), l1_rung(tmp_path), sbx_rung(tmp_path)])
    s = group(rep, "sbx")["classes"]["py_requery"]
    assert s["warm"]["n"] == 0 and s["all"]["median_ms"] == 6500 and "gain" not in s


def test_two_gains_each_with_its_n(tmp_path):
    rep = LR.build([l2_rung(tmp_path), l1_rung(tmp_path), sbx_rung(tmp_path)])
    rq = group(rep, "ship-300-l2")["classes"]["py_requery"]
    assert rq["gain"] == pytest.approx(1 - 250 / 6500.0)
    assert rq["gain_n"] == {"warm": 2, "baseline_all": 3}
    # warm against warm: ship-300-l2's warm median against ship-300's (5200), same point, N and class
    assert rq["gain_vs_l1"] == pytest.approx(1 - 250 / 5200.0)
    assert rq["gain_vs_l1_n"] == {"warm": 2, "l1_warm": 2}
    assert rq["l1_warm_median_ms"] == 5200
    l1 = group(rep, "ship-300")["classes"]["py_requery"]
    assert l1["gain_n"] == {"warm": 2, "baseline_all": 3} and "gain_vs_l1" not in l1


def test_no_level2_group_keeps_the_report_unchanged(tmp_path):
    rep = LR.build([l1_rung(tmp_path), sbx_rung(tmp_path)])
    l1 = group(rep, "ship-300")["classes"]["py_requery"]
    assert "gain_n" not in l1 and "restart" not in l1 and "gain_vs_l1" not in l1


def test_markdown_has_the_level2_table(tmp_path):
    md = LR.markdown(LR.build([l2_rung(tmp_path), l1_rung(tmp_path), sbx_rung(tmp_path)]))
    assert "## Level 2 against level 1" in md and "| pycache-l2 | 1 | ship-300-l2 | py_requery | 2 | 250 | 2 | 5200 | 0.95 |" in md
    assert "## Level 2 against level 1" not in LR.markdown(LR.build([l1_rung(tmp_path, "l1b"), sbx_rung(tmp_path, "sbxb")]))


# --- level2.py: restarts (reading 2) ----------------------------------------------------------------------------

def test_restarts_by_kind_with_cost_and_the_previous_end(tmp_path):
    r = L2.analyse(l2_rung(tmp_path), paired=l1_rung(tmp_path))
    rs = r["restarts"]
    assert rs["total"] == 3
    assert rs["by_kind"]["lease_cold"]["n"] == 2 and rs["by_kind"]["lease_cold"]["median_ms"] == 6750
    assert rs["by_kind"]["server_lost"]["n"] == 1 and rs["by_kind"]["server_lost"]["start_median_ms"] == 50.0
    prev = {(c["call"], c["prev_end_reason"]) for c in rs["calls"]}
    assert prev == {(1, "first"), (5, None), (6, "idle")}  # server-lost: the lease did not end
    assert rs["prev_end_reasons"] == {"first": 1, "idle": 1}


def test_lease_cold_share_beside_the_paired_ship_300_rung(tmp_path):
    r = L2.analyse(l2_rung(tmp_path), paired=l1_rung(tmp_path))
    # ship-300-l2: calls 1 and 6 lease-cold of 6 (the server-lost one ran in a live lease); ship-300: 1 of 4
    assert r["lease_cold_share"] == {"cold": 2, "calls": 6, "share": pytest.approx(2 / 6.0)}
    assert r["paired_lease_cold_share"] == {"cold": 1, "calls": 4, "share": 0.25}


def test_server_lost_rate_over_the_live_requeries(tmp_path):
    r = L2.analyse(l2_rung(tmp_path))
    # py_requery calls that found their lease live: 2, 3 and 5 (5 is the server-lost restart)
    assert r["server_lost_rate"] == {"server_lost": 1, "live_requeries": 3, "rate": pytest.approx(1 / 3.0)}


# --- judged ends and their notices (reading 4) ------------------------------------------------------------------

def ends_rung(tmp_path, extra_log=(), extra_calls=(), tail=None, name="ends"):
    sl = lambda k, vm: start_line(k, vm, mode="lease+processes")  # noqa: E731
    el = lambda k, vm, r, p=" processes=[1:l2srv:running]": end_line(k, vm, reason=r, mode="lease+processes", tail=p)  # noqa: E731
    log = [sl("A", "vm-1"), exec_line("A", "vm-1"), el("A", "vm-1", "idle"), sl("A", "vm-2"), exec_line("A", "vm-2"),
           el("A", "vm-2", "memory_reclaim"),
           '2026-11-05T11:00:00Z vmpool: lease end sync workspace_key="A" vm=vm-2: exit 1, teardown_failed=false, '
           'context deadline exceeded; destroying it anyway\n',
           sl("A", "vm-3"), exec_line("A", "vm-3"),
           sl("B", "vm-4"), exec_line("B", "vm-4"), el("B", "vm-4", "sandbox_deleted"),
           sl("C", "vm-5"), exec_line("C", "vm-5"), el("C", "vm-5", "teardown_failed"),
           sl("D", "vm-6"), exec_line("D", "vm-6"), el("D", "vm-6", "idle", ""),  # no tracked process: not judged
           sl("E", "vm-7"), exec_line("E", "vm-7"), el("E", "vm-7", "agent_dead")] + list(extra_log)
    calls = [call("A", 1, cls="py_requery", lease_events=[ev("start", at=1)], first_lease=True),
             call("A", 2, cls="py_requery", lease_events=[ev("end", "idle", 10), ev("start", at=11)],
                  process_events=[pev("end", "idle", 10)]),
             call("A", 3, cls="py_requery", lease_events=[ev("end", "memory_reclaim", 20), ev("start", at=21)],
                  process_events=[pev("end", "memory_reclaim", 20, names=("other",))]),
             call("B", 1, cls="py_requery", lease_events=[ev("start", at=1)], first_lease=True),
             call("C", 1, cls="py_requery", lease_events=[ev("start", at=1)], first_lease=True),
             call("D", 1, cls="py_requery", lease_events=[ev("start", at=1)], first_lease=True),
             call("E", 1, cls="py_requery", lease_events=[ev("start", at=1)], first_lease=True, cause="cut_at_end",
                  status="err")] + list(extra_calls)
    tails = tail if tail is not None else [{"key": k, "state": "active" if k == "A" else "none", "swept_at_unix_ms": 9e12}
                                           for k in "ABCDE"]
    return write_rung(tmp_path, name, "ship-300-l2", log, calls, tail=tails)


def test_judged_ends_exclude_skip_sync_and_run_cut_ends(tmp_path):
    e = L2.analyse(ends_rung(tmp_path))["ends"]
    judged = {(j["key"], j["n"]): j for j in e["judged"]}
    assert set(judged) == {("A", 1), ("A", 2)}  # B sandbox_deleted, C teardown_failed, E cut by the run; D ran none
    assert e["excluded"] == {"skip_sync": 2, "run_cut": 1, "after_sweep": 0, "carryover": 0}
    assert e["ends_with_running_process"] == 5


def test_each_judged_end_gets_its_notices_and_its_sync_line(tmp_path):
    e = L2.analyse(ends_rung(tmp_path))["ends"]
    j = {(x["key"], x["n"]): x for x in e["judged"]}
    a1, a2 = j[("A", 1)], j[("A", 2)]
    assert (a1["reason"], a1["notices"], a1["names_l2srv"], a1["sync_line"], a1["pass"]) == ("idle", 1, True, False, True)
    # the memory_reclaim end's notice names another process, and its sync logged a line: two reasons it fails
    assert (a2["notices"], a2["names_l2srv"], a2["sync_line"], a2["pass"]) == (1, False, True, False)
    assert e["pass"] is False and e["with_sync_line"] == 1 and "sync_duration_ms" not in a1


def test_an_end_without_its_notice_fails(tmp_path):
    d = ends_rung(tmp_path)
    calls = [json.loads(l) for l in open(os.path.join(d, "calls.jsonl"))]
    for c in calls:
        if c["session"] == "A" and c["call"] == 2:
            c["lease_events"], c["process_events"] = [ev("start", at=11)], []
    with open(os.path.join(d, "calls.jsonl"), "w") as f:
        f.write("".join(json.dumps(c) + "\n" for c in calls))
    j = {(x["key"], x["n"]): x for x in L2.analyse(d)["ends"]["judged"]}
    assert (j[("A", 1)]["notices"], j[("A", 1)]["pass"]) == (0, False)


def test_no_judged_end_is_null_not_a_pass(tmp_path):
    log = [start_line("A", "vm-1", mode="lease+processes"), exec_line("A", "vm-1")]
    d = write_rung(tmp_path, "none", "ship-300-l2", log, [call("A", 1, cls="py_requery", lease_events=[ev("start")], first_lease=True)],
                   tail=[{"key": "A", "state": "active", "swept_at_unix_ms": 9e12}])
    assert L2.analyse(d)["ends"]["pass"] is None


# --- OOM kills and refusal reasons ------------------------------------------------------------------------------

def test_oom_kills_with_the_state_they_left(tmp_path):
    r = L2.analyse(l2_rung(tmp_path))
    ks = r["oom_kills"]
    assert [(k["source"], k["session"], k["name"], k["state"]) for k in ks] == [("process_list", "A", "l2srv", "killed(9)")]
    assert r["oom_kills_l2srv"] == 1


def test_memory_budget_refusals_give_their_why(tmp_path):
    log = ['2026-11-05T11:00:00Z vmpool: memory-budget refusal workspace_key="K%d" why=%s short_by=1 standby_bytes=0 '
           'idle_leases=0 gate_held=0 lease_bytes=0 shed_standbys=0 leases_taken=0 freed=0 reclaim_queue=0/64\n' % (i, w)
           for i, w in enumerate(["futile", "futile", "gates-taken"])]
    d = write_rung(tmp_path, "ref", "ship-300-l2", log, [])
    rf = L2.analyse(d)["refusals"]
    assert rf["total"] == 3 and rf["by_why"] == {"futile": 2, "gates-taken": 1}
    assert rf["lines"][2] == {"key": "K2", "why": "gates-taken", "ts": "2026-11-05T11:00:00Z"}


# --- the level-2 charge (reading 3) -----------------------------------------------------------------------------

T0 = 1793877000


def stamp(t):
    return datetime.datetime.fromtimestamp(int(T0 + t), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def charge_rung(tmp_path, name, arm, fp_at_45, mode="lease+processes", trace="pycache-l2:1:0001"):
    """Key K: one lease on vm-1 (cgroup pool-0) from t=0; its last call ends at t=20; vm_fp is 100 MiB before t=60
    and fp_at_45 MiB from t=60 (the +45 s reading is at t=65)."""
    log = ["%s vmpool: restore phases id=vm-1 prep_us=1 total_us=2\n" % stamp(0),
           '%s vmpool: lease start workspace_key="K" vm=vm-1 mode=%s\n' % (stamp(0), mode),
           '%s vmpool: exec req=1 workspace_key="K" kind=command vm=vm-1 cold="" exit=0 err=<nil>\n' % stamp(20)]
    ts = datetime.datetime.fromtimestamp(T0 + 19, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000000Z")
    calls = [{"ts": ts, "session": "K", "trace": trace, "call": 0, "class": "py_requery", "execs": 1,
              "observed_ms": 1000, "status": "ok", "in_window": True, "lease_events": [ev("start")], "first_lease": True}]
    samples = [{"ts": T0 + t + 0.2, "vm_mem": {"pool-0": 900 * MIB},
                "vm_fp": {"pool-0": (fp_at_45 if t >= 60 else 100) * MIB}} for t in range(0, 120)]
    return write_rung(tmp_path, name, arm, log, calls, samples=samples,
                      tail=[{"key": "K", "state": "active", "swept_at_unix_ms": 9e12}])


def test_the_level2_charge_is_vm_fp_at_45_s_beside_the_paired_lease(tmp_path):
    r = L2.analyse(charge_rung(tmp_path, "l2c", "ship-300-l2", 640),
                   paired=charge_rung(tmp_path, "l1c", "ship-300", 120, mode="lease"))
    ch = r["charge"]
    assert ch["valid"] is True
    (lease,) = ch["leases"]
    assert (lease["session"], lease["vm"], lease["fp_45s_bytes"], lease["paired_fp_45s_bytes"]) == ("K", "vm-1", 640 * MIB, 120 * MIB)
    assert ch["median_fp_45s_bytes"] == 640 * MIB and ch["paired_median_fp_45s_bytes"] == 120 * MIB


def test_charge_without_vm_fp_is_null_with_its_reason(tmp_path):
    d = charge_rung(tmp_path, "nofp", "ship-300-l2", 640)
    rows = [json.loads(l) for l in open(os.path.join(d, "samples.jsonl"))]
    with open(os.path.join(d, "samples.jsonl"), "w") as f:
        for s in rows:
            s.pop("vm_fp")
            f.write(json.dumps(s) + "\n")
    ch = L2.analyse(d)["charge"]
    assert ch["valid"] is False and ch["leases"] is None and "vm_fp" in ch["reason"]


# --- the chain's warm count -------------------------------------------------------------------------------------

def test_warm_count_is_the_smallest_pooled_class_count(tmp_path):
    a, b = l2_rung(tmp_path, "s1"), l2_rung(tmp_path, "s2")
    assert L2.warm_count([a, b], ["py_requery", "py_refit"]) == {"py_requery": 4, "py_refit": 2, "min": 2}


def test_cli_writes_level2_json(tmp_path):
    d = l2_rung(tmp_path)
    L2.main([d, "--paired", l1_rung(tmp_path)])
    out = json.load(open(os.path.join(d, "level2.json")))
    assert out["arm"] == "ship-300-l2" and out["restarts"]["total"] == 3
