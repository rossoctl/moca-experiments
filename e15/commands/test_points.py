"""Checks for the memory-pressure point mem512 (SPEC §10.3): make_point_library.py and
build_workspace.sh's --dataset-mib.

Run: PYTHONPATH=/tmp/kagenti/pylibs python3 -m pytest -q e15/commands

The build_workspace.sh check stages the project in --dir mode, so it needs a clone holding
project.lock's commit: E15_PROJECT_SRC, else /tmp/kagenti/e15work/project-candidate; skipped
when neither has it.
"""

import gzip
import hashlib
import json
import os
import pathlib
import subprocess
import sys

import pytest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import make_point_library as mpl  # noqa: E402

SCAN = "cat /workspace/data.bin >/dev/null"
SCAN_CLASSES = ("read", "shell_read", "search", "test", "interpreter", "lint_check")


def tiny_lib():
    inv = lambda i, cmd, ex=0: {"id": i, "cmd": cmd, "exit": ex, "nominal_ms": 30, "run_ms": 3, "cpu_ms": 2}
    return {"version": 1,
            "classes": {"read": [inv("r1", "cd project && cat a"), inv("r2", "cd project && head b")],
                        "shell_read": [inv("g", "cd project && grep x .", 1)],
                        "vcs": [inv("v", "cd project && git status")]},
            "standin": {"interpreter_class": "read", "infra_sleep_frac": 0.5}}


def test_prefixes_only_listed_classes():
    src = tiny_lib()
    out = mpl.point_library(src, ["read", "shell_read"], SCAN)
    for cls in ("read", "shell_read"):
        for a, b in zip(src["classes"][cls], out["classes"][cls]):
            assert b["cmd"] == SCAN + " && " + a["cmd"]
            assert b["id"] == a["id"] + "+scan"
            for k in ("exit", "nominal_ms", "run_ms", "cpu_ms"):
                assert b[k] == a[k]
    assert out["classes"]["vcs"] == src["classes"]["vcs"]
    assert out["standin"] == src["standin"] and out["version"] == src["version"]
    assert src["classes"]["read"][0]["cmd"] == "cd project && cat a", "source left untouched"


def test_unknown_class_refused():
    with pytest.raises(SystemExit):
        mpl.point_library(tiny_lib(), ["read", "nosuch"], SCAN)


def test_cli_writes_dst(tmp_path):
    src = tmp_path / "lib.json"
    src.write_text(json.dumps(tiny_lib()))
    dst = tmp_path / "out.json"
    subprocess.run([sys.executable, str(HERE / "make_point_library.py"), str(src), str(dst),
                    "--scan-classes", "read,shell_read", "--scan-cmd", SCAN], check=True)
    out = json.loads(dst.read_text())
    assert [v["id"] for v in out["classes"]["read"]] == ["r1+scan", "r2+scan"]
    assert out["classes"]["shell_read"][0]["exit"] == 1


def test_committed_mem512_library_is_generated_from_library_json():
    """library-mem512.json tracks library.json: regenerate it when library.json changes."""
    src = json.loads((HERE / "library.json").read_text())
    got = json.loads((HERE / "library-mem512.json").read_text())
    assert got == mpl.point_library(src, list(SCAN_CLASSES), SCAN)
    ids = [v["id"] for vs in got["classes"].values() for v in vs]
    assert len(ids) == len(set(ids))
    n_scan = sum(len(got["classes"][c]) for c in SCAN_CLASSES)
    assert sum(v["cmd"].startswith(SCAN + " && ") for vs in got["classes"].values() for v in vs) == n_scan


LOCK = json.loads((HERE / "project.lock").read_text())


def project_src():
    for cand in (os.environ.get("E15_PROJECT_SRC"), "/tmp/kagenti/e15work/project-candidate"):
        if cand and os.path.isdir(cand) and subprocess.run(
                ["git", "-C", cand, "cat-file", "-e", LOCK["commit"] + "^{commit}"],
                capture_output=True).returncode == 0:
            return cand
    return None


def stage(out, *args):
    src = project_src()
    if src is None:
        pytest.skip("no clone holding project.lock's commit (set E15_PROJECT_SRC)")
    env = dict(os.environ, E15_PROJECT_SRC=src)
    return subprocess.run(["bash", str(HERE / "build_workspace.sh"), *args, "--dir", str(out)],
                          env=env, capture_output=True, text=True)


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def test_dataset_dir_mode(tmp_path):
    r = stage(tmp_path / "a", "--dataset-mib", "4", "--dataset-seed", "1", "--image-mb", "1024")
    assert r.returncode == 0, r.stderr
    d = tmp_path / "a" / "data.bin"
    assert d.stat().st_size == 4 << 20
    raw = d.read_bytes()
    assert len(gzip.compress(raw, 6)) / len(raw) > 0.95, "incompressible"
    assert (tmp_path / "a" / "project" / ".git").is_dir()
    # deterministic: same seed, same bytes; another seed, other bytes
    r = stage(tmp_path / "b", "--dataset-mib", "4", "--dataset-seed", "1")
    assert r.returncode == 0, r.stderr
    assert sha(tmp_path / "b" / "data.bin") == sha(d)
    r = stage(tmp_path / "c", "--dataset-mib", "4", "--dataset-seed", "2")
    assert r.returncode == 0, r.stderr
    assert sha(tmp_path / "c" / "data.bin") != sha(d)


def test_no_dataset_by_default(tmp_path):
    r = stage(tmp_path / "a")
    assert r.returncode == 0, r.stderr
    assert not (tmp_path / "a" / "data.bin").exists()


@pytest.mark.parametrize("args", [["--dataset-mib", "0"], ["--dataset-mib", "x"], ["--dataset-seed", "-1"],
                                  ["--image-mb", "12q"], ["--dataset-mib", "1000", "--image-mb", "1024"]])
def test_bad_dataset_args(tmp_path, args):
    r = subprocess.run(["bash", str(HERE / "build_workspace.sh"), *args, "--dir", str(tmp_path / "x")],
                       capture_output=True, text=True)
    assert r.returncode != 0
    assert not (tmp_path / "x").exists()


def test_dataset_image_initialised_eagerly():
    """Image mode (rig only): a data.bin image is mkfs'd without lazy init, the default one as before."""
    s = (HERE / "build_workspace.sh").read_text()
    assert '[ "$DATA_MIB" = 0 ] || mkfs_opts=(-E "lazy_itable_init=0,lazy_journal_init=0")' in s
    assert 'mkfs.ext4 -F -q "${mkfs_opts[@]}" "$TMP_IMG"' in s
