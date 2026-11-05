# E15 — sessions per host: per-Exec microVMs vs resident microVMs

**The question.** At equal hardware, does SBX (moca's fresh Firecracker microVM per command) hold
more concurrent coding-agent sessions per host than resident microVMs (one VM kept for each
session)?

**How.** A Go driver replays real Claude Code and Codex sessions from TraceLab v0.0.2. It keeps the
recorded gaps between commands and runs a real command of the same class for each recorded one. It
raises the session count up a ladder until the host no longer "holds" it (SPEC §8: no failures, no
refusals, sessions keep pace, added latency bounded).
- **SBX:** stock moca v0.9.0 worker, one VM per command.
- **Resident ∞:** a rig-only patch, one VM per session, kept for the whole session.
- **Resident 300 s:** the same, with an idle VM reclaimed after 300 s.
- **Control:** a null responder, to check that the driver itself is not the bottleneck.

**The preliminary answer.** No. On a 4-vCPU nested Nitro instance, all three arms hold 8 sessions
at the default point. Where the arms differ (no Codex chains, short gaps, mem512), resident holds
more. Every arm fails on the latency tail, long before CPU or memory runs out. See
[`RESULTS-SUMMARY.md`](RESULTS-SUMMARY.md).

**Stage.** Preliminary, on one 4-vCPU nested-KVM AWS instance (`m8i.xlarge`). A bare-metal run
follows (SPEC §13).

## Reading order

1. [`RESULTS-SUMMARY.md`](RESULTS-SUMMARY.md): the headline, each arm's `N_max`, the binding
   resource, and each prediction's verdict.
2. [`EXPERIMENTS.md`](EXPERIMENTS.md): the record. Setup as run, every rung, every prediction
   against its outcome, every corpus transformation, per-provider and per-class splits, and
   anything retried or excluded. On any disagreement it wins.
3. [`predictions.json`](predictions.json): the predictions, sealed before the first measured rung
   (commit `708d62f`).
4. [`SPEC.md`](SPEC.md): the design. [`PLAN.md`](PLAN.md): how it was built.
5. [`RUNBOOK.md`](RUNBOOK.md): how to replicate it.

## Layout

- `extract/`: TraceLab DuckDB → `corpus.jsonl` + `corpus-report.json` (SPEC §5).
- `commands/`: the command library (`library.json`, measured run times), the workspace project lock
  and the workspace image builder.
- `driver/`: the Go replay driver.
- `resident/`: the resident-arm patch against moca v0.9.0's worker, with its tests. Rig-only; it
  never enters the moca repo.
- `analysis/`: the "holds N" test (`holds.py`), the per-rung record (`record.py`), the N=1
  baseline (`baseline.py`) and the class probe (`make_probe.py`).
- `rig/`: setup, teardown, rung, ladder, sampler, baseline and probe scripts, and their tests.
  `fine.sh` runs supplementary (not sealed) rungs between ladder steps.
- `results/calibration/`: calibration evidence and scripts (SPEC §10.1).
- `results/<point>/<arm>/<N>/`: each measured rung (record, params, calls, sessions, samples,
  worker log), plus each ladder's `ladder.json` and the baseline it used.
- `results/aws-prelim/`: the scripts that drove the preliminary run and their logs.

---

_Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>_
