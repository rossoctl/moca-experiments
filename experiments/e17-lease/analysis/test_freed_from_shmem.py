"""freed_from_shmem.py (PLAN-E17B Task 10, ruling E17B-R23): RUNDIR/shmem.json = {"calls": {"session:call":
dShmem bytes or null}, "turns": {"session:turn": bytes or null}, "unexpected_turns": {...}, "tolerance_bytes"}."""
import gzip
import json
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import freed_from_shmem as F  # noqa: E402

KIB = 1024
MIB = 1 << 20
FIXTURE = os.path.join(HERE, "..", "..", "e15-session-density", "driver", "testdata", "pycache-corpus-tmpfs.jsonl")


def c(key, i, cls, tmpfs=False, **kw):
    row = dict({"session": key, "call": i, "class": cls, "status": "ok", "execs": 1}, **kw)
    if tmpfs:
        row["tmpfs"] = True  # the driver writes it on every row of a flagged session (omitted otherwise)
    return row


def shm(key, i, kb, tmpfs=False, **kw):
    return c(key, i, "py_shmem", tmpfs, stdout="%d\n" % kb, **kw)


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


def two_turns(key="A", tmpfs=False, kb=(800, 800)):
    """Two pycache-shaped turns (three heavy calls each), the lease beginning at call 0; Shmem kb[0]
    after turn 1 (call 6), kb[1] after turn 2 (call 13)."""
    t = tmpfs
    return [c(key, 0, "py_analyze", t, first_lease=True, lease_events=start_ev()), c(key, 1, "py_test", t),
            c(key, 2, "py_import", t), c(key, 3, "py_grep", t), c(key, 4, "py_short", t),
            c(key, 5, "py_analyze", t), shm(key, 6, kb[0], t),
            c(key, 7, "py_analyze", t), c(key, 8, "py_test", t), c(key, 9, "py_import", t),
            c(key, 10, "py_grep", t), c(key, 11, "py_short", t), c(key, 12, "py_analyze", t), shm(key, 13, kb[1], t)]


HEAVY = {0, 1, 5, 7, 8, 12}


def test_shape_and_tolerance(tmp_path):
    out = run(rundir(tmp_path, two_turns()))
    assert set(out) == {"calls", "turns", "unexpected_turns", "tolerance_bytes"}
    assert out["tolerance_bytes"] == F.SHMEM_TOL_BYTES == 1 << 20
    assert "max(0, peak - start - dShmem)" in F.__doc__


def test_untouched_tmpfs_gives_every_heavy_call_zero(tmp_path):
    # tmpfs=false: Shmem 800 kB at both turn ends (and from 0 in the first turn, where the lease began):
    # within 1 MiB, so every heavy call of both turns gets dShmem 0.
    out = run(rundir(tmp_path, two_turns()))
    assert out["calls"] == {"A:%d" % i: 0 for i in HEAVY}
    assert out["turns"] == {} and out["unexpected_turns"] == {}


def test_growth_over_tolerance_nulls_the_turn_and_lists_it(tmp_path):
    out = run(rundir(tmp_path, two_turns(kb=(800, 800 + 2048))))
    assert out["calls"] == {"A:0": 0, "A:1": 0, "A:5": 0, "A:7": None, "A:8": None, "A:12": None}
    assert out["unexpected_turns"] == {"A:13": 2048 * KIB}
    # exactly 1 MiB is within it; a shrink counts by its size too
    out = run(rundir(tmp_path, two_turns(kb=(800, 800 + 1024)), name="edge"))
    assert out["calls"]["A:12"] == 0
    out = run(rundir(tmp_path, two_turns(kb=(4000, 800)), name="shrink"))
    assert out["calls"]["A:0"] is None and out["calls"]["A:7"] is None  # 4000 kB from 0, then -3200 kB
    assert out["unexpected_turns"] == {"A:6": 4000 * KIB, "A:13": -3200 * KIB}


def test_tmpfs_sessions_are_not_judged_and_their_growth_is_reported(tmp_path):
    out = run(rundir(tmp_path, two_turns(tmpfs=True, kb=(60000, 61000))))
    assert out["calls"] == {"A:%d" % i: None for i in HEAVY}
    assert out["turns"] == {"A:6": 60000 * KIB, "A:13": 1000 * KIB}
    assert out["unexpected_turns"] == {}


def test_first_turn_without_lease_start_in_it_is_null(tmp_path):
    # The recorded calls begin mid-lease (the driver's random start index; no mark before the reading).
    calls = [x for x in two_turns() if x["call"] >= 3]
    out = run(rundir(tmp_path, calls))
    assert out["calls"] == {"A:5": None, "A:7": 0, "A:8": 0, "A:12": 0}


