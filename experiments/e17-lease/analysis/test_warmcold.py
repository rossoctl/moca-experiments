import calendar
import datetime
import gzip
import json
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import warmcold as W  # noqa: E402

SLICE = os.path.join(HERE, "testdata", "resident-300-n8-slice")
K0 = "e15-default-resident-300-n8-1793877159-0-0"
K3 = "e15-default-resident-300-n8-1793877159-3-0"


def exec_line(key, vm, req=1, cold="", ts="2026-11-05T11:00:00Z"):
    return '%s vmpool: exec req=%d workspace_key="%s" vm=%s cold="%s" exit=0 err=<nil>\n' % (
        ts, req, key, vm, cold)


def resident_line(kind, key, vm, ts="2026-11-05T11:00:00Z"):
    tail = {"idle-destroy": " idle=5m0s", "retire": " reason=run-error", "end-session": ""}[kind]
    return '%s vmpool: e15 resident %s workspace_key="%s" vm=%s%s\n' % (ts, kind, key, vm, tail)


T_LOG = calendar.timegm((2026, 11, 5, 11, 0, 0, 0, 0, 0))  # exec_line's default stamp


def call(key, i, cls="py_analyze", ms=1000.0, execs=1, status="ok", in_window=True, end=T_LOG + 0.4,
         **extra):
    """A calls.jsonl record whose send time is `end` - observed_ms: its Exec ends at `end`, within the
    join's 2 s timestamp guard of an exec line stamped at T_LOG (the default)."""
    ts = datetime.datetime.fromtimestamp(end - ms / 1000.0, datetime.timezone.utc)
    return dict({"ts": ts.strftime("%Y-%m-%dT%H:%M:%S.%fZ"), "session": key, "call": i, "class": cls,
                 "execs": execs, "observed_ms": ms, "status": status, "in_window": in_window}, **extra)


def rung(tmp_path, calls, log, name="rung", gz=False):
    d = tmp_path / name
    d.mkdir()
    body = "".join(json.dumps(c) + "\n" for c in calls)
    text = "microvm-worker: attached, serving execs\n" + "".join(log)
    if gz:
        with gzip.open(d / "calls.jsonl.gz", "wt") as f:
            f.write(body)
        with gzip.open(d / "worker.log.gz", "wt") as f:
            f.write(text)
    else:
        (d / "calls.jsonl").write_text(body)
        (d / "worker.log").write_text(text)
    return str(d)


def by_call(rows):
    return {(r["session"], r["call"]): r for r in rows}


def test_join_by_key_and_order(tmp_path):
    # Two calls of key A in the same second on the same VM, another key interleaved, every
    # timestamp identical, and calls.jsonl out of call order: only the key and the log position
    # can place the lines.
    log = [exec_line("A", "vm-1", req=10, cold="first-exec"),
           exec_line("B", "vm-2", req=11, cold="first-exec"),
           exec_line("A", "vm-1", req=12)]
    calls = [call("A", 2), call("B", 1), call("A", 1)]
    rows, summary = W.join(rung(tmp_path, calls, log))
    r = by_call(rows)
    assert r[("A", 1)]["warm"] is False and r[("A", 1)]["cold_reason"] == "first"
    assert r[("A", 2)]["warm"] is True
    assert r[("A", 2)]["vm"] == "vm-1" and r[("A", 2)]["prev_vm"] == "vm-1"
    assert r[("B", 1)]["warm"] is False
    assert [(x["session"], x["call"]) for x in rows] == [("A", 1), ("A", 2), ("B", 1)]
    assert summary["warm"] == 1 and summary["cold"] == 2 and summary["unknown"] == 0


def test_idle_destroy_makes_next_cold(tmp_path):
    # Even with the same vm id on both sides (impossible on a real pool, whose ids are never
    # reused), a teardown between two calls makes the later one cold.
    log = [exec_line("A", "vm-1", cold="first-exec"),
           resident_line("idle-destroy", "A", "vm-1"),
           exec_line("A", "vm-1"),
           exec_line("A", "vm-1")]
    rows, _ = W.join(rung(tmp_path, [call("A", 1), call("A", 2), call("A", 3)], log))
    r = by_call(rows)
    assert r[("A", 2)]["warm"] is False and r[("A", 2)]["cold_reason"] == "idle-destroy"
    assert r[("A", 3)]["warm"] is True


def test_other_keys_teardown_does_not_break_warmth(tmp_path):
    log = [exec_line("A", "vm-1"), resident_line("idle-destroy", "B", "vm-9"), exec_line("A", "vm-1")]
    rows, _ = W.join(rung(tmp_path, [call("A", 1), call("A", 2)], log))
    assert by_call(rows)[("A", 2)]["warm"] is True


