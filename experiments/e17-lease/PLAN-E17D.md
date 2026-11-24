# E17d Implementation Plan — level 2's latency case on the shipped `lease+processes`

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Size level 2's latency case on what moca ships (spec §14): a re-query and a recompute against a persistent interpreter that `process_start` started, against level 1 and per-`Exec`, at N = 1 and N = 128. Then measure what the server costs in memory and restarts, and check that the level-2 ends notify and sync within their bounds. Then report it, so that moca's security review §7 can be signed off with the latency case measured (ADR-0048 decision 19).

**Architecture:** E17d is E17c's instrument at a new pin, plus one arm, one point and a driver feature. An `E17D=1` profile layers on `E17C=1`: its own pin file, checkout and snapshot leaf. The new arm `ship-300-l2` sets the sandbox's mode to `lease+processes`. The new point `pycache-l2` reuses `pycache`'s workspace with turns built around a loaded frame. The driver learns the process kinds (`EXEC_KIND_PROCESS_START`, `_LIST`, `_STOP`) and one rule: when a level-2 re-query's client exits 3 (no server), it starts `l2srv.py` and re-runs the client, recording the call as a restart. Predictions are sealed with the user after calibration and before the first measured rung.

**Tech Stack:** as E17c: bash rig scripts and their shell tests, Python 3 analysis (pytest), the E15 Go driver, a moca checkout at the new pin.

**Spec:** `experiments/e17-lease/SPEC.md` v0.10 §14 (and §4–§7, §13 for what it inherits). E17b and E17c's records are sealed and not edited. Design under test: moca's lease spec §7 (level 2) and §16 item 6.

**Branches:** this plan on `e17d/plan`; the build on `e17d/build` (moca-experiments). Rig: the AWS m7i.metal-24xl, through `~/gh/aws-rig`. **The user decided on 2026-11-24 to stop it until this plan is approved.**

## Global Constraints

- **Sealed procedures stay.** Every earlier profile resolves exactly as before with `E17D` unset, and its tests keep passing.
- **No rig time before the user approves this plan, and no measured rung before `predictions-e17d.json` is sealed with the user's approval.** One manifest line per host change in `~/e17-manifest.md`, with its undo. Every `rm -rf` targets a checked leaf. Snapshots go into new leaves only, and earlier runs are moved aside, never deleted.
- **One pin:** `E17D_MOCA_PIN`, a full sha of moca `main` with #1026 merged, in `experiments/e17-lease/rig/e17d-pins.sh`.
- **Arms:** `sbx`, `ship-300`, `ship-300-l2` (spec §14.2). Every arm keeps `SH_LEASE_CACHE_DROP_S` at its default and the E17b admission settings.
- **Gated criteria** (spec §14.4): L2a–L2d, with numbers fixed at the seal. Everything else is reported.
- **Records:** each rung's `params.json` records the moca commit, the snapshot hash, the arm's mode and idle timeout, and whether the snapshot advertises `lease-processes-v1`.

## Review Focus

1. **A restart is not a warm call.** The client's exit 3 is the only signal that the server is gone. A server that answers late, or a socket left over from a dead server, must not read as warm. Task 4's tests cover a stale socket file, a server that is still loading, and one killed between two calls.
2. **The level-2 charge can bind before N = 128.** Calibration (Task 10) measures the per-lease charge and moves the N = 128 rung down before the seal if it doesn't fit (spec §14.5).
3. **Ownership of the socket.** A tracked process runs under a uid in 20000–20003, and an Exec under the Exec uid, both in group `sbx-ws`. Task 9's socket check runs on the built snapshot before any calibration.

## File Structure

