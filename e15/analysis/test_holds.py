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


def BL(excess=100, gmed=0, medians=None, **kw):
    d = dict(class_medians=medians or {}, global_median_ms=gmed, excess_p95_ms=excess, n1_median_pace=0.0)
    d.update(kw)
    return d


def good_calls():
    return [call(added=a) for a in [50] * 18 + [150, 150]]


def test_holds_all_green():
    r = H.evaluate(good_calls(), [sess(0.05)] * 3, BL())
    assert r["holds"] and r["p95_added_ms"] == 150 and r["failed_calls"] == 0


def test_fails_on_one_failed_call():
    c = good_calls() + [call(status="err", cause="rpc_error")]
    assert not H.evaluate(c, [sess(0.05)], BL())["holds"]


def test_control_exit_mismatch_ok_but_other_causes_fail():
    c = [call(status="err", cause="exit_mismatch")]
    assert H.evaluate(c, [sess(0)], BL(), arm="control")["holds"]
    assert not H.evaluate(c, [sess(0)], BL(), arm="sbx")["holds"]


def test_not_started_deadline_not_failure():
    c = [call(), call(status="err", cause="deadline", execs=0)]
    r = H.evaluate(c, [sess(0)], BL())
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
    # class pace (medians {}, global 0 here: expected = planned): inclusive at 0.10; the N=1 pace
    # is reported but no longer enters the verdict
    bl = BL(excess=1000, n1_median_pace=0.193)
    assert H.evaluate([call()], [sess(0.10)], bl)["holds"]
    r = H.evaluate([call()], [sess(0.1001)], bl)
    assert not r["holds"] and not r["holds_abs"] and not r["conditions"]["pace"]
    assert abs(r["median_class_pace"] - 0.1001) < 1e-9 and r["n1_median_pace"] == 0.193
    assert H.evaluate([call()], [sess(0.293)], BL(excess=1000, n1_median_pace=0.193))["holds"] is False


def test_n1_skips_pace_and_holds_with_slow_pace():
    r = H.evaluate([call()], [sess(0.193)], None)
    assert r["holds"] and r["holds_abs"] and r["median_pace"] is not None
    assert r["pace_excess"] is None and r["n1_median_pace"] is None
    assert H.evaluate([call()], [sess(0.5)], None)["holds"]


def test_control_exempt_from_pace():
    (r,) = [H.evaluate([call()], [sess(0.9)], None, arm="control")]
    assert r["holds"]


def test_p95_boundary():
    assert H.evaluate([call(added=300)], [sess(0)], BL())["holds"]
    assert not H.evaluate([call(added=301)], [sess(0)], BL())["holds"]


def test_baseline_none_skips_cond4():
    r = H.evaluate([call(added=9999)], [sess(0)], None)
    assert r["holds"] and r["p95_added_ms"] == 9999


def test_excludes_short_sessions():
    r = H.evaluate([call()], [sess(5.0, n=2), sess(0.0, n=3)], BL())
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
    r = H.evaluate([], [sess(0)], BL())
    assert not r["holds"] and r["reason"] == "empty_window"
    r = H.evaluate([call()], [sess(0, n=2)], BL())
    assert not r["holds"] and r["reason"] == "empty_window"


def test_out_of_window_excluded():
    out = dict(call(status="err", cause="rpc_error"), in_window=False)
    r = H.evaluate([call(), out], [sess(0)], BL())
    assert r["holds"] and r["window_calls"] == 1


def test_baseline_nonpositive_floor():
    assert H.evaluate([call(added=50)], [sess(0)], BL(excess=0))["holds"]
    assert not H.evaluate([call(added=51)], [sess(0)], BL(excess=0))["holds"]
    assert H.evaluate([call(added=3)], [sess(0)], BL(excess=-5))["excess_limit_ms"] == 50.0
    assert H.evaluate([call(added=3)], [sess(0)], BL(excess=100))["excess_limit_ms"] == 300.0


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


def test_holds_abs_excess_B_plus_250ms():
    # B = 100: 3x limit 300, absolute limit 350 (inclusive)
    bl = BL(excess=100)
    c = [call(added=350)]
    r = H.evaluate(c, [sess(0.05)], bl)
    assert r["p95_limit_abs_ms"] == 350 and r["holds_abs"] and r["conditions_abs"]["added_latency"]
    assert not r["holds"]            # primary limit is 300
    r = H.evaluate([call(added=351)], [sess(0.05)], bl)
    assert not r["holds"] and not r["holds_abs"]
    # a small B no longer makes the absolute rule tighter than B + 250
    r = H.evaluate([call(added=260)], [sess(0.05)], BL(excess=10))
    assert r["p95_limit_abs_ms"] == 260 and r["holds_abs"]


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


# --- Task 8a: one Exec per recorded call --------------------------------------------------

def test_cut_at_end_not_failure_and_excluded_from_latency():
    c = good_calls() + [call(status="err", cause="cut_at_end", added=99999)]
    r = H.evaluate(c, [sess(0.05)], BL())
    assert r["holds"] and r["failed_calls"] == 0 and r["cut_at_end"] == 1
    assert r["p95_added_ms"] == 150 and r["causes"] == {"cut_at_end": 1}
    assert r["by_class"]["x"]["failed"] == 0 and r["by_class"]["x"]["p95_added_ms"] == 150
    # a cut call outside the window is not counted
    out = dict(call(status="err", cause="cut_at_end"), in_window=False)
    assert H.evaluate(good_calls() + [out], [sess(0)], BL())["cut_at_end"] == 0


def test_window_added_ms_ok_in_window_only():
    out = dict(call(added=7), in_window=False)
    cs = [call(added=10), call(added=20, status="err", cause="rpc_error"),
          call(added=30, status="err", cause="cut_at_end"), out, call(added=40)]
    assert H.window_added_ms(cs) == [10, 40]


import baseline as B  # noqa: E402


