# e17/results: where E17's rig output lands

Every rung is run on the metal host by the controller (PLAN Task 5 and the run plan after it). On
the host, a rung writes `/srv/e15/runs/<point>/<arm>/N<N>[-<tag>]/` (`e15/rig/rung.sh`). The
controller copies the files listed below into this directory and commits them. `calls.jsonl`,
`samples.jsonl` and `worker.log` are copied gzipped, as in `e16/results/`.

## Layout

| path | what | from |
|---|---|---|
| `bringup/manifest.md` | the host's `~/e17-manifest.md`: every bring-up step with its undo line | `e17/rig/bringup.sh` |
| `bringup/artifacts` | `/srv/e15/state/artifacts`: the sha256 of each corpus, template and snapshot file | `bringup.sh`, `e15/rig/setup.sh` |
| `bringup/template-pycache-d<D>.BUILD` | each template's `BUILD`: the dataset size, rows and `dataset_sha256`, the wheel check, and the venv versions (D = 64, 256, 768) | `e17/workload/build_pycache_workspace.sh`, via `bringup.sh` |
| `corpus/pycache-report.json`, `corpus/pycache-low-report.json` | the `corpus-report.json` of each staged corpus. Its `durations_ms` must be the calibrated ones (`durations_from` not null), not the generator's placeholders, before any measured rung. `py_short` stays planned at 300 ms on purpose: below every short command's `nominal_ms`, the driver's fill would always pick the first one | `e17/rig/gen_corpora.sh` |
| `smoke/<arm>/N1-smoke/` | one smoke rung per arm at `pycache`: N=1, a 60 s warm-up, a 120 s window. In git: `record.json`, `params.json`, `worker.env`, `attach-probe.log` and `warmcold-report.json` (`e17/analysis/warmcold.py`). The raw files (`calls.jsonl.gz`, `samples.jsonl.gz`, `worker.log.gz`, `sessions.jsonl`, `driver-cpu.jsonl`, `warmcold.jsonl`) are the `data-v3` release archive (`moca-experiments-e17-pycache-raw.tar.gz`, fetched by `data/fetch-data.sh e17-pycache` into `results/raw/pycache/`), never in git. Exception, as a test fixture: the small slices under `e17/analysis/testdata/` (tens of KB: one seeded rung's `calls.jsonl` and `worker.log.gz`, and an aborted run's) and `e17/extract/testdata/gaps-20.jsonl` stay in git so the analysis and extract tests run without a rig; the fixture rule is "under a few MB", from the same convention | `e17/rig/smoke.sh` |
| `smoke/sbx/N1-smoke/analyze-check.log` | the guest import check: one `py_analyze` Exec through the relay (`grpcurl`, lib.sh `gexec`), its exit code and its `sha256=` line. That line must equal `template-pycache-d256.BUILD`'s `dataset_sha256` | `smoke.sh` |
| `smoke/smoke.out` | smoke.sh's output: the warm, cold and unknown counts per rung, then pass or fail | `smoke.sh` |
| `smoke/measured_delta.txt` | the per-session disk delta of the sbx smoke rung, in MiB (PLAN Task 5 step 3). If it is above 64, the pycache rungs' disk check is sized with it (`E15_WS_DELTA_MB`) | `e16/rig/measured_delta.py` |
| `calibration/<arm>/N1/baseline.json` | the pooled N=1 baseline, for `sbx` and `resident-300` at `pycache` | `e15/rig/baseline.sh` |
| `calibration/<arm>/N1-s<k>/`, `calibration/<arm>/N1-probe-<class>/` | the seeded N=1 runs and the per-class probes behind each baseline (`py_analyze`, `py_test`, `py_import`, `py_grep`, `py_short`). Files as for a smoke rung | `baseline.sh`, `e15/rig/classprobe.sh` |
| `calibration/<arm>/N1/baseline.cap30k.json`, `calibration/<arm>/_cap30k-N1-probe-<class>/` | the first baseline and probes, under E15's 30 s probe cap (`py_test` median +31 s), kept when `reprobe.sh` re-probed the arm at the 120 s pycache cap. The new `N1/baseline.json` records the re-probe in its `reprobe` field | `e17/rig/reprobe.sh` |
| `calibration/durations.json` | `{"py_analyze": ms, "py_test": ms, "py_import": ms, "py_grep": ms, "py_short": ms}`: each class's N=1 median `run_ms` on `sbx`, taken from the probes. It is the input to `gen_corpora.sh --durations-from`. If the test suite is retuned so that `py_test` is 50–70 s, this file is from the final suite | controller |
| `calibration/README.md` | how the calibration ran: the suite size chosen, re-stamped templates, the re-run smoke | controller |
| `<point>/<arm>/N<N>[-<tag>]/` | the measured E17a rungs, after the predictions are sealed (spec §8). Files as for a smoke rung, plus `ladder.json` per point and arm | the run plan's `chain.sh`-style stages |
| `latency/<point>-N<N>/latency.json`, `latency.md` | the latency report per point and N (spec §7.1): the gain per class, the warm share, and the first call after an idle teardown | `e17/analysis/latency_report.py` |

`e17/predictions.json` (spec §9) lives in `e17/`, not here. It is written from `calibration/` and
sealed by the user before the first measured rung.

## Order

1. `gen_corpora.sh`, then `sync.sh`, then `bringup.sh`: `bringup/`, and `corpus/` with the
   placeholder durations.
2. `smoke.sh`: `smoke/`. Then `measured_delta.py` on `smoke/sbx/N1-smoke`.
3. Calibration: `calibration/`. Then `gen_corpora.sh --durations-from calibration/durations.json`,
   `sync.sh` and `bringup.sh` again: the corpora change, and the templates only if the suite was
   retuned. Then the smoke again, written over `smoke/`, and `corpus/` refreshed.
4. The predictions are sealed. Then the measured rungs: `<point>/`, `latency/`.
