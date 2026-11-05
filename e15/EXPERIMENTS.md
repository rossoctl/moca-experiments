# E15 — the record (preliminary run, AWS nested rig)

This is the source of truth for E15's preliminary run. [`RESULTS-SUMMARY.md`](RESULTS-SUMMARY.md)
copies its numbers. On any disagreement this file wins. The design is [`SPEC.md`](SPEC.md) v0.9;
the predictions are [`predictions.json`](predictions.json), sealed at `708d62f` before the first
measured rung. Every `N_max` here is **on a 4-vCPU nested Nitro instance** (SPEC A4). None of it
is a capacity number.

Raw data: `results/<point>/<arm>/<N>/` holds each counted and repeated rung. Each has
`record.json`, `params.json`, `calls.jsonl.gz`, `sessions.jsonl`, `samples.jsonl.gz`,
`worker.log.gz`, `driver-cpu.jsonl` and `shared-host.json`. `results/<point>/<arm>/ladder.json`
is the ladder's verdict, and `baseline/baseline.json` is the N=1 baseline it used. The scripts
that drove the run are in `results/aws-prelim/scripts/`.

---

## 1. Setup as run

| | |
|---|---|
| Host | AWS `m8i.xlarge`, nested KVM, 4 vCPU, 15.7 GiB RAM (MemTotal 16,082,476 kB), no swap. Shared with a P6 stack (SPEC §4). |
| Disk | 40 GB root, XFS; workspaces reflinked from the template. Measured sequential read 130.5 MB/s (`disk_read_max_mbs`). |
| moca | v0.9.0 `c13d5564`: relay, stock `microvm-worker` (SBX), resident patch (`resident/resident.patch`). |
| moca-experiments | `708d62f` (sealed predictions) on the rig for every sealed rung; supplementary rungs add `rig/fine.sh` (`8071464`). |
| Guest | Firecracker v1.17.0, 1 vCPU, 1024 MiB, snapshot `sha256:c60ed949…`. |
| Driver | `e15-driver` sha256 `297c8e8a…`; library `7c2bdc4b…`. Both match every baseline by hash. |
| Memory guards | `e15.slice` MemoryMax 12,633 MiB (RAM − 3 GiB), MemoryHigh 11,609 MiB. The rung watchdog aborts at MemAvailable < 1,024 MiB for 3 s. |
| Worker env | `SH_GUEST_RAM_MB=1024`, `SH_HOST_MEM_FLOOR_MB=1536`, `WORKER_MAX_CONCURRENT=256`, `SH_MAX_RUNS=512`, `SH_MAX_COMMITTED_MB=1048576`, `SH_WORKSPACE_IMAGE_MB=256` (1024 at mem512). Standby depth: SBX 2, resident 0. Resident 300 s: `E15_RESIDENT_IDLE_S=300`. |
| Rung | 10-minute warm-up, 15-minute window, 60 s spread, 300 s grace, seed 1. Before each rung: fresh workspaces, relay restart, fresh worker, attach probe. |

Setup ran at 2026-11-04 01:59Z. The ladders ran 02:16Z Nov 4 to 11:41Z Nov 5. The supplementary
rungs ran 11:41–14:08Z Nov 5 (§9). The rig was torn down at 14:29Z (§10).

**The verdicts (SPEC §8, prediction 7).** A rung holds when it has no failed call, no refusal,
a median class pace ≤ 10%, and a condition-4 tail within bounds. Condition 4 is the p95 of each
call's *excess*: its added latency minus its class's N=1 probe median. Two limits:
- **primary (`holds`, `n_max`):** p95 excess ≤ max(3 × B, 50 ms);
- **absolute (`holds_abs`, `n_max_abs`):** p95 excess ≤ B + 250 ms.

B is the arm's own N=1 within-class excess p95. Limits per arm, default point:

| arm | B | primary limit | absolute limit | N=1 overhead per call |
|---|---|---|---|---|
| SBX | 229 ms | 687 ms | 479 ms | +186 ms |
| resident ∞ | 284 ms | 853 ms | 534 ms | −16 ms |
| resident 300 s | 290 ms | 871 ms | 540 ms | −19 ms |
| SBX, mem512 | 298 ms | 895 ms | 548 ms | +1,589 ms |
| resident ∞, mem512 | 287 ms | 862 ms | 537 ms | −19 ms |

The short, long, no-infra and no-chains points have no baselines of their own. They borrow the
default point's (SPEC §10.3; `baseline_source` in each record).

## 2. The workload (corpus)

TraceLab v0.0.2, `syfi_coding_trace.duckdb` (sha256 `a7bab286…`). The counts come from each point's
`corpus-report.json`; copies are in `results/calibration/corpus-reports/`.

| | default | short | long | no-infra | no-chains |
|---|---|---|---|---|---|
| H (gap cap) | 1800 s | 300 s | 7200 s | 1800 s | 1800 s |
| sessions in the source | 8,058 | 8,058 | 8,058 | 8,058 | 8,058 |
| dropped: < 20 replayed calls | 3,911 | 3,911 | 3,911 | 3,911 | 3,911 |
| excluded by the point | 0 | 0 | 0 | 893 (infra) | 873 (chains) |
| **sessions replayed** | **4,147** | 4,147 | 4,147 | 3,254 | 3,274 |
| Claude / Codex | 2,539 / 1,608 | same | same | 1,988 / 1,266 | 2,539 / 735 |
| copied-history calls dropped | 12,319 (94 sessions) | same | same | same | same |
| calls with no wall time dropped | 616 | same | same | same | same |
| Codex chains collapsed | 36,680 | 36,680 | 36,680 | 15,258 | 0 |
| chains capped at 2 h | 16 | 16 | 16 | 1 | 0 |
| durations capped (Claude / Codex) | 13,347 / 251 | same | same | 3,390 / 129 | 13,347 / 55 |
| gaps capped at H | 5,239 | 20,490 | 2,003 | 2,080 | 3,970 |
| polls with no parent | 487 | same | same | same | same |
| errored calls (replayed, with their exit) | 27,082 | same | same | 11,877 | 14,475 |
| host-infra calls / sessions | 26,751 / 893 | same | same | 0 / 0 | 10,363 / 594 |
| opaque calls (busy %) | 8,954 (14.5%) | same | same | 5,575 (26.8%) | 3,643 (4.2%) |
| unparsed calls (busy %) | 1,629 (0.5%) | same | same | 843 (0.8%) | 860 (1.0%) |
| calls/s per session | 0.0174 | 0.0313 | 0.0115 | 0.0214 | 0.0135 |
| work % of session time | 8.2 | 14.7 | 5.4 | 7.0 | 3.6 |
| held at T_idle = 300 s | 56.1% | 100% | 37.0% | 54.5% | 53.1% |
| mean session span | 123 min | 69 min | 187 min | 60 min | 110 min |

Note that removing host-infra sessions *raises* the call rate per session (0.0214 against 0.0174
calls/s), and their sessions are shorter. "No infra" is therefore not a lighter load per session.
mem512 replays the default corpus.

## 3. Every ladder

One line per counted rung. `p95x` is the p95 of class excess in ms. "rep" marks a rung counted from
its footprint-drift repeat (ladder.sh: drift > 10% → re-run once with a 20-minute warm-up, and the
repeat counts). `host` is the mean whole-host CPU busy % in the window. Every rung had **0 failed
calls and 0 refusals**, so conditions 1 and 2 never failed. Condition 3 (class pace) never failed
either: the highest median class pace was +1.35%. **Every failed rung failed on condition 4, the
latency tail.**

### 3.1 Default point (H = 1800 s), full ladders