| file | change |
|---|---|
| `experiments/e17-lease/rig/e17d-pins.sh` | new: `E17D_MOCA_PIN` |
| `experiments/e15-session-density/rig/lib.sh` | the `E17D` profile beside `E17C`'s; `ship-300-l2` in `E15_ARMS`, `worker_env` and the lease-arm helper |
| `experiments/e15-session-density/driver/exec.go`, `lease.go`, `replay.go` | the process kinds; the restart rule; `restart`, `server_ms` and `process_events` in `calls.jsonl` |
| `experiments/e17-lease/workload/project/l2srv.py`, `l2c.py`, `l2q.py`, `l2common.py` | new: from `results/followups/`, with the socket in `/workspace/.l2/` and the client's exit codes |
| `experiments/e17-lease/workload/library.json` | classes `py_requery`, `py_refit`, each with a per-arm command |
| `experiments/e17-lease/rig/gen_corpora.sh` | point `pycache-l2`, its own corpus hash |
| `experiments/e17-lease/rig/chain-e17d.sh` | new: E17d's stages, seal file `predictions-e17d.json` |
| `experiments/e17-lease/analysis/latency_report.py`, `warmcold_lease.py` | the warm/restart split for `ship-300-l2` |
| `experiments/e17-lease/analysis/level2.py` | new: restarts, the level-2 charge, end notices and sync times |
| `experiments/e17-lease/analysis/verdict_e17d.py` | new: L2a–L2d and the reported readings |
| `experiments/e17-lease/predictions-e17d.json` | new, Task 11 |
| `experiments/e17-lease/results/E17D-REPORT.md` | new, Task 13 |

---

### Task 1: Branch, pin and the `E17D` profile

**Files:** `rig/e17d-pins.sh` (new), `lib.sh`; test `rig.test.sh`.

- [ ] **Step 1:** Branch `e17d/build` from `e17d/plan`. Run the rig and pytest suites. Expected: pass (baseline).
- [ ] **Step 2: Failing tests:** `test_e17d_profile_off_is_unchanged`, `test_e17d_profile_on` (pin, checkout and snapshot key follow `e17d-pins.sh`), and `test_e17d_pin_is_a_full_sha`.
- [ ] **Step 3:** Implement. The pin is an all-zero placeholder until #1026 merges; `e17d_require_pin` refuses it at bring-up. PASS.
- [ ] **Step 4:** Commit `feat(e17d): E17D profile with its own moca pin and checkout`.

### Task 2: The `ship-300-l2` arm

**Files:** `lib.sh`; test `rig.test.sh`.

- [ ] **Step 1: Failing tests:** `ship-300-l2` is in `E15_ARMS` only under `E17D=1`. Its worker env equals `ship-300`'s, and its sessions' set-mode request names `lease+processes`. Bring-up refuses a snapshot whose manifest lacks `lease-processes-v1`.
- [ ] **Step 2:** Implement. PASS. Commit `feat(e17d): the ship-300-l2 arm`.

### Task 3: The level-2 workload

**Files:** `workload/project/l2*.py`, `library.json`, `gen_corpora.sh`; tests `workload/test_l2.py`, `rig/tests`.