def test_retire_inside_own_exec_keeps_call_warm(tmp_path):
    # runResident logs a retire (run-error, timeout, dead-agent) inside the Exec that ran on the
    # VM, before that Exec's own exec line. vm ids are never reused, so a retire naming the call's
    # own vm happened after the call ran on it: that call was warm, the next one is cold.
    log = [exec_line("A", "vm-1"),
           resident_line("retire", "A", "vm-1"),
           exec_line("A", "vm-1"),
           exec_line("A", "vm-4", cold="parked")]
    rows, _ = W.join(rung(tmp_path, [call("A", 1), call("A", 2), call("A", 3)], log))
    r = by_call(rows)
    assert r[("A", 2)]["warm"] is True
    assert r[("A", 3)]["warm"] is False and r[("A", 3)]["cold_reason"] == "retire"


def test_sbx_arm_is_never_warm(tmp_path):
    # Stock worker: every Exec restores (or pops a standby: cold="") a VM of its own.
    log = [exec_line("A", "vm-1", cold="first-exec"),
           'x vmpool: exec phases acquire_us=1 resume_us=1 vmresume_us=1 vsockdial_us=1 mount_us=1 run_us=1 destroy_us=1 cold=""\n',
           exec_line("A", "vm-2"), exec_line("A", "vm-3"), exec_line("A", "vm-5")]
    calls = [call("A", i) for i in range(1, 5)]
    rows, summary = W.join(rung(tmp_path, calls, log))
    assert [x["warm"] for x in rows] == [False] * 4
    assert summary["warm"] == 0 and summary["cold"] == 4


def test_attach_probe_and_phases_lines_ignored(tmp_path):
    log = [exec_line("_e15-attach-probe", "", cold=""), exec_line("A", "vm-1"),
           exec_line("_e15-attach-probe", ""), exec_line("A", "vm-1")]
    rows, summary = W.join(rung(tmp_path, [call("A", 1), call("A", 2)], log))
    assert [x["warm"] for x in rows] == [False, True]
    assert "_e15-attach-probe" not in summary["unknown_keys"]
    assert summary["log_keys_without_calls"] == [] and summary["dropped_end_session_execs"] == []


def test_unmatched_is_unknown_not_guessed(tmp_path):
    # Key A: 2 calls, 1 exec line -> every call of A unknown. Key C: a call never started
    # (execs 0) has no exec line: unknown, and the next call compares with the last that ran.
    log = [exec_line("A", "vm-1"), exec_line("C", "vm-7"), exec_line("C", "vm-7")]
    calls = [call("A", 1), call("A", 2), call("C", 1), call("C", 2, execs=0, status="err"), call("C", 3)]
    rows, summary = W.join(rung(tmp_path, calls, log))
    r = by_call(rows)
    assert r[("A", 1)]["warm"] == "unknown" and r[("A", 2)]["warm"] == "unknown"
    assert r[("A", 1)]["vm"] is None
    assert r[("C", 2)]["warm"] == "unknown"
    assert r[("C", 3)]["warm"] is True and r[("C", 3)]["prev_vm"] == "vm-7"
    assert summary["unknown"] == 3
    assert summary["unknown_keys"] == {"A": "calls want 2 exec lines, the log has 1"}


def test_end_session_exec_dropped_only_after_end_session_line(tmp_path):
    # The driver's `: e15-end-session` Exec is logged after `e15 resident end-session`: dropped and
    # recorded. An extra exec line with no end-session before it still makes the key unknown.
    log = [exec_line("A", "vm-1", req=1), exec_line("A", "vm-1", req=2),
           resident_line("end-session", "A", "vm-1"), exec_line("A", "vm-1", req=3),
           exec_line("B", "vm-2", req=4), exec_line("B", "vm-2", req=5)]
    rows, summary = W.join(rung(tmp_path, [call("A", 1), call("A", 2), call("B", 1)], log))
    r = by_call(rows)
    assert r[("A", 2)]["warm"] is True
    assert summary["dropped_end_session_execs"] == [
        {"session": "A", "req": 3, "vm": "vm-1", "reason": "after-end-session-line"}]
    assert r[("B", 1)]["warm"] == "unknown"
    assert summary["unknown_keys"] == {"B": "calls want 1 exec lines, the log has 2"}


