"""measured_delta.py RUNG_DIR -> the per-image disk delta to size the next climb rung's disk check with, in MiB
(integer, printed): (peak disk_used_kb over the rung - disk_used_kb at its first sample) / images pre-created,
x 1.5, floor 2 MiB. Supplementary-climb disk sizing on fresh-metal (ruling 2026-11-06): reflinked workspace
images un-share only the blocks a guest writes, and most pre-created images are never opened, so the static
22 MiB-per-image estimate overstates a rung's disk use ~10x. The < 10 GiB free sentinel stays the real guard.
Reads RUNG_DIR/samples.jsonl or samples.jsonl.gz and params.json (workspaces_precreated)."""
import gzip
import json
import math
import os
import sys

FLOOR_MIB, FACTOR = 2, 1.5


def main(d):
    p = json.load(open(os.path.join(d, "params.json")))
    path = os.path.join(d, "samples.jsonl")
    op = open if os.path.exists(path) else (lambda f: gzip.open(f, "rt"))
    if not os.path.exists(path):
        path += ".gz"
    used = [json.loads(x).get("disk_used_kb") for x in op(path) if x.strip()]
    used = [u for u in used if u is not None]
    imgs = p.get("workspaces_precreated") or 0
    if not used or not imgs:
        raise SystemExit("measured_delta: no disk_used_kb samples or no workspaces_precreated in %s" % d)
    growth_kb = max(0, max(used) - used[0])
    mib = growth_kb / 1024.0 / imgs * FACTOR
    return max(FLOOR_MIB, int(math.ceil(mib)))


if __name__ == "__main__":
    print(main(sys.argv[1]))
