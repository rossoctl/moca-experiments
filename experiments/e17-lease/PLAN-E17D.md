# E17d Implementation Plan — level 2's latency case on the shipped `lease+processes`

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Size level 2's latency case on what moca ships (spec §14): a re-query and a recompute against a persistent interpreter that `process_start` started, against level 1 and per-`Exec`, at N = 1 and N = 128. Then measure what the server costs in memory and restarts, and check that the level-2 ends notify and sync within their bounds. Then report it, so that moca's security review §7 can be signed off with the latency case measured (ADR-0048 decision 19).

**Architecture:** E17d is E17c's instrument at a new pin, plus one arm, one point and a driver feature. An `E17D=1` profile layers on `E17C=1`: its own pin file, checkout and snapshot leaf. The new arm `ship-300-l2` sets the sandbox's mode to `lease+processes`. The new point `pycache-l2` reuses `pycache`'s workspace with turns built around a loaded frame. The arm's command differs by library file: the rig gives `ship-300-l2` its own `library-l2.json`, and the driver's `Library` stays arm-free. The driver gains two flags: `-lease-mode` (the `mode` claim it mints, `lease` or `lease+processes`, so it becomes a per-rung value) and `-l2-restart` (the restart rule, accepted only with `lease+processes`). It also learns the process kinds (`EXEC_KIND_PROCESS_START`, `_LIST`, `_STOP`). The restart rule: when a level-2 re-query's client exits 3 (its 2 s connect-and-`ping` probe found no server), the driver starts `l2srv.py` and re-runs the client, recording the call as a restart (spec §14.2). Predictions are sealed with the user after calibration and before the first measured rung.

**Tech Stack:** as E17c: bash rig scripts and their shell tests, Python 3 analysis (pytest), the E15 Go driver, a moca checkout at the new pin.

**Spec:** `experiments/e17-lease/SPEC.md` v0.10 §14 (and §4–§7, §13 for what it inherits). E17b and E17c's records are sealed and not edited. Design under test: moca's lease spec §7 (level 2) and §16 item 6.

**Branches:** this plan on `e17d/plan`; the build on `e17d/build` (moca-experiments). Rig: **the SBX0 metal host** (`ssh sbx-kvm`), not the AWS m7i.metal-24xl: the AWS rig could not start (2026-11-25), recorded as deviation E17D-D1 (SPEC §14.7). **The user decided on 2026-11-24 to stop it until this plan is approved.**

## Global Constraints

- **Sealed procedures stay.** Every earlier profile resolves exactly as before with `E17D` unset, and its tests keep passing.
- **No rig time before the user approves this plan, and no measured rung before `predictions-e17d.json` is sealed with the user's approval.** One manifest line per host change in `~/e17-manifest.md`, with its undo. Every `rm -rf` targets a checked leaf. Snapshots go into new leaves only, and earlier runs are moved aside, never deleted.
- **One pin:** `E17D_MOCA_PIN`, a full sha of moca `main` with #1026 merged, in `experiments/e17-lease/rig/e17d-pins.sh`.
- **Arms:** `sbx`, `ship-300`, `ship-300-l2` (spec §14.2). Every arm keeps `SH_LEASE_CACHE_DROP_S` at its default and the E17b admission settings.
- **Gated criteria** (spec §14.4): L2a–L2d, with numbers fixed at the seal. Everything else is reported.
- **Records:** each rung's `params.json` records the moca commit, the snapshot hash, the arm's mode and idle timeout, and whether the snapshot advertises `lease-processes-v1`.

## Review Focus

1. **A restart is not a warm call, and a slow call is not a restart.** The client's exit 3 is the only signal that the server is gone, and it comes from the 2 s probe alone, never from the query's own bound (120 s: `py_refit` takes about 11 s server-side, `results/followups/l2spike.txt:32-34`). A socket left over from a dead server must not read as warm. Task 3's and Task 4's tests cover a stale socket file, a server that is still loading, one killed between two calls, and a live server whose query takes longer than 2 s.
2. **The level-2 charge can bind before N = 128.** Calibration (Task 10) measures the per-lease charge and moves the N = 128 rung down before the seal if it doesn't fit (spec §14.5).
3. **The server's paths.** `l2common.py` resolves `src/` and `../data` from its working directory, and pandas only exists in `/workspace/venv`. So the server starts in `/workspace/project` with `../venv/bin/python`, as the spike did (`l2spike.sh:65`). Task 3's tests run it the same way, from a staged copy of the workspace layout.
4. **Ownership of the socket.** A tracked process runs under a uid in 20000–20003, and an Exec under the Exec uid, both in group `sbx-ws`. Task 9's socket check runs on the built snapshot before any calibration.

## File Structure

