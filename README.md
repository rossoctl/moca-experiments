# moca-experiments

Reproducible experiments and benchmark drivers for [moca](https://github.com/rossoctl/moca),
split out so people deploying moca are not exposed to research clutter in the main repo.
Each experiment has a question, a sealed prediction where it applies, a driver, a result and
the steps to repeat it.

## Experiments

| ID | Question | Status | Start here |
|---|---|---|---|
| E1, E3, E4, E6, E7 | Knative economics, mobility, recovery, saturation, converge-contention | archived (Kind/OCP cluster, deprecated deployment) | [`experiments/e01-e07-knative/EXPERIMENTS.md`](experiments/e01-e07-knative/EXPERIMENTS.md) |
| E2, E5 | In-process experiment runners; SWE-bench sandbox sharing | archived | [`experiments/e02-e05-harness/README.md`](experiments/e02-e05-harness/README.md), [`experiments/e02-e05-harness/RESULTS.md`](experiments/e02-e05-harness/RESULTS.md) |
| E10–E13 | microVM sandbox tier: lifecycle, density, vsock egress, restore capacity | done: measured against a pre-set bar, then stopped | [`experiments/e10-e13-microvm/RESULTS-SUMMARY.md`](experiments/e10-e13-microvm/RESULTS-SUMMARY.md) |
| E14 | Stock coding agents with every command in a fresh microVM, 40-run SWE-bench comparison | done: no measurable difference at this sample size | [`experiments/e14-sbx/RESULTS-SUMMARY.md`](experiments/e14-sbx/RESULTS-SUMMARY.md) |
| E15 | Sessions per host: SBX per-Exec microVMs vs resident microVMs, trace replay | done: resident holds as many or more on every host and point | [`experiments/e15-session-density/results/metal/RESULTS-METAL.md`](experiments/e15-session-density/results/metal/RESULTS-METAL.md), spec [`experiments/e15-session-density/SPEC.md`](experiments/e15-session-density/SPEC.md) |
| E15b | Per-turn command bundling, SBX vs resident | spec approved, not built | [`experiments/e15b-bundled/SPEC.md`](experiments/e15b-bundled/SPEC.md) |
| E16 | Does SBX beat resident at duty cycle ≤ 2%? | done: tie at the sealed point, hypothesis falsified | [`experiments/e16-low-duty/RESULTS.md`](experiments/e16-low-duty/RESULTS.md) |
| E17 | Lease mode: does a warm guest with an idle timeout pay? | E17a done: level 1 misses its import/grep bar (short commands gain ~90%); level 2 being built | [`experiments/e17-lease/results/E17A-REPORT.md`](experiments/e17-lease/results/E17A-REPORT.md), spec [`experiments/e17-lease/SPEC.md`](experiments/e17-lease/SPEC.md) |
| E18 | Crash recovery latency on the Compose trial | done | [`experiments/e18-crash-recovery/RESULTS.md`](experiments/e18-crash-recovery/RESULTS.md) |

Analysis: [`analysis/tracelab/`](analysis/tracelab/README.md) re-derives the E15 and E16 tables and
figures from the published raw data, and holds the write-up ([`REPORT.md`](analysis/tracelab/REPORT.md))
and the summary deck. Its [fetch script](analysis/tracelab/scripts/fetch_results.sh) verifies and
unpacks the `data-v1` and `data-v2` archives.

## Reproducing

[`docs/REPRODUCING.md`](docs/REPRODUCING.md) says what each experiment needs: cluster-free tests
that run on a laptop, a KVM host for E10–E14, or a bare-metal host for E15–E17. It also covers
fetching the raw data and the main-repo checkout the drivers expect.

- The summaries, sealed predictions and analysis code are all in this repo.
- The raw per-run traces for E15 and E16 (about 1.4 GB uncompressed) are release assets, not
  git content. `data/fetch-data.sh` downloads and verifies them; see
  [`data/MANIFEST.md`](data/MANIFEST.md).
- How an experiment is laid out and what each file is for: [`docs/CONVENTIONS.md`](docs/CONVENTIONS.md).

## Layout

```
README.md             this file: index of experiments
docs/                 REPRODUCING.md, CONVENTIONS.md, MOVED.md
data/                 MANIFEST.md, fetch-data.sh (raw traces live in release assets)
analysis/tracelab/    E15/E16 analysis: report, deck, tables, fetch script
experiments/          one directory per experiment, `<id>-<slug>`:
                        e01-e07-knative/  e02-e05-harness/  e10-e13-microvm/  e14-sbx/
                        e15-session-density/  e15b-bundled/  e16-low-duty/
                        e17-lease/  e18-crash-recovery/
scripts/              repo tooling (commit-msg hook)
```

## Relationship to the main repo

This repo holds research and benchmark code only. Production code, deployment automation and
design documents live in [rossoctl/moca](https://github.com/rossoctl/moca). What did not move
and why is in [`docs/REPRODUCING.md`](docs/REPRODUCING.md#what-stays-in-the-main-repo).

## History

Git history for every file here except `experiments/e01-e07-knative/lib.sh` (a point-in-time copy) was preserved
via `git filter-repo` from the main repo at the split (2026-09-25).
