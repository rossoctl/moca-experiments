"""Checks for E17's pycache workspace template and command library (PLAN Task 2).

Run: /tmp/kagenti/e17-venv/bin/python -m pytest -q experiments/e17-lease/workload

Every check stages a template with build_pycache_workspace.sh --dir (any OS, no root, no venv:
the venv needs the guest's Python 3.9 and is built in a rootfs chroot on the rig). The checks that
run analyze.py or the project's tests use this interpreter (it must have numpy, pandas and
scikit-learn; skipped otherwise) behind a venv/bin/python shim, so the library's exact command
strings run unchanged. The wheel check uses the downloaded cp39 wheels when E17_WHEELS (default
/tmp/kagenti/e17-wheels-probe) holds them.
"""

import hashlib
import importlib.util
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys

import pytest

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SCRIPT = HERE / "build_pycache_workspace.sh"
LIBRARY = HERE / "library.json"
LOCK = HERE / "wheels.lock"
DRIVER = ROOT / "e15-session-density" / "driver"
WHEELS = pathlib.Path(os.environ.get("E17_WHEELS", "/tmp/kagenti/e17-wheels-probe"))
SHARD_MIB = 32
CLASSES = {"py_analyze", "py_test", "py_import", "py_grep", "py_short", "py_shmem"}
SHMEM_CMD = "awk '/^Shmem:/{print $2}' /proc/meminfo"

sys.path.insert(0, str(ROOT / "e17-lease" / "extract"))
import pycache_corpus  # noqa: E402


def stage(out, *args, check=True):
    r = subprocess.run(["bash", str(SCRIPT), *args, "--dir", str(out)], capture_output=True, text=True)
    if check:
        assert r.returncode == 0, r.stderr
    return r


def shards(ws):
    return sorted((ws / "data").glob("shard-*.csv"))


def shard_sha256(ws):
    h = hashlib.sha256()
    for p in shards(ws):
        h.update(p.read_bytes())
    return h.hexdigest()


def build_field(ws, key):
    for line in (ws / "BUILD").read_text().splitlines():
        if line.startswith(key + ": "):
            return line[len(key) + 2:]
    raise KeyError(key)


def library():
    return json.loads(LIBRARY.read_text())


def lock_entries():
    out = []
    for line in LOCK.read_text().splitlines():
        if line.strip() and not line.startswith("#"):
            sha, name = line.split()
            out.append((sha, name))
    return out


def need_stack():
    for m in ("numpy", "pandas", "sklearn"):
        if importlib.util.find_spec(m) is None:
            pytest.skip(f"{m} is not importable by {sys.executable}")


def shim_venv(ws):
    """ws/venv/bin/python execs this interpreter, so `../venv/bin/python` resolves in a staging."""
    b = ws / "venv" / "bin"
    b.mkdir(parents=True)
    (b / "python").write_text(f'#!/bin/sh\nexec "{sys.executable}" "$@"\n')
    (b / "python").chmod(0o755)


def run_cmd(ws, cmd, env=None):
    return subprocess.run(["bash", "-c", cmd], cwd=ws, capture_output=True, text=True,
                          env=dict(os.environ, **(env or {})))


def test_dataset_is_deterministic(tmp_path):
    d = 40  # one full 32 MiB shard and one partial
    stage(tmp_path / "a", "--dataset-mib", str(d), "--dataset-seed", "1")
    stage(tmp_path / "b", "--dataset-mib", str(d), "--dataset-seed", "1")
    a, b = shards(tmp_path / "a"), shards(tmp_path / "b")
    assert [p.name for p in a] == ["shard-000.csv", "shard-001.csv"]
    assert [p.name for p in b] == [p.name for p in a]
    for x, y in zip(a, b):
        assert x.read_bytes() == y.read_bytes(), x.name
    total = sum(p.stat().st_size for p in a)
    assert abs(total - (d << 20)) <= SHARD_MIB << 20
    assert a[0].stat().st_size <= SHARD_MIB << 20
    # numeric CSV: a header and numeric fields only
    head = a[0].read_text().splitlines()[:3]
    assert head[0] == "g,x0,x1,x2,x3,x4,x5"
    for row in head[1:]:
        assert all(re.fullmatch(r"\d+(\.\d+)?", f) for f in row.split(",")), row
    assert build_field(tmp_path / "a", "dataset_sha256") == shard_sha256(tmp_path / "a")
    stage(tmp_path / "c", "--dataset-mib", str(d), "--dataset-seed", "2")
    assert shard_sha256(tmp_path / "c") != shard_sha256(tmp_path / "a")


