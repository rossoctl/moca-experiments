import datetime
import json
import os
import sys

import pytest

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
    vms, problems, _ = L.vm_table_lease(ev, {"vm-1"})
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


def heavy_fixture(tmp_path, after_mib, delta_mib=0, next_send=None, name="rung", shmem_at=None,
                  start_mib=100, peak_mib=900, params=None):
    """A lease VM (pool-0, ages 0-90 s) with one py_analyze from t=10 to t=30: `start_mib` at its start,
    peak `peak_mib` (by default 100 and 900 MiB), then `after_mib` from t=31 on. shmem.json gives its
    dShmem (None: no shmem.json; "null": the key is there with null)."""
    log = [restore(0, "vm-1"), lstart(0, "A", "vm-1"), execl(30, "A", "vm-1")]

    def mem(t):
        if t < 10:
            return {"pool-0": start_mib * MIB}
        if t <= 30:
            return {"pool-0": min(peak_mib, start_mib + 80 * (t - 10)) * MIB}  # 900 MiB by t=20 by default
        return {"pool-0": after_mib * MIB}
    calls = [call("A", 1, "py_analyze", 10, 20000)]
    if shmem_at is not None:  # the turn's py_shmem reading, sent right after the heavy call
        log.append(execl(shmem_at, "A", "vm-1"))
        calls.append(call("A", 1.5, "py_shmem", shmem_at, 40, stdout="800\n"))
    if next_send is not None:
        log.append(execl(next_send + 1, "A", "vm-1"))
        calls.append(call("A", 2, "py_short", next_send, 500))
    d = rung(tmp_path, log, mem, calls, name=name, params=params)
    if delta_mib is not None:
        with open(os.path.join(d, "shmem.json"), "w") as f:
            json.dump({"calls": {"A:1": None if delta_mib == "null" else delta_mib * MIB}, "turns": {},
                       "unexpected_turns": {}, "tolerance_bytes": 1 << 20}, f)
    return d


def run_fpr(d):
    # what main() does: RUNDIR/shmem.json when it exists
    p = os.path.join(d, "shmem.json")
    r = L.analyse(d, shmem=json.load(open(p)) if os.path.exists(p) else None)
    assert r["mapping_valid"], r["mapping_reasons"]
    return r["fpr"]


def test_memory_falls_back_after_heavy_exec(tmp_path):
    f = run_fpr(heavy_fixture(tmp_path, after_mib=300))
    e = f["execs"][0]
    assert e["end_bytes"] == 900 * MIB and e["after_15s_bytes"] == 300 * MIB and e["peak_bytes"] == 900 * MIB
    assert e["start_bytes"] == 100 * MIB and e["delta_shmem_bytes"] == 0
    assert e["freed_bytes"] == 800 * MIB  # max(0, 900 - 100 - 0)
    assert e["follows"] is True  # 300 <= 900 - 800/2
    assert f["follows_true"] == 1 and f["follows_false"] == 0
    assert f["definition"] == "freed = max(0, peak - start - dShmem); follows: value_15s <= peak - freed/2"


def test_memory_pinned_after_heavy_exec_is_false(tmp_path):
    e = run_fpr(heavy_fixture(tmp_path, after_mib=880))["execs"][0]
    assert e["follows"] is False  # 880 > 500


def test_tmpfs_growth_is_not_counted_as_freed(tmp_path):
    # 600 MiB of the growth went to guest tmpfs: freed 200 MiB, so 700 MiB 15 s later still follows.
    e = run_fpr(heavy_fixture(tmp_path, after_mib=700, delta_mib=600))["execs"][0]
    assert e["freed_bytes"] == 200 * MIB and e["follows"] is True  # 700 <= 900 - 100
    e = run_fpr(heavy_fixture(tmp_path, after_mib=700, name="no-tmpfs"))["execs"][0]
    assert e["follows"] is False  # without the tmpfs growth: 700 > 500
    # more tmpfs than growth: freed is 0, never negative
    e = run_fpr(heavy_fixture(tmp_path, after_mib=880, delta_mib=2000, name="big-tmpfs"))["execs"][0]
    assert e["freed_bytes"] == 0 and e["follows"] is True


