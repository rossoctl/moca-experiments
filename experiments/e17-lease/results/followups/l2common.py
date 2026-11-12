import hashlib, os, sys, time
sys.path.insert(0, "src")
T0 = time.time()
from pyc import config, data, model  # noqa: E402
import pandas as pd  # noqa: E402
V = list(config.VALUE_COLUMNS)
def load():
    paths = data.shard_paths(config.DATA_DIR)
    sampler = model.Sampler(data.estimated_rows(paths))
    frames = []
    for f in data.iter_shards(paths, hashlib.sha256()):
        frames.append(f)
        sampler.add(f)
    return pd.concat(frames, ignore_index=True), sampler.sample()
def q_light(df, x):
    m = df.groupby("g")[V].mean()
    return "light groups=%d median_x0=%.3f" % (len(m), df["x0"].median())
def q_fit(df, x):
    return "fit inertia=%.3f" % model.inertia(model.fit_repeated(x, config.ANALYZE_WORK_SCALE))
Q = {"light": q_light, "fit": q_fit, "ping": lambda df, x: "pong"}
