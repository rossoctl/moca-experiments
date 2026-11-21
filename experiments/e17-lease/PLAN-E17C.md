# E17c Implementation Plan — the v0.12.0 measurements: F1's charge, its latency cost, and E17b's deferrals

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Measure, on the AWS metal rig, what moca v0.12.0 changed in lease mode (spec §13): whether a lease VM's charge now falls back to its working set after moca #974 (criterion 5a′), what the idle page-cache drop costs warm latency (criterion 2′), and the items E17b deferred (`pycache-low`, the 256 MiB guests, the ownership walk observed directly, N = 1 on several seeds). Then report it.

**Architecture:** E17c is E17b's instrument at a new moca pin, plus one arm and a handful of readings. An `E17C=1` profile layers on E17b's `E17B=1` one: its own pin file and checkout, its own snapshot leaves, and a chain script whose stages are E17c's. The new arm `ship-300-nd` is `ship-300` with `SH_LEASE_CACHE_DROP_S=0`, so the two lease arms separate F1's guest drop from its host-cache exclusion. The sampler gains a per-VM footprint (`vm_fp`, `LeaseBytes`' formula) beside `vm_mem`, under the E17c profile only. The analysis gains the +45 s and idle-tail charge readings and a split of warm calls by whether the cache had been dropped. Predictions are sealed with the user after calibration and before the first measured rung.

**Tech Stack:** as E17b: bash rig scripts and their shell tests, Python 3 analysis (pytest), the E15 Go driver, a moca checkout at the new pin.

**Spec:** `experiments/e17-lease/SPEC.md` v0.8 §13 (and §4–§7 for what it inherits). E17b's record (`PLAN-E17B.md`, `predictions-e17b.json`, `results/E17B-REPORT.md`) is sealed and not edited. Design under test: moca's lease spec §6 as amended by #974.

**Branches:** this plan on `e17c/plan`; the build on `e17c/build` (moca-experiments). Rig: the AWS m7i.metal-24xl (`fresh-metal`, `/srv/e15`), through `~/gh/aws-rig`.

## Global Constraints

- **Sealed procedures stay.** E15, E16, E17a and E17b procedures resolve exactly as before with `E17C` unset; their tests keep passing (`experiments/e15-session-density/rig/tests/rig.test.sh`, `pytest experiments/e16-low-duty/rig experiments/e17-lease`).
- **No rig time before the user approves this plan; no measured rung before `predictions-e17c.json` is sealed with the user's approval.** One manifest line per host change in `~/e17-manifest.md`, with its undo. Every `rm -rf` targets a checked leaf; snapshots go into new leaves only, never over `/srv/e15/snapshots/e15` or an E17b leaf; earlier runs are moved aside, never deleted.
- **One pin for every E17c arm:** `E17C_MOCA_PIN`, a full sha of moca `main` with #966, #970 and #974 merged, in a new `experiments/e17-lease/rig/e17c-pins.sh`. With `E17C=1`, `lib.sh` sets `E17B=1` semantics plus `E15_MOCA_PIN="$E17C_MOCA_PIN"` and `E15_MOCA="$E15_ROOT/moca-e17c"`. E17b's rungs are not reused for a verdict (spec §13): `sbx` is re-run at the new pin.
- **Arms:** `sbx`; `ship-300` (idle 300 s, `SH_LEASE_CACHE_DROP_S` unset, so the worker's default 30 s stands and its banner says `lease_cache_drop=30s`); `ship-300-nd` (the same with `SH_LEASE_CACHE_DROP_S=0`, banner `lease_cache_drop=off`). `ship-30` and `ship-120` are not run.
- **Admission and guests:** E17b's settings unchanged (`SH_LEASE_START_MB` 192, `SH_LEASE_HEADROOM` 1.25, `SH_LEASE_PAGECACHE_MB` 256, `SH_MAX_COMMITTED_MB` host RAM − 8 GiB on the lease arms, E16's never-binding budget on `sbx`); guest RAM 1024 MiB, and 256 MiB for `pycache-d64` and `squeeze-256`.
- **Gated criteria** (spec §13.4): 5a′, 2′, 5b′, 3′. Everything else is reported.
- **Records:** each rung's `params.json` records the moca commit, the snapshot hash, the arm's token idle timeout and its `SH_LEASE_CACHE_DROP_S` as the banner printed it.

## Review Focus

1. **The +45 s reading can starve.** `pycache`'s gap draw decides how many heavy Execs have no next call within 45 s. Task 6 computes the idle-tail reading as well, and the calibration (Task 11) decides which one 5a′ is judged on, before the seal. The choice is written into the predictions, not made after the run.
2. **A guest-written file's host cache is dirty for about 30 s** (the host's `dirty_expire`), and dirty pages stay in the footprint (moca #974's gate: 175 → 107 MiB after the drop, 27 MiB only after writeback). How much of `pycache`'s charge this holds depends on how much each turn writes to the workspace, which is not yet measured; Task 6 reports `file_dirty` beside each reading, and Task 11's calibration reports its share before the seal.
3. **`ship-300-nd` is not "E17b at the new pin":** its charge already leaves out the host cache. E17b's 0.536 is cited for context only.

## File Structure

| file | change |
|---|---|
| `experiments/e17-lease/rig/e17c-pins.sh` | new: `E17C_MOCA_PIN` |
| `experiments/e15-session-density/rig/lib.sh` | the `E17C` profile (`:80-116` beside E17B's), `ship-300-nd` in `E15_ARMS` and `worker_env` (`:914`), `e17b_lease_arm` (`:992`) |
| `experiments/e15-session-density/rig/sample.sh` | `vm_fp` per VM (`:145-158`), under `E17C=1` only |
| `experiments/e17-lease/rig/chain-e17c.sh` | new: E17c's stages, seal file `predictions-e17c.json`, `E17C_OPTIONAL`, `E17C_RAM256` |
| `experiments/e17-lease/rig/snapshot-e17b.sh` | accept `e17c-<pin8>-{1024,256}` leaves under `E17C=1` |
| `experiments/e17-lease/analysis/vm_age_lease.py` | the `vm_fp` readings at +15 s, +45 s and the idle tail |
| `experiments/e17-lease/analysis/warmcold_lease.py`, `latency_report.py` | the warm split by the session's previous call's end (dropped / kept) |
| `experiments/e17-lease/analysis/verdict_e17c.py` | new: criteria 5a′, 2′, 5b′, 3′ and the reported readings |
| `experiments/e17-lease/workload/library-256.json` | new: the 256 MiB library (`py_analyze` at the calibrated scale) |
| `experiments/e17-lease/predictions-e17c.json` | new, Task 12 |
| `experiments/e17-lease/results/E17C-REPORT.md` | new, Task 14 |

---

### Task 1: Branch, pin and the `E17C` profile

**Files:** `rig/e17c-pins.sh` (new), `e15-session-density/rig/lib.sh`, `setup.sh`; test `rig.test.sh`.

- [ ] **Step 1:** Branch `e17c/build` from `e17c/plan`. Run the rig and pytest suites. Expected: pass (baseline).
- [ ] **Step 2: Failing tests:** `test_e17c_profile_off_is_unchanged` (with `E17C` unset, every variable `lib.sh` exports is as under `E17B=1` alone and as with both unset); `test_e17c_profile_on` (pin and checkout follow `e17c-pins.sh`, the snapshot key carries the new pin); `test_e17c_pin_is_a_full_sha` (placeholder and short shas refused, as `e17b_require_pin`).
- [ ] **Step 3:** Implement. Pick the pin: upstream `main` after #974 merges; record it in the commit message. PASS.
- [ ] **Step 4:** Commit `feat(e17c): E17C profile with its own moca pin and checkout`.

### Task 2: The `ship-300-nd` arm

**Files:** `lib.sh` (`E15_ARMS`, `worker_env`, `e17b_lease_arm`, the arm's warm-up `:182`), `e15-session-density/rig/points.sh` if it lists arms; test `rig.test.sh`.

- [ ] **Step 1: Failing tests:** `ship-300-nd` is in `E15_ARMS` only under `E17C=1`; its `worker_env` is `ship-300`'s plus `SH_LEASE_CACHE_DROP_S=0`, and `ship-300`'s has no `SH_LEASE_CACHE_DROP_S` line; its token idle timeout is 300 s; it is a lease arm for every caller of `e17b_lease_arm`.
- [ ] **Step 2:** Implement; PASS; commit `feat(e17c): ship-300-nd, the lease arm without the idle page-cache drop`.

### Task 3: The sampler's per-VM footprint

**Files:** `e15-session-density/rig/sample.sh`; test `e15-session-density/rig/tests/` (the sampler's fixture test).

- [ ] **Step 1: Failing test:** under `E17C=1`, a fake cgroup tree with `memory.current` and `memory.stat` gives `"vm_fp":{"<cgroup>":<memory.current − max(file − file_mapped − shmem − file_dirty − file_writeback, 0)>}` and `"vm_dirty":{"<cgroup>":<file_dirty>}` beside `vm_mem`; a VM whose `memory.stat` lacks a field is left out of `vm_fp` (not zero); with `E17C` unset the line is byte-identical to today's.
- [ ] **Step 2:** Implement in the existing per-VM loop (one more file read per VM). PASS. Commit `feat(e17c): the sampler records each VM's footprint as the worker charges it`.

### Task 4: Snapshots and the chain script

**Files:** `rig/snapshot-e17b.sh` (leaf names), `rig/chain-e17c.sh` (new); tests beside them.

- [ ] **Step 1: Failing tests:** `snapshot-e17b.sh` under `E17C=1` accepts only `e17c-<E17C pin8>-{1024|256}` and refuses `e17b-*`; `chain-e17c.sh --list` lists the stages below with their needs (`-` before the seal, `seal`, `opt`, `ram256`); a `seal` stage refuses while `predictions-e17c.json` is unsealed; the chain refuses `E15_*` stage knobs, as `chain-e17b.sh` does.
- [ ] **Step 2:** Implement with these stages (spec §13.6):
  - before the seal: `smoke`; `cal-pycache-{sbx,ship-300,ship-300-nd}` (N = 1 baselines, 4 seeds, `E15_START_ZERO=1`, plus class probes); `gate-pycache-low` (Task 9's gate); `gate-256` (Task 10's calibration);
  - `seal`: `lat-pycache-{sbx,ship-300,ship-300-nd}-n128`; `base-pycache-low-{sbx,ship-300}`, `lat-pycache-low-{sbx,ship-300}-n128`; `base-squeeze-{sbx,ship-300}`, `squeeze-ship-300` (climb at `E17B_SQUEEZE_MEMMAX_MB` 24576), `squeeze-sbx`; `ownwalk 10000 100000`; `verdict`;
  - `ram256`: `ram256-pycache-{sbx,ship-300}-n1`, `ram256-base-squeeze-{sbx,ship-300}`, `ram256-squeeze-{ship-300,sbx}`;
  - `opt`: `ladder-default-{sbx,ship-300}`; `ownwalk 500000` (needs a snapshot with a workspace drive ≥ 4 GiB, moca #907; refused otherwise, naming why).
- [ ] **Step 3:** PASS. Commit `feat(e17c): the E17c chain and snapshot leaves`.

### Task 5: The warm split by cache drop

**Files:** `analysis/warmcold_lease.py`, `analysis/latency_report.py`; tests.

- [ ] **Step 1: Failing tests:** a warm call whose session's previous call ended more than `SH_LEASE_CACHE_DROP_S` before it (read from the rung's `params.json`) is tagged `after_drop`, the rest `kept`; `ship-300-nd` (drop off) and `sbx` tag nothing; `latency_report.py` prints per class the median of each group and their ratio; criterion 2′'s gains are still over all warm calls, as in E17b.
- [ ] **Step 2:** Implement; PASS; commit `feat(e17c): warm latency split by whether the guest had dropped its page cache`.

### Task 6: The charge readings

**Files:** `analysis/vm_age_lease.py`; tests.

- [ ] **Step 1: Failing tests:** for a judged heavy Exec (E17B-R29's rules), the reading carries `vm_fp`, `vm_mem` and `vm_dirty` at +15 s and at +45 s (null at +45 s when the session's next call began within 45 s); the idle-tail reading is each lease's `vm_fp` in its last sample before an `idle` end and at least 45 s after its last Exec's end; pinned shares (≥ 0.9 of guest RAM) are computed on `vm_fp` for both readings and on `vm_mem` at +15 s (E17b's, for continuity); the relative follow rule (share_true) runs on `vm_fp`. Rungs without `vm_fp` (E17b's) keep their old output byte-identical.
- [ ] **Step 2:** Implement; PASS; commit `feat(e17c): lease charge readings on the worker's footprint, after the drop`.

### Task 7: `verdict_e17c.py`

**Files:** `analysis/verdict_e17c.py` (new), its test.

- [ ] **Step 1: Failing tests** (fixture rung trees): 5a′ pass/fail at its two bars on the reading `predictions-e17c.json` names (`plus45` or `idle_tail`); 2′ on the pooled N = 1 seeds and N = 128; 5b′ on every `ship-*` rung at `pycache`; 3′ as E17b's criterion 3; a missing input is null and listed, never guessed; `ship-300-nd`, `pycache-low`, the 256 MiB stages and the walk under `reported`.
- [ ] **Step 2:** Implement (reuse `verdict.py`'s criterion helpers rather than copy them); PASS; commit `feat(e17c): the E17c verdict`.

### Task 8: The walk, observed

**Files:** `analysis/ownwalk_phases.py`; test.

- [ ] **Step 1:** At the new pin the phase line carries `normalise_us` (moca #966). Failing test: when present, `ownwalk.json` reports per size the median `normalise_us` of the A runs, that B's is 0, and the A − B inference beside it; the `NO_FIELD` reason appears only when the field is absent.
- [ ] **Step 2:** Implement; PASS; commit `feat(e17c): the ownership walk from the worker's own phase`.

### Task 9: `pycache-low`'s baseline, made attainable (R47)

**Files:** `chain-e17c.sh` (`gate-pycache-low`), `e15-session-density/rig/baseline.sh` knobs if needed; test.

- [ ] **Step 1: Failing test:** the gate runs the N = 1 baseline at `pycache-low` with `E15_START_ZERO=1` and a 1800 s window, 4 seeds per arm, and passes only when every seed has at least 3 in-window calls of the classes criterion 2 reads (`py_short`, `py_import`); on a fail it writes `gate-pycache-low.json` with the counts and the chain skips the `pycache-low` stages, reported as cut.
- [ ] **Step 2:** Implement; PASS; commit `feat(e17c): an attainable pycache-low baseline, or a recorded cut`.

### Task 10: The 256 MiB library (R45)

**Files:** `workload/library-256.json` (new), `workload/test_workload.py`, `chain-e17c.sh` (`gate-256`).

- [ ] **Step 1: Failing tests:** the 256 library differs from `library.json` only in `py_analyze`'s `ANALYZE_WORK_SCALE`; its corpus hash differs, and `params.json` records which library a rung ran.
- [ ] **Step 2:** The calibration stage `gate-256` (rig): `py_analyze` at candidate scales in a 256 MiB guest, both arms; the chosen scale is the largest whose peak RSS ≤ 120 MiB with zero OOM kills in 20 runs per arm. It writes `gate-256.json`; the `ram256` stages refuse to start without a passing one.
- [ ] **Step 3:** PASS; commit `feat(e17c): a 256 MiB library whose py_analyze fits the lease command cap`.

### Task 11: Bring-up and calibration (controller-run, rig; about 15 h)

- [ ] **Step 1:** `aws-rig set-location home`; sync (`rig/sync.sh`); `E17C=1 setup.sh`; `snapshot-e17b.sh --ram-mb 1024 --leaf e17c-<pin8>-1024` and `--ram-mb 256 --leaf e17c-<pin8>-256` (new leaves). The worker banners show `lease_cache_drop=30s` and `=off` for the two lease arms.
- [ ] **Step 2:** `smoke`; one sampler line checked by hand: `vm_fp` ≤ `vm_mem` for every VM, and the difference near the VM's clean unmapped `file` pages.
- [ ] **Step 3:** The calibration stages. From them: how many judged heavy Execs per rung have a +45 s reading, which decides `plus45` or `idle_tail` for 5a′ (Review Focus 1); the `pycache-low` gate; the 256 scale.

### Task 12: E17c predictions — draft, user approval, seal

**Files:** `predictions-e17c.json` (E15's format, as `predictions-e17b.json`).

- [ ] **Step 1:** Draft from Task 11, one entry each: 5a′ (the chosen reading, its two shares, and the expected footprint after the drop as a share of guest RAM); 5a′ for `ship-300-nd` (how much the host-cache exclusion alone gives); 2′'s gains for both lease arms at N = 1 and 128, and the `after_drop` / `kept` ratio per class; 5b′'s ratio range; 3′ and the N at which reclaim becomes continuous against E17b's ≈ 40; `pycache-low`'s gains (or its cut); the 256 MiB gains and squeeze outcome; `normalise_us` at 10k and 100k against E17b's inferred 91 ms and 756 ms. Each with `falsifiedBy`.
- [ ] **Step 2 (user gate):** send the draft to the user; nothing in Task 13 starts until they approve. On approval set `sealed: true`, record the commit; commit `docs(e17c): predictions sealed`.

### Task 13: The measured rungs (controller-run, rig; about 36 h)

- [ ] **Step 1:** The `seal` stages in the order of Task 4, as small sequencer scripts that stop at the first failure (E17b's `e17b-seq*.sh` pattern). Watchers are bash scripts with ssh spelled out and an `__OK__` marker, re-armed every time they fire.
- [ ] **Step 2:** The `ram256` stages if Task 10's gate passed and rig time allows; the `opt` stages only on the user's say.
- [ ] **Step 3:** After each stage the analysis gate (as E17b's): an unknown call, a source disagreement or an unmatched lease end stops the chain and goes to the user, with the rung's `lease_ends.json`, `warmcold-report.json` and `vm_age_lease.json` read first.

### Task 14: The report and the raw data

**Files:** `results/E17C-REPORT.md` (new), `results/e17c/` (summaries), `results/README.md`, `SPEC.md` (status, v0.9), `data/MANIFEST.md`, `data/fetch-data.sh`, `data/e17c.files`.

- [ ] **Step 1:** The report in E17B-REPORT's shape: per criterion pass/fail with its numbers, the predictions scored against the sealed file, F1's two halves separated (`ship-300` against `ship-300-nd`), the drop's latency cost per class, and the deferred items' results or cuts. The recommendation on the 30 s default stays the user's decision.
- [ ] **Step 2:** Publish the raw rungs as the next `data-v*` release (`runs/` mirrored under `raw/e17c/runs/`, side trees beside it, as `data-v5`), verified file by file against the rig and by `verdict_e17c.py` over the extracted tree. PR on moca-experiments; ask the user whether the rig stops.

---

## Self-Review

**Spec coverage.** §13.1 questions Q5–Q7: Tasks 3, 5, 6, 8. §13.2 pin, arms, points: Tasks 1, 2, 4. §13.3 readings 1–5: Tasks 6, 5, (5b′ reuses `vm_age_lease --sbx`), 4/13 (squeeze), 8. §13.4 criteria: Task 7. §13.5 deferrals: Task 9 (`pycache-low`), Task 10 (256 MiB), Task 4 (N = 1 seeds in `cal-*`; the 500k walk as `opt`), Task 14 (raw data). §13.6 rig time: Tasks 11 and 13 (about 51 h).

**Calls to confirm.** (a) `default` is not re-run (criterion 1 cannot get worse when a lease's charge only falls); its ladder pair is `opt`. (b) 5a′ is judged on the worker's footprint, not `memory.current`, because the host's clean cache stays in `memory.current` by design. (c) The +45 s reading assumes the 30 s default; a different default would move it, and the predictions record the value. (d) `ship-30` and `ship-120` are not run. (e) The 500k walk waits for moca #907's open half.

**Proportion.** About 190 lines against a 120-line spec section. Code appears only as interfaces and test names.
