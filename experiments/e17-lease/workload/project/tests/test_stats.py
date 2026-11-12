import numpy as np
import pandas as pd  # noqa: F401
import pytest
import sklearn  # noqa: F401

from conftest import reps
from pyc import stats


@pytest.mark.parametrize("size", [200_000, 250_000, 300_000, 350_000])
def test_moments_of_a_normal_sample(rng, size):
    for _ in range(reps(300)):
        mean, var, skew, kurt = stats.moments(rng.normal(2.0, 3.0, size=size))
        assert abs(mean - 2.0) < 0.05 and abs(var - 9.0) < 0.2
        assert abs(skew) < 0.05 and abs(kurt) < 0.1


@pytest.mark.parametrize("cols", [8, 12, 16, 20])
def test_covariance_matches_numpy(rng, cols):
    for _ in range(reps(550)):
        x = rng.normal(size=(40_000, cols))
        assert np.allclose(stats.covariance(x), np.cov(x, rowvar=False))
