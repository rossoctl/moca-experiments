import json
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import verdict as V  # noqa: E402
from test_warmcold import call  # noqa: E402
from test_warmcold_lease import exec_line, start_line  # noqa: E402

PIN = "1" * 40


def write_rung(root, point, arm, name, n, calls=(), log=(), commit=PIN, **files):
    """A rung directory RUNS/POINT/ARM/NAME with params.json and the given JSON outputs."""
    d = os.path.join(root, point, arm, name)
    os.makedirs(d)
    json.dump({"arm": arm, "n": n, "point": point, "moca_commit": commit}, open(os.path.join(d, "params.json"), "w"))
    with open(os.path.join(d, "calls.jsonl"), "w") as f:
        f.writelines(json.dumps(c) + "\n" for c in calls)
    with open(os.path.join(d, "worker.log"), "w") as f:
        f.write("microvm-worker: attached, serving execs\n" + "".join(log))
    for k, v in files.items():
        json.dump(v, open(os.path.join(d, k.replace("_json", ".json")), "w"))
    return d


def ladder(root, point, arm, **kw):
    os.makedirs(os.path.join(root, point, arm), exist_ok=True)
    json.dump(dict({"point": point, "arm": arm}, **kw), open(os.path.join(root, point, arm, "ladder.json"), "w"))


def ship_lat(root, point, n, short_ms, import_ms, arm="ship-300"):
    """Key A: a first call (first_lease), then a warm py_short and a warm py_import on vm-1."""
    log = [start_line("A", "vm-1"), exec_line("A", "vm-1"), exec_line("A", "vm-1", req=2), exec_line("A", "vm-1", req=3)]
    ev = [{"state": "start", "reason": "", "at_unix_ms": 1, "age_ms": 0, "mode": "lease"}]
    calls = [call("A", 1, first_lease=True, lease_events=ev), call("A", 2, cls="py_short", ms=short_ms),
             call("A", 3, cls="py_import", ms=import_ms)]
    return write_rung(root, point, arm, "N%d-lat" % n, n, calls, log)


def sbx_lat(root, point, n, short_ms, import_ms):
    log = [exec_line("S", "vm-%d" % i, req=i) for i in (1, 2)]
    calls = [call("S", 1, cls="py_short", ms=short_ms), call("S", 2, cls="py_import", ms=import_ms)]
    return write_rung(root, point, "sbx", "N%d-lat" % n, n, calls, log)


def le(c4=True, valid=True, guards=0, with_idle=0, host_idle=0, wrong=0, unknown=0, reclaims=0, after_sweep=0, live=0,
       guards_available=True, memory_high=0):
    return {"valid": valid, "invalid_reasons": [] if valid else ["stub"], "criterion4_pass": c4,
            "criterion3_guards_pass": False if guards + memory_high else (True if guards_available else None),
            "criterion3_refusals_pass": with_idle == 0 and host_idle == 0,
            "criterion3_order_pass": (wrong == 0 and unknown == 0) if reclaims else None,
            "guards": {"total": guards + memory_high, "memory_high": memory_high, "available": guards_available},
            "refusals": {"with_idle_lease": with_idle, "host_memory_with_idle_lease": host_idle,
                                                     "unclassified": []},
            "reclaim": {"total": reclaims, "wrong": wrong, "unknown": unknown, "victim_executing": 0},
            "notices": {"ended_after_sweep": after_sweep, "live_at_stop": live}}


def vml(share_true=1.0, t=2, f=0, low=1, pinned_share=0.0, ratio=1.1, valid=True):
    fpr = {"share_true": share_true, "follows_true": t, "follows_false": f, "follows_null": low,
           "not_judged_low_growth": low,
           "absolute": {"readings": t + f + low, "pinned": 0, "pinned_share": pinned_share,
                        "judged_readings": t + f, "pinned_share_of_judged": 0.0, "pinned_vm_share": 0.0}}
    return {"mapping_valid": valid, "fpr": fpr if valid else None,
            "replacement": {"replacement_leases": 2, "with_first_py_grep": 2, "median_first_py_grep_ms": 440.0,
                            "sbx_median_py_grep_ms": 400.0 if ratio else None, "ratio_to_sbx": ratio}}


def crit(r, k):
    c = r["criteria"][k]
    if k == "5":
        assert c["pass"] is None  # criterion 5's thresholds are sealed in Task 13: never set here
    assert set(c) >= {"value", "inputs", "pass", "why"}
    return c