@pytest.mark.parametrize("delta", [None, "null"])
def test_fpr_without_delta_shmem_is_null_not_false(tmp_path, delta):
    e = run_fpr(heavy_fixture(tmp_path, after_mib=300, delta_mib=delta))["execs"][0]
    assert e["follows"] is None and e["freed_bytes"] is None and "dShmem" in e["why_null"]
    assert (e["end_bytes"], e["after_15s_bytes"], e["peak_bytes"]) == (900 * MIB, 300 * MIB, 900 * MIB)


def test_main_reads_shmem_json_not_freed_json(tmp_path):
    d = heavy_fixture(tmp_path, after_mib=300)
    with open(os.path.join(d, "freed.json"), "w") as f:
        json.dump({"A:1": 10 * MIB}, f)  # nothing writes it any more: ignored
    r = L.main([d])
    assert r["fpr"]["execs"][0]["freed_bytes"] == 800 * MIB
    os.remove(os.path.join(d, "shmem.json"))
    assert L.main([d])["fpr"]["execs"][0]["follows"] is None


def test_fpr_null_when_next_call_within_15s(tmp_path):
    e = run_fpr(heavy_fixture(tmp_path, after_mib=300, next_send=40))["execs"][0]
    assert e["follows"] is None and "next call" in e["why_null"]


def test_py_shmem_right_after_does_not_void_the_verdict(tmp_path):
    # The turn's py_shmem follows the closing py_analyze at +0 s; the next real call is at +40 s. The
    # reading is reported only (warmcold_lease.REPORTED_ONLY): it is not "the session's next call".
    e = run_fpr(heavy_fixture(tmp_path, after_mib=300, shmem_at=30, next_send=70))["execs"][0]
    assert e["follows"] is True and e["why_null"] is None
    # a real call within 15 s still voids it, with the reading in between
    e = run_fpr(heavy_fixture(tmp_path, after_mib=300, shmem_at=30, next_send=40, name="near"))["execs"][0]
    assert e["follows"] is None and "next call" in e["why_null"]


# ---- E17B-R29: criterion 5's first half is never vacuous ----

def test_vm_pinned_at_its_ceiling_is_not_judged_and_reads_pinned(tmp_path):
    # E17a's failure mode: free-page reporting returns nothing, the VM sits near its 1024 MiB ceiling
    # from an earlier heavy call. start 1000, peak 1010, +15 s 1005: no growth to return, so the
    # relative verdict (1005 <= 1010 - 5) would be a vacuous pass. It is not judged; the absolute
    # reading shows the VM pinned.
    f = run_fpr(heavy_fixture(tmp_path, after_mib=1005, start_mib=1000, peak_mib=1010))
    e = f["execs"][0]
    assert e["follows"] is None and e["why_null"] == "not_judged_low_growth"
    assert e["growth_bytes"] == 10 * MIB
    assert e["ceiling_ratio_15s"] == pytest.approx(1005 / 1024.0)
    assert f["not_judged_low_growth"] == 1 and f["follows_true"] == 0 and f["share_true"] is None
    assert f["growth_min_bytes"] == 64 * MIB == L.GROWTH_MIN_BYTES
    a = f["absolute"]
    assert a["guest_ram_bytes"] == 1024 * MIB and a["pinned_fraction"] == 0.9
    assert a["readings"] == 1 and a["pinned"] == 1 and a["pinned_share"] == 1.0
    assert a["per_vm"] == [{"vm": "vm-1", "readings": 1, "max_ceiling_ratio_15s": pytest.approx(1005 / 1024.0),
                            "pinned": True}]
    assert a["pinned_vms"] == 1 and a["pinned_vm_share"] == 1.0
    assert a["judged_readings"] == 0 and a["pinned_share_of_judged"] is None


