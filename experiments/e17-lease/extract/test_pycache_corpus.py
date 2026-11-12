import hashlib
import json
import os
import shutil
import statistics
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import pycache_corpus  # noqa: E402

GAPS = os.path.join(HERE, "testdata", "gaps-20.jsonl")
DRIVER = os.path.join(HERE, "..", "..", "..", "experiments", "e15-session-density", "driver")
DRIVER_FIXTURE = os.path.join(DRIVER, "testdata", "pycache-corpus.jsonl")
TURN_HEAD = ["py_analyze", "py_test", "py_import", "py_grep"]  # spec v0.4 §4.3


def gen(tmp_path, duty=0.095, sessions=40, seed=1, name="out", extra=()):
    out = tmp_path / name
    pycache_corpus.main(["--gaps-from", GAPS, "--duty", str(duty), "--sessions", str(sessions),
                         "--seed", str(seed), "--out", str(out), *extra])
    corpus = [json.loads(l) for l in (out / "corpus.jsonl").read_text().splitlines()]
    report = json.loads((out / "corpus-report.json").read_text())
    return out, corpus, report


def turns(classes):
    """Split a session's classes into turns; None when they do not follow the cycle."""
    out, k = [], 0
    while k < len(classes):
        if classes[k:k + len(TURN_HEAD)] != TURN_HEAD:
            return None
        j = k + len(TURN_HEAD)
        while j < len(classes) and classes[j] == "py_short":
            j += 1
        if j >= len(classes) or classes[j] != "py_analyze":
            return None
        out.append(j - k - len(TURN_HEAD))
        k = j + 1
    return out


def test_turn_order(tmp_path):
    # Spec v0.4 §4.3: py_analyze, py_test, py_import, py_grep, py_short x k (2 <= k <= 5), py_analyze.
    _, corpus, report = gen(tmp_path, duty=0.015)
    for s in corpus:
        ks = turns([c["class"] for c in s["calls"]])
        assert ks, s["session"]
        assert all(2 <= k <= 5 for k in ks), (s["session"], ks)
    per = report["calls_per_class"]
    assert set(per) == set(pycache_corpus.DUR_MS)
    assert per["py_import"] == per["py_grep"] == per["py_test"] == per["py_analyze"] // 2


def test_seed_is_deterministic(tmp_path):
    a, _, _ = gen(tmp_path, name="a")
    b, _, _ = gen(tmp_path, name="b")
    c, _, _ = gen(tmp_path, seed=2, name="c")
    assert (a / "corpus.jsonl").read_bytes() == (b / "corpus.jsonl").read_bytes()
    assert (a / "corpus.jsonl").read_bytes() != (c / "corpus.jsonl").read_bytes()


@pytest.mark.parametrize("duty", [0.095, 0.015])
def test_duty_is_met(tmp_path, duty):
    _, corpus, report = gen(tmp_path, duty=duty)
    assert report["sessions"] == len(corpus) == 40
    assert abs(report["duty_achieved"]["mean"] - duty) <= 0.2 * duty
    # The report's duty is E15's occupied / span, re-measured here from the written calls.
    for s in corpus:
        busy = sum(c["dur_ms"] for c in s["calls"])
        span = busy + sum(c["gap_ms"] for c in s["calls"])
        assert busy / span <= 1.2 * duty, s["session"]


@pytest.mark.parametrize("duty", [0.095, 0.015])
def test_min_turns(tmp_path, duty):
    # Spec §4.2: a session is a loop of turns, so warmth across turns is exercised. Default floor 4.
    _, corpus, report = gen(tmp_path, duty=duty)
    counts = []
    for s in corpus:
        ks = turns([c["class"] for c in s["calls"]])
        assert ks and len(ks) >= 4, (s["session"], ks)
        counts.append(len(ks))
    tps = report["turns_per_session"]
    assert (tps["min"], tps["max"]) == (min(counts), max(counts)) and tps["min"] >= 4
    assert tps["median"] == statistics.median(counts)
    spans = report["span_min"]
    assert 0 < spans["min"] <= spans["median"] <= spans["max"]


