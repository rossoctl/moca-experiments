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
    (tmp_path / "worker.log").write_text("ok\nhost-floor reached\n")
    (tmp_path / "calls.jsonl").write_text(json.dumps(call()) + "\n")
    rec = R.build(str(tmp_path), dict(arm="sbx", n=1, warmup_s=0, window_s=10, baseline_p95_ms=None))
    assert rec["refusals"] == 1 and not rec["holds"]
    assert rec["binding"] == "gate" and rec["refusal_scope"] == "all_lines"


def test_pace_boundary():
    assert H.evaluate([call()], [sess(0.10)], None)["holds"]
    assert not H.evaluate([call()], [sess(0.1001)], None)["holds"]


def test_p95_boundary():
    assert H.evaluate([call(added=200)], [], 100)["holds"]
    assert not H.evaluate([call(added=201)], [], 100)["holds"]


def test_baseline_none_skips_cond4():
    r = H.evaluate([call(added=9999)], [], None)
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
    pj = tmp_path / "params.json"
    pj.write_text(json.dumps(dict(arm="sbx", n=1, warmup_s=0, window_s=10)))
    R.main([str(tmp_path), "--params", str(pj)])
    assert json.load(open(tmp_path / "record.json"))["holds"] is True