def set_analyze_scale(ws, n):
    """The one-line edit Task 5 makes: ANALYZE_WORK_SCALE in the staged project's config.py."""
    cfg = ws / "project" / "src" / "pyc" / "config.py"
    s, k = re.subn(r"(?m)^ANALYZE_WORK_SCALE = \d+$", f"ANALYZE_WORK_SCALE = {n}", cfg.read_text())
    assert k == 1, "config.py has no ANALYZE_WORK_SCALE = <int> line"
    cfg.write_text(s)


def analyze_line(r):
    assert r.returncode == 0, r.stderr
    m = re.fullmatch(r"rows=(\d+) sha256=([0-9a-f]{64}) clusters=(-?\d+\.\d{3})\n", r.stdout)
    assert m, r.stdout
    return m.groups()


def test_analyze_reads_every_byte(tmp_path):
    need_stack()
    ws = tmp_path / "ws"
    stage(ws, "--dataset-mib", "8", "--dataset-seed", "1")
    shim_venv(ws)
    set_analyze_scale(ws, 1)
    cmd = library()["classes"]["py_analyze"][0]["cmd"]
    r = run_cmd(ws, cmd)
    rows, sha, _ = analyze_line(r)
    assert sha == build_field(ws, "dataset_sha256") == shard_sha256(ws)
    assert int(rows) == sum(p.read_bytes().count(b"\n") - 1 for p in shards(ws))
    # the same staging and the same seed give the same line
    assert run_cmd(ws, cmd).stdout == r.stdout


def test_analyze_work_scale_changes_cpu_only(tmp_path):
    need_stack()
    ws = tmp_path / "ws"
    stage(ws, "--dataset-mib", "8", "--dataset-seed", "1")
    shim_venv(ws)
    cfg = (HERE / "project" / "src" / "pyc" / "config.py").read_text()
    assert re.search(r"(?m)^ANALYZE_WORK_SCALE = [1-9]\d*$", cfg), "the default is a positive int in config.py"
    cmd = library()["classes"]["py_analyze"][0]["cmd"]
    lines = {}
    for n in (1, 2):
        set_analyze_scale(ws, n)
        lines[n] = analyze_line(run_cmd(ws, cmd))
    # rows, sha256 and the printed inertia (the random_state 0 fit's) do not depend on the scale
    assert lines[1] == lines[2]
    assert lines[1][1] == build_field(ws, "dataset_sha256")
    # the scale is read from config.py: 0 is refused by fit_repeated
    set_analyze_scale(ws, 0)
    r = run_cmd(ws, cmd)
    assert r.returncode != 0 and "repeats must be >= 1" in r.stderr, r.stderr