| arm | N | counted run | holds | holds_abs | p95x | calls | host | binding |
|---|---|---|---|---|---|---|---|---|
| SBX | 1 | first | yes | yes | — | 7 | 1.8 | none |
| SBX | 8 | first | yes | **no** (566 > 479) | 566 | 132 | 16.8 | none |
| SBX | 16 | first | **no** | no | 1,545 | 439 | 40.7 | cpu |
| resident ∞ | 1 | first | yes | yes | — | 7 | 1.8 | none |
| resident ∞ | 8 | first | yes | yes | 359 | 132 | 15.8 | none |
| resident ∞ | 16 | rep (drift 32.6%) | **no** | no | 15,200 (first: 1,246) | 283 | 54.0 | none (first: cpu) |
| resident 300 s | 1 | first | yes | yes | — | 7 | 1.8 | none |
| resident 300 s | 8 | first | yes | yes | 367 | 132 | 15.9 | none |
| resident 300 s | 16 | rep (drift 14.1%) | **no** | no | 13,053 (first: 1,390) | 283 | 54.5 | none (first: cpu) |

**Result:** SBX `n_max` 8, `n_max_abs` 1. Resident ∞ `n_max` 8, `n_max_abs` 8. Resident 300 s
`n_max` 8, `n_max_abs` 8. **The three arms tie at 8 on the primary rule.** On the absolute rule the
resident arms hold 8 and SBX holds only 1. SBX's N=8 tail is 566 ms over the class medians, and
SBX's 186 ms per-call lifecycle (§1) leaves it less room under B + 250.

**The binding at N=16.** record.py reads the binding from the window's last 60 s. At SBX N=16 that
was 94% CPU, but the window mean was only 41% (p50 36%, 5.6% of seconds ≥ 90%). The host was
not saturated on average. It saturated in bursts, when a few long CPU-bound calls (`test`,
`interpreter`, `build`) overlapped on 4 vCPUs, each guest having 1 vCPU. Those classes carry the
tail: at SBX N=16 the p95 added latency was 39 s for `test` and 16 s for `interpreter`. The
resident arms behave the same way: test 42 s and interpreter 15 s at resident ∞ N=16. Memory never
came near the floor: resident ∞'s MemAvailable minimum at N=16 was 11,427 MiB, with VMs at a mean
of about 100–114 MiB.

**Per-call CPU** (worker slice core-seconds per window call): SBX 3.95 at N=8, 3.10 at N=16;
resident ∞ 3.74 at N=8, 2.98 at N=16. SBX pays about 0.2 core-s per call more, in line with
calibration (0.218).

### 3.2 Sensitivity points (SPEC §10.3)

Each point starts two ladder steps below the arm's default `n_max`. The default `n_max` is 8 for
every arm, two steps below 8 clamps to the ladder's first rung, so **every sensitivity ladder
starts at N=1**.

| point | arm | `n_max` | `n_max_abs` | first failed rung (p95x vs primary limit) | binding there |
|---|---|---|---|---|---|
| short (H = 300 s) | SBX | 1 | 1 | N=8: 883 vs 687 | none (host 32%) |
| short | resident ∞ | 1 | 1 | N=8 (rep, drift 78.7%): 1,943 vs 853; first run 623, held | none |
| long (H = 7200 s) | SBX | 8 | 1 | N=16: 1,678 vs 687 | cpu (host 41%) |
| long | resident ∞ | 8 | 8 | N=16 (rep): 13,543; first run 1,399 | none (first: cpu) |
| long | resident 300 s | 8 | 8 | N=16 (rep): 15,839; first run 1,276 | none (first: cpu) |
| no-infra | SBX | 1 | 1 | N=8: 717 vs 687 | none (host 25%) |
| no-infra | resident ∞ | 8 * | 1 * | N=16: 2,551 (rep); first run 1,426 | none |
| no-infra | resident 300 s | 8 * | 1 * | N=16: 1,846 vs 871 | none |
| no-chains | SBX | 1 | 1 | N=8: 838 vs 687 | none (host 17%) |
| no-chains | resident ∞ | **24** † | 24 † | N=32 (rep): 10,818; first run 18,484 | none (host 66%) |
| no-chains | resident 300 s | **24** † | 24 † | N=32 (rep): 9,860; first run 15,394 | none |
| mem512 | SBX | 1 | 1 | N=8: 1,715 vs 895 | none (disk 6.7 MB/s, host 22%) |
| mem512 | resident ∞ | 8 | 1 | N=16: 3,413 vs 862 | none (MemAvailable min 3,945 MiB) |

