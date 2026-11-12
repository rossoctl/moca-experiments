"""Small numeric helpers the tests exercise: moments, covariance, a least-squares fit."""

import numpy as np


def moments(x):
    """Mean, variance, skewness and excess kurtosis of a 1-D array."""
    x = np.asarray(x, dtype=np.float64)
    mean = x.mean()
    d = x - mean
    var = (d * d).mean()
    if var == 0:
        return mean, 0.0, 0.0, 0.0
    skew = (d ** 3).mean() / var ** 1.5
    kurt = (d ** 4).mean() / var ** 2 - 3.0
    return mean, var, skew, kurt


def covariance(x):
    """Sample covariance of the columns of a 2-D array."""
    x = np.asarray(x, dtype=np.float64)
    d = x - x.mean(axis=0)
    return d.T @ d / (x.shape[0] - 1)


def least_squares(a, b):
    """The x minimising |a x - b|, through the normal equations' Cholesky factor."""
    a = np.asarray(a, dtype=np.float64)
    gram = a.T @ a
    chol = np.linalg.cholesky(gram)
    y = np.linalg.solve(chol, a.T @ b)
    return np.linalg.solve(chol.T, y)


def running_mean(x, window):
    """Mean of every length-window run of a 1-D array (len(x) - window + 1 values)."""
    c = np.cumsum(np.concatenate(([0.0], np.asarray(x, dtype=np.float64))))
    return (c[window:] - c[:-window]) / window