def test_criterion_1_reads_the_default_ladders(tmp_path):
    root = str(tmp_path)
    ladder(root, "default", "ship-300", n_max=128, n_max_abs=160, stopped_at=160)
    ladder(root, "default", "sbx", n_max=96, n_max_abs=96, stopped_at=128)
    c = crit(V.verdict(root), "1")
    assert c["value"]["ship_300_n_max"] == 128 and c["value"]["sbx_n_max"] == 96
    assert c["value"]["ship_300_minus_sbx"] == 32 and c["value"]["n_max_abs"] == {"ship-300": 160, "sbx": 96}
    assert sorted(os.path.basename(os.path.dirname(p)) for p in c["inputs"]) == ["sbx", "ship-300"]


def test_criterion_1_missing_ladder_is_null_and_listed(tmp_path):
    root = str(tmp_path)
    ladder(root, "default", "sbx", n_max=96)
    c = crit(V.verdict(root), "1")
    assert c["value"]["ship_300_n_max"] is None and c["value"]["ship_300_minus_sbx"] is None
    assert any("default/ship-300/ladder.json" in m for m in c["missing"])


def test_criterion_2_gains_against_sbx_at_pycache_n1_and_n128(tmp_path):
    root = str(tmp_path)
    for n in (1, 128):
        sbx_lat(root, "pycache", n, short_ms=400, import_ms=1000)
        ship_lat(root, "pycache", n, short_ms=100, import_ms=600)
    # E17B-R52: a pycache N=1 baseline seed (N1-s<k>) is pooled into N=1; a probe rung and a pycache-low seed are not
    write_rung(root, "pycache", "sbx", "N1-s1", 1, [call("S", 1, cls="py_short", ms=400)], [exec_line("S", "vm-9")])
    write_rung(root, "pycache", "sbx", "N1-probe-py_short", 1, [call("P", 1, cls="py_short", ms=99999)],
               [exec_line("P", "vm-8")])
    write_rung(root, "pycache-low", "sbx", "N1-s1", 1, [call("L", 1, cls="py_short", ms=99999)], [exec_line("L", "vm-7")])
    c = crit(V.verdict(root), "2")
    g = c["value"]["gated"]
    assert g["1"]["py_short"] == pytest.approx(0.75) and g["1"]["py_import"] == pytest.approx(0.4)
    assert g["128"]["py_short"] == pytest.approx(0.75) and g["128"]["py_import"] == pytest.approx(0.4)
    rep = {(x["point"], x["n"], x["arm"]): x for x in c["value"]["groups"]}
    assert rep[("pycache", 1, "ship-300")]["classes"]["py_short"]["baseline_median_ms"] == 400
    assert any(p.endswith("pycache/sbx/N1-s1") for p in c["inputs"])
    assert not any(p.endswith("N1-probe-py_short") or p.endswith("pycache-low/sbx/N1-s1") for p in c["inputs"])


def test_criterion_2_without_sbx_is_null(tmp_path):
    root = str(tmp_path)
    ship_lat(root, "pycache", 1, short_ms=100, import_ms=600)
    g = crit(V.verdict(root), "2")["value"]["gated"]
    assert g["1"]["py_short"] is None and g["128"]["py_short"] is None


def test_criterion_3_reads_the_squeeze_climb(tmp_path):
    root = str(tmp_path)
    a = write_rung(root, "squeeze", "ship-300", "N64", 64, lease_ends_json=le(reclaims=3))
    b = write_rung(root, "squeeze", "ship-300", "N96", 96, lease_ends_json=le(reclaims=9, wrong=1, with_idle=2))
    ladder(root, "squeeze", "ship-300", squeeze={"stop_n": 96, "stopped_by": "reclaim_rate", "memmax_mb": 65536,
                                                 "rungs": [{"n": 64, "met": False, "dir": a},
                                                           {"n": 96, "met": True, "dir": "/elsewhere/N96"}]})
    write_rung(root, "squeeze", "sbx", "N96-sq", 96)
    c = crit(V.verdict(root), "3")
    sq = c["value"]["squeeze"]
    assert sq["stop_n"] == 96 and sq["stopped_by"] == "reclaim_rate"
    assert [r["n"] for r in sq["rungs"]] == [64, 96]  # the rung dir is resolved under RUNS when it moved
    assert sq["rungs"][1]["order_pass"] is False and sq["rungs"][1]["refusals_with_idle_lease"] == 2
    assert sq["totals"] == {"guards": 0, "memory_high": 0, "refusals_with_idle_lease": 2, "host_memory_with_idle_lease": 0,
                            "reclaims": 12, "wrong": 1, "unknown": 0, "victim_executing": 0}
    assert sq["sbx_rungs"][0]["dir"].endswith("squeeze/sbx/N96-sq")
    assert c["pass"] is False and any("wrong" in w for w in c["why"]) and any("idle lease" in w for w in c["why"])
    assert b in c["inputs"] or os.path.join(b, "lease_ends.json") in c["inputs"]
    assert c["value"]["squeeze-256"] is None and any("squeeze-256" in m for m in c["missing"])


