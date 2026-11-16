"""E17's py_analyze command: read every shard, aggregate by group, fit KMeans on a fixed sample.

Run from the project directory (the library's `cd project && ../venv/bin/python analyze.py`).
Prints one line,

    rows=<n> sha256=<hex of all shard bytes in order> clusters=<inertia rounded to 3 dp>

where the sha256 covers the raw shard bytes exactly as on disk, so a check can compare it with the
generator's own hash (BUILD's dataset_sha256) and know every byte was read. The fit is repeated
config.ANALYZE_WORK_SCALE times (the CPU knob); the printed inertia is the first fit's.

With PYC_CACHE_DIR set (E17b: a tmpfs session's /tmp/pycache-<workspace key>), the bytecode of every
module imported below goes to PYC_CACHE_DIR/pyc and the KMeans sample to PYC_CACHE_DIR/dataset
(pyc/cache.py); the printed line is the same. Unset, nothing is cached, as in E17a.
"""

import hashlib
import os
import sys

CACHE_DIR = os.environ.get("PYC_CACHE_DIR") or None
if CACHE_DIR:  # before the first import that compiles: pyc, numpy, pandas, scikit-learn
    sys.pycache_prefix = os.path.join(CACHE_DIR, "pyc")

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "src"))

from pyc import cache, config, data, features, model  # noqa: E402


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
    sample = sampler.sample()
    if CACHE_DIR:
        cache.check_or_store_sample(CACHE_DIR, digest.hexdigest(), sample)
    km = model.fit_repeated(sample, config.ANALYZE_WORK_SCALE)
    print(f"rows={agg.rows()} sha256={digest.hexdigest()} clusters={model.inertia(km):.3f}")


if __name__ == "__main__":
    main()
