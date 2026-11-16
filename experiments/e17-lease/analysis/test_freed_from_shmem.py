"""freed_from_shmem.py (PLAN-E17B Task 10 fix round 1, ruling E17B-R22): RUNDIR/shmem.json =
{"session:call": dShmem bytes or null} for every heavy call, from the py_shmem readings that bracket it."""
import json
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import freed_from_shmem as F  # noqa: E402

KIB = 1024


def c(key, i, cls, **kw):
    return dict({"session": key, "call": i, "class": cls, "status": "ok", "execs": 1}, **kw)


def shm(key, i, kb, **kw):
    return c(key, i, "py_shmem", stdout="%d\n" % kb, **kw)


def start_ev():
    return [{"state": "start", "reason": "", "at_unix_ms": 1, "age_ms": 0, "mode": "lease"}]


def end_ev(reason="idle"):
    return [{"state": "end", "reason": reason, "at_unix_ms": 2, "age_ms": 5, "mode": "lease"}]


def rundir(tmp_path, calls, arm="ship-300", name="rung"):
    d = tmp_path / name
    d.mkdir()
    (d / "calls.jsonl").write_text("".join(json.dumps(x) + "\n" for x in calls))
    if arm is not None:
        (d / "params.json").write_text(json.dumps({"arm": arm, "n": 1, "point": "pycache"}))
    return str(d)


def run(d):
    F.main([d])
    with open(os.path.join(d, "shmem.json")) as f:
        return json.load(f)


def one_heavy_turns(key="A"):
    """Two turns of one heavy call each, bracketed: first_lease at call 0, Shmem 2000 kB after turn 1,
    5000 kB after turn 2."""
    return [c(key, 0, "py_grep", first_lease=True, lease_events=start_ev()), c(key, 1, "py_analyze"),
            c(key, 2, "py_short"), shm(key, 3, 2000),
            c(key, 4, "py_short"), c(key, 5, "py_analyze"), shm(key, 6, 5000)]


def test_delta_between_bracketing_readings(tmp_path):
    out = run(rundir(tmp_path, one_heavy_turns()))
    assert out == {"A:1": 2000 * KIB, "A:5": 3000 * KIB}  # first turn: the lease began in it, Shmem 0


def test_turn_with_more_than_one_heavy_call_is_null(tmp_path):
    calls = [c("A", 0, "py_analyze", first_lease=True, lease_events=start_ev()), c("A", 1, "py_test"),
             c("A", 2, "py_short"), c("A", 3, "py_analyze"), shm("A", 4, 9000)]
    assert run(rundir(tmp_path, calls)) == {"A:0": None, "A:1": None, "A:3": None}


def test_first_turn_without_lease_start_in_it_is_null(tmp_path):
    # The recorded calls begin mid-lease (no first_lease, no event before the heavy call): no "before".
    calls = [c("A", 7, "py_short"), c("A", 8, "py_analyze"), shm("A", 9, 4000)]
    assert run(rundir(tmp_path, calls)) == {"A:8": None}


def test_new_lease_inside_the_turn_resets_before_to_zero(tmp_path):
    # An idle end is delivered on call 4 (a replacement lease starts there, before the heavy call): the
    # earlier reading is the old VM's, so "before" is the new lease's start, Shmem 0.
    calls = one_heavy_turns()
    calls[4] = c("A", 4, "py_short", lease_events=end_ev())
    assert run(rundir(tmp_path, calls))["A:5"] == 5000 * KIB


def test_lease_change_after_the_heavy_call_is_null(tmp_path):
    calls = one_heavy_turns()
    calls[6] = shm("A", 6, 5000, lease_events=end_ev("memory_reclaim"))
    assert run(rundir(tmp_path, calls))["A:5"] is None


def test_no_reading_after_or_a_bad_reading_is_null(tmp_path):
    calls = one_heavy_turns()[:6]  # the run ended before the turn's py_shmem
    assert run(rundir(tmp_path, calls, name="cut"))["A:5"] is None
    for bad in (dict(stdout="oops\n"), dict(status="err"), dict(stdout=None)):
        calls = one_heavy_turns()
        calls[6] = dict(shm("A", 6, 5000), **bad)
        if bad.get("stdout", 0) is None:
            del calls[6]["stdout"]
        assert run(rundir(tmp_path, calls, name="bad%d" % len(os.listdir(tmp_path))))["A:5"] is None
    # a bad earlier reading nulls the next turn's heavy call only
    calls = one_heavy_turns()
    calls[3] = dict(shm("A", 3, 2000), stdout="")
    assert run(rundir(tmp_path, calls, name="badprev")) == {"A:1": None, "A:5": None}


def test_sessions_are_separate_and_keys_are_session_call(tmp_path):
    calls = one_heavy_turns("A") + one_heavy_turns("B")
    calls[-1] = shm("B", 6, 2500)
    out = run(rundir(tmp_path, calls))
    assert out == {"A:1": 2000 * KIB, "A:5": 3000 * KIB, "B:1": 2000 * KIB, "B:5": 500 * KIB}


def test_not_a_lease_arm_is_all_null(tmp_path):
    # sbx: every Exec is its own VM, so a reading never sees the heavy call's guest.
    out = run(rundir(tmp_path, one_heavy_turns(), arm="sbx"))
    assert out == {"A:1": None, "A:5": None}


def test_set_mode_failed_rows_are_skipped(tmp_path):
    calls = [c("A", 0, "py_analyze", cause="set_mode_failed", status="err")]
    assert run(rundir(tmp_path, calls)) == {}


def test_reads_gzipped_calls(tmp_path):
    import gzip
    d = rundir(tmp_path, one_heavy_turns())
    with open(os.path.join(d, "calls.jsonl"), "rb") as f, gzip.open(os.path.join(d, "calls.jsonl.gz"), "wb") as g:
        g.write(f.read())
    os.remove(os.path.join(d, "calls.jsonl"))
    assert run(d) == {"A:1": 2000 * KIB, "A:5": 3000 * KIB}


def test_heavy_classes_are_vm_age_lease_s():
    import vm_age_lease
    assert F.HEAVY_CLASSES == vm_age_lease.HEAVY_CLASSES == ("py_analyze", "py_test")
    assert "max(0, peak - start - dShmem)" in F.__doc__


def test_usage(tmp_path):
    with pytest.raises(SystemExit):
        F.main([])
