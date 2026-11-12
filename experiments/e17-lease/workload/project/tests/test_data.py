import io

import numpy as np
import pandas as pd
import pytest
import sklearn  # noqa: F401

from conftest import reps
from pyc import config, data


def csv_bytes(rng, rows):
    """rows in the generator's format: "gg" and six "dd.ddd" fields."""
    g = rng.integers(0, config.N_GROUPS, size=rows)
    v = rng.integers(0, 100_000, size=(rows, len(config.VALUE_COLUMNS)))
    out = io.StringIO()
    out.write(",".join(config.COLUMNS) + "\n")
    body = pd.DataFrame({"g": [f"{x:02d}" for x in g]})
    for i, c in enumerate(config.VALUE_COLUMNS):
        body[c] = [f"{x // 1000:02d}.{x % 1000:03d}" for x in v[:, i]]
    body.to_csv(out, header=False, index=False)
    return out.getvalue().encode(), g, v / 1000.0


@pytest.mark.parametrize("rows", [20_000, 25_000, 30_000, 35_000])
def test_parse_reads_the_generator_format(rng, rows):
    for _ in range(reps(24)):
        raw, g, v = csv_bytes(rng, rows)
        assert len(raw) == config.HEADER_BYTES + rows * config.ROW_BYTES
        f = data.parse(io.BytesIO(raw))
        assert np.array_equal(f["g"].to_numpy(), g)
        assert np.allclose(f[list(config.VALUE_COLUMNS)].to_numpy(), v)
        assert np.array_equal(data.stride_rows(f, 3, 10).index.to_numpy(), np.arange(7, rows, 10))
