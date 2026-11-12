"""Constants shared by analyze.py, the package and the tests.

The shard format is build_pycache_workspace.sh's: a header line, then fixed-width rows of one
group id and six values, each "dd.ddd". The py_short `edit` command rewrites MAX_ITER and puts it
back in the same command, so keep that line exactly as it is.
"""

DATA_DIR = "../data"
SHARD_GLOB = "shard-*.csv"
COLUMNS = ("g", "x0", "x1", "x2", "x3", "x4", "x5")
VALUE_COLUMNS = COLUMNS[1:]
HEADER_BYTES = len(",".join(COLUMNS)) + 1
ROW_BYTES = 2 + 7 * len(VALUE_COLUMNS) + 1  # "gg" then ",dd.ddd" per value, "\n"
N_GROUPS = 100  # g is two digits, 00..99

SAMPLE_ROWS = 200_000
N_CLUSTERS = 8
N_INIT = 1
RANDOM_STATE = 0
MAX_ITER = 300
TOLERANCE = 1e-4

# analyze.py's CPU knob: the number of single-start KMeans fits on the sample, with random_state
# 0, 1, .., ANALYZE_WORK_SCALE - 1. Only the random_state 0 fit's inertia is printed, so
# `clusters=` is the same at every scale, and the read of every shard byte does not depend on it.
# 32 puts analyze.py at about 15 s on the laptop at D = 256 (spec §4.2: about 10-20 s of CPU);
# Task 5's calibration tunes it here, in this one line.
ANALYZE_WORK_SCALE = 32
