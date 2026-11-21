"""ownwalk_phases.py (PLAN-E17B Task 11 fix round 1): what the worker log shows of each ownwalk repeat.

The fixture lines use the worker's own formats (moca remote-worker internal/vmpool): runner.go:74 (the per-Exec
audit line), diag.go:53 (the SH_DIAG_PHASES=1 phase line, printed just before it) and lease.go:599 (a lease start).
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import ownwalk_phases as P  # noqa: E402

SCRIPT = os.path.join(HERE, "ownwalk_phases.py")
TS = "2026/11/16 10:00:00 "


def phases(acq, res, run, dest=0, cold="restore", normalise=None):
    # normalise=None: the worker at E17b's pin (no normalise_us); else moca #966's line, normalise_us after mount_us
    extra = "" if normalise is None else " normalise_us=%d" % normalise
    return (TS + "vmpool: exec phases acquire_us=%d resume_us=%d vmresume_us=1 vsockdial_us=2 mount_us=3%s run_us=%d "
            'destroy_us=%d cold="%s"' % (acq, res, extra, run, dest, cold))


def exec_line(key, vm, req=7):
    return TS + 'vmpool: exec req=%d workspace_key="%s" kind=command vm=%s cold="restore" exit=0 err=<nil>' % (req, key, vm)


def lease_start(key, vm):
    return TS + 'vmpool: lease start workspace_key="%s" vm=%s mode=lease' % (key, vm)


def repeat_lines(key, a_norm=None, b_norm=None, b_new_vm=True):
    vm_a, vm_b = key + "-va", (key + "-vb" if b_new_vm else key + "-va")
    out = [phases(100000, 20000, 2000000), exec_line(key, key + "-vp")]  # the per-exec build
    out += [lease_start(key, vm_a), phases(110000, 30000, 4000, normalise=a_norm), exec_line(key, vm_a)]  # A
    out += ["%svmpool: lease end workspace_key=\"%s\" vm=%s mode=lease reason=reset age=1s" % (TS, key, vm_a)]
    if b_new_vm:
        out.append(lease_start(key, vm_b))
    out += [phases(90000, 25000, 4500, normalise=b_norm), exec_line(key, vm_b)]  # B
    return out


def rundir(tmp_path, keys, lines, walk=(400.0,)):
    d = tmp_path / "F10000"
    d.mkdir()
    runs = []
    for i, k in enumerate(keys):
        w = walk[i % len(walk)]
        runs.append({"rep": i, "key": k, "a_ms": 500.0 + w - 400.0, "b_ms": 100.0, "walk_ms": w, "valid": True,
                     "invalid_reasons": []})
    rep = {"files": 10000, "repeats": len(keys), "runs": runs, "valid": True, "invalid_reasons": [],
           "median_a_ms": 500.0, "median_b_ms": 100.0, "median_walk_ms": 400.0}
    (d / "ownwalk.json").write_text(json.dumps(rep))
    (d / "worker.log").write_text("\n".join(lines) + "\n")
    return d


def test_this_pins_worker_logs_no_normalise_phase(tmp_path):
    keys = ["ow-%d" % i for i in range(5)]
    d = rundir(tmp_path, keys, sum((repeat_lines(k) for k in keys), []))
    r = P.annotate(str(d))
    run = r["runs"][0]
    assert run["walk_observed"]["A"] is None and run["walk_observed"]["B"] is None
    assert "no normalise_us" in run["walk_observed"]["reason"]
    assert run["valid"] is True and r["valid"] is True and r["median_walk_ms"] == 400.0
    # B started its own lease in a new VM: the observed half of "B is cold"
    assert run["lease_starts"] == ["ow-0-va", "ow-0-vb"]
    # the phases of A and B, and the part of A - B no logged phase accounts for
    assert run["worker_phases"]["a"]["resume_us"] == 30000 and run["worker_phases"]["b"]["run_us"] == 4500
    # A's phases 110000+30000+4000 = 144000 us, B's 90000+25000+4500 = 119500 us: 24.5 ms of A - B is in the phases
    assert run["phase_corrected_walk_ms"] == 375.5
    assert r["phase_corrected_walk_median_ms"] == 375.5
    assert r["walk_observed_median_ms"] is None
    # no normalise_us anywhere: none of the observed-walk keys is written (E17b's ownwalk.json is unchanged)
    assert not [k for k in r if k.startswith("normalise_us")]


def test_an_observed_normalise_phase_is_reported_and_checked(tmp_path):
    keys = ["ow-0", "ow-1", "ow-2"]
    lines = repeat_lines("ow-0", 380000, 0) + repeat_lines("ow-1", 390000, 0) + repeat_lines("ow-2", 0, 0)
    d = rundir(tmp_path, keys, lines)
    r = P.annotate(str(d))
    wo = [x["walk_observed"] for x in r["runs"]]
    assert [w["A"] for w in wo] == [True, True, False] and [w["B"] for w in wo] == [False, False, False]
    assert wo[0]["a_normalise_ms"] == 380.0 and wo[0]["b_normalise_ms"] == 0.0
    # repeat 2: A did not walk -> invalid, and the report's medians are withheld
    assert r["runs"][2]["valid"] is False and "A did not walk" in "; ".join(r["runs"][2]["invalid_reasons"])
    assert r["valid"] is False and r["median_walk_ms"] is None and r["walk_observed_median_ms"] is None
    # the observed walk's median is withheld with the others; B's maximum stays, it is what B did
    assert r["normalise_us_median_a"] is None and r["normalise_us_b_max"] == 0


def test_the_walk_from_the_workers_own_phase(tmp_path):
    # moca #966: normalise_us on the phase line, the lease start's ownership walk; 0 on B (a reset, known clean)
    keys = ["ow-0", "ow-1", "ow-2"]
    lines = repeat_lines("ow-0", 380000, 0) + repeat_lines("ow-1", 400000, 0) + repeat_lines("ow-2", 390000, 0)
    d = rundir(tmp_path, keys, lines)
    r = P.annotate(str(d))
    assert r["valid"] is True
    assert r["normalise_us_median_a"] == 390000 and r["normalise_us_b_max"] == 0
    assert r["walk_observed_median_ms"] == 390.0
    # the A - B inference stays beside it
    assert r["median_walk_ms"] == 400.0 and r["phase_corrected_walk_median_ms"] == 375.5
    assert all(x["walk_observed"]["reason"] is None for x in r["runs"])
    p = subprocess.run([sys.executable, SCRIPT, str(d)], capture_output=True, text=True)
    assert p.returncode == 0, p.stderr
    assert "no normalise_us" not in p.stdout
    j = json.loads((d / "ownwalk.json").read_text())
    assert j["normalise_us_median_a"] == 390000 and j["normalise_us_b_max"] == 0


def test_e17b_shaped_output_is_byte_identical(tmp_path):
    # testdata/ownwalk-e17b-shaped: E17b's F10000 driver output and a worker.log in its pin's formats (no
    # normalise_us); expected.json and expected.stdout are what this script wrote before moca #966's field existed
    # (expected.json equals results/e17b/ownwalk/F10000.json)
    src = os.path.join(HERE, "testdata", "ownwalk-e17b-shaped")
    d = tmp_path / "F10000"
    d.mkdir()
    for n in ("ownwalk.json", "worker.log"):
        (d / n).write_bytes(open(os.path.join(src, n), "rb").read())
    p = subprocess.run([sys.executable, SCRIPT, str(d)], capture_output=True, text=True)
    assert p.returncode == 0, p.stderr
    assert (d / "ownwalk.json").read_bytes() == open(os.path.join(src, "expected.json"), "rb").read()
    assert p.stdout == open(os.path.join(src, "expected.stdout")).read()


def test_b_that_walked_is_invalid(tmp_path):
    d = rundir(tmp_path, ["ow-0"], repeat_lines("ow-0", 380000, 5000))
    r = P.annotate(str(d))
    assert r["runs"][0]["walk_observed"]["B"] is True and r["runs"][0]["valid"] is False
    assert "B walked" in "; ".join(r["runs"][0]["invalid_reasons"])
    assert r["normalise_us_b_max"] == 5000 and r["normalise_us_median_a"] is None


def test_b_without_its_own_lease_start_is_invalid(tmp_path):
    d = rundir(tmp_path, ["ow-0"], repeat_lines("ow-0", b_new_vm=False))
    r = P.annotate(str(d))
    assert r["runs"][0]["valid"] is False
    assert "2 lease starts" in "; ".join(r["runs"][0]["invalid_reasons"])


def test_a_key_with_missing_exec_lines_is_not_observed(tmp_path):
    lines = repeat_lines("ow-0")[:3]  # the build and A's lease start only
    d = rundir(tmp_path, ["ow-0"], lines)
    r = P.annotate(str(d))
    run = r["runs"][0]
    assert run["walk_observed"]["A"] is None and "1 exec line" in run["walk_observed"]["reason"]
    assert run["phase_corrected_walk_ms"] is None
    assert run["valid"] is False and r["valid"] is False


def test_cli_rewrites_ownwalk_json_and_exits_by_validity(tmp_path):
    d = rundir(tmp_path, ["ow-0"], repeat_lines("ow-0"))
    p = subprocess.run([sys.executable, SCRIPT, str(d)], capture_output=True, text=True)
    assert p.returncode == 0, p.stderr
    j = json.loads((d / "ownwalk.json").read_text())
    assert "walk_observed" in j["runs"][0] and j["phase_corrected_walk_median_ms"] == 375.5
    assert "phase-corrected" in p.stdout
    bad = tmp_path / "bad"
    bad.mkdir()
    (bad / "ownwalk.json").write_text(json.dumps({"runs": [{"key": "ow-0", "walk_ms": 1.0, "valid": True, "invalid_reasons": []}],
                                                  "valid": True, "invalid_reasons": []}))
    (bad / "worker.log").write_text("\n".join(repeat_lines("ow-0", 0, 0)) + "\n")
    assert subprocess.run([sys.executable, SCRIPT, str(bad)], capture_output=True, text=True).returncode == 1
    assert subprocess.run([sys.executable, SCRIPT, str(tmp_path / "none")], capture_output=True, text=True).returncode == 2
