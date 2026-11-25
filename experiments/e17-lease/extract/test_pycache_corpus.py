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


# --- E17d (PLAN-E17D Task 3, spec §14.2): point pycache-l2, pycache's sessions with turns around the loaded frame ---
L2_CLASSES = {"py_requery", "py_refit", "py_short"}


def gen_l2(tmp_path, name="l2", sessions=40, seed=1, extra=()):
    out = tmp_path / name
    pycache_corpus.main(["--point", "pycache-l2", "--gaps-from", GAPS, "--duty", "0.095", "--sessions", str(sessions),
                         "--seed", str(seed), "--out", str(out), *extra])
    corpus = [json.loads(l) for l in (out / "corpus.jsonl").read_text().splitlines()]
    return out, corpus, json.loads((out / "corpus-report.json").read_text())


def l2_turns(classes):
    """A pycache-l2 session's turns as lists of classes, or None when they do not follow the shape: one py_requery,
    then 2-5 py_requery or py_short, then one py_refit."""
    out, k = [], 0
    while k < len(classes):
        try:
            j = classes.index("py_refit", k)
        except ValueError:
            return None
        t = classes[k:j + 1]
        if t[0] != "py_requery" or not 2 <= len(t) - 2 <= 5 or any(c not in ("py_requery", "py_short") for c in t[1:-1]):
            return None
        out.append(t)
        k = j + 1
    return out


def test_l2_turn_shape(tmp_path):
    _, corpus, report = gen_l2(tmp_path)
    mids = set()
    for s in corpus:
        ts = l2_turns([c["class"] for c in s["calls"]])
        assert ts, s["session"]
        mids.update(c for t in ts for c in t[1:-1])
        assert "tmpfs" not in s
    assert mids == {"py_requery", "py_short"}  # both drawn in the middle of a turn
    assert set(report["calls_per_class"]) == L2_CLASSES  # no py_analyze, py_test, py_import, py_grep (nor py_shmem)
    assert report["point"] == "pycache-l2"
    assert (report["tmpfs_share"], report["tmpfs_sessions"], report["py_shmem_ms"]) == (0.0, 0, None)


def test_l2_keeps_pycache_s_gap_draw_unscaled(tmp_path):
    # Each pycache-l2 session is pycache's session of the same seed and index with its turns rewritten: as many turns,
    # and its gaps are pycache's gaps in order (fewer calls take a prefix), not re-fitted to any duty. So the duty is
    # lower than pycache's, and the report says what it achieved.
    _, pc, prep = share0(tmp_path, duty=0.095)
    _, l2, lrep = gen_l2(tmp_path)
    assert len(pc) == len(l2) == 40
    for a, b in zip(pc, l2):
        assert b["session"] == a["session"].replace("pycache:", "pycache-l2:") and b["user"] == a["user"]
        assert len(l2_turns([c["class"] for c in b["calls"]])) == sum(c["class"] == "py_test" for c in a["calls"])
        ga, gb = [c["gap_ms"] for c in a["calls"]], [c["gap_ms"] for c in b["calls"]]
        assert gb[:-1] == ga[:len(gb) - 1] and gb[-1] == 0
    assert lrep["duty_achieved"]["mean"] < prep["duty_achieved"]["mean"]
    assert lrep["gaps_from_point"] == "pycache" and lrep["duty_target"] == 0.095


def test_l2_durations_and_offsets(tmp_path):
    _, corpus, report = gen_l2(tmp_path)
    assert report["durations_ms"] == pycache_corpus.L2_DUR_MS
    for s in corpus:
        prev = None
        for c in s["calls"]:
            assert c["dur_ms"] == c["work_ms"] == pycache_corpus.L2_DUR_MS[c["class"]]
            assert c["offset_ms"] == (0 if prev is None else prev["dur_ms"] + prev["gap_ms"])
            prev = c


def test_l2_has_its_own_hash(tmp_path):
    a, _, ra = gen_l2(tmp_path, name="a")
    b, _, rb = gen_l2(tmp_path, name="b")
    _, _, rp = share0(tmp_path, duty=0.095)
    assert (a / "corpus.jsonl").read_bytes() == (b / "corpus.jsonl").read_bytes()
    assert ra["corpus_sha256"] == sha256_of(a / "corpus.jsonl") != rp["corpus_sha256"]


def test_l2_durations_from_accepts_exactly_its_classes(tmp_path, capsys):
    good = tmp_path / "l2cal.json"
    good.write_text(json.dumps({"py_requery": 6400.4, "py_refit": 17100, "py_short": 410}))
    _, corpus, report = gen_l2(tmp_path, extra=("--durations-from", str(good)))
    assert report["durations_ms"] == {"py_requery": 6400, "py_refit": 17100, "py_short": 410}
    assert {c["dur_ms"] for s in corpus for c in s["calls"] if c["class"] == "py_refit"} == {17100}
    pc = tmp_path / "pccal.json"
    pc.write_text(json.dumps({"py_analyze": 1, "py_test": 1, "py_import": 1, "py_grep": 1, "py_short": 1}))
    for bad in (pc, tmp_path / "partial.json"):
        if bad.name == "partial.json":
            bad.write_text(json.dumps({"py_requery": 1, "py_refit": 1}))
        with pytest.raises(SystemExit) as e:
            gen_l2(tmp_path, name="bad", extra=("--durations-from", str(bad)))
        assert e.value.code == 1
        assert "are not exactly" in capsys.readouterr().err
    # and pycache's own --durations-from still refuses the level-2 classes
    with pytest.raises(SystemExit):
        share0(tmp_path, name="pcbad", extra=("--durations-from", str(good)))