\* **no-infra resident arms: re-run from N=8.** The first ladder held at N=1 (3 window calls),
but footprint drift (21.5%) forced a repeat. The repeat's longer warm-up moved the window into a
long gap, so it held only 2 calls: `reason=empty_window`, which counts as not holding. ladder.sh
recorded `n_max` null. This is an instrument artefact; baseline.sh treats the same case as "not
evaluable". The ladder was re-run from N=8, with N=1 counted from its first, evaluable run
(ruling, ledger). The first ladder is kept as `ladder.emptywindow.json`. `n_max_abs` 1: N=8 failed
the absolute rule, and N=1's first run held both rules.

† **no-chains resident arms: a §12 shared-host repeat at N=32.** The ladders first ran N=1 → 32
(`n_max` 24). The §12 check (§6) flagged N=32: non-E15 CPU reached a 10 s mean of 17.6%
(resident ∞) and 16.2% (resident 300 s). The ladder was re-run from N=32 and failed again.
`ladder.json` merges the two runs: rungs below 32 come from the first ladder, N=32 from the re-run.
The originals are kept as `ladder.first.json` and `ladder.shared-rerun.json`.

**What moves `n_max`.** Only the no-chains point separates the arms. There the resident arms
hold 24 and SBX holds 1.
- The no-chains corpus does the least work per session (3.6% of session time, 0.0135 calls/s) and
  replays only 735 Codex sessions against 2,539 Claude sessions. Resident VMs hold up to N=24 with
  host CPU at 23%.
- SBX fails at N=8 with host CPU at 17%. Its tail comes from `interpreter` (p95 added 3.6 s),
  `other` (3.4 s) and `write` (1.6 s) calls: 838 ms of excess against a 687 ms limit.

At every other point all arms meet the same latency tail at 8–16 sessions, far below their CPU
and memory bounds.

### 3.3 Per provider

The worst p95 added latency, split by provider, at the first failed default rung:

| rung | Claude calls / p95 added | Codex calls / p95 added |
|---|---|---|
| SBX N=16 | 320 / 1,235 ms | 119 / 5,618 ms |
| resident ∞ N=16 (rep) | 201 / 14,337 ms | 82 / 15,517 ms |
| resident 300 s N=16 (rep) | 201 / 11,677 ms | 82 / 15,307 ms |

