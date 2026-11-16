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
DRIVER_FIXTURE = os.path.join(DRIVER, "testdata", "pycache-corpus.jsonl")  # E17a: --tmpfs-share 0
DRIVER_FIXTURE_TMPFS = os.path.join(DRIVER, "testdata", "pycache-corpus-tmpfs.jsonl")  # E17b: the default
TURN_HEAD = ["py_analyze", "py_test", "py_import", "py_grep"]  # spec v0.4 §4.3
CALIBRATION = os.path.join(HERE, "..", "results", "calibration", "durations-v0.4.json")
# sha256 of corpus.jsonl from the E17a generator (commit 76a0d39, e17/extract/pycache_corpus.py) on the
# committed inputs: gaps-20.jsonl, --sessions 400 --seed 1 --min-turns 4 --durations-from
# durations-v0.4.json, at each corpus's duty. Computed by running that commit's generator.
E17A_GAPS20_SHA256 = {
    0.095: "6f90fac44d3b58734a9867e768d6297b0b534f0ef40901e4965e005b00614520",
    0.015: "0c739a6c0c31e1de4caa14b9bb59ee132172ec9663ac011b8c68ae9ffb184b98",
}
# The rig's gap source (E15's default corpus) and the staged E17a corpora's committed reports.
RIG_GAPS = os.environ.get("E17_GAPS", "/tmp/kagenti/e16-corpus-default/corpus.jsonl")
RIG_GAPS_SHA256 = "24050ae8ac96b4cd25e211ebaa961333009bdc6fa083b667909f1ae3ce8a3132"
E17A_REPORTS = {0.095: os.path.join(HERE, "..", "results", "corpus", "pycache-report.json"),
                0.015: os.path.join(HERE, "..", "results", "corpus", "pycache-low-report.json")}


def gen(tmp_path, duty=0.095, sessions=40, seed=1, name="out", extra=(), share="0.5"):
    """The E17b corpus (--tmpfs-share 0.5, as gen_corpora.sh passes under E17B=1) unless extra names a share;
    share=None runs the generator with its own default."""
    out = tmp_path / name
    if share is not None and "--tmpfs-share" not in extra:
        extra = ("--tmpfs-share", share) + tuple(extra)
    pycache_corpus.main(["--gaps-from", GAPS, "--duty", str(duty), "--sessions", str(sessions),
                         "--seed", str(seed), "--out", str(out), *extra])
    corpus = [json.loads(l) for l in (out / "corpus.jsonl").read_text().splitlines()]
    report = json.loads((out / "corpus-report.json").read_text())
    return out, corpus, report


def turns(classes, shmem=True):
    """Split a session's classes into turns; None when they do not follow the cycle. With shmem,
    every turn closes with py_shmem after its last py_analyze (the E17b corpus); without, never."""
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
        if shmem:
            if k >= len(classes) or classes[k] != "py_shmem":
                return None
            k += 1
    return out


def share0(tmp_path, name="e17a", **kw):
    return gen(tmp_path, name=name, extra=("--tmpfs-share", "0") + tuple(kw.pop("extra", ())), **kw)