def test_library_matches_classes():
    lib = library()
    assert lib["version"] == 1
    assert set(lib["classes"]) == CLASSES
    assert lib["standin"]["interpreter_class"] in CLASSES
    ids = [inv["id"] for invs in lib["classes"].values() for inv in invs]
    assert len(ids) == len(set(ids))
    for cls, invs in lib["classes"].items():
        for inv in invs:
            # py_shmem reads the guest's /proc/meminfo: it needs no project directory
            assert cls == "py_shmem" or inv["cmd"].startswith("cd project && "), inv
            assert inv["exit"] == 0, inv
            assert inv["nominal_ms"] == dict(pycache_corpus.DUR_MS, py_shmem=pycache_corpus.SHMEM_MS)[cls], inv
            assert inv["run_ms"] is None and inv["cpu_ms"] is None, inv
    assert [(i["id"], i["cmd"]) for i in lib["classes"]["py_shmem"]] == [("shmem", SHMEM_CMD)]
    # Sessions flagged tmpfs run these classes with PYC_CACHE_DIR=/tmp/pycache-<workspace key>.
    assert lib["tmpfs"] == {"classes": ["py_analyze", "py_test"], "env": "PYC_CACHE_DIR", "dir": "/tmp/pycache-"}
    assert [i["cmd"] for i in lib["classes"]["py_analyze"]] == ["cd project && ../venv/bin/python analyze.py"]
    assert [i["cmd"] for i in lib["classes"]["py_test"]] == ["cd project && ../venv/bin/python -m pytest -p no:cacheprovider -x -q tests"]
    assert [(i["id"], i["cmd"]) for i in lib["classes"]["py_import"]] == [
        ("import_stack", "cd project && ../venv/bin/python -c 'import numpy, pandas, scipy, sklearn'")]
    assert [(i["id"], i["cmd"]) for i in lib["classes"]["py_grep"]] == [
        ("grep_venv", "cd project && grep -rc --include='*.py' 'def ' ../venv/lib/python3.9/site-packages | wc -l")]
    assert 6 <= len(lib["classes"]["py_short"]) <= 10
    assert sum("python3 -c" in i["cmd"] for i in lib["classes"]["py_short"]) == 1


def test_cache_bound_classes_nominal_is_planned_duration():
    # Spec v0.4 §4.3: py_import and py_grep have one invocation each whose nominal_ms is the corpus
    # generator's planned duration, so the driver's fill runs it once and sleeps 0.
    lib = library()
    for cls, ms in (("py_import", 2000), ("py_grep", 2200)):
        assert pycache_corpus.DUR_MS[cls] == ms
        (inv,) = lib["classes"][cls]
        assert inv["nominal_ms"] == pycache_corpus.DUR_MS[cls], cls


def test_grep_venv_prints_one_count(tmp_path):
    # The guest's venv is not staged by --dir: a fake site-packages stands in for it. The command
    # reads every .py file under it and prints one line (the number of files), exit 0.
    ws = tmp_path / "ws"
    stage(ws, "--dataset-mib", "1")
    sp = ws / "venv" / "lib" / "python3.9" / "site-packages"
    (sp / "pkg").mkdir(parents=True)
    (sp / "x.py").write_text("def f():\n    pass\n")
    (sp / "pkg" / "y.py").write_text("x = 1\n")
    (sp / "pkg" / "z.txt").write_text("def not_python\n")
    (inv,) = library()["classes"]["py_grep"]
    r = run_cmd(ws, inv["cmd"])
    assert r.returncode == inv["exit"] == 0, r.stderr
    assert re.fullmatch(r"\s*2\n", r.stdout), r.stdout


def test_import_stack_runs(tmp_path):
    need_stack()
    if importlib.util.find_spec("scipy") is None:
        pytest.skip(f"scipy is not importable by {sys.executable}")
    ws = tmp_path / "ws"
    stage(ws, "--dataset-mib", "1")
    shim_venv(ws)
    (inv,) = library()["classes"]["py_import"]
    r = run_cmd(ws, inv["cmd"])
    assert r.returncode == inv["exit"] == 0, r.stderr


def test_short_commands_exit_zero(tmp_path):
    ws = tmp_path / "ws"
    stage(ws, "--dataset-mib", "1")
    for inv in library()["classes"]["py_short"]:
        r = run_cmd(ws, inv["cmd"])
        assert r.returncode == inv["exit"], (inv["id"], r.stderr)
        assert r.stdout, inv["id"]


def test_project_tests_pass(tmp_path):
    need_stack()
    ws = tmp_path / "ws"
    stage(ws, "--dataset-mib", "1")
    shim_venv(ws)
    assert re.search(r"^WORK_SCALE = ", (ws / "project/tests/conftest.py").read_text(), re.M)
    cmd = library()["classes"]["py_test"][0]["cmd"]
    r = run_cmd(ws, cmd, env={"PYC_WORK_SCALE": "0.02"})
    assert r.returncode == 0, r.stdout + r.stderr
    assert re.search(r"\b40 passed\b", r.stdout), r.stdout


