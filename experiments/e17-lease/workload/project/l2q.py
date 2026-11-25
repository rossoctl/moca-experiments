"""E17d's per-Exec and level-1 query (spec §14.2): import, load, one query, exit.

  cd project && ../venv/bin/python l2q.py QUERY      (QUERY: light or fit, l2common.QUERIES)

Prints the same result line l2c.py gets from l2srv.py for the same query on the same data (without the server's
server_ms), and its own timings on stderr.
"""

import sys
import time

import l2common


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1 or argv[0] not in l2common.QUERIES:
        sys.stderr.write("usage: l2q.py {%s}\n" % ",".join(sorted(l2common.QUERIES)))
        return 2
    df, x = l2common.load()
    t = time.time()
    print(l2common.QUERIES[argv[0]](df, x))
    sys.stderr.write("l2q: query_ms=%.0f total_ms=%.0f\n" % ((time.time() - t) * 1000, (time.time() - l2common.T0) * 1000))
    return 0


if __name__ == "__main__":
    sys.exit(main())