def test_min_turns_is_a_parameter(tmp_path):
    _, corpus, report = gen(tmp_path, extra=("--min-turns", "6"))
    assert all(len(turns([c["class"] for c in s["calls"]])) >= 6 for s in corpus)
    assert report["min_turns"] == 6


def test_schema_and_timeline(tmp_path):
    _, corpus, report = gen(tmp_path)
    want = {"py_analyze": 15000, "py_test": 60000, "py_import": 2000, "py_grep": 2200, "py_short": 300}
    users = set()
    for s in corpus:
        assert set(s) == {"session", "user", "provider", "calls"}
        assert s["provider"] == "synthetic"
        users.add(s["user"])
        calls = s["calls"]
        for n, c in enumerate(calls):
            assert set(c) == {"i", "class", "skeleton", "dur_ms", "work_ms", "gap_ms", "offset_ms",
                              "out_bytes", "chain"}
            assert c["i"] == n and c["chain"] is False
            assert c["dur_ms"] == c["work_ms"] == want[c["class"]]
            # offset_ms is from the previous call's emit (E15's replay timeline adds them up).
            assert c["offset_ms"] == (0 if n == 0 else calls[n - 1]["dur_ms"] + calls[n - 1]["gap_ms"])
        assert calls[-1]["gap_ms"] == 0
    assert users == {"pyc-u%02d" % u for u in range(40)}
    assert sum(report["calls_per_class"].values()) == sum(len(s["calls"]) for s in corpus)
    with open(GAPS, "rb") as f:
        assert report["gap_source_sha256"] == hashlib.sha256(f.read()).hexdigest()
    # the basename, so the report is byte-identical on the laptop and the rig
    assert report["gap_source"] == "gaps-20.jsonl"


def test_report_is_independent_of_the_gap_source_dir(tmp_path):
    for d in ("x", "y/z"):
        os.makedirs(tmp_path / d)
        shutil.copy(GAPS, tmp_path / d / "gaps-20.jsonl")
    reports = []
    for d in ("x", "y/z"):
        out = tmp_path / ("out-" + d.replace("/", "-"))
        pycache_corpus.main(["--gaps-from", str(tmp_path / d / "gaps-20.jsonl"), "--duty", "0.095",
                             "--sessions", "10", "--seed", "1", "--out", str(out)])
        reports.append((out / "corpus-report.json").read_bytes())
    assert reports[0] == reports[1]


def test_gaps_are_capped(tmp_path):
    for duty in (0.095, 0.015):
        _, corpus, _ = gen(tmp_path, duty=duty, name="d%s" % duty)
        assert max(c["gap_ms"] for s in corpus for c in s["calls"]) <= 1_800_000


def test_unmeetable_duty_fails(tmp_path, capsys):
    with pytest.raises(SystemExit) as e:
        gen(tmp_path, duty=0.0001)
    assert e.value.code not in (0, None)
    assert "duty" in capsys.readouterr().err