def test_wheels_lock_pins_sha256(tmp_path):
    entries = lock_entries()
    assert len(entries) == 10
    for sha, name in entries:
        assert re.fullmatch(r"[0-9a-f]{64}", sha), name
        assert name.endswith(".whl") and "/" not in name, name
    names = {n for _, n in entries}
    for pkg in ("numpy-2.0.2-cp39", "pandas-2.2.3-cp39", "scikit_learn-1.6.1-cp39", "scipy-1.13.1-cp39"):
        assert any(n.startswith(pkg) for n in names), pkg

    wd = tmp_path / "wheels"
    wd.mkdir()
    have = WHEELS.is_dir() and all((WHEELS / n).is_file() for n in names)
    for _, n in entries:
        if have:
            (wd / n).symlink_to(WHEELS / n)
        else:
            (wd / n).write_bytes(b"not the locked wheel\n")
    if have:
        r = stage(tmp_path / "good", "--dataset-mib", "1", "--wheels", str(wd))
        assert "wheels: 10 verified" in (tmp_path / "good" / "BUILD").read_text()
    bad = sorted(names)[3]
    (wd / bad).unlink()
    (wd / bad).write_bytes(b"tampered\n")
    r = stage(tmp_path / "bad", "--dataset-mib", "1", "--wheels", str(wd), check=False)
    assert r.returncode != 0
    assert bad in r.stderr and "sha256" in r.stderr, r.stderr
    (wd / bad).unlink()
    r = stage(tmp_path / "missing", "--dataset-mib", "1", "--wheels", str(wd), check=False)
    assert r.returncode != 0 and bad in r.stderr, r.stderr


def test_dir_mode_records_skipped_venv(tmp_path):
    ws = tmp_path / "ws"
    stage(ws, "--dataset-mib", "1")
    assert build_field(ws, "venv") == "skipped (no rootfs)"
    assert not (ws / "venv").exists()
    assert (ws / "project" / "analyze.py").is_file()
    # the staged project is the committed one, without bytecode or caches
    staged = sorted(str(p.relative_to(ws / "project")) for p in (ws / "project").rglob("*") if p.is_file())
    assert not any("__pycache__" in p or p.endswith(".pyc") for p in staged), staged
    assert "src/pyc/config.py" in staged and "tests/conftest.py" in staged


def test_edit_is_idempotent(tmp_path):
    ws = tmp_path / "ws"
    stage(ws, "--dataset-mib", "1")
    cfg = ws / "project" / "src" / "pyc" / "config.py"
    before = cfg.read_bytes()
    (edit,) = [i for i in library()["classes"]["py_short"] if "python3 -c" in i["cmd"]]
    for _ in range(2):
        r = run_cmd(ws, edit["cmd"])
        assert r.returncode == 0, r.stderr
        assert "edited" in r.stdout, r.stdout  # it did rewrite the constant before reverting
        assert cfg.read_bytes() == before


def test_edit_recovers_from_an_interrupted_edit(tmp_path):
    ws = tmp_path / "ws"
    stage(ws, "--dataset-mib", "1")
    cfg = ws / "project" / "src" / "pyc" / "config.py"
    before = cfg.read_bytes()
    # a run killed between its two writes leaves the edited constant behind
    cfg.write_bytes(before.replace(b"MAX_ITER = 300", b"MAX_ITER = 301"))
    (edit,) = [i for i in library()["classes"]["py_short"] if "python3 -c" in i["cmd"]]
    for _ in range(2):
        r = run_cmd(ws, edit["cmd"])
        assert r.returncode == 0, r.stderr
        assert cfg.read_bytes() == before
    assert sorted(p.name for p in cfg.parent.iterdir()) == sorted(
        p.name for p in (HERE / "project" / "src" / "pyc").glob("*.py"))


