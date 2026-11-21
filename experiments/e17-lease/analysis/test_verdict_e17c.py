import json
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import verdict_e17c as VC  # noqa: E402
from test_verdict import PIN, ladder, le, write_rung  # noqa: E402
from test_warmcold import call  # noqa: E402
from test_warmcold_lease import exec_line, start_line  # noqa: E402


# ---- fixtures: small synthetic rung trees ------------------------------------------------------------------------
# Ruling R-z2: the gated N=1 rungs are the seal stages' seeds N1-l<k> (seeds 11..14), read only when evaluable.
EVAL = {"holds": True, "reason": None}


def preds(tmp_path, reading="plus45", sealed=True, name="predictions-e17c.json"):
    p = str(tmp_path / name)
    body = {"sealed": sealed}
    if reading is not None:
        body["criterion5a_reading"] = reading
    json.dump(body, open(p, "w"))
    return p


def vmf(t=3, f=1, r45=4, p45=1, rtail=2, ptail=0, r15=4, p15=4, j45=4, pj45=1, ratio=1.1, first_ms=440.0,
        valid=True, fp=True):
    """A vm_age_lease.json with Task 6's E17c fpr keys (flat in fpr) and a replacement reading."""
    fpr = {"share_true": 0.5, "follows_true": 1, "follows_false": 1, "not_judged_low_growth": 0,
           "absolute": {"readings": 2, "pinned": 1, "pinned_share": 0.5, "judged_readings": 2}}
    if fp:
        sh = lambda n, d: (n / float(d)) if d else None  # noqa: E731
        fpr.update({"follows_fp_true": t, "follows_fp_false": f, "follows_fp_null": 0, "not_judged_low_growth_fp": 0,
                    "share_true_fp": sh(t, t + f),
                    "fp_15s_readings": r15, "fp_15s_pinned": p15, "pinned_share_fp_15s": sh(p15, r15),
                    "fp_45s_readings": r45, "fp_45s_pinned": p45, "pinned_share_fp_45s": sh(p45, r45),
                    "fp_45s_judged_readings": j45, "pinned_share_fp_45s_of_judged": sh(pj45, j45),
                    "fp_15s_judged_readings": r15, "pinned_share_fp_15s_of_judged": sh(p15, r15),
                    "fp_idle_tail_readings": rtail, "fp_idle_tail_pinned": ptail,
                    "pinned_share_fp_idle_tail": sh(ptail, rtail), "idle_tail_leases": rtail})
    return {"mapping_valid": valid, "fpr": fpr if valid else None,
            "replacement": {"replacement_leases": 2 if first_ms else 0, "with_first_py_grep": 2 if first_ms else 0,
                            "median_first_py_grep_ms": first_ms,
                            "sbx_median_py_grep_ms": 400.0 if ratio else None, "ratio_to_sbx": ratio}}


def lat(root, point, arm, name, n, short_ms, import_ms, **files):
    """A latency rung: a lease arm's first call then a warm py_short and py_import; sbx's two calls."""
    if arm == "sbx":
        log = [exec_line("S", "vm-%d" % i, req=i) for i in (1, 2)]
        calls = [call("S", 1, cls="py_short", ms=short_ms), call("S", 2, cls="py_import", ms=import_ms)]
    else:
        log = [start_line("A", "vm-1"), exec_line("A", "vm-1"), exec_line("A", "vm-1", req=2),
               exec_line("A", "vm-1", req=3)]
        ev = [{"state": "start", "reason": "", "at_unix_ms": 1, "age_ms": 0, "mode": "lease"}]
        calls = [call("A", 1, first_lease=True, lease_events=ev), call("A", 2, cls="py_short", ms=short_ms),
                 call("A", 3, cls="py_import", ms=import_ms)]
    return write_rung(root, point, arm, name, n, calls, log, **files)


def c2_tree(root, seeds=4, sbx_seeds=None, short_ms=100, import_ms=600, n128=True, arms=("ship-300",),
            n128_import_ms=None, reason=None):
    """sbx 400/1000 ms; the lease arms short_ms/import_ms: gains 1 - 100/400 = 0.75, 1 - 600/1000 = 0.40. Every seed
    is evaluable (record.json, reason `reason`); n128_import_ms overrides the lease arms' N=128 py_import."""
    rec = {"holds": True, "reason": reason}
    for k in range(1, (sbx_seeds if sbx_seeds is not None else seeds) + 1):
        lat(root, "pycache", "sbx", "N1-l%d" % (10 + k), 1, 400, 1000, record_json=rec)
    for arm in arms:
        for k in range(1, seeds + 1):
            lat(root, "pycache", arm, "N1-l%d" % (10 + k), 1, short_ms, import_ms, record_json=rec)
    if n128:
        lat(root, "pycache", "sbx", "N128-lat", 128, 400, 1000)
        for arm in arms:
            lat(root, "pycache", arm, "N128-lat", 128, short_ms,
                import_ms if n128_import_ms is None else n128_import_ms)


