"""The clustering step: a fixed sample of the dataset and a seeded KMeans fit.

The sample is every stride-th row of the dataset (stride from the shards' sizes), so it is the
same rows for the same shards and spans every shard. The fit is single-start and seeded, so the
same sample gives the same inertia.
"""

import numpy as np
from sklearn.cluster import KMeans

from pyc import config
from pyc.data import stride_rows


class Sampler:
    """Collects at most `size` rows, every `stride`-th row of the frames fed in order."""

    def __init__(self, total_rows, size=config.SAMPLE_ROWS):
        self.size = size
        self.stride = max(1, total_rows // size)
        self.offset = 0
        self.parts = []
        self.taken = 0

    def add(self, frame):
        if self.taken < self.size:
            part = stride_rows(frame, self.offset, self.stride)[list(config.VALUE_COLUMNS)]
            # A copy, not a view: a view would keep the whole shard's frame alive until the fit.
            part = part.iloc[: self.size - self.taken].to_numpy(dtype=np.float64, copy=True)
            self.parts.append(part)
            self.taken += len(part)
        self.offset += len(frame)

    def sample(self):
        return np.concatenate(self.parts)


def fit(x, n_clusters=config.N_CLUSTERS, random_state=config.RANDOM_STATE):
    """The seeded single-start KMeans fit of x."""
    km = KMeans(n_clusters=n_clusters, n_init=config.N_INIT, random_state=random_state,
                max_iter=config.MAX_ITER, tol=config.TOLERANCE)
    km.fit(x)
    return km


def fit_repeated(x, repeats):
    """The fit with random_state RANDOM_STATE, after repeats - 1 more fits with the next states.

    The extra fits are analyze.py's CPU work (config.ANALYZE_WORK_SCALE); their results are
    discarded, so the returned fit is the same for every repeats >= 1.
    """
    if repeats < 1:
        raise ValueError(f"repeats must be >= 1, not {repeats}")
    first = fit(x)
    for k in range(1, repeats):
        fit(x, random_state=config.RANDOM_STATE + k)
    return first


def inertia(km):
    return round(float(km.inertia_), 3)
