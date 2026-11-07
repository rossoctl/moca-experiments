import gzip
import json
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vm_age as V

MiB = 1 << 20


def rung(tmp_path, name, rows, gz=True):
    d = tmp_path / name
    d.mkdir()
    body = "".join(json.dumps(r) + "\n" for r in rows)
    if gz:
        with gzip.open(d / "samples.jsonl.gz", "wt") as f:
            f.write(body)
    else:
        (d / "samples.jsonl").write_text(body)
    return str(d)


def linear(vms, t_end_s, step_s=60):
    """vms: {name: (base MiB, MiB per minute)}; one sample per step_s from t = 0."""
    rows = [{"t": -5.0, "vm_mem": {}}]
    for t in range(0, t_end_s + 1, step_s):
        rows.append({"t": float(t), "vm_mem": {k: int((b + g * t / 60) * MiB) for k, (b, g) in vms.items()}})
    return rows


def test_linear_bins_and_growth(tmp_path):
    # 3 VMs, first seen at t = 0, growing 1, 2, 3 MiB/min from 100 MiB, sampled each minute to 65 min.
    d = rung(tmp_path, "r", linear({"pool-0": (100, 1), "pool-1": (100, 2), "pool-2": (100, 3)}, 65 * 60))
    r = V.analyse([d], min_vms=3)
    assert r["vms"] == 3
    assert r["bins_min"][:3] == [0, 5, 10]
    # bin 0 holds ages 0..4 min: each VM's median sample is at 2 min -> 102, 104, 106; median 104
    assert r["median_mib"][0] == pytest.approx(104.0)
    # bin 20 (ages 20..24): medians at 22 min -> 122, 144, 166
    i20 = r["bins_min"].index(20)
    assert r["median_mib"][i20] == pytest.approx(144.0)
    assert r["p95_mib"][i20] == pytest.approx(166.0)  # nearest rank of 3
    # at 60 min (bin 60, median at 62 min): 162, 224, 286 -> median 224; growth 224/144 - 1
    assert r["growth_20_60_pct"] == pytest.approx(100 * (224 / 144 - 1))
    assert r["vms_20_60"] == 3


def test_growth_null_with_too_few_old_vms(tmp_path):
    d = rung(tmp_path, "r", linear({"pool-0": (100, 1), "pool-1": (100, 2), "pool-2": (100, 3)}, 65 * 60))
    r = V.analyse([d])  # default needs 20 VMs at both ages
    assert r["growth_20_60_pct"] is None and r["vms_20_60"] == 3
    # VMs that never reach 60 min of age: null too
    d2 = rung(tmp_path, "r2", linear({"pool-%d" % i: (100, 1) for i in range(25)}, 50 * 60))
    r2 = V.analyse([d2])
    assert r2["vms"] == 25 and r2["growth_20_60_pct"] is None and r2["vms_20_60"] == 0


def test_reused_name_after_memory_drop_is_a_new_vm(tmp_path):
    # pool-0 grows to 200 MiB, then drops to 20 MiB at t = 10 min (> 50% drop): a new VM, age 0.
    rows = [{"t": float(t), "vm_mem": {"pool-0": (200 if t < 600 else 20) * MiB}} for t in range(0, 1201, 60)]
    r = V.analyse([rung(tmp_path, "r", rows)], min_vms=1)
    assert r["vms"] == 2
    # bin 0 now holds both VMs' first 5 minutes: 200 and 20 -> median 110
    assert r["median_mib"][0] == pytest.approx(110.0)
    # bin 10 (ages 10..14) holds only the first VM, which ended at age 9 min: absent. The new VM is
    # at most 10 min old, so bins 10+ are empty except its age-10 sample (t = 1200).
    assert r["median_mib"][r["bins_min"].index(10)] == pytest.approx(20.0)


def test_a_drop_of_half_or_less_is_the_same_vm(tmp_path):
    rows = [{"t": float(t), "vm_mem": {"pool-0": (200 if t < 600 else 100) * MiB}} for t in range(0, 1201, 60)]
    assert V.analyse([rung(tmp_path, "r", rows)], min_vms=1)["vms"] == 1


def test_reused_name_after_absence_is_a_new_vm(tmp_path):
    # pool-0 absent for 120 s (> 60 s): a new VM even with the same memory
    rows = [{"t": float(t), "vm_mem": {} if 300 < t < 420 else {"pool-0": 100 * MiB}} for t in range(0, 901, 30)]
    r = V.analyse([rung(tmp_path, "r", rows)], min_vms=1)
    assert r["vms"] == 2
    # absent for 60 s exactly: the same VM
    rows = [{"t": float(t), "vm_mem": {} if t == 330 else {"pool-0": 100 * MiB}} for t in range(0, 901, 30)]
    assert V.analyse([rung(tmp_path, "r2", rows)], min_vms=1)["vms"] == 1


def test_rungs_pool_and_names_are_per_rung(tmp_path):
    a = rung(tmp_path, "a", linear({"pool-0": (100, 0)}, 600))
    b = rung(tmp_path, "b", linear({"pool-0": (300, 0)}, 600), gz=False)
    r = V.analyse([a, b], min_vms=1)
    assert r["vms"] == 2 and r["median_mib"][0] == pytest.approx(200.0)
    assert r["rungs"] == [a, b]


def test_cli_writes_json_and_md(tmp_path):
    d = rung(tmp_path, "r", linear({"pool-0": (100, 1)}, 600))
    out = tmp_path / "out" / "vm"
    V.main([d, "--out", str(out)])
    j = json.loads((tmp_path / "out" / "vm.json").read_text())
    assert set(j) >= {"bins_min", "median_mib", "p95_mib", "growth_20_60_pct", "vms"}
    assert j["growth_20_60_pct"] is None
    assert "growth_20_60_pct" in (tmp_path / "out" / "vm.md").read_text()