def squeeze_tree(root, point="squeeze", **kw):
    a = write_rung(root, point, "ship-300", "N64", 64, lease_ends_json=le(**dict({"reclaims": 3}, **kw)))
    ladder(root, point, "ship-300", squeeze={"stop_n": 64, "stopped_by": "reclaim_rate", "memmax_mb": 24576,
                                            "rungs": [{"n": 64, "met": True, "dir": a}]})


def c5a_tree(root, **kw):
    """ship-300 at pycache: one N=1 seed and N128-lat (pooled); ship-300-nd beside them (reported only)."""
    write_rung(root, "pycache", "ship-300", "N1-l11", 1, record_json=EVAL, vm_age_lease_json=vmf(**kw.get("s1", {})))
    write_rung(root, "pycache", "ship-300", "N128-lat", 128, vm_age_lease_json=vmf(**kw.get("n128", {})))
    write_rung(root, "pycache", "ship-300-nd", "N128-lat", 128,
               vm_age_lease_json=vmf(**kw.get("nd", dict(t=0, f=4, p45=4, ptail=2))))


def full_tree(root):
    """Every gated criterion passes."""
    c2_tree(root)
    # the vm_age_lease outputs ride on the latency rungs, as the chain's analysis gate writes them
    for name in ("N1-l11", "N1-l12", "N1-l13", "N1-l14", "N128-lat"):
        json.dump(vmf(), open(os.path.join(root, "pycache", "ship-300", name, "vm_age_lease.json"), "w"))
    # 5b' reads every ship-* rung at pycache, ship-300-nd's too
    write_rung(root, "pycache", "ship-300-nd", "N128-lat", 128, vm_age_lease_json=vmf(ratio=0.9))
    squeeze_tree(root)


def V(root, p=None, **kw):
    return VC.verdict(root, predictions=p, **kw)


def crit(r, k):
    c = r["criteria"][k]
    assert set(c) >= {"name", "value", "inputs", "missing", "pass", "why"}
    return c


# ---- 5a': the charge after a heavy command, on the reading predictions-e17c.json names --------------------------

def test_5a_plus45_pools_ship_300_by_summing_counts(tmp_path):
    root = str(tmp_path / "runs")
    # s1: follows 3/4, pinned 1/4 at +45 s; N128: follows 1/4, pinned 3/4 -> pooled 4/8 and 4/8 (both at the bars)
    c5a_tree(root, s1=dict(t=3, f=1, r45=4, p45=1), n128=dict(t=1, f=3, r45=4, p45=3))
    c = crit(V(root, preds(tmp_path)), "5a_prime")
    v = c["value"]
    assert v["reading"] == "plus45" and v["arm"] == "ship-300" and v["point"] == "pycache"
    assert v["pooled"]["follows_fp_true"] == 4 and v["pooled"]["follows_fp_false"] == 4
    assert v["follow_share"] == pytest.approx(0.5) and v["pinned_share"] == pytest.approx(0.5)
    assert v["pooled"]["plus45"]["readings"] == 8 and v["pooled"]["plus45"]["pinned"] == 4
    assert v["bars"] == {"follow_share_min": 0.5, "pinned_share_max": 0.5}
    assert c["pass"] is True and c["why"] == []
    assert len(v["rungs"]) == 2  # ship-300-nd is not pooled
    assert all("ship-300-nd" not in p for p in c["inputs"])


def test_5a_reports_the_of_judged_variants_and_both_readings(tmp_path):
    root = str(tmp_path / "runs")
    c5a_tree(root, s1=dict(j45=2, pj45=1), n128=dict(j45=2, pj45=0))
    v = crit(V(root, preds(tmp_path)), "5a_prime")["value"]
    assert v["pooled"]["plus45"]["judged_readings"] == 4 and v["pooled"]["plus45"]["judged_pinned"] == 1
    assert v["pooled"]["plus45"]["pinned_share_of_judged"] == pytest.approx(0.25)
    assert v["pooled"]["idle_tail"]["readings"] == 4 and v["pooled"]["idle_tail"]["pinned_share"] == 0.0
    assert v["pooled"]["plus15"]["pinned_share"] == pytest.approx(1.0)  # reported beside, never gated


@pytest.mark.parametrize("s1,n128,why", [
    (dict(t=3, f=2), dict(t=1, f=3), "follow"),           # 4/9 < 0.50
    (dict(r45=4, p45=2), dict(r45=4, p45=3), "pinned"),   # 5/8 > 0.50
])
def test_5a_fails_at_either_bar(tmp_path, s1, n128, why):
    root = str(tmp_path / "runs")
    c5a_tree(root, s1=s1, n128=n128)
    c = crit(V(root, preds(tmp_path)), "5a_prime")
    assert c["pass"] is False and any(why in w for w in c["why"])


