E15 metal calibration (SPEC §10.1) on the AWS m7i.metal-24xl, 2026-11-04. Summary: calibration-summary.md.
library.json            metal-measured command library (installed over commands/library.json on the host by tools/sync.sh)
library-raw/            measure_library.sh raw rows (5 reps x 72 invocations) and guest facts
build_library.py        library.json from the raw rows (medians, the AWS library's invocations)
baseline/<point>/<arm>/ N=1 seeded runs (N1-s*), per-class probes (N1-probe-*) and the pooled N1/baseline.json
rungs/                  control N=128 and the N=8 calibration rungs (+ analysis.json from calibration/calib_analyze.py);
                        default-resident-inf-N8-cal/record.rejudged-sum-07ab661.json = the same rung judged with drift_basis=sum;
                        default-resident-inf-N8-cal-repeat = warm-up 1200 s at e964dd0
lifecycle/              100 no-op Execs on the SBX worker, idle host
burst_model.py, burst-model/   burst-aware N_max model, its runs and summary.json (fit on the preliminary n_max)
make_predictions_metal.py      writes the DRAFT e15/predictions-metal.json (not committed until sealed)
tools/                  chain.sh (host calibration chain), sync/pull/waitstep helpers (laptop)
state-*.txt             host state files (disk read max, artifacts, profile, src COMMIT)
