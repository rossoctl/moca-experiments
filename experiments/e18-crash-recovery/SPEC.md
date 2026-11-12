# E18 — crash recovery latency: what does a user wait when the harness crashes?

Version: 0.1 (draft for review), 2026-11-10
Status: **Design. Reviewed; awaiting the user's approval.** Nothing is built.
Parent: none. E4 (`experiments/e01-e07-knative/e4-recovery.sh`) showed that a pod kill loses no completed turn; it recorded no timing.
Design under test: moca `docs/specs/2026-09-08-p6-vm-process-manager-design.md` (failure table, ~line 663) and
`docs/specs/2026-10-09-turn-reattach-design.md` (owner-crash lease, ~line 194).
Rig: the moca Docker Compose trial (`deploy/compose/`), on a developer machine. No cluster, no metal.

Marked **(call)** below are the author's choices, not the user's decisions. The user decided: both crash
kinds (worker and supervisor), the metric is latency as the end user perceives it, the rig is Compose, the
model is replaced by a canned-response stub, and the result is also expressed against the median turn time
of a real model.

---

## 1. The question

**When the harness crashes while a user has a session open, how much longer does the user wait than they
would have without the crash?**

The unit is user-perceived time, not process-restart time. A user who must resend a turn, or who sees an
error before the retry works, waits longer than the restart alone. E4 answered "is anything lost"
(no). E18 answers "how long does it feel".

Expected shape (from the code, not measured): a worker kill costs the supervisor's restart backoff
(`SH_WORKER_RESTART_BACKOFF_MS`, default 250 ms, doubling per crash up to a cap) plus a retry. A supervisor
kill costs a container restart plus worker start-up, probably seconds.

## 2. Goals, non-goals, anti-goals

**Goals**
- Per crash case, the user-perceived overhead: seconds, and as a share of a real-model median turn.
- Whether the user sees an error (and how long until it) or only a delay.
- Whether session context (the earlier turns) survives each case.

**Non-goals**
- No change to moca. No ladder, no capacity, no sealed predictions, no verdict thresholds.
- No cluster, Knative, microVM or SBX path. No Redis or relay crash (a follow-up if wanted).
- Not an availability or SLO study. About ten runs per case; the output is a small table.

**Anti-goals**
- Reporting restart time as if it were user latency.
- A real-model run in the crash loop, where model variance (1–3 s) is the size of the effect.

## 3. Design

### 3.1 Cases (2 crashes × 2 moments = 4)

| Case | Kill                                         | Moment                          |
| ---- | -------------------------------------------- | ------------------------------- |
| W-I  | one worker process, `SIGKILL` of its pid     | between turns (session idle)    |
| W-M  | one worker process, `SIGKILL` of its pid     | mid-turn (turn in flight)       |
| S-I  | the supervisor container, `docker kill`      | between turns                   |
| S-M  | the supervisor container, `docker kill`      | mid-turn                        |

Worker pids come from the supervisor's `/metrics` (`workers[].pid`, `inFlight`), the admin listener on
`SH_ADMIN_PORT` 8081. For W-M the harness kills the worker whose `inFlight` is non-zero. **(call)** For the
supervisor cases the container is restarted by Compose (`restart: unless-stopped`, to be confirmed in
`docker-compose.yml`); if the trial file has no restart policy, the harness issues `docker start` and the
delay to do so is excluded and reported separately. **(call)**

### 3.2 Model stub

A small HTTP server answers the Anthropic Messages API with a fixed short reply after a fixed delay D
(**(call)** D = 200 ms), the supervisor pointed at it through `ANTHROPIC_BASE_URL` (already in the
supervisor's env allowlist). Every turn thus costs about D plus harness overhead, so the crash overhead is
not buried in model noise.

**Unverified:** that the harness completes a turn, including any tool-call round trip, against a minimal
stub. Turns use a prompt that needs no tool call, so only the plain message path is exercised. If the
stub is not enough, the fallback is a small recorded-response replay; that is the first thing to settle in
the plan.

### 3.3 Client

One script plays a user, per run:

1. Open a session; run two turns, each noting a fact (as E4 does), to establish context.
2. Run a baseline turn (no crash), time it → `t_base`.
3. Inject the crash (§3.1). For mid-turn cases, send a turn and kill after a random fraction of D.
4. Keep sending the same turn (every 200 ms, up to 120 s) on the same session until one succeeds. A run with no success by 120 s is censored: it is counted and reported, and is not dropped from the median or p95 (it counts as 120 s). The 200 ms poll is the headline (the system's recovery time).
5. Check that context survived by reading the session's stored history from Redis for the two facts (the stub cannot recall anything, so the model's answer is not used). **(call)**

### 3.4 Measurements (per run)

- `t_err`: kill → first error or stall the user would see (connection reset, 5xx, or no response by a
  timeout of 5 s). Null if the turn simply took longer.
- `t_recover`: kill → first successful turn on the same session.
- `overhead` = `t_recover` − `t_base`, with `t_base` the median of the uncrashed stub turns in that run.
- `context_ok`: boolean.
- `t_recover_user`: the perceived time for a user who retries once every 3 s, computed from the same runs as `t_recover` rounded up to the next 3 s tick after the first error (no extra runs). Reported beside the headline. **(call)**
- `resend_needed`: whether the user's in-flight turn had to be sent again.

### 3.5 Real-model baseline and the reported figure

Once, outside the crash loop: about 20 uncrashed turns against the real model with a representative prompt,
giving a median `T` and p95. **(call)** The prompt is the compose smoke's `uname -a` style turn, so tool
latency is included.

Per case the report gives `overhead` (median, p95, max over ~10 runs) in seconds and as `overhead / T`.
Example of the form: "W-I: +0.4 s, about 10% of a typical 4 s turn."

For the mid-turn cases the kill lands at a random fraction f of the stub turn, and `elapsed_at_kill` for the real-model figure is f × T. **(call)** A kill during a long tool run would cost more than one during the model call; this spec does not test that and says so in the results. For the mid-turn cases a real model throws away the work done before the kill, and the user waits
for it again. So alongside the measured stub overhead the report computes
`elapsed_at_kill + t_recover + T` (the wait the real user sees if they must resend), and the worst case,
where the kill lands just before the reply. This is arithmetic on measured quantities, not a measurement,
and is labelled as such.

## 4. Run procedure

1. `docker compose up -d` in `deploy/compose/` with the stub's URL and no real model key; wait for ready.
2. Warm-up: 5 uncrashed turns.
3. For each of the four cases, ~10 runs, each on a fresh session, with the stack back to a healthy
   steady state (all workers healthy per `/metrics`) before the next kill.
4. The real-model baseline, on the same host, in a separate step.
5. Write `results/` JSON (one record per run) and `E18/RESULTS.md` with the table.

Total wall time is expected to be well under an hour. **(call)**

## 5. Risks

- The stub may not satisfy the harness (§3.2).
- Docker Desktop on a laptop adds scheduling noise; report the host. The comparison to `T` is only
  indicative for another environment.
- Worker restart backoff doubles per consecutive crash; runs must wait for the pool to settle so the
  backoff counter does not leak between runs.
- The turn-reattach lease (30 s) may govern the mid-turn supervisor case; if so `t_recover` for S-M will
  be dominated by it and should be reported with that explanation.

## 6. Scope — explicitly not building

- No change to moca code, deploy files or the compose file.
- No automation beyond the one driver script and the stub.
- No Kubernetes, VM or microVM variant. Those are follow-ups if the Compose numbers warrant them.