def test_5a_idle_tail_reading_uses_the_idle_tail_counts(tmp_path):
    root = str(tmp_path / "runs")
    # +45 s would fail (pinned 8/8), the idle tail passes (pinned 1/4)
    c5a_tree(root, s1=dict(p45=4, rtail=2, ptail=1), n128=dict(p45=4, rtail=2, ptail=0))
    c = crit(V(root, preds(tmp_path, "idle_tail")), "5a_prime")
    assert c["value"]["reading"] == "idle_tail" and c["value"]["pinned_share"] == pytest.approx(0.25)
    assert c["pass"] is True
    c = crit(V(root, preds(tmp_path, "plus45", name="p45.json")), "5a_prime")
    assert c["pass"] is False


@pytest.mark.parametrize("kind", ["absent", "unsealed", "no_field", "other_value", "unreadable"])
def test_5a_without_a_sealed_reading_is_null_never_a_default(tmp_path, kind):
    root = str(tmp_path / "runs")
    c5a_tree(root)
    p = {"absent": str(tmp_path / "nope.json"), "unsealed": preds(tmp_path, sealed=False),
         "no_field": preds(tmp_path, reading=None), "other_value": preds(tmp_path, reading="plus15")}.get(kind)
    if kind == "unreadable":
        p = str(tmp_path / "bad.json")
        open(p, "w").write("{not json")
    r = V(root, p)
    c = crit(r, "5a_prime")
    assert c["pass"] is None and c["value"]["reading"] is None
    assert any("criterion5a_reading" in m or "predictions" in m for m in c["missing"])
    assert c["value"]["pooled"]["plus45"]["readings"] == 8  # still reported
    assert r["predictions"]["path"] == p


def test_5a_rung_without_its_reading_is_null_and_listed(tmp_path):
    root = str(tmp_path / "runs")
    c5a_tree(root, n128=dict(fp=False))  # an E17b-shaped vm_age_lease.json: no vm_fp keys
    write_rung(root, "pycache", "ship-300", "N1-l12", 1, record_json=EVAL)  # no vm_age_lease.json at all
    c = crit(V(root, preds(tmp_path)), "5a_prime")
    assert c["pass"] is None
    assert any("N1-l12/vm_age_lease.json" in m for m in c["missing"])
    assert any("N128-lat" in m and "vm_fp" in m for m in c["missing"])


def test_5a_invalid_mapping_is_null(tmp_path):
    root = str(tmp_path / "runs")
    c5a_tree(root, n128=dict(valid=False))
    c = crit(V(root, preds(tmp_path)), "5a_prime")
    assert c["pass"] is None and any("mapping_valid" in m for m in c["missing"])


def test_5a_no_ship_300_rung_is_null(tmp_path):
    root = str(tmp_path / "runs")
    os.makedirs(root)
    c = crit(V(root, preds(tmp_path)), "5a_prime")
    assert c["pass"] is None and c["missing"]


# ---- 2': warm gains, pooled N=1 seeds and N=128 ------------------------------------------------------------------

def test_2_pools_the_n1_seeds_and_n128(tmp_path):
    root = str(tmp_path / "runs")
    c2_tree(root, seeds=4)
    lat(root, "pycache", "sbx", "N1-probe-py_short", 1, 99999, 99999)  # a probe is not a seed
    c = crit(V(root), "2_prime")
    g = c["value"]["gated"]
    assert g["1"]["py_short"] == pytest.approx(0.75) and g["1"]["py_import"] == pytest.approx(0.40)
    assert g["128"]["py_short"] == pytest.approx(0.75)
    assert c["value"]["seeds"] == {"sbx": 4, "ship-300": 4} and c["value"]["min_seeds"] == 4
    assert c["pass"] is True
    assert not any(p.endswith("N1-probe-py_short") for p in c["inputs"])


@pytest.mark.parametrize("short_ms,import_ms,want", [(200, 700, True), (210, 600, False), (100, 750, False)])
def test_2_bars(tmp_path, short_ms, import_ms, want):
    root = str(tmp_path / "runs")
    c2_tree(root, short_ms=short_ms, import_ms=import_ms)
    assert crit(V(root), "2_prime")["pass"] is want


@pytest.mark.parametrize("seeds,sbx_seeds", [(3, 4), (4, 3)])
def test_2_fewer_than_4_seeds_per_arm_is_null(tmp_path, seeds, sbx_seeds):
    root = str(tmp_path / "runs")
    c2_tree(root, seeds=seeds, sbx_seeds=sbx_seeds, import_ms=900, n128_import_ms=600)  # an N=1 fail is not judged
    c = crit(V(root), "2_prime")
    assert c["pass"] is None and any("evaluable seed" in m for m in c["missing"])
    assert c["value"]["n1_judged"] is False