def test_end_session_exec_without_vm_dropped(tmp_path):
    # An end-session Exec on a key that holds no VM (idle-destroyed just before): the patch answers
    # it with no VM, no end-session line and err=<nil>. A failed acquire (err set) is not dropped.
    log = [exec_line("A", "vm-1"), resident_line("idle-destroy", "A", "vm-1"),
           '2026-11-05T11:00:00Z vmpool: exec req=9 workspace_key="A" vm= cold="" exit=0 err=<nil>\n',
           exec_line("B", "vm-2"),
           '2026-11-05T11:00:00Z vmpool: exec req=11 workspace_key="B" vm= cold="" exit=0 err=memory-budget: x\n']
    rows, summary = W.join(rung(tmp_path, [call("A", 1), call("B", 1), call("B", 2)], log))
    r = by_call(rows)
    assert summary["dropped_end_session_execs"] == [
        {"session": "A", "req": 9, "vm": None, "reason": "no-vm-no-error"}]
    assert r[("A", 1)]["warm"] is False and summary["unknown_keys"] == {}
    assert r[("B", 2)]["warm"] == "unknown" and r[("B", 2)]["cold_reason"] == "no-vm"


ABORTED = os.path.join(HERE, "testdata", "resident-inf-n1024-aborted")
K1005 = "e15-lowduty-resident-inf-n1024-1794182088-1005-1"
QF = "rpc error: code = Internal desc = busy: queue full"


def test_aborted_end_session_exec_dropped():
    # Real key from E16 resident-inf N1024 (2026-11-09, lowduty): 8 calls (1500..1507) on vm-1292,
    # then the driver's end-session Exec aborted at the run's teardown before endResidentSession ran:
    #   2026-11-09T00:33:29Z vmpool: exec req=8145070469489191 workspace_key="...-1005-1" vm= cold=""
    #   exit=0 err=vmpool: aborted
    # (no end-session line). By hand: 9 exec lines, 8 calls; 1 cold (1500, first), 7 warm.
    rows, summary = W.join(ABORTED)
    assert summary["unknown"] == 0 and summary["unknown_keys"] == {}
    assert summary["warm"] == 7 and summary["cold"] == 1
    assert summary["dropped_aborted_end_session"] == [
        {"session": K1005, "req": 8145070469489191, "err": "vmpool: aborted"}]
    assert summary["dropped_end_session_execs"] == []


def test_aborted_last_line_dropped_only_when_one_extra(tmp_path):
    # Two extra lines (one aborted at the end): not the end-session case alone, so unknown. An
    # aborted no-vm line that is not the key's last is never dropped either.
    ab = '2026-11-05T11:00:00Z vmpool: exec req=99 workspace_key="%s" vm= cold="" exit=0 err=vmpool: aborted\n'
    log = [exec_line("A", "vm-1"), exec_line("A", "vm-1"), ab % "A",
           exec_line("B", "vm-2"), ab % "B", exec_line("B", "vm-2")]
    rows, summary = W.join(rung(tmp_path, [call("A", 1), call("B", 1)], log))
    assert set(summary["unknown_keys"]) == {"A", "B"}
    assert summary["dropped_aborted_end_session"] == []


def test_queue_full_call_does_not_misalign_key(tmp_path):
    # A call the session loop refused (busy: queue full) is recorded with execs 1 but logs no exec
    # line: it counts 0, comes out unknown, and the calls around it keep their own lines.
    log = [exec_line("A", "vm-1", cold="first-exec"), exec_line("A", "vm-1")]
    calls = [call("A", 1), call("A", 2, status="err", cause="rpc_error", msg=QF), call("A", 3)]
    rows, summary = W.join(rung(tmp_path, calls, log))
    r = by_call(rows)
    assert summary["unknown_keys"] == {}
    assert r[("A", 2)]["warm"] == "unknown" and r[("A", 2)]["cold_reason"] == "queue-full"
    assert r[("A", 1)]["warm"] is False and r[("A", 3)]["warm"] is True


def test_missing_line_plus_extra_line_is_caught_by_timestamp_guard(tmp_path):
    # The cancel-out: call 1 left no exec line, and the key has one stray line at its end (an
    # aborted Exec WITH a vm, not dropped). Before the queue-full rule, a queue-full call was that
    # missing line: 3 calls want 3 lines, the log has 3, and every call takes the next call's line.
    stray = '2026-11-05T11:02:00Z vmpool: exec req=9 workspace_key="A" vm=vm-1 cold="" exit=0 err=vmpool: aborted\n'
    log = [exec_line("A", "vm-1", req=2, ts="2026-11-05T11:00:30Z"),
           exec_line("A", "vm-1", req=3, ts="2026-11-05T11:01:00Z"), stray]
    # (1) queue-full: counts 0, so 2 calls want 2 lines and the log has 3. Unknown, by count.
    calls = [call("A", 1, status="err", cause="rpc_error", msg=QF), call("A", 2, end=W_T(30)),
             call("A", 3, end=W_T(60))]
    rows, summary = W.join(rung(tmp_path, calls, log, name="qf"))
    assert summary["unknown_keys"] == {"A": "calls want 2 exec lines, the log has 3"}
    # (2) a refusal the join does not know (another msg): the counts match, 3 = 3. Unknown, by the
    # timestamp guard (call 1, sent at 11:00:00, would take the line stamped 11:00:30), not shifted.
    calls[0] = call("A", 1, status="err", cause="rpc_error", msg="rpc error: code = Unavailable")
    rows, summary = W.join(rung(tmp_path, calls, log, name="other"))
    assert summary["unknown_keys"]["A"].startswith("timestamp_mismatch: call 1 ")
    assert {x["warm"] for x in rows} == {"unknown"}
    assert {x["cold_reason"] for x in rows} == {"timestamp_mismatch"}