Codex calls carry the longer tail in every arm. Codex replays more chained and longer commands (its
duration cap is 120 s, Claude's 30 s). All values per rung are in `record.json` `by_provider`.

### 3.4 Per class

The classes with the largest p95 added latency at the first failed rung (`record.json`
`by_class`):

| rung | top classes (calls, p95 added) |
|---|---|
| SBX default N=16 | test (7, 39.2 s), interpreter (42, 15.7 s), build (7, 4.1 s), network (8, 2.3 s) |
| resident ∞ default N=16, first run | test (8, 41.6 s), interpreter (40, 15.4 s), host_infra (23, 6.2 s), build (7, 2.5 s) |
| resident ∞ default N=16, repeat | test (13, 68.8 s), opaque (5, 25.9 s), interpreter (30, 24.2 s), lint_check (6, 18.2 s) |
| SBX no-chains N=8 | interpreter (17, 3.6 s), other (4, 3.4 s), write (32, 1.6 s), test (1, 1.5 s) |
| resident ∞ no-chains N=24 (rep, held) | unparsed (3, 17.7 s), interpreter (24, 12.3 s), host_infra (8, 3.4 s) |
| SBX mem512 N=8 | shell_read (44, 3.4 s), read (27, 3.4 s), lint_check (2, 2.2 s), network (5, 2.1 s) |
| resident ∞ mem512 N=16 | test (1, 64.1 s), build (5, 25.1 s), network (8, 17.9 s), interpreter (42, 11.2 s) |

The tail rests on a few long CPU-bound calls. On a 4-vCPU host a handful of overlapping `test` or
`interpreter` calls (each up to 26 s of single-core work, measured) queue every other call behind
them. Condition 4's p95 rests on about 7–22 calls per rung.

### 3.5 mem512

- **SBX** fails at N=8 (p95x 1,715 ms vs 895). Each scanning call re-reads the 512 MiB dataset in
  a fresh VM. At N=8 the reads come from the host page cache: disk read was 6.7 MB/s of 130.5.
  The cost is per-call time (`shell_read` and `read` p95 3.4 s), not disk saturation. Per-call CPU
  was 5.18 core-s, against 3.95 at the default point.
- **Resident ∞** holds 8. Each VM keeps the dataset in its guest page cache: the median VM sat at its
  1,024 MiB cgroup cap at N=8, and MemAvailable fell to 7,927 MiB. At N=16 MemAvailable fell to
  3,945 MiB. That is above the 1,536 MiB floor and the 1,024 MiB watchdog floor, so there was no
  abort.
  - e15.slice MemoryHigh never throttled (`high` +0).
  - The VMs' own 1 GiB caps reclaimed page cache (`max` +27,044 events in the window; +8,176 at
    N=8, which held).
  - N=16 failed on the tail (p95x 3,413), with host CPU at 43%.
- **Global OOM: none.** `journalctl -k` showed 0 "Out of memory: Killed process" lines over the
  whole run, checked after the first mem512 resident rung and by a sentinel every 20 s. e15.slice
  `oom_kill` stayed 0.

## 4. Predictions against outcomes

Sealed at `708d62f` (2026-11-04 01:55Z). Each verdict uses the prediction's own `falsifiedBy` text
and the primary `n_max` (prediction 7).

| # | prediction | outcome | verdict |
|---|---|---|---|
| 1 | SBX bound by CPU; resident ∞ by memory. | SBX's first failed default rung (N=16) reads binding `cpu`. Resident ∞'s first failed default rung (N=16) failed on latency with binding `cpu` (first run) / `none` (counted repeat), and MemAvailable stayed at 11.4 GiB, far above floor + 1 GiB. | **Falsified** (the resident half), as calibration expected. The SBX half holds as labelled, but the window mean was 41% CPU: bursts, not saturation. |
| 2 | SBX holds more than resident ∞ at default. SBX [40, 48]; resident ∞ [48, 48]. | SBX 8, resident ∞ 8. | **Falsified**: 8 ≤ 8, a tie. Both numeric ranges are also falsified: 8 is far below [40, 48]. |
| 3 | Resident 300 s within one ladder step of SBX. Range [48, 48]. | resident 300 s 8, SBX 8: same step. | **Held** (direction). The numeric range is falsified (8, not 48). |
| 4 | At H = 7200 s SBX's and resident 300 s's `n_max` rise; resident ∞ stays within one step of its default. | SBX 8 → 8; resident 300 s 8 → 8; resident ∞ 8 → 8. | **Falsified**: neither SBX nor resident 300 s rose. The resident ∞ half holds (no move). The calibration concern was the opposite risk (resident ∞ rising too); neither happened. |
| 5 | Removing host-infra sessions and chains moves both arms the same way; neither reverses the default result. | Default: SBX − resident ∞ = 0 (tie). no-infra: 1 − 8 = −7. no-chains: 1 − 24 = −23. | **Falsified.** The default sign is zero (a tie). At both points resident ∞ holds more than SBX, so the arms did not move the same way: SBX fell to 1 at both, resident ∞ stayed at 8 (no-infra) or rose to 24 (no-chains). Judged strictly by sign, a tie has no sign to reverse; we report it as falsified because the arms moved in opposite directions. |
| 6 | Driver < 1% of host CPU at every N (A2). | Max `a2_pct_of_host` over 102 rung records: 0.248% (no-chains resident 300 s N=32). Control N=128: 0.056%. | **Held.** |
| 7 | Method, not a prediction. | Applied as sealed. | — |
| 8 | Metal SBX/resident ∞ ratio larger than here. | Preliminary ratio: 8 / 8 = **1.0** (default, primary). | **Pending the metal run.** |
| 9 | At mem512 resident ∞ is memory-bound, and SBX holds more. Resident ∞ [8, 8]; SBX [16, 16]. | Resident ∞ 8 (in range). Its first failed rung (N=16) had no memory_floor, no watchdog abort and no MemoryHigh throttling (`high` +0); it failed on the latency tail, binding `none`. SBX 1 (not in [16, 16]). | **Falsified** on both halves: resident ∞'s failure is not memory-bound by the sealed definition, and n_max(SBX) 1 ≤ 8. The resident numeric range held. The calibration concern ("SBX's N=8 smoke did not hold, so n_max(SBX) may be 1") came true. |