def test_library_plans_one_invocation_per_heavy_call():
    if shutil.which("go") is None:
        pytest.skip("go is not installed")
    env = dict(os.environ)
    for k, v in (("GOPATH", "/tmp/gopath"), ("GOMODCACHE", "/tmp/gopath/pkg/mod"), ("GOCACHE", "/tmp/gocache")):
        env.setdefault(k, v)
    r = subprocess.run(["go", "test", "-count=1", "-run", "^TestPlanPycacheOneInvocationPerHeavyCall$", "."],
                       cwd=DRIVER, capture_output=True, text=True, env=env)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "no tests to run" not in r.stdout, r.stdout


def test_preflight_runs_python_like_in_guest():
    # Image mode needs root, so this is a check of the script's text: the venv/ensurepip preflight
    # runs the guest's python3.9 with a clean environment (env -i, as in_guest) and -B (no bytecode
    # written into the read-only rootfs tree), so the host's PYTHON* variables cannot change it.
    text = SCRIPT.read_text()
    pre = [l for l in text.splitlines() if "import venv, ensurepip" in l and not l.lstrip().startswith("#")]
    assert len(pre) == 1, pre
    assert re.search(r'chroot "\$ROOTFS" /usr/bin/env -i PATH=/usr/bin:/bin HOME=/tmp TMPDIR=/tmp '
                     r"/usr/bin/python3\.9 -B -c 'import venv, ensurepip'", pre[0]), pre[0]


def test_py_shmem_prints_the_guest_shmem_kb(tmp_path):
    # The command is the brief's, verbatim; here it reads a stand-in for the guest's /proc/meminfo.
    (inv,) = library()["classes"]["py_shmem"]
    meminfo = tmp_path / "meminfo"
    meminfo.write_text("MemTotal:        1004548 kB\nShmem:             51234 kB\nShmemHugePages:        0 kB\n"
                       "ShmemPmdMapped:        0 kB\n")
    r = run_cmd(tmp_path, inv["cmd"].replace("/proc/meminfo", str(meminfo)))
    assert r.returncode == inv["exit"] == 0, r.stderr
    assert r.stdout == "51234\n"
    # one cheap invocation per call: nominal_ms is the corpus's planned duration
    assert inv["nominal_ms"] == pycache_corpus.SHMEM_MS


def files_under(d):
    return sorted(str(p.relative_to(d)) for p in d.rglob("*") if p.is_file()) if d.exists() else []


def test_analyze_cache_dir_puts_caches_there(tmp_path):
    # PYC_CACHE_DIR (a tmpfs session's /tmp/pycache-<key>): analyze.py writes the dependency cache
    # (the bytecode of everything it imports, sys.pycache_prefix) and the dataset cache (the KMeans
    # sample, keyed by the dataset sha256) there, and prints the same line. Unset: no cache at all.
    need_stack()
    ws = tmp_path / "ws"
    stage(ws, "--dataset-mib", "4", "--dataset-seed", "1")
    shim_venv(ws)
    set_analyze_scale(ws, 1)
    cmd = library()["classes"]["py_analyze"][0]["cmd"]
    plain = analyze_line(run_cmd(ws, cmd))
    cache = tmp_path / "pycache-key"
    got = analyze_line(run_cmd(ws, cmd, env={"PYC_CACHE_DIR": str(cache)}))
    assert got == plain
    files = files_under(cache)
    sha = build_field(ws, "dataset_sha256")
    assert "dataset/sample-%s.npy" % sha in files, files
    pyc = [f for f in files if f.startswith("pyc/") and f.endswith(".pyc")]
    assert any("/numpy/" in f for f in pyc) and any("/pandas/" in f for f in pyc), pyc[:5]
    # a second run reuses (and checks) both caches
    before = {f: (cache / f).stat().st_mtime_ns for f in files}
    assert analyze_line(run_cmd(ws, cmd, env={"PYC_CACHE_DIR": str(cache)})) == plain
    assert {f: (cache / f).stat().st_mtime_ns for f in files_under(cache)} == before
    # a cache that does not match the dataset is refused, never trusted
    (cache / "dataset" / ("sample-%s.npy" % sha)).write_bytes(b"not a sample")
    r = run_cmd(ws, cmd, env={"PYC_CACHE_DIR": str(cache)})
    assert r.returncode != 0 and "dataset cache" in r.stderr, r.stderr


