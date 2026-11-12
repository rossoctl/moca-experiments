import datetime
import gzip
import json
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vm_age as V

MiB = 1 << 20
T0 = 1_800_000_000.0
HERE = os.path.dirname(os.path.abspath(__file__))
E15_RI = os.path.join(HERE, "..", "..", "e15", "results", "metal", "default", "resident-inf")


def stamp(t):
    return datetime.datetime.fromtimestamp(T0 + t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def rung(tmp_path, name, rows, events, gz=True):
    """rows: samples ({t, vm_mem}); events: [(t, "restore"|"destroy", "vm-N")] for worker.log."""
    d = tmp_path / name
    d.mkdir()
    body = "".join(json.dumps(dict(r, ts=T0 + r["t"])) + "\n" for r in rows)
    log = "microvm-worker: attached, serving execs\n" + "".join(
        "%s vmpool: %s phases id=%s total_us=1\n" % (stamp(t), kind, vm) for t, kind, vm in events)
    if gz:
        with gzip.open(d / "samples.jsonl.gz", "wt") as f:
            f.write(body)
        with gzip.open(d / "worker.log.gz", "wt") as f:
            f.write(log)
    else:
        (d / "samples.jsonl").write_text(body)
        (d / "worker.log").write_text(log)
    return str(d)


def linear(vms, t_end_s, step_s=60):
    """vms: {pool name: (base MiB, MiB per minute)}; one sample per step_s from t = 0."""
    rows = [{"t": -5.0, "vm_mem": {}}]
    for t in range(0, t_end_s + 1, step_s):
        rows.append({"t": float(t), "vm_mem": {k: int((b + g * t / 60) * MiB) for k, (b, g) in vms.items()}})
    return rows


def born_at_0(n):
    return [(0, "restore", "vm-%d" % (i + 1)) for i in range(n)]


def test_linear_bins_and_growth(tmp_path):
    # 3 VMs restored at t = 0 (pool-0..2), growing 1, 2, 3 MiB/min from 100 MiB, sampled each minute.
    d = rung(tmp_path, "r", linear({"pool-0": (100, 1), "pool-1": (100, 2), "pool-2": (100, 3)}, 65 * 60),
             born_at_0(3))
    r = V.analyse([d], min_vms=3)
    assert r["vms"] == 3 and r["births"] == 3
    assert r["bins_min"][:3] == [0, 5, 10]
    # bin 0 holds ages 0..4 min: each VM's median sample is at 2 min -> 102, 104, 106; median 104
    assert r["median_mib"][0] == pytest.approx(104.0)
    i20 = r["bins_min"].index(20)
    assert r["median_mib"][i20] == pytest.approx(144.0)   # 122, 144, 166
    assert r["p95_mib"][i20] == pytest.approx(166.0)      # nearest rank of 3
    # at 60 min (median at 62 min): 162, 224, 286 -> 224; growth 224/144 - 1
    assert r["growth_20_60_pct"] == pytest.approx(100 * (224 / 144 - 1))
    assert r["vms_20_60"] == 3
    assert r["growth_20_to"]["60"]["pct"] == pytest.approx(r["growth_20_60_pct"])
    # bin 50 (median at 52 min): 152, 204, 256 -> 204
    assert r["growth_20_to"]["50"] == {"pct": pytest.approx(100 * (204 / 144 - 1)), "vms": 3}


def test_growth_null_with_too_few_old_vms(tmp_path):
    d = rung(tmp_path, "r", linear({"pool-0": (100, 1), "pool-1": (100, 2), "pool-2": (100, 3)}, 65 * 60),
             born_at_0(3))
    r = V.analyse([d])  # default needs 20 VMs at both ages
    assert r["growth_20_60_pct"] is None and r["vms_20_60"] == 3
    d2 = rung(tmp_path, "r2", linear({"pool-%d" % i: (100, 1) for i in range(25)}, 50 * 60), born_at_0(25))
    r2 = V.analyse([d2])
    assert r2["vms"] == 25 and r2["growth_20_60_pct"] is None and r2["vms_20_60"] == 0


def test_reuse_without_a_memory_drop_is_a_new_vm(tmp_path):
    # I1: vm-1 on pool-0 is destroyed at 600 s and vm-2 restored into the same cgroup at once, at
    # 150 MiB against its predecessor's 200 (a 25% drop): the restore event makes it a new VM.
    rows = [{"t": float(t), "vm_mem": {"pool-0": (200 if t < 600 else 150) * MiB}} for t in range(0, 1201, 60)]
    ev = [(0, "restore", "vm-1"), (600, "destroy", "vm-1"), (600, "restore", "vm-2")]
    r = V.analyse([rung(tmp_path, "r", rows, ev)], min_vms=1)
    assert r["vms"] == 2 and r["births"] == 2
    assert r["median_mib"][0] == pytest.approx(175.0)          # both VMs' first 5 min
    assert r["median_mib"][r["bins_min"].index(5)] == pytest.approx(175.0)
    assert r["max_age_min"] == 10                               # vm-2 at age 10 min (t = 1200)


def test_memory_drop_without_a_restore_is_the_same_vm(tmp_path):
    rows = [{"t": float(t), "vm_mem": {"pool-0": (200 if t < 600 else 20) * MiB}} for t in range(0, 1201, 60)]
    r = V.analyse([rung(tmp_path, "r", rows, born_at_0(1))], min_vms=1)
    assert r["vms"] == 1 and r["max_age_min"] == 20


def test_free_list_is_lifo_like_moca(tmp_path):
    # vm-1 (pool-0) and vm-2 (pool-1) die, pool-0 released first, then pool-1; the next restore
    # pops pool-1 (last released), the one after pops pool-0.
    rows = [{"t": float(t), "vm_mem": {"pool-0": 100 * MiB, "pool-1": 300 * MiB}} for t in range(0, 1201, 60)]
    ev = born_at_0(2) + [(300, "destroy", "vm-1"), (301, "destroy", "vm-2"),
                         (600, "restore", "vm-3"), (900, "restore", "vm-4")]
    r = V.analyse([rung(tmp_path, "r", rows, ev)], min_vms=1)
    names = {v["id"]: v["name"] for v in V.vm_table(r["_raw"][0]["events"])}
    assert names == {"vm-1": "pool-0", "vm-2": "pool-1", "vm-3": "pool-1", "vm-4": "pool-0"}
    assert r["births"] == 4 and r["vms"] == 4


def test_samples_of_a_free_cgroup_are_unattributed(tmp_path):
    # pool-0 free between 300 and 600 s (destroyed, not yet reused): samples there belong to no VM.
    rows = [{"t": float(t), "vm_mem": {"pool-0": 100 * MiB}} for t in range(0, 901, 60)]
    ev = [(0, "restore", "vm-1"), (300, "destroy", "vm-1"), (600, "restore", "vm-2")]
    r = V.analyse([rung(tmp_path, "r", rows, ev)], min_vms=1)
    assert r["vms"] == 2
    assert r["per_rung"][0]["unattributed_samples"] == 4       # t = 360, 420, 480, 540
    assert r["per_rung"][0]["attributed_samples"] == 12


def test_no_worker_log_is_refused(tmp_path):
    d = tmp_path / "r"
    d.mkdir()
    (d / "samples.jsonl").write_text(json.dumps({"t": 0.0, "ts": T0, "vm_mem": {}}) + "\n")
    with pytest.raises(SystemExit, match="worker.log"):
        V.analyse([str(d)])
    (d / "worker.log").write_text("microvm-worker: attached\n")
    with pytest.raises(SystemExit, match="restore phases"):
        V.analyse([str(d)])


def test_rungs_pool_and_names_are_per_rung(tmp_path):
    a = rung(tmp_path, "a", linear({"pool-0": (100, 0)}, 600), born_at_0(1))
    b = rung(tmp_path, "b", linear({"pool-0": (300, 0)}, 600), born_at_0(1), gz=False)
    r = V.analyse([a, b], min_vms=1)
    assert r["vms"] == 2 and r["median_mib"][0] == pytest.approx(200.0)
    assert r["rungs"] == [a, b]


@pytest.mark.parametrize("rung_name, restores", [("N8", 19), ("N128-repeat", 475)])
def test_real_e15_rung_births_match_restores(rung_name, restores):
    """On committed E15 metal rungs: one VM per `restore phases` line, and (nearly) every pool
    sample attributed to a live VM."""
    d = os.path.join(E15_RI, rung_name)
    if not os.path.isdir(d):
        pytest.skip("E15 metal results not in this checkout")
    r = V.analyse([d], min_vms=1)
    pr = r["per_rung"][0]
    assert r["births"] == restores
    assert r["vms"] >= restores - 2           # a VM may die before its first sample
    assert pr["unattributed_samples"] <= 0.001 * pr["attributed_samples"]


def test_cli_writes_json_and_md(tmp_path):
    d = rung(tmp_path, "r", linear({"pool-0": (100, 1)}, 600), born_at_0(1))
    out = tmp_path / "out" / "vm"
    V.main([d, "--out", str(out)])
    j = json.loads((tmp_path / "out" / "vm.json").read_text())
    assert set(j) >= {"bins_min", "median_mib", "p95_mib", "growth_20_60_pct", "vms", "births"}
    assert "_raw" not in j
    assert j["growth_20_60_pct"] is None
    assert "growth_20_60_pct" in (tmp_path / "out" / "vm.md").read_text()


def test_decision_rule():
    assert V.decision(None).startswith("run")
    assert V.decision(10.5).startswith("run")
    assert V.decision(10.0).startswith("skip")