**The calibration concerns, as recorded before measurement:**
- **P1:** "the resident half of this prediction is expected to be falsified". It was.
- **P2:** "calibration suggests it may be falsified or tie". It tied.
- **P4:** "the 'resident ∞ stays within one step' half is expected to be falsified unless memory
  binds first". It was not falsified. Nothing rose: every arm met the latency tail at 8–16, well
  below the CPU bound calibration predicted (~48).
- **P9:** "n_max(SBX) may be 1". It was 1.

**Why every numeric range missed.** The ranges came from resource bounds: CPU at 80–90% of 4 vCPU,
and memory against the footprint. The arms failed long before either bound, on condition 4's
tail. Calibration measured CPU per call at N=8, where the tail was still inside the limit, and did
not model queueing of long single-vCPU calls behind each other.

## 5. Both readings of the resident results (footprint-drift repeats)

**The repeat rule is asymmetric.** ladder.sh repeats a rung, once, with a doubled warm-up, when a
resident arm's VM footprint drifts more than 10% across the window (SPEC §5.7); the repeat
counts. SBX has no VMs that live across calls, so it never drifts and never gets a second run. A
resident rung therefore has two chances to land on either side of a noisy threshold; an SBX rung
has one.

Below, **sealed** is the reading the predictions use (the repeat counts). **First run only**
ignores every drift repeat. "≥" marks a first-run reading the ladder never tested beyond: the
sealed ladder stopped at the next rung, so the next rung's first run does not exist. No sealed
number changes.

| point | arm | sealed `n_max` / `n_max_abs` | first-run-only `n_max` / `n_max_abs` | rungs repeated / run | verdict flipped by the repeat |
|---|---|---|---|---|---|
| default | resident ∞ | 8 / 8 | 8 / 8 | 1 / 3 | none (N=16 failed both runs) |
| default | resident 300 s | 8 / 8 | 8 / 8 | 1 / 3 | none |
| long | resident ∞ | 8 / 8 | 8 / 8 | 1 / 3 | none |
| long | resident 300 s | 8 / 8 | 8 / 8 | 1 / 3 | none |
| short | resident ∞ | 1 / 1 | **≥ 8** / 1 | 2 / 2 | N=8: held → failed |
| no-infra (first ladder) | resident ∞ | null / null | ≥ 1 / ≥ 1 | 1 / 1 | N=1: held → empty_window |
| no-infra (first ladder) | resident 300 s | null / null | ≥ 1 / ≥ 1 | 1 / 1 | N=1: held → empty_window |
| no-infra (re-run from 8) | resident ∞ | 8 / 1 | 8 / 1 | 1 / 2 | none |
| no-infra (re-run from 8) | resident 300 s | 8 / 1 | 8 / 1 | 0 / 2 | none |
| no-chains | resident ∞ | **24** / 24 | **8** / 1 | 5 / 5 | N=16, N=24: failed → held; N=8 abs: failed → held |
| no-chains | resident 300 s | **24** / 24 | **16** / 1 | 5 / 5 | N=24: failed → held; N=8, N=16 abs: failed → held |
| mem512 | resident ∞ | 8 / 1 | 8 / 1 | 0 / 3 | none |