def test_growth_of_300_mib_that_falls_back_is_judged_true(tmp_path):
    f = run_fpr(heavy_fixture(tmp_path, after_mib=120, start_mib=100, peak_mib=400))
    e = f["execs"][0]
    assert e["growth_bytes"] == 300 * MIB and e["follows"] is True  # 120 <= 400 - 300/2
    assert f["share_true"] == 1.0 and f["not_judged_low_growth"] == 0
    a = f["absolute"]
    assert a["pinned"] == 0 and a["pinned_share"] == 0.0 and a["judged_readings"] == 1
    assert a["pinned_share_of_judged"] == 0.0 and e["ceiling_ratio_15s"] == pytest.approx(120 / 1024.0)


def test_growth_that_stays_is_judged_false(tmp_path):
    f = run_fpr(heavy_fixture(tmp_path, after_mib=390, start_mib=100, peak_mib=400))
    assert f["execs"][0]["follows"] is False and f["share_true"] == 0.0  # 390 > 250


def test_growth_threshold_boundary(tmp_path):
    # exactly 64 MiB of growth is judged; 63 MiB is not
    e = run_fpr(heavy_fixture(tmp_path, after_mib=100, start_mib=100, peak_mib=164, name="at"))["execs"][0]
    assert e["growth_bytes"] == 64 * MIB and e["follows"] is True
    e = run_fpr(heavy_fixture(tmp_path, after_mib=100, start_mib=100, peak_mib=163, name="below"))["execs"][0]
    assert e["follows"] is None and e["why_null"] == "not_judged_low_growth"


def test_absolute_reading_uses_the_vms_guest_ram(tmp_path):
    # a 256 MiB rung: the ceiling is the snapshot's guest RAM (params snapshot_guest_ram_mb)
    f = run_fpr(heavy_fixture(tmp_path, after_mib=240, start_mib=230, peak_mib=250,
                              params={"arm": "ship-300", "snapshot_guest_ram_mb": 256}))
    a = f["absolute"]
    assert a["guest_ram_bytes"] == 256 * MIB and a["pinned"] == 1
    assert f["execs"][0]["ceiling_ratio_15s"] == pytest.approx(240 / 256.0)


def test_absolute_reading_skips_a_call_whose_next_call_began_within_15s(tmp_path):
    # its +15 s value is the next call's charge, not this one's: no absolute reading either
    f = run_fpr(heavy_fixture(tmp_path, after_mib=1005, start_mib=1000, peak_mib=1010, next_send=40))
    assert f["execs"][0]["ceiling_ratio_15s"] is None and f["absolute"]["readings"] == 0
    assert f["absolute"]["pinned_share"] is None


def test_absolute_reading_does_not_need_dshmem(tmp_path):
    # a lease's first turn (dShmem null, R24) has no relative verdict but still has the absolute reading
    f = run_fpr(heavy_fixture(tmp_path, after_mib=1005, start_mib=1000, peak_mib=1010, delta_mib="null"))
    assert f["execs"][0]["follows"] is None and f["absolute"]["readings"] == 1 and f["absolute"]["pinned"] == 1


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


# ---- fix round 1 -------------------------------------------------------------------------------

def normalise_failed(t, key, vm):
    return ('%s vmpool: lease normalise workspace_key="%s" vm=%s: exit 1; the lease start fails, '
            'root_wrote stays set\n' % (stamp(T0 + t), key, vm))


def cgroup_line(t, key, vm, err):
    return ('%s vmpool: lease cgroup workspace_key="%s" vm=%s: %s; the VM keeps the per-Exec memory bound\n'
            % (stamp(T0 + t), key, vm, err))


def names_of(r):
    return {v["id"]: v["cgroup"] for v in r["vms"]}


