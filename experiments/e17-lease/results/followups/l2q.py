# From scratch: import, load, one query, exit (per-Exec and level 1).
import sys, time
exec(open("../l2common.py").read())
df, x = load()
t = time.time()
r = Q[sys.argv[1]](df, x)
print("%s query_ms=%.0f total_ms=%.0f" % (r, (time.time() - t) * 1000, (time.time() - T0) * 1000))