| file                                                                                 | change                                                                                                                                                                                          |
| ------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `experiments/e17-lease/rig/e17d-pins.sh`                                             | new: `E17D_MOCA_PIN`                                                                                                                                                                            |
| `experiments/e15-session-density/rig/lib.sh`                                         | the `E17D` profile beside `E17C`'s; `ship-300-l2` in `E15_ARMS`, `worker_env` and the lease-arm helper; the arm's driver flags (`-lease-mode lease+processes -l2-restart`) and its library file |
| `experiments/e15-session-density/rig/points.sh`                                      | the `pycache-l2` and `squeeze-l2` points (corpus, library, template, arms), and the `E17D` arm append beside `E17C`'s (`rung.sh:84` refuses an arm its point does not list)                     |
| `experiments/e15-session-density/driver/main.go`                                     | flags `-lease-mode` and `-l2-restart`                                                                                                                                                           |
| `experiments/e15-session-density/driver/lease.go`                                    | the `mode` claim from `-lease-mode` (today the constant `leaseModeName = "lease"`, `:32`), in the Exec tokens (`:136`) and the set-mode token (`:164`)                                          |
| `experiments/e15-session-density/driver/exec.go`, `replay.go`                        | the process kinds; the restart rule; `restart`, `restart_kind`, `start_ms` and `process_events` in `calls.jsonl`                                                                                |
| `experiments/e17-lease/workload/project/l2common.py`, `l2srv.py`, `l2c.py`, `l2q.py` | new: from `results/followups/`, run from `project/` with the venv; the socket in `/workspace/.l2/`; the client's probe, bounds and exit codes (spec §14.2)                                      |
| `experiments/e17-lease/workload/library.json`, `library-l2.json` (new)               | classes `py_requery`, `py_refit`: `l2q.py` in `library.json`, `l2c.py` in `library-l2.json`                                                                                                     |
| `experiments/e17-lease/extract/pycache_corpus.py`                                    | the `pycache-l2` turn shape beside `TURN_HEAD`/`DUR_MS`, and `--durations-from` for its classes                                                                                                 |
| `experiments/e17-lease/rig/gen_corpora.sh`                                           | point `pycache-l2`, its own corpus hash                                                                                                                                                         |
| `experiments/e17-lease/rig/chain-e17d.sh`                                            | new: E17d's stages (Task 7), seal file `predictions-e17d.json`                                                                                                                                  |
| `experiments/e17-lease/analysis/latency_report.py`, `warmcold_lease.py`              | the warm/restart split for `ship-300-l2`, and the warm-against-warm gain (spec §14.3 reading 1)                                                                                                 |
| `experiments/e17-lease/analysis/level2.py`                                           | new: restarts by kind, the level-2 charge, judged ends, their notices and `lease end sync` lines, #1026's `why` per refusal from `worker.log`                                                   |
| `experiments/e17-lease/analysis/verdict_e17d.py`                                     | new: L2a–L2d and the reported readings                                                                                                                                                          |
| `experiments/e17-lease/predictions-e17d.json`                                        | new, Task 11                                                                                                                                                                                    |
| `experiments/e17-lease/results/E17D-REPORT.md`                                       | new, Task 13                                                                                                                                                                                    |

---

### Task 1: Branch, pin and the `E17D` profile

**Files:** `rig/e17d-pins.sh` (new), `lib.sh`; test `rig.test.sh`.

- [ ] **Step 1:** Branch `e17d/build` from `e17d/plan`. Run the rig and pytest suites. Expected: pass (baseline).
- [ ] **Step 2: Failing tests:** `test_e17d_profile_off_is_unchanged`, `test_e17d_profile_on` (pin, checkout and snapshot key follow `e17d-pins.sh`), and `test_e17d_pin_is_a_full_sha`.
- [ ] **Step 3:** Implement. The pin is an all-zero placeholder until #1026 merges; `e17d_require_pin` refuses it at bring-up. PASS.
- [ ] **Step 4:** Commit `feat(e17d): E17D profile with its own moca pin and checkout`.

### Task 2: The `ship-300-l2` arm

**Files:** `lib.sh`, `points.sh`, `driver/main.go`, `driver/lease.go`; tests `rig.test.sh`, `driver/lease_test.go`.

- [ ] **Step 1: Failing tests (rig):** `ship-300-l2` is in `E15_ARMS` only under `E17D=1`. Its worker env equals `ship-300`'s, and its driver flags are `-lease-mode lease+processes -l2-restart` with `library-l2.json`. The two level-1 arms keep `-lease-mode lease` and `library.json`. `points.sh` lists `pycache-l2` and `squeeze-l2` with their arms. Bring-up refuses a snapshot whose manifest lacks `lease-processes-v1`.
- [ ] **Step 2: Failing tests (driver):** `-lease-mode lease+processes` puts that claim in every Exec token and the set-mode token. The default stays `lease`. `-l2-restart` without `lease+processes` is refused at start.
- [ ] **Step 3:** Implement. PASS. Commit `feat(e17d): the ship-300-l2 arm`.