def test_timestamp_guard_passes_within_two_seconds(tmp_path):
    # Exec lines carry whole seconds and are written when the Exec ends: 1.9 s off is accepted.
    log = [exec_line("A", "vm-1"), exec_line("A", "vm-1", ts="2026-11-05T11:00:10Z")]
    rows, summary = W.join(rung(tmp_path, [call("A", 1, end=T_LOG + 1.9), call("A", 2, end=W_T(8.1))], log))
    assert summary["unknown_keys"] == {} and by_call(rows)[("A", 2)]["warm"] is True


def W_T(s):
    return T_LOG + s


def test_real_slice_resident_300(tmp_path):
    # Real resident-300 rung slice (metal, E15 default point, N=8, 2026-11-05): two keys, their
    # calls (calls.jsonl, plain) and their worker.log lines (worker.log.gz). Derived by hand from
    # the log, per key, in log order (`zgrep KEY worker.log.gz`, collapsing runs of exec lines on
    # one vm with `uniq -c`; the calls of each key are contiguous, so position p is call min+p-1):
    #   -0-0: 46 calls (134..179). vm-2 x15, idle-destroy, vm-13 x10, idle-destroy, vm-18 x7,
    #         idle-destroy, vm-24 x14, end-session, 1 exec (the end-session Exec, dropped).
    #         15+10+7+14 = 46 = calls. Cold: positions 1, 16, 26, 33 = calls 134, 149, 159, 166
    #         (134 first, the other three each right after an idle-destroy). 4 cold, 42 warm.
    #   -3-0: 66 calls (97..162). vm-5 x66, end-session, 1 exec (dropped). 1 cold (97), 65 warm.
    # Total 112 calls: 107 warm, 5 cold, 0 unknown; 2 end-session Execs dropped. The slice holds
    # 3 idle-destroy lines (this pair's); every call after one is cold.
    rows, summary = W.join(SLICE)
    assert len(rows) == 112
    assert summary["unknown"] == 0 and summary["unknown_keys"] == {}
    assert summary["warm"] == 107 and summary["cold"] == 5
    assert [(d["session"], d["vm"]) for d in summary["dropped_end_session_execs"]] == [
        (K0, "vm-24"), (K3, "vm-5")]
    cold = sorted((x["session"], x["call"], x["cold_reason"]) for x in rows if x["warm"] is False)
    assert cold == [(K0, 134, "first"), (K0, 149, "idle-destroy"), (K0, 159, "idle-destroy"),
                    (K0, 166, "idle-destroy"), (K3, 97, "first")]
    r = by_call(rows)
    assert (r[(K0, 149)]["prev_vm"], r[(K0, 149)]["vm"]) == ("vm-2", "vm-13")
    with W.open_rung_file(SLICE, "worker.log") as f:  # the fixture's log is worker.log.gz
        assert sum("e15 resident idle-destroy" in l for l in f) == 3


def test_cli_writes_warmcold_jsonl_from_gz(tmp_path):
    d = tmp_path / "rung"
    d.mkdir()
    with open(os.path.join(SLICE, "calls.jsonl"), "rb") as src, gzip.open(d / "calls.jsonl.gz", "wb") as dst:
        shutil.copyfileobj(src, dst)
    shutil.copy(os.path.join(SLICE, "worker.log.gz"), d / "worker.log.gz")
    W.main([str(d)])
    rows = [json.loads(l) for l in (d / "warmcold.jsonl").read_text().splitlines()]
    assert len(rows) == 112
    assert set(rows[0]) >= {"session", "call", "class", "observed_ms", "warm", "vm", "prev_vm"}
    assert sum(x["warm"] is True for x in rows) == 107
    rep = json.loads((d / "warmcold-report.json").read_text())
    assert rep["warm"] == 107 and rep["cold"] == 5 and rep["unknown"] == 0
