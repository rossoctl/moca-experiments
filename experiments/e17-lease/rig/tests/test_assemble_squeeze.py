import json
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import assemble_squeeze as A  # noqa: E402


def write(d, part1_n=(1, 8, 16), start=24, part2_n=(24, 32), stop=32):
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "ladder-rungs.part1.jsonl"), "w") as f:
        for n in part1_n:
            f.write(json.dumps({"n": n, "holds": False, "dir": "N%d-repeat" % n}) + "\n")
    with open(os.path.join(d, "ladder-squeeze.part1.jsonl"), "w") as f:
        for n in part1_n:
            f.write(json.dumps({"n": n, "met": False, "dir": "N%d-repeat" % n}) + "\n")
    with open(os.path.join(d, "ladder.json"), "w") as f:
        json.dump({"point": "squeeze", "arm": "ship-300", "start_n": start, "rungs_below_start_assumed_held": True,
                   "rungs": [{"n": n, "dir": "N%d" % n} for n in part2_n],
                   "squeeze": {"memmax_mb": 24576, "stop_n": stop, "stopped_by": "reclaim_rate",
                               "rungs": [{"n": n, "met": n == stop, "dir": "N%d" % n} for n in part2_n]}}, f)


def test_assembles_both_parts_in_order_and_keeps_part2(tmp_path):
    d = str(tmp_path / "a")
    write(d)
    out = A.assemble(d)
    assert [r["n"] for r in out["rungs"]] == [1, 8, 16, 24, 32]
    assert [r["n"] for r in out["squeeze"]["rungs"]] == [1, 8, 16, 24, 32]
    assert out["start_n"] == 1 and out["rungs_below_start_assumed_held"] is False
    assert out["squeeze"]["stop_n"] == 32 and out["squeeze"]["memmax_mb"] == 24576
    assert out["assembled"]["part1_n"] == [1, 8, 16] and out["assembled"]["part2_start_n"] == 24
    p2 = json.load(open(os.path.join(d, "ladder.part2.json")))
    assert p2["start_n"] == 24 and [r["n"] for r in p2["rungs"]] == [24, 32]
    # idempotent: a second run re-assembles from the kept part 2, not from the assembled file
    again = A.assemble(d)
    assert [r["n"] for r in again["rungs"]] == [1, 8, 16, 24, 32]


@pytest.mark.parametrize("kw,why", [
    (dict(part1_n=(1, 8, 16, 24)), "counted twice"),
    (dict(start=1, part2_n=(1, 8)), "above N=1"),
])
def test_refuses_inconsistent_parts_and_writes_nothing(tmp_path, kw, why):
    d = str(tmp_path / "b")
    write(d, **kw)
    before = open(os.path.join(d, "ladder.json")).read()
    with pytest.raises(ValueError, match=why):
        A.assemble(d)
    assert open(os.path.join(d, "ladder.json")).read() == before
    assert not os.path.exists(os.path.join(d, "ladder.part2.json"))


def test_main_exit_codes(tmp_path):
    d = str(tmp_path / "c")
    write(d)
    assert A.main(["x", d]) == 0
    assert A.main(["x", str(tmp_path / "missing")]) == 1
    assert A.main(["x"]) == 2