def test_2_fewer_than_4_seeds_does_not_hide_an_n128_failure(tmp_path):
    root = str(tmp_path / "runs")
    c2_tree(root, seeds=3, n128_import_ms=900)
    c = crit(V(root), "2_prime")
    assert c["pass"] is False and any("N=128" in w and "py_import" in w for w in c["why"])


def mark_empty_window(root, arm, name):
    json.dump({"holds": False, "reason": "empty_window"},
              open(os.path.join(root, "pycache", arm, name, "record.json"), "w"))


def test_2_counts_evaluable_seeds_only_4_dirs_one_empty_window_is_null(tmp_path):
    # R-l': 4 seed directories, one with reason empty_window -> 3 evaluable ship-300 seeds
    root = str(tmp_path / "runs")
    c2_tree(root, seeds=4)
    mark_empty_window(root, "ship-300", "N1-l12")
    c = crit(V(root), "2_prime")
    assert c["value"]["seeds"] == {"sbx": 4, "ship-300": 3}
    assert c["pass"] is None and any("ship-300 has 3 evaluable seed" in m for m in c["missing"])
    assert [x["state"] for x in c["value"]["seeds_not_evaluable"]] == ["empty_window"]


def test_2_four_evaluable_plus_one_empty_window_is_judged_on_the_4(tmp_path):
    root = str(tmp_path / "runs")
    c2_tree(root, seeds=4)
    # a fifth ship-300 seed, empty_window, whose calls would fail the bar were it read
    lat(root, "pycache", "ship-300", "N1-l15", 1, 99999, 99999, record_json={"holds": False, "reason": "empty_window"})
    c = crit(V(root), "2_prime")
    assert c["value"]["seeds"] == {"sbx": 4, "ship-300": 4} and c["value"]["n1_judged"] is True
    assert c["value"]["gated"]["1"]["py_short"] == pytest.approx(0.75)
    assert not any(p.endswith("ship-300/N1-l15") for p in c["inputs"])
    assert c["pass"] is True


@pytest.mark.parametrize("state", ["no_record", "unreadable"])
def test_2_seed_without_a_readable_record_is_not_evaluable(tmp_path, state):
    root = str(tmp_path / "runs")
    c2_tree(root, seeds=4)
    lat(root, "pycache", "sbx", "N1-l15", 1, 400, 1000)
    if state == "unreadable":
        open(os.path.join(root, "pycache", "sbx", "N1-l15", "record.json"), "w").write("{")
    c = crit(V(root), "2_prime")
    assert c["value"]["seeds"]["sbx"] == 4 and c["value"]["seeds_not_evaluable"][0]["state"] == state
    # an unreadable record is unknown, never read as fine: null; a seed with no record is simply not one
    assert c["pass"] is (None if state == "unreadable" else True)


def test_2_without_n128_is_null(tmp_path):
    root = str(tmp_path / "runs")
    c2_tree(root, n128=False)
    assert crit(V(root), "2_prime")["pass"] is None


def test_2_reports_ship_300_nd_and_never_gates_it(tmp_path):
    root = str(tmp_path / "runs")
    c2_tree(root, arms=("ship-300",))
    for k in range(1, 5):
        lat(root, "pycache", "ship-300-nd", "N1-l%d" % (10 + k), 1, 390, 990,  # fails the bars: reported only
            record_json={"reason": None})
    lat(root, "pycache", "ship-300-nd", "N128-lat", 128, 390, 990)
    r = V(root)
    assert crit(r, "2_prime")["pass"] is True
    nd = r["reported"]["ship-300-nd"]["latency"]
    assert nd["1"]["py_short"] == pytest.approx(1 - 390 / 400.0) and nd["128"]["py_import"] == pytest.approx(0.01)


# ---- 5b': replacement leases, every ship-* rung at pycache -------------------------------------------------------

def test_5b_every_ship_rung_within_1_5(tmp_path):
    root = str(tmp_path / "runs")
    c5a_tree(root, s1=dict(ratio=1.5), n128=dict(ratio=0.8), nd=dict(ratio=1.2))
    write_rung(root, "pycache", "ship-300", "N1-l12", 1, record_json=EVAL, vm_age_lease_json=vmf(ratio=None, first_ms=None))
    c = crit(V(root), "5b_prime")
    assert c["pass"] is True
    assert c["value"]["ratio_to_sbx_max"] == 1.5 and c["value"]["bar"] == 1.5
    assert c["value"]["rungs_without_replacement"] == 1  # no replacement lease: no reading, not a failure


def test_5b_one_rung_above_fails(tmp_path):
    root = str(tmp_path / "runs")
    c5a_tree(root, nd=dict(ratio=1.6))
    c = crit(V(root), "5b_prime")
    assert c["pass"] is False and any("ship-300-nd" in w and "1.6" in w for w in c["why"])


