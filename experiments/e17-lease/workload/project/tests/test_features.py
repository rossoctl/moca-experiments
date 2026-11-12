import numpy as np
import pandas as pd
import pytest
import sklearn  # noqa: F401
from sklearn.preprocessing import StandardScaler

from conftest import reps
from pyc import config, features


def frame(rng, rows):
    f = pd.DataFrame(rng.uniform(0, 100, size=(rows, len(config.VALUE_COLUMNS))),
                     columns=list(config.VALUE_COLUMNS))
    f.insert(0, "g", rng.integers(0, config.N_GROUPS, size=rows))
    return f


@pytest.mark.parametrize("parts", [2, 3, 4, 5])
def test_running_aggregate_equals_one_groupby(rng, parts):
    for _ in range(reps(120)):
        f = frame(rng, 200_000)
        agg = features.GroupAggregate()
        for chunk in np.array_split(np.arange(len(f)), parts):
            agg.add(f.iloc[chunk])
        want = f.groupby("g")[list(config.VALUE_COLUMNS)].mean()
        assert agg.rows() == len(f)
        assert np.allclose(agg.means().to_numpy(), want.to_numpy())
        assert np.allclose(agg.variances().to_numpy(), f.groupby("g")[list(config.VALUE_COLUMNS)].var(ddof=0).to_numpy())


@pytest.mark.parametrize("cols", [4, 6, 8, 10])
def test_standardize_matches_sklearn(rng, cols):
    for _ in range(reps(160)):
        x = rng.normal(5.0, 2.0, size=(100_000, cols))
        assert np.allclose(features.standardize(x), StandardScaler().fit_transform(x))
