# E16 — low duty cycle: does SBX hold more sessions than resident VMs when sessions are mostly idle?

Version: 0.1, 2026-11-07
2026-11-08 (user decision at the seal, before any ladder rung): the resident ∞ ladder extends past 1024 to 1280 and 1536 (fresh-metal `E15_LADDER_EXTRA`), so a resident `N_max` at the old ladder top is not censored. Capacity at 1536: ~230 GiB of VM memory at ~150 MiB per VM, 4 MiB per workspace image.
Status: **Design. Approved by the user 2026-11-07.**
Parent: E15 (`experiments/e15-session-density/SPEC.md`, metal procedure in its §13; results in `experiments/e15-session-density/results/metal/RESULTS-METAL.md`).
E16 reuses E15's instrument, rig scripts and metal host unchanged except where this document says so.
"E15 §n" refers to E15's spec.
Rig: the E15 metal host, AWS m7i.metal-24xl (96 vCPU, 377 GiB, bare metal), as set up for E15.

---

## 1. The question

**When each session is busy at most 2% of the time, does SBX (a fresh microVM per command) hold more
concurrent coding-agent sessions per host than resident microVMs kept for the whole session?**

The hypothesis is the user's: *at a duty cycle of 2% or less, SBX may win on the total number of
sessions.*

### 1.1 Why it could be true

A resident VM lives for its session's whole span, busy or idle. SBX keeps a VM only while a command
runs. At the E15 default point (9.5% occupied) both arms were stopped by the latency tail long before
memory mattered: resident ∞ held 128 sessions on metal and SBX 80. Lowering the duty cycle lowers
each session's CPU and latency load, so both latency limits move up roughly as 1/duty. Resident's
memory per session does not move. At some duty cycle resident's held memory could bind before SBX's
latency limit does. E16 tests whether 2% is that point.

### 1.2 What "fair" means here (user decision 2026-11-07)

- **Memory is physical memory.** moca's admission budget charges every VM its full guest RAM
  (`SH_MAX_COMMITTED_MB`), so a resident VM using about 114 MiB is counted as about 1 GiB. That is a
  policy an operator sets, not a host limit. E16 sets the budget and the run cap high enough that
  they never bind, in both arms. The host's real memory is the only memory limit, enforced by the
  E15 guards (moca's host-memory floor, the e15.slice `MemoryHigh`/`MemoryMax`, rung.sh's
  MemAvailable watchdog), each of which records a measured memory verdict, not a crash.
- **Resident VMs are kept forever** (resident ∞, `T_idle` = ∞, E15 §7.3). No idle reclaim. This is
  the comparison the hypothesis names. Resident 300 s is not run.
- What moca's admission rule *would* allow is reported as a calculation (§7.3), never as a verdict.

## 2. Goals, non-goals

**Goals**
- One verdict: at duty ≤ 2%, is SBX's `N_max` above resident ∞'s by at least one ladder step?
- The mechanism behind it: each arm's binding resource (latency tail, CPU, physical memory), resident
  VM memory against VM age over long sessions, live-VM counts.

**Non-goals**
- No change to moca. No bundling (E15b, on hold). No other host.
- No synthetic sessions. E16 replays recorded sessions whose own duty cycle is ≤ 2%; it does not
  stretch the gaps of busier sessions.

**Anti-goals**
- A result that rests on moca's admission accounting.
- A resident arm stopped by a rig cap (workspaces, disk, run cap) rather than by the host.

## 3. Workload

### 3.1 The low-duty band

Duty cycle = a session's occupied time (at least one command running) ÷ its span, on the replay
timeline at H = 1800 s (E15 §5.4, the same definition). From the E15 default corpus (4,147 sessions,
TraceLab v0.0.2):

| band | sessions | users | top user | occupied | CPU-carrying work | calls/s per session | mean span |
|---|---|---|---|---|---|---|---|
| all (E15 default) | 4,147 | — | — | 9.54% | 8.21% | 0.0174 | 2.05 h |
| duty ≤ 2% | 1,151 | 41 | 20.0% | 0.77% | 0.79% | 0.0092 | 2.63 h |
| **(1%, 2%] — E16** | **456** | **40** | **24.3%** | **1.49%** | **1.52%** | **0.0112** | **2.49 h** |
| ≤ 1% | 695 | 35 | 19.9% | 0.34% | 0.35% | 0.0079 | 2.72 h |

Heavy calls (work > 10 s) carry 65% of the work in the (1%, 2%] band, against 87% in the full corpus.

**E16 replays the (1%, 2%] band** (point `lowduty`). It is the hardest case for the hypothesis
inside "≤ 2%": resident's memory per session does not depend on duty, while both latency limits rise
as duty falls. So an SBX win at about 1.5% duty implies a win below it; a loss leaves the ≤ 1% band as
the next test (§9).

### 3.2 Reuse and limits

