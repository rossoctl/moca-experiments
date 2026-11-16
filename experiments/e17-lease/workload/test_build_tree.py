"""Checks for build_tree.sh, the N-file tree the ownership-walk probe writes as root (PLAN-E17B Task 11).

Run: /tmp/e17b-venv/bin/python -m pytest -q experiments/e17-lease/workload/test_build_tree.py

The driver's `ownwalk` sends the script's text as `sh -c SCRIPT build_tree.sh DIR N`; these checks run
it that way too, under /bin/sh (POSIX: the guest's shell, no other tool than mkdir).
"""

import os
import pathlib
import subprocess

import pytest

HERE = pathlib.Path(__file__).resolve().parent
SCRIPT = HERE / "build_tree.sh"


def run(tree, n, shell="/bin/sh"):
    return subprocess.run([shell, "-c", SCRIPT.read_text(), "build_tree.sh", str(tree), str(n)],
                          capture_output=True, text=True)


def listing(root):
    out = []
    for d, dirs, files in os.walk(root):
        rel = os.path.relpath(d, root)
        out += [os.path.join(rel, f) for f in files]
        out += [os.path.join(rel, x) + "/" for x in dirs]
    return sorted(out)


def test_builds_n_empty_files_in_dirs_of_1000(tmp_path):
    r = run(tmp_path / "tree", 2500)
    assert r.returncode == 0, r.stderr
    files = [p for p in listing(tmp_path / "tree") if not p.endswith("/")]
    dirs = [p for p in listing(tmp_path / "tree") if p.endswith("/")]
    assert len(files) == 2500
    assert dirs == ["./d0/", "./d1/", "./d2/"]
    assert sorted(len(os.listdir(tmp_path / "tree" / d)) for d in ("d0", "d1", "d2")) == [500, 1000, 1000]
    assert all((tmp_path / "tree" / p).stat().st_size == 0 for p in files)
    # the line the driver checks: files=N as its own word
    assert r.stdout.split() == ["build_tree:", "files=2500", "dirs=3", "dir=%s" % (tmp_path / "tree")]


def test_is_deterministic(tmp_path):
    assert run(tmp_path / "a", 1234).returncode == 0
    assert run(tmp_path / "b", 1234).returncode == 0
    assert listing(tmp_path / "a") == listing(tmp_path / "b")


def test_an_exact_multiple_has_no_partial_dir(tmp_path):
    r = run(tmp_path / "tree", 10000)
    assert r.returncode == 0, r.stderr
    assert len(os.listdir(tmp_path / "tree")) == 10
    assert "files=10000 dirs=10 " in r.stdout


def test_refuses_an_existing_dir(tmp_path):
    (tmp_path / "tree").mkdir()
    (tmp_path / "tree" / "keep").write_text("x")
    r = run(tmp_path / "tree", 10)
    assert r.returncode != 0
    assert "exists" in r.stderr
    assert os.listdir(tmp_path / "tree") == ["keep"]


@pytest.mark.parametrize("n", ["0", "-5", "abc", "1e3", ""])
def test_refuses_a_bad_count(tmp_path, n):
    r = run(tmp_path / "tree", n)
    assert r.returncode != 0
    assert not (tmp_path / "tree").exists()


@pytest.mark.parametrize("shell", ["/bin/sh", "/bin/bash"])
def test_runs_under_posix_shells(tmp_path, shell):
    if not os.path.exists(shell):
        pytest.skip(shell)
    r = run(tmp_path / "tree", 1001, shell=shell)
    assert r.returncode == 0, r.stderr
    assert len([p for p in listing(tmp_path / "tree") if not p.endswith("/")]) == 1001
