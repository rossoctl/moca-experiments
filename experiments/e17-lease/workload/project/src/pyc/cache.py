"""The dataset cache of a run with PYC_CACHE_DIR (E17b, spec §7.3).

The driver sets PYC_CACHE_DIR=/tmp/pycache-<workspace key> for the py_analyze and py_test calls of a
session flagged tmpfs (library.json "tmpfs"), so the caches below live in the guest's tmpfs and stay
in guest RAM until the VM goes. Two caches:
  - the dependency cache: the bytecode of every module analyze.py or the tests import after the
    variable is read (sys.pycache_prefix = DIR/pyc, set by analyze.py and tests/conftest.py before
    they import numpy, pandas or scikit-learn); the venv's own bytecode is not used then;
  - the dataset cache (here): analyze.py's KMeans sample, DIR/dataset/sample-<dataset sha256>.npy.
A run that finds the sample checks it against the one it has just drawn and fails on a mismatch:
the cache is never trusted, so every run still reads every shard byte and does the same fits. The
sample is SAMPLE_ROWS x 6 float64 (about 9.6 MB) whatever the dataset's size: a copy of the
dataset itself would not fit the 768 MiB squeeze point's 1 GiB guest, nor a default /tmp tmpfs
(half the guest's RAM).
Without PYC_CACHE_DIR there is no cache at all, as in E17a.
"""

import os

import numpy as np

ENV = "PYC_CACHE_DIR"


def sample_path(cache_dir, dataset_sha256):
    return os.path.join(cache_dir, "dataset", "sample-%s.npy" % dataset_sha256)


def check_or_store_sample(cache_dir, dataset_sha256, sample):
    """Store the sample under the dataset's sha256, or check it against the stored one. Returns
    True when it was stored; exits on a stored sample that is unreadable or differs."""
    path = sample_path(cache_dir, dataset_sha256)
    if os.path.exists(path):
        try:
            cached = np.load(path, allow_pickle=False)
        except (OSError, ValueError) as e:
            raise SystemExit(f"analyze.py: dataset cache {path} is unreadable: {e}")
        if cached.shape != sample.shape or not np.array_equal(cached, sample):
            raise SystemExit(f"analyze.py: dataset cache {path} does not match the dataset")
        return False
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.tmp-%d" % (path, os.getpid())
    with open(tmp, "wb") as f:
        np.save(f, sample, allow_pickle=False)
    os.replace(tmp, path)
    return True
