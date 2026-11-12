# E15 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and run E15's instrument — corpus extractor, command library, replay driver, resident-arm patch, rig scripts — and produce the preliminary `N_max` per arm on the AWS rig.

**Architecture:** A Python extractor turns TraceLab v0.0.2 into a per-session replay corpus. A standalone Go driver replays `N` sessions against `sandbox/v1` over one gRPC connection, closed-loop per session. Two worker builds of moca v0.9.0 — stock and a rig-only resident patch — run behind one sandbox-relay; a bash orchestrator runs rungs, samples the host at 1 Hz and writes one JSON record per rung.

**Tech Stack:** Python 3.9+ with DuckDB (extractor, analysis); Go 1.26 (driver, patch; toolchain auto-downloaded); bash (rig scripts, shellcheck-clean); moca v0.9.0 (`c13d5564`) relay and worker; Firecracker v1.17.0.

**Spec:** [`SPEC.md`](SPEC.md) (v0.3). Read it first; this plan argues from it and does not restate its reasons.

## Global Constraints

- Everything lives under `experiments/e15-session-density/` in moca-experiments. **Nothing is added to the moca repo.**
- moca components pinned to tag `v0.9.0` = `c13d5564`.
- Corpus source: TraceLab `v0.0.2`, `syfi_coding_trace.duckdb`, SHA-256 `a7bab286bc640844560850965ccf47975cf66407154132abaab90f27ec9be744`. Refuse any other.
- Replayed tools: `exec_command`, `Bash`, `write_stdin`, `shell_command`, `shell`, `Read`, `Write`, `Edit`, `apply_patch`, `Grep`, `Glob`, `LS`, `NotebookEdit`, `multiedit`.
- Session floor: ≥ 20 replayed calls (after chain collapsing).
- Duration caps: Codex non-chain 120 s; Claude 30 s; chain lifetime 7200 s.
- Default `H` = 1800 s; points 300 s and 7200 s.
- Per-user share of a population ≤ 15%.
- Guest RAM 1024 MiB; standby depth SBX 2, resident 0; `WORKER_MAX_CONCURRENT=256`; `SH_MAX_RUNS=512`; `SH_MAX_COMMITTED_MB=1048576`; `SH_HOST_MEM_FLOOR_MB=1536`; `SH_WORKSPACE_IMAGE_MB=256`.
- Ladder `1 8 16 24 32 40 48 56 64 80 96 128`; warm-up 600 s; window 900 s.
- "Holds N": no failed call; no refusal; median pace ≤ 10%; p95 added latency ≤ 2× the arm's own `N=1` p95.
- Rig: never touch `/opt/serverless-harness`, ports 8080/8081/8090/8787, or `sh-*` units; every change logged in `~/e15-manifest.md` with its undo; E15 binds only 127.0.0.1 (attach 9643, exec 9644, Redis 6400); all files under `/srv/e15/`.
- Commits: `git commit -s`, trailer `Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>`. Never `Co-Authored-By`.
- Go tests on the laptop under nono: `GOPATH=/tmp/kagenti/gopath GOMODCACHE=/tmp/kagenti/gomodcache GOCACHE=/tmp/kagenti/gocache`.

## Review Focus

1. **A session joining mid-trace at a chain's middle or at its last call** — the driver must start at a call boundary and still have ≥ 3 calls left in the window, or skip to the next session; never send a negative sleep.
2. **Exit codes from the command library** — a replayed command that legitimately exits non-zero (`grep` with no match, `git diff --exit-code`) must be declared in the library with its expected code, or §8.1 fails a healthy rung.
3. **Relay restart or a worker detaching mid-rung** — `no live worker` must classify as a failed call (§8.1), not a driver crash, and the rung record must say so.
4. **Clock jumps on the rig** — the driver times with a monotonic clock; wall time only labels records.
5. **The resident VM reaching `T_idle` while a command is queued on its gate** — destroy only when the gate is free and `lastExec` is older than `T_idle`; a queued command must get the live VM or a fresh one, never a destroyed one.

Each line's test is in the owning task: (1) Task 4, (2) Task 2, (3) Task 4, (4) Task 4, (5) Task 5.

---

## File Structure

