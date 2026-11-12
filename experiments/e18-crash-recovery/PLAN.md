# E18 Crash Recovery Latency Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Measure the extra wait a user sees when a moca worker or the supervisor is killed, on the Docker Compose trial, with a stubbed model, and express it against a real-model median turn.

**Architecture:** A zero-dependency Node ESM directory `experiments/e18-crash-recovery/`: a pure stats module, an Anthropic-API stub server, a compose override that points the supervisor at the stub, a driver that plays a user and injects kills, a real-model baseline script, and a report generator. Everything pure is unit-tested with `node --test`; the compose-dependent parts are verified by a live run.

**Tech Stack:** Node 22+ (ESM, built-in `node:test`, global `fetch`), Docker Compose, bash for the compose wrapper. No npm dependencies.

**Spec:** `SPEC.md`.

## Global Constraints

- Four cases: `W-I`, `W-M`, `S-I`, `S-M` (worker or supervisor killed; idle or mid-turn). About 10 runs each, each on a fresh session.
- Worker kill is `SIGKILL` of a pid taken from the supervisor's `/metrics` (`workers[].pid`, `inFlight`); supervisor kill is `docker kill` of the supervisor container.
- The admin `/metrics` listener (`SH_ADMIN_PORT` 8081) is not published; reach it with `docker compose exec supervisor`.
- Stub reply delay D = 200 ms; stub is reached through `ANTHROPIC_BASE_URL`; turns use a prompt that needs no tool call.
- Client retries the same turn every 200 ms for up to 120 s; a run with no success by 120 s is censored, counted, and counted as 120 s in the median and p95.
- `t_recover_user` is `t_recover` rounded up to the next 3 s tick after the first error, computed from the same runs.
- `context_ok` is read from the session history in Redis, not from the model's answer.
- Mid-turn kill lands at a random fraction f of the stub turn; real-model `elapsed_at_kill` is f × T.
- Real-model baseline: about 20 uncrashed turns, median T and p95, a `uname -a`-style prompt.
- Time is taken with `performance.now()` in the one driver process (monotonic; no cross-host clocks).
- No change to moca code, deploy files or the compose file; the stub and override live in `experiments/e18-crash-recovery/`.
- Commits use `git commit -s` and the trailer `Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>`; never `Co-Authored-By`.

## Review Focus

- A kill-between-runs backoff leak: worker restart backoff doubles per consecutive crash, so a run started before the pool is healthy again inherits a longer delay. Expected: each run waits for all workers `healthy` and `inFlight` 0 first (Task 4).
- W-M picks a worker with `inFlight` 0 (the turn already finished or has not reached a worker). Expected: the run is discarded and redone, not recorded (Task 4).
- A run that never recovers. Expected: recorded as censored at 120 s, present in the median and p95, and counted in the report (Tasks 1, 6).
- Server returns non-JSON or a 5xx during the outage. Expected: counted as an error for `t_err`, never thrown out of the driver (Task 4).
- Supervisor container stays down because of a restart policy gap. Expected: the driver detects it and issues `docker compose up -d supervisor`, reporting that delay separately (Task 4).

---

## File Structure

```
experiments/e18-crash-recovery/
  README.md              run instructions (Task 7)
  lib/stats.mjs          pure: percentile, summarize, userRetryTime, realModelMix
  lib/stub.mjs           Anthropic Messages API stub server (createStub)
  lib/injector.mjs       crash injection and cluster-state helpers (docker compose exec/kill)
  lib/client.mjs         the simulated user (session, turns, retry loop)
  driver.mjs             runs the four cases, writes results/runs.jsonl
  baseline.mjs           real-model baseline, writes results/baseline.json
  report.mjs             builds RESULTS.md from the two files
  compose.override.yml   adds the stub service and points the supervisor at it
  run.sh                 brings the stack up with the override, runs driver, tears down
  test/*.test.mjs        node --test
  results/               output (committed after the run)
```

### Task 1: Stats module

**Files:**
- Create: `experiments/e18-crash-recovery/lib/stats.mjs`
- Test: `experiments/e18-crash-recovery/test/stats.test.mjs`

