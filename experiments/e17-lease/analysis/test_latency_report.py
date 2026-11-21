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


def with_shmem(d, key, log_line, at):
    """Insert a py_shmem call after each of key's calls numbered in `at`, its exec line right after
    that call's own (key's calls run one Exec each, in order: the k-th exec line of key is its k-th call)."""
    calls = [json.loads(l) for l in open(os.path.join(d, "calls.jsonl"))]
    mine = sorted(c["call"] for c in calls if c["session"] == key)
    out_c = []
    for c in calls:
        out_c.append(c)
        if c["session"] == key and c["call"] in at:
            out_c.append(call(key, c["call"] + 0.5, cls="py_shmem", ms=50))
    out_l, k = [], 0
    for line in open(os.path.join(d, "worker.log")):
        out_l.append(line)
        if 'vmpool: exec ' in line and 'workspace_key="%s"' % key in line:
            if mine[k] in at:
                out_l.append(log_line)
            k += 1
    with open(os.path.join(d, "calls.jsonl"), "w") as f:
        f.writelines(json.dumps(c) + "\n" for c in out_c)
    with open(os.path.join(d, "worker.log"), "w") as f:
        f.writelines(out_l)
    return d


def test_py_shmem_excluded_from_gates(tmp_path):
    # py_shmem is reported only: never a per-class median, never in the gain (the latency gates read
    # it), the counts, the warm share or the first call after idle; its calls are reported apart.
    plain = L.build([lease_rung(tmp_path, name="l0"), sbx_rung(tmp_path, name="s0")], baseline_arm="sbx")
    lease = with_shmem(lease_rung(tmp_path, name="l1"), "A", exec_line("A", "vm-1"), at={1, 2})
    sbx = with_shmem(sbx_rung(tmp_path, name="s1"), "S", exec_line("S", "vm-9"), at={1})
    rep = L.build([lease, sbx], baseline_arm="sbx")
    for arm in ("lease-120", "sbx"):
        g, p = group(rep, arm), group(plain, arm)
        assert "py_shmem" not in g["classes"]
        for k in ("classes", "counts", "warm_share", "first_after_idle"):
            assert g[k] == p[k], (arm, k)
        assert g["reported_only"]["py_shmem"]["all"]["n"] == {"lease-120": 2, "sbx": 1}[arm]
        assert g["reported_only"]["py_shmem"]["all"]["median_ms"] == 50
    assert "py_shmem" not in L.markdown(rep).split("## Warm share")[0]


def test_one_reported_only_definition():
    import warmcold_lease as WL
    assert L.REPORTED_ONLY is WL.REPORTED_ONLY


def test_first_lease_py_shmem_still_reports_the_first_lease_cost(tmp_path):
    # A session drawn to start at a py_shmem call: that call carries the first-lease walk, so it is
    # filed under first_lease (before the reported-only check), not under reported_only.
    from test_warmcold_lease import ev, exec_line as xl, start_line
    log = [start_line("A", "vm-1"), xl("A", "vm-1"), xl("A", "vm-1", req=2), xl("A", "vm-1", req=3)]
    calls = [call("A", 1, cls="py_shmem", ms=900, first_lease=True, lease_events=[ev("start")]),
             call("A", 2, ms=5000), call("A", 3, cls="py_shmem", ms=40)]
    d = rung(tmp_path, calls, log)
    with open(os.path.join(d, "params.json"), "w") as f:
        json.dump({"arm": "ship-300", "n": 1, "point": "pycache", "seed": 1}, f)
    g = L.build([d])["groups"][0]
    assert g["first_lease"]["calls"] == 1 and g["first_lease"]["by_class"]["py_shmem"]["median_ms"] == 900
    assert g["reported_only"]["py_shmem"]["all"]["n"] == 1  # only the later reading
    assert set(g["classes"]) == {"py_analyze"}


