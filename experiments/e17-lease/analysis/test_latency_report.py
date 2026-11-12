import json
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import latency_report as L  # noqa: E402
from test_warmcold import call, exec_line, resident_line, rung  # noqa: E402


def lease_rung(tmp_path, name="lease", arm="lease-120", n=1, point="pycache", **params):
    # Key A on vm-1: a cold first analyze (30 s), then warm analyzes of 5, 6 and 7 s (median 6 s);
    # an idle-destroy, then a cold analyze of 20 s on vm-2 (the first call after idle) and a warm
    # py_short. One unknown call (key B: no exec line), one out-of-window and one failed call.
    log = [exec_line("A", "vm-1", cold="first-exec")] + [exec_line("A", "vm-1")] * 3 + [
        resident_line("idle-destroy", "A", "vm-1"), exec_line("A", "vm-2", cold="parked"),
        exec_line("A", "vm-2"), exec_line("A", "vm-2"), exec_line("A", "vm-2")]
    calls = [call("A", 1, ms=30000), call("A", 2, ms=5000), call("A", 3, ms=7000), call("A", 4, ms=6000),
             call("A", 5, ms=20000), call("A", 6, cls="py_short", ms=300),
             call("A", 7, ms=1, in_window=False), call("A", 8, ms=1, status="err"),
             call("B", 1, ms=9000)]
    d = rung(tmp_path, calls, log, name=name)
    with open(os.path.join(d, "params.json"), "w") as f:
        json.dump(dict({"arm": arm, "n": n, "point": point, "seed": 1}, **params), f)
    return d


def sbx_rung(tmp_path, name="sbx", n=1, point="pycache", **params):
    # Every call on a VM of its own: analyzes 9, 10, 11 s (median 10 s), one py_short.
    log = [exec_line("S", "vm-%d" % i) for i in range(1, 5)]
    calls = [call("S", 1, ms=9000), call("S", 2, ms=10000), call("S", 3, ms=11000),
             call("S", 4, cls="py_short", ms=400)]
    d = rung(tmp_path, calls, log, name=name)
    with open(os.path.join(d, "params.json"), "w") as f:
        json.dump(dict({"arm": "sbx", "n": n, "point": point, "seed": 1}, **params), f)
    return d


def group(rep, arm, n=1, point="pycache"):
    return next(g for g in rep["groups"] if (g["arm"], g["n"], g["point"]) == (arm, n, point))


def test_gain_formula(tmp_path):
    rep = L.build([lease_rung(tmp_path), sbx_rung(tmp_path)], baseline_arm="sbx")
    lease = group(rep, "lease-120")
    pa = lease["classes"]["py_analyze"]
    assert pa["warm"]["median_ms"] == 6000 and pa["warm"]["n"] == 3
    assert group(rep, "sbx")["classes"]["py_analyze"]["all"]["median_ms"] == 10000
    assert pa["gain"] == pytest.approx(0.4)
    assert pa["baseline_median_ms"] == 10000
    # No warm py_short call on sbx's side matters: gain uses the lease's warm median only.
    assert lease["classes"]["py_short"]["gain"] == pytest.approx(1 - 300 / 400.0)
    assert "gain" not in group(rep, "sbx")["classes"]["py_analyze"]


def test_first_call_after_idle_and_warm_share(tmp_path):
    rep = L.build([lease_rung(tmp_path), sbx_rung(tmp_path)], baseline_arm="sbx")
    lease = group(rep, "lease-120")
    after = lease["first_after_idle"]
    assert after["all"]["n"] == 1 and after["all"]["median_ms"] == 20000
    assert after["by_class"]["py_analyze"]["median_ms"] == 20000
    # In-window ok calls with a tag: 6 (2 cold, 4 warm); the unknown call is outside the share.
    assert lease["warm_share"] == pytest.approx(4 / 6.0)
    assert group(rep, "sbx")["warm_share"] == 0.0


def test_unknown_and_excluded_calls_are_counted(tmp_path):
    rep = L.build([lease_rung(tmp_path), sbx_rung(tmp_path)], baseline_arm="sbx")
    c = group(rep, "lease-120")["counts"]
    assert c == {"calls": 9, "used": 6, "unknown": 1, "not_in_window": 1, "not_ok": 1}
    assert group(rep, "lease-120")["classes"]["py_analyze"]["unknown"] == 1


def test_no_baseline_rung_gives_no_gain(tmp_path):
    rep = L.build([lease_rung(tmp_path, n=32)], baseline_arm="sbx")
    pa = group(rep, "lease-120", n=32)["classes"]["py_analyze"]
    assert pa["gain"] is None and pa["baseline_median_ms"] is None


def test_seeds_of_one_group_are_pooled(tmp_path):
    a = lease_rung(tmp_path, name="s1")
    b = lease_rung(tmp_path, name="s2")
    rep = L.build([a, b], baseline_arm="sbx")
    g = group(rep, "lease-120")
    assert g["counts"]["used"] == 12 and len(g["rungs"]) == 2


@pytest.mark.parametrize("field", ["dataset_mib", "snapshot_guest_ram_mb"])
def test_refuses_to_pool_different_dataset_or_guest_ram(tmp_path, field):
    a = lease_rung(tmp_path, name="d64", **{field: 64})
    b = lease_rung(tmp_path, name="d256", **{field: 256})
    with pytest.raises(SystemExit) as e:
        L.build([a, b], baseline_arm="sbx")
    assert field in str(e.value) and "pycache" in str(e.value) and "lease-120" in str(e.value)
    with pytest.raises(SystemExit) as e:
        L.main([a, b, "--out", str(tmp_path / "out")])
    assert e.value.code not in (0, None)
    # The same values pool.
    c = lease_rung(tmp_path, name="d256b", **{field: 256})
    assert group(L.build([b, c]), "lease-120")["counts"]["used"] == 12


@pytest.mark.parametrize("field", ["dataset_mib", "snapshot_guest_ram_mb"])
def test_refuses_gain_against_baseline_with_other_dataset_or_guest_ram(tmp_path, field):
    # The gain-against-D runs: lease at D=64 must not be divided by sbx at D=256.
    lease = lease_rung(tmp_path, name="lease-d64", **{field: 64})
    sbx = sbx_rung(tmp_path, name="sbx-d256", **{field: 256})
    with pytest.raises(SystemExit) as e:
        L.build([lease, sbx], baseline_arm="sbx")
    msg = str(e.value)
    assert field in msg and "64" in msg and "256" in msg and lease in msg and sbx in msg
    with pytest.raises(SystemExit) as e:
        L.main([lease, sbx, "--baseline-arm", "sbx", "--out", str(tmp_path / "out")])
    assert e.value.code not in (0, None)
    # Matching values still give the gain.
    sbx64 = sbx_rung(tmp_path, name="sbx-d64", **{field: 64})
    rep = L.build([lease, sbx64], baseline_arm="sbx")
    assert group(rep, "lease-120")["classes"]["py_analyze"]["gain"] == pytest.approx(0.4)


def test_cli_writes_json_and_md(tmp_path):
    out = tmp_path / "out"
    L.main([lease_rung(tmp_path), sbx_rung(tmp_path), "--baseline-arm", "sbx", "--out", str(out)])
    rep = json.loads((out / "latency.json").read_text())
    assert group(rep, "lease-120")["classes"]["py_analyze"]["gain"] == pytest.approx(0.4)
    md = (out / "latency.md").read_text()
    assert "| pycache | 1 | lease-120 | py_analyze |" in md
    assert "0.40" in md
    assert "warm share" in md.lower() and "first call after idle" in md.lower()
