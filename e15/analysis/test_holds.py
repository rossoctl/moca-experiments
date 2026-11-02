import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import holds as H
import record as R


def call(i=0, added=100, status="ok", cause="", execs=1, provider="a", cls="x", tail=0):
    planned = 1000
    return dict(session="s", provider=provider, **{"class": cls}, execs=execs,
                planned_dur_ms=planned, tail_ms=tail, observed_ms=planned - tail + added,
                status=status, cause=cause, in_window=True)


def sess(pace, n=5):
    return dict(session="s", window_calls=n, planned_ms=1000, observed_ms=1000 * (1 + pace))


def good_calls():
    return [call(added=a) for a in [50] * 18 + [150, 150]]


def test_holds_all_green():
    r = H.evaluate(good_calls(), [sess(0.05)] * 3, 100)
    assert r["holds"] and r["p95_added_ms"] == 150 and r["failed_calls"] == 0


def test_fails_on_one_failed_call():
    c = good_calls() + [call(status="err", cause="rpc_error")]
    assert not H.evaluate(c, [sess(0.05)], 100)["holds"]


def test_control_exit_mismatch_ok_but_other_causes_fail():
    c = [call(status="err", cause="exit_mismatch")]
    assert H.evaluate(c, [sess(0)], 100, arm="control")["holds"]
    assert not H.evaluate(c, [sess(0)], 100, arm="sbx")["holds"]


def test_not_started_deadline_not_failure():
    c = [call(), call(status="err", cause="deadline", execs=0)]
    r = H.evaluate(c, [sess(0)], 100)
    assert r["holds"] and r["not_started"] == 1


def test_tail_subtracted():
    assert H.added_ms(call(added=40, tail=300)) == 40


def test_fails_on_refusal_line(tmp_path):
    (tmp_path / "worker.log").write_text("ok\nmemory-budget: 900 MiB requested\n")
    (tmp_path / "calls.jsonl").write_text(json.dumps(call()) + "\n")
    (tmp_path / "sessions.jsonl").write_text(json.dumps(sess(0)) + "\n")
    rec = R.build(str(tmp_path), dict(arm="sbx", n=1, warmup_s=0, window_s=10, baseline_p95_ms=None))
    assert rec["refusals"] == 1 and not rec["holds"]
    assert rec["binding"] == "gate" and rec["refusal_scope"] == "all_lines"


def test_pace_boundary():
    assert H.evaluate([call()], [sess(0.10)], None)["holds"]
    assert not H.evaluate([call()], [sess(0.1001)], None)["holds"]


def test_p95_boundary():
    assert H.evaluate([call(added=200)], [sess(0)], 100)["holds"]
    assert not H.evaluate([call(added=201)], [sess(0)], 100)["holds"]


def test_baseline_none_skips_cond4():
    r = H.evaluate([call(added=9999)], [sess(0)], None)
    assert r["holds"] and r["p95_added_ms"] == 9999


def test_excludes_short_sessions():
    r = H.evaluate([call()], [sess(5.0, n=2), sess(0.0, n=3)], 100)
    assert r["sessions_excluded_lt3"] == 1 and r["holds"]


def _rung(tmp_path, samples, **extra):
    (tmp_path / "samples.jsonl").write_text("\n".join(json.dumps(s) for s in samples))
    p = dict(arm="sbx", n=1, warmup_s=0, window_s=120, floor_mb=1536, baseline_p95_ms=None)
    p.update(extra)
    return R.build(str(tmp_path), p)


def S(t, mem=10_000_000, cpu=10.0, disk=10.0, vm=None):
    d = dict(t=t, mem_available_kb=mem, host_cpu_busy_pct=cpu, disk_used_pct=disk)
    if vm is not None:
        d["vm_mem"] = vm
    return d


def test_binding_memory(tmp_path):
    r = _rung(tmp_path, [S(1), S(2, mem=1536 * 1024)])
    assert r["binding"] == "memory_floor"


def test_binding_cpu(tmp_path):
    r = _rung(tmp_path, [S(t, cpu=95) for t in range(0, 121)])
    assert r["binding"] == "cpu"
    r = _rung(tmp_path, [S(t, cpu=95 if t < 50 else 10) for t in range(0, 121)])
    assert r["binding"] == "none"


def test_binding_disk(tmp_path):
    assert _rung(tmp_path, [S(1, disk=90)])["binding"] == "disk"


MiB = 1 << 20


def test_footprint_drift(tmp_path):
    s = [S(0, vm={"a": 400 * MiB, "b": 400 * MiB}), S(120, vm={"a": 450 * MiB, "b": 450 * MiB})]
    r = _rung(tmp_path, s, arm="resident-inf")
    assert abs(r["footprint_drift_pct"] - 12.5) < 1e-9 and r["repeat_required"]
    r = _rung(tmp_path, s, arm="sbx")
    assert "footprint_drift_pct" not in r


import pytest


def test_empty_window():
    r = H.evaluate([], [sess(0)], 100)
    assert not r["holds"] and r["reason"] == "empty_window"
    r = H.evaluate([call()], [sess(0, n=2)], 100)
    assert not r["holds"] and r["reason"] == "empty_window"