- 456 sessions are fewer than the larger rungs' N. The E15 sampler draws without replacement and
  reshuffles on exhaustion (`experiments/e15-session-density/driver/corpus.go`), so at N > 456 some recorded sessions run twice
  at once, each from its own random start index. Reported per rung (distinct traces / N).
- The per-user cap of 15% (E15 §5.7) stays. The top user holds 24.3% of the band, so the sampler
  skips that user more often than others; the realised per-user share is reported.
- Every rung reports the duty cycle actually replayed in its window (occupied ÷ window, per session,
  median and mean), so a window that drifts away from the band is visible.

## 4. Arms

| arm | sandbox | baseline |
|---|---|---|
| **sbx** | a fresh microVM per recorded call (E15) | its own N = 1 baseline and per-class probe at `lowduty` |
| **resident ∞** | one VM per session, kept for the session's life (E15 resident patch, `T_idle` = ∞) | its own N = 1 baseline and per-class probe at `lowduty` |
| control | no sandbox | once, at the top rung, for A2 (driver < 1% of host CPU) |

Guest RAM 1024 MiB in both arms (E15). Standby depth SBX 2, resident 0 (E15).

## 5. Configuration

E15 metal procedure (E15 §13) unchanged, except:

| setting | E15 metal | E16 | why |
|---|---|---|---|
| `SH_MAX_COMMITTED_MB` | 1,048,576 (1 TiB) | **4,194,304 (4 TiB)** | never binds: 4 TiB ÷ 1,056 MiB ≈ 3,970 VMs, above any N run |
| `SH_MAX_RUNS` | 2,048 | **4,096** | never binds for resident ∞ (one run per session) |
| `SH_HOST_MEM_FLOOR_MB` | 1,536 | 1,536 | kept: the physical memory guard |
| e15.slice `MemoryMax` / `MemoryHigh` | host − 3 GiB / − 4 GiB | same | kept |
| rung.sh MemAvailable watchdog | 1,024 MiB × 3 s | same | kept |
| ladder | E15 metal ladder | explicit rung list (§8) | time |
| point | default | `lowduty` (§3.1) | |

Every change is recorded in the host manifest with its undo, as in E15.

## 6. Pre-check: does a resident VM keep growing over a long session?

Under physical memory, resident ∞ can only be stopped by memory if its VMs grow well beyond the
~114 MiB E15 measured at its default rungs. E15's windows saw VMs up to about 40 minutes old, and the
band's sessions last 2.5 hours. So, before any E16 rung:

1. **From E15's records, at no rig cost:** for every resident ∞ rung on metal, each VM's
   `memory.current` against its age (from `samples.jsonl` VM cgroups and session start times). Fit the
   growth between 20 and 60 minutes of age.
2. **If the median VM grows by more than 10% between 20 and 60 minutes**, run one long rung:
   resident ∞, `lowduty`, N = 256, warm-up 600 s, window 3 h (about 3.5 h on the rig), and report VM
   memory against age to 3 h. Its verdict is information, not a ladder rung.
3. The predictions (§10) use the measured growth to compute resident's physical memory bound.

If VMs flatten (≤ 10%), the resident memory bound is about 377 GiB ÷ (measured footprint), several
thousand sessions, and E16 expects latency to decide both arms.

## 7. The verdict

### 7.1 Holds N

E15 §8 unchanged (class-matched pace ≤ 10%, class-matched p95 excess ≤ max(3 × B, 50 ms), no failed
call, no refusal), with B and the class medians from each arm's `lowduty` baseline. The absolute
verdict (B + 250 ms) and the two supplementary readings of the E15 metal run (p95 excess ≤ 1 s, and
conditions 1–3 only) are reported beside it, from the same rungs. A memory verdict (`memory_floor`,
`memory_high`, a host-memory refusal, an OOM kill inside e15.slice) is a failed rung bound by memory.

### 7.2 The hypothesis, decided before any rung runs

- **Holds** if SBX's `N_max` is at least one ladder step above resident ∞'s.
- **Falsified** if SBX's `N_max` is at or below resident ∞'s.
- Stated on the primary verdict. The absolute and supplementary readings are reported, not voted.

### 7.3 Admission as a calculation

For each arm, the measured peak of live VMs at its `N_max` rung, times 1,056 MiB, against a budget
equal to host RAM (377 GiB): the N at which moca's default no-overcommit admission would have refused
it. Reported for sizing moca. Not part of the verdict.

## 8. Rungs: the shortest rigorous plan

E15 showed both arms hold far beyond N = 8 at higher duty, so E16 starts high. Expected limits
(E15 metal default `n_max` scaled by CPU-carrying work, 8.21% → 1.52%, ×5.4): SBX about 430,
resident ∞ about 690. Rungs are taken from E15's metal ladder.