def test_5b_replacement_without_sbx_baseline_is_null(tmp_path):
    root = str(tmp_path / "runs")
    c5a_tree(root, n128=dict(ratio=None))  # a first py_grep, but no sbx median
    c = crit(V(root), "5b_prime")
    assert c["pass"] is None and any("N128-lat" in m for m in c["missing"])


def test_5b_an_arm_with_no_ratio_is_null(tmp_path):
    root = str(tmp_path / "runs")
    c5a_tree(root, nd=dict(ratio=None, first_ms=None))
    c = crit(V(root), "5b_prime")
    assert c["pass"] is None and any("ship-300-nd" in m for m in c["missing"])


def test_5b_ship_rung_without_vm_age_lease_is_null(tmp_path):
    root = str(tmp_path / "runs")
    c5a_tree(root)
    write_rung(root, "pycache", "ship-300-nd", "N1-l11", 1, record_json=EVAL)
    c = crit(V(root), "5b_prime")
    assert c["pass"] is None and any("ship-300-nd/N1-l11/vm_age_lease.json" in m for m in c["missing"])


# ---- 3': E17b's criterion 3 at squeeze, ship-300 -----------------------------------------------------------------

def test_3_is_e17b_criterion_3_at_squeeze_only(tmp_path):
    root = str(tmp_path / "runs")
    squeeze_tree(root)
    squeeze_tree(root, point="squeeze-256", guards=2)  # fails, but squeeze-256 is reported, not gated
    r = V(root)
    c = crit(r, "3_prime")
    assert c["pass"] is True and list(c["value"]) == ["squeeze"]
    s256 = r["reported"]["ram256"]["squeeze-256"]
    assert s256["pass"] is False and s256["value"]["squeeze-256"]["totals"]["guards"] == 2


@pytest.mark.parametrize("kw", [dict(guards=1), dict(with_idle=1), dict(wrong=1), dict(reclaims=0)])
def test_3_failures(tmp_path, kw):
    root = str(tmp_path / "runs")
    squeeze_tree(root, **kw)
    assert crit(V(root), "3_prime")["pass"] is False


def test_3_no_climb_is_null(tmp_path):
    root = str(tmp_path / "runs")
    os.makedirs(root)
    assert crit(V(root), "3_prime")["pass"] is None


# ---- the top-level pass -------------------------------------------------------------------------------------------

def test_top_level_pass_true_only_when_all_four_hold(tmp_path):
    root = str(tmp_path / "runs")
    full_tree(root)
    r = V(root, preds(tmp_path))
    assert [r["criteria"][k]["pass"] for k in VC.GATED] == [True] * 4
    assert r["pass"] is True


def test_top_level_pass_null_when_any_is_null(tmp_path):
    root = str(tmp_path / "runs")
    full_tree(root)
    r = V(root, None)  # no predictions path given
    assert r["criteria"]["5a_prime"]["pass"] is None and r["pass"] is None


def test_top_level_pass_null_when_one_is_null_and_another_false(tmp_path):
    root = str(tmp_path / "runs")
    full_tree(root)
    json.dump(vmf(ratio=2.0), open(os.path.join(root, "pycache", "ship-300", "N128-lat", "vm_age_lease.json"), "w"))
    r = V(root, None)  # 5a' null (no predictions), 5b' false
    assert r["criteria"]["5a_prime"]["pass"] is None and r["criteria"]["5b_prime"]["pass"] is False
    assert r["pass"] is None


def test_top_level_pass_false_when_one_fails(tmp_path):
    root = str(tmp_path / "runs")
    full_tree(root)
    json.dump(vmf(ratio=2.0), open(os.path.join(root, "pycache", "ship-300", "N128-lat", "vm_age_lease.json"), "w"))
    r = V(root, preds(tmp_path))
    assert r["criteria"]["5b_prime"]["pass"] is False and r["pass"] is False
    assert any("5b_prime" in w for w in r["why"])


# ---- reported, never gated ----------------------------------------------------------------------------------------

def test_reported_ship_300_nd_5a_on_every_reading(tmp_path):
    root = str(tmp_path / "runs")
    c5a_tree(root)
    r = V(root, preds(tmp_path))
    nd = r["reported"]["ship-300-nd"]["5a"]
    assert nd["pooled"]["follows_fp_true"] == 0 and nd["follow_share"] == 0.0
    assert nd["pooled"]["plus45"]["pinned_share"] == 1.0 and nd["pooled"]["idle_tail"]["pinned_share"] == 1.0
    assert "pass" not in nd


