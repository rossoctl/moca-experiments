import io
import json
import os
import sys
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import chainlib as C

LADDER = [1, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 128, 160, 192, 256, 320, 384, 448, 512, 576, 640, 704, 768, 896, 1024]


def put(arm, n, seed, holds, holds_abs=None):
    sfx = "" if seed == 1 else "-s%d" % seed
    os.makedirs(os.path.join(arm, "e16"), exist_ok=True)
    json.dump({"n": n, "seed": seed, "holds": holds, "holds_abs": holds if holds_abs is None else holds_abs},
              open(os.path.join(arm, "e16", "N%d%s.json" % (n, sfx)), "w"))


def out(fn, *a):
    b = io.StringIO()
    with redirect_stdout(b):
        fn(*a)
    return b.getvalue().strip()


def test_assemble_gaps_and_stepdown(tmp_path):
    arm = str(tmp_path)
    for n, h in ((256, False), (192, False), (160, True)):  # run in descending order
        put(arm, n, 1, h)
    assert out(C.assemble, arm, "lowduty", "sbx", LADDER) == "160 192 160 192"
    d = json.load(open(os.path.join(arm, "ladder.json")))
    assert d["rungs_run"] == [160, 192, 256]
    assert d["rungs_not_run_assumed_held"] == [1, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 128]


def test_assemble_gap_between_run_rungs(tmp_path):
    arm = str(tmp_path)
    for n, h in ((256, True), (384, True), (512, False), (448, True)):
        put(arm, n, 1, h)
    out(C.assemble, arm, "lowduty", "sbx", LADDER)
    d = json.load(open(os.path.join(arm, "ladder.json")))
    assert (d["n_max"], d["stopped_at"]) == (448, 512)
    assert 320 in d["rungs_not_run_assumed_held"] and 448 not in d["rungs_not_run_assumed_held"]


def test_seed_majority_and_undecided(tmp_path):
    arm = str(tmp_path)
    put(arm, 256, 1, True)
    put(arm, 384, 1, False)
    put(arm, 384, 2, True)
    out(C.assemble, arm, "lowduty", "sbx", LADDER)
    d = json.load(open(os.path.join(arm, "ladder.json")))
    assert d["n_max"] == 256 and d["seeds_undecided"] == [384]  # s1 stands until s3
    put(arm, 384, 3, True)
    out(C.assemble, arm, "lowduty", "sbx", LADDER)
    d = json.load(open(os.path.join(arm, "ladder.json")))
    assert d["n_max"] == 384 and d["stopped_at"] is None and d["seeds_undecided"] == []


def test_abs_ladder_independent(tmp_path):
    arm = str(tmp_path)
    put(arm, 256, 1, False, True)
    put(arm, 384, 1, False, False)
    assert out(C.assemble, arm, "lowduty", "sbx", LADDER) == "null 256 256 384"


def test_bisect():
    assert out(C.bisect, 384, 512, LADDER) == "448"
    assert out(C.bisect, 512, 640, LADDER) == "576"
    assert out(C.bisect, 160, 192, LADDER) == ""
    assert out(C.bisect, 768, 1024, LADDER) == "896"
    assert out(C.bisect, 512, 768, LADDER) == "640"


def test_reason_of():
    assert C.reason_of({"holds": True}) == "none"
    assert C.reason_of({"holds": False, "conditions": {"added_latency": False, "pace": True}}) == "added_latency"
    assert C.reason_of({"holds": False, "reason": "memory_floor"}) == "memory_floor"


def test_assemble_keeps_post_seal_label(tmp_path):
    arm = str(tmp_path)
    put(arm, 1024, 1, True)
    out(C.assemble, arm, "lowduty", "sbx", LADDER + [1280, 1536])
    d = json.load(open(os.path.join(arm, "ladder.json")))
    d["post_seal_extension"] = {"rungs": [1280, 1536]}
    json.dump(d, open(os.path.join(arm, "ladder.json"), "w"))
    put(arm, 1280, 1, False)
    out(C.assemble, arm, "lowduty", "sbx", LADDER + [1280, 1536])
    d = json.load(open(os.path.join(arm, "ladder.json")))
    assert d["post_seal_extension"] == {"rungs": [1280, 1536]} and d["stopped_at"] == 1280