**Count.** 17 resident rungs were repeated out of 31 resident rungs run (counted ladders; the
no-infra first ladders add 2 more N=1 repeats, both flips). The repeat flipped a primary verdict on 6 rungs:
- to **hold** on 3 (no-chains resident ∞ N=16 and N=24, no-chains resident 300 s N=24);
- to **fail** on 3 (short resident ∞ N=8, and both no-infra N=1 empty windows).

It flipped an absolute verdict on 3 more (no-chains N=8 for both arms, N=16 for resident 300 s).

**What this does to the findings:**
- **Default and long:** the reading does not matter. The arms tie at 8 either way.
- **no-chains:** first-run only, resident ∞ holds 8 and resident 300 s 16, against SBX 1. Resident
  still holds more than SBX, but by one or two ladder steps, not three. The sealed 24 rests on
  repeats that ran with a 20-minute warm-up while SBX's ran with 10 minutes.
- **short:** first-run only, resident ∞ holds at least 8 against SBX 1. The sealed tie at 1 comes
  from the repeat.

Either way, no point shows SBX holding more than a resident arm.

## 6. Retried, repeated or excluded

- **Shared-host rule (SPEC §12).** The SPEC says to repeat a rung whose window overlaps a spike of
  other services' CPU above 10% of the host. record.py has no such check, so the run added one
  (`results/aws-prelim/scripts/shared_host.py`): other CPU = host busy % − e15.slice's share, per
  1 s sample in the window, flagged when its 10 s rolling mean exceeds 10% (ruling). The driver and
  E15's Redis sit outside e15.slice and count as "other"; at idle that baseline is 1.5–2%.
  - Two rungs were flagged: no-chains resident ∞ N=32 (17.6%) and resident 300 s N=32 (16.2%).
  - Both were re-run and failed again, so no verdict depends on the flag.
  - Both fell at about 66–77% host busy, where the estimate gets noisy (p95 15% at a mean of 2.7%).
    The flags may be load artefacts, not another tenant.
  - Every other rung's maximum was ≤ 7.9%.
- **Footprint-drift repeats:** see §5. 19 resident rungs in all.
- **Unseeded-session re-runs (`-k2`):** none. K = 16 per slot was enough at every rung.
- **Empty-window N=1 at no-infra resident:** re-run from N=8 (§3.2).
- **Rig errors:** none. There were 0 driver aborts, 0 time-origin mismatches, 0 corpus-join misses
  and 0 relay-attach failures. Every rung logged "relay attach check passed".
- **Excluded sessions:** per rung, sessions with fewer than 3 window calls are excluded from
  condition 3 and counted (`sessions_excluded_lt3`).
- **Calibration attempts superseded** before sealing are under `results/calibration/` and in the
  ledger. None of them is used here.

## 7. Fidelity concerns

- **The tail limits are tight for a 4-vCPU host.** B (the N=1 within-class excess p95) is
  229–298 ms. At N=8–16 a few overlapping long calls push the p95 past 3B. The verdicts then rest on
  roughly the top 5% of 100–450 window calls.
