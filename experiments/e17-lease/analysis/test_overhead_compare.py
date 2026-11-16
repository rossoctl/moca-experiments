"""overhead_compare.py (PLAN-E17B Task 11, spec §7.4): the level-1 overhead, ship-300 against the E17a resident
patch, per default probe class, from two baseline.json files (e15/rig/baseline.sh)."""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import overhead_compare as O  # noqa: E402

SCRIPT = os.path.join(HERE, "overhead_compare.py")
REFERENCE = os.path.join(HERE, "..", "..", "e15-session-density", "results", "metal", "baseline", "default",
                         "resident-300", "N1", "baseline.json")


def baseline(tmp_path, name, medians, counts=None, corpus="c" * 64, library="l" * 64, overhead=10.0, glob=5.0):
    b = {"class_medians": medians, "class_counts": counts or {k: 20 for k in medians}, "corpus_sha256": corpus,
         "library_sha256": library, "point_sig": "p" * 64, "driver_bin_sha256": "d" * 64, "overhead_ms": overhead,
         "global_median_ms": glob, "probe_failed": {}}
    p = tmp_path / ("%s.json" % name)
    p.write_text(json.dumps(b))
    return str(p)


def test_per_class_added_latency(tmp_path):
    ship = baseline(tmp_path, "ship", {"build": 40.0, "read": 12.5, "vcs": 30.0}, overhead=35.0, glob=20.0)
    ref = baseline(tmp_path, "ref", {"build": -34.0, "read": -13.7, "wait": -60.0}, overhead=-26.0, glob=-34.1)
    r = O.compare(ship, ref)
    assert r["classes"] == {
        "build": {"ship_ms": 40.0, "reference_ms": -34.0, "added_ms": 74.0, "ship_n": 20, "reference_n": 20},
        "read": {"ship_ms": 12.5, "reference_ms": -13.7, "added_ms": 26.2, "ship_n": 20, "reference_n": 20},
    }
    assert r["only_ship"] == ["vcs"] and r["only_reference"] == ["wait"]
    assert r["overhead_ms"] == {"ship": 35.0, "reference": -26.0, "added": 61.0}
    assert r["global_median_ms"] == {"ship": 20.0, "reference": -34.1, "added": 54.1}
    assert r["same_corpus"] is True and r["same_library"] is True and r["comparable"] is True
    assert r["comparable_reasons"] == []
    assert r["median_added_ms"] == 50.1  # the median of the per-class differences (74.0, 26.2)


def test_a_different_corpus_is_not_comparable(tmp_path):
    ship = baseline(tmp_path, "ship", {"build": 1.0}, corpus="a" * 64)
    ref = baseline(tmp_path, "ref", {"build": 0.0}, corpus="b" * 64)
    r = O.compare(ship, ref)
    assert r["same_corpus"] is False and r["comparable"] is False
    assert r["classes"]["build"]["added_ms"] == 1.0  # still computed, flagged


def test_cli_prints_and_writes_json(tmp_path):
    ship = baseline(tmp_path, "ship", {"build": 40.0, "read": 12.5})
    ref = baseline(tmp_path, "ref", {"build": -34.0, "read": -13.7}, library="x" * 64)
    out = tmp_path / "overhead.json"
    p = subprocess.run([sys.executable, SCRIPT, ship, ref, "--out", str(out)], capture_output=True, text=True)
    assert p.returncode == 0, p.stderr
    lines = p.stdout.splitlines()
    assert any(ln.split()[:4] == ["build", "40.0", "-34.0", "74.0"] for ln in lines), p.stdout
    assert any(ln.split()[:4] == ["read", "12.5", "-13.7", "26.2"] for ln in lines), p.stdout
    assert "not comparable" in p.stdout  # the libraries differ
    j = json.loads(out.read_text())
    assert j["ship"]["path"] == ship and j["reference"]["path"] == ref and j["same_library"] is False


def test_cli_fails_without_class_medians(tmp_path):
    ship = tmp_path / "ship.json"
    ship.write_text(json.dumps({"calls": 3}))
    ref = baseline(tmp_path, "ref", {"build": 0.0})
    p = subprocess.run([sys.executable, SCRIPT, str(ship), ref], capture_output=True, text=True)
    assert p.returncode == 1 and "class_medians" in p.stderr


def test_reference_is_e17a_resident_patch_at_default():
    """The default reference: the resident patch's N=1 default probe (E15 metal, the patch E17a reused at default)."""
    assert os.path.normpath(O.DEFAULT_REFERENCE) == os.path.normpath(
        os.path.join("e15-session-density", "results", "metal", "baseline", "default", "resident-300", "N1", "baseline.json"))
    ref = json.load(open(REFERENCE))
    assert len(ref["class_medians"]) == 17 and all(r["dir"].startswith("/srv/e15/runs/default/resident-300/")
                                                  for r in ref["probe_runs"])
    r = O.compare(REFERENCE, REFERENCE)
    assert r["comparable"] is True and all(c["added_ms"] == 0 for c in r["classes"].values())


def test_missing_hashes_are_not_comparable(tmp_path):
    a = tmp_path / "a.json"
    b = tmp_path / "b.json"
    a.write_text(json.dumps({"class_medians": {"build": 1.0}}))
    b.write_text(json.dumps({"class_medians": {"build": 0.0}}))
    r = O.compare(str(a), str(b))
    assert r["comparable"] is False
    assert r["comparable_reasons"] == ["corpus_sha256 missing on both sides", "library_sha256 missing on both sides"]
    a.write_text(json.dumps({"class_medians": {"build": 1.0}, "corpus_sha256": "c", "library_sha256": "l"}))
    r = O.compare(str(a), str(b))
    assert r["comparable"] is False and r["comparable_reasons"] == ["corpus_sha256 missing on the reference",
                                                                   "library_sha256 missing on the reference"]
