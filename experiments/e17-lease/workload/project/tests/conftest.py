"""Shared setup for the pycache project's tests (E17's py_test command).

WORK_SCALE scales every test's numeric work at once: each test repeats its unit of work
reps(BASE) times, and BASE is chosen so that reps(BASE) takes about 1.5 s at WORK_SCALE = 1.0
on the laptop. Task 5's calibration tuned the suite on the rig by editing WORK_SCALE alone (and
re-stamping the templates): in an sbx guest on the E15 metal host, 0.30 took 54.9 s, 0.35 62.8 s and
0.40 72.1 s (2026-11-10), so 0.35. PYC_WORK_SCALE overrides it for the laptop checks only; the
library's command never sets it.
"""

import os
import sys
import zlib

import numpy as np
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src"))

WORK_SCALE = float(os.environ.get("PYC_WORK_SCALE", "0.35"))


def reps(base):
    """How many times a test repeats its unit of work: base scaled by WORK_SCALE, at least 1."""
    return max(1, round(base * WORK_SCALE))


@pytest.fixture
def rng(request):
    """A generator seeded from the test's node id, so every run of a test draws the same data."""
    return np.random.default_rng(zlib.crc32(request.node.nodeid.encode()))