**Interfaces:**
- Produces:
  - `percentile(values: number[], p: number): number` (linear interpolation, `p` in 0..100)
  - `summarize(runs: Run[]): { n: number, censored: number, median: number, p95: number, max: number }` over `run.tRecover` in ms, where a run with `censored: true` contributes 120000
  - `userRetryTime(tErr: number|null, tRecover: number, tickMs?: number = 3000): number` (if `tErr` is null returns `tRecover`; otherwise `tErr` + the smallest multiple of `tickMs` that is ≥ `tRecover - tErr`)
  - `realModelMix(overheadMs: number, medianRealMs: number): { seconds: number, share: number }`
  - `midTurnWait(elapsedAtKillMs: number, tRecoverMs: number, medianRealMs: number): number` (= sum of the three)
  - type `Run = { tRecover: number, censored: boolean }`

- [ ] **Step 1: Write the failing tests** in `experiments/e18-crash-recovery/test/stats.test.mjs`: `percentile([1,2,3,4,5], 50) === 3`; `percentile([1,2,3,4,5], 95) === 4.8`; `summarize` over three runs of 400, 600 and one censored gives `censored: 1`, `max: 120000`, `median: 600`; `userRetryTime(null, 400) === 400`; `userRetryTime(100, 400) === 3100`; `userRetryTime(100, 3100) === 3100`; `realModelMix(400, 4000)` gives `share` 0.1; `midTurnWait(1000, 500, 4000) === 5500`.
- [ ] **Step 2: Run** `cd e18 && node --test test/stats.test.mjs`. Expected: FAIL (module not found).
- [ ] **Step 3: Implement** the six exports in `lib/stats.mjs`. Plain functions, no state.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit** `feat(e18): stats module`.

### Task 2: Model stub, and the stub-satisfies-harness check

**Files:**
- Create: `experiments/e18-crash-recovery/lib/stub.mjs`, `experiments/e18-crash-recovery/test/stub.test.mjs`, `experiments/e18-crash-recovery/compose.override.yml`

**Interfaces:**
- Produces: `createStub({ delayMs = 200, reply = 'OK' }): http.Server` answering `POST /v1/messages`. Honours `stream: true` by sending the Anthropic SSE event sequence (`message_start`, `content_block_start`, `content_block_delta`, `content_block_stop`, `message_delta`, `message_stop`) with the first event after `delayMs`; otherwise returns one JSON message. `GET /healthz` returns 200.
- `compose.override.yml`: adds service `stub` (image `node:22-alpine`, mounts `./lib/stub.mjs`, runs it on port 8099, network `moca-brain`) and sets on `supervisor`: `ANTHROPIC_BASE_URL: http://stub:8099`, `ANTHROPIC_API_KEY: stub-key`, and `depends_on: [stub]`.