def test_analyze_without_cache_dir_writes_no_cache(tmp_path):
    need_stack()
    ws = tmp_path / "ws"
    stage(ws, "--dataset-mib", "1", "--dataset-seed", "1")
    shim_venv(ws)
    set_analyze_scale(ws, 1)
    env = {k: v for k, v in os.environ.items() if k != "PYC_CACHE_DIR"}
    cmd = library()["classes"]["py_analyze"][0]["cmd"]
    r = subprocess.run(["bash", "-c", cmd], cwd=ws, capture_output=True, text=True, env=env)
    analyze_line(r)
    assert not [p for p in ws.rglob("*") if p.name.startswith("sample-")]


def test_project_tests_cache_dir_puts_bytecode_there(tmp_path):
    need_stack()
    ws = tmp_path / "ws"
    stage(ws, "--dataset-mib", "1")
    shim_venv(ws)
    cache = tmp_path / "pycache-key"
    cmd = library()["classes"]["py_test"][0]["cmd"]
    r = run_cmd(ws, cmd, env={"PYC_WORK_SCALE": "0.02", "PYC_CACHE_DIR": str(cache)})
    assert r.returncode == 0, r.stdout + r.stderr
    assert re.search(r"\b40 passed\b", r.stdout), r.stdout
    pyc = [f for f in files_under(cache) if f.startswith("pyc/") and f.endswith(".pyc")]
    assert any("/numpy/" in f for f in pyc), pyc[:5]


# --- E17c Task 10 (SPEC §13.5, R45): the 256 MiB library ------------------------------------------------------------
# Ruling R-z1: config.py stays as it was at deb53c3 (no E17c line in the project's sources); library-256.json's
# py_analyze command sets ANALYZE_WORK_SCALE itself (gate256.analyze_cmd) before it runs analyze.py.
LIBRARY_256 = HERE / "library-256.json"
CHAIN_E17C = ROOT / "e17-lease" / "rig" / "chain-e17c.sh"
BRINGUP = ROOT / "e17-lease" / "rig" / "bringup.sh"
sys.path.insert(0, str(ROOT / "e17-lease" / "analysis"))
import gate256  # noqa: E402

# bringup.sh's template inputs (its §5 key: builder, wheels.lock, project) at deb53c3, the E17b procedure's sources.
# An E17C-unset bring-up must find these, or it rebuilds the E17a/E17b templates in place (Global Constraint 1).
E17B_TEMPLATE_INPUTS = {
    "builder": "9133f777cdeb0a444cca39b683cfb8caa919b9205250dcab08c9cfe67859dcf0",
    "wheels.lock": "568b1ba4af3eda30db8a2991ef10f3db5ae78014cacba72c07cf896b08edae41",
    "project": "f2871d26721dbb91f9d96741691533b78730ae67716bb2ab5838e52d97ebe548",
}


def default_scale():
    cfg = (HERE / "project" / "src" / "pyc" / "config.py").read_text()
    return int(re.search(r"(?m)^ANALYZE_WORK_SCALE = (\d+)$", cfg).group(1))


def gate_candidates():
    """chain-e17c.sh's G256_SCALES, the scales gate-256 may choose."""
    m = re.search(r'(?m)^G256_SCALES="([\d ]+)"$', CHAIN_E17C.read_text())
    assert m, "chain-e17c.sh has no G256_SCALES line"
    return tuple(int(s) for s in m.group(1).split())


def project_sha(project):
    """bringup.sh's proj_sha: find . -type f (no __pycache__, .pytest_cache, *.pyc) | LC_ALL=C sort -z | sha256sum."""
    paths = []
    for dirpath, dirnames, files in os.walk(project):
        rel = os.path.relpath(dirpath, project)
        for f in files:
            q = "./" + f if rel == "." else "./" + rel + "/" + f
            if "/__pycache__/" in q or "/.pytest_cache/" in q or f.endswith(".pyc"):
                continue
            paths.append(q)
    out = b""
    for q in sorted(paths, key=lambda x: x.encode()):
        out += ("%s  %s\n" % (hashlib.sha256((project / q[2:]).read_bytes()).hexdigest(), q)).encode()
    return hashlib.sha256(out).hexdigest()


