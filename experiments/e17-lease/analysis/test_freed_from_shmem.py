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
FIRST = {"A:0": None, "A:1": None, "A:5": None}  # the lease's first turn (R24: never judged)


def test_shape_and_tolerance(tmp_path):
    out = run(rundir(tmp_path, two_turns()))
    assert set(out) == {"calls", "turns", "unexpected_turns", "first_turn_readings", "tolerance_bytes"}
    assert out["tolerance_bytes"] == F.SHMEM_TOL_BYTES == 1 << 20
    assert "max(0, peak - start - dShmem)" in F.__doc__ and "E17B-R24" in F.__doc__


@pytest.mark.parametrize("kb", [0, 800])
def test_lease_first_turn_is_null(tmp_path, kb):
    # R24: a turn holding a new-lease mark has no base (a guest's Shmem at lease start is unknown, not 0),
    # whatever it reads at its end; the next turn is judged against that reading. R25: the reading is
    # kept under first_turn_readings, flagged or not.
    for t in (False, True):
        out = run(rundir(tmp_path, two_turns(tmpfs=t, kb=(kb, kb)), name="r%d-%s" % (kb, t)))
        assert all(out["calls"][k] is None for k in FIRST)
        assert out["first_turn_readings"] == {"A:6": kb * KIB}
        assert out["unexpected_turns"] == {}
        if t:
            assert out["turns"] == {"A:6": None, "A:13": 0}
        else:
            assert out["calls"]["A:7"] == out["calls"]["A:8"] == out["calls"]["A:12"] == 0


def test_untouched_tmpfs_gives_every_later_heavy_call_zero(tmp_path):
    # tmpfs=false: Shmem 800 kB at both turn ends: the second turn's delta is 0, within 1 MiB.
    out = run(rundir(tmp_path, two_turns()))
    assert out["calls"] == dict(FIRST, **{"A:7": 0, "A:8": 0, "A:12": 0})
    assert out["turns"] == {} and out["unexpected_turns"] == {}
    assert out["first_turn_readings"] == {"A:6": 800 * KIB}


def test_growth_over_tolerance_nulls_the_turn_and_lists_it(tmp_path):
    out = run(rundir(tmp_path, two_turns(kb=(800, 800 + 2048))))
    assert out["calls"] == dict(FIRST, **{"A:7": None, "A:8": None, "A:12": None})
    assert out["unexpected_turns"] == {"A:13": 2048 * KIB}
    # exactly 1 MiB is within it; a shrink counts by its size too
    out = run(rundir(tmp_path, two_turns(kb=(800, 800 + 1024)), name="edge"))
    assert out["calls"]["A:12"] == 0
    out = run(rundir(tmp_path, two_turns(kb=(4000, 800)), name="shrink"))
    assert out["calls"]["A:7"] is None and out["unexpected_turns"] == {"A:13": -3200 * KIB}


def test_tmpfs_sessions_are_not_judged_and_their_growth_is_reported(tmp_path):
    out = run(rundir(tmp_path, two_turns(tmpfs=True, kb=(60000, 61000))))
    assert out["calls"] == {"A:%d" % i: None for i in HEAVY}
    assert out["turns"] == {"A:6": None, "A:13": 1000 * KIB}
    assert out["first_turn_readings"] == {"A:6": 60000 * KIB}
    assert out["unexpected_turns"] == {}


def test_first_turn_without_lease_start_in_it_is_null(tmp_path):
    # The recorded calls begin mid-lease (the driver's random start index; no mark before the reading):
    # null, and not a lease's first turn (no first_turn_readings).
    calls = [x for x in two_turns() if x["call"] >= 3]
    out = run(rundir(tmp_path, calls))
    assert out["calls"] == {"A:5": None, "A:7": 0, "A:8": 0, "A:12": 0}
    assert out["first_turn_readings"] == {}


def three_turns(tmpfs=False, kb=(800, 900, 900)):
    calls = two_turns(tmpfs=tmpfs, kb=kb[:2])
    t = tmpfs
    return calls + [c("A", 14, "py_analyze", t), c("A", 15, "py_test", t), c("A", 16, "py_short", t),
                    c("A", 17, "py_analyze", t), shm("A", 18, kb[2], t)]


def test_new_lease_inside_a_turn(tmp_path):
    # An idle end is delivered on call 9: turn 2 is the replacement lease's first turn, so all of its
    # heavy calls are null (R24); turn 3 is judged against turn 2's closing reading.
    calls = three_turns(kb=(800, 5000, 5000 + 512))
    calls[9] = c("A", 9, "py_import", lease_events=end_ev())
    out = run(rundir(tmp_path, calls))
    assert [out["calls"]["A:%d" % i] for i in (7, 8, 12, 14, 15, 17)] == [None, None, None, 0, 0, 0]
    assert out["first_turn_readings"] == {"A:6": 800 * KIB, "A:13": 5000 * KIB}
    # the same in a tmpfs session: no growth for the first turns, turn 3's from turn 2's reading
    calls = three_turns(tmpfs=True, kb=(5000, 3000, 7000))
    calls[9] = c("A", 9, "py_import", True, lease_events=end_ev())
    out = run(rundir(tmp_path, calls, name="t"))
    assert out["turns"] == {"A:6": None, "A:13": None, "A:18": 4000 * KIB}
    assert out["first_turn_readings"] == {"A:6": 5000 * KIB, "A:13": 3000 * KIB}


