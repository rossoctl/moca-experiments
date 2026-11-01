"""Checks on the E15 command library (SPEC §5.6).

Run: cd e15/commands && PYTHONPATH=/tmp/kagenti/pylibs python3 -m pytest -q

Two checks are opt-in because they need a staged workspace:
  E15_WORKSPACE=DIR   a `build_workspace.sh --dir DIR` tree; every invocation is run in it
                      (cwd DIR, as the worker runs in /workspace) and its exit code checked.
                      Commands name /workspace/scripts, so DIR must be reachable as /workspace
                      or the check rewrites that prefix to DIR.
"""

import json
import os
import pathlib
import re
import subprocess
import sys

import pytest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "extract"))
sys.path.insert(0, str(HERE / "scripts"))

from classes import CLASSES  # noqa: E402

STANDIN_CLASSES = {"opaque", "build", "host_infra"}
BURN_MS = (50, 200, 1000, 5000, 20000)


@pytest.fixture(scope="module")
def library():
    return json.loads((HERE / "library.json").read_text())


def invocations(library):
    for cls, invs in library["classes"].items():
        for inv in invs:
            yield cls, inv


def test_schema(library):
    assert library["version"] == 1
    assert set(library["classes"]) <= set(CLASSES)
    ids = [inv["id"] for _, inv in invocations(library)]
    assert len(ids) == len(set(ids)), "invocation ids must be unique"
    for cls, inv in invocations(library):
        assert isinstance(inv["id"], str) and isinstance(inv["cmd"], str), inv
        assert inv["run_ms"] is None or isinstance(inv["run_ms"], int), inv
        assert inv["cpu_ms"] is None or isinstance(inv["cpu_ms"], int), inv
        assert isinstance(inv["nominal_ms"], int) and inv["nominal_ms"] > 0, inv
    standin = library["standin"]
    assert standin["infra_sleep_frac"] == 0.5
    assert standin["interpreter_id"] in library["classes"]


def test_every_class_covered(library):
    covered = {c for c, invs in library["classes"].items() if invs}
    for cls in CLASSES:
        if cls in STANDIN_CLASSES:
            continue
        assert cls in covered, f"class {cls} has no invocations"
        assert len(library["classes"][cls]) >= 3, f"class {cls} has < 3 invocations"
    # The stand-in classes replay through the interpreter stand-in, which must exist.
    assert library["classes"][library["standin"]["interpreter_id"]]


def test_expected_exit_declared(library):
    for cls, inv in invocations(library):
        assert isinstance(inv["exit"], int) and not isinstance(inv["exit"], bool), inv
    assert any(inv["exit"] == 1 for inv in library["classes"]["shell_read"]), \
        "shell_read needs a no-match grep declared exit 1"


ABS = re.compile(r"(?:^|[\s'\"=:(<>])(/[^\s'\";|&)]*)")


def test_commands_relative(library):
    for cls, inv in invocations(library):
        cmd = inv["cmd"]
        assert cmd.startswith("cd project && "), inv["id"]
        assert ".." not in cmd, inv["id"]
        for path in ABS.findall(cmd):
            path = "/" + path.lstrip("/")
            assert path == "/dev/null" or path.startswith("/workspace/"), (inv["id"], path)


def test_writes_confined(library):
    """write and file_ops touch only the scratch dir .e15/, never tracked project files."""
    for cls in ("write", "file_ops"):
        for inv in library["classes"][cls]:
            for m in re.finditer(r"\b(rm|mv)\s+(-\S+\s+)*(\S+)(\s+(\S+))?", inv["cmd"]):
                targets = [m.group(3)] if m.group(1) == "rm" else [m.group(5)]
                for t in targets:
                    assert t and t.startswith(".e15/"), (inv["id"], m.group(0))
            for m in re.finditer(r">+\s*(\S+)", inv["cmd"]):
                assert m.group(1).startswith((".e15/", "/dev/null")), (inv["id"], m.group(0))


def test_spread(library):
    for cls, invs in library["classes"].items():
        times = [inv["run_ms"] if inv["run_ms"] is not None else inv["nominal_ms"]
                 for inv in invs]
        assert max(times) / min(times) >= 10, (cls, times)


def test_test_class_grades_pytest(library):
    cmds = [inv["cmd"] for inv in library["classes"]["test"]]
    assert all("python3 -m pytest" in c for c in cmds)
    assert any("::" in c for c in cmds), "a single test"
    assert any(re.search(r"pytest\b.*\btests/test_\w+\.py(\s|$)", c) for c in cmds), "a file"
    assert any(re.search(r"pytest\b.*\btests(\s|$)", c) for c in cmds), "the suite"


def test_interpreter_uses_burn_scripts(library):
    cmds = {inv["cmd"] for inv in library["classes"]["interpreter"]}
    for ms in BURN_MS:
        assert f"cd project && python3 /workspace/scripts/burn_{ms}.py" in cmds


def test_gen_scripts(tmp_path):
    import gen_scripts
    gen_scripts.main([str(tmp_path)])
    names = sorted(p.name for p in tmp_path.iterdir())
    for ms in BURN_MS:
        assert f"burn_{ms}.py" in names
    for p in tmp_path.iterdir():
        compile(p.read_text(), str(p), "exec")
    out = subprocess.run([sys.executable, str(tmp_path / "burn_50.py")],
                         capture_output=True, text=True, check=True)
    assert "burn_50" in out.stdout


@pytest.mark.skipif(not os.environ.get("E15_WORKSPACE"), reason="E15_WORKSPACE not set")
def test_commands_run_in_workspace(library):
    ws = pathlib.Path(os.environ["E15_WORKSPACE"]).resolve()
    skip = set(os.environ.get("E15_SKIP", "").split(","))
    bad = []
    for cls, inv in invocations(library):
        if inv["id"] in skip:
            continue
        cmd = inv["cmd"].replace("/workspace/", f"{ws}/")
        r = subprocess.run(["bash", "-c", cmd], cwd=ws, capture_output=True, text=True,
                           timeout=600)
        if r.returncode != inv["exit"]:
            bad.append((inv["id"], r.returncode, r.stderr[-300:]))
    assert not bad
    status = subprocess.run(["git", "status", "--porcelain"], cwd=ws / "project",
                            capture_output=True, text=True, check=True).stdout
    assert status == "", f"library left the project dirty:\n{status}"
