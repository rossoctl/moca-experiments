"""gate256.py (PLAN-E17C Task 10; SPEC §13.5, R45): the 256 MiB library's calibration gate, on synthetic results."""

import json
import os
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import gate256 as G  # noqa: E402

PIN = "2222222222222222222222222222222222222222"
LIB256 = os.path.join(HERE, "..", "workload", "library-256.json")
MIB = 1024


def ok(rss_mib=100):
    return {"ok": True, "oom": False, "peak_rss_kb": rss_mib * MIB, "observed_ms": 4000.0}


def oom():
    return {"ok": False, "oom": True, "peak_rss_kb": None, "observed_ms": 3000.0}


def arm(n_ok=20, rss_mib=100, n_oom=0, extra=()):
    return [ok(rss_mib) for _ in range(n_ok)] + [oom() for _ in range(n_oom)] + list(extra)


# ---- the selection rule ---------------------------------------------------------------------------------------------

def test_largest_scale_that_passes_both_arms():
    res = {32: {"sbx": arm(19, n_oom=1), "ship-300": arm()},
           16: {"sbx": arm(), "ship-300": arm(rss_mib=121)},
           8: {"sbx": arm(rss_mib=110), "ship-300": arm(rss_mib=120)},
           4: {"sbx": arm(rss_mib=90), "ship-300": arm(rss_mib=90)}}
    assert G.choose_scale(res) == 8  # 120 MiB is "<= 120"; 4 passes too but is smaller


def test_one_oom_in_either_arm_fails_the_scale():
    for a in ("sbx", "ship-300"):
        res = {8: {"sbx": arm(), "ship-300": arm()}}
        res[8][a] = arm(19, n_oom=1)
        assert G.choose_scale(res) is None, a
        j = G.judge(res)
        assert j["results"]["8"][a]["oom_kills"] == 1 and j["results"]["8"][a]["pass"] is False
        assert "OOM" in j["results"]["8"][a]["reason"]


def test_peak_rss_above_120_mib_fails_the_scale():
    res = {8: {"sbx": arm(19) + [ok(121)], "ship-300": arm()}}
    j = G.judge(res)
    assert j["chosen_scale"] is None and j["pass"] is False
    assert j["results"]["8"]["sbx"]["peak_rss_kb"] == 121 * MIB
    assert j["results"]["8"]["sbx"]["peak_rss_mib"] == 121.0


def test_fewer_than_20_runs_or_a_missing_reading_or_another_failure_fails_the_scale():
    nofill = {"ok": True, "oom": False, "peak_rss_kb": None, "observed_ms": 1.0}
    timeout = {"ok": False, "oom": False, "peak_rss_kb": None, "observed_ms": 136000.0, "cause": "rpc_error"}
    for bad, word in ((arm(19), "19 run"), (arm(19, extra=[nofill]), "no peak RSS"),
                      (arm(19, extra=[timeout]), "failed")):
        j = G.judge({4: {"sbx": arm(), "ship-300": bad}})
        assert j["chosen_scale"] is None, word
        assert word in j["results"]["4"]["ship-300"]["reason"], j["results"]["4"]["ship-300"]["reason"]


def test_an_arm_not_run_fails_the_scale():
    assert G.choose_scale({8: {"sbx": arm()}}) is None
    assert G.choose_scale({8: {"sbx": arm(), "ship-300": None}}) is None


def test_no_scale_passes_reason_names_each_candidate():
    res = {32: {"sbx": arm(0, n_oom=20), "ship-300": arm(0, n_oom=20)},
           16: {"sbx": arm(rss_mib=130), "ship-300": arm(rss_mib=130)}}
    j = G.judge(res)
    assert j["chosen_scale"] is None and j["pass"] is False
    assert "scale 32" in j["reason"] and "scale 16" in j["reason"]
    assert j["candidates"] == [32, 16]


def test_judge_records_the_rule_and_the_chosen_scales_sbx_median():
    res = {16: {"sbx": arm(rss_mib=130), "ship-300": arm()},
           8: {"sbx": [dict(ok(), observed_ms=float(i)) for i in range(1, 21)], "ship-300": arm()}}
    j = G.judge(res)
    assert j["chosen_scale"] == 8 and j["pass"] is True
    assert j["runs_per_arm"] == 20 and j["rss_max_mib"] == 120 and j["arms"] == ["sbx", "ship-300"]
    assert j["py_analyze_ms"] == 10.5  # the median observed_ms of the chosen scale's sbx runs (the corpus's duration)
    assert "scale 8" in j["reason"]


# ---- one call row -> one run ----------------------------------------------------------------------------------------

