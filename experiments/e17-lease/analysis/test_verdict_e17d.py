"""E17d's verdict (PLAN-E17D Task 6, spec §14.4): L2a-L2d from a fixture rung tree, thresholds from the predictions."""
import json
import os
import shutil
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import test_level2 as T  # noqa: E402
import verdict_e17d as VD  # noqa: E402

PIN = "a" * 40


def preds(tmp_path, sealed=True, **over):
    p = {"sealed": sealed, "min_warm": 1, "min_seeds": 1, "n_load": 128, "n1_gated": True,
         "criteria": {"L2a": {"class": "py_requery", "gain_vs_sbx_min": 0.80, "gain_vs_l1_min": 0.70},
                      "L2b": {"class": "py_refit", "gain_vs_sbx_min": 0.20},
                      "L2c": {"server_lost_rate_max": 0.5, "oom_kills_max": 1}}}
    for k, v in over.items():
        if k in ("L2a", "L2b", "L2c"):
            p["criteria"][k].update(v)
        else:
            p[k] = v
    f = tmp_path / ("preds-%d.json" % len(list(tmp_path.glob("preds-*"))))
    f.write_text(json.dumps(p))
    return str(f)


def place(tmp_path, root, d, arm, name):
    dst = root / "pycache-l2" / arm / name
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(d, dst)
    pj = dst / "params.json"
    p = json.loads(pj.read_text())
    p.update(moca_commit=PIN, guest_ram_mb=1024, n=128 if name.startswith("N128") else 1)
    pj.write_text(json.dumps(p))
    (dst / "record.json").write_text(json.dumps({"reason": "ok"}))


def tree(tmp_path, load=True, l2_warm_extra=0):
    root = tmp_path / "runs"
    src = tmp_path / "src"
    src.mkdir()
    names = ["N1-l11"] + (["N128-lat"] if load else [])
    for name in names:
        place(tmp_path, root, T.l2_rung(src, "l2-" + name), "ship-300-l2", name)
        place(tmp_path, root, T.l1_rung(src, "l1-" + name), "ship-300", name)
        place(tmp_path, root, T.sbx_rung(src, "sbx-" + name), "sbx", name)
    return str(root)


def run(root, p):
    return VD.verdict(root, PIN, p)


def test_criteria_read_their_thresholds_from_the_predictions(tmp_path):
    root = tree(tmp_path)
    r = run(root, preds(tmp_path))
    assert r["criteria"]["L2a"]["pass"] is True and r["criteria"]["L2b"]["pass"] is True
    r = run(root, preds(tmp_path, L2a={"gain_vs_l1_min": 0.99}, L2b={"gain_vs_sbx_min": 0.5}))
    assert r["criteria"]["L2a"]["pass"] is False and r["criteria"]["L2b"]["pass"] is False
    assert any("gain_vs_l1" in w for w in r["criteria"]["L2a"]["why"])


def test_a_warm_set_below_its_minimum_is_null_never_a_pass(tmp_path):
    r = run(tree(tmp_path), preds(tmp_path, min_warm=3))
    a = r["criteria"]["L2a"]
    assert a["pass"] is None and any("warm py_requery set has 2 call(s)" in m for m in a["missing"])
    assert r["pass"] is None


def test_a_missing_rung_is_null_not_run(tmp_path):
    r = run(tree(tmp_path, load=False), preds(tmp_path))
    for k in ("L2a", "L2b", "L2c"):
        assert r["criteria"][k]["pass"] is None, k
        assert any("not run" in m for m in r["criteria"][k]["missing"]), k


def test_n1_not_gated_is_left_out_and_reported(tmp_path):
    root = tree(tmp_path)
    r = run(root, preds(tmp_path, n1_gated=False))
    assert "N=1" not in r["criteria"]["L2a"]["value"] and "N=128" in r["criteria"]["L2a"]["value"]
    assert r["reported"]["n1_not_gated"]["rungs"] and all("N1-l11" in d for d in r["reported"]["n1_not_gated"]["rungs"])


def test_evidence_is_listed_by_rung(tmp_path):
    r = run(tree(tmp_path), preds(tmp_path))
    v = r["criteria"]["L2a"]["value"]
    assert set(v) == {"N=1", "N=128"} and all(len(e["rungs"]) == 3 for e in v.values())
    assert v["N=128"]["gain_n"] == {"warm": 2, "baseline_all": 3} and v["N=128"]["gain_vs_l1_n"] == {"warm": 2, "l1_warm": 2}
    assert set(r["criteria"]["L2d"]["value"]["by_rung"]) == {d for d in r["criteria"]["L2d"]["inputs"]}


def test_l2c_from_level2_with_its_thresholds(tmp_path):
    root = tree(tmp_path)
    c = run(root, preds(tmp_path))["criteria"]["L2c"]
    assert c["pass"] is True and c["value"]["oom_kills_l2srv"] == 1
    c = run(root, preds(tmp_path, L2c={"server_lost_rate_max": 0.01}))["criteria"]["L2c"]
    assert c["pass"] is False and any("server-lost" in w for w in c["why"])
    c = run(root, preds(tmp_path, L2c={"oom_kills_max": 0}))["criteria"]["L2c"]
    assert c["pass"] is False and any("OOM" in w for w in c["why"])


def test_l2d_every_judged_end_and_its_vacuous_case(tmp_path):
    r = run(tree(tmp_path), preds(tmp_path))
    d = r["criteria"]["L2d"]
    # the fixture's idle end names l2srv in its notice and has no sync line: every rung passes
    assert d["pass"] is True and all(v["judged"] == 1 for v in d["value"]["by_rung"].values())


def test_unsealed_or_incomplete_predictions_leave_everything_null(tmp_path):
    root = tree(tmp_path)
    for p in (preds(tmp_path, sealed=False), str(tmp_path / "none.json")):
        r = run(root, p)
        assert r["pass"] is None and all(c["pass"] is None for c in r["criteria"].values())
    bad = tmp_path / "bad.json"
    bad.write_text(json.dumps({"sealed": True, "criteria": {}}))
    r = run(root, str(bad))
    assert r["pass"] is None and "lacks" in r["criteria"]["L2a"]["missing"][0]


def test_top_level_pass_and_cli(tmp_path):
    root = tree(tmp_path)
    out = tmp_path / "v.json"
    VD.main([root, "--moca-commit", PIN, "--predictions", preds(tmp_path), "--out", str(out)])
    v = json.loads(out.read_text())
    assert v["pass"] is True and v["why"] == []


def test_squeeze_l2_first_refusal_and_reclaim_n(tmp_path):
    root = tree(tmp_path)
    src = tmp_path / "sq"
    src.mkdir()
    log = ['2026-11-05T11:00:00Z vmpool: memory-budget refusal workspace_key="K" why=futile short_by=1\n']
    for n in (16, 32):
        d = T.write_rung(src, "s%d" % n, "ship-300-l2", log if n == 32 else [], [], point="squeeze-l2", n=n)
        dst = os.path.join(root, "squeeze-l2", "ship-300-l2", "N%d" % n)
        shutil.copytree(d, dst)
        p = json.load(open(os.path.join(dst, "params.json")))
        p["moca_commit"] = PIN
        json.dump(p, open(os.path.join(dst, "params.json"), "w"))
    sq = run(root, preds(tmp_path))["reported"]["squeeze_l2"]["ship-300-l2"]
    assert sq["first_refusal_n"] == 32 and sq["first_reclaim_of_a_running_server_n"] is None
    assert sq["rungs"]["N32"]["refusals_by_why"] == {"futile": 1}