def test_reported_pycache_low_gains_and_its_cut(tmp_path):
    root = str(tmp_path / "runs")
    lat(root, "pycache-low", "sbx", "N128-lat", 128, 400, 1000)
    lat(root, "pycache-low", "ship-300", "N128-lat", 128, 100, 600)
    r = V(root)
    pl = r["reported"]["pycache-low"]
    assert pl["latency"]["ship-300"]["128"]["py_short"] == pytest.approx(0.75)
    assert pl["gate"] is None
    gate = {"pass": False, "cut": True, "seeds": {"sbx": [3, 1, 0, 2]}}
    os.makedirs(os.path.join(root, "pycache-low"), exist_ok=True)
    json.dump(gate, open(os.path.join(root, "pycache-low", "gate-pycache-low.json"), "w"))
    pl = V(root)["reported"]["pycache-low"]
    assert pl["gate"]["value"] == gate and pl["gate"]["path"].endswith("pycache-low/gate-pycache-low.json")
    other = str(tmp_path / "elsewhere.json")
    json.dump({"pass": True}, open(other, "w"))
    assert V(root, gate_pycache_low=other)["reported"]["pycache-low"]["gate"]["value"] == {"pass": True}


def test_reported_pycache_low_n1_reads_the_baseline_seeds_not_the_gate_rungs(tmp_path):
    """R-v: pycache-low's reported N=1 is its baseline seeds N1-s<k> (evaluable ones); the gate's N1-g<k> rungs are
    calibration only and never read."""
    root = str(tmp_path / "runs")
    rec = {"holds": True, "reason": None}
    for k in (1, 2):
        lat(root, "pycache-low", "sbx", "N1-s%d" % k, 1, 400, 1000, record_json=rec)
        lat(root, "pycache-low", "ship-300", "N1-s%d" % k, 1, 100, 600, record_json=rec)
    lat(root, "pycache-low", "ship-300", "N1-s3", 1, 400, 1000, record_json={"reason": "empty_window"})
    for k in (1, 2, 3, 4):  # slow gate rungs: read, they would pull the N=1 gain down
        lat(root, "pycache-low", "sbx", "N1-g%d" % k, 1, 400, 1000, record_json=rec)
        lat(root, "pycache-low", "ship-300", "N1-g%d" % k, 1, 400, 1000, record_json=rec)
    pl = V(root)["reported"]["pycache-low"]
    assert pl["latency"]["ship-300"]["1"]["py_short"] == pytest.approx(0.75)
    assert pl["latency"]["ship-300"]["1"]["py_import"] == pytest.approx(0.40)
    names = sorted(os.path.basename(d) for d in pl["inputs"])
    assert names == ["N1-s1", "N1-s1", "N1-s2", "N1-s2"]
    assert pl["latency_error"] is None


def test_reported_256_mib_stages(tmp_path):
    root = str(tmp_path / "runs")
    lat(root, "pycache-d64", "sbx", "N1-ram256", 1, 400, 1000)
    lat(root, "pycache-d64", "ship-300", "N1-ram256", 1, 100, 600, vm_age_lease_json=vmf(t=9, f=0))
    r = V(root, preds(tmp_path))
    d64 = r["reported"]["ram256"]["pycache-d64"]
    assert d64["latency"]["ship-300"]["1"]["py_short"] == pytest.approx(0.75)
    assert d64["5a"]["ship-300"]["pooled"]["follows_fp_true"] == 9
    # never pooled into the gated pycache readings
    assert crit(r, "5a_prime")["value"]["pooled"]["follows_fp_true"] == 0


def test_reported_256_mib_reads_the_ram256_rungs_not_the_gate_256_rungs(tmp_path):
    """Task 10: gate-256's calibration rungs (pycache-d64 N1-g256-s<scale>, the probe corpus and a gate library) are
    never read as the 256 MiB stage; its gate-256.json is reported beside it."""
    root = str(tmp_path / "runs")
    lat(root, "pycache-d64", "sbx", "N1-ram256", 1, 400, 1000)
    lat(root, "pycache-d64", "ship-300", "N1-ram256", 1, 100, 600, vm_age_lease_json=vmf(t=9, f=0))
    for s in (16, 8):  # slow gate rungs: read, they would pull the gain down and add to 5a
        lat(root, "pycache-d64", "sbx", "N1-g256-s%d" % s, 1, 400, 1000)
        lat(root, "pycache-d64", "ship-300", "N1-g256-s%d" % s, 1, 400, 1000, vm_age_lease_json=vmf(t=5, f=0))
    json.dump({"stage": "gate-256", "pass": True, "chosen_scale": 8, "reason": "scale 8 passed"},
              open(os.path.join(root, "pycache-d64", "gate-256.json"), "w"))
    d64 = V(root, preds(tmp_path))["reported"]["ram256"]["pycache-d64"]
    assert d64["latency"]["ship-300"]["1"]["py_short"] == pytest.approx(0.75)
    assert d64["5a"]["ship-300"]["pooled"]["follows_fp_true"] == 9
    assert d64["gate"] == {"pass": True, "chosen_scale": 8, "reason": "scale 8 passed",
                           "path": os.path.join(root, "pycache-d64", "gate-256.json")}
    os.remove(os.path.join(root, "pycache-d64", "gate-256.json"))
    assert V(root, preds(tmp_path))["reported"]["ram256"]["pycache-d64"]["gate"] is None


