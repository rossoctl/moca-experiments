#!/usr/bin/env python3
"""merge_shared.py DIR: DIR/ladder.first.json (full ladder) + DIR/ladder.json (re-run from the
§12-flagged rung) -> DIR/ladder.json merged: rungs below the re-run start from the first ladder,
rungs from it on from the re-run; n_max / n_max_abs recomputed. Originals kept as
ladder.first.json and ladder.shared-rerun.json."""
import json, os, sys
d = sys.argv[1]
first = json.load(open(os.path.join(d, "ladder.first.json")))
rerun_p = os.path.join(d, "ladder.shared-rerun.json")
if not os.path.exists(rerun_p):
    os.rename(os.path.join(d, "ladder.json"), rerun_p)
rerun = json.load(open(rerun_p))
s = rerun["start_n"]
rungs = [r for r in first["rungs"] if r["n"] < s] + rerun["rungs"]
def walk(key):
    nm = st = None
    for r in rungs:
        if r[key]:
            nm = r["n"]
        else:
            st = r["n"]; break
    return nm, st
out = dict(first)
out["rungs"] = rungs
out["n_max"], out["stopped_at"] = walk("holds")
out["n_max_abs"], out["stopped_at_abs"] = walk("holds_abs")
out["shared_host_rerun_from"] = s
out["note"] = "merged: rungs < %d from ladder.first.json, rungs >= %d from the SPEC §12 re-run (ladder.shared-rerun.json)" % (s, s)
json.dump(out, open(os.path.join(d, "ladder.json"), "w"), indent=2)
print(out["n_max"], out["stopped_at"], out["n_max_abs"], out["stopped_at_abs"])
