# Planned N = 1 durations for the v0.4 pycache corpora

`durations-v0.4.json` is the `--durations-from` input of `e17/rig/gen_corpora.sh` for spec v0.4.

| class | ms | source |
|---|---|---|
| `py_analyze` | 15421 | median of 10 in-window calls, `sbx` N = 1 seeds 1, 4, 5, 7 (v0.3 corpus, tuned templates) |
| `py_test` | 61434 | median of 5 in-window calls, same runs |
| `py_short` | 300 | **planned, not measured** (measured median 63 ms). Below every short command's `nominal_ms` (300), the driver's fill always falls back to the first command; at 300 it picks among all nine |
| `py_import` | 2000 | feasibility probe 2 (spec §1.1), cold, `resident-300` guest |
| `py_grep` | 2200 | same probe |