def test_reported_ownership_walk_per_size(tmp_path):
    root = str(tmp_path / "runs")
    for n, ms in ((10000, 91.0), (100000, 756.0)):
        d = os.path.join(root, "ownwalk", "ship-300", "F%d" % n)
        os.makedirs(d)
        json.dump({"files": n, "valid": True, "median_walk_ms": ms, "phase_corrected_walk_median_ms": ms - 1,
                   "walk_observed_median_ms": ms - 2, "runs": [{"rep": 1}]}, open(os.path.join(d, "ownwalk.json"), "w"))
    w = V(root)["reported"]["ownwalk"]
    assert sorted(w["sizes"]) == ["10000", "100000"]
    assert w["sizes"]["100000"]["walk_observed_median_ms"] == 754.0 and w["sizes"]["10000"]["median_walk_ms"] == 91.0
    assert "runs" not in w["sizes"]["10000"]


def test_other_commit_is_excluded(tmp_path):
    root = str(tmp_path / "runs")
    c5a_tree(root)
    write_rung(root, "pycache", "ship-300", "N1-l19", 1, commit="2" * 40, record_json=EVAL, vm_age_lease_json=vmf(t=0, f=99))
    r = VC.verdict(root, moca_commit=PIN, predictions=preds(tmp_path))
    assert [e["rung"].split(os.sep)[-1] for e in r["excluded_rungs"]] == ["N1-l19"]
    assert crit(r, "5a_prime")["value"]["pooled"]["follows_fp_false"] == 2


# ---- the CLI ------------------------------------------------------------------------------------------------------

def test_default_predictions_path_is_beside_the_analysis_dir():
    assert VC.DEFAULT_PREDICTIONS == os.path.join(os.path.dirname(HERE), "predictions-e17c.json")


def test_main_writes_the_verdict(tmp_path, capsys):
    root = str(tmp_path / "runs")
    full_tree(root)
    out = str(tmp_path / "verdict.json")
    VC.main([root, "--moca-commit", PIN, "--out", out, "--predictions", preds(tmp_path)])
    r = json.load(open(out))
    assert r["pass"] is True and r["moca_commit"] == PIN and sorted(r["criteria"]) == sorted(VC.GATED)
    o = capsys.readouterr().out
    assert "verdict.json" in o and "pass True" in o


# ---- fix round 1, item 2: 5a' reads the keys vm_age_lease.py really writes ----------------------------------------

def test_5a_reads_the_producers_numbers(tmp_path):
    """Two ship-300 rungs built with test_vm_age_lease's E17c fixture, analysed by the real vm_age_lease.main (as the
    chain's analysis gate runs it), then the verdict over the tree."""
    import test_vm_age_lease as TL
    import vm_age_lease as VAL
    os.makedirs(str(tmp_path / "runs" / "pycache" / "ship-300"))
    # follows on vm_fp, +45 s and idle tail at 150 MiB (not pinned); then one that stays at 950 MiB and drops to
    # 1000 MiB (follows false, pinned at +45 s and at the idle tail)
    specs = (("N1-l11", 1, {}), ("N128-lat", 128, dict(fp_after=950, fp_drop=1000)))
    fprs = []
    for name, n, kw in specs:
        d = TL.fp_fixture(tmp_path, name="runs/pycache/ship-300/" + name, **kw)
        json.dump({"arm": "ship-300", "n": n, "point": "pycache", "moca_commit": PIN},
                  open(os.path.join(d, "params.json"), "w"))
        json.dump(EVAL, open(os.path.join(d, "record.json"), "w"))  # an evaluable seal seed
        VAL.main([d, "--sbx-median-ms", "400"])
        fprs.append(json.load(open(os.path.join(d, "vm_age_lease.json")))["fpr"])
    root = str(tmp_path / "runs")
    for reading, infix in (("plus45", "45s"), ("idle_tail", "idle_tail")):
        c = crit(VC.verdict(root, PIN, predictions=preds(tmp_path, reading, name=reading + ".json")), "5a_prime")
        v = c["value"]
        t, f = (sum(x[k] for x in fprs) for k in ("follows_fp_true", "follows_fp_false"))
        assert (t, f) == (1, 1)  # the fixture behaves as designed
        assert v["pooled"]["follows_fp_true"] == t and v["pooled"]["follows_fp_false"] == f
        assert v["follow_share"] == pytest.approx(t / float(t + f))
        rd, pn = (sum(x["fp_%s_%s" % (infix, k)] for x in fprs) for k in ("readings", "pinned"))
        assert (rd, pn) == (2, 1)
        assert v["pooled"][reading]["readings"] == rd and v["pooled"][reading]["pinned"] == pn
        assert v["pinned_share"] == pytest.approx(pn / float(rd))
        assert [r["share_true_fp"] for r in v["rungs"]] == [x["share_true_fp"] for x in fprs]
        assert [r["pinned_share_fp_" + infix] for r in v["rungs"]] == [x["pinned_share_fp_" + infix] for x in fprs]
        assert v["pooled"]["plus45"]["judged_readings"] == sum(x["fp_45s_judged_readings"] for x in fprs)
        assert c["missing"] == [] and c["pass"] is True  # 0.50 and 0.50: at both bars


