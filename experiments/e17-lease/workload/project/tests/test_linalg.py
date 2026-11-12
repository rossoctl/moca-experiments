import numpy as np
import pandas as pd  # noqa: F401  (every test module imports the whole stack, as the workload does)
import pytest
import sklearn  # noqa: F401

from conftest import reps
from pyc import stats


@pytest.mark.parametrize("n", [160, 192, 224, 256])
def test_least_squares_recovers_coefficients(rng, n):
    for _ in range(reps(1500)):
        a = rng.normal(size=(4 * n, n))
        x = rng.normal(size=n)
        b = a @ x
        assert np.allclose(stats.least_squares(a, b), x, atol=1e-6)


@pytest.mark.parametrize("n", [96, 112, 128, 144])
def test_symmetric_eigendecomposition(rng, n):
    for _ in range(reps(2000)):
        m = rng.normal(size=(n, n))
        s = m @ m.T
        w, v = np.linalg.eigh(s)
        assert (w > -1e-8).all()
        assert np.allclose(v @ np.diag(w) @ v.T, s, atol=1e-6)
