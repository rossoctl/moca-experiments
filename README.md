# moca-experiments

Reproducible experiments and benchmark drivers for [MOCA](https://github.com/rossoctl/moca),
split out so people deploying MOCA are not exposed to research clutter in the main repo.
Each experiment has a question, a sealed prediction where it applies, a driver, a result and
the steps to repeat it.

## Experiments

| ID | Question | Status | Start here |
|---|---|---|---|
| E1, E3, E4, E6, E7 | Knative economics, mobility, recovery, saturation, converge-contention | archived (Kind/OCP cluster, deprecated deployment) | [`knative/EXPERIMENTS.md`](knative/EXPERIMENTS.md) |
| E2, E5 | In-process experiment runners; SWE-bench sandbox sharing | archived | [`experiments/README.md`](experiments/README.md), [`experiments/RESULTS.md`](experiments/RESULTS.md) |
| E10–E13 | microVM sandbox tier: lifecycle, density, vsock egress, restore capacity | done: measured against a pre-set bar, then stopped | [`microvm/RESULTS-SUMMARY.md`](microvm/RESULTS-SUMMARY.md) |
| E14 | Stock coding agents with every command in a fresh microVM, 40-run SWE-bench comparison | done: no measurable difference at this sample size | [`sbx/RESULTS-SUMMARY.md`](sbx/RESULTS-SUMMARY.md) |
| E15 | Sessions per host: SBX per-Exec microVMs vs resident microVMs, trace replay | done: resident holds as many or more on every host and point | [`e15/results/metal/RESULTS-METAL.md`](e15/results/metal/RESULTS-METAL.md), spec [`e15/SPEC.md`](e15/SPEC.md) |
| E15b | Per-turn command bundling, SBX vs resident | spec approved, not built | [`e15/SPEC-bundled.md`](e15/SPEC-bundled.md) |
| E16 | Does SBX beat resident at duty cycle ≤ 2%? | done: tie at the sealed point, hypothesis falsified | [`e16/RESULTS.md`](e16/RESULTS.md) |
| E17 | Lease mode: does a warm guest with an idle timeout pay? | E17a done: level 1 misses its import/grep bar (short commands gain ~90%); level 2 being built | [`e17/results/E17A-REPORT.md`](e17/results/E17A-REPORT.md), spec [`e17/SPEC.md`](e17/SPEC.md) |
| E18 | Crash recovery latency on the Compose trial | done | [`e18/RESULTS.md`](e18/RESULTS.md) |

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
docs/                 REPRODUCING.md, CONVENTIONS.md
data/                 MANIFEST.md, fetch-data.sh (raw traces live in release assets)
knative/  experiments/  microvm/  sbx/     E1–E14 (older, grouped by theme)
e15/  e16/  e17/  e18/                     one directory per experiment
scripts/              repo tooling (commit-msg hook)
```

## Relationship to the main repo

This repo holds research and benchmark code only. Production code, deployment automation and
design documents live in [rossoctl/moca](https://github.com/rossoctl/moca). What did not move
and why is in [`docs/REPRODUCING.md`](docs/REPRODUCING.md#what-stays-in-the-main-repo).

## History

Git history for every file here except `knative/lib.sh` (a point-in-time copy) was preserved
via `git filter-repo` from the main repo at the split (2026-09-25).