# ---- final fix wave, R-z2/R-z3: the gated pools read the seal stages' rungs only ---------------------------------

def noise(root):
    """Every pycache rung the gated pools must never read, with readings that would move every gated number: the
    bring-up smoke, a class probe, the cal seeds N1-s<k> (evaluable: the predictions are drafted from them), a gate
    rung and an empty_window seal seed, in all three arms."""
    bad = dict(t=0, f=99, r45=50, p45=50, rtail=50, ptail=50, ratio=9.0)
    ok, empty = {"holds": True, "reason": None}, {"holds": False, "reason": "empty_window"}
    names = [("N1-smoke", ok), ("N1-probe-py_short", ok), ("N1-g1", ok), ("N1-l15", empty)]
    names += [("N1-s%d" % k, ok) for k in range(1, 7)]
    for arm in ("sbx", "ship-300", "ship-300-nd"):
        for name, rec in names:
            if arm == "sbx":
                lat(root, "pycache", arm, name, 1, 50, 50, record_json=rec)  # a fast sbx: every gain would drop
            else:
                lat(root, "pycache", arm, name, 1, 99999, 99999, record_json=rec, vm_age_lease_json=vmf(**bad))


def gated_numbers(r):
    c = r["criteria"]
    return {"pass": [c[k]["pass"] for k in VC.GATED], "top": r["pass"],
            "2": (c["2_prime"]["value"]["gated"], c["2_prime"]["value"]["seeds"]),
            "5a": (c["5a_prime"]["value"]["pooled"], c["5a_prime"]["value"]["follow_share"],
                   c["5a_prime"]["value"]["pinned_share"], len(c["5a_prime"]["value"]["rungs"])),
            "5b": (c["5b_prime"]["value"]["ratio_to_sbx_max"], c["5b_prime"]["value"]["rungs_with_ratio"],
                   len(c["5b_prime"]["value"]["rungs"])),
            "nd": (r["reported"]["ship-300-nd"]["5a"]["pooled"], r["reported"]["ship-300-nd"]["latency"])}


def test_smoke_probe_cal_and_gate_rungs_never_move_the_gated_numbers(tmp_path):
    a, b = str(tmp_path / "a"), str(tmp_path / "b")
    full_tree(a)
    full_tree(b)
    noise(b)
    ra, rb = V(a, preds(tmp_path)), V(b, preds(tmp_path))
    assert ra["pass"] is True
    assert gated_numbers(rb) == gated_numbers(ra)
    for c in ("2_prime", "5a_prime", "5b_prime"):
        read = [os.path.basename(os.path.dirname(p)) if p.endswith(".json") else os.path.basename(p)
                for p in crit(rb, c)["inputs"]]
        assert read and all(n == "N128-lat" or n in ("N1-l11", "N1-l12", "N1-l13", "N1-l14") for n in read), (c, read)
    # the empty_window seal seed is listed as not evaluable, never read
    assert {os.path.basename(x["rung"]) for x in crit(rb, "2_prime")["value"]["seeds_not_evaluable"]} == {"N1-l15"}


def test_2_cal_seeds_do_not_count_toward_the_four(tmp_path):
    root = str(tmp_path / "runs")
    c2_tree(root, seeds=3)  # 3 seal seeds per arm
    rec = {"holds": True, "reason": None}
    for k in range(1, 5):  # 4 evaluable cal seeds per arm: calibration, not the seal's N=1 half
        lat(root, "pycache", "sbx", "N1-s%d" % k, 1, 400, 1000, record_json=rec)
        lat(root, "pycache", "ship-300", "N1-s%d" % k, 1, 100, 600, record_json=rec)
    c = crit(V(root), "2_prime")
    assert c["value"]["seeds"] == {"sbx": 3, "ship-300": 3} and c["value"]["n1_judged"] is False
    assert c["pass"] is None and any("evaluable seed(s) N1-l<k>" in m for m in c["missing"])


def test_5a_unreadable_seal_seed_record_is_null(tmp_path):
    root = str(tmp_path / "runs")
    c5a_tree(root)
    open(os.path.join(root, "pycache", "ship-300", "N1-l11", "record.json"), "w").write("{")
    c = crit(V(root, preds(tmp_path)), "5a_prime")
    assert c["pass"] is None and any("N1-l11/record.json unreadable" in m for m in c["missing"])