def test_out_of_window_excluded():
    out = dict(call(status="err", cause="rpc_error"), in_window=False)
    r = H.evaluate([call(), out], [sess(0)], 100)
    assert r["holds"] and r["window_calls"] == 1


def test_baseline_nonpositive_floor():
    assert H.evaluate([call(added=2)], [sess(0)], 0)["holds"]
    assert not H.evaluate([call(added=3)], [sess(0)], 0)["holds"]
    assert H.evaluate([call(added=2)], [sess(0)], -5)["p95_limit_ms"] == 2.0


def test_multi_session_median_and_splits():
    ss = [sess(0.01), sess(0.5), sess(0.02)]
    assert abs(H.evaluate([call()], ss, None)["median_pace"] - 0.02) < 1e-9
    c = [call(provider="a", cls="x", added=10), call(provider="b", cls="y", added=300),
         call(provider="b", cls="y", status="err", cause="unavailable")]
    r = H.evaluate(c, [sess(0)], None)
    assert r["by_provider"]["b"]["failed"] == 1 and r["by_provider"]["b"]["p95_added_ms"] == 300
    assert r["by_class"]["x"]["p95_added_ms"] == 10 and r["causes"] == {"unavailable": 1}


@pytest.mark.parametrize("line,hit", [
    ("memory-budget: 1 GiB over", True), ("host-memory: low", True),
    ("max-runs: 5", True), ("spawn-failure: boom", True), ("busy: queue full", True),
    ("rpc RESOURCE_EXHAUSTED", True), ("Out of memory: Killed process 4", True),
    ("oom-kill:constraint=", True), ("pod OOMKilled", True),
    ("the room is ready", False), ("busybox started", False),
    ("microvm-worker: relay=x memory-budget: 1", False)])
def test_refusal_forms(tmp_path, line, hit):
    p = tmp_path / "worker.log"
    p.write_text(line + "\n")
    assert (R.count_refusals(str(p))[0] == 1) is hit


def test_refusals_by_reason(tmp_path):
    p = tmp_path / "worker.log"
    p.write_text("max-runs: a\nmax-runs: b\nbusy: queue full\n")
    assert R.count_refusals(str(p))[2] == {"max-runs": 2, "busy": 1}


def test_window_scoped_refusals(tmp_path):
    p = tmp_path / "worker.log"
    p.write_text("2026-01-01T00:00:05Z max-runs: early\n2026-01-01T00:01:30Z max-runs: in\n"
                 "2026-01-01T00:05:00Z max-runs: late\n")
    base = R._parse_ts("2026-01-01T00:00:00Z")
    n, scope, _ = R.count_refusals(str(p), base + 60, base + 120)
    assert (n, scope) == (1, "window")


def test_binding_precedence_and_cpu_boundary(tmp_path):
    s = [S(t, cpu=95, disk=95, mem=1) for t in range(0, 121)]
    assert _rung(tmp_path, s)["binding"] == "memory_floor"
    s = [S(t, cpu=95, disk=95) for t in range(0, 121)]
    assert _rung(tmp_path, s)["binding"] == "cpu"
    s = [S(t, cpu=90) for t in range(0, 121)]
    assert _rung(tmp_path, s)["binding"] == "cpu"
    s = [S(t, disk=95) for t in range(0, 121)]
    assert _rung(tmp_path, s)["binding"] == "disk"


def test_a2_rows_filtering():
    hdr = dict(header=True, num_cpu=2, t=0)
    ftr = dict(footer=True, t=999)
    one = [hdr, ftr, dict(t=5, utime_ms=1, stime_ms=1)]
    assert R.driver_cpu(one, 0, 10)["a2_ok"] is False
    same = [hdr, dict(t=5, utime_ms=1, stime_ms=1), dict(t=5, utime_ms=9, stime_ms=1)]
    d = R.driver_cpu(same, 5, 5)
    assert d["a2_pct_of_host"] is None and d["a2_ok"] is False
    two = [hdr, dict(t=0, utime_ms=0, stime_ms=0), dict(t=10, utime_ms=100, stime_ms=0)]
    assert R.driver_cpu(two, 0, 10)["a2_pct_of_host"] == 100 / (10 * 1000.0 * 2) * 100


def test_windows_use_warmup_offset(tmp_path):
    rows = [dict(header=True, num_cpu=1)] + [
        dict(t=t, utime_ms=t * 10 if t <= 60 else 600 + (t - 60) * 100, stime_ms=0)
        for t in range(0, 181)]
    (tmp_path / "driver-cpu.jsonl").write_text("\n".join(json.dumps(x) for x in rows))
    (tmp_path / "calls.jsonl").write_text(json.dumps(call()) + "\n")
    (tmp_path / "samples.jsonl").write_text("\n".join(json.dumps(S(t, mem=1 if t < 60 else 10**7))
                                                     for t in range(0, 181)))
    r = R.build(str(tmp_path), dict(arm="sbx", n=1, warmup_s=60, window_s=120))
    assert r["binding"] == "none" and r["window_samples"] == 121
    assert r["driver"]["window_cpu_ms"] == 12000