def test_template_inputs_are_e17bs():
    txt = BRINGUP.read_text()
    # the key this mirrors (if bringup.sh's own hashing changes, so must this check)
    assert ("proj_sha=$(cd \"$WL/project\" && find . -type f ! -path '*/__pycache__/*' ! -path '*/.pytest_cache/*' "
            "! -name '*.pyc' -print0 |") in txt
    assert "LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)" in txt
    assert "BUILDER=$WL/build_pycache_workspace.sh" in txt and "LOCK=$WL/wheels.lock" in txt
    got = {"builder": hashlib.sha256(SCRIPT.read_bytes()).hexdigest(),
           "wheels.lock": hashlib.sha256(LOCK.read_bytes()).hexdigest(),
           "project": project_sha(HERE / "project")}
    assert got == E17B_TEMPLATE_INPUTS


def check_library_256(path):
    """The committed library-256.json: library.json but py_analyze's command, which is gate256.analyze_cmd(scale)
    for the placeholder 0 (ruling R-x) or one of gate-256's candidates. Returns the scale."""
    base, l256 = library(), json.loads(pathlib.Path(path).read_text())
    (inv,) = l256["classes"]["py_analyze"]
    scale = gate256.library_scale(str(path))
    assert inv["cmd"] == gate256.analyze_cmd(scale), inv["cmd"]
    l256["classes"]["py_analyze"][0]["cmd"] = base["classes"]["py_analyze"][0]["cmd"]
    assert l256 == base
    assert scale == gate256.PLACEHOLDER or scale in gate_candidates(), scale
    return scale


def test_library_256_differs_from_library_only_in_py_analyze_scale():
    check_library_256(LIBRARY_256)


def test_committed_scale_check_accepts_every_gate_candidate_and_the_placeholder(tmp_path):
    assert gate_candidates() == (32, 16, 8, 4, 2, 1)
    assert gate_candidates()[0] == default_scale()
    lib = json.loads(LIBRARY_256.read_text())
    p = tmp_path / "library-256.json"
    for s in (0,) + gate_candidates():
        lib["classes"]["py_analyze"][0]["cmd"] = gate256.analyze_cmd(s)
        p.write_text(json.dumps(lib))
        assert check_library_256(p) == s
    for s in (3, 64):
        lib["classes"]["py_analyze"][0]["cmd"] = gate256.analyze_cmd(s)
        p.write_text(json.dumps(lib))
        with pytest.raises(AssertionError):
            check_library_256(p)


def probe_analyze(ws, body):
    """The staged project's analyze.py replaced by BODY (no numpy here); venv/bin/python is this interpreter."""
    shim_venv(ws)
    (ws / "project" / "analyze.py").write_text(body)


def test_library_256_command_sets_the_scale_without_touching_the_sources(tmp_path):
    ws = tmp_path / "ws"
    stage(ws, "--dataset-mib", "1")
    cfg = (ws / "project" / "src" / "pyc" / "config.py").read_bytes()
    assert cfg == (HERE / "project" / "src" / "pyc" / "config.py").read_bytes()
    probe_analyze(ws, "import os, sys\n"  # analyze.py's own path line, so __file__ must be set as for a script
                      "sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'src'))\n"
                      "from pyc import config\n"
                      "print(config.ANALYZE_WORK_SCALE, sys.pycache_prefix, __name__)\n")
    env = {k: v for k, v in os.environ.items() if k != "PYC_CACHE_DIR"}
    for s in (7, 0):
        r = subprocess.run(["bash", "-c", gate256.analyze_cmd(s)], cwd=ws, capture_output=True, text=True, env=env)
        assert (r.returncode, r.stdout) == (0, "%d None __main__\n" % s), r.stderr
    # a tmpfs session: the bytecode prefix is set before pyc.config is first imported, as analyze.py sets it
    r = run_cmd(ws, gate256.analyze_cmd(5), env={"PYC_CACHE_DIR": str(tmp_path / "c")})
    assert (r.returncode, r.stdout) == (0, "5 %s __main__\n" % (tmp_path / "c" / "pyc")), r.stderr
    assert any(p.name.startswith("config.") for p in (tmp_path / "c" / "pyc").rglob("*.pyc"))
    assert (ws / "project" / "src" / "pyc" / "config.py").read_bytes() == cfg  # the command edits no source
    # unset, the project's own scale stands: library.json's command is E17a/E17b's
    r = run_cmd(ws, library()["classes"]["py_analyze"][0]["cmd"])
    assert r.stdout.split()[0] == str(default_scale()), r.stderr


