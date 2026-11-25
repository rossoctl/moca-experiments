"""E17d's level-2 client (spec §14.2): one query to the l2srv.py server over its unix socket.

  cd project && ../venv/bin/python l2c.py [--wait S] QUERY

First the probe: connect to the socket and send `ping`, bounded at PROBE_S (2 s) in all. The probe is the only test of
"is a server there": it fails on no socket, a refused connection (a stale socket file a dead server left), or no
`pong` within the bound. Then the query on a new connection, with its own bound QUERY_S (120 s: the fit takes about
11 s server-side). Exit codes (the driver's restart rule reads 3, and only 3):

  0  the result line on stdout (for QUERY ping, `pong`: the probe alone)
  3  the probe failed: no server answered (with --wait S, not within S seconds)
  4  the server answered the query with an error
  5  the query passed its bound, or the connection broke during it

--wait S polls the probe (connect and ping; never the socket file's existence) every 0.2 s for up to S seconds
before the query, so a stale socket file and a server still loading are waited out. The socket is SOCK
(/workspace/.l2/l2.sock; L2_SOCK overrides it, for tests). No pandas here: a client starts in milliseconds.
"""

import argparse
import os
import socket
import sys
import time

SOCK = os.environ.get("L2_SOCK", "/workspace/.l2/l2.sock")
PROBE_S = 2.0
QUERY_S = 120.0
POLL_S = 0.2
EXIT_OK, EXIT_NO_SERVER, EXIT_SERVER_ERROR, EXIT_QUERY_BOUND = 0, 3, 4, 5


class Bound(Exception):
    """The exchange passed its bound (deadline) or the connection broke before a whole line came back."""


def exchange(path, request, bound_s):
    """Send request on a new connection and return the server's one-line answer, all within bound_s.
    Raises OSError when the connection cannot be made, Bound when no whole answer came back in time."""
    deadline = time.monotonic() + bound_s
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.settimeout(bound_s)
        s.connect(path)
        s.sendall((request + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            left = deadline - time.monotonic()
            if left <= 0:
                raise Bound("no answer within %.0f s" % bound_s)
            s.settimeout(left)
            try:
                b = s.recv(65536)
            except socket.timeout:
                raise Bound("no answer within %.0f s" % bound_s)
            if not b:
                raise Bound("the server closed the connection before a whole answer")
            buf += b
        return buf.decode().strip()
    finally:
        s.close()


def probe(path):
    """True when a server answers ping with pong within PROBE_S."""
    try:
        return exchange(path, "ping", PROBE_S).startswith("pong")
    except (OSError, Bound):
        return False


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--wait", type=float, default=0.0, metavar="S",
                   help="poll the probe every %.1f s for up to S seconds before giving up (default 0: one probe)" % POLL_S)
    p.add_argument("query")
    a = p.parse_args(argv)
    t0 = time.monotonic()
    ok = probe(SOCK)
    while not ok and time.monotonic() - t0 < a.wait:
        time.sleep(POLL_S)
        ok = probe(SOCK)
    if not ok:
        sys.stderr.write("l2c: no server answered the probe on %s%s\n" % (SOCK, " within %g s" % a.wait if a.wait else ""))
        return EXIT_NO_SERVER
    if a.query == "ping":
        print("pong")
        return EXIT_OK
    t1 = time.monotonic()
    try:
        ans = exchange(SOCK, a.query, QUERY_S)
    except (OSError, Bound) as e:
        sys.stderr.write("l2c: query %s: %s\n" % (a.query, e))
        return EXIT_QUERY_BOUND
    if ans.startswith("ERR"):
        sys.stderr.write("l2c: query %s: %s\n" % (a.query, ans))
        return EXIT_SERVER_ERROR
    print(ans)
    sys.stderr.write("l2c: query_ms=%.0f probe_ms=%.0f\n" % ((time.monotonic() - t1) * 1000, (t1 - t0) * 1000))
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
