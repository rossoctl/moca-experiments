"""E17d's level-2 workload (PLAN-E17D Task 3, spec §14.2): l2srv.py, l2c.py and l2q.py in the project.

Run: /tmp/kagenti/e17c-venv/bin/python -m pytest -q experiments/e17-lease/workload/test_l2.py

Each test stages the workspace layout with build_pycache_workspace.sh --dir (project/ and data/) and a venv/bin/python
shim (test_workload.shim_venv), and runs the commands from project/ with ../venv/bin/python, as the library and the
driver's process_start do. The socket is L2_SOCK under a short /tmp directory (a unix socket path is at most 104 bytes
on macOS). The protocol tests (the bind by rename, the probe's bound, the exit codes, --wait, a stale socket, a killed
server) run the real l2srv.serve and l2c.py against a stub query table that needs no pandas; the data tests (l2q.py
against l2c.py on the same data) need numpy, pandas and scikit-learn in this interpreter and are skipped without them.
"""

import os
import pathlib
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time

import pytest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from test_workload import need_stack, shim_venv, stage  # noqa: E402

STUB = r'''
import sys, time
import l2srv
delay = float(sys.argv[1])
def load():
    time.sleep(delay)
    return ()
Q = {"quick": lambda: "quick ok", "slow": lambda: (time.sleep(5), "slow done")[1], "boom": lambda: 1 / 0}
l2srv.serve(l2srv.SOCK, Q, load)
'''


@pytest.fixture
def ws(tmp_path):
    """A staged workspace (project/, data/ at 8 MiB, the venv shim) and a short socket root; servers killed after."""
    root = tmp_path / "ws"
    stage(root, "--dataset-mib", "8", "--dataset-seed", "1")
    shim_venv(root)
    (root / "project" / "l2stub.py").write_text(STUB)
    sockdir = pathlib.Path(tempfile.mkdtemp(prefix="l2t-", dir="/tmp"))
    w = type("WS", (), {})()
    w.root, w.project = root, root / "project"
    w.sock = sockdir / ".l2" / "l2.sock"
    w.env = dict(os.environ, L2_SOCK=str(w.sock))
    w.procs = []
    yield w
    for p in w.procs:
        if p.poll() is None:
            p.kill()
            p.wait()
    shutil.rmtree(sockdir, ignore_errors=True)


