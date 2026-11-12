# experiments/e16-low-duty/rig — the E16 run chain on the metal host

E16 runs on the E15 metal host (`/srv/e15`, profile `fresh-metal`) with E15's rig unchanged except
for the fresh-metal-only switches in `experiments/e15-session-density/rig` (point `lowduty`, `E15_MAX_COMMITTED_MB`/`E15_MAX_RUNS`,
`E15_LADDER_RUNGS`, `E15_LADDER_TAG`, a caller-set `E15_K_MULT` base in `ladder.sh`).

| file | what |
|---|---|
| `chain.sh STAGE [ARM]` | stages `baselines`, `cal`, `long-rung`, `ladder-sbx`, `ladder-resident`, `seeds`, `control` (header comment: the rules) |
| `chainlib.py` | per-rung rows, the assembled `ladder.json` (gaps, step-down, seeds), bisect rung; `test_chainlib.py` |
| `rung-perf.sh` | `rung.sh` with `perfsample.sh` in the measured window (also `ladder.sh`'s `E15_RUNG`) |
| `grace_artefact.py`, `measured_delta.py`, `perfsample.sh` | copied from `experiments/e15-session-density/results/metal/tools/` |
| `calib_analyze.py` | copied from `experiments/e15-session-density/results/calibration/` (cal-rung core-s per call, VM footprint) |
| `sync.sh` | laptop: rsync `experiments/e15-session-density/` + `experiments/e16-low-duty/` to `/srv/e15/src/`, the metal library, the lowduty corpus |

Run a stage detached on the host, e.g.

    cd /srv/e15 && nohup bash /srv/e15/src/e16/rig/chain.sh long-rung >>/srv/e15/e16/long-rung.out 2>&1 &

Each stage prints `E16 <stage> <arm> N=<n> holds=.. holds_abs=.. p95x=.. reason=..` per rung. Rungs
land in `/srv/e15/runs/lowduty/<arm>/`; per-rung rows and each `ladder.sh` invocation's own
`ladder.json` in `<arm>/e16/`; the assembled ladder in `<arm>/ladder.json`. Logs in `/srv/e15/e16/`.
The sentinel writes `/srv/e15/e16/STOP` (global OOM outside a memory cgroup, or < 10 GiB free) and
kills the rung. Tests: `experiments/e15-session-density/rig/tests/rig.test.sh` (stage dispatch, idempotence, output format) and
`pytest experiments/e16-low-duty/rig`.
