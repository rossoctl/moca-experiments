import numpy as np
import pandas as pd
import pytest
from sklearn.cluster import KMeans
from sklearn.decomposition import PCA

from conftest import reps
from pyc import config, model


@pytest.mark.parametrize("k", [3, 4, 5, 6])
def test_kmeans_finds_separated_blobs(rng, k):
    for _ in range(reps(150)):
        centres = np.arange(k)[:, None] * 50.0 * np.ones((1, 6))
        x = np.concatenate([c + rng.normal(size=(8_000, 6)) for c in centres])
        km = model.fit(x, n_clusters=k)
        assert np.allclose(np.sort(km.cluster_centers_[:, 0]), centres[:, 0], atol=0.5)
        assert model.inertia(km) == model.inertia(model.fit(x, n_clusters=k))


@pytest.mark.parametrize("stride_rows", [7, 13, 50, 101])
def test_sampler_takes_every_stride_th_row(rng, stride_rows):
    for _ in range(reps(170)):
        f = pd.DataFrame(rng.uniform(size=(150_000, len(config.VALUE_COLUMNS))),
                         columns=list(config.VALUE_COLUMNS))
        s = model.Sampler(len(f), size=len(f) // stride_rows)
        for chunk in np.array_split(np.arange(len(f)), 7):
            s.add(f.iloc[chunk])
        want = f.to_numpy()[:: s.stride][: s.size]
        assert np.array_equal(s.sample(), want)
        KMeans(n_clusters=config.N_CLUSTERS, n_init=1, random_state=0, max_iter=20).fit(want[:20_000])


@pytest.mark.parametrize("n_components", [2, 3, 4, 5])
def test_pca_recovers_low_rank_structure(rng, n_components):
    for _ in range(reps(280)):
        basis = rng.normal(size=(n_components, 40))
        x = rng.normal(size=(30_000, n_components)) @ basis + 1e-3 * rng.normal(size=(30_000, 40))
        pca = PCA(n_components=n_components + 1, random_state=0).fit(x)
        assert pca.explained_variance_ratio_[:n_components].sum() > 0.999
