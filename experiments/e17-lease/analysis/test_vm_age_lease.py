import datetime
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "e16-low-duty", "analysis"))

import vm_age as V  # noqa: E402
import vm_age_lease as L  # noqa: E402

T0 = 1793877000
MIB = 1 << 20


def stamp(t):
    return datetime.datetime.fromtimestamp(int(t), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def restore(t, vm):
    return "%s vmpool: restore phases id=%s prep_us=1 total_us=2\n" % (stamp(T0 + t), vm)


def destroy(t, vm):
    return "%s vmpool: destroy phases id=%s kill_us=1 total_us=2\n" % (stamp(T0 + t), vm)


def lstart(t, key, vm):
    return '%s vmpool: lease start workspace_key="%s" vm=%s mode=lease\n' % (stamp(T0 + t), key, vm)


def lend(t, key, vm, reason="idle"):
    return '%s vmpool: lease end workspace_key="%s" vm=%s mode=lease reason=%s age=5s\n' % (
        stamp(T0 + t), key, vm, reason)


def execl(t, key, vm):
    return '%s vmpool: exec req=1 workspace_key="%s" kind=command vm=%s cold="" exit=0 err=<nil>\n' % (
        stamp(T0 + t), key, vm)


def call(key, i, cls, send, ms, **kw):
    ts = datetime.datetime.fromtimestamp(T0 + send, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000000Z")
    return dict({"ts": ts, "session": key, "call": i, "class": cls, "execs": 1, "observed_ms": ms,
                 "status": "ok", "in_window": True}, **kw)


def rung(tmp_path, log, mem, calls=(), t_end=120, name="rung", params=None):
    """mem(t) -> {cgroup: bytes} sampled at 1 Hz for t in 0..t_end."""
    d = tmp_path / name
    d.mkdir()
    (d / "worker.log").write_text("microvm-worker: attached, serving execs\n" + "".join(log))
    (d / "calls.jsonl").write_text("".join(json.dumps(c) + "\n" for c in calls))
    with open(d / "samples.jsonl", "w") as f:
        for t in range(t_end + 1):
            f.write(json.dumps({"ts": T0 + t + 0.3, "vm_mem": mem(t)}) + "\n")
    if params is not None:
        (d / "params.json").write_text(json.dumps(params))
    return str(d)


def test_retired_cgroups_not_reused():
    # vm-1 is a lease (pool-0, retired at destroy); vm-3 is a per-Exec VM (pool-1, recycled).
    ev = [("restore", "vm-1"), ("restore", "vm-3"), ("destroy", "vm-3"), ("destroy", "vm-1"),
          ("restore", "vm-4"), ("restore", "vm-5")]
    vms, problems = L.vm_table_lease(ev, {"vm-1"})
    names = {v["id"]: v["name"] for v in vms}
    assert problems == []
    assert names == {"vm-1": "pool-0", "vm-3": "pool-1", "vm-4": "pool-1", "vm-5": "pool-2"}
    naive = {v["id"]: v["name"] for v in V.vm_table([(float(i), k, v) for i, (k, v) in enumerate(ev)])}
    assert naive["vm-4"] == "pool-0" and naive != names  # the LIFO replay hands the retired name to vm-4


def test_retired_cgroups_end_to_end(tmp_path):
    log = [restore(0, "vm-1"), lstart(0, "A", "vm-1"), restore(1, "vm-3"), destroy(10, "vm-3"),
           destroy(30, "vm-1"), restore(31, "vm-4"), restore(32, "vm-5")]

    def mem(t):
        m = {}
        if t < 30:
            m["pool-0"] = 500 * MIB
        if 1 <= t < 10:
            m["pool-1"] = 100 * MIB
        if t >= 31:
            m["pool-1"] = 120 * MIB
        if t >= 32:
            m["pool-2"] = 130 * MIB
        return m
    r = L.analyse(rung(tmp_path, log, mem, t_end=60))
    assert r["mapping_valid"], r["mapping_reasons"]
    assert {v["id"]: v["cgroup"] for v in r["vms"]} == {"vm-1": "pool-0", "vm-3": "pool-1", "vm-4": "pool-1",
                                                        "vm-5": "pool-2"}


def heavy_fixture(tmp_path, after_mib, freed=True, next_send=None):
    """A lease VM (pool-0, ages 0-90 s) with one py_analyze from t=10 to t=30: peak 900 MiB, then
    `after_mib` from t=31 on."""
    log = [restore(0, "vm-1"), lstart(0, "A", "vm-1"), execl(30, "A", "vm-1")]

    def mem(t):
        if t < 10:
            return {"pool-0": 100 * MIB}
        if t <= 30:
            return {"pool-0": min(900, 100 + 80 * (t - 10)) * MIB}  # up to 900 MiB by t=20
        return {"pool-0": after_mib * MIB}
    calls = [call("A", 1, "py_analyze", 10, 20000)]
    if next_send is not None:
        log.append(execl(next_send + 1, "A", "vm-1"))
        calls.append(call("A", 2, "py_short", next_send, 500))
    d = rung(tmp_path, log, mem, calls)
    if freed:
        with open(os.path.join(d, "freed.json"), "w") as f:
            json.dump({"A:1": 500 * MIB}, f)
    return d


def run_fpr(d):
    freed = json.load(open(os.path.join(d, "freed.json"))) if os.path.exists(os.path.join(d, "freed.json")) else None
    r = L.analyse(d, freed=freed)
    assert r["mapping_valid"], r["mapping_reasons"]
    return r["fpr"]


def test_memory_falls_back_after_heavy_exec(tmp_path):
    f = run_fpr(heavy_fixture(tmp_path, after_mib=300))
    e = f["execs"][0]
    assert e["end_bytes"] == 900 * MIB and e["after_15s_bytes"] == 300 * MIB and e["peak_bytes"] == 900 * MIB
    assert e["follows"] is True  # 300 <= 900 - 500/2
    assert f["follows_true"] == 1 and f["follows_false"] == 0


def test_memory_pinned_after_heavy_exec_is_false(tmp_path):
    e = run_fpr(heavy_fixture(tmp_path, after_mib=880, freed=True, ))["execs"][0]
    assert e["follows"] is False  # 880 > 650


def test_fpr_without_freed_is_null_not_false(tmp_path):
    d = tmp_path / "nofreed"
    d.mkdir()
    e = run_fpr(heavy_fixture(d, after_mib=300, freed=False))["execs"][0]
    assert e["follows"] is None and "freed" in e["why_null"]
    assert (e["end_bytes"], e["after_15s_bytes"], e["peak_bytes"]) == (900 * MIB, 300 * MIB, 900 * MIB)


def test_fpr_null_when_next_call_within_15s(tmp_path):
    e = run_fpr(heavy_fixture(tmp_path, after_mib=300, next_send=40))["execs"][0]
    assert e["follows"] is None and "next call" in e["why_null"]


def test_share_above_thresholds(tmp_path):
    peaks = [100, 600, 950, 1000]  # of 1024 MiB: above 512 -> 3, above 921.6 -> 2
    log = []
    for i in range(4):
        log += [restore(0, "vm-%d" % i), lstart(0, "k%d" % i, "vm-%d" % i)]
    r = L.analyse(rung(tmp_path, log, lambda t: {"pool-%d" % i: p * MIB for i, p in enumerate(peaks)},
                       t_end=20, params={"arm": "ship-300"}), guest_ram_mib=1024)
    assert r["mapping_valid"], r["mapping_reasons"]
    s = r["share_above"]
    assert s["lease_vms"] == 4
    assert s["above_50_pct"] == {"vms": 3, "share": 0.75}
    assert s["above_90_pct"] == {"vms": 2, "share": 0.5}
    assert r["arm"] == "ship-300"
    assert r["memory_vs_age"]["median_mib"][0] == 775.0  # median of 100, 600, 950, 1000


def test_replacement_vm_first_grep(tmp_path):
    log = [restore(0, "vm-1"), lstart(0, "A", "vm-1"), execl(5, "A", "vm-1"), execl(8, "A", "vm-1"),
           lend(60, "A", "vm-1", "idle"),
           destroy(60, "vm-1"), restore(70, "vm-2"), lstart(70, "A", "vm-2"), execl(72, "A", "vm-2"),
           execl(75, "A", "vm-2"), execl(78, "A", "vm-2")]
    calls = [call("A", 1, "py_short", 4.5, 500), call("A", 2, "py_grep", 7.5, 300),
             call("A", 3, "py_short", 71.5, 500), call("A", 4, "py_grep", 74.5, 800),
             call("A", 5, "py_grep", 77.5, 100)]

    def mem(t):
        m = {}
        if t < 60:
            m["pool-0"] = 200 * MIB
        if t >= 70:
            m["pool-1"] = 200 * MIB
        return m
    r = L.analyse(rung(tmp_path, log, mem, calls, t_end=100), sbx_median_ms=400.0)
    assert r["mapping_valid"], r["mapping_reasons"]
    rp = r["replacement"]
    assert rp["replacement_leases"] == 1 and rp["leases"][0]["vm"] == "vm-2"
    assert rp["median_first_py_grep_ms"] == 800  # the first py_grep of the replacement lease, not call 5
    assert rp["ratio_to_sbx"] == 2.0


def test_ambiguous_mapping_is_reported_not_guessed(tmp_path):
    log = [restore(0, "vm-1"), lstart(0, "A", "vm-1"), restore(1, "vm-1"), lstart(0, "B", "vm-7"),
           destroy(40, "vm-9")]
    r = L.analyse(rung(tmp_path, log, lambda t: {"pool-0": 100 * MIB, "pool-9": 5 * MIB}, t_end=50))
    assert r["mapping_valid"] is False
    joined = " ".join(r["mapping_reasons"])
    assert "vm-1 restored twice" in joined and "vm-9 destroyed" in joined and "vm-7" in joined
    assert "pool-9" in joined  # a sampled cgroup holding no live VM
    assert r["vms"] is None and r["memory_vs_age"] is None and r["share_above"] is None and r["fpr"] is None


def test_replay_disagreeing_with_samples_is_invalid(tmp_path):
    # vm-2 is replayed onto pool-0 (vm-1 was a per-Exec VM, so its name recycled) but the samples
    # show it in pool-1: the replay does not match the sampled cgroups.
    log = [restore(0, "vm-1"), destroy(10, "vm-1"), restore(11, "vm-2")]
    r = L.analyse(rung(tmp_path, log, lambda t: {"pool-0": 1} if t < 10 else {"pool-1": 1}, t_end=40))
    assert r["mapping_valid"] is False and any("pool-1" in x for x in r["mapping_reasons"])


def test_no_phase_lines_is_invalid(tmp_path):
    r = L.analyse(rung(tmp_path, [], lambda t: {}, t_end=3))
    assert r["mapping_valid"] is False and "SH_DIAG_PHASES" in r["mapping_reasons"][0]


def test_main_writes_json(tmp_path):
    d = heavy_fixture(tmp_path, after_mib=300)
    L.main([d])
    out = json.load(open(os.path.join(d, "vm_age_lease.json")))
    assert out["mapping_valid"] is True and out["fpr"]["execs"][0]["follows"] is True
