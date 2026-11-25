"""E17d's level-2 workload (spec §14.2): the loaded frame and the two queries, shared by l2srv.py and l2q.py.

Ported from the E17a follow-up spike (results/followups/l2common.py). Run from the project directory with the
workspace venv (`cd project && ../venv/bin/python l2srv.py` or `... l2q.py <query>`): src/pyc is found beside this
file, and config.DATA_DIR (../data) is relative to the working directory, as for every library command.

  load()        every shard's frame concatenated, and the model's fixed 200k-row sample
  QUERIES       name -> f(df, x) -> one result line:
                  light  group means of the six values, then the median of x0 (the spike's light query: one
                         column's median; the six-column quantiles OOM-killed the spike's first run)
                  fit    the KMeans fit on the sample, repeated config.ANALYZE_WORK_SCALE times (the spike's fit)
"""

import hashlib
import os
import sys
import time

T0 = time.time()
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "src"))

import pandas as pd  # noqa: E402

from pyc import config, data, model  # noqa: E402

VALUES = list(config.VALUE_COLUMNS)


def load():
    """(frame, sample): every shard in order, and the sample the fit runs on."""
    paths = data.shard_paths(config.DATA_DIR)
    sampler = model.Sampler(data.estimated_rows(paths))
    frames = []
    for f in data.iter_shards(paths, hashlib.sha256()):
        frames.append(f)
        sampler.add(f)
    return pd.concat(frames, ignore_index=True), sampler.sample()


def q_light(df, x):
    m = df.groupby("g")[VALUES].mean()
    return "light groups=%d median_x0=%.3f" % (len(m), df["x0"].median())


def q_fit(df, x):
    return "fit inertia=%.3f" % model.inertia(model.fit_repeated(x, config.ANALYZE_WORK_SCALE))


QUERIES = {"light": q_light, "fit": q_fit}
