"""E17d's level-2 server (spec §14.2): load the frame once, then answer queries on a unix socket.

  cd project && ../venv/bin/python l2srv.py       (the driver's process_start: cwd /workspace/project, name l2srv)

The socket appears only once the frame is loaded and the socket listens: it is bound under a temporary name in the
same directory and renamed onto l2c.SOCK, so a client never connects to a half-bound socket, and a stale socket file
a dead server left is replaced in one step. The directory (/workspace/.l2) and the socket are group-writable: a
tracked process runs under its own uid and an Exec under the Exec uid, both in group sbx-ws (spec §14.5).

Protocol: one request line per connection, one answer line back. `ping` answers `pong` at once, even while a query
runs (each connection has its own thread); queries run one at a time (a lock), so two never hold their transient
memory together. An unknown query or a query that raises answers `ERR <why>` (the client's exit 4).
"""

import os
import socket
import sys
import threading
import time

from l2c import SOCK


def bind_listening(path):
    """A listening socket at path, bound under a temporary name and renamed onto path."""
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    try:
        os.chmod(d, 0o775)
    except OSError:
        pass  # made by another uid of the group (an earlier tracked process); it is group-writable already
    tmp = os.path.join(d, ".%s.%d.tmp" % (os.path.basename(path), os.getpid()))
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(tmp)
    os.chmod(tmp, 0o660)
    s.listen(16)
    os.rename(tmp, path)
    return s


def answer(line, queries, state, lock):
    if line == "ping":
        return "pong"
    q = queries.get(line)
    if q is None:
        return "ERR unknown query %r" % line[:64]
    with lock:
        t = time.time()
        try:
            r = q(*state)
        except Exception as e:  # noqa: BLE001 -- any failure of the query is the client's exit 4
            return "ERR %s: %s" % (type(e).__name__, e)
        return "%s server_ms=%.0f" % (r, (time.time() - t) * 1000)


def handle(c, queries, state, lock):
    try:
        c.settimeout(30)
        buf = b""
        while b"\n" not in buf and len(buf) < 256:
            b = c.recv(256)
            if not b:
                break
            buf += b
        c.sendall((answer(buf.decode(errors="replace").strip(), queries, state, lock) + "\n").encode())
    except OSError:
        pass
    finally:
        c.close()


def serve(path, queries, load, ready=sys.stdout):
    """Load (load() -> the state each query gets), bind, then answer forever."""
    t0 = time.time()
    state = load()
    s = bind_listening(path)
    ready.write("ready load_ms=%.0f sock=%s\n" % ((time.time() - t0) * 1000, path))
    ready.flush()
    lock = threading.Lock()
    while True:
        c, _ = s.accept()
        threading.Thread(target=handle, args=(c, queries, state, lock), daemon=True).start()


def main():
    import l2common

    serve(SOCK, l2common.QUERIES, l2common.load)


if __name__ == "__main__":
    main()
