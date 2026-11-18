#!/usr/bin/env python3
"""E17b: assemble a squeeze climb's ladder.json from a part stopped by a rig error and its resumed part (ruling E17B-R51).

  python3 experiments/e17-lease/rig/assemble_squeeze.py ARM_DIR

ARM_DIR is $E15_RUNS/<squeeze point>/ship-300. It holds part 1's per-rung rows, ladder-rungs.part1.jsonl and
ladder-squeeze.part1.jsonl (ladder.sh's own files, copied before the resume truncated them), and ladder.json from the
resumed climb (ladder.sh POINT ARM START_N, START_N the rung the rig error stopped). Writes ladder.part2.json (the
resumed climb's ladder.json, unchanged) and a new ladder.json: part 2's, with part 1's rows before its own in `rungs`
and `squeeze.rungs`, start_n 1, rungs_below_start_assumed_held false and `assembled` saying how. The precedent is E15
metal's default resident ladders (ladder.part2.json, RESULTS-METAL.md). Part 1 rows at or above part 2's start_n are
refused (a rung counted twice). Exit 1 on missing or inconsistent inputs; nothing is written then.
"""
import json
import os
import sys


def rows(path):
    with open(path) as f:
        return [json.loads(l) for l in f if l.strip()]


def assemble(arm_dir):
    lj = os.path.join(arm_dir, "ladder.json")
    p2 = os.path.join(arm_dir, "ladder.part2.json")
    src = p2 if os.path.exists(p2) else lj  # a second run re-assembles from the kept part 2
    with open(src) as f:
        part2 = json.load(f)
    r1 = rows(os.path.join(arm_dir, "ladder-rungs.part1.jsonl"))
    s1 = rows(os.path.join(arm_dir, "ladder-squeeze.part1.jsonl"))
    if "squeeze" not in part2:
        raise ValueError("%s has no squeeze block: not a squeeze climb" % src)
    start = part2.get("start_n")
    if not isinstance(start, int) or start <= 1:
        raise ValueError("%s start_n %r: the resumed part must start above N=1" % (src, start))
    late = [r["n"] for r in r1 + s1 if r["n"] >= start]
    if late:
        raise ValueError("part 1 rows at N %s are at or above part 2's start_n %d (counted twice)" % (late, start))
    if [r["n"] for r in r1] != [r["n"] for r in s1]:
        raise ValueError("part 1's rungs and squeeze rows list different N")
    out = dict(part2)
    out["rungs"] = r1 + list(part2.get("rungs") or [])
    out["squeeze"] = dict(part2["squeeze"], rungs=s1 + list(part2["squeeze"].get("rungs") or []))
    out["start_n"] = 1
    out["rungs_below_start_assumed_held"] = False
    out["assembled"] = {"ruling": "E17B-R51", "part1_n": [r["n"] for r in r1], "part2_start_n": start,
                        "part2": "ladder.part2.json",
                        "why": "part 1 stopped on a rig error (the disk preflight refused the N=%d repeat); "
                               "part 2 resumed at that rung" % start}
    if src == lj:
        with open(p2, "w") as f:
            json.dump(part2, f, indent=2)
    with open(lj, "w") as f:
        json.dump(out, f, indent=2)
    return out


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    try:
        out = assemble(argv[1])
    except (OSError, ValueError, KeyError) as e:
        print("assemble_squeeze.py: %s" % e, file=sys.stderr)
        return 1
    print("assembled %s: rungs %s, squeeze stop_n %s" % (os.path.join(argv[1], "ladder.json"),
                                                        [r["n"] for r in out["rungs"]], out["squeeze"].get("stop_n")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
