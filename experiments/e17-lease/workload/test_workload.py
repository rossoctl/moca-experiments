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
DRIVER = ROOT / "e15" / "driver"
WHEELS = pathlib.Path(os.environ.get("E17_WHEELS", "/tmp/kagenti/e17-wheels-probe"))
SHARD_MIB = 32
CLASSES = {"py_analyze", "py_test", "py_import", "py_grep", "py_short"}

sys.path.insert(0, str(ROOT / "e17" / "extract"))
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
            assert inv["cmd"].startswith("cd project && "), inv
            assert inv["exit"] == 0, inv
            assert inv["nominal_ms"] == pycache_corpus.DUR_MS[cls], inv
            assert inv["run_ms"] is None and inv["cpu_ms"] is None, inv
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
