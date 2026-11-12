"""E17's py_analyze command: read every shard, aggregate by group, fit KMeans on a fixed sample.

Run from the project directory (the library's `cd project && ../venv/bin/python analyze.py`).
Prints one line,

    rows=<n> sha256=<hex of all shard bytes in order> clusters=<inertia rounded to 3 dp>

where the sha256 covers the raw shard bytes exactly as on disk, so a check can compare it with the
generator's own hash (BUILD's dataset_sha256) and know every byte was read. The fit is repeated
config.ANALYZE_WORK_SCALE times (the CPU knob); the printed inertia is the first fit's.
"""

import hashlib
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "src"))

from pyc import config, data, features, model  # noqa: E402


def main():
    paths = data.shard_paths(config.DATA_DIR)
    digest = hashlib.sha256()
    agg = features.GroupAggregate()
    sampler = model.Sampler(data.estimated_rows(paths))
    for frame in data.iter_shards(paths, digest):
        agg.add(frame)
        sampler.add(frame)
    means = agg.means()
    if len(means) == 0 or means.isna().to_numpy().any():
        raise SystemExit("analyze.py: empty group aggregate")
    km = model.fit_repeated(sampler.sample(), config.ANALYZE_WORK_SCALE)
    print(f"rows={agg.rows()} sha256={digest.hexdigest()} clusters={model.inertia(km):.3f}")


if __name__ == "__main__":
    main()