### Task 3: The level-2 workload

**Files:** `workload/project/l2*.py`, `library.json`, `library-l2.json`, `extract/pycache_corpus.py`, `gen_corpora.sh`; tests `workload/test_l2.py`, `extract/` tests, `rig/tests`.

- [ ] **Step 1: Failing tests** (pytest, local, no VM, against a staged `project/`+`data/`+`venv/` layout, run from `project/` with that venv):
  - `l2srv.py` binds `/workspace/.l2/l2.sock` (a test root in the tests) through a temporary name and a rename, so a client never sees a half-bound socket.
  - `l2c.py`'s probe (connect and `ping`) is bounded at 2 s, and the query gets its own 120 s bound. It exits 0 with the result, and 3 only when the probe fails: a missing socket, a refused connection, a stale socket file, or no `pong` within 2 s. It exits 4 on a server error and 5 past the query bound.
  - A live server whose query takes 5 s gives exit 0, not 3.
  - `l2c.py --wait 60` polls the probe, never the socket file: with a stale socket file and a server still loading, it waits for the `pong`.
  - `l2q.py` gives `l2c.py`'s result for the same query on the same data.
- [ ] **Step 2:** Implement from `results/followups/`, with the spike's `light` and `fit` queries and the one-column median. Move `l2common.py` into `project/` and import it normally, not through `exec(open("../l2common.py"))`. PASS.
- [ ] **Step 3: Failing tests:** `pycache_corpus.py --point pycache-l2` gives, per turn, one first `py_requery`, 2–5 `py_requery` or `py_short`, and one `py_refit`. It has no `py_analyze`, `py_test`, `py_import` or `py_grep`, keeps `pycache`'s think-gap draw unscaled, and gets its own hash. `--durations-from` accepts exactly this point's classes. In `library.json`, `py_requery` and `py_refit` run `cd project && ../venv/bin/python l2q.py <query>`. `library-l2.json` runs `cd project && ../venv/bin/python l2c.py <query>` and has the same `py_short`.
- [ ] **Step 4:** Implement. PASS. Commit `feat(e17d): the pycache-l2 workload and corpus`.

### Task 4: The driver's process kinds and the restart rule

**Files:** `driver/exec.go`, `replay.go`; tests `driver/*_test.go`.