def row(status="ok", exit=0, failed_rc=None, stdout="rows=1 sha256=x clusters=1.000\npeak_rss_kb=102400\n", **kw):
    r = {"class": "py_analyze", "status": status, "exit": exit, "in_window": True, "observed_ms": 4000.0,
         "stdout": stdout}
    if failed_rc is not None:
        r["failed_rc"] = failed_rc
    r.update(kw)
    return r


def test_run_of_reads_the_oom_kill_and_the_peak():
    assert G.run_of(row()) == {"ok": True, "oom": False, "peak_rss_kb": 102400, "observed_ms": 4000.0,
                               "status": "ok", "cause": None}
    # E17b's R45 rows: the joined script's step 0 exited 137 (exit 90, failed_rc 137), no peak line
    r = G.run_of(row(status="err", exit=90, failed_rc=137, stdout="", cause="exit_mismatch"))
    assert r["oom"] is True and r["ok"] is False and r["peak_rss_kb"] is None
    assert G.run_of(row(status="err", exit=137, stdout=None))["oom"] is True
    t = G.run_of(row(status="err", exit=None, stdout=None, cause="rpc_error", msg="timeout:136"))
    assert t["oom"] is False and t["ok"] is False and t["cause"] == "rpc_error"


def test_peak_rss_kb_parses_only_the_wrapper_line():
    assert G.peak_rss_kb("rows=1\npeak_rss_kb=5\n") == 5
    assert G.peak_rss_kb("rows=1\n") is None
    assert G.peak_rss_kb(None) is None
    assert G.peak_rss_kb("peak_rss_kb=5 trailing\n") is None


# ---- the library helpers --------------------------------------------------------------------------------------------

def test_library_scale(tmp_path):
    p = tmp_path / "l.json"
    lib = json.load(open(LIB256))
    for s in (0, 8, 16):
        lib["classes"]["py_analyze"][0]["cmd"] = G.analyze_cmd(s)
        p.write_text(json.dumps(lib))
        assert G.library_scale(str(p)) == s
    for bad in ("cd project && ../venv/bin/python analyze.py",
                "cd project && PYC_ANALYZE_WORK_SCALE=8 ../venv/bin/python analyze.py",  # the env form R-z1 retired
                G.wrapper_cmd(8)):
        lib["classes"]["py_analyze"][0]["cmd"] = bad
        p.write_text(json.dumps(lib))
        with pytest.raises(ValueError):
            G.library_scale(str(p))


# ---- the CLI: write (from rung trees) and state (the ram256 stages' check) -----------------------------------------