def test_criterion_4_combines_by_r16(tmp_path):
    root = str(tmp_path)
    write_rung(root, "pycache", "ship-300", "N1-lat", 1, lease_ends_json=le(c4=True, after_sweep=1, live=2))
    write_rung(root, "pycache", "ship-300", "N128-lat", 128, lease_ends_json=le(c4=None))
    write_rung(root, "default", "sbx", "N1-lat", 1)  # sbx: no lease_ends, not counted
    c = crit(V.verdict(root), "4")
    v = c["value"]
    assert (v["rungs"], v["true"], v["false"], v["null"], v["invalid"]) == (2, 1, 0, 1, 0)
    assert v["r16_met"] is True and v["ended_after_sweep"] == 1 and v["live_at_stop"] == 2
    write_rung(root, "default", "ship-300", "N8", 8, lease_ends_json=le(c4=False))
    v = crit(V.verdict(root), "4")["value"]
    assert v["r16_met"] is False and v["false_rungs"] == [os.path.join(root, "default", "ship-300", "N8")]


def test_criterion_4_invalid_or_all_null_is_not_met(tmp_path):
    root = str(tmp_path)
    write_rung(root, "pycache", "ship-300", "N1-lat", 1, lease_ends_json=le(c4=None))
    assert crit(V.verdict(root), "4")["value"]["r16_met"] is False  # no rung true
    write_rung(root, "pycache", "ship-300", "N128-lat", 128, lease_ends_json=le(c4=True, valid=False))
    v = crit(V.verdict(root), "4")["value"]
    assert v["r16_met"] is False and v["invalid"] == 1
    # a ship rung with no lease_ends.json is missing, never a pass
    write_rung(root, "pycache", "ship-30", "N128-lat", 128)
    c = crit(V.verdict(root), "4")
    assert c["value"]["r16_met"] is False and any("ship-30/N128-lat" in m for m in c["missing"])


def test_criterion_5_first_and_second_half(tmp_path):
    root = str(tmp_path)
    write_rung(root, "pycache", "ship-300", "N1-lat", 1, vm_age_lease_json=vml(t=3, f=1, low=2, ratio=1.1))
    write_rung(root, "pycache", "ship-300", "N128-lat", 128, vm_age_lease_json=vml(t=1, f=0, low=4, ratio=None))
    write_rung(root, "pycache", "ship-120", "N128-lat", 128, vm_age_lease_json=vml(valid=False))
    write_rung(root, "pycache-d64", "ship-300", "N1-ram256", 1, vm_age_lease_json=vml(t=9, f=9))
    c = crit(V.verdict(root), "5")
    fh = c["value"]["first_half"]
    assert fh["pooled"]["follows_true"] == 4 and fh["pooled"]["follows_false"] == 1
    assert fh["pooled"]["share_true"] == pytest.approx(0.8) and fh["pooled"]["not_judged_low_growth"] == 6
    assert fh["pooled"]["absolute_readings"] == 11 and fh["pooled"]["pinned_share"] == 0.0
    assert [r["rung"].split(root + "/")[1] for r in fh["rungs"]] == [  # by point, arm, N
        "pycache/ship-120/N128-lat", "pycache/ship-300/N1-lat", "pycache/ship-300/N128-lat"]
    assert fh["rungs"][0]["mapping_valid"] is False and fh["rungs"][0]["share_true"] is None
    sh = c["value"]["second_half"]
    assert [r["ratio_to_sbx"] for r in sh["rungs"]] == [1.1, 1.1, None]
    assert sh["ratio_to_sbx_max"] == 1.1 and sh["rungs_without_sbx"] == 1
    # the 256 MiB rungs are reported, not pooled into the pycache reading
    assert c["value"]["reported"]["pycache-d64"]["first_half"]["pooled"]["follows_true"] == 9


def test_other_commit_is_excluded_and_listed(tmp_path):
    root = str(tmp_path)
    write_rung(root, "pycache", "ship-300", "N1-lat", 1, commit="2" * 40, lease_ends_json=le(c4=False))
    r = V.verdict(root, moca_commit=PIN)
    assert r["excluded_rungs"] == [{"rung": os.path.join(root, "pycache", "ship-300", "N1-lat"), "moca_commit": "2" * 40}]
    assert r["criteria"]["4"]["value"]["rungs"] == 0