def test_library_256_scale_reaches_analyze(tmp_path):
    need_stack()
    ws = tmp_path / "ws"
    stage(ws, "--dataset-mib", "4", "--dataset-seed", "1")
    shim_venv(ws)
    one = analyze_line(run_cmd(ws, gate256.analyze_cmd(1)))
    assert one[1] == build_field(ws, "dataset_sha256")
    r = run_cmd(ws, gate256.analyze_cmd(0))
    assert r.returncode != 0 and "repeats must be >= 1" in r.stderr, r.stderr


def test_gate_library_measures_peak_rss_inside_the_command(tmp_path):
    lib = tmp_path / "lib-s8.json"
    gate256.write_gate_library(str(LIBRARY_256), 8, str(lib))
    g = json.loads(lib.read_text())
    base = json.loads(LIBRARY_256.read_text())
    cmd = g["classes"]["py_analyze"][0]["cmd"]
    # the wrapper runs as the venv's interpreter (the guest is only sure to have that and python3.9), never python3
    assert cmd.startswith("cd project && ../venv/bin/python -c ") and "python3" not in cmd, cmd
    g["classes"]["py_analyze"][0]["cmd"] = base["classes"]["py_analyze"][0]["cmd"]
    assert g == base  # only py_analyze's command differs from the 256 library
    ws = tmp_path / "ws"
    stage(ws, "--dataset-mib", "1")
    # a child that grows to ~40 MiB and prints analyze's line; the gate's scale reaches it through pyc.config
    probe_analyze(ws, "from pyc import config\nprint('rows=1 scale=%d' % config.ANALYZE_WORK_SCALE, flush=True)\n"
                      "b = bytearray(40 << 20)\nb[::4096] = b'x' * len(b[::4096])\n")
    r = run_cmd(ws, cmd)
    assert r.returncode == 0, r.stderr
    lines = r.stdout.splitlines()
    assert lines[0] == "rows=1 scale=8", r.stdout
    peak = gate256.peak_rss_kb(r.stdout)
    # ru_maxrss is KiB on Linux (the guest), bytes on macOS: either way at least the 40 MiB the child touched
    assert peak is not None and peak >= 40 << 10, r.stdout
    assert (ws / "project" / "src" / "pyc" / "config.py").read_bytes() == (
        HERE / "project" / "src" / "pyc" / "config.py").read_bytes()
    # killed by SIGKILL (the guest's OOM killer): exit 137, as the driver's failed_rc records it
    ws2 = tmp_path / "ws2"
    stage(ws2, "--dataset-mib", "1")
    probe_analyze(ws2, "import os, signal\nos.kill(os.getpid(), signal.SIGKILL)\n")
    r = run_cmd(ws2, cmd)
    assert r.returncode == 137, (r.returncode, r.stderr)
    ws3 = tmp_path / "ws3"
    stage(ws3, "--dataset-mib", "1")
    probe_analyze(ws3, "raise SystemExit(3)\n")
    assert run_cmd(ws3, cmd).returncode == 3  # any other exit passes through


def test_gate_library_refuses_a_bad_scale(tmp_path):
    for s in (0, -1):
        with pytest.raises(ValueError):
            gate256.write_gate_library(str(LIBRARY_256), s, str(tmp_path / "x.json"))
