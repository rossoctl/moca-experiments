"""Reading the workspace's CSV shards.

Each shard is hashed in a streaming pass (1 MiB reads, the bytes exactly as on disk) and then
parsed by pandas.read_csv from its path; the second read comes from the page cache the first one
filled. One shard's frame is alive at a time, so peak memory does not grow with the dataset: at
D = 768 MiB the whole dataset's frame would not fit the guest's 1 GiB. (Parsing from an in-memory
copy of the bytes, io.BytesIO, was measured to grow the peak by about 16 MiB per shard.)
"""

import glob
import os

import pandas as pd

from pyc import config

DTYPES = {c: ("int64" if c == "g" else "float64") for c in config.COLUMNS}
BLOCK = 1 << 20


def shard_paths(data_dir=config.DATA_DIR):
    """The shards in name order, which is the generator's order."""
    paths = sorted(glob.glob(os.path.join(data_dir, config.SHARD_GLOB)))
    if not paths:
        raise FileNotFoundError(f"no {config.SHARD_GLOB} under {data_dir}")
    return paths


def estimated_rows(paths):
    """Row count from file sizes alone (fixed-width rows), used to pick the sample stride."""
    return sum((os.path.getsize(p) - config.HEADER_BYTES) // config.ROW_BYTES for p in paths)


def hash_into(digest, path):
    """Feed every byte of path to digest, in order."""
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(BLOCK), b""):
            digest.update(block)


def parse(source):
    """One shard (a path or a file-like object) as a frame with the shard's dtypes."""
    frame = pd.read_csv(source, dtype=DTYPES)
    if tuple(frame.columns) != config.COLUMNS:
        raise ValueError(f"unexpected columns {list(frame.columns)}")
    return frame


def iter_shards(paths, digest):
    """Yield each shard's parsed frame, in order, after feeding its bytes to digest."""
    for p in paths:
        hash_into(digest, p)
        yield parse(p)


def stride_rows(frame, offset, stride):
    """The rows of frame whose global index (offset + position) is a multiple of stride."""
    start = (-offset) % stride
    return frame.iloc[start::stride]