def test_moved_aside_rungs_are_ignored(tmp_path):
    root = str(tmp_path)
    write_rung(root, "pycache", "ship-300", "N1-lat.prev-20261116T000000Z", 1, lease_ends_json=le(c4=False))
    assert crit(V.verdict(root), "4")["value"]["rungs"] == 0


def test_main_writes_verdict_json(tmp_path, capsys):
    root = str(tmp_path / "runs")
    os.makedirs(root)
    out = str(tmp_path / "verdict.json")
    V.main([root, "--moca-commit", PIN, "--out", out])
    r = json.load(open(out))
    assert sorted(r["criteria"]) == ["1", "2", "3", "4", "5"] and r["moca_commit"] == PIN
    assert r["criteria"]["5"]["pass"] is None
    assert all(r["criteria"][k]["pass"] is None for k in "1235")  # no inputs: nothing judged
    assert r["criteria"]["4"]["pass"] is False  # R16: no rung true
    assert "verdict.json" in capsys.readouterr().out


# ---- PR #34 review item 9 (E17B-R40): SPEC 7.5's fixed bars for criteria 1-4 ----

def test_criterion_1_pass_is_ship_300_at_least_sbx(tmp_path):
    for ship, sbx, want in ((128, 96, True), (96, 96, True), (80, 96, False)):
        root = str(tmp_path / ("c1-%d-%d" % (ship, sbx)))
        ladder(root, "default", "ship-300", n_max=ship)
        ladder(root, "default", "sbx", n_max=sbx)
        c = crit(V.verdict(root), "1")
        assert c["pass"] is want, (ship, sbx)
        assert bool(c["why"]) is (want is False)
    root = str(tmp_path / "c1-missing")
    ladder(root, "default", "sbx", n_max=96)
    assert crit(V.verdict(root), "1")["pass"] is None


def c2_root(tmp_path, name, short_ms=100, import_ms=600, n128=True):
    root = str(tmp_path / name)
    for n in ((1, 128) if n128 else (1,)):
        sbx_lat(root, "pycache", n, short_ms=400, import_ms=1000)
        ship_lat(root, "pycache", n, short_ms=short_ms, import_ms=import_ms)
    return root


def test_criterion_2_pass_applies_the_50_and_30_percent_bars(tmp_path):
    # gains: py_short 1 - 100/400 = 0.75, py_import 1 - 600/1000 = 0.40
    assert crit(V.verdict(c2_root(tmp_path, "ok")), "2")["pass"] is True
    # exactly at the bars: 200/400 = 0.50, 700/1000 = 0.30
    assert crit(V.verdict(c2_root(tmp_path, "edge", short_ms=200, import_ms=700)), "2")["pass"] is True
    c = crit(V.verdict(c2_root(tmp_path, "imp", import_ms=750)), "2")  # py_import 0.25 < 0.30
    assert c["pass"] is False and any("py_import" in w and "0.30" in w for w in c["why"])
    c = crit(V.verdict(c2_root(tmp_path, "short", short_ms=210)), "2")  # py_short 0.475 < 0.50
    assert c["pass"] is False and any("py_short" in w for w in c["why"])
    # N=128 missing: not judged (null), unless another value already fails
    assert crit(V.verdict(c2_root(tmp_path, "n1only", n128=False)), "2")["pass"] is None
    assert crit(V.verdict(c2_root(tmp_path, "n1fail", import_ms=900, n128=False)), "2")["pass"] is False


def c3_root(tmp_path, name, rungs, point="squeeze"):
    root = str(tmp_path / name)
    rows = []
    for i, kw in enumerate(rungs):
        n = 32 * (i + 1)
        rows.append({"n": n, "met": False, "dir": write_rung(root, point, "ship-300", "N%d" % n, n, lease_ends_json=le(**kw))})
    ladder(root, point, "ship-300", squeeze={"stop_n": rows[-1]["n"], "stopped_by": "reclaim_rate", "memmax_mb": 65536,
                                             "rungs": rows})
    return root