def test_failed_normalise_retires_without_start_line(tmp_path):
    # vm-1 was promoted (LeaseCgroup ran), its normalise failed, it was destroyed: no `lease start` line.
    # Its cgroup is retired, so vm-2 gets pool-1, not the recycled pool-0, and vm-3 gets pool-2.
    log = [restore(0, "vm-1"), normalise_failed(5, "A", "vm-1"), destroy(6, "vm-1"),
           restore(10, "vm-2"), restore(11, "vm-3")]

    def mem(t):
        m = {}
        if t < 6:
            m["pool-0"] = 100 * MIB
        if t >= 10:
            m["pool-1"] = 100 * MIB
        if t >= 11:
            m["pool-2"] = 100 * MIB
        return m
    r = L.analyse(rung(tmp_path, log, mem, t_end=40))
    assert r["mapping_valid"], r["mapping_reasons"]
    assert names_of(r) == {"vm-1": "pool-0", "vm-2": "pool-1", "vm-3": "pool-2"}
    assert r["lease_vms"] == 0  # a failed start is not a lease VM: no memory statistics for it


def test_lease_cgroup_write_failure_still_retires(tmp_path):
    # LeaseCgroup marks the VM BEFORE the memory.max write (launcher_firecracker.go), so a write
    # failure ("keeps the per-Exec memory bound") still retires the cgroup.
    ev = [("restore", "vm-1"), ("destroy", "vm-1"), ("restore", "vm-2")]
    vms, _, _ = L.vm_table_lease(ev, {"vm-1"}, started=set())
    assert {v["id"]: v["name"] for v in vms} == {"vm-1": "pool-0", "vm-2": "pool-1"}
    d = rung(tmp_path, [restore(0, "vm-1"), cgroup_line(1, "A", "vm-1", "write memory.max: permission denied"),
                        destroy(6, "vm-1"), restore(10, "vm-2")],
             lambda t: {"pool-0": 1} if t < 6 else ({"pool-1": 1} if t >= 10 else {}), t_end=30)
    assert names_of(L.analyse(d))["vm-2"] == "pool-1"


def test_lease_cgroup_without_pooled_cgroup_is_not_promoted(tmp_path):
    # LeaseCgroup returns before marking when the VM has no pooled cgroup: the name recycles normally.
    err = "firecracker VM vm-1: no pooled cgroup to lease (ParentCgroup unset?)"
    log = [restore(0, "vm-1"), cgroup_line(1, "A", "vm-1", err), lstart(2, "A", "vm-1"), destroy(6, "vm-1"),
           restore(10, "vm-2")]
    r = L.analyse(rung(tmp_path, log, lambda t: {"pool-0": 1} if (t < 6 or t >= 10) else {}, t_end=30))
    assert r["mapping_valid"], r["mapping_reasons"]
    assert names_of(r) == {"vm-1": "pool-0", "vm-2": "pool-0"}


def test_unmarked_promotion_is_suspected_only_when_samples_disagree(tmp_path):
    # A Resume failure promotes the cgroup (retired) but logs nothing: the replay recycles pool-0
    # for vm-2 while the samples show vm-2 in pool-1.
    log = [restore(0, "vm-1"), destroy(6, "vm-1"), restore(10, "vm-2")]
    r = L.analyse(rung(tmp_path, log, lambda t: {"pool-0": 1} if t < 6 else ({"pool-1": 1} if t >= 10 else {}),
                       t_end=30))
    assert r["mapping_valid"] is False
    assert any("lease_start_failed_without_marker_suspected" in x for x in r["mapping_reasons"])
    assert r["vms"] is None
    # no recycle happened -> the reason is not offered
    log = [restore(0, "vm-1"), restore(1, "vm-2")]
    r = L.analyse(rung(tmp_path, log, lambda t: {"pool-0": 1, "pool-1": 1, "pool-7": 1}, t_end=30, name="r2"))
    assert r["mapping_valid"] is False
    assert not any("suspected" in x for x in r["mapping_reasons"])


