# Level 2 stand-in: load once, then serve queries on a unix socket.
import os, socket, time
exec(open("../l2common.py").read())
df, x = load()
load_ms = (time.time() - T0) * 1000
try:
    os.unlink("/tmp/l2.sock")
except FileNotFoundError:
    pass
s = socket.socket(socket.AF_UNIX)
s.bind("/tmp/l2.sock.tmp")
s.listen(4)
os.rename("/tmp/l2.sock.tmp", "/tmp/l2.sock")
print("ready load_ms=%.0f rows=%d" % (load_ms, len(df)), flush=True)
while True:
    c, _ = s.accept()
    name = c.recv(64).decode().strip()
    t = time.time()
    r = Q[name](df, x)
    c.sendall(("%s server_ms=%.0f\n" % (r, (time.time() - t) * 1000)).encode())
    c.close()