| arm | rungs, ascending | stop |
|---|---|---|
| sbx | 256, 384, 512 | first failure; then one bisecting rung between the last hold and the first failure (448 or 576) |
| resident ∞ | 256, 384, 512, 640, 768 | the same, with bisecting rung 704 or 896; if 768 holds, 896 and 1024; if 1024 holds, 1280 and 1536 |

- **If an arm fails at 256**, it steps down the E15 ladder (192, 160, 128, …) until a rung holds,
  then bisects.
- **Precision.** At N ≥ 256 a window holds about 2,500 or more calls, so each rung's p95 is well
  estimated (E15's AWS rungs had 7–22).
- **Seeds.** The two rungs that set each arm's `N_max` (its last hold and its first failure) run with
  a second seed. A rung's verdict stands only if both seeds agree; if they disagree, a third seed
  decides by majority.
- **Repeats.** E15 metal rules: footprint drift on summed VM memory (> 10% → repeat with warm-up
  2400 s, K doubled); a rung whose only condition-1 failures are grace-end cuts is re-run once with
  grace 900 s. Both runs are kept.
- **Order.** SBX's ladder first, then resident ∞'s, so the two never share the host. Control N = 768
  once at the end.

**Capacity check at the top rung (N = 768):** workspaces about 25 GiB of disk (measured delta 2 MiB per
image, K × 2); resident ∞ memory about 85 GiB at 114 MiB per VM; 287 GiB disk and 377 GiB RAM free.

### 8.1 Rig time

| step | hours |
|---|---|
| Band corpus, resync, setup (E16 settings) | 1.5 |
| §6 step 1 (E15 records, off-rig) | 0 |
| N = 1 baselines + per-class probes, sbx and resident ∞ | 5.5 |
| **Predictions sealed (user approval)** | — |
| SBX ladder (3 + 1 rungs) | 3 |
| Resident ∞ ladder (5 + 1 rungs) | 4.5 |
| Second seeds on the four deciding rungs | 2.5 |
| Control N = 768 | 0.5 |
| **Total** | **about 17.5 h** (+3.5 h if §6 step 2 runs) |

## 9. Risks and open items

- **Band edge.** If SBX wins at (1%, 2%] the result extends to lower duty (§3.1). If it loses, the
  ≤ 1% band (695 sessions, 0.34% occupied) is the natural next point; it is not in E16.
- **Session reuse above N = 456** (§3.2). If a rung's distinct-trace share falls below 60%, the
  report flags it.
- **The latency tail is the likely decider again.** E15 showed both arms fail on minutes-long calls
  running a few percent slow. At low duty there are fewer such calls per session, but the band's heavy
  calls still carry 65% of its work. If both arms stop on the same tail mechanism, the verdict is
  about per-command cold state (E15's finding), not memory.
- **Long-session memory** (§6) is the one effect that could let SBX win. It is measured before the
  predictions are sealed.

## 10. Predictions (written after calibration and §6, sealed before the first measured rung)

Written from the `lowduty` baselines, §6 and E15's metal results, in E15's `predictions.json`
format, each with `metric` and `falsifiedBy`. At least:

1. The hypothesis (§7.2), with each arm's predicted `N_max` range.
2. Each arm's binding resource at its first failed rung.
3. Resident ∞'s peak physical memory at its `N_max`, against the host.
4. The driver stays under 1% of host CPU (A2).

## 11. What's built

New code lives in moca-experiments under `experiments/e16-low-duty/`; changes to E15's rig scripts are fresh-metal-only
and leave the sealed E15 procedures unchanged.

1. `experiments/e16-low-duty/extract/duty_band.py`: filters an E15 corpus by session duty cycle (`--duty-min`,
   `--duty-max`, E15 §5.4 definition) and writes a corpus and its report. Tests.
2. Point `lowduty` in the rig's points table.
3. Per-run worker overrides for `SH_MAX_COMMITTED_MB` and `SH_MAX_RUNS` (`E15_MAX_COMMITTED_MB`,
   `E15_MAX_RUNS` env), with rig tests.
4. `ladder.sh` with an explicit rung list (`E15_LADDER_RUNGS`), with rig tests.
5. Per-rung replayed duty cycle and distinct-trace share in `record.py`.
6. `experiments/e16-low-duty/analysis/vm_age.py`: VM memory against VM age from E15/E16 samples (§6).

## 12. Decisions taken during design

| decision | value | source |
|---|---|---|
| Memory basis | physical memory; admission never binds (4 TiB budget, 4,096 runs) | user, 2026-11-07 |
| Resident arm | resident ∞ only (kept forever) | user, 2026-11-07 |
| Band | (1%, 2%] of the E15 default corpus | our call: hardest case inside ≤ 2% |
| Starting rung | 256 | our call: E15 metal limits scaled by 1/duty |
| Deciding rungs | two seeds, third on disagreement | our call |
| E15b | on hold | user, 2026-11-07 |