def test_time_origin_mismatch(tmp_path):
    rows = [dict(header=True, num_cpu=1, t0_epoch=1000.0)]
    (tmp_path / "driver-cpu.jsonl").write_text(json.dumps(rows[0]))
    (tmp_path / "calls.jsonl").write_text(json.dumps(call()) + "\n")
    base = dict(arm="sbx", n=1, warmup_s=0, window_s=10)
    assert R.build(str(tmp_path), dict(base, rung_start_ts=1001.0))["time_origin_mismatch"] is False
    r = R.build(str(tmp_path), dict(base, rung_start_ts=1003.0))
    assert r["time_origin_mismatch"] and not r["holds"]


def test_aborted_and_a2(tmp_path):
    rows = [dict(header=True, num_cpu=4, gomaxprocs=4, goos="l", goarch="a"),
            dict(t=0, utime_ms=500, stime_ms=0), dict(t=120, utime_ms=1000, stime_ms=800),
            dict(footer=True, end_sessions_sent=3, end_sessions_ok=3, end_sessions_failed=0)]
    (tmp_path / "driver-cpu.jsonl").write_text("\n".join(json.dumps(x) for x in rows))
    (tmp_path / "calls.jsonl").write_text(json.dumps(call()) + "\n")
    r = _rung(tmp_path, [S(1)], driver_exit=2)
    assert r["aborted"] and not r["holds"]
    # (1800-500)/(120*1000*4)*100 = 0.27%
    assert r["driver"]["a2_ok"] and abs(r["driver"]["a2_pct_of_host"] - 1300 / 4800.0) < 1e-9
    assert r["driver"]["end_sessions"]["end_sessions_ok"] == 3


def test_cli(tmp_path):
    (tmp_path / "calls.jsonl").write_text(json.dumps(call()) + "\n")
    (tmp_path / "sessions.jsonl").write_text(json.dumps(sess(0)) + "\n")
    pj = tmp_path / "params.json"
    pj.write_text(json.dumps(dict(arm="sbx", n=1, warmup_s=0, window_s=10)))
    R.main([str(tmp_path), "--params", str(pj)])
    assert json.load(open(tmp_path / "record.json"))["holds"] is True


# --- fix round 1 (Task 7): OOM kills and the absolute-latency verdict -------------------------

def test_oom_kills_are_refusals(tmp_path):
    (tmp_path / "calls.jsonl").write_text("\n".join(json.dumps(c) for c in good_calls()))
    (tmp_path / "sessions.jsonl").write_text(json.dumps(sess(0)) + "\n")
    r = _rung(tmp_path, [S(1)], oom_kills=0)
    assert r["holds"] and r["refusals"] == 0
    r = _rung(tmp_path, [S(1)], oom_kills=2)
    assert not r["holds"] and not r["holds_abs"]
    assert r["refusals"] == 2 and r["refusals_by_reason"]["oom_kill"] == 2
    assert r["conditions"]["no_refusals"] is False and r["binding"] == "gate"


def test_holds_abs_adds_250ms_not_2x():
    # baseline 100 ms: 2x limit 200 ms, absolute limit 350 ms; p95 here is 300 ms
    c = [call(added=a) for a in [50] * 18 + [300, 300]]
    r = H.evaluate(c, [sess(0.05)] * 3, 100)
    assert r["p95_added_ms"] == 300
    assert not r["holds"] and r["holds_abs"]
    assert r["p95_limit_abs_ms"] == 350 and r["conditions_abs"]["added_latency"]
    c = [call(added=a) for a in [50] * 18 + [400, 400]]
    r = H.evaluate(c, [sess(0.05)] * 3, 100)
    assert not r["holds"] and not r["holds_abs"]


def test_holds_abs_n1_skips_latency_and_shares_other_conditions():
    c = [call(added=a) for a in [50] * 18 + [5000, 5000]]
    r = H.evaluate(c, [sess(0.05)] * 3, None)
    assert r["holds"] and r["holds_abs"] and r["p95_limit_abs_ms"] is None
    bad = c + [call(status="err", cause="rpc_error")]
    r = H.evaluate(bad, [sess(0.05)] * 3, None)
    assert not r["holds"] and not r["holds_abs"]


def test_holds_abs_forced_false_with_holds(tmp_path):
    (tmp_path / "calls.jsonl").write_text("\n".join(json.dumps(c) for c in good_calls()))
    (tmp_path / "sessions.jsonl").write_text(json.dumps(sess(0)) + "\n")
    r = _rung(tmp_path, [S(1)], driver_exit=1)
    assert not r["holds"] and not r["holds_abs"]
    (tmp_path / "driver-cpu.jsonl").write_text(json.dumps(dict(header=True, num_cpu=1, t0_epoch=1000.0)))
    r = _rung(tmp_path, [S(1)], rung_start_ts=1010.0)
    assert r["time_origin_mismatch"] and not r["holds_abs"]
