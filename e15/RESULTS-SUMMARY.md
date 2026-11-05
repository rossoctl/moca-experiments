# E15 — sessions per host, preliminary results: summary

**An entry point, not a source of truth.** Every number here is copied from
[`EXPERIMENTS.md`](EXPERIMENTS.md). On any disagreement **`EXPERIMENTS.md` wins**: fix it there,
then here. To replicate, follow [`RUNBOOK.md`](RUNBOOK.md).

---

## The headline

**On a 4-vCPU nested Nitro instance, SBX does not hold more coding-agent sessions than resident
microVMs. At the default point all three arms hold 8 sessions.**

| arm | `N_max` (primary) | `N_max` (absolute) | first failed rung | binding there |
|---|---|---|---|---|
| SBX (fresh VM per command) | **8** | 1 | N=16 | CPU (last 60 s; window mean 41%) |
| resident ∞ (one VM per session) | **8** | 8 | N=16 | CPU on the first run; none on the counted repeat |
| resident 300 s (idle VM reclaimed after 300 s) | **8** | 8 | N=16 | CPU on the first run; none on the counted repeat |

All values are on a 4-vCPU nested Nitro instance (AWS `m8i.xlarge`), default point
(gaps capped at 30 minutes).

- **Every failed rung failed on one condition: the latency tail** (SPEC §8 condition 4). No call
  failed, nothing was refused, no session lost pace, and no host ran out of memory.
- **What fails is a few long CPU-bound calls overlapping.** `test` and `interpreter` calls run up to
  26 s on one vCPU. When a few overlap on 4 vCPUs, every other call queues behind them. At N=16 the
  p95 added latency of `test` calls was about 40 s in every arm.
- **Both resources still had room.** Mean host CPU at N=16 was 41–54%, and resident ∞'s
  MemAvailable stayed above 11 GiB. The numeric predictions, built from resource bounds (~48
  sessions), all missed for this reason.
- **The arms differ on the absolute rule.** SBX's N=8 tail (566 ms over class medians) exceeds its
  B + 250 ms limit (479 ms), so SBX's absolute `N_max` is 1. The resident arms hold 8 on both
  rules. SBX pays about 186 ms per call for VM lifecycle at N=1 on this nested host.

## The sensitivity points

Each point starts two ladder steps below the arm's default `N_max`; from 8 that clamps to N=1.

| point | SBX | resident ∞ | resident 300 s |
|---|---|---|---|
| default (H = 1800 s) | 8 | 8 | 8 |
| short gaps (H = 300 s) | 1 | 1 (first run only: ≥ 8) | — |
| long gaps (H = 7200 s) | 8 | 8 | 8 |
| no host-infra sessions | 1 | 8 * | 8 * |
| no Codex chains | 1 | **24** (first run only: 8) | **24** (first run only: 16) |
| mem512 (512 MiB dataset per session) | 1 | 8 | — |

Primary `N_max`. \* re-run from N=8 after an empty-window artefact at N=1 (EXPERIMENTS §3.2).

- **No point shows SBX ahead.** Where the arms differ, resident holds more.
- **Longer gaps changed nothing.** Every arm stayed at 8 at H = 7200 s.
- **mem512:** SBX fails at N=8. Each scanning call re-reads the 512 MiB dataset in a fresh VM:
  +1.6 s per call at N=1, from page cache, not disk. Resident ∞ holds 8 with each VM at its
  1 GiB cap, and fails at 16 on the latency tail, not on memory. There was no global OOM over
  the whole run.

## Resident results read both ways

**The footprint-drift repeat rule is asymmetric.** A resident rung whose VM memory drifts more than
10% is re-run once with a doubled warm-up, and the repeat counts. SBX never drifts, so it never
gets a second run.
- 17 of 31 counted resident rungs were repeated.
- The repeat flipped a primary verdict on 6 rungs: 3 to hold, 3 to fail.

| point | arm | sealed (repeat counts) | first run only |
|---|---|---|---|
| default, long | both resident arms | 8 | 8 |
| short | resident ∞ | 1 | ≥ 8 |
| no-chains | resident ∞ | 24 | 8 |
| no-chains | resident 300 s | 24 | 16 |

The default result does not depend on the reading. In no-chains the resident lead over SBX
shrinks from three ladder steps to one or two. → [EXPERIMENTS §5](EXPERIMENTS.md#5-both-readings-of-the-resident-results-footprint-drift-repeats)

## The predictions

Sealed at `708d62f` before the first measured rung.

| # | claim (short) | verdict |
|---|---|---|
| 1 | SBX CPU-bound, resident ∞ memory-bound | **Falsified** (resident half: CPU/latency, memory far from floor); SBX half held as labelled |
| 2 | SBX > resident ∞ at default; SBX [40, 48], resident ∞ [48, 48] | **Falsified**: 8 = 8; both ranges missed |
| 3 | resident 300 s within one step of SBX; [48, 48] | **Held** (8 and 8); range missed |
| 4 | at H = 7200 s SBX and resident 300 s rise, resident ∞ stays | **Falsified**: nothing rose (8, 8, 8); resident ∞ half held |
| 5 | no-infra and no-chains move both arms the same way | **Falsified**: SBX fell to 1, resident stayed at 8 or rose to 24 |
| 6 | driver < 1% of host CPU at every N | **Held**: max 0.248% |
| 8 | metal shows a larger SBX/resident ∞ ratio | **Pending the metal run.** Preliminary ratio 8 / 8 = 1.0 |
| 9 | mem512: resident ∞ memory-bound, SBX > resident ∞; [8, 8] / [16, 16] | **Falsified**: resident ∞ 8 (in range) but bound by latency, not memory; SBX 1 |

The calibration concerns recorded before measurement:
- P1 said the resident half would likely fail. It did.
- P2 said a tie was likely. It tied.
- P9 said SBX might hold only 1. It held 1.
- P4 said resident ∞ might rise with longer gaps. It did not; nothing rose.

→ [EXPERIMENTS §4](EXPERIMENTS.md#4-predictions-against-outcomes)

## Supplementary (not sealed)

Added by user decision after the default tie: N=10 at the default point for every arm, same
procedure. **Not sealed: these rungs change no `N_max` and no verdict.**

| arm | `n_fine` (counted) | first run only |
|---|---|---|
| SBX | none (N=10 fails: p95x 823 ms) | none |
| resident ∞ | none (N=10's repeat fails: 1,556 ms) | ≥ 10 (first run 385 ms) |
| resident 300 s | none (N=10's repeat fails: 3,104 ms) | ≥ 10 (first run 620 ms) |

As counted, every arm's knee lies between 8 and 10. On first runs only, the resident arms reach 10
and SBX does not. → [EXPERIMENTS §9](EXPERIMENTS.md#9-supplementary-not-sealed)

## What this means for the metal run

- **On this host the question is decided by the latency tail, not by memory or idle time.** 4 vCPUs
  and 1-vCPU guests let a few long calls queue the rest. That is the regime SPEC §12 warned about
  ("every arm may hit the same CPU wall"), reached through queueing well before the wall.
- **The metal run (96 vCPU, no nesting) removes both.** There the memory difference between the
  arms can show, and SBX's per-call lifecycle cost falls about 4× (SPEC §4).
- **Prediction 8 compares against a preliminary ratio of 1.0.**

---

_Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>_