def _rung_dir(tmp_path, name, added):
    d = tmp_path / name
    d.mkdir()
    rows = [call(added=a) for a in added]
    rows.append(call(added=5000, status="err", cause="cut_at_end"))
    rows.append(dict(call(added=9000), in_window=False))
    (d / "calls.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
    (d / "record.json").write_text(json.dumps(
        dict(library_sha256="L", driver_bin_sha256="D", corpus_sha256="C")))
    (d / "sessions.jsonl").write_text(json.dumps(sess(0.1)) + "\n")
    return str(d)


def test_baseline_pools_three_dirs(tmp_path):
    # 3 x 10 in-window ok calls: added 1..30 ms. Nearest-rank p95 of 30 values is the
    # ceil(0.95 * 30) = 29th smallest = 29. Each run alone would give 10, 20, 30.
    dirs = [_rung_dir(tmp_path, "N1-s%d" % k, range(10 * k - 9, 10 * k + 1)) for k in (1, 2, 3)]
    out = tmp_path / "baseline.json"
    B.main([str(out)] + dirs)
    got = json.loads(out.read_text())
    assert got["baseline_p95_ms"] == 29 and got["calls"] == 30
    assert [r["dir"] for r in got["runs"]] == dirs
    assert [r["calls"] for r in got["runs"]] == [10, 10, 10]
    assert [r["p95_added_ms"] for r in got["runs"]] == [10, 20, 30]


def test_baseline_needs_a_dir_and_calls(tmp_path):
    with pytest.raises(SystemExit):
        B.main([str(tmp_path / "b.json")])
    empty = tmp_path / "e"
    empty.mkdir()
    (empty / "calls.jsonl").write_text("")
    with pytest.raises(SystemExit):
        B.main([str(tmp_path / "b.json"), str(empty)])
    assert not (tmp_path / "b.json").exists()


# --- Task 8a fix round 1 ------------------------------------------------------------------

def test_cut_at_end_needs_an_exec():
    # cut_at_end with no Exec sent is not a run-end cut the driver can produce: a failure
    c = good_calls() + [call(status="err", cause="cut_at_end", execs=0)]
    r = H.evaluate(c, [sess(0)], BL())
    assert not r["holds"] and r["failed_calls"] == 1 and r["cut_at_end"] == 0


def _n1(tmp_path, name, added, **hashes):
    d = _rung_dir(tmp_path, name, added)
    rec = dict(library_sha256="L", driver_bin_sha256="D", corpus_sha256="C")
    rec.update(hashes)
    (tmp_path / name / "record.json").write_text(json.dumps(rec))
    return d


def test_baseline_records_hashes(tmp_path):
    dirs = [_n1(tmp_path, "N1-s%d" % k, [k]) for k in (1, 2, 3)]
    out = tmp_path / "baseline.json"
    B.main([str(out)] + dirs)
    got = json.loads(out.read_text())
    assert (got["library_sha256"], got["driver_bin_sha256"], got["corpus_sha256"]) == ("L", "D", "C")


@pytest.mark.parametrize("key", ["library_sha256", "driver_bin_sha256", "corpus_sha256"])
def test_baseline_dies_on_hash_disagreement(tmp_path, key):
    dirs = [_n1(tmp_path, "N1-s1", [1]), _n1(tmp_path, "N1-s2", [2], **{key: "other"})]
    out = tmp_path / "baseline.json"
    with pytest.raises(SystemExit):
        B.main([str(out)] + dirs)
    assert not out.exists()


def test_baseline_dies_on_missing_record(tmp_path):
    d = _rung_dir(tmp_path, "N1-s1", [1])
    os.remove(os.path.join(d, "record.json"))
    with pytest.raises(SystemExit):
        B.main([str(tmp_path / "b.json"), d])


# --- Task 8: empty-window seeds skipped ----------------------------------------------------

def test_baseline_records_evaluable_and_skipped(tmp_path, monkeypatch):
    dirs = [_rung_dir(tmp_path, "N1-s%d" % k, range(1, 11)) for k in (1, 3, 4)]
    monkeypatch.setenv("E15_BASELINE_SEEDS", "1 3 4")
    monkeypatch.setenv("E15_BASELINE_SKIPPED", "2:s2:empty_window")
    out = tmp_path / "baseline.json"
    B.main([str(out)] + dirs)
    got = json.loads(out.read_text())
    assert [e["seed"] for e in got["evaluable"]] == [1, 3, 4]
    assert [e["dir"] for e in got["evaluable"]] == dirs
    assert got["skipped"] == [{"seed": 2, "tag": "s2", "reason": "empty_window"}]
    assert got["calls"] == 30


# --- class-matched condition 4 -------------------------------------------------------------

def test_class_medians_and_fallback():
    cs = [call(added=a, cls="x") for a in (10, 20, 30, 40, 50)] + [call(added=500, cls="y")] * 4
    m, g = H.class_medians(cs)
    assert m == {"x": 30} and g == 50  # y has 4 < 5 calls: omitted; global over all 9 ok calls
    exc, fb = H.excess_ms([call(added=100, cls="x"), call(added=100, cls="y")], m, g)
    assert exc == [70, 50] and fb == 1
    out = dict(call(added=1, cls="x"), in_window=False)
    assert H.excess_ms([out, call(added=9, status="err", cause="rpc_error")], m, g) == ([], 0)


def test_excess_p95_and_floor_boundary():
    bl = BL(excess=10, medians={"x": 100}, gmed=100)
    assert H.evaluate([call(added=150)], [sess(0)], bl)["holds"]       # excess 50 = floor
    r = H.evaluate([call(added=151)], [sess(0)], bl)
    assert not r["holds"] and r["p95_excess_ms"] == 51 and r["excess_limit_ms"] == 50.0


def test_heavy_class_matches_its_median():
    # heavy class normally +800 ms; light +10. Old pooled rule (p95 14 ms x 3) would fail it.
    bl = BL(excess=10, medians={"heavy": 800, "light": 10}, gmed=10)
    c = [call(added=810, cls="heavy"), call(added=15, cls="light")] * 10
    r = H.evaluate(c, [sess(0)], bl)
    assert r["holds"] and r["p95_added_ms"] == 810 and r["p95_excess_ms"] == 10
    slow = [call(added=a + 200, cls=k) for k, a in (("heavy", 800), ("light", 10))] * 10
    r = H.evaluate(slow, [sess(0)], bl)
    assert not r["holds"] and r["p95_excess_ms"] == 200
    assert r["holds_abs"] is True and r["fallback_calls"] == 0   # limit B + 250 = 260 ms
    worse = [call(added=a + 400, cls=k) for k, a in (("heavy", 800), ("light", 10))] * 10
    r = H.evaluate(worse, [sess(0)], bl)
    assert not r["holds"] and not r["holds_abs"]


def test_record_reads_baseline_path(tmp_path):
    bp = tmp_path / "b.json"
    bp.write_text(json.dumps(BL(excess=10, medians={"x": 100}, gmed=100)))
    (tmp_path / "calls.jsonl").write_text(json.dumps(call(added=130)) + "\n")
    (tmp_path / "sessions.jsonl").write_text(json.dumps(sess(0)) + "\n")
    r = R.build(str(tmp_path), dict(arm="sbx", n=8, warmup_s=0, window_s=10, baseline_path=str(bp)))
    assert r["holds"] and r["p95_excess_ms"] == 30 and r["excess_limit_ms"] == 50.0


def _probe_dir(tmp_path, name, cls, added, status="ok"):
    d = tmp_path / name
    d.mkdir()
    rows = [call(added=a, cls=cls) for a in added]
    if status != "ok":
        rows.append(call(cls=cls, status="err", cause="rpc_error"))
    (d / "calls.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
    return str(d)


def test_baseline_medians_from_probe_only(tmp_path):
    seeded = _rung_dir(tmp_path, "N1-s1", [500] * 10)   # class "x", added 500: must NOT set medians
    px = _probe_dir(tmp_path, "p-x", "x", [10, 20, 30, 40, 50])
    py = _probe_dir(tmp_path, "p-y", "y", [7, 8], status="err")
    out = tmp_path / "b.json"
    B.main([str(out), seeded, "--probe", px, py])
    g = json.loads(out.read_text())
    assert g["class_medians"] == {"x": 30} and g["class_counts"] == {"x": 5, "y": 2}
    assert g["undercovered"] == ["y"] and g["probe_failed"] == {"y": 1}
    assert g["baseline_p95_ms"] == 500 and g["global_median_ms"] == 20
    # excess over own medians: x -20,-10,0,10,20 ; y falls back to global 20: -13,-12
    assert g["excess_p95_ms"] == 20


def test_fallback_share_and_undercovered_in_record(tmp_path):
    bp = tmp_path / "b.json"
    bp.write_text(json.dumps(BL(excess=10, medians={"x": 100}, gmed=100, undercovered=["z"])))
    rows = [call(added=100, cls="x"), call(added=100, cls="z"), call(added=100, cls="x"), call(added=100, cls="z")]
    (tmp_path / "calls.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
    (tmp_path / "sessions.jsonl").write_text(json.dumps(sess(0)) + "\n")
    r = R.build(str(tmp_path), dict(arm="sbx", n=8, warmup_s=0, window_s=10, baseline_path=str(bp)))
    assert r["fallback_calls"] == 2 and r["fallback_share"] == 0.5 and r["undercovered"] == ["z"]


def test_control_without_baseline_skips_condition_4(tmp_path):
    (tmp_path / "calls.jsonl").write_text(json.dumps(call(added=99999)) + "\n")
    (tmp_path / "sessions.jsonl").write_text(json.dumps(sess(0)) + "\n")
    r = R.build(str(tmp_path), dict(arm="control", n=128, warmup_s=0, window_s=10, baseline_path=None))
    assert r["holds"] and r["excess_limit_ms"] is None


# --- make_probe.py -------------------------------------------------------------------------

import make_probe as MP  # noqa: E402


def _probe_fixture(tmp_path):
    corpus = tmp_path / "corpus.jsonl"
    calls = [{"i": i, "class": "read", "work_ms": 10 * (i + 1), "dur_ms": 20 * (i + 1), "chain": False}
             for i in range(6)]
    calls.append({"i": 6, "class": "read", "work_ms": 99999, "dur_ms": 99999, "chain": True})
    corpus.write_text(json.dumps({"session": "s", "user": "u", "provider": "claude", "calls": calls}) + "\n")
    lib = tmp_path / "lib.json"
    lib.write_text(json.dumps({"version": 1, "classes": {
        "read": [{"id": "r", "cmd": "x", "exit": 0, "nominal_ms": 30, "run_ms": 3}],
        "test": [{"id": "t", "cmd": "y", "exit": 0, "nominal_ms": 900, "run_ms": None}]}, "standin": {}}))
    return str(corpus), str(lib)


def test_make_probe_one_session_per_class(tmp_path):
    c, lib = _probe_fixture(tmp_path)
    out = tmp_path / "probe"
    MP.main([c, lib, str(out), "--per-class", "20", "--seed", "3"])
    classes = (out / "classes.txt").read_text().split()
    assert classes == ["build", "host_infra", "opaque", "read", "test"]
    for cls in classes:
        lines = (out / cls / "corpus.jsonl").read_text().splitlines()
        assert len(lines) == 1
        s = json.loads(lines[0])
        assert (s["session"], s["user"], s["provider"]) == ("probe-" + cls, "probe", "probe")
        assert len(s["calls"]) == 20 and {x["class"] for x in s["calls"]} == {cls}
        assert all(not x["chain"] and x["gap_ms"] == 2000 for x in s["calls"])
        assert s["calls"][0]["offset_ms"] == 0
        for prev, x in zip(s["calls"], s["calls"][1:]):
            assert x["offset_ms"] == prev["dur_ms"] + 2000
        rep = json.loads((out / cls / "corpus-report.json").read_text())
        assert rep["span_ms"] == sum(x["offset_ms"] for x in s["calls"]) + s["calls"][-1]["dur_ms"]
    # durations come from the class distribution, chains excluded; classes absent from the
    # corpus use the library's invocation times
    r = json.loads((out / "read" / "corpus.jsonl").read_text())["calls"]
    assert {(x["work_ms"], x["dur_ms"]) for x in r} <= {(10 * k, 20 * k) for k in range(1, 7)}
    t = json.loads((out / "test" / "corpus.jsonl").read_text())["calls"]
    assert {x["dur_ms"] for x in t} == {900}


def test_make_probe_deterministic(tmp_path):
    c, lib = _probe_fixture(tmp_path)
    MP.main([c, lib, str(tmp_path / "a"), "--seed", "5"])
    MP.main([c, lib, str(tmp_path / "b"), "--seed", "5"])
    MP.main([c, lib, str(tmp_path / "c"), "--seed", "6"])
    rd = lambda d: (tmp_path / d / "read" / "corpus.jsonl").read_text()  # noqa: E731
    assert rd("a") == rd("b") and rd("a") != rd("c")
    # validatePlans needs >= 3 calls and a class in the library or the stand-ins; both hold
    # (the Go side is covered by the driver's own tests; no Go in this suite).


def test_b_excludes_undercovered_classes(tmp_path):
    px = _probe_dir(tmp_path, "p-x", "x", [10, 10, 10, 10, 10])
    py = _probe_dir(tmp_path, "p-y", "y", [900, 1000, 800])   # 3 calls: undercovered
    seeded = _rung_dir(tmp_path, "N1-s1", [5] * 10)
    out = tmp_path / "b.json"
    B.main([str(out), seeded, "--probe", px, py])
    g = json.loads(out.read_text())
    assert g["undercovered"] == ["y"] and g["excess_p95_ms"] == 0


def test_probe_failed_uses_arm_and_record_copies_it(tmp_path, monkeypatch):
    d = tmp_path / "pc"
    d.mkdir()
    rows = [call(cls="c") for _ in range(5)] + [call(cls="c", status="err", cause="exit_mismatch")]
    (d / "calls.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
    seeded = _rung_dir(tmp_path, "N1-s1", [5] * 3)
    out = tmp_path / "b.json"
    B.main([str(out), seeded, "--probe", str(d)])
    assert json.loads(out.read_text())["probe_failed"] == {"c": 1}
    monkeypatch.setenv("E15_BASELINE_ARM", "control")
    B.main([str(out), seeded, "--probe", str(d)])
    assert json.loads(out.read_text())["probe_failed"] == {}
    bj = json.loads(out.read_text())
    bj["probe_failed"] = {"c": 2}
    (tmp_path / "b2.json").write_text(json.dumps(bj))
    (tmp_path / "calls.jsonl").write_text(json.dumps(call(cls="c")) + "\n")
    (tmp_path / "sessions.jsonl").write_text(json.dumps(sess(0)) + "\n")
    r = R.build(str(tmp_path), dict(arm="sbx", n=8, warmup_s=0, window_s=10, baseline_path=str(tmp_path / "b2.json")))
    assert r["probe_failed"] == {"c": 2}


def test_make_probe_caps_durations(tmp_path):
    corpus = tmp_path / "c.jsonl"
    corpus.write_text(json.dumps({"calls": [{"class": "read", "work_ms": 90000, "dur_ms": 120000, "chain": False}]}) + "\n")
    lib = tmp_path / "l.json"
    lib.write_text(json.dumps({"classes": {"read": [{"id": "r", "cmd": "x", "nominal_ms": 3}]}}))
    MP.main([str(corpus), str(lib), str(tmp_path / "o"), "--per-class", "4"])
    for x in json.loads((tmp_path / "o" / "read" / "corpus.jsonl").read_text())["calls"]:
        assert x["dur_ms"] == 30000 and x["work_ms"] == 30000


def test_overhead_weighted_by_corpus_share(tmp_path, monkeypatch):
    px = _probe_dir(tmp_path, "p-x", "x", [10] * 5)
    py = _probe_dir(tmp_path, "p-y", "y", [100] * 5)
    pz = _probe_dir(tmp_path, "p-z", "z", [1000] * 5)
    corpus = tmp_path / "corpus.jsonl"
    cs = [{"class": "x"}] * 10 + [{"class": "y"}] * 60 + [{"class": "z"}] * 30
    corpus.write_text(json.dumps({"calls": cs}) + "\n")
    monkeypatch.setenv("E15_BASELINE_CORPUS", str(corpus))
    out = tmp_path / "b.json"
    B.main([str(out), _rung_dir(tmp_path, "N1-s1", [5] * 3), "--probe", px, py, pz])
    g = json.loads(out.read_text())
    assert g["overhead_ms"] == 100          # y holds 60% of the weight
    assert g["class_medians"] == {"x": 10, "y": 100, "z": 1000}
    out2 = tmp_path / "b2.json"
    monkeypatch.delenv("E15_BASELINE_CORPUS")
    B.main([str(out2), _rung_dir(tmp_path, "N1-s2", [5] * 3), "--probe", px])
    assert json.loads(out2.read_text())["overhead_ms"] is None


def test_record_copies_n1_overhead(tmp_path):
    bp = tmp_path / "b.json"
    bp.write_text(json.dumps(BL(excess=10, medians={"x": 100}, gmed=100, overhead_ms=42)))
    (tmp_path / "calls.jsonl").write_text(json.dumps(call(added=100)) + "\n")
    (tmp_path / "sessions.jsonl").write_text(json.dumps(sess(0)) + "\n")
    r = R.build(str(tmp_path), dict(arm="sbx", n=8, warmup_s=0, window_s=10, baseline_path=str(bp)))
    assert r["n1_overhead_ms"] == 42


# --- mem512 fix round 1: disk_io binding, read stats, point_sig in the baseline -------------------

def SD(t, rd=None, aw=None, **kw):
    d = S(t, **kw)
    if rd is not None:
        d["disk_read_mbs"] = rd
    if aw is not None:
        d["disk_await_ms"] = aw
    return d


def test_binding_disk_io(tmp_path):
    # last 60 s of a 120 s window at 95 MB/s against a measured 100 MB/s -> disk_io
    s = [SD(t, rd=10 if t < 60 else 95) for t in range(0, 121)]
    assert _rung(tmp_path, s, disk_read_max_mbs=100.0)["binding"] == "disk_io"
    # 89% of max: not disk_io
    s = [SD(t, rd=89) for t in range(0, 121)]
    assert _rung(tmp_path, s, disk_read_max_mbs=100.0)["binding"] == "none"
    # exactly 90%: disk_io
    s = [SD(t, rd=90) for t in range(0, 121)]
    assert _rung(tmp_path, s, disk_read_max_mbs=100.0)["binding"] == "disk_io"
    # high only before the last 60 s: not disk_io
    s = [SD(t, rd=100 if t < 60 else 0) for t in range(0, 121)]
    assert _rung(tmp_path, s, disk_read_max_mbs=100.0)["binding"] == "none"
    # unknown maximum: never disk_io
    s = [SD(t, rd=500) for t in range(0, 121)]
    assert _rung(tmp_path, s)["binding"] == "none"


def test_binding_disk_io_precedence(tmp_path):
    s = [SD(t, rd=99, mem=1, cpu=95, disk=95) for t in range(0, 121)]
    assert _rung(tmp_path, s, disk_read_max_mbs=100.0)["binding"] == "memory_floor"
    s = [SD(t, rd=99, cpu=95, disk=95) for t in range(0, 121)]
    assert _rung(tmp_path, s, disk_read_max_mbs=100.0)["binding"] == "cpu"
    s = [SD(t, rd=99, disk=95) for t in range(0, 121)]
    assert _rung(tmp_path, s, disk_read_max_mbs=100.0)["binding"] == "disk_io"
    s = [SD(t, rd=10, disk=95) for t in range(0, 121)]
    assert _rung(tmp_path, s, disk_read_max_mbs=100.0)["binding"] == "disk"


def test_disk_read_stats_recorded(tmp_path):
    s = [SD(t, rd=float(t), aw=2.0) for t in range(1, 101)] + [SD(0)]
    r = _rung(tmp_path, s, window_s=120)
    assert r["disk_read_mean_mbs"] == 50.5
    assert r["disk_read_p95_mbs"] == 95.0
    assert r["disk_await_mean_ms"] == 2.0
    r = _rung(tmp_path, [S(1)])
    assert r["disk_read_mean_mbs"] is None and r["disk_read_p95_mbs"] is None


def test_baseline_refuses_mixed_point_sig(tmp_path):
    import subprocess
    dirs = [_rung_dir(tmp_path, "N1-s%d" % k, range(1, 11)) for k in (1, 2)]
    rec = json.loads(open(os.path.join(dirs[1], "record.json")).read())
    rec["point_sig"] = "other"
    open(os.path.join(dirs[1], "record.json"), "w").write(json.dumps(rec))
    r = subprocess.run([sys.executable, os.path.join(os.path.dirname(__file__), "baseline.py"),
                        str(tmp_path / "b.json")] + dirs, capture_output=True, text=True)
    assert r.returncode != 0 and "point_sig" in r.stderr


def test_baseline_carries_point_sig(tmp_path):
    import subprocess
    dirs = [_rung_dir(tmp_path, "N1-s%d" % k, range(1, 11)) for k in (1, 2, 3)]
    for d in dirs:
        rec = json.loads(open(os.path.join(d, "record.json")).read())
        rec["point_sig"] = "SIG"
        open(os.path.join(d, "record.json"), "w").write(json.dumps(rec))
    out = tmp_path / "b.json"
    r = subprocess.run([sys.executable, os.path.join(os.path.dirname(__file__), "baseline.py"),
                        str(out)] + dirs, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert json.loads(out.read_text())["point_sig"] == "SIG"


def _sessions_file(d, paces, n=5):
    (d / "sessions.jsonl").write_text("".join(json.dumps(sess(p, n=n)) + "\n" for p in paces))


def test_baseline_n1_pace_from_seeded_runs_only(tmp_path):
    s1 = _rung_dir(tmp_path, "N1-s1", [5] * 3)
    s2 = _rung_dir(tmp_path, "N1-s2", [5] * 3)
    _sessions_file(tmp_path / "N1-s1", [0.10, 0.30])
    _sessions_file(tmp_path / "N1-s2", [0.20, 9.0], n=2)    # the 2-call session is excluded
    px = _probe_dir(tmp_path, "p-x", "x", [10] * 5)
    _sessions_file(tmp_path / "p-x", [5.0, 5.0, 5.0])        # probe sessions must not count
    out = tmp_path / "b.json"
    B.main([str(out), s1, s2, "--probe", px])
    g = json.loads(out.read_text())
    assert g["n1_pace_sessions"] == 2 and abs(g["n1_median_pace"] - 0.20) < 1e-9


def test_record_carries_n1_pace_and_pace_excess(tmp_path):
    bp = tmp_path / "b.json"
    bp.write_text(json.dumps(BL(excess=10, medians={"x": 100}, gmed=100, n1_median_pace=0.193)))
    (tmp_path / "calls.jsonl").write_text(json.dumps(call(added=100)) + "\n")
    (tmp_path / "sessions.jsonl").write_text(json.dumps(sess(0.25)) + "\n")
    r = R.build(str(tmp_path), dict(arm="sbx", n=8, warmup_s=0, window_s=10, baseline_path=str(bp)))
    assert r["n1_median_pace"] == 0.193 and abs(r["pace_excess"] - 0.057) < 1e-9
    # expected = 1000 planned + 100 (class x median); observed 1250 -> class pace 1250/1100 - 1
    assert abs(r["median_class_pace"] - (1250 / 1100.0 - 1)) < 1e-9 and not r["holds"]


def test_negative_n1_pace_does_not_move_the_verdict():
    bl = BL(excess=1000, n1_median_pace=-0.033)
    assert H.evaluate([call()], [sess(0.10)], bl)["holds"]
    assert not H.evaluate([call()], [sess(0.1001)], bl)["holds"]


def test_baseline_exits_without_pace_sessions(tmp_path):
    s1 = _rung_dir(tmp_path, "N1-s1", [5] * 3)
    _sessions_file(tmp_path / "N1-s1", [0.1], n=2)       # < 3 window calls: no pace session
    px = _probe_dir(tmp_path, "p-x", "x", [10] * 5)
    out = tmp_path / "b.json"
    with pytest.raises(SystemExit) as e:
        B.main([str(out), s1, "--probe", px])
    assert "no N=1 pace" in str(e.value) and not out.exists()


# --- class-matched pace -------------------------------------------------------------------

def csess(session, observed, planned=1000, n=3):
    return dict(session=session, window_calls=n, planned_ms=planned, observed_ms=observed)


def sc(session, i, cls, dur=100, gap=0, trace="t", **kw):
    """A window call record as the driver writes it (calls.jsonl), with its planned dur and gap."""
    d = dict(call(cls=cls, **kw), session=session, trace=trace, call=i, planned_dur_ms=dur, planned_gap_ms=gap)
    return d


def offs(*offsets, trace="t"):
    """{trace: {i: offset_ms}}: the corpus offsets, call 0 first."""
    return {trace: {i: o for i, o in enumerate(offsets)}}


def driver_planned(cs):
    """What replay.go puts in sessions.jsonl planned_ms: sum(dur + gap) minus the last gap."""
    return sum(c["planned_dur_ms"] + c["planned_gap_ms"] for c in cs) - cs[-1]["planned_gap_ms"]


def test_schedule_with_zero_medians_reproduces_planned_ms():
    # gaps 400/0/250 ms; offset = dur + gap, as the extractor writes it
    cs = [sc("a", 0, "x", 100, 400), sc("a", 1, "x", 300, 0), sc("a", 2, "x", 50, 250), sc("a", 3, "x", 80, 10)]
    o = offs(0, 500, 300, 300)
    assert abs(H.expected_ms(cs, o["t"], {}, 0) - driver_planned(cs)) <= 1
    # overlapping emits: the extractor clips the gap to 0 and writes offset = emit_delta < prev dur;
    # the max(send + offset, End) in the schedule restores dur + 0, so the two still agree
    cs = [sc("a", 0, "x", 500, 0), sc("a", 1, "x", 100, 0), sc("a", 2, "x", 100, 70)]
    o = offs(0, 200, 50)
    assert abs(H.expected_ms(cs, o["t"], {}, 0) - driver_planned(cs)) <= 1
    # the last call's gap is after its End, so neither side counts it


def test_class_pace_zero_when_latency_equals_class_medians():
    meds = {"x": 100, "y": 400}
    cs = [sc("a", 0, "x", 100, 300), sc("a", 1, "y", 100, 300), sc("a", 2, "x", 100, 0)]
    o = offs(0, 400, 400)
    exp = H.expected_ms(cs, o["t"], meds, 0)
    paces, ex, np_ = H.class_paces(cs, [csess("a", exp)], meds, 0, o)
    assert abs(paces[0]) < 1e-9 and ex == 0 and np_ == 0
    # a scan-heavy session (large M on some classes) at its medians is 0 as well
    meds = {"scan": 1600, "read": 5}
    cs = [sc("a", i, c, 100, 50) for i, c in enumerate(["scan", "scan", "read", "scan", "read"])]
    o = offs(0, *[150] * 4)
    paces, _, _ = H.class_paces(cs, [csess("a", H.expected_ms(cs, o["t"], meds, 0), n=5)], meds, 0, o)
    assert abs(paces[0]) < 1e-9


def test_slowdown_is_absorbed_by_gaps_longer_than_x():
    meds = {"x": 20}
    cs = [sc("a", i, "x", 100, 500) for i in range(4)]
    o = offs(0, 600, 600, 600)
    exp = H.expected_ms(cs, o["t"], meds, 0)          # 3 x 600 + 100 + 20 = 1920
    assert exp == 1920
    X = 50                                            # < gap - M: every send stays on its offset
    obs = exp + X                                     # only the last call's own +X is visible
    paces, _, _ = H.class_paces(cs, [csess("a", obs, n=4)], meds, 0, o)
    assert abs(paces[0] - X / exp) < 1e-9


def test_slowdown_beyond_gaps_accumulates():
    meds = {"x": 0}
    dur, gap, k, X = 100, 10, 4, 200
    cs = [sc("a", i, "x", dur, gap) for i in range(k)]
    o = offs(0, *[dur + gap] * (k - 1))
    exp = H.expected_ms(cs, o["t"], meds, 0)
    assert exp == (k - 1) * (dur + gap) + dur                 # 430
    # independent simulation of the driver with every call really taking dur + X: a send waits for
    # the previous End when that is later than its planned offset
    send = end = 0
    for i in range(k):
        send = 0 if i == 0 else max(send + dur + gap, end)
        end = send + dur + X
    obs = end
    assert obs == k * (dur + X)                               # 1200: nothing is absorbed
    paces, _, _ = H.class_paces(cs, [csess("a", obs, n=k)], meds, 0, o)
    assert abs(paces[0] - (1200 / 430.0 - 1)) < 1e-9


def test_scan_heavy_session_fails_relative_rule_but_holds_class_pace():
    meds = {"scan": 600, "read": 5}
    cs = [sc("a", i, c, 100, 50, added=meds[c]) for i, c in enumerate(["scan"] * 3 + ["read"] * 2)]
    o = offs(0, *[150] * 4)
    exp = H.expected_ms(cs, o["t"], meds, 0)
    bl = BL(excess=1000, medians=meds, gmed=5, n1_median_pace=0.012)
    r = H.evaluate(cs, [csess("a", exp, planned=driver_planned(cs), n=5)], bl, offsets=o)
    assert r["median_pace"] > 0.19 and r["median_pace"] - r["n1_median_pace"] > 0.10   # old rule fails
    assert abs(r["median_class_pace"]) < 1e-9 and r["holds"] and r["holds_abs"]


def test_class_pace_join_and_window_match_sessions_jsonl():
    meds = {"x": 100, "y": 1000}
    o = offs(0, 100, 100)
    cs = ([sc("a", i, "x", 100, 0) for i in range(3)]
          + [dict(c, in_window=False) for c in [sc("a", 3, "y", 100, 0)] * 5]      # out of window
          + [sc("a", 3, "y", 100, 0, status="err", cause="cut_at_end")]            # cut: not in pace
          + [sc("b", i, "y", 100, 0) for i in range(3)])                           # other session
    exp_a = H.expected_ms(cs[:3], o["t"], meds, 0)
    p = H.class_paces(cs, [csess("a", exp_a), csess("b", 9999)], meds, 0, o)
    assert abs(p[0][0]) < 1e-9 and p[1:] == (0, 0)
    # a failed (err, not cut) in-window call is part of the session's pace window
    cs2 = [sc("a", 0, "x", 100, 0), sc("a", 1, "x", 100, 0), sc("a", 2, "x", 100, 0, status="err", cause="rpc_error")]
    assert abs(H.class_paces(cs2, [csess("a", exp_a)], meds, 0, o)[0][0]) < 1e-9


def test_class_pace_nonpositive_expected_excluded_and_counted():
    meds = {"x": -2000}
    cs = [sc("a", i, "x", 100, 0) for i in range(3)] + [sc("b", 0, "x", 100, 0)]
    paces, ex, nonpos = H.class_paces(cs, [csess("a", 500), csess("b", 900, n=1)], meds, 0)
    assert paces == [] and ex == 1 and nonpos == 1
    r = H.evaluate(cs, [csess("a", 500)], BL(excess=10, medians=meds))
    assert r["pace_excluded_nonpositive"] == 1 and r["median_class_pace"] is None
    # every eligible session dropped as non-positive: the rung is an empty window
    assert not r["holds"] and not r["holds_abs"] and r["reason"] == "empty_window"


def test_global_median_for_unknown_class():
    cs = [sc("a", i, "zzz", 100, 0) for i in range(3)]
    o = offs(0, 100, 100)
    exp = H.expected_ms(cs, o["t"], {}, 100)
    # each call lasts 100 + global median 100 = 200 but its offset is only 100, so every send waits
    # for the previous End: sends 0/200/400, last End 600 (not planned 300 + 3 x 100)
    assert exp == 600
    paces, _, _ = H.class_paces(cs, [csess("a", exp)], {}, 100, o)
    assert abs(paces[0]) < 1e-9


def test_n1_and_control_skip_class_pace():
    r = H.evaluate([sc("s", i, "x") for i in range(3)], [sess(5.0)], None)
    assert r["holds"] and r["median_class_pace"] is None


def test_record_loads_corpus_offsets_for_class_pace(tmp_path):
    # session trace "t" has 3 calls; gaps 500 ms, so a +20 ms class median is absorbed
    corpus = tmp_path / "corpus.jsonl"
    corpus.write_text(
        json.dumps({"session": "t", "user": "u", "provider": "claude", "calls": [
            {"i": i, "class": "x", "dur_ms": 100, "work_ms": 1, "gap_ms": 500, "offset_ms": 0 if i == 0 else 600,
             "chain": False} for i in range(3)]}) + "\n"
        + json.dumps({"session": "other", "user": "u", "provider": "claude", "calls": []}) + "\n")
    cs = [sc("a", i, "x", 100, 500, added=20) for i in range(3)]
    (tmp_path / "calls.jsonl").write_text("".join(json.dumps(c) + "\n" for c in cs))
    bp = tmp_path / "b.json"
    bp.write_text(json.dumps(BL(excess=1000, medians={"x": 20}, gmed=20)))
    exp = 2 * 600 + 100 + 20
    (tmp_path / "sessions.jsonl").write_text(json.dumps(csess("a", exp, planned=1300)) + "\n")
    r = R.build(str(tmp_path), dict(arm="sbx", n=8, warmup_s=0, window_s=10, baseline_path=str(bp),
                                    corpus=str(corpus)))
    assert abs(r["median_class_pace"]) < 1e-9 and r["holds"]
    assert R.corpus_offsets(str(corpus), {"t"}) == {"t": {0: 0, 1: 600, 2: 600}}
    assert R.corpus_offsets(None, {"t"}) == {}


def _join_rung(tmp_path, corpus_calls, with_corpus=True):
    cs = [sc("a", i, "x", 100, 500, added=20) for i in range(3)]
    (tmp_path / "calls.jsonl").write_text("".join(json.dumps(c) + "\n" for c in cs))
    (tmp_path / "sessions.jsonl").write_text(json.dumps(csess("a", 1340, planned=1300)) + "\n")
    bp = tmp_path / "b.json"
    bp.write_text(json.dumps(BL(excess=1000, medians={"x": 20}, gmed=20)))
    p = dict(arm="sbx", n=8, warmup_s=0, window_s=10, baseline_path=str(bp))
    if with_corpus:
        corpus = tmp_path / "corpus.jsonl"
        corpus.write_text(json.dumps({"session": "t", "user": "u", "provider": "claude",
                                      "calls": corpus_calls}) + "\n")
        p["corpus"] = str(corpus)
    return R.build(str(tmp_path), p)


def _corpus_calls(n=3):
    return [{"i": i, "class": "x", "dur_ms": 100, "work_ms": 1, "gap_ms": 500,
             "offset_ms": 0 if i == 0 else 600, "chain": False} for i in range(n)]


def test_corpus_join_correct_has_no_misses(tmp_path):
    r = _join_rung(tmp_path, _corpus_calls())
    assert r["offset_join_misses"] == 0 and r["holds"] and "reason" not in r


def test_missing_trace_or_calls_counts_misses_and_refuses(tmp_path):
    # the trace "t" is absent from the corpus (session id differs): calls 1 and 2 miss
    r = _join_rung(tmp_path, [])
    assert r["offset_join_misses"] == 2
    assert not r["holds"] and not r["holds_abs"] and r["reason"] == "corpus_join_miss"


def test_missing_call_index_counts_one_miss(tmp_path):
    r = _join_rung(tmp_path, _corpus_calls(2))          # call index 2 absent
    assert r["offset_join_misses"] == 1 and not r["holds"] and r["reason"] == "corpus_join_miss"


def test_unset_corpus_path_is_a_miss(tmp_path):
    r = _join_rung(tmp_path, [], with_corpus=False)
    assert r["offset_join_misses"] == 2 and not r["holds"]


def test_n1_never_joins(tmp_path):
    (tmp_path / "calls.jsonl").write_text(json.dumps(sc("a", 0, "x")) + "\n")
    (tmp_path / "sessions.jsonl").write_text(json.dumps(csess("a", 100)) + "\n")
    r = R.build(str(tmp_path), dict(arm="sbx", n=1, warmup_s=0, window_s=10))
    assert r["offset_join_misses"] == 0


# --- Task 8 mem512 OOM incident: rung.sh's memory watchdog ---------------------------------

def test_memory_abort_is_a_memory_floor_failure_not_a_rig_error(tmp_path):
    (tmp_path / "calls.jsonl").write_text("\n".join(json.dumps(c) for c in good_calls()))
    (tmp_path / "sessions.jsonl").write_text(json.dumps(sess(0)) + "\n")
    ab = {"reason": "memory_floor", "at": "2026-11-03T13:53:29Z", "mem_available_kb": 900000, "floor_mib": 1024}
    r = _rung(tmp_path, [S(1)], memory_abort=ab, driver_exit=143)
    assert not r["holds"] and not r["holds_abs"]
    assert r["binding"] == "memory_floor" and r["reason"] == "memory_floor"
    assert r["memory_abort"] == ab
    assert r["refusals_by_reason"]["memory_floor_abort"] == 1 and r["conditions"]["no_refusals"] is False
    assert r["aborted"] is False          # a measured failure: the ladder records it, not a rig error
    r = _rung(tmp_path, [S(1)], memory_abort=None, driver_exit=143)
    assert r["aborted"] is True and r.get("memory_abort") is None   # a plain driver failure still aborts


# --- binding memory_high: e15.slice MemoryHigh throttling (memory.events "high") ------------------

def _ev(t, high, mx=0, oom=0, **kw):
    d = S(t, **kw)
    d["e15_mem_events"] = {"high": high, "max": mx, "oom_kill": oom}
    return d


def _failing(tmp_path):
    (tmp_path / "calls.jsonl").write_text(json.dumps(call(status="error", cause="exec")) + "\n")


def test_memory_high_binds_a_failed_rung_with_no_other_binding(tmp_path):
    _failing(tmp_path)
    r = _rung(tmp_path, [_ev(1, 10), _ev(60, 10), _ev(120, 25)])
    assert not r["holds"] and r["binding"] == "memory_high"
    assert r["memory_events_window"] == {"high": 15, "max": 0, "oom_kill": 0}


def test_memory_high_not_without_a_high_delta_or_events(tmp_path):
    _failing(tmp_path)
    r = _rung(tmp_path, [_ev(1, 10), _ev(120, 10)])
    assert not r["holds"] and r["binding"] == "none"
    r = _rung(tmp_path, [S(1), S(120)])                      # no events data: as before
    assert r["binding"] == "none" and r["memory_events_window"] is None
    # counters before the window do not count (warmup_s=60: window is t 60..180)
    (tmp_path / "samples.jsonl").write_text("\n".join(json.dumps(x) for x in [_ev(10, 0), _ev(60, 50), _ev(180, 50)]))
    r = R.build(str(tmp_path), dict(arm="sbx", n=1, warmup_s=60, window_s=120, floor_mb=1536))
    assert r["binding"] == "none" and r["memory_events_window"]["high"] == 0


def test_memory_high_never_on_a_holding_rung(tmp_path):
    (tmp_path / "calls.jsonl").write_text("\n".join(json.dumps(c) for c in good_calls()))
    (tmp_path / "sessions.jsonl").write_text(json.dumps(sess(0)) + "\n")
    r = _rung(tmp_path, [_ev(1, 0), _ev(120, 99)])
    assert r["holds"] and r["binding"] == "none" and r["memory_events_window"]["high"] == 99


def test_memory_high_yields_to_other_bindings_and_memory_abort(tmp_path):
    _failing(tmp_path)
    assert _rung(tmp_path, [_ev(1, 0), _ev(120, 5, mem=1536 * 1024)])["binding"] == "memory_floor"
    assert _rung(tmp_path, [_ev(1, 0, cpu=95.0), _ev(120, 5, cpu=95.0)])["binding"] == "cpu"
    assert _rung(tmp_path, [_ev(1, 0), _ev(120, 5, disk=95.0)])["binding"] == "disk"
    ab = {"reason": "memory_floor", "at": "2026-11-03T13:53:29Z", "mem_available_kb": 900000, "floor_mib": 1024}
    r = _rung(tmp_path, [_ev(1, 0), _ev(120, 5)], memory_abort=ab, driver_exit=143)
    assert r["binding"] == "memory_floor" and r["reason"] == "memory_floor"
    r = _rung(tmp_path, [_ev(1, 0), _ev(120, 5)], driver_exit=2)   # a rig error gets no binding
    assert r["aborted"] and r["binding"] == "none"


def test_footprint_drift_sum_basis(tmp_path):
    # fresh-metal (drift_basis "sum"): judged on the summed VM memory; the median is information.
    # a: 100 -> 300 MiB (+200%), b and c flat at 1000: median +0%, sum 2100 -> 2300 (+9.5%)
    s = [S(0, vm={"a": 100 * MiB, "b": 1000 * MiB, "c": 1000 * MiB}),
         S(120, vm={"a": 300 * MiB, "b": 1000 * MiB, "c": 1000 * MiB})]
    r = _rung(tmp_path, s, arm="resident-inf", drift_basis="sum")
    assert r["footprint_drift_basis"] == "sum"
    assert abs(r["footprint_drift_sum_pct"] - 200 / 21.0) < 1e-9
    assert abs(r["footprint_drift_median_pct"]) < 1e-9
    assert r["footprint_drift_pct"] == r["footprint_drift_sum_pct"] and not r["repeat_required"]
    # the median rises > 10% while the sum stays within 10%: no repeat on the sum basis
    s = [S(0, vm={"a": 100 * MiB, "b": 100 * MiB, "c": 2000 * MiB}),
         S(120, vm={"a": 100 * MiB, "b": 120 * MiB, "c": 2000 * MiB})]
    r = _rung(tmp_path, s, arm="resident-inf", drift_basis="sum")
    assert r["footprint_drift_median_pct"] > 10 and not r["repeat_required"]
    # the sum grows > 10%: repeat
    s = [S(0, vm={"a": 100 * MiB, "b": 100 * MiB}), S(120, vm={"a": 100 * MiB, "b": 200 * MiB})]
    r = _rung(tmp_path, s, arm="resident-inf", drift_basis="sum")
    assert abs(r["footprint_drift_sum_pct"] - 50) < 1e-9 and r["repeat_required"]


def test_footprint_drift_median_basis_is_the_default(tmp_path):
    # no drift_basis (every aws-prelim params.json): the median, as sealed; the sum is information
    s = [S(0, vm={"a": 100 * MiB, "b": 100 * MiB, "c": 2000 * MiB}),
         S(120, vm={"a": 100 * MiB, "b": 120 * MiB, "c": 2000 * MiB})]
    r = _rung(tmp_path, s, arm="resident-inf")
    assert r["footprint_drift_basis"] == "median"
    assert abs(r["footprint_drift_pct"] - 20.0) < 1e-9 and r["repeat_required"]
    assert abs(r["footprint_drift_sum_pct"] - 20 / 22.0) < 1e-9
    r = _rung(tmp_path, s, arm="resident-inf", drift_basis="median")
    assert r["footprint_drift_basis"] == "median" and r["repeat_required"]


def test_flat_p95_limit_override_holds_1s(tmp_path):
    # supplementary 1-second limit (user decision 2026-11-04): condition 4 for both verdicts is
    # p95(excess) <= the flat limit; conditions 1-3 unchanged; the default is the sealed rule.
    c = [call(added=a) for a in [50] * 18 + [700, 700]]
    bl = BL(excess=100)                       # sealed: limit max(3 x 100, 50) = 300, abs 350
    r = H.evaluate(c, [sess(0.0)] * 3, bl)
    assert not r["holds"] and not r["holds_abs"] and r["excess_limit_ms"] == 300
    r = H.evaluate(c, [sess(0.0)] * 3, bl, p95_limit_ms=1000)
    assert r["holds"] and r["holds_abs"] and r["excess_limit_ms"] == 1000 and r["p95_limit_abs_ms"] == 1000
    assert r["p95_limit_override_ms"] == 1000
    assert not H.evaluate(c, [sess(0.0)] * 3, bl, p95_limit_ms=600)["holds"]
    # conditions 1-2 still apply under the flat limit
    bad = c + [call(status="err", cause="rpc_error")]
    assert not H.evaluate(bad, [sess(0.0)] * 3, bl, p95_limit_ms=1000)["holds"]


def test_record_main_out_and_limit_never_overwrites_record(tmp_path):
    (tmp_path / "samples.jsonl").write_text(json.dumps(S(1)))
    (tmp_path / "params.json").write_text(json.dumps(dict(arm="sbx", n=1, warmup_s=0, window_s=120, floor_mb=1536)))
    (tmp_path / "record.json").write_text('{"sealed": true}')
    R.main([str(tmp_path), "--params", str(tmp_path / "params.json"), "--p95-limit-ms", "1000",
            "--out", str(tmp_path / "record_1s.json")])
    assert json.loads((tmp_path / "record.json").read_text()) == {"sealed": True}
    assert json.loads((tmp_path / "record_1s.json").read_text())["p95_limit_override_ms"] == 1000
    with pytest.raises(SystemExit):
        R.main([str(tmp_path), "--params", str(tmp_path / "params.json"), "--p95-limit-ms", "1000"])