def test_l2_gap_durations_from_follows_pycache_s(tmp_path):
    # pycache's gaps depend on the durations its duty fit used; --gap-durations-from gives the fit pycache's own
    # calibrated ones (results/calibration), so the gaps are those of the pycache corpus built with them.
    _, pc, _ = share0(tmp_path, duty=0.095, extra=("--durations-from", CALIBRATION))
    _, l2, _ = gen_l2(tmp_path, extra=("--gap-durations-from", CALIBRATION))
    for a, b in zip(pc, l2):
        gb = [c["gap_ms"] for c in b["calls"]]
        assert gb[:-1] == [c["gap_ms"] for c in a["calls"]][:len(gb) - 1]


def test_l2_refuses_a_tmpfs_share(tmp_path, capsys):
    with pytest.raises(SystemExit) as e:
        gen_l2(tmp_path, extra=("--tmpfs-share", "0.5"))
    assert e.value.code == 2 and "pycache-l2" in capsys.readouterr().err


def test_pycache_point_is_the_default_and_unchanged(tmp_path):
    a, _, _ = share0(tmp_path, name="dflt", duty=0.095)
    b, _, _ = share0(tmp_path, name="named", duty=0.095, extra=("--point", "pycache"))
    assert (a / "corpus.jsonl").read_bytes() == (b / "corpus.jsonl").read_bytes()


GEN = os.path.join(HERE, "..", "rig", "gen_corpora.sh")


def run_gen(tmp_path, env_extra, *args):
    env = {k: v for k, v in os.environ.items() if k not in ("E17B", "E17C", "E17D")}
    env.update(E17_GAPS=GAPS, E17_CORPORA=str(tmp_path / "corpora"), E17_PYTHON=sys.executable, **env_extra)
    return subprocess.run(["bash", GEN, *args], env=env, capture_output=True, text=True)


def test_gen_corpora_writes_pycache_l2_under_e17d_only(tmp_path):
    l2cal = tmp_path / "l2cal.json"
    l2cal.write_text(json.dumps({"py_requery": 6000, "py_refit": 17000, "py_short": 400}))
    r = run_gen(tmp_path, {"E17C": "1"})
    assert r.returncode == 0, r.stderr
    assert not (tmp_path / "corpora" / "pycache-l2").exists()  # E17D unset: E17c's corpora only
    r = run_gen(tmp_path, {"E17C": "1"}, "--l2-durations-from", str(l2cal))
    assert r.returncode == 2 and "E17D=1" in r.stderr
    r = run_gen(tmp_path, {"E17D": "1"}, "--durations-from", CALIBRATION, "--l2-durations-from", str(l2cal))
    assert r.returncode == 0, r.stderr
    rep = json.loads((tmp_path / "corpora" / "pycache-l2" / "corpus-report.json").read_text())
    pc = [json.loads(l) for l in (tmp_path / "corpora" / "pycache" / "corpus.jsonl").read_text().splitlines()]
    l2 = [json.loads(l) for l in (tmp_path / "corpora" / "pycache-l2" / "corpus.jsonl").read_text().splitlines()]
    assert (rep["point"], rep["sessions"], rep["durations_ms"], rep["tmpfs_share"]) == (
        "pycache-l2", 400, {"py_requery": 6000, "py_refit": 17000, "py_short": 400}, 0.0)
    assert rep["gap_durations_from"]["file"] == os.path.basename(CALIBRATION)
    # its gaps are the staged pycache corpus's (that one has py_shmem readings, which take over a py_analyze's gap:
    # compare against pycache's own fit, the corpus without them)
    for a, b in zip(pc, l2):
        ga = []
        for c in a["calls"]:
            if c["class"] == "py_shmem":
                ga[-1] = c["gap_ms"]
            else:
                ga.append(c["gap_ms"])
        gb = [c["gap_ms"] for c in b["calls"]]
        assert gb[:-1] == ga[:len(gb) - 1]
    r = run_gen(tmp_path, {"E17D": "1"})
    assert r.returncode == 0 and "pycache-l2 has placeholder durations" in r.stderr, r.stderr


def test_l2_driver_fixture_is_the_generator_s(tmp_path):
    out, _, _ = gen_l2(tmp_path, name="fix", sessions=3)
    with open(os.path.join(DRIVER, "testdata", "pycache-l2-corpus.jsonl"), "rb") as f:
        assert f.read() == (out / "corpus.jsonl").read_bytes()
