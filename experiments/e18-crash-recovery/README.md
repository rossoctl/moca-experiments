# E18: crash recovery latency

Measures the extra wait a user sees when a moca worker or the supervisor is killed, on the Docker Compose
trial, with the model replaced by a canned-response stub. Spec: `SPEC.md`.
Plan: `PLAN.md`.

## Run

Needs Node 22+, Docker with Compose, and a moca checkout (`E18_COMPOSE_DIR`, default `~/gh/moca/deploy/compose`).

```bash
./run.sh stub --runs 10 --out results/runs.jsonl    # four cases x 10 runs, stubbed model
ANTHROPIC_API_KEY=... ./run.sh real --n 20 --out results/baseline.json   # real-model median T
node report.mjs --runs results/runs.jsonl --baseline results/baseline.json --out RESULTS.md
```

Unit tests (no Docker): `node --test test/`.

## How the supervisor kill works

`docker kill` counts as a manual stop, so Docker does not apply `restart: unless-stopped` and the container would
sit down until someone starts it. The S cases therefore stand in for an orchestrator that restarts at once: the
driver runs `docker compose up -d supervisor` right after the kill. `tRecover` includes the restart (it is the
recovery work); the `up -d` command time is reported separately as `restartCmdMs`. There is no detection wait.

## Worker restart backoff

The pool doubles a slot's restart backoff on each crash and resets it only after the worker ran 10 s. W cases
wait 11 s after the pool is steady before each kill, so a run does not inherit the previous run's backoff.

## First thing to check

The stub is unverified against the harness (spec §3.2). Before the full run, `./run.sh stub --runs 1 --cases W-I`
must produce one record. If the harness rejects the stub's replies, fix `lib/stub.mjs`; if it cannot be made to
work, the spec's fallback is a recorded-response replay.

## Host

Record the host (OS, Docker version, `SH_WORKERS`) next to the results; numbers are indicative for other environments.
