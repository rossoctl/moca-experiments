import gzip
import hashlib
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))

import duty_band
from duty_band import duty


def mk_calls(offsets, durs, work=None):
    work = work or durs
    return [{"i": i, "class": "shell_read", "offset_ms": o, "dur_ms": d, "work_ms": w,
             "gap_ms": 0} for i, (o, d, w) in enumerate(zip(offsets, durs, work))]


def session(sid, user, provider, calls):
    return {"session": sid, "user": user, "provider": provider, "calls": calls}


def with_duty(busy_ms, span_ms=100_000):
    """Two calls: one of busy_ms at 0, one of 0 ms ending the span."""
    return mk_calls([0, span_ms], [busy_ms, 0])


def write(path, sessions, gz=False):
    data = "".join(json.dumps(s, separators=(",", ":")) + "\n" for s in sessions).encode()
    if gz:
        with gzip.open(path, "wb") as f:
            f.write(data)
    else:
        path.write_bytes(data)
    return hashlib.sha256(data).hexdigest()


def run(tmp_path, sessions, gz=False, lo=0.01, hi=0.02):
    src = tmp_path / ("in.jsonl.gz" if gz else "in.jsonl")
    digest = write(src, sessions, gz)
    out = tmp_path / "out"
    duty_band.main(["--in", str(src), "--out", str(out), "--duty-min", str(lo),
                    "--duty-max", str(hi)])
    kept = [json.loads(l) for l in (out / "corpus.jsonl").read_text().splitlines()]
    report = json.loads((out / "corpus-report.json").read_text())
    return kept, report, digest


def test_duty_matches_e15_timeline():
    calls = mk_calls([0, 10000, 5000], [1000, 1000, 2000])
    assert duty(calls) == (1000 + 1000 + 2000) / 17000


def test_zero_span_is_none(tmp_path):
    calls = mk_calls([0], [0])
    assert duty(calls) is None
    kept, report, _ = run(tmp_path, [session("z", "u1", "claude", calls),
                                     session("a", "u1", "claude", with_duty(1500))])
    assert [s["session"] for s in kept] == ["a"]
    assert report["sessions"] == 1


def test_band_edges(tmp_path):
    ss = [session("d010", "u1", "claude", with_duty(1000)),
          session("d015", "u1", "claude", with_duty(1500)),
          session("d020", "u1", "claude", with_duty(2000)),
          session("d0201", "u1", "claude", with_duty(2010))]
    assert duty(ss[0]["calls"]) == 0.01 and duty(ss[2]["calls"]) == 0.02
    kept, _, _ = run(tmp_path, ss)
    assert [s["session"] for s in kept] == ["d015", "d020"]


def test_report_counts(tmp_path):
    ss = [session("a", "u1", "claude", with_duty(1500)),
          session("b", "u2", "codex", with_duty(1200)),
          session("c", "u1", "codex", with_duty(1800)),
          session("x", "u3", "claude", with_duty(5000))]
    kept, report, digest = run(tmp_path, ss, gz=True)
    assert kept == ss[:3]  # input order, unchanged
    assert report["source_sha256"] == digest
    assert report["duty_min"] == 0.01 and report["duty_max"] == 0.02
    assert report["sessions"] == 3
    assert report["users"] == 2
    assert report["top_user_share"] == 2 / 3
    assert report["by_provider"] == {"claude": 1, "codex": 2}
    assert report["occupied_pct"] == 100 * (1500 + 1200 + 1800) / 300_000
    assert report["work_pct"] == 100 * (1500 + 1200 + 1800) / 300_000
    assert report["calls_per_s_per_session"] == 6 / 300
    assert report["mean_span_h"] == 100_000 / 3_600_000
