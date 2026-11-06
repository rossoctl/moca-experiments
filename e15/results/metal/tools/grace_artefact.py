"""grace_artefact.py RUNG_DIR -> prints "yes" if the rung's ONLY condition-1 failures are calls cancelled by the
grace-end cut (cause deadline, execs >= 1, send + observed within 1 s of warmup+window+grace), else "no"."""
import json
import os
import sys

d = sys.argv[1]
p = json.load(open(os.path.join(d, "params.json")))
ge = (p["warmup_s"] + p["window_s"] + p["grace_s"]) * 1000.0
fails = []
for line in open(os.path.join(d, "calls.jsonl")):
    c = json.loads(line)
    if not c.get("in_window") or c.get("status") != "err":
        continue
    cause = c.get("cause", "")
    if (cause == "deadline" and c.get("execs", 0) == 0) or cause == "cut_at_end":
        continue  # not failures under holds.py
    fails.append(c)
art = [c for c in fails if c.get("cause") == "deadline" and c.get("execs", 0) >= 1
       and abs(c["t_ms"] + c["observed_ms"] - ge) <= 1000]
print("yes" if fails and len(art) == len(fails) else "no")