- **One run per cell** (SPEC §10.3). The short resident ∞ N=8 verdict flipped between its first run
  and its repeat. Differences of one ladder step are within noise here.
- **The ladder is coarse at the knee.** It jumps 8 → 16. The supplementary rungs (§9) probe 10,
  12 and 14 at the default point.
- **`file_ops` replays about 40% less work than recorded.** The library overstates its run time.
  Class matching neutralises it for condition 4 (from calibration).
- **Stand-ins:** host-infra, opaque and build calls replay as stand-ins (SPEC §12).
- **The binding label reads only the window's last 60 s.** It can say `cpu` for a window whose mean
  was 41%, or `none` for one that failed on CPU bursts mid-window.

## 8. Rig operations during the run

- **Chain:** `results/aws-prelim/scripts/chain.sh` ran the sealed ladders unattended.
  `post-chain.sh` merged the §12 re-runs, re-ran the empty-window ladders and then ran the
  supplementary rungs.
- **OOM sentinel:** every 20 s, `journalctl -k` was scanned for "Out of memory: Killed process".
  It never fired. The chain's built-in sentinels were killed at 2026-11-05 01:12Z by an operator
  `pkill` while restarting post-chain, and a standalone sentinel (`sentinel.sh`) replaced them
  within 5 minutes. No rung was running unguarded by both the slice limits and the watchdog.
- **Laptop checkout:** 69 tracked files outside `e15/` were found deleted on disk at about
  2026-11-04 10:30Z, by something external to E15. They were restored from HEAD; nothing was lost.

## 9. Supplementary (not sealed)

A user decision taken after the default ladders tied at 8: extra rungs at N=10, 12 and 14, default
point, all three arms. **These rungs are outside the sealed procedure.** They never change
`ladder.json`, any `n_max` or any prediction verdict.

They used the same rung procedure as the sealed rungs: the same default baselines, the
footprint-drift repeat rule, the §12 check, the relay restart and attach check, and the OOM
sentinel. They ran through `rig/fine.sh` (`8071464`), ascending, and stopped at the first N where
both rules failed. Results are in `results/default/<arm>/supplementary/` (`fine.json`, `N10/`, and
`N10-repeat/` for the resident arms). They ran 2026-11-05 11:41–14:08Z.

| arm | N=10 first run | N=10 repeat (counted) | `n_fine` / `n_fine_abs` | first run only |
|---|---|---|---|---|
| SBX | fails both: p95x 823 (limits 687 / 479), host 18.5% | — (no drift) | none / none | none / none |
| resident ∞ | **holds both**: p95x 385, drift 27.5% | fails: p95x 1,556, drift 58.0% | none / none | ≥ 10 / ≥ 10 |
| resident 300 s | holds primary: p95x 620 (abs fails vs 540), drift 65.0% | fails: p95x 3,104, drift 78.4% | none / none | ≥ 10 / none |

All three runs had 0 failed calls and 0 refusals, and no §12 flag (other CPU ≤ 4.3%). "≥ 10":
N=12 was never run, because the counted repeat stopped the steps.

**Reading.** As counted, no arm holds 10, so the knee lies between 8 and 10 for every arm. On first
runs only, both resident arms hold 10 and SBX does not. This is the same asymmetry as §5: here the
repeat decides whether resident ∞ is ahead of SBX by part of a ladder step or tied with it.

## 10. Teardown

`teardown.sh --purge` at 2026-11-05 14:29Z: every UNDO and PURGE line replayed with exit 0. Then
the verify checks passed. `microvm-worker.service` is active; `bench-cp` and `bench-redis` are Up;
`sh-relay`, `sh-supervisor` and `sh-control-plane` are active and were never touched. No E15 unit,
cgroup or port (9643/9644/9645/9646/6400) is left, no Firecracker process is running, and
`/srv/e15` is removed. The manifest (`~/e15-manifest.md` on the rig) ends with the Teardown
section.

---

_Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>_
