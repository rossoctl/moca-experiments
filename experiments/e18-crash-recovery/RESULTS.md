# E18 results: crash recovery latency

Spec: `SPEC.md`. Host: macOS (Apple silicon), podman machine through the
docker CLI, Compose 5.7.0, moca image `ghcr.io/rossoctl/moca:latest`, 2026-11-10. Model replaced by a canned-response
stub (200 ms per turn; 2000 ms for the mid-turn cases so a kill can land inside the turn). 10 runs per case, each on a
fresh session. Real-model baseline: 20 turns through the IBM LiteLLM gateway, median T = 3.67 s, p95 = 6.03 s
(`results/baseline.json`). Numbers are indicative for other environments.

## Reading the tables

- `recover` = kill to the first successful turn on the same session. `overhead vs T` = recover minus one normal stub turn,
  as seconds and as a share of the real-model median T. `t_err` = kill to the first error the user sees.
- `user-retry` = recover rounded up to a 3 s retry tick after the first error (a user who retries every 3 s).
- The S cases model an orchestrator that restarts the supervisor at once: `docker kill` is a manual stop, so Compose's
  restart policy would not act. They exclude any container-detection delay.

## Default pool (4 workers): `results/runs-w4.jsonl`


| case | n | censored | recover median (s) | p95 (s) | max (s) | overhead vs T | t_err median (s) | resend | restart cmd median (s) | discarded | user-retry median (s) | context ok |
| ---- | - | -------- | ------------------ | ------- | ------- | ------------- | ---------------- | ------ | ---------------------- | --------- | --------------------- | ---------- |
| W-I | 10 | 0 | 0.21 | 0.24 | 0.26 | -0.00 s, -0.1% (p95 0.02 s, max 0.04 s) | none | 0/10 | - | 0 | 0.21 | 10/10 |
| W-M | 10 | 0 | 2.01 | 2.01 | 2.01 | -0.00 s, -0.1% (p95 0.00 s, max 0.00 s) | 0.00 | 10/10 | - | 0 | 3.00 | 10/10 |
| S-I | 10 | 0 | 1.45 | 1.46 | 1.47 | 1.24 s, 33.8% (p95 1.25 s, max 1.25 s) | 0.18 | 0/10 | 0.11 | 0 | 3.18 | 10/10 |
| S-M | 10 | 0 | 3.49 | 16.15 | 16.53 | 1.48 s, 40.3% (p95 14.13 s, max 14.51 s) | 0.00 | 10/10 | 0.11 | 0 | 6.00 | 10/10 |

Mid-turn wait for a real-model user who must resend: `elapsed_at_kill + recovery overhead + T` (computed, not measured; the overhead is t_recover minus one normal turn, floored at 0). Typical uses the median landing point of the recorded kills; worst case is a kill just before the reply (f = 1).

| case | typical (s) | worst (s) |
| ---- | ----------- | --------- |
| W-M | 6.12 | 7.34 |
| S-M | 6.63 | 8.82 |

## One worker (`SH_WORKERS=1`), W cases only: `results/runs-w1.jsonl`


| case | n | censored | recover median (s) | p95 (s) | max (s) | overhead vs T | t_err median (s) | resend | restart cmd median (s) | discarded | user-retry median (s) | context ok |
| ---- | - | -------- | ------------------ | ------- | ------- | ------------- | ---------------- | ------ | ---------------------- | --------- | --------------------- | ---------- |
| W-I | 10 | 0 | 1.28 | 1.29 | 1.29 | 1.07 s, 29.1% (p95 1.08 s, max 1.08 s) | 0.00 | 0/10 | - | 0 | 3.00 | 10/10 |
| W-M | 10 | 0 | 3.08 | 3.09 | 3.09 | 1.07 s, 29.1% (p95 1.07 s, max 1.07 s) | 0.00 | 10/10 | - | 0 | 6.00 | 10/10 |

Mid-turn wait for a real-model user who must resend: `elapsed_at_kill + recovery overhead + T` (computed, not measured; the overhead is t_recover minus one normal turn, floored at 0). Typical uses the median landing point of the recorded kills; worst case is a kill just before the reply (f = 1).

| case | typical (s) | worst (s) |
| ---- | ----------- | --------- |
| W-M | 5.99 | 8.40 |

## What it says

1. **A worker kill is invisible to the user when other workers are healthy.** With 4 workers a kill between turns cost
   nothing (recover 0.21 s, the same as a normal turn, no error seen): a sibling worker takes the next turn. This
   measures the sibling, not the restart.
2. **With one worker the restart is felt:** a worker kill between turns costs the user about 1.1 s extra (1.28 s against
   0.21 s), preceded by an error; 29% of a typical real-model turn.
3. **A mid-turn kill always fails the in-flight turn, and the user must resend.** The wait is the work already done plus
   recovery plus a full turn. With 4 workers recovery adds nothing beyond that resend. For a real-model user the
   computed wait is about 6.1 s typical and 7.3 s worst case (against a normal turn of 3.7 s); with one worker it is
   about 1.1 s more. These two figures are computed from measured quantities, not measured.
4. **A supervisor kill costs about 1.2 s extra between turns** (recover 1.45 s, 34% of T) and fails the first attempt at
   about 0.18 s. Mid-turn it costs about 1.5 s extra at the median.
5. **No completed turn was lost in any of 60 runs:** context survived, and the recovered turn was on the same session.

## Open: two unexplained slow runs

Two of the ten S-M runs (run 4 and run 8) took about 16 s to recover, against about 3.3 s for the other eight
(p95 16.2 s). Their `restartCmdMs` (about 110 ms) and kill landing point (0.32 and 0.79) are not different from the
fast runs, so the extra roughly 13 s is spent after the container is up. The cause is not known: it could be the sandbox
re-attaching through the relay, or the turn-reattach lease, but nothing in the records distinguishes them. It needs a
rerun with the supervisor and relay logs kept. Until then the S-M median (3.5 s) understates what one run in five
may cost.

## Not tested

A kill during a long tool run (the stub path has no tool call); a Redis or relay crash; a real orchestrator restart delay
for the supervisor; more than 10 runs per case.