def start(w, *cmd):
    p = subprocess.Popen(["../venv/bin/python", *cmd], cwd=w.project, env=w.env,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    w.procs.append(p)
    return p


def start_stub(w, delay=0.0):
    return start(w, "l2stub.py", str(delay))


def wait_ready(p, timeout=60):
    line = p.stdout.readline()
    assert line.startswith("ready "), (line, p.stderr.read() if p.poll() is not None else "")
    return line


def client(w, *args, timeout=200):
    t = time.monotonic()
    r = subprocess.run(["../venv/bin/python", "l2c.py", *args], cwd=w.project, env=w.env,
                       capture_output=True, text=True, timeout=timeout)
    return r, time.monotonic() - t


def client_bound(w, bound_s, *args):
    """l2c.py with its query bound set to bound_s (the 120 s of the spec is too long for a test)."""
    code = "import sys, l2c; l2c.QUERY_S = %r; sys.exit(l2c.main(%r))" % (bound_s, list(args))
    return subprocess.run(["../venv/bin/python", "-c", code], cwd=w.project, env=w.env, capture_output=True, text=True)


def stale_socket(path):
    """A socket file with nothing listening: what a killed server leaves."""
    path.parent.mkdir(parents=True, exist_ok=True)
    s = socket.socket(socket.AF_UNIX)
    s.bind(str(path))
    s.close()
    assert stat.S_ISSOCK(os.stat(path).st_mode)


def test_the_bounds_and_the_socket_are_the_spec_s():
    env = {k: v for k, v in os.environ.items() if k != "L2_SOCK"}
    code = ("import l2c; print(l2c.SOCK, l2c.PROBE_S, l2c.QUERY_S, l2c.POLL_S, "
            "l2c.EXIT_NO_SERVER, l2c.EXIT_SERVER_ERROR, l2c.EXIT_QUERY_BOUND)")
    r = subprocess.run([sys.executable, "-B", "-c", code], cwd=HERE / "project", env=env, capture_output=True, text=True)
    assert r.stdout.split() == ["/workspace/.l2/l2.sock", "2.0", "120.0", "0.2", "3", "4", "5"], r.stderr


def test_server_binds_through_a_temporary_name_and_a_rename(ws):
    p = start_stub(ws, delay=1.5)
    seen_before_ready, half_bound = False, 0
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if ws.sock.exists():
            # once the name exists, a client connects: it never sees a socket that is not listening yet
            s = socket.socket(socket.AF_UNIX)
            try:
                s.connect(str(ws.sock))
            except OSError:
                half_bound += 1
            finally:
                s.close()
            break
        seen_before_ready = True
        time.sleep(0.005)
    wait_ready(p)
    assert seen_before_ready and half_bound == 0
    assert stat.S_IMODE(os.stat(ws.sock).st_mode) & 0o060 == 0o060  # the group (sbx-ws) can connect
    assert stat.S_IMODE(os.stat(ws.sock.parent).st_mode) & 0o070 == 0o070  # and so can it create and rename there
    assert [n for n in os.listdir(ws.sock.parent) if n != "l2.sock"] == []  # no temporary name left


def test_server_replaces_a_stale_socket(ws):
    stale_socket(ws.sock)
    wait_ready(start_stub(ws))
    r, _ = client(ws, "quick")
    assert (r.returncode, r.stdout.split(" server_ms=")[0]) == (0, "quick ok"), r.stderr


def test_probe_fails_with_exit_3_on_no_server(ws):
    r, t = client(ws, "quick")  # no socket at all
    assert r.returncode == 3 and t < 3, (r.returncode, t, r.stderr)
    stale_socket(ws.sock)  # a socket file left by a dead server: refused
    r, t = client(ws, "quick")
    assert r.returncode == 3 and t < 3, (r.returncode, t, r.stderr)


def test_probe_is_bounded_at_2_s_when_no_pong_comes(ws):
    ws.sock.parent.mkdir(parents=True)
    hung = socket.socket(socket.AF_UNIX)
    hung.bind(str(ws.sock))
    hung.listen(4)  # connects, never answers
    try:
        r, t = client(ws, "quick")
    finally:
        hung.close()
    assert r.returncode == 3 and 1.9 <= t < 3.5, (r.returncode, t, r.stderr)


def test_query_exit_codes(ws):
    wait_ready(start_stub(ws))
    r, _ = client(ws, "quick")
    assert r.returncode == 0 and r.stdout.startswith("quick ok server_ms="), (r.stdout, r.stderr)
    r, _ = client(ws, "ping")
    assert (r.returncode, r.stdout.strip()) == (0, "pong")
    r, _ = client(ws, "boom")
    assert r.returncode == 4 and "ZeroDivisionError" in r.stderr, r.stderr
    r, _ = client(ws, "nope")
    assert r.returncode == 4 and "unknown query" in r.stderr, r.stderr
    r = client_bound(ws, 1.0, "slow")  # past the query's own bound
    assert r.returncode == 5, (r.returncode, r.stderr)


def test_a_live_server_whose_query_takes_5_s_is_exit_0_not_3(ws):
    wait_ready(start_stub(ws))
    r, t = client(ws, "slow")
    assert r.returncode == 0 and r.stdout.startswith("slow done") and t >= 5, (r.returncode, t, r.stderr)


def test_ping_is_answered_while_a_query_runs(ws):
    wait_ready(start_stub(ws))
    slow = subprocess.Popen(["../venv/bin/python", "l2c.py", "slow"], cwd=ws.project, env=ws.env,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        time.sleep(1.0)
        r, t = client(ws, "ping")
        assert r.returncode == 0 and t < 2, (r.returncode, t, r.stderr)
    finally:
        assert slow.wait(30) == 0


def test_wait_polls_the_probe_not_the_socket_file(ws):
    stale_socket(ws.sock)  # the file exists from the start: a check of the file alone would go at once
    p = start_stub(ws, delay=3.0)  # still loading
    r, t = client(ws, "quick")
    assert r.returncode == 3, r.stderr  # without --wait: one probe, refused
    r, t = client(ws, "--wait", "60", "quick")
    assert r.returncode == 0 and r.stdout.startswith("quick ok") and t >= 1.5, (r.returncode, t, r.stderr)
    wait_ready(p)


def test_wait_gives_up_with_exit_3(ws):
    stale_socket(ws.sock)
    r, t = client(ws, "--wait", "1", "quick")
    assert r.returncode == 3 and 1 <= t < 4, (r.returncode, t, r.stderr)


def test_a_server_killed_between_two_calls_reads_exit_3(ws):
    p = start_stub(ws)
    wait_ready(p)
    assert client(ws, "quick")[0].returncode == 0
    p.send_signal(signal.SIGKILL)
    p.wait()
    assert ws.sock.exists()  # the stale socket stays
    r, t = client(ws, "quick")
    assert r.returncode == 3 and t < 3, (r.returncode, t, r.stderr)
    p2 = start_stub(ws)  # a restart replaces it
    wait_ready(p2)
    assert client(ws, "quick")[0].returncode == 0


def test_l2q_gives_l2c_s_result_on_the_same_data(ws):
    need_stack()
    srv = start(ws, "l2srv.py")
    wait_ready(srv, timeout=300)
    for q in ("light", "fit"):
        r1 = subprocess.run(["../venv/bin/python", "l2q.py", q], cwd=ws.project, env=ws.env, capture_output=True, text=True)
        assert r1.returncode == 0, r1.stderr
        r2, _ = client(ws, q)
        assert r2.returncode == 0, r2.stderr
        assert r2.stdout.strip().split(" server_ms=")[0] == r1.stdout.strip(), (r1.stdout, r2.stdout)
    assert r1.stdout.startswith("fit inertia=")


def test_l2q_refuses_an_unknown_query(ws):
    need_stack()
    r = subprocess.run(["../venv/bin/python", "l2q.py", "nope"], cwd=ws.project, env=ws.env, capture_output=True, text=True)
    assert r.returncode == 2 and "usage" in r.stderr


# --- the libraries (Task 3 step 3): l2q.py at the level-1 and per-Exec arms, l2c.py at ship-300-l2 ---
import json  # noqa: E402

sys.path.insert(0, str(HERE.parent / "extract"))
import pycache_corpus  # noqa: E402

L2_QUERY = {"py_requery": "light", "py_refit": "fit"}


def lib(name):
    return json.loads((HERE / name).read_text())


def test_library_runs_l2q_for_the_level2_classes():
    for cls, q in L2_QUERY.items():
        (inv,) = lib("library.json")["classes"][cls]
        assert inv["cmd"] == "cd project && ../venv/bin/python l2q.py " + q, inv
        assert (inv["exit"], inv["nominal_ms"], inv["run_ms"], inv["cpu_ms"]) == (0, pycache_corpus.L2_DUR_MS[cls], None, None)


def test_library_l2_runs_l2c_with_the_same_py_short():
    base, l2 = lib("library.json"), lib("library-l2.json")
    assert set(l2["classes"]) == {"py_requery", "py_refit", "py_short"}
    for cls, q in L2_QUERY.items():
        (inv,) = l2["classes"][cls]
        assert inv["cmd"] == "cd project && ../venv/bin/python l2c.py " + q, inv
        # the same id, exit and planned duration as library.json's: only the program differs
        (b,) = base["classes"][cls]
        assert {k: v for k, v in inv.items() if k not in ("cmd", "id")} == {k: v for k, v in b.items() if k not in ("cmd", "id")}
    assert l2["classes"]["py_short"] == base["classes"]["py_short"]
    assert (l2["version"], l2["standin"]) == (base["version"], base["standin"])
    assert "tmpfs" not in l2  # pycache-l2 flags no session tmpfs


def test_library_commands_run_from_the_project_with_the_venv(ws):
    # the library's exact strings, run from the workspace root as the guest's wrapper runs them (cd /workspace)
    need_stack()
    srv = start(ws, "l2srv.py")
    wait_ready(srv, timeout=300)
    for name in ("library.json", "library-l2.json"):
        (inv,) = lib(name)["classes"]["py_requery"]
        r = subprocess.run(["bash", "-c", inv["cmd"]], cwd=ws.root, env=ws.env, capture_output=True, text=True)
        assert r.returncode == 0 and r.stdout.startswith("light groups="), (name, r.stdout, r.stderr)