def test_turn_order(tmp_path):
    # Spec v0.4 §4.3: py_analyze, py_test, py_import, py_grep, py_short x k (2 <= k <= 5), py_analyze.
    # E17b (--tmpfs-share 0.5) closes every turn with py_shmem; --tmpfs-share 0 never.
    for shmem, (_, corpus, report) in ((True, gen(tmp_path, duty=0.015)),
                                       (False, share0(tmp_path, duty=0.015))):
        for s in corpus:
            ks = turns([c["class"] for c in s["calls"]], shmem)
            assert ks, s["session"]
            assert all(2 <= k <= 5 for k in ks), (s["session"], ks)
        per = report["calls_per_class"]
        assert set(per) == set(pycache_corpus.DUR_MS) | ({"py_shmem"} if shmem else set())
        assert per["py_import"] == per["py_grep"] == per["py_test"] == per["py_analyze"] // 2
        assert per.get("py_shmem", 0) == (per["py_test"] if shmem else 0)


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
    want = {"py_analyze": 15000, "py_test": 60000, "py_import": 2000, "py_grep": 2200, "py_short": 300,
            "py_shmem": 100}
    users = set()
    for s in corpus:
        assert set(s) == {"session", "user", "provider", "tmpfs", "calls"}
        assert isinstance(s["tmpfs"], bool)
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
    # The committed driver fixtures are exactly what the generator writes for these arguments: the
    # E17a one at --tmpfs-share 0, the E17b one at 0.5.
    out, _, _ = share0(tmp_path, sessions=3)
    with open(DRIVER_FIXTURE, "rb") as f:
        assert f.read() == (out / "corpus.jsonl").read_bytes()
    out, _, _ = gen(tmp_path, sessions=3, name="e17b")
    with open(DRIVER_FIXTURE_TMPFS, "rb") as f:
        assert f.read() == (out / "corpus.jsonl").read_bytes()
    if shutil.which("go") is None:
        pytest.skip("go is not on PATH")
    env = dict(os.environ)
    for k, v in (("GOPATH", "/tmp/gopath"), ("GOMODCACHE", "/tmp/gopath/pkg/mod"),
                 ("GOCACHE", "/tmp/gocache")):
        env.setdefault(k, v)
    r = subprocess.run(["go", "test", "-count=1", "-run", "^TestLoadCorpusAcceptsPycache", "."],
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
    # py_shmem is not calibrated: it keeps its planned SHMEM_MS (reported only, never gated).
    for s in corpus:
        for c in s["calls"]:
            assert c["dur_ms"] == c["work_ms"] == dict(want, py_shmem=pycache_corpus.SHMEM_MS)[c["class"]]
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


def tmpfs_count(corpus):
    return sum(s["tmpfs"] for s in corpus)


def test_tmpfs_share_fraction(tmp_path):
    # Spec §7.3: a seeded fraction tmpfs_share of the sessions keeps its caches in guest tmpfs.
    _, a, ra = gen(tmp_path, sessions=400, name="a", extra=("--tmpfs-share", "0.5"))
    _, b, rb = gen(tmp_path, sessions=400, name="b", extra=("--tmpfs-share", "0.5"))
    n = tmpfs_count(a)
    assert n == tmpfs_count(b)
    assert [s["tmpfs"] for s in a] == [s["tmpfs"] for s in b]
    assert abs(n - 200) <= 0.05 * 200
    assert (ra["tmpfs_share"], ra["tmpfs_sessions"]) == (0.5, n) == (rb["tmpfs_share"], rb["tmpfs_sessions"])
    # The E17b share (0.5) is the parameter gen() passes; a different seed flags different sessions.
    _, d, rd = gen(tmp_path, sessions=400, name="d")
    assert [s["tmpfs"] for s in d] == [s["tmpfs"] for s in a] and rd["tmpfs_share"] == 0.5
    _, q, _ = gen(tmp_path, sessions=400, name="q", extra=("--tmpfs-share", "0.25"))
    assert abs(tmpfs_count(q) - 100) <= 0.05 * 100
    _, c, _ = gen(tmp_path, sessions=400, seed=2, name="c")
    assert [s["tmpfs"] for s in c] != [s["tmpfs"] for s in a]
    _, one, _ = gen(tmp_path, sessions=400, name="one", extra=("--tmpfs-share", "1"))
    assert tmpfs_count(one) == 400


@pytest.mark.parametrize("share", ["-0.1", "1.5", "nan"])
def test_tmpfs_share_out_of_range_refused(tmp_path, share, capsys):
    with pytest.raises(SystemExit) as e:
        gen(tmp_path, extra=("--tmpfs-share", share))
    assert e.value.code not in (0, None)
    assert "--tmpfs-share must be in [0, 1]" in capsys.readouterr().err


def sha256_of(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


@pytest.mark.parametrize("duty", [0.095, 0.015])
def test_corpus_unchanged_with_share_zero(tmp_path, duty):
    # Ruling: --tmpfs-share 0 writes the E17a corpus byte for byte (no tmpfs field, no py_shmem).
    out, corpus, report = share0(tmp_path, duty=duty, sessions=400,
                                 extra=("--min-turns", "4", "--durations-from", CALIBRATION))
    assert sha256_of(out / "corpus.jsonl") == E17A_GAPS20_SHA256[duty] == report["corpus_sha256"]
    assert all("tmpfs" not in s for s in corpus)
    assert not any(c["class"] == "py_shmem" for s in corpus for c in s["calls"])
    assert (report["tmpfs_share"], report["tmpfs_sessions"], report["py_shmem_ms"]) == (0.0, 0, None)


@pytest.mark.parametrize("duty", [0.095, 0.015])
def test_corpus_unchanged_with_share_zero_on_the_rig_gap_source(tmp_path, duty):
    # The staged E17a corpora themselves (results/corpus/*-report.json corpus_sha256), regenerated from
    # the rig's gap source: run where E17_GAPS holds it (the laptop has only gaps-20.jsonl).
    if not os.path.isfile(RIG_GAPS) or sha256_of(RIG_GAPS) != RIG_GAPS_SHA256:
        pytest.skip("the E15 default corpus (sha256 %s...) is not at E17_GAPS=%s" % (RIG_GAPS_SHA256[:12], RIG_GAPS))
    with open(E17A_REPORTS[duty]) as f:
        want = json.load(f)
    out = tmp_path / "rig"
    pycache_corpus.main(["--gaps-from", RIG_GAPS, "--duty", str(duty), "--sessions", "400", "--seed", "1",
                         "--min-turns", "4", "--durations-from", CALIBRATION, "--tmpfs-share", "0",
                         "--out", str(out)])
    assert sha256_of(out / "corpus.jsonl") == want["corpus_sha256"]


def test_py_shmem_in_every_turn(tmp_path):
    # Every turn ends with exactly one py_shmem, sent back to back after the turn's last py_analyze
    # (whose gap moves to the py_shmem call), so the reading is the guest's Shmem right after the
    # heavy call. Apart from those calls the E17b corpus is the E17a one: same sessions, classes,
    # durations and idle time.
    _, e17b, report = gen(tmp_path, duty=0.095, sessions=40)
    _, e17a, _ = share0(tmp_path, duty=0.095, sessions=40)
    assert report["py_shmem_ms"] == pycache_corpus.SHMEM_MS == 100
    for b, a in zip(e17b, e17a):
        calls = b["calls"]
        classes = [c["class"] for c in calls]
        assert classes.count("py_shmem") == classes.count("py_test") == len(turns(classes))
        for n, c in enumerate(calls):
            if c["class"] != "py_shmem":
                continue
            prev = calls[n - 1]
            assert prev["class"] == "py_analyze" and calls[n - 2]["class"] == "py_short", (b["session"], n)
            assert prev["gap_ms"] == 0
            assert c["offset_ms"] == prev["dur_ms"]
            assert c["dur_ms"] == c["work_ms"] == pycache_corpus.SHMEM_MS and c["chain"] is False
        assert calls[-1]["class"] == "py_shmem" and calls[-1]["gap_ms"] == 0
        # remove the readings: the E17a session, gap for gap
        merged = []
        for c in calls:
            if c["class"] == "py_shmem":
                merged[-1] = dict(merged[-1], gap_ms=merged[-1]["gap_ms"] + c["gap_ms"])
            else:
                merged.append(c)
        key = lambda c: (c["class"], c["skeleton"], c["dur_ms"], c["work_ms"], c["gap_ms"])  # noqa: E731
        assert [key(c) for c in merged] == [key(c) for c in a["calls"]]
        assert (b["session"], b["user"], b["provider"]) == (a["session"], a["user"], a["provider"])
    # the readings add their own busy time only: the duty stays within the fit's tolerance
    assert abs(report["duty_achieved"]["mean"] - 0.095) <= 0.2 * 0.095


def test_default_tmpfs_share_is_e17a(tmp_path):
    # PR #34 nit (E17B-R41g): the generator's own default is E17a's (0), so PLAN.md's E17a command as written still
    # writes the E17a corpus byte for byte; gen_corpora.sh passes 0.5 under E17B=1.
    assert pycache_corpus.TMPFS_SHARE == 0
    out, corpus, report = gen(tmp_path, name="default", share=None)
    e17a, _, _ = share0(tmp_path)
    assert (out / "corpus.jsonl").read_bytes() == (e17a / "corpus.jsonl").read_bytes()
    assert report["tmpfs_share"] == 0.0 and all("tmpfs" not in s for s in corpus)
    # fix round 2, minor 3: the report records the default as 0.0, as an explicit --tmpfs-share 0 does
    assert isinstance(report["tmpfs_share"], float)
    assert json.loads((e17a / "corpus-report.json").read_text())["tmpfs_share"] == report["tmpfs_share"]
    assert '"tmpfs_share": 0.0' in (out / "corpus-report.json").read_text()
