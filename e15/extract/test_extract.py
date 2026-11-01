import json

import pytest

from conftest import call, pad
import extract
from classes import CLASSES, EXECUTABLE_CLASSES, TOOL_CLASSES, classify

H5 = 5 * 3600 * 1000


def run(make_db, calls, H=1800, exclude=None, name="fixture.duckdb", skip=True, out=None):
    db = make_db(calls, name=name)
    out = out or db.parent / "out"
    argv = ["--db", str(db), "--H", str(H), "--out", str(out)]
    if skip:
        argv.append("--skip-sha-check")
    if exclude:
        argv += ["--exclude", exclude]
    extract.main(argv)
    corpus = {}
    for line in (out / "corpus.jsonl").read_text().splitlines():
        s = json.loads(line)
        corpus[s["session"]] = s
    report = json.loads((out / "corpus-report.json").read_text())
    return corpus, report


def test_refuses_wrong_sha(make_db, tmp_path):
    db = make_db(pad("s", 20, 0))
    with pytest.raises(SystemExit, match="sha256"):
        extract.main(["--db", str(db), "--H", "1800", "--out", str(tmp_path / "out")])


def test_skip_sha_check_refused_for_real_db_name(make_db):
    with pytest.raises(SystemExit, match="skip-sha-check"):
        run(make_db, pad("s", 20, 0), name="syfi_coding_trace.duckdb")


def test_classify_skips_plumbing():
    assert classify("Bash", ["cd", "echo", "pytest"]) == "test"
    assert classify("exec_command", ["custom_7"]) == "opaque"
    assert classify("Read", []) == "read"
    assert classify("Bash", []) == "unparsed"
    assert classify("exec_command", None) == "unparsed"
    assert classify("Bash", ["echo", "tee"]) == "other"  # all plumbing: first one as is
    assert classify("Bash", ["timeout", "docker", "grep"]) == "host_infra"
    assert classify("apply_patch", None) == "write"
    assert classify("Glob", None) == "search"


def test_class_set_is_complete():
    mapped = set(TOOL_CLASSES.values()) | set(EXECUTABLE_CLASSES.values())
    assert mapped | {"opaque", "unparsed", "other"} == set(CLASSES)
    assert len(CLASSES) == 17


def chain(session, end, internal=2000):
    return [
        call(session, "exec_command", emit=0, wall=internal + 100, internal=internal, id="c1",
             exes=["python-script"], chars=100),
        call(session, "write_stdin", emit=10_000, wall=600, internal=500, cont="c1", exes=None,
             chars=20),
        call(session, "write_stdin", emit=end - 1000, wall=1000, internal=500, result_at=end,
             cont="c1", exes=None, chars=30),
    ]


def test_chain_collapses(make_db):
    corpus, report = run(make_db, chain("s", 60_000) + pad("s", 20, 100_000))
    calls = corpus["s"]["calls"]
    assert len(calls) == 21  # the two polls are not calls
    c = calls[0]
    assert (c["chain"], c["dur_ms"], c["work_ms"], c["class"]) == (True, 60_000, 3000,
                                                                     "interpreter")
    assert c["out_bytes"] == 150
    assert not any(x["chain"] for x in calls[1:])
    assert report["chains_collapsed"] == 1
    assert report["chains_capped"] == 0


def test_chain_cap(make_db):
    three_days = 3 * 24 * 3600 * 1000
    corpus, report = run(make_db, chain("s", three_days) + pad("s", 20, three_days + 1000))
    c = corpus["s"]["calls"][0]
    assert (c["dur_ms"], c["work_ms"]) == (7_200_000, 3000)
    assert report["chains_capped"] == 1


def test_chain_links_stay_within_session(make_db):
    # A second session reuses the tool_call_id (TraceLab has two such sessions); its poll must
    # not stretch the first session's chain.
    calls = chain("a", 60_000) + pad("a", 20, 100_000)
    calls += chain("b", H5) + pad("b", 20, H5 + 1000)
    corpus, report = run(make_db, calls)
    assert corpus["a"]["calls"][0]["dur_ms"] == 60_000
    assert corpus["b"]["calls"][0]["dur_ms"] == 7_200_000
    assert report["chains_collapsed"] == 2