```
experiments/e15-session-density/
├── SPEC.md                      # the design (exists)
├── PLAN.md                      # this plan
├── README.md                    # what E15 is, reading order (Task 9)
├── predictions.json             # sealed after calibration (Task 8)
├── RUNBOOK.md                   # step-by-step replication (Task 9)
├── EXPERIMENTS.md               # the record (Task 9)
├── RESULTS-SUMMARY.md           # the short version (Task 9)
├── extract/
│   ├── extract.py               # DuckDB → corpus.jsonl + corpus-report.json
│   ├── classes.py               # executable → class mapping (§5.6)
│   └── test_extract.py          # pytest, against a tiny fixture DuckDB
├── commands/
│   ├── library.json             # class → invocations, expected exit codes, measured run times
│   ├── project.lock             # chosen OSS project: repo URL, commit, licence
│   ├── scripts/                 # generated interpreter scripts of graded run time
│   └── build_workspace.sh       # builds the seeded workspace.img template
├── driver/
│   ├── go.mod                   # module experiments/e15-session-density/driver; requires github.com/rossoctl/moca/gen/go v0.9.0
│   ├── main.go                  # flags, wiring
│   ├── corpus.go                # load corpus + library, seeded sampling, user cap
│   ├── replay.go                # per-session closed loop
│   ├── exec.go                  # one Exec over the shared ClientConn
│   ├── record.go                # per-call / per-session JSON lines, self CPU sampler
│   └── *_test.go
├── resident/
│   ├── resident.patch           # against remote-worker at v0.9.0
│   ├── resident_test.go         # applied with the patch into internal/vmpool
│   └── apply.sh                 # checkout v0.9.0, apply, build, run tests
├── rig/
│   ├── lib.sh                   # manifest logging, port checks, rig-rule guards
│   ├── setup.sh                 # stop shared units, build stack, snapshot, workspace image
│   ├── teardown.sh              # undo setup from the manifest
│   ├── rung.sh                  # one rung: start worker, warm up, measure, record
│   ├── ladder.sh                # a point's ladder, stopping at first failure
│   ├── sample.sh                # 1 Hz host + slice sampler
│   └── tests/*.test.sh          # cluster-free structural tests (repo convention)
└── analysis/
    ├── holds.py                 # §8 test over a rung's call/session lines
    ├── record.py                # one rung record (§9.3)
    └── test_holds.py
```

Files that change together live together: the extractor and its class map; the driver's loop and its recording; the patch and its tests.

---

### Task 1: Corpus extractor

**Files:**
- Create: `experiments/e15-session-density/extract/classes.py`, `experiments/e15-session-density/extract/extract.py`, `experiments/e15-session-density/extract/test_extract.py`, `experiments/e15-session-density/extract/conftest.py` (builds the fixture DuckDB in `tmp_path`)

**Interfaces:**
- Produces: `corpus.jsonl`, one session per line:
  `{"session": str, "user": str, "provider": "claude"|"codex", "calls": [Call]}` where
  `Call = {"i": int, "class": str, "skeleton": str, "dur_ms": int, "work_ms": int, "gap_ms": int, "offset_ms": int, "out_bytes": int, "chain": bool}`.
  `offset_ms` is the emit offset from the previous call's emit (the ordering rule, §5.4); `gap_ms` is end-to-next-emit capped at `H`.
- Produces: `corpus-report.json` with keys `sessions`, `by_provider`, `chains_collapsed`, `chains_capped`, `dur_capped{claude,codex}`, `gap_capped`, `errored`, `dropped_lt20`, `infra_calls`, `infra_sessions`, `opaque_calls`, `table{occupied_pct,work_pct,calls_per_s,held_t300_pct,wakes_per_session_h,mean_span_min}`, `duckdb_sha256`, `H_s`.
- Produces: `classes.classify(tool_name: str, executables: list[str]) -> str` returning one of `read write search test interpreter build lint_check vcs shell_read file_ops wait process host_infra network opaque unparsed other`.
- CLI: `python3 extract.py --db PATH --H 1800 --out DIR [--exclude infra|chains]`.

- [ ] **Step 1: Write failing tests** in `test_extract.py`:
  - `test_refuses_wrong_sha` — a DB whose SHA-256 ≠ the pinned value → `SystemExit` with message containing `sha256`. (Tests pass `--skip-sha-check` only for the fixture; the flag is refused when `--db` basename is `syfi_coding_trace.duckdb`.)
  - `test_classify_skips_plumbing` — `classify("Bash", ["cd","echo","pytest"]) == "test"`; `classify("exec_command", ["custom_7"]) == "opaque"`; `classify("Read", []) == "read"`; `classify("Bash", []) == "unparsed"`.
  - `test_chain_collapses` — fixture: one `exec_command` (internal 2,000 ms) + two `write_stdin` polls linked by `continuation_of_tool_call_id` (internal 500 ms each, last result 60 s after emit) → one `Call` with `chain=True`, `dur_ms=60000`, `work_ms=3000`.
  - `test_chain_cap` — same chain spanning 3 days → `dur_ms=7200000`, counted in `chains_capped`.
  - `test_caps_by_provider` — Claude `Bash` wall 90 s → `dur_ms=30000`; Codex `exec_command` internal 200 s → `120000`.
  - `test_gap_cap_and_offsets` — two calls 5 h apart, `H=1800` → `gap_ms=1800000`, and `offset_ms` of the second = first's `dur_ms + 1800000`.
  - `test_session_floor` — a 19-call session is dropped and counted in `dropped_lt20`.
  - `test_exclude_infra` — `--exclude infra` drops any session with a `host_infra` call.