def test_criterion_3_pass_needs_zero_guards_refusals_wrong_picks_and_a_reclaim(tmp_path):
    assert crit(V.verdict(c3_root(tmp_path, "ok", [dict(reclaims=0), dict(reclaims=4)])), "3")["pass"] is True
    for name, rungs, why in (
            ("noreclaim", [dict(reclaims=0), dict(reclaims=0)], "no reclaim happened"),
            ("guard", [dict(reclaims=4, guards=1)], "guard"),
            ("idle", [dict(reclaims=4, with_idle=1)], "idle lease"),
            ("host", [dict(reclaims=4, host_idle=2)], "idle lease"),
            ("wrong", [dict(reclaims=4, wrong=1)], "wrong"),
            ("unknown", [dict(reclaims=4, unknown=1)], "unknown")):
        c = crit(V.verdict(c3_root(tmp_path, name, rungs)), "3")
        assert c["pass"] is False and any(why in w for w in c["why"]), (name, c["why"])
    # E17B-R49: the squeezed slice's memory.high is reported, not judged; any other guard event still fails
    c = crit(V.verdict(c3_root(tmp_path, "high", [dict(reclaims=4, memory_high=19)])), "3")
    assert c["pass"] is True, c["why"]
    row = c["value"]["squeeze"]["rungs"][0]
    assert row["memory_high"] == 19 and row["guards"] == 0 and row["lease_ends_guards_pass"] is False
    assert c["value"]["squeeze"]["totals"]["memory_high"] == 19
    c = crit(V.verdict(c3_root(tmp_path, "high-oom", [dict(reclaims=4, memory_high=19, guards=1)])), "3")
    assert c["pass"] is False and any("1 memory-guard event" in w for w in c["why"]), c["why"]
    # a rung whose guard reading is unavailable cannot pass it: null
    c = crit(V.verdict(c3_root(tmp_path, "unavail", [dict(reclaims=4, guards_available=False)])), "3")
    assert c["pass"] is None
    # no squeeze climb at all: null
    root = str(tmp_path / "none")
    os.makedirs(root)
    assert crit(V.verdict(root), "3")["pass"] is None


def test_criterion_3_judges_squeeze_256_when_it_ran(tmp_path):
    root = c3_root(tmp_path, "both", [dict(reclaims=4)])
    rows = [{"n": 32, "met": True, "dir": write_rung(root, "squeeze-256", "ship-300", "N32", 32, lease_ends_json=le(reclaims=0))}]
    ladder(root, "squeeze-256", "ship-300", squeeze={"stop_n": 32, "stopped_by": "reclaim_rate", "memmax_mb": 9000,
                                                     "rungs": rows})
    c = crit(V.verdict(root), "3")
    assert c["pass"] is False and any("squeeze-256" in w and "no reclaim happened" in w for w in c["why"])


def test_criterion_4_pass_is_r16(tmp_path):
    root = str(tmp_path)
    write_rung(root, "pycache", "ship-300", "N1-lat", 1, lease_ends_json=le(c4=True))
    assert crit(V.verdict(root), "4")["pass"] is True
    write_rung(root, "pycache", "ship-300", "N128-lat", 128, lease_ends_json=le(c4=False))
    c = crit(V.verdict(root), "4")
    assert c["pass"] is False and c["why"]


def test_criterion_5_pass_stays_null(tmp_path):
    root = str(tmp_path)
    write_rung(root, "pycache", "ship-300", "N1-lat", 1, vm_age_lease_json=vml(t=3, f=0))
    assert crit(V.verdict(root), "5")["pass"] is None


def test_criterion_3_is_null_when_no_lease_ends_was_read(tmp_path):
    # Fix round 2, minor 2: with no lease_ends.json read (or a climb listing no rungs) "no reclaim happened" is not
    # known: null, not a fail.
    root = str(tmp_path / "unread")
    d = write_rung(root, "squeeze", "ship-300", "N32", 32)  # no lease_ends.json
    ladder(root, "squeeze", "ship-300", squeeze={"stop_n": 32, "stopped_by": "reclaim_rate", "memmax_mb": 65536,
                                                 "rungs": [{"n": 32, "met": True, "dir": d}]})
    c = crit(V.verdict(root), "3")
    assert c["pass"] is None and not any("no reclaim happened" in w for w in c["why"])
    root = str(tmp_path / "norungs")
    os.makedirs(root)
    ladder(root, "squeeze", "ship-300", squeeze={"stop_n": None, "stopped_by": "none", "memmax_mb": 65536, "rungs": []})
    assert crit(V.verdict(root), "3")["pass"] is None
    # one rung read with no reclaim, another unread: still not known
    root = c3_root(tmp_path, "mixed", [dict(reclaims=0)])
    d2 = write_rung(root, "squeeze", "ship-300", "N64x", 64)
    lj = json.load(open(os.path.join(root, "squeeze", "ship-300", "ladder.json")))
    lj["squeeze"]["rungs"].append({"n": 64, "met": True, "dir": d2})
    json.dump(lj, open(os.path.join(root, "squeeze", "ship-300", "ladder.json"), "w"))
    assert crit(V.verdict(root), "3")["pass"] is None
