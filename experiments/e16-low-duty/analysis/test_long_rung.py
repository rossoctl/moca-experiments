import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import long_rung as LR

HERE = os.path.dirname(os.path.abspath(__file__))
RUNG = os.path.join(HERE, "..", "..", "..", "experiments", "e15-session-density", "results", "metal", "default", "resident-inf", "N128-repeat")


def test_e15_rung_lives_and_lag():
    r = LR.analyse(RUNG)
    L = r["lives"]
    assert L["vms"] == 475 and L["ended_in_run"] + L["censored_at_run_end"] == 475
    # fix round 1's ~12 min lag came from VMs cut at the run's end (censored here); VMs whose session
    # ended on its own are destroyed right after the last call
    assert L["censored_at_run_end"] > 40
    assert L["last_exec_to_destroy_min"]["median"] < 0.1
    assert set(r["growth_20_to_60_120_180"]) == {"60", "120", "180"}
    assert r["growth_20_to_60_120_180"]["60"]["enough"] is False  # E15 VMs never reach 60 min


def test_cli(tmp_path):
    LR.main([RUNG, "--out", str(tmp_path / "x")])
    md = (tmp_path / "x.md").read_text()
    assert "VM memory at 2.5 h" in md and "last Exec to destroy" in md