- [ ] **Step 1: Failing tests** (Go, against the driver's fake relay):
  - `execProcessStart` sends `EXEC_KIND_PROCESS_START` with command `../venv/bin/python l2srv.py` and `ProcessArgs{name: "l2srv", cwd: "/workspace/project"}`.
  - The restart rule, with `-l2-restart` only: a call whose client exits 3 starts the server once and re-runs the client with `--wait 60`.
  - The call records `restart: true`, its `restart_kind`, its observed time from the first send, and the start's own time (`start_ms`). `restart_kind` is `lease_cold` when the call's lease events show a new lease, else `server_lost`.
  - A second exit 3 after the start fails the call with `cause: "l2_server_unavailable"`.
  - Exits 0, 4 and 5 never start a server.
  - Without `-l2-restart`, the driver never sends a process kind.
- [ ] **Step 2:** Implement. PASS.
- [ ] **Step 3: Failing tests:** every lease event's `processes` and `tracked` reach `calls.jsonl` (`process_events`), and `lease-tail.jsonl` records each live lease's process table from `LeaseControl status`.
- [ ] **Step 4:** Implement. PASS. Commit `feat(driver): process kinds and the level-2 restart rule`.

### Task 5: The level-2 analysis

**Files:** `analysis/level2.py` (new), `latency_report.py`, `warmcold_lease.py`; tests `analysis/test_level2.py`.

- [ ] **Step 1: Failing tests:**
  - Warm means a live lease and no restart. `sbx` gives only its all-call median.
  - The warm-against-warm gain (`ship-300-l2` against `ship-300`) is a new field beside the existing gain against the baseline. Each gain carries its `n`.
  - Restarts are counted by kind, with their cost and the previous lease's end reason, and the lease-cold share is set beside the paired `ship-300` rung's cold share.
  - The level-2 charge is the `vm_fp` at +45 s.
  - Judged ends are ends with a running tracked process, minus `sandbox_deleted` and `teardown_failed` (they skip the sync by design) and minus the driver's end-of-run cut ends (E17B-R54). Each one gets its notices (exactly one is the pass), and whether a `vmpool: lease end sync workspace_key=` line exists for its key and end. The worker logs no sync duration at this pin, so none is computed.
  - Each `vmpool: memory-budget refusal` line in `worker.log` gives its `why`.
- [ ] **Step 2:** Implement. PASS. Commit `feat(e17d): level-2 readings`.

### Task 6: The verdict

**Files:** `analysis/verdict_e17d.py` (new); test `analysis/test_verdict_e17d.py`.

- [ ] **Step 1: Failing tests:** L2a–L2d read their thresholds and minimum warm counts from `predictions-e17d.json`, never from code. A warm set below its minimum makes the criterion `null` at that rung, with the reason, never a pass. So does a missing rung (not run). An N = 1 marked "reported, not gated" at the seal is left out of the verdict. Each criterion's evidence is listed by rung.
- [ ] **Step 2:** Implement. PASS. Commit `feat(e17d): verdict for L2a-L2d`.

### Task 7: The chain

**Files:** `rig/chain-e17d.sh` (new); test `rig/tests/chain-e17d.test.sh`.

- [ ] **Step 1: Failing tests:** `--list` prints exactly these stages, in this order. Every stage after `seal` refuses to start without a sealed `predictions-e17d.json`. `--from` and `--to` take these names, as in `chain-e17c.sh`.
  - before the seal: `smoke`, `socket-check`, `cal-pycache-l2-sbx`, `cal-pycache-l2-ship-300`, `cal-pycache-l2-ship-300-l2`, `memcheck-pycache-l2-ship-300-l2-n128`;
  - after it, N = 1: `lat-pycache-l2-sbx-n1`, `lat-pycache-l2-ship-300-n1`, `lat-pycache-l2-ship-300-l2-n1` (seeds from 11 until the warm minimum is met, at most 8);
  - N = 128: `lat-pycache-l2-sbx-n128`, `lat-pycache-l2-ship-300-n128`, `lat-pycache-l2-ship-300-l2-n128`;
  - the squeeze: `base-squeeze-l2-ship-300`, `base-squeeze-l2-ship-300-l2`, `squeeze-l2-ship-300`, `squeeze-l2-ship-300-l2` (last, so they can be cut);
  - `verdict`.
- [ ] **Step 2:** Implement. PASS. Commit `feat(e17d): chain-e17d.sh`.

### Task 8: Final review of the build

- [ ] Review the whole branch against spec §14 (`superpowers:requesting-code-review`), fix what it finds, and open the build PR as a draft. **Stop here for the user: the rig steps that follow need the rig started, and the user's go-ahead.**

### Task 9: Bring-up on the rig (user's go-ahead)

- [ ] Start the rig (`aws-rig start`, from a plain terminal). Set `E17D_MOCA_PIN` to `main` with #1026, check out and build at the pin. Build `e17d-<pin8>-1024` in a new leaf, with a fresh throwaway test egress CA (manifested). Check the gates CA's `notAfter` with `openssl x509 -enddate` before reusing it: the 2026-11-24 handoff notes, from the rig's own records, that it expired on 2026-11-22.
- [ ] `go test -run TestGateLease ./internal/vmpool/` at the pin, against that snapshot. Record pass/fail counts and the snapshot in the report. This run is also evidence for moca's security review §6.2 and §7.2, at this pin.
- [ ] The socket check (stage `socket-check`): a tracked `l2srv.py`, started with the Task 4 `process_start` (cwd `/workspace/project`, the venv), and an Exec's `l2c.py ping` talk over `/workspace/.l2/l2.sock`. Then stop the server and check that `l2c.py` exits 3 on the stale socket. Then the smoke for all three arms.

### Task 10: Calibration

- [ ] N = 1 probes, three arms, at `pycache-l2`: per-class medians, warm counts per seed, the duty, and the server's peak RSS. Then the N = 128 memory check at `ship-300-l2`: the per-lease charge and the committed total against the budget. If N = 128 does not fit, choose the largest N that does.
- [ ] Draft `predictions-e17d.json` with L2a–L2d's numbers, the minimum warm count, the N chosen, and whether N = 1 is gated (the warm minimum reachable within 8 seeds). Add a prediction per reported reading.

### Task 11: Seal (user)

- [ ] **The user reviews and seals `predictions-e17d.json`.** No measured rung runs before this. Later changes are deviations (`E17D-D<n>`), never edits.

### Task 12: The measured rungs

- [ ] `chain-e17d.sh --from lat-pycache-l2-n1 --to verdict`, logging to `/srv/e15/logs/e17d/`. `squeeze-l2` is last and may be cut (spec §14.6).

### Task 13: Report and data

- [ ] `results/E17D-REPORT.md`: each criterion judged as sealed, the reported readings, the deviations. Publish the raw rungs as the next `data-v*` release (`data/MANIFEST.md`), and open the report PR.
- [ ] Bring the user the moca follow-ups the report finds, and ask whether the rig stops.