def test_caps_by_provider(make_db):
    calls = [call("cl", "Bash", emit=0, wall=90_000)] + pad("cl", 20, 100_000, tool="Bash")
    calls += [call("cx", "exec_command", emit=0, wall=201_000, internal=200_000)]
    calls += [call("cx", "exec_command", emit=300_000, wall=5000, internal=0)]  # 0 → wall
    calls += pad("cx", 19, 400_000)
    corpus, report = run(make_db, calls)
    cl, cx = corpus["cl"]["calls"], corpus["cx"]["calls"]
    assert (cl[0]["dur_ms"], cl[0]["work_ms"]) == (30_000, 30_000)
    assert (cx[0]["dur_ms"], cx[0]["work_ms"]) == (120_000, 120_000)
    assert cx[1]["dur_ms"] == 5000
    assert report["dur_capped"] == {"claude": 1, "codex": 1}
    assert report["by_provider"] == {"claude": 1, "codex": 1}


def test_gap_cap_and_offsets(make_db):
    calls = [call("s", emit=0, wall=100), call("s", emit=H5, wall=100)] + pad("s", 18, H5 + 1000)
    corpus, report = run(make_db, calls, H=1800)
    a, b = corpus["s"]["calls"][:2]
    assert a["gap_ms"] == 1_800_000
    assert (a["offset_ms"], b["offset_ms"]) == (0, a["dur_ms"] + 1_800_000)
    assert b["gap_ms"] == 900  # emit H5, end H5+100, next emit H5+1000
    assert report["gap_capped"] == 1
    assert corpus["s"]["calls"][-1]["gap_ms"] == 0
    assert [c["i"] for c in corpus["s"]["calls"]] == list(range(20))


def test_overlap_keeps_recorded_offset(make_db):
    calls = [call("s", emit=0, wall=5000), call("s", emit=1000, wall=100)] + pad("s", 18, 10_000)
    corpus, _ = run(make_db, calls)
    a, b = corpus["s"]["calls"][:2]
    assert (a["gap_ms"], b["offset_ms"]) == (0, 1000)


def test_session_floor(make_db):
    calls = pad("short", 19, 0) + pad("long", 20, 0)
    calls += [call("short", "WebFetch", emit=50_000, exes=None)]  # not replayed: no lift
    corpus, report = run(make_db, calls)
    assert set(corpus) == {"long"}
    assert report["dropped_lt20"] == 1
    assert report["sessions"] == 1


def test_exclude_infra(make_db):
    calls = [call("infra", emit=0, exes=["cd", "docker"])] + pad("infra", 19, 1000)
    calls += pad("plain", 20, 0)
    corpus, report = run(make_db, calls)
    assert set(corpus) == {"infra", "plain"}
    assert (report["infra_calls"], report["infra_sessions"]) == (1, 1)
    corpus, report = run(make_db, calls, exclude="infra", name="excl.duckdb")
    assert set(corpus) == {"plain"}
    assert report["sessions"] == 1


def test_exclude_chains(make_db):
    calls = chain("ch", 60_000) + pad("ch", 20, 100_000) + pad("plain", 20, 0)
    corpus, _ = run(make_db, calls, exclude="chains")
    assert set(corpus) == {"plain"}


def test_corpus_line_fields(make_db):
    calls = pad("s", 20, 0, user="dev7", tool="Bash", exes=["git", "grep"], chars=42, error=True)
    corpus, report = run(make_db, calls)
    s = corpus["s"]
    assert (s["user"], s["provider"]) == ("dev7", "claude")
    assert s["calls"][0] == {"i": 0, "class": "vcs", "skeleton": "git | grep", "dur_ms": 100,
                             "work_ms": 100, "gap_ms": 900, "offset_ms": 0, "out_bytes": 42,
                             "chain": False}
    assert report["errored"] == 20


def test_table(make_db):
    # 20 calls of 1 s each, 1 s apart, except one 400 s gap (over T300, under H).
    emits, t = [], 0
    for k in range(20):
        emits.append(t)
        t += 1000 + (400_000 if k == 9 else 1000)
    calls = [call("s", "Bash", emit=e, wall=1000) for e in emits]
    _, report = run(make_db, calls, H=1800)
    span = 20 * 1000 + 18 * 1000 + 400_000  # last call has no gap
    tb = report["table"]
    assert tb["occupied_pct"] == pytest.approx(100 * 20_000 / span, abs=1e-3)
    assert tb["work_pct"] == pytest.approx(100 * 20_000 / span, abs=1e-3)
    assert tb["calls_per_s"] == pytest.approx(20 / (span / 1000), abs=1e-5)
    assert tb["held_t300_pct"] == pytest.approx(100 * (20_000 + 18_000 + 300_000) / span,
                                                abs=1e-3)
    assert tb["wakes_per_session_h"] == pytest.approx(1 / (span / 3_600_000), abs=1e-3)
    assert tb["mean_span_min"] == pytest.approx(span / 60_000, abs=1e-3)
    assert report["H_s"] == 1800