def rung(root, arm_, scale, rows, guest=256, n=None):
    d = os.path.join(root, arm_, "N1-g256-s%d" % scale)
    os.makedirs(d)
    json.dump({"arm": arm_, "n": 1, "moca_commit": PIN, "guest_ram_mb": guest, "library": "/x/library-s%d.json" % scale,
               "library_sha256": "ab" * 32}, open(os.path.join(d, "params.json"), "w"))
    with open(os.path.join(d, "calls.jsonl"), "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
    return d


def cli(*args):
    return subprocess.run([sys.executable, os.path.join(HERE, "gate256.py"), *args], capture_output=True, text=True)


def write(tmp_path, scales="16 8"):
    out = tmp_path / "gate-256.json"
    r = cli("write", "--runs", str(tmp_path / "runs"), "--out", str(out), "--moca-commit", PIN, "--scales", scales,
            "--arms", "sbx ship-300", "--runs-per", "20", "--rss-max-mib", "120", "--library", LIB256)
    return r, out


def test_write_from_rung_trees(tmp_path):
    root = str(tmp_path / "runs")
    big = row(stdout="rows=1\npeak_rss_kb=%d\n" % (130 * MIB))
    rung(root, "sbx", 16, [big] * 20)
    rung(root, "ship-300", 16, [row(status="err", exit=90, failed_rc=137, stdout="")] + [row()] * 19)
    rung(root, "sbx", 8, [row()] * 20)
    rung(root, "ship-300", 8, [row()] * 20)
    r, out = write(tmp_path)
    assert r.returncode == 0, r.stderr
    assert r.stdout.startswith("PASS: scale 8"), r.stdout
    g = json.load(open(out))
    assert g["stage"] == "gate-256" and g["point"] == "pycache-d64" and g["moca_commit"] == PIN
    assert g["guest_ram_mb"] == 256 and g["pass"] is True and g["chosen_scale"] == 8
    assert g["candidates"] == [16, 8]
    s16 = g["results"]["16"]
    assert s16["sbx"]["peak_rss_mib"] == 130.0 and s16["sbx"]["pass"] is False
    assert s16["ship-300"]["oom_kills"] == 1 and s16["ship-300"]["runs"] == 20
    assert s16["sbx"]["rung"] == "pycache-d64/sbx/N1-g256-s16"
    assert g["library_256"]["sha256"] and g["library_256"]["scale"] == G.library_scale(LIB256)


def test_write_fails_on_a_missing_or_short_rung(tmp_path):
    root = str(tmp_path / "runs")
    rung(root, "sbx", 8, [row()] * 20)
    r, out = write(tmp_path, scales="8")
    assert r.returncode != 0 and "ship-300" in r.stderr and not out.exists()
    rung(root, "ship-300", 8, [row()] * 20 + [dict(row(), **{"class": "py_short"})])
    r, out = write(tmp_path, scales="8")
    assert r.returncode == 0, r.stderr  # other classes are not py_analyze runs


def test_write_refuses_a_rung_not_at_256_mib(tmp_path):
    root = str(tmp_path / "runs")
    rung(root, "sbx", 8, [row()] * 20, guest=1024)
    rung(root, "ship-300", 8, [row()] * 20)
    r, out = write(tmp_path, scales="8")
    assert r.returncode != 0 and "guest_ram_mb 1024" in r.stderr and not out.exists()


def test_write_records_a_fail(tmp_path):
    root = str(tmp_path / "runs")
    rung(root, "sbx", 8, [row(status="err", exit=90, failed_rc=137, stdout="")] * 20)
    rung(root, "ship-300", 8, [row()] * 20)
    r, out = write(tmp_path, scales="8")
    assert r.returncode == 0 and r.stdout.startswith("FAIL: "), r.stdout
    g = json.load(open(out))
    assert g["pass"] is False and g["chosen_scale"] is None and g["py_analyze_ms"] is None


def gate_doc(tmp_path, **kw):
    g = {"stage": "gate-256", "pass": True, "chosen_scale": 8, "moca_commit": PIN, "reason": "ok", "guest_ram_mb": 256,
         "py_analyze_ms": 4000.0}
    g.update(kw)
    p = tmp_path / "gate-256.json"
    p.write_text(json.dumps(g))
    return str(p)


def lib_at(tmp_path, scale):
    lib = json.load(open(LIB256))
    lib["classes"]["py_analyze"][0]["cmd"] = G.analyze_cmd(scale)
    p = tmp_path / "library-256.json"
    p.write_text(json.dumps(lib))
    return str(p)


def state(gate, lib):
    r = cli("state", "--gate", gate, "--moca-commit", PIN, "--library", lib)
    return r.returncode, r.stdout.strip()


def test_state_passes_only_a_passing_gate_at_this_pin_with_its_scale_committed(tmp_path):
    assert state(gate_doc(tmp_path), lib_at(tmp_path, 8)) == (0, "pass 8")
    rc, out = state(str(tmp_path / "none.json"), lib_at(tmp_path, 8))
    assert rc == 1 and "no " in out and "run gate-256" in out
    (tmp_path / "bad.json").write_text('{"pass": ')
    rc, out = state(str(tmp_path / "bad.json"), lib_at(tmp_path, 8))
    assert rc == 1 and "unreadable" in out
    rc, out = state(gate_doc(tmp_path, moca_commit="1" * 40), lib_at(tmp_path, 8))
    assert rc == 1 and "moca_commit" in out and "re-run gate-256" in out
    rc, out = state(gate_doc(tmp_path, **{"pass": False, "chosen_scale": None, "reason": "scale 1: OOM"}), lib_at(tmp_path, 8))
    assert rc == 1 and "did not pass" in out and "scale 1: OOM" in out
    rc, out = state(gate_doc(tmp_path, **{"pass": 1}), lib_at(tmp_path, 8))  # strict: 1 is not true
    assert rc == 1 and "unreadable" in out
    # ruling R-x: the gate reports the scale; library-256.json carries it only through a committed change
    rc, out = state(gate_doc(tmp_path), lib_at(tmp_path, 0))
    assert rc == 1 and "placeholder" in out and "commit" in out
    rc, out = state(gate_doc(tmp_path), lib_at(tmp_path, 16))
    assert rc == 1 and "scale 16" in out and "chose 8" in out


def test_library_cli(tmp_path):
    out = tmp_path / "g.json"
    r = cli("library", "--base", LIB256, "--scale", "4", "--out", str(out))
    assert r.returncode == 0, r.stderr
    assert json.load(open(out))["classes"]["py_analyze"][0]["cmd"] == G.wrapper_cmd(4)
    assert G.wrapper_cmd(4).startswith("cd project && ../venv/bin/python -c 'import resource, ")
