import gzip
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import measured_delta as M  # noqa: E402


def rung(tmp, used, imgs, gz=False):
    (tmp / "params.json").write_text(json.dumps({"workspaces_precreated": imgs}))
    body = "\n".join(json.dumps({"t": i, "disk_used_kb": u}) for i, u in enumerate(used))
    if gz:
        with gzip.open(tmp / "samples.jsonl.gz", "wt") as f:
            f.write(body)
    else:
        (tmp / "samples.jsonl").write_text(body)
    return str(tmp)


def test_peak_growth_per_image_times_1_5(tmp_path):
    # 5120 images, peak growth 10 GiB -> 2 MiB/image x 1.5 = 3 MiB
    assert M.main(rung(tmp_path, [100, 100 + 10 * 1024 * 1024, 200], 5120)) == 3


def test_floor_2_mib(tmp_path):
    assert M.main(rung(tmp_path, [100, 110, 105], 5120)) == 2


def test_gz_samples(tmp_path):
    assert M.main(rung(tmp_path, [0, 40 * 1024 * 1024], 1024, gz=True)) == 60


def test_no_samples_refuses(tmp_path):
    import pytest
    (tmp_path / "params.json").write_text(json.dumps({"workspaces_precreated": 8}))
    (tmp_path / "samples.jsonl").write_text(json.dumps({"t": 0}))
    with pytest.raises(SystemExit):
        M.main(str(tmp_path))