def test_schema_loads_in_e15_driver(tmp_path):
    # The committed driver fixture is exactly what the generator writes for these arguments.
    out, _, _ = gen(tmp_path, sessions=3)
    with open(DRIVER_FIXTURE, "rb") as f:
        assert f.read() == (out / "corpus.jsonl").read_bytes()
    if shutil.which("go") is None:
        pytest.skip("go is not on PATH")
    env = dict(os.environ)
    for k, v in (("GOPATH", "/tmp/gopath"), ("GOMODCACHE", "/tmp/gopath/pkg/mod"),
                 ("GOCACHE", "/tmp/gocache")):
        env.setdefault(k, v)
    r = subprocess.run(["go", "test", "-count=1", "-run", "^TestLoadCorpusAcceptsPycache$", "."],
                       cwd=DRIVER, env=env, capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "no tests to run" not in r.stdout


def test_gaps_already_at_cap_are_scaled_down():
    # A source gap equal to H is a draw like any other: at a high duty it must shrink, not pin the
    # session's idle time at H.
    gaps = pycache_corpus.fit([1_800_000, 1_000], 10_000)
    assert sum(gaps) == 10_000 and max(gaps) < 1_800_000


def cal_file(tmp_path, durations, name="cal.json"):
    path = tmp_path / name
    path.write_text(json.dumps(durations))
    return str(path)


def test_durations_from_overrides_dur_and_work(tmp_path):
    # After calibration the corpora carry the measured N=1 medians, never the placeholders.
    cal = {"py_analyze": 21000.4, "py_test": 55000, "py_import": 1980.6, "py_grep": 2150, "py_short": 450}
    path = cal_file(tmp_path, cal)
    _, base, base_report = gen(tmp_path, name="base")
    _, corpus, report = gen(tmp_path, name="cal", extra=("--durations-from", path))
    want = {"py_analyze": 21000, "py_test": 55000, "py_import": 1981, "py_grep": 2150, "py_short": 450}
    for s in corpus:
        for c in s["calls"]:
            assert c["dur_ms"] == c["work_ms"] == want[c["class"]]
        busy = sum(c["dur_ms"] for c in s["calls"])
        assert busy / (busy + sum(c["gap_ms"] for c in s["calls"])) <= 1.2 * 0.095
    # The same seed gives the same sessions and turns; only the durations and the scaled gaps move.
    assert [[c["class"] for c in s["calls"]] for s in corpus] == \
        [[c["class"] for c in s["calls"]] for s in base]
    assert report["durations_ms"] == want
    with open(path, "rb") as f:
        assert report["durations_from"] == {"file": "cal.json",
                                            "sha256": hashlib.sha256(f.read()).hexdigest()}
    assert base_report["durations_ms"] == {"py_analyze": 15000, "py_test": 60000, "py_import": 2000,
                                           "py_grep": 2200, "py_short": 300}
    assert base_report["durations_from"] is None


def test_durations_from_is_deterministic(tmp_path):
    path = cal_file(tmp_path, {"py_analyze": 18000, "py_test": 52000, "py_import": 1990, "py_grep": 2170,
                               "py_short": 410})
    a, _, _ = gen(tmp_path, name="a", extra=("--durations-from", path))
    b, _, _ = gen(tmp_path, name="b", extra=("--durations-from", path))
    assert (a / "corpus.jsonl").read_bytes() == (b / "corpus.jsonl").read_bytes()
    assert (a / "corpus-report.json").read_bytes() == (b / "corpus-report.json").read_bytes()


FIVE = {"py_analyze": 18000, "py_test": 52000, "py_import": 1990, "py_grep": 2170, "py_short": 410}


def with_(**kw):
    """FIVE with some classes replaced; a value of None drops the class."""
    d = dict(FIVE, **kw)
    return {k: v for k, v in d.items() if v is not None}


@pytest.mark.parametrize("durations", [
    with_(py_grep=None),                         # four classes: py_grep missing
    with_(py_import=None),                       # four classes: py_import missing
    with_(py_import=None, py_grep=None),         # the three pre-v0.4 classes
    with_(py_lint=1),                            # six classes: an unknown one
    with_(py_test=0),                            # not positive
    with_(py_grep=-5),                           # not positive
    with_(py_test="52000"),                      # not a number
    with_(py_analyze=True),                      # a bool is not a number
    list(FIVE.values()),                         # not an object
])
def test_durations_from_refuses_a_bad_file(tmp_path, capsys, durations):
    path = cal_file(tmp_path, durations)
    with pytest.raises(SystemExit) as e:
        gen(tmp_path, extra=("--durations-from", path))
    assert e.value.code == 1
    assert "pycache_corpus.py: --durations-from" in capsys.readouterr().err