def by_tmpfs_rung(tmp_path, name="sbx-t", tmpfs=True):
    # sbx: S is a flagged session, T is not; py_short 500/700 ms (S) and 300 ms (T), py_import 2500 (S) and 2000 (T)
    log = [exec_line(k, "vm-%d" % i) for i, k in enumerate("SSSTT", 1)]
    flag = {"tmpfs": True} if tmpfs else {}
    calls = [call("S", 1, cls="py_short", ms=500, **flag), call("S", 2, cls="py_short", ms=700, **flag),
             call("S", 3, cls="py_import", ms=2500, **flag),
             call("T", 1, cls="py_short", ms=300), call("T", 2, cls="py_import", ms=2000)]
    d = rung(tmp_path, calls, log, name=name)
    with open(os.path.join(d, "params.json"), "w") as f:
        json.dump({"arm": "sbx", "n": 1, "point": "pycache", "seed": 1}, f)
    return d


def test_gated_classes_split_by_tmpfs(tmp_path):
    # R26: per group, py_short and py_import medians by the session's tmpfs flag, reported only (the
    # gain and the per-class medians are unchanged).
    g = group(L.build([by_tmpfs_rung(tmp_path)]), "sbx")
    bt = g["by_tmpfs"]
    assert set(bt) == {"py_short", "py_import"}
    assert bt["py_short"]["flagged"]["all"]["median_ms"] == 600 and bt["py_short"]["flagged"]["all"]["n"] == 2
    assert bt["py_short"]["unflagged"]["all"]["median_ms"] == 300
    assert bt["py_import"]["flagged"]["all"]["median_ms"] == 2500 and bt["py_import"]["unflagged"]["all"]["n"] == 1
    assert bt["py_short"]["flagged"]["warm"]["n"] == 0  # sbx is never warm
    assert g["classes"]["py_short"]["all"]["n"] == 3  # the class median still pools both
    # no flagged session at all (E15/E16/E17a rungs): the group keeps its exact shape
    assert "by_tmpfs" not in group(L.build([by_tmpfs_rung(tmp_path, name="plain", tmpfs=False)]), "sbx")


# ---- E17c Task 5: the warm split by the guest's page-cache drop (ruling R-g) ----

def test_warm_split_by_cache_drop_beside_the_unchanged_gain(tmp_path):
    from test_warmcold_lease import drop_rung
    ship = drop_rung(tmp_path)  # ship-300, lease_cache_drop 30s
    nd = drop_rung(tmp_path, drop="off", name="nd", arm="ship-300-nd")
    sbx = sbx_rung(tmp_path)  # py_analyze all median 10 s, py_short 400 ms
    rep = L.build([ship, nd, sbx], baseline_arm="sbx")
    pa = group(rep, "ship-300")["classes"]["py_analyze"]
    # criterion 2': the gain is over ALL warm calls (5, 7, 9, 15 s: median 8 s), as in E17b
    assert pa["warm"]["n"] == 4 and pa["warm"]["median_ms"] == 8000
    assert pa["gain"] == pytest.approx(1 - 8000 / 10000.0)
    wc = pa["warm_by_cache"]
    assert wc["after_drop"]["n"] == 2 and wc["after_drop"]["median_ms"] == 10000  # 5 s, 15 s
    assert wc["kept"]["n"] == 2 and wc["kept"]["median_ms"] == 8000  # 7 s, 9 s
    assert wc["ratio"] == pytest.approx(1.25)
    ps = group(rep, "ship-300")["classes"]["py_short"]["warm_by_cache"]
    assert ps["after_drop"]["n"] == 1 and ps["kept"]["n"] == 0 and ps["ratio"] is None  # an empty group: null
    # ship-300-nd (drop off) and sbx: no split, their classes keep E17b's exact shape
    for arm in ("ship-300-nd", "sbx"):
        assert not any("warm_by_cache" in c for c in group(rep, arm)["classes"].values())
    md = L.markdown(rep)
    assert "## Warm calls by the guest's page-cache drop" in md
    assert "| pycache | 1 | ship-300 | py_analyze | 2 | 10000 | 2 | 8000 | 1.25 |" in md
    assert "| pycache | 1 | ship-300 | py_short | 1 | 500 | 0 | - | - |" in md
    assert "ship-300-nd | py_analyze | 2 |" not in md


def test_no_tagged_rung_keeps_the_markdown_unchanged(tmp_path):
    from test_warmcold_lease import drop_rung
    rep = L.build([drop_rung(tmp_path, drop="off", arm="ship-300-nd"), sbx_rung(tmp_path)], baseline_arm="sbx")
    assert "page-cache drop" not in L.markdown(rep)