def test_runs_fast_on_1500_vms(tmp_path):
    import time
    log, events, lease_ids = [], [], set()
    for i in range(1500):
        vm = "vm-%d" % i
        log.append(restore(i * 2, vm))
        if i % 2:
            log.append(lstart(i * 2, "k%d" % i, vm))
        log.append(destroy(i * 2 + 30, vm))
    log.sort(key=lambda s: s[:20])  # stable: restore before its destroy
    for line in log:
        if "restore phases" in line:
            events.append(("restore", line.split("id=")[1].split()[0]))
        elif "destroy phases" in line:
            events.append(("destroy", line.split("id=")[1].split()[0]))
        elif "lease start" in line:
            lease_ids.add(line.split("vm=")[1].split()[0])
    vms, _, _ = L.vm_table_lease(events, lease_ids)
    name = {v["id"]: v["name"] for v in vms}

    d = rung(tmp_path, log, lambda t: {}, t_end=0)
    with open(os.path.join(d, "samples.jsonl"), "w") as f:
        for t in range(0, 3030):
            live = {name["vm-%d" % i]: 10 * MIB for i in range(max(0, (t - 30) // 2), min(1500, t // 2 + 1))
                    if i * 2 <= t < i * 2 + 30}
            f.write(json.dumps({"ts": T0 + t + 0.3, "vm_mem": live}) + "\n")
    t0 = time.time()
    r = L.analyse(d)
    assert time.time() - t0 < 10
    assert r["mapping_valid"], r["mapping_reasons"][:3]
    assert r["lease_vms"] == 750


def test_in_window_is_honoured_on_both_sides(tmp_path):
    log = [restore(0, "vm-1"), lstart(0, "A", "vm-1"), execl(5, "A", "vm-1"),
           lend(60, "A", "vm-1", "idle"), destroy(60, "vm-1"), restore(70, "vm-2"), lstart(70, "A", "vm-2"),
           execl(72, "A", "vm-2"), execl(75, "A", "vm-2")]
    calls = [call("A", 1, "py_short", 4.5, 500), call("A", 2, "py_short", 71.5, 500),
             call("A", 3, "py_grep", 74.5, 500, in_window=False)]
    d = rung(tmp_path, log, lambda t: {"pool-0": 1} if t < 60 else ({"pool-1": 1} if t >= 70 else {}),
             calls, t_end=100)
    r = L.analyse(d, sbx_median_ms=400.0)
    assert r["replacement"]["replacement_leases"] == 1
    assert r["replacement"]["leases"][0]["first_grep_ms"] is None  # the only py_grep is out of window
    # sbx baseline: out-of-window py_grep calls are not in the median
    s = tmp_path / "sbx"
    s.mkdir()
    (s / "calls.jsonl").write_text("".join(json.dumps(c) + "\n" for c in [
        call("A", 1, "py_grep", 0, 400), call("A", 2, "py_grep", 1, 9000, in_window=False)]))
    assert L.sbx_median_grep(str(s)) == 400


def test_age_text_and_freed_format_documented(tmp_path):
    d = heavy_fixture(tmp_path, after_mib=300)
    r = L.analyse(d)
    assert "not its promotion" in r["memory_vs_age"]["age"]
    assert '"session:call"' in L.__doc__ and "py_shmem" in L.__doc__ and "shmem.json" in L.__doc__
    assert "freed.json" not in L.__doc__ and "max(0, peak - start - dShmem)" in L.__doc__
    assert "lease_start_failed_without_marker_suspected" in L.__doc__


def test_replacement_reading_is_null_when_the_vms_first_call_is_unknown():
    # PR #34 nit (E17B-R41f): vm-2's first call could not be placed (unknown), so whether vm-2 replaced an idle
    # lease is not known: a null reading, not "not a replacement" taken from its later warm call.
    def r(call, vm, warm, reason, cls="py_grep", ms=100):
        return {"session": "A", "call": call, "vm": vm, "warm": warm, "cold_reason": reason, "class": cls,
                "status": "ok", "in_window": True, "observed_ms": ms}
    rows = [r(1, "vm-1", False, "first"), r(2, "vm-2", "unknown", "no-live-lease", ms=900),
            r(3, "vm-2", True, None, ms=800), r(4, "vm-3", False, "idle", ms=300)]
    rp = L.replacement_reading(rows, 100.0)
    assert rp["replacement_leases"] == 1 and [x["vm"] for x in rp["leases"]] == ["vm-3"]
    assert rp["replacement_unknown"] == 1 and rp["unknown_leases"][0]["vm"] == "vm-2"
    assert rp["unknown_leases"][0]["replacement"] is None
    assert rp["median_first_py_grep_ms"] == 300  # vm-2's py_grep is not a replacement reading

def test_imports_from_the_rig_staged_layout(tmp_path):
    """On the rig the experiments are staged as /srv/e15/src/{e15,e16,e17}: the script finds E16's vm_age there."""
    import shutil
    import subprocess
    repo = os.path.abspath(os.path.join(HERE, "..", ".."))
    src = tmp_path / "src"
    shutil.copytree(os.path.join(repo, "e15-session-density"), src / "e15", ignore=shutil.ignore_patterns("driver", "results"))
    shutil.copytree(os.path.join(repo, "e16-low-duty"), src / "e16", ignore=shutil.ignore_patterns("results"))
    shutil.copytree(os.path.join(repo, "e17-lease"), src / "e17", ignore=shutil.ignore_patterns("results"))
    out = subprocess.run([sys.executable, str(src / "e17" / "analysis" / "vm_age_lease.py"), "--help"],
                         capture_output=True, text=True, env={"PATH": os.environ.get("PATH", "")})
    assert out.returncode == 0, out.stderr


def test_same_second_restores_are_resolved_from_the_samples(tmp_path):
    # E17B-R53: vm-2 and vm-3 restore in the same second; vm-3's line is logged first, but the allocator gave
    # vm-2 pool-0 and vm-3 pool-1 (the samples). Log order alone puts vm-2 on pool-1 and leaves pool-1's samples
    # after vm-2's end with no live VM; the swap of the two same-second restores is consistent with every sample.
    log = [restore(1, "vm-3"), restore(1, "vm-2"), lstart(1, "B", "vm-3"), lstart(1, "A", "vm-2"),
           destroy(20, "vm-2"), destroy(40, "vm-3")]
    mem = lambda t: dict(([("pool-0", 50 * MIB)] if 1 <= t < 20 else []) + ([("pool-1", 70 * MIB)] if 1 <= t < 40 else []))
    r = L.analyse(rung(tmp_path, log, mem, t_end=60))
    assert r["mapping_valid"], r["mapping_reasons"]
    assert r["same_second_reorders"] == [{"vms": ["vm-3", "vm-2"], "at": float(T0 + 1)}]
    assert {v["id"]: v["cgroup"] for v in r["vms"]} == {"vm-2": "pool-0", "vm-3": "pool-1"}


def test_same_second_swap_that_does_not_explain_the_samples_stays_invalid(tmp_path):
    # the same two restores, but a sample in a cgroup no order explains (pool-7): nothing is accepted
    log = [restore(1, "vm-3"), restore(1, "vm-2"), lstart(1, "B", "vm-3"), lstart(1, "A", "vm-2"),
           destroy(20, "vm-2"), destroy(40, "vm-3")]
    mem = lambda t: dict(([("pool-0", 50 * MIB)] if 1 <= t < 20 else []) + ([("pool-1", 70 * MIB)] if 1 <= t < 40 else [])
                         + ([("pool-7", 1)] if t == 30 else []))
    r = L.analyse(rung(tmp_path, log, mem, t_end=60))
    assert r["mapping_valid"] is False and r["same_second_reorders"] == []
    assert r["vms"] is None