- [ ] **Step 1: Failing tests** (pytest, local, no VM): `l2srv.py` binds `/workspace/.l2/l2.sock` through a temporary name and a rename, so a client never sees a half-bound socket. `l2c.py` exits 0 with the result, 3 when no server answers within 2 s (a missing socket, a refused connection, or a stale socket file), and 4 on a server error. `l2q.py` gives `l2c.py`'s result for the same query on the same data. `l2c.py --wait 60` polls until the server is ready.
- [ ] **Step 2:** Implement from `results/followups/` (the spike's `light` and `fit` queries, with the one-column median). PASS.
- [ ] **Step 3: Failing tests:** `pycache-l2`'s corpus has per turn one first `py_requery`, 2–5 `py_requery` or `py_short`, and one `py_refit`, with `pycache`'s think-gap draw and its own hash. `library.json`'s classes map to `l2q.py` at `sbx` and `ship-300`, and to `l2c.py` at `ship-300-l2`.
- [ ] **Step 4:** Implement. PASS. Commit `feat(e17d): the pycache-l2 workload and corpus`.

### Task 4: The driver's process kinds and the restart rule

**Files:** `driver/exec.go`, `lease.go`, `replay.go`; tests `driver/*_test.go`.

- [ ] **Step 1: Failing tests** (Go, against the driver's fake relay): `execProcessStart` sends `EXEC_KIND_PROCESS_START` with `ProcessArgs{name: "l2srv", cwd: "/workspace"}`. The restart rule: a `ship-300-l2` call whose client exits 3 starts the server once and re-runs the client with `--wait 60`, and the call records `restart: true`, its observed time from the first send, and the start's own time. A second exit 3 after the start fails the call with `cause: "l2_server_unavailable"`. Exits 0 and 4 never start a server. A call at another arm never sends a process kind.
- [ ] **Step 2:** Implement. PASS.
- [ ] **Step 3: Failing tests:** every lease event's `processes` and `tracked` reach `calls.jsonl` (`process_events`), and `lease-tail.jsonl` records each live lease's process table from `LeaseControl status`.
- [ ] **Step 4:** Implement. PASS. Commit `feat(driver): process kinds and the level-2 restart rule`.

### Task 5: The level-2 analysis

**Files:** `analysis/level2.py` (new), `latency_report.py`, `warmcold_lease.py`; tests `analysis/test_level2.py`.

- [ ] **Step 1: Failing tests:** warm means a live lease and no restart. Restarts are counted with their cost and the previous lease's end reason. The level-2 charge is the `vm_fp` at +45 s. For each end with a running tracked process: its notices (exactly one is the pass), and its sync time from the worker's lease end line (`age` and the destroy phases).
- [ ] **Step 2:** Implement. PASS. Commit `feat(e17d): level-2 readings`.

### Task 6: The verdict

**Files:** `analysis/verdict_e17d.py` (new); test `analysis/test_verdict_e17d.py`.

- [ ] **Step 1: Failing tests:** L2a–L2d read their thresholds from `predictions-e17d.json`, never from code. A missing rung is `null` (not run), never a pass. Each criterion's evidence is listed by rung.
- [ ] **Step 2:** Implement. PASS. Commit `feat(e17d): verdict for L2a-L2d`.

### Task 7: The chain

**Files:** `rig/chain-e17d.sh` (new); test `rig/tests/chain-e17d.test.sh`.

- [ ] **Step 1: Failing tests:** stages in spec §14.6's order. Every measured stage refuses to start without a sealed `predictions-e17d.json`. `--from` and `--to` work as in `chain-e17c.sh`, and `squeeze-l2` comes last so it can be cut.
- [ ] **Step 2:** Implement. PASS. Commit `feat(e17d): chain-e17d.sh`.

### Task 8: Final review of the build

- [ ] Review the whole branch against spec §14 (`superpowers:requesting-code-review`), fix what it finds, and open the build PR as a draft. **Stop here for the user: the rig steps that follow need the rig started, and the user's go-ahead.**

### Task 9: Bring-up on the rig (user's go-ahead)

- [ ] Start the rig (`aws-rig start`, from a plain terminal). Set `E17D_MOCA_PIN` to `main` with #1026, check out and build at the pin. Build `e17d-<pin8>-1024` in a new leaf, with a fresh throwaway test egress CA (manifested; the gates CA expired 2026-11-22).
- [ ] `go test -run TestGateLease ./internal/vmpool/` at the pin, against that snapshot. Record pass/fail counts and the snapshot in the report. This run is also evidence for moca's security review §6.2 and §7.2, at this pin.
- [ ] The socket check: a tracked `l2srv.py` and an Exec's `l2c.py` talk over `/workspace/.l2/l2.sock`; the smoke for all three arms.

### Task 10: Calibration

- [ ] N = 1 probes, three arms, at `pycache-l2`: per-class medians and the server's peak RSS. Then the N = 128 memory check at `ship-300-l2`: the per-lease charge and the committed total against the budget. If N = 128 does not fit, choose the largest N that does.
- [ ] Draft `predictions-e17d.json` with L2a–L2d's numbers, the N chosen, and a prediction per reported reading.

### Task 11: Seal (user)

- [ ] **The user reviews and seals `predictions-e17d.json`.** No measured rung runs before this. Later changes are deviations (`E17D-D<n>`), never edits.

### Task 12: The measured rungs

- [ ] `chain-e17d.sh --from lat-pycache-l2-n1 --to verdict`, logging to `/srv/e15/logs/e17d/`. `squeeze-l2` is last and may be cut (spec §14.6).

### Task 13: Report and data

- [ ] `results/E17D-REPORT.md`: each criterion judged as sealed, the reported readings, the deviations. Publish the raw rungs as the next `data-v*` release (`data/MANIFEST.md`), and open the report PR.
- [ ] Bring the user the moca follow-ups the report finds, and ask whether the rig stops.