def test_missing_or_bad_reading_nulls_its_turn_and_the_next(tmp_path):
    calls = three_turns()[:18]  # the run ended before turn 3's py_shmem
    out = run(rundir(tmp_path, calls, name="cut"))
    assert out["calls"]["A:17"] is None and out["calls"]["A:12"] == 0
    for n, bad in enumerate((dict(stdout="oops\n"), dict(status="err"), dict(stdout=""))):
        calls = three_turns()
        calls[13] = dict(calls[13], **bad)
        out = run(rundir(tmp_path, calls, name="bad%d" % n))
        # turn 2 has no reading at its end; turn 3 has no reading at its start
        assert all(out["calls"]["A:%d" % i] is None for i in (7, 8, 12, 14, 15, 17)), (bad, out)
    # a bad first-turn reading: first_turn_readings keeps the turn, with null
    calls = two_turns()
    calls[6] = dict(calls[6], stdout="")
    assert run(rundir(tmp_path, calls, name="badfirst"))["first_turn_readings"] == {"A:6": None}


def test_sessions_are_separate(tmp_path):
    out = run(rundir(tmp_path, two_turns("A") + two_turns("B", tmpfs=True, kb=(9000, 9100))))
    assert [out["calls"]["A:%d" % i] for i in (7, 8, 12)] == [0, 0, 0]
    assert all(out["calls"]["B:%d" % i] is None for i in HEAVY)
    assert out["turns"] == {"B:6": None, "B:13": 100 * KIB}
    assert out["first_turn_readings"] == {"A:6": 800 * KIB, "B:6": 9000 * KIB}


def test_not_a_lease_arm_is_all_null(tmp_path):
    out = run(rundir(tmp_path, two_turns(tmpfs=False) + two_turns("B", tmpfs=True), arm="sbx"))
    assert set(out["calls"].values()) == {None} and len(out["calls"]) == 12
    assert out["turns"] == {} and out["unexpected_turns"] == {} and out["first_turn_readings"] == {}


def test_set_mode_failed_rows_are_skipped(tmp_path):
    out = run(rundir(tmp_path, [c("A", 0, "py_analyze", cause="set_mode_failed", status="err")]))
    assert out["calls"] == {} and out["turns"] == {}


def test_reads_gzipped_calls(tmp_path):
    d = rundir(tmp_path, two_turns())
    with open(os.path.join(d, "calls.jsonl"), "rb") as f, gzip.open(os.path.join(d, "calls.jsonl.gz"), "wb") as g:
        g.write(f.read())
    os.remove(os.path.join(d, "calls.jsonl"))
    assert run(d)["calls"] == dict(FIRST, **{"A:7": 0, "A:8": 0, "A:12": 0})


def test_driver_fixture_every_untouched_session_heavy_call_is_judged(tmp_path):
    # The E17b driver fixture (3 sessions, 2 flagged tmpfs), replayed as if every call ran ok in one
    # lease per session with Shmem steady at 800 kB: every heavy call of the tmpfs=false session after
    # its lease's first turn has a dShmem (0); the first turn's and every flagged session's are null;
    # each session's first turn is in first_turn_readings, and the flagged sessions' turns are reported.
    calls, flags, first_turn = [], {}, {}
    for line in open(FIXTURE):
        s = json.loads(line)
        flags[s["session"]] = s["tmpfs"]
        first_turn[s["session"]] = next(x["i"] for x in s["calls"] if x["class"] == "py_shmem")
        for x in s["calls"]:
            row = c(s["session"], x["i"], x["class"], s["tmpfs"],
                    **({"stdout": "800\n"} if x["class"] == "py_shmem" else {}),
                    **({"first_lease": True} if x["i"] == 0 else {}))
            calls.append(row)
    assert sorted(flags.values()) == [False, True, True]
    out = run(rundir(tmp_path, calls))
    for key, v in out["calls"].items():
        sess, call = key.rsplit(":", 1)
        assert (v is None) == (flags[sess] or int(call) < first_turn[sess]), (key, v)
    plain = [k for k in out["calls"] if not flags[k.rsplit(":", 1)[0]] and out["calls"][k] is not None]
    assert len(plain) >= 9 and all(out["calls"][k] == 0 for k in plain)
    assert out["turns"] and all(flags[k.rsplit(":", 1)[0]] for k in out["turns"])
    assert out["first_turn_readings"] == {"%s:%d" % (k, v): 800 * KIB for k, v in first_turn.items()}


def test_heavy_classes_are_vm_age_lease_s():
    import vm_age_lease
    assert F.HEAVY_CLASSES == vm_age_lease.HEAVY_CLASSES == ("py_analyze", "py_test")


def test_usage():
    with pytest.raises(SystemExit):
        F.main([])