def test_new_lease_inside_a_turn(tmp_path):
    # An idle end is delivered on call 9: calls 7 and 8 ran on the old VM, whose last reading is unknown
    # (null); from call 9 on the new lease starts at Shmem 0, so call 12 is judged against 0.
    calls = two_turns()
    calls[9] = c("A", 9, "py_import", lease_events=end_ev())
    out = run(rundir(tmp_path, calls))
    assert (out["calls"]["A:7"], out["calls"]["A:8"], out["calls"]["A:12"]) == (None, None, 0)
    # the same in a tmpfs session: the turn's growth is from the new lease's start
    calls = two_turns(tmpfs=True, kb=(5000, 3000))
    calls[9] = c("A", 9, "py_import", True, lease_events=end_ev())
    assert run(rundir(tmp_path, calls, name="t"))["turns"] == {"A:6": 5000 * KIB, "A:13": 3000 * KIB}


def test_missing_or_bad_reading_nulls_its_turn_and_the_next(tmp_path):
    calls = two_turns()[:13]  # the run ended before turn 2's py_shmem
    out = run(rundir(tmp_path, calls, name="cut"))
    assert out["calls"]["A:12"] is None and out["calls"]["A:0"] == 0
    for n, bad in enumerate((dict(stdout="oops\n"), dict(status="err"), dict(stdout=""))):
        calls = two_turns()
        calls[6] = dict(calls[6], **bad)
        out = run(rundir(tmp_path, calls, name="bad%d" % n))
        # turn 1 has no reading at its end; turn 2 has no reading at its start
        assert all(out["calls"]["A:%d" % i] is None for i in HEAVY), (bad, out)


def test_sessions_are_separate(tmp_path):
    out = run(rundir(tmp_path, two_turns("A") + two_turns("B", tmpfs=True, kb=(9000, 9100))))
    assert all(out["calls"]["A:%d" % i] == 0 for i in HEAVY)
    assert all(out["calls"]["B:%d" % i] is None for i in HEAVY)
    assert out["turns"] == {"B:6": 9000 * KIB, "B:13": 100 * KIB}


def test_not_a_lease_arm_is_all_null(tmp_path):
    out = run(rundir(tmp_path, two_turns(tmpfs=False) + two_turns("B", tmpfs=True), arm="sbx"))
    assert set(out["calls"].values()) == {None} and len(out["calls"]) == 12
    assert out["turns"] == {} and out["unexpected_turns"] == {}


def test_set_mode_failed_rows_are_skipped(tmp_path):
    out = run(rundir(tmp_path, [c("A", 0, "py_analyze", cause="set_mode_failed", status="err")]))
    assert out["calls"] == {} and out["turns"] == {}


def test_reads_gzipped_calls(tmp_path):
    d = rundir(tmp_path, two_turns())
    with open(os.path.join(d, "calls.jsonl"), "rb") as f, gzip.open(os.path.join(d, "calls.jsonl.gz"), "wb") as g:
        g.write(f.read())
    os.remove(os.path.join(d, "calls.jsonl"))
    assert run(d)["calls"] == {"A:%d" % i: 0 for i in HEAVY}


def test_driver_fixture_every_untouched_session_heavy_call_is_judged(tmp_path):
    # The E17b driver fixture (3 sessions, 2 flagged tmpfs), replayed as if every call ran ok in one
    # lease per session with Shmem steady at 800 kB: every heavy call of the tmpfs=false session has a
    # dShmem (0); every heavy call of the flagged ones is null, and their turns are reported.
    calls, flags = [], {}
    for line in open(FIXTURE):
        s = json.loads(line)
        flags[s["session"]] = s["tmpfs"]
        for x in s["calls"]:
            row = c(s["session"], x["i"], x["class"], s["tmpfs"],
                    **({"stdout": "800\n"} if x["class"] == "py_shmem" else {}),
                    **({"first_lease": True} if x["i"] == 0 else {}))
            calls.append(row)
    assert sorted(flags.values()) == [False, True, True]
    out = run(rundir(tmp_path, calls))
    for key, v in out["calls"].items():
        sess = key.rsplit(":", 1)[0]
        assert (v is None) == flags[sess], (key, v)
    plain = [k for k in out["calls"] if not flags[k.rsplit(":", 1)[0]]]
    assert plain and all(out["calls"][k] == 0 for k in plain)
    assert out["turns"] and all(flags[k.rsplit(":", 1)[0]] for k in out["turns"])


def test_heavy_classes_are_vm_age_lease_s():
    import vm_age_lease
    assert F.HEAVY_CLASSES == vm_age_lease.HEAVY_CLASSES == ("py_analyze", "py_test")


def test_usage():
    with pytest.raises(SystemExit):
        F.main([])