- [ ] **Step 1: Write the failing test**: start `createStub({delayMs: 50})` on an ephemeral port; a non-streaming POST resolves after ≥ 50 ms with `content[0].text === 'OK'`; a streaming POST yields events ending in `message_stop`.
- [ ] **Step 2: Run** `node --test test/stub.test.mjs`. Expected: FAIL.
- [ ] **Step 3: Implement** `createStub` and a `if (import.meta.url === ...)` entry that listens on `PORT` (default 8099) for the container.
- [ ] **Step 4: Run** the test. Expected: PASS.
- [ ] **Step 5: Live check (the spec's open risk).** In `~/gh/moca/deploy/compose` (a scratch project dir with a `.env` holding `SH_RELAY_TOKEN`, `MOCA_RELAY_EXEC_TOKEN`, `SH_TURNS_PER_WORKER=4`), run `docker compose -f docker-compose.yml -f <path>/e18/compose.override.yml up -d` and `curl -s -d '{"prompt":"Say OK."}' -H 'Content-Type: application/json' http://127.0.0.1:8080/turn`. Expected: a JSON response with a `sessionId` and the stub's reply, and the stub's log shows one request. If the harness rejects the stub (wrong shape, tool preamble, model-id validation), fix `stub.mjs` until it passes; if it cannot, stop and report: the spec's fallback is a recorded-response replay.
- [ ] **Step 6: Commit** `feat(e18): model stub and compose override`.

### Task 3: Injector (cluster state and kills)

**Files:**
- Create: `experiments/e18-crash-recovery/lib/injector.mjs`, `experiments/e18-crash-recovery/test/injector.test.mjs`

**Interfaces:**
- Consumes: a `run(cmd: string[]): Promise<{code, stdout}>` function (injected so tests need no Docker; the default runs `docker compose -f ... -p e18 ...`).
- Produces (all take `{ run }` first):
  - `readMetrics(ctx): Promise<{ workers: {id, pid, inFlight, healthy}[], counters: {restarts} }>` via `exec -T supervisor node -e "fetch('http://127.0.0.1:8081/metrics')..."`
  - `waitSteady(ctx, { timeoutMs = 60000 }): Promise<void>`: resolves when all workers `healthy` and `inFlight === 0`, else rejects.
  - `killWorker(ctx, { busy: boolean }): Promise<{ pid, killedAt: number }>`: SIGKILL via `exec -T supervisor kill -9 <pid>`; when `busy`, chooses a worker with `inFlight > 0` and throws `NoBusyWorker` if none.
  - `killSupervisor(ctx): Promise<{ killedAt: number }>` via `docker kill`; then `ensureSupervisorUp(ctx): Promise<{ manualStartMs: number|null }>` which polls up to 30 s for Compose's restart and issues `up -d supervisor` otherwise.

- [ ] **Step 1: Write failing tests** with a fake `run`: `waitSteady` rejects after the timeout when a worker stays unhealthy; `killWorker({busy:true})` throws `NoBusyWorker` when all `inFlight` are 0 and kills the busy pid when one is not; `ensureSupervisorUp` returns `manualStartMs: null` when the container comes back by itself and a number when it had to start it.
- [ ] **Step 2: Run** `node --test test/injector.test.mjs`. Expected: FAIL.
- [ ] **Step 3: Implement** the four functions. Time with `performance.now()`.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(e18): injector`.

### Task 4: Client and driver

**Files:**
- Create: `experiments/e18-crash-recovery/lib/client.mjs`, `experiments/e18-crash-recovery/driver.mjs`, `experiments/e18-crash-recovery/test/client.test.mjs`

**Interfaces:**
- Consumes: Task 3 injector; Task 1 `userRetryTime`.
- Produces:
  - `client.mjs`: `turn(baseUrl, prompt, sessionId?, { timeoutMs = 5000 }): Promise<{ ok: boolean, ms: number, sessionId?: string, status?: number, error?: string }>` (never throws); `retryUntilOk(baseUrl, prompt, sessionId, { intervalMs = 200, capMs = 120000 }): Promise<{ firstErrorMs: number|null, recoverMs: number, censored: boolean, attempts: number }>` measured from its own start.
  - `driver.mjs`: `node driver.mjs --runs 10 --out results/runs.jsonl [--cases W-I,W-M,S-I,S-M]`. Per run, one JSON line: `{ case, run, tBase, tErr, tRecover, tRecoverUser, censored, contextOk, resendNeeded, fraction, manualStartMs, restartsBefore, restartsAfter }`.

- [ ] **Step 1: Write failing tests** (against a local fake HTTP server): `turn` returns `ok:false` with `status` 503 and does not throw; `turn` returns `ok:false, error` on connection refused; `retryUntilOk` against a server that fails for 600 ms then succeeds reports `firstErrorMs` small and `recoverMs` ≥ 600 and `censored: false`; with `capMs: 400` and a server that never succeeds it returns `censored: true`.
- [ ] **Step 2: Run** `node --test test/client.test.mjs`. Expected: FAIL.
- [ ] **Step 3: Implement `client.mjs`.** Use global `fetch` with `AbortSignal.timeout`.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Implement `driver.mjs`** following spec §3.3 steps 1–5 and §4: before every run `waitSteady`; open a session with two fact turns; time a baseline turn (`tBase` is the median of the run's uncrashed stub turns); inject by case; for the `-M` cases send the turn without awaiting, kill after `fraction × (delayMs + tBase)` with `fraction` uniform in (0.1, 0.9), and on `NoBusyWorker` discard and redo that run (at most 3 redos); then `retryUntilOk`; then `contextOk` by reading the session history from Redis with `docker compose exec -T redis valkey-cli` for the two fact strings; write the line.
- [ ] **Step 6: Commit** `feat(e18): client and driver`.

### Task 5: Real-model baseline

**Files:**
- Create: `experiments/e18-crash-recovery/baseline.mjs`

**Interfaces:**
- Produces: `node baseline.mjs --n 20 --url http://127.0.0.1:8080 --out results/baseline.json` writing `{ n, medianMs, p95Ms, prompt, model }`. Uses Task 4 `turn` and Task 1 `percentile`. Prompt: `Run uname -a and tell me the kernel.` (the compose README's example). Requires a real `ANTHROPIC_API_KEY` in the stack, with no stub override.

- [ ] **Step 1: Implement** the script; discard the first call as warm-up and record the count discarded.
- [ ] **Step 2: Verify** against a live stack with a real key (Task 7), expected: `n` ≥ 19 and `medianMs` in a plausible range (1,000–15,000).
- [ ] **Step 3: Commit** `feat(e18): real-model baseline`.

### Task 6: Report generator

**Files:**
- Create: `experiments/e18-crash-recovery/report.mjs`, `experiments/e18-crash-recovery/test/report.test.mjs`

**Interfaces:**
- Consumes: Task 1 exports; `results/runs.jsonl`, `results/baseline.json`.
- Produces: `buildReport(runs: Run[], baseline: {medianMs, p95Ms}): string` (markdown): a per-case table with columns `n`, `censored`, `median`, `p95`, `max` (seconds), `overhead / T`, `t_recover_user` median, `context_ok` count; and the mid-turn arithmetic row labelled "computed, not measured". CLI: `node report.mjs --runs ... --baseline ... --out RESULTS.md`.

- [ ] **Step 1: Write the failing test**: three synthetic runs for `W-I` (one censored) and a baseline of 4000 ms; the output contains `W-I`, the censored count `1`, and a share formatted to one decimal; a `-M` case includes the sentence "computed, not measured".
- [ ] **Step 2: Run** `node --test test/report.test.mjs`. Expected: FAIL.
- [ ] **Step 3: Implement** `buildReport` and the CLI.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(e18): report generator`.

### Task 7: Wrapper, live run, results

**Files:**
- Create: `experiments/e18-crash-recovery/run.sh`, `experiments/e18-crash-recovery/README.md`, `experiments/e18-crash-recovery/results/*`, `experiments/e18-crash-recovery/RESULTS.md`

**Interfaces:**
- `run.sh [stub|real]`: `stub` brings the stack up with the override and runs `driver.mjs`; `real` brings it up without the override (a real key from the environment) and runs `baseline.mjs`; both tear down on exit with `trap`.

- [ ] **Step 1: Write `run.sh`** (shellcheck-clean; takes the compose directory from `E18_COMPOSE_DIR`, default `~/gh/moca/deploy/compose`; creates a throwaway project dir and `.env` as in `smoke.sh`).
- [ ] **Step 2: Smoke** `./run.sh stub` with `--runs 1`. Expected: four lines in `results/runs.jsonl`, none censored.
- [ ] **Step 3: Full stub run** with `--runs 10`. Expected: about 40 lines; record the host (OS, Docker version, `SH_WORKERS`) in the README.
- [ ] **Step 4: Real baseline** `ANTHROPIC_API_KEY=... ./run.sh real`. Expected: `results/baseline.json`.
- [ ] **Step 5: Generate** `RESULTS.md` with `report.mjs`; write the interpretation paragraph (what dominated each case, including whether the 30 s turn-reattach lease governed S-M, per spec §5).
- [ ] **Step 6: Commit** `docs(e18): results`.

---

## Self-review

- **Spec coverage:** §3.1 cases and kills → Tasks 3, 4; §3.2 stub and its open risk → Task 2 step 5; §3.3 client → Task 4; §3.4 measurements, including `t_recover_user` and censoring → Tasks 1, 4; §3.5 baseline and mid-turn arithmetic → Tasks 1, 5, 6; §4 procedure and §5 risks (backoff leak, lease) → Task 4 step 5, Task 7 step 5; §6 non-changes → Global Constraints.
- **Type consistency:** `Run` fields `tRecover` and `censored` (Task 1) match the driver's output fields (Task 4); `turn` and `retryUntilOk` signatures are defined once in Task 4 and used in Task 5.
- **Proportion:** 7 tasks for a spec of about 6 sections; code appears only as signatures and test assertions.