- [ ] **Step 2: Run** `cd experiments/e15-session-density/extract && PYTHONPATH=/tmp/kagenti/pylibs python3 -m pytest -q` → all FAIL (module not found).
- [ ] **Step 3: Implement** `classes.py` (the §5.6 table, plumbing set from SPEC §5.6) and `extract.py` (one DuckDB query per stage, mirroring the queries that produced SPEC §5.4's table; chain = `exec_command` whose `tool_call_id` is the `continuation_of_tool_call_id` of ≥ 1 `write_stdin`; continuation `write_stdin` rows are removed as calls).
- [ ] **Step 4: Run** tests → PASS.
- [ ] **Step 5: Verify against the real DB:** `python3 extract.py --db /tmp/kagenti/tracelab/trace/v0.0.2/syfi_coding_trace.duckdb --H 1800 --out /tmp/kagenti/e15work/corpus` → `corpus-report.json` has `sessions` within ±1% of 4,210 and `table` matching SPEC §5.4's default row (18.8 / 7.2 / 0.0152 / 61 / 2.1 / 142) to the printed precision. A mismatch is a bug in the extractor or in the spec; resolve it before moving on and note which.
- [ ] **Step 6: Commit** `feat(e15): corpus extractor for TraceLab v0.0.2`.

### Task 2: Command library and workspace template

**Files:**
- Create: `experiments/e15-session-density/commands/library.json`, `experiments/e15-session-density/commands/project.lock`, `experiments/e15-session-density/commands/scripts/gen_scripts.py`, `experiments/e15-session-density/commands/build_workspace.sh`, `experiments/e15-session-density/commands/test_library.py`

**Interfaces:**
- Produces: `library.json`:
  `{"version": 1, "classes": {CLASS: [{"id": str, "cmd": str, "exit": int, "run_ms": int|null, "cpu_ms": int|null}]}, "standin": {"interpreter_id": str, "infra_sleep_frac": 0.5}}`.
  `run_ms`/`cpu_ms` are `null` until calibration (Task 8) fills them. Every class in `classes.classify`'s range except `opaque`, `build`, `host_infra` (which use the stand-in) has ≥ 3 invocations spanning ≥ 10× in expected run time.
- Produces: `build_workspace.sh OUT_IMG` — builds an ext4 `workspace.img` of 256 MiB (sparse) holding `/project` (the locked repo at its commit, with `.git`) and `/scripts` (generated scripts). Workspace root inside the guest is `/workspace`, so commands run in `/workspace/project`.

- [ ] **Step 1: Choose the project** and write `project.lock` (`url`, `commit`, `licence`, `test_cmd`, `test_count`, `size_mib`). Constraints from SPEC §5.6: pure Python, tests runnable with only `python3 -m pytest` and the stdlib plus the project itself, ≤ 60 MiB with history, ≥ 200 tests, permissive licence. Our call recorded in the lock's `why` field.
- [ ] **Step 2: Write failing tests** in `test_library.py`:
  - `test_every_class_covered` — every class returned by `classify` maps to library invocations or the stand-in.
  - `test_expected_exit_declared` — every invocation has an integer `exit`; at least one `shell_read` invocation declares `exit: 1` (grep with no match).
  - `test_commands_relative` — every `cmd` runs relative to `/workspace/project` and never references `..` or absolute paths outside `/workspace`.
  - `test_spread` — per class, max expected time ÷ min ≥ 10 (expected times come from a `nominal_ms` field the author fills; calibration replaces them).
- [ ] **Step 3: Run** → FAIL.
- [ ] **Step 4: Write** `library.json` and `gen_scripts.py` (scripts `burn_<ms>.py` for 50, 200, 1000, 5000, 20000 ms that spin a CPU loop and touch 32 MiB of heap; the interpreter stand-in picks among them).
- [ ] **Step 5: Run** → PASS. Then `bash -n build_workspace.sh && shellcheck build_workspace.sh` → clean.
- [ ] **Step 6: Commit** `feat(e15): command library and workspace template`.

### Task 3: Replay driver — corpus loading and sampling

**Files:**
- Create: `experiments/e15-session-density/driver/go.mod`, `experiments/e15-session-density/driver/corpus.go`, `experiments/e15-session-density/driver/corpus_test.go`, `experiments/e15-session-density/driver/testdata/corpus-small.jsonl`, `experiments/e15-session-density/driver/testdata/library.json`

**Interfaces:**
- Consumes: Task 1's `corpus.jsonl` schema; Task 2's `library.json` schema.
- Produces:
  ```go
  type Call struct { I int; Class, Skeleton string; DurMs, WorkMs, GapMs, OffsetMs, OutBytes int64; Chain bool }
  type Session struct { ID, User, Provider string; Calls []Call }
  type Library struct { /* parsed library.json */ }
  func LoadCorpus(path string) ([]Session, error)
  func LoadLibrary(path string) (*Library, error)
  // Sampler draws sessions without replacement (reshuffling on exhaustion), seeded,
  // enforcing userCap (fraction of the live population one user may hold).
  type Sampler struct{ /* … */ }
  func NewSampler(sessions []Session, seed int64, userCap float64) *Sampler
  func (s *Sampler) Next(live map[string]int, n int) (Session, int /*startIndex*/)
  // Plan expands one call into the commands to send, from the library, deterministically.
  func (l *Library) Plan(c Call, seed int64, sessionID string) []Planned
  type Planned struct { Cmd string; Exit int32; SleepAfterMs int64 } // SleepAfterMs: chain idle tail
  ```
  `go.mod`: `module github.com/rossoctl/moca-experiments/e15/driver`, `go 1.26.0`, `require github.com/rossoctl/moca/gen/go v0.0.0-20261028…` resolved by `go get github.com/rossoctl/moca/gen/go@v0.9.0`.

- [ ] **Step 1: Write failing tests:**
  - `TestSamplerDeterministic` — two samplers with seed 7 return the same 50 `(id, start)` pairs.
  - `TestSamplerUserCap` — corpus where user `u1` owns 60% of sessions, `n=20`, `userCap=0.15` → `u1` never exceeds 3 in `live`.
  - `TestStartIndexLeavesThreeCalls` — start index is always ≤ `len(Calls)-3` (Review Focus 1).
  - `TestPlanMatchesWork` — a `test` call with `WorkMs=12000` against a library with runs 1,000/5,000/20,000 → planned commands' summed `run_ms` ≤ 12,000 and ≥ 11,950 (repeat-until-remainder-<50 ms rule), all from class `test`.
  - `TestPlanShorterThanShortest` — `WorkMs=10` → exactly one invocation (the shortest).
  - `TestPlanChainIdleTail` — chain with `DurMs=60000, WorkMs=3000` → last `Planned.SleepAfterMs ≈ 57000`.
  - `TestPlanStandIn` — `host_infra`, `WorkMs=4000` → one `sleep 2` and interpreter invocations summing to ~2,000 ms (`infra_sleep_frac=0.5`).
  - `TestPlanDeterministic` — same `(seed, session, call)` → identical `[]Planned`.
- [ ] **Step 2: Run** `cd experiments/e15-session-density/driver && go test ./...` (env from Global Constraints) → FAIL.
- [ ] **Step 3: Implement** `corpus.go`. Seed per call = FNV-64 of `seed‖sessionID‖I`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(e15): driver corpus loading, sampling and command planning`.

### Task 4: Replay driver — closed loop, Exec, records

**Files:**
- Create: `experiments/e15-session-density/driver/exec.go`, `experiments/e15-session-density/driver/replay.go`, `experiments/e15-session-density/driver/record.go`, `experiments/e15-session-density/driver/main.go`, `experiments/e15-session-density/driver/replay_test.go`

**Interfaces:**
- Consumes: Task 3's types; `pb "github.com/rossoctl/moca/gen/go/sandbox/v1"`.
- Produces: binary `e15-driver` with flags `--corpus --library --seed --n --warmup-s 600 --window-s 900 --target 127.0.0.1:9644 --sandbox-id e15 --run-id --out DIR`; reads `MOCA_RELAY_EXEC_TOKEN` from env (refuses empty, as `exec-driver` does).
- Produces: `DIR/calls.jsonl` lines `{"ts","session","call","class","planned_dur_ms","planned_gap_ms","observed_ms","status":"ok"|"err","cause","exit","expected_exit","in_window"}`; `DIR/sessions.jsonl` lines `{"session","window_calls","planned_ms","observed_ms"}` covering only calls inside the window; `DIR/driver-cpu.jsonl` 1 Hz `{"t","utime_ms","stime_ms"}`.
- Wire rules: one `grpc.ClientConn` dialed READY before any session starts (copy `dialReady` from `remote-worker/cmd/exec-driver/drive.go` with attribution); `authorization: Bearer <token>` metadata; `ExecRequest{SandboxId, Exec{ReqId, Command, TimeoutS, WorkspaceKey}}`; drain stream to `io.EOF`; an in-stream `ExecEvent.error` is a failed call; `End.exit_code` ≠ `expected_exit` is a failed call. `workspace_key = "e15-" + runID + "-" + slot + "-" + seq`. `TimeoutS = ceil(planned_dur_ms/1000) + 120`.
- Timing: monotonic `time.Now()` deltas only (Review Focus 4). Sleep before each call = `max(0, offset_ms − elapsed_since_previous_emit)`; never negative.

- [ ] **Step 1: Write failing tests** with an in-process fake `SandboxExecServer` (bufconn):
  - `TestClosedLoopWaitsForResult` — fake holds each Exec 200 ms; a 3-call session with `offset_ms` 50 → calls are sequential and session observed ≥ 600 ms.
  - `TestPopulationHeldAtN` — `n=4`, sessions of 3 calls → at every recorded instant after start-up, 4 sessions are live.
  - `TestStartupSpread` — `n=10` → first-call emits span ≥ 0.9 × 60 s of the configured spread (test uses a 1 s spread).
  - `TestInStreamErrorIsFailure` — fake sends `ExecEvent{error}` then OK → `status:"err"`.
  - `TestExitMismatchIsFailure` — fake returns `End{exit_code:1}` for an invocation expecting 0 → `status:"err"`, `cause:"exit_mismatch"`; expecting 1 → `ok`.
  - `TestNoLiveWorkerIsRecordedNotFatal` — fake returns `Unavailable: no live worker for sandbox 'e15'` → recorded `status:"err", cause:"no_live_worker"`, driver keeps running (Review Focus 3).
  - `TestWindowFlag` — calls emitted during warm-up have `in_window:false`.
  - `TestNoNegativeSleep` — a call whose `offset_ms` is smaller than the previous call's observed duration is sent immediately.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** `exec.go`, `replay.go`, `record.go`, `main.go`. Buffered writers flushed at end of run (exec-driver's rationale).
- [ ] **Step 4: Run** `go test ./... -race` → PASS.
- [ ] **Step 5: Local control check:** build `remote-worker/cmd/null-responder` at v0.9.0 from `<moca-checkout>` (read-only checkout, build into `/tmp`), run it, run `e15-driver --n 128 --warmup-s 10 --window-s 30` against it. Expected: zero failures, and `driver-cpu.jsonl` shows < 1% of one core averaged over the window. (A2 on the laptop; re-checked on the rig in Task 8.)
- [ ] **Step 6: Commit** `feat(e15): replay driver closed loop and records`.

### Task 5: Resident-arm patch

**Files:**
- Create: `experiments/e15-session-density/resident/resident.patch`, `experiments/e15-session-density/resident/resident_test.go`, `experiments/e15-session-density/resident/apply.sh`

**Interfaces:**
- Consumes: `remote-worker/internal/vmpool` at v0.9.0 — `pool.ExecPhased` (`pool.go:245`), `pool.acquire` (`pool.go:392`), `pool.destroy` (`pool.go:541`), `runPool` (`runpool.go`: `ready`, `inFlight`, `lastExec`, `execGate`), `sweepOnce` (`sweep.go:30`), `firecrackerVM.Run` (dials a fresh vsock connection per call, `launcher_firecracker.go:1095`).
- Produces: a worker build that honours `E15_RESIDENT=1` and `E15_RESIDENT_IDLE_S` (`0` = ∞). With `E15_RESIDENT` unset the patched binary behaves exactly as stock (its own test proves it).

Patch shape (decided here; the implementer writes the code):
- `runPool` gains `resident VM` (the kept VM, nil when none).
- In `ExecPhased`: if resident mode and `rp.resident != nil`, skip `acquire` and `Resume` — take the gate, run on `rp.resident`, release the gate, **do not destroy**. If `rp.resident == nil`, acquire and resume as today, run, then store it as `rp.resident` instead of destroying.
- A run's guest shell killed by a timeout (`Run` returns the agent's "agent is dead" error or the VM reports dead) → destroy and clear `rp.resident`; the next command acquires fresh.
- `sweepOnce`: in resident mode, when `E15_RESIDENT_IDLE_S > 0`, destroy `rp.resident` where `now − lastExec ≥ idle` **and** the gate is free (non-blocking send on `execGate` succeeds; release immediately after clearing) — Review Focus 5.
- The memory budget is charged at acquire as today and released at the resident VM's destroy (move the `inFlight--`/release from per-Exec to resident-VM destroy).
- `TestGateNoVMReuse` stays as is in the tree and **is expected to fail with `E15_RESIDENT=1`** and pass without it; `apply.sh` runs it both ways and asserts exactly that.

- [ ] **Step 1: Write failing tests** in `resident_test.go` (package `vmpool`, using the in-tree fake launcher `testlauncher.go`):
  - `TestResidentReusesVM` — three Execs for key `k` → one `Restore`, zero `Destroy` until idle.
  - `TestResidentSerialisesOneKey` — two concurrent Execs for `k` → they do not overlap (second starts after first ends).
  - `TestResidentIdleDestroy` — idle 300 s, fake clock advanced 301 s, sweep → one `Destroy`; next Exec → a new `Restore`.
  - `TestResidentIdleRespectsGate` — gate held by an in-flight Exec at 301 s → sweep does not destroy; after the Exec ends and 301 s more → destroyed.
  - `TestResidentInfiniteNeverIdles` — idle `0`, clock +10 h → no `Destroy`.
  - `TestResidentRetiresDeadAgent` — fake VM returns the dead-agent error → destroyed, next Exec restores fresh.
  - `TestStockUnchanged` — `E15_RESIDENT` unset → every Exec restores and destroys (one each).
  - `TestResidentBudgetReleasedAtDestroy` — committed bytes stay at one PerVM across three Execs, return to zero after idle destroy.
- [ ] **Step 2: Write `apply.sh`:** clone moca at `v0.9.0` into `$WORK/moca` (or reuse), `git apply resident.patch`, copy `resident_test.go` into `remote-worker/internal/vmpool/`, run `go test ./internal/vmpool/ -run 'Resident|StockUnchanged'`, run `TestGateNoVMReuse` with and without `E15_RESIDENT=1` and assert fail/pass respectively, then `go build -o $OUT/microvm-worker-resident ./cmd/microvm-worker`. Refuses if `git -C $WORK/moca rev-parse HEAD` ≠ `c13d5564…`.
- [ ] **Step 3: Run** `apply.sh` locally with an empty patch → resident tests FAIL.
- [ ] **Step 4: Write the patch** (edit a scratch v0.9.0 checkout, `git diff > resident.patch`).
- [ ] **Step 5: Run** `apply.sh` → all resident tests PASS; full `go test ./internal/vmpool/` passes except `TestGateNoVMReuse` under `E15_RESIDENT=1`, as asserted; worker binary built. (KVM gates are skipped on the laptop; they run on the rig in Task 7.)
- [ ] **Step 6: Commit** `feat(e15): rig-only resident-VM patch for the vmpool baseline arm`.

### Task 6: Rung analysis (the "holds N" test)

**Files:**
- Create: `experiments/e15-session-density/analysis/holds.py`, `experiments/e15-session-density/analysis/record.py`, `experiments/e15-session-density/analysis/test_holds.py`

**Interfaces:**
- Consumes: Task 4's `calls.jsonl` and `sessions.jsonl`; Task 7's `samples.jsonl` and `worker.log`.
- Produces: `holds.evaluate(calls, sessions, baseline_p95_ms: float) -> dict` with keys `holds: bool`, `failed_calls`, `refusals`, `median_pace`, `p95_added_ms`, `p95_limit_ms`, `sessions_excluded_lt3`; `record.build(rung_dir, params) -> dict` writing `record.json` per SPEC §9.3, including `binding` ∈ `memory_floor | cpu | disk_io | disk | gate | memory_high | none`.
- Refusal detection in `worker.log`: lines matching `memory-budget|host-floor|busy|queue full|RESOURCE_EXHAUSTED|oom`.

- [ ] **Step 1: Write failing tests:**
  - `test_holds_all_green` — synthetic window: 0 failures, pace median 5%, p95 added 150 ms vs baseline 100 → `holds=True`.
  - `test_fails_on_one_failed_call` — one `status:"err"` → `holds=False`.
  - `test_fails_on_refusal_line` — a `host-floor` line in `worker.log` → `holds=False`, `refusals=1`.
  - `test_pace_boundary` — median pace exactly 0.10 → holds; 0.1001 → fails.
  - `test_p95_boundary` — p95 added exactly 2× baseline → holds; above → fails.
  - `test_excludes_short_sessions` — sessions with < 3 window calls excluded from pace and counted.
  - `test_binding_memory` — `MemAvailable` reaches the floor in samples → `binding="memory_floor"`.
  - `test_binding_cpu` — host CPU ≥ 90% busy for the last 60 s of samples → `binding="cpu"`.
  - `test_footprint_drift` — resident arm, median VM `memory.current` 400 MiB at window start and 450 MiB at end → `footprint_drift_pct=12.5`, `repeat_required=True` (SPEC §5.7); SBX arm → field absent.
- [ ] **Step 2: Run** `python3 -m pytest -q experiments/e15-session-density/analysis` → FAIL.
- [ ] **Step 3: Implement.** Added latency = `observed_ms − planned_dur_ms`; pace per SPEC §8.3.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(e15): holds-N evaluation and rung records`.

### Task 7: Rig scripts

**Files:**
- Create: `experiments/e15-session-density/rig/lib.sh`, `experiments/e15-session-density/rig/setup.sh`, `experiments/e15-session-density/rig/teardown.sh`, `experiments/e15-session-density/rig/rung.sh`, `experiments/e15-session-density/rig/ladder.sh`, `experiments/e15-session-density/rig/sample.sh`, `experiments/e15-session-density/rig/tests/rig.test.sh`

**Interfaces:**
- Consumes: Tasks 1–6 artifacts, copied to the rig under `/srv/e15/`.
- Produces: `setup.sh` — logs every step to `~/e15-manifest.md` with its undo; stops `microvm-worker.service` and the `bench-redis`/`bench-cp` containers; clones moca `v0.9.0` to `/srv/e15/moca`, `pnpm install --frozen-lockfile`; builds stock `microvm-worker` and (via `resident/apply.sh`) the resident build; builds the rootfs from the rig's `default` snapshot's rootfs plus `pytest` (pip into the tree), then `deploy/microvm/build-snapshot.sh --guest-ram-mb 1024 --out /srv/e15/snapshots/e15`; builds `workspace.img` with `commands/build_workspace.sh`; starts Redis on 6400 (podman, `--save ''`).
- Produces: `rung.sh ARM N POINT` — resets `/srv/e15/workspaces` from the template (one hard copy per planned session key, created lazily by the driver's key scheme; or a `cp --sparse=always` per key on first use — implementer's choice, recorded), starts relay (attach 9643, exec 9644, Redis 6400, `SH_RELAY_TOKEN`/`MOCA_RELAY_EXEC_TOKEN` from `/srv/e15/secrets`) and the arm's worker in `e15.slice` with SPEC §7 env, starts `sample.sh`, runs `e15-driver`, stops all, runs `analysis/record.py`. `ARM` ∈ `sbx | resident-inf | resident-300 | control`.
- Produces: `ladder.sh POINT ARM [START_N]` — runs `rung.sh` up the ladder until `record.json.holds=false`; a rung with `repeat_required=true` is re-run once with warm-up doubled before it counts; writes `ladder.json` with `N_max`.
- Guards in `lib.sh`, each a function that exits non-zero: `refuse_shared_paths` (any write under `/opt/serverless-harness`), `refuse_ports` (anything already on 9643/9644/6400), `refuse_units` (any `systemctl` on `sh-*`).

- [ ] **Step 1: Write failing structural tests** in `rig.test.sh` (repo convention: cluster-free, run with `bash`): each script passes `bash -n` and `shellcheck`; `lib.sh`'s three guards refuse their cases (stub `systemctl`/`ss` on `PATH`); `rung.sh` refuses an unknown `ARM`; `teardown.sh` replays undo lines from a fixture manifest in reverse order.
- [ ] **Step 2: Run** `bash experiments/e15-session-density/rig/tests/rig.test.sh` → FAIL.
- [ ] **Step 3: Implement** the scripts.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Rig bring-up:** copy `experiments/e15-session-density/` to the rig, run `setup.sh`. Expected: manifest written; relay up on 127.0.0.1:9643/9644; the resident build's KVM gates run on the rig with `SH_KVM=1` (`go test ./internal/vmpool/ -run 'Gate'` with and without `E15_RESIDENT`, as in Task 5); a 1-session smoke with each arm completes 20 calls with zero failures.
- [ ] **Step 6: Run** `teardown.sh`, then `setup.sh` again. Expected: teardown restores `microvm-worker.service` active and the bench containers running; second setup is idempotent.
- [ ] **Step 7: Commit** `feat(e15): rig setup, rung and ladder scripts`.

### Task 8: Calibration and sealed predictions

**Files:**
- Modify: `experiments/e15-session-density/commands/library.json` (fill `run_ms`, `cpu_ms`)
- Create: `experiments/e15-session-density/predictions.json`, `experiments/e15-session-density/results/calibration/` (raw outputs)

- [ ] **Step 1: Measure the library** on the rig (SPEC §10.1 step 2): every invocation 5× inside one VM; write medians into `library.json`. Expected: every class keeps ≥ 3 invocations with distinct `run_ms`; re-run Task 2's `test_spread` against measured values → PASS.
- [ ] **Step 2: `N=1` baselines** (SPEC §10.1 step 3): `rung.sh sbx 1 default`, `rung.sh resident-inf 1 default`, `rung.sh resident-300 1 default`. Record each arm's `p95_added_ms` — these are the §8.4 baselines.
- [ ] **Step 3: Control** (step 4): `rung.sh control 128 default`. Expected: driver CPU < 1% of host CPU over the window. If not, stop: the driver must be fixed before any measured rung (A2).
- [ ] **Step 4: Measure the two numbers the predictions need:** mean CPU-seconds per replayed call (SBX `N=8` rung's slice CPU ÷ calls), and resident VM grown footprint (median VM cgroup `memory.current` at the end of a resident-inf `N=8` window).
- [ ] **Step 5: Write `predictions.json`** in `experiments/e10-e13-microvm/predictions.json`'s format: SPEC §11's six predictions with numeric `N_max` ranges computed from Step 4, each with `metric` and `falsifiedBy`; `recordedAt`, `spec: "experiments/e15-session-density/SPEC.md v0.3"`, and the calibration inputs.
- [ ] **Step 6: Commit and seal** `docs(e15): sealed predictions from calibration` — committed before Task 9's first measured rung.

### Task 9: Measured runs and the record

**Files:**
- Create: `experiments/e15-session-density/results/<point>/<arm>/<N>/` (raw), `experiments/e15-session-density/EXPERIMENTS.md`, `experiments/e15-session-density/RESULTS-SUMMARY.md`, `experiments/e15-session-density/RUNBOOK.md`, `experiments/e15-session-density/README.md`
- Modify: moca-experiments `README.md` (add `experiments/e15-session-density/` to Layout)

- [ ] **Step 1: Default point:** `ladder.sh default sbx`, `ladder.sh default resident-inf`, `ladder.sh default resident-300`. Expected: each writes `ladder.json` with `N_max` and its `binding`. Note any rung repeated under the shared-host rule (SPEC §12).
- [ ] **Step 2: Sensitivity points** (SPEC §10.3), each starting two ladder steps below that arm's default `N_max`.
- [ ] **Step 3: Write `EXPERIMENTS.md`:** setup as run, every prediction against its outcome, every transformation count from `corpus-report.json`, per-provider and per-class splits, anything retried or excluded.
- [ ] **Step 4: Write `RESULTS-SUMMARY.md`** (headline: `N_max` per arm "on a 4-vCPU nested Nitro instance", binding resource, prediction verdicts), `RUNBOOK.md`, `README.md`; add `experiments/e15-session-density/` to the repo `README.md` Layout list after `experiments/e14-sbx/`.
- [ ] **Step 5: Run `teardown.sh`** on the rig. Expected: manifest's undo lines all succeed; `microvm-worker.service` active; `/srv/e15` removed.
- [ ] **Step 6: Commit** `docs(e15): preliminary results on the AWS rig`.

---

## Self-review

- **Spec coverage:** §5.1–5.5 → Task 1; §5.6 → Tasks 2–3; §5.7 → Task 3 (start index, user cap) and Task 6 (`footprint_drift_pct`); §5.8 → Task 3; §6.1–6.6 → Tasks 1–5, 7; §7 → Task 7's env; §8 → Task 6; §9 → Tasks 6–7; §10.1 → Task 8; §10.2–10.3 → Tasks 7, 9; §11 → Task 8; §12 shared-host repeat → Task 9 Step 1; rig rules (§4) → Task 7 guards.
- **Types:** `Call`/`Session`/`Planned` defined in Task 3, used in Task 4; `calls.jsonl` fields defined in Task 4, consumed in Task 6; `library.json` schema defined in Task 2, consumed in Task 3, filled in Task 8.
- **Gap fixed inline:** the §5.7 warm-up footprint check lives in Task 6's `record.build` (`footprint_drift_pct`; > 10% sets `repeat_required`, test `test_footprint_drift`), and Task 7's `ladder.sh` repeats such a rung once with warm-up doubled.
