"""Group aggregates and feature scaling.

The aggregate is built shard by shard (sums and counts per group), so it never needs the whole
dataset in memory; the result is the per-group mean of every value column.
"""

import numpy as np
import pandas as pd

from pyc import config


class GroupAggregate:
    """Running per-group sums, sums of squares and counts over the value columns."""

    def __init__(self):
        self.sums = None
        self.squares = None
        self.counts = None

    def add(self, frame):
        values = frame[list(config.VALUE_COLUMNS)]
        grouped = values.groupby(frame["g"])
        sums = grouped.sum()
        squares = (values * values).groupby(frame["g"]).sum()
        counts = grouped.size()
        if self.sums is None:
            self.sums, self.squares, self.counts = sums, squares, counts
        else:
            self.sums = self.sums.add(sums, fill_value=0)
            self.squares = self.squares.add(squares, fill_value=0)
            self.counts = self.counts.add(counts, fill_value=0)

    def means(self):
        return self.sums.div(self.counts, axis=0)

    def variances(self):
        mean = self.means()
        return self.squares.div(self.counts, axis=0) - mean * mean

    def rows(self):
        return 0 if self.counts is None else int(self.counts.sum())


def aggregate(frame):
    """Per-group mean of one frame (the same as GroupAggregate over that frame alone)."""
    agg = GroupAggregate()
    agg.add(frame)
    return agg.means()


def standardize(x):
    """Columns scaled to mean 0 and standard deviation 1 (a constant column stays 0)."""
    x = np.asarray(x, dtype=np.float64)
    mean = x.mean(axis=0)
    std = x.std(axis=0)
    std[std == 0] = 1.0
    return (x - mean) / std


def to_frame(x, names=None):
    """A 2-D array as a frame with x0.. column names."""
    x = np.asarray(x)
    names = names or [f"x{i}" for i in range(x.shape[1])]
    return pd.DataFrame(x, columns=names)
