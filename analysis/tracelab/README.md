# tracelab — E15 and E16 trace and results analysis

Analysis of experiments E15 and E16 (both complete), and of the TraceLab traces they replay.

E15 asks one question: on the same hardware, does SBX (a fresh Firecracker microVM for each shell
command) hold more concurrent coding-agent sessions per host than resident microVMs (one VM kept
per session)? A Go driver replays recorded Claude Code and Codex sessions from TraceLab, and each
call runs a real command of its class. The design is `../../experiments/e15-session-density/SPEC.md` and the record is
`../../experiments/e15-session-density/results/metal/RESULTS-METAL.md` (metal) and `../../experiments/e15-session-density/SPEC.md` (AWS preliminary), all in
[rossoctl/moca-experiments](https://github.com/rossoctl/moca-experiments).

E16 asks the same question for mostly idle sessions. Its hypothesis is: at a duty cycle of 2% or
less, SBX holds more sessions than resident VMs. It replays the (1%, 2%] duty band of the E15
corpus on the E15 metal host. Its spec is `../../experiments/e16-low-duty/SPEC.md` and its record `../../experiments/e16-low-duty/RESULTS.md`.

The full write-up with figures is in [REPORT.md](REPORT.md). A 16-slide summary deck is
[out/e15-e16-tracelab-summary.pptx](out/e15-e16-tracelab-summary.pptx).

## What the data is

| input | where | in git? |
|---|---|---|
| Replay corpora (default, short, long, no-infra, no-chains) | `data/corpora/<point>/` | no; fetched from release `data-v2` (sha256 in `data/corpora/MANIFEST.md`, verified) |
| TraceLab v0.0.2 DuckDB | `/tmp/kagenti/tracelab/trace/v0.0.2/` | no; path and hash in [data/SOURCES.md](data/SOURCES.md) |
| AWS preliminary results | `data/results/aws/` | no; fetched from release `data-v2` (source commit `3c295c9`) |
| E15 metal results (final) | `data/results/metal/` | no; fetched from release `data-v1` (source commit `7a90a76`) |
| E16 results (final) | `data/results/e16/` | no; fetched from release `data-v1` (source commit `c8dba13`) |

TraceLab is © the uw-syfi TraceLab project, licensed
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/), from
[github.com/uw-syfi/TraceLab](https://github.com/uw-syfi/TraceLab). Every table and figure here
that uses the corpora or the DuckDB is derived from it.

## How to reproduce

```sh
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
scripts/fetch_results.sh          # verifies and unpacks the release archives into data/, writes data/results-lock.json
V=.venv/bin/python
$V analysis/sessions.py           # span, duty cycle, gaps, H cap
$V analysis/tiers.py              # weight tiers, sensitivity, class mix
$V analysis/turns.py              # shell calls per LLM turn (needs the DuckDB)
$V analysis/overlap.py            # heavy-call concurrency at N = 8, 16, 80, 96
$V analysis/rungs.py              # rung table, ladders, latency tail
$V analysis/e16.py                # E16 band, rungs, ladders; duty cycle vs memory and sessions
$V analysis/deck.py               # summary slides: out/e15-e16-tracelab-summary.pptx
```

Each script runs on its own. Figures go to `out/figures/` and tables (CSV + Markdown) go to
`out/tables/`. `fetch_results.sh` never copies `worker.log.gz` into `data/results/`, because rung logs can
hold tokens; the archives carry them, but the analysis does not read them.

**Weight tiers** are cut on a call's `work_ms` (the part that uses CPU): **light < 1 s, medium
1–10 s, heavy > 10 s**. A sensitivity check also uses 0.5/5 s and 2/20 s cuts.

## Findings

1. **Sessions are mostly idle.** At the default point a command is running 9.5% of session time,
   and work is 8.2% of it. Claude sessions are 3.8% busy and Codex sessions 19.2%. These match
   SPEC §5.4. → [sessions_summary](out/tables/sessions_summary.md)
2. **The H cap does a lot of work.** At H = 1800 s the cap removes 44,268 h of idle time, which is
   84% of the uncapped session time. → [sessions_summary](out/tables/sessions_summary.md)
3. **A few heavy calls carry the work.** 7.4% of calls are heavy, and they carry 86.5% of all work
   (79.9–91.3% across the sensitivity cuts). Codex has 16,639 heavy calls, and 75% of them are
   polled chains. → [tiers_sensitivity](out/tables/tiers_sensitivity.md),
   [tiers_heavy_by_provider](out/tables/tiers_heavy_by_provider.md)
4. **On AWS, heavy calls cause the failures.** At N=16 the heavy-tier p95 excess was 30.7 s (SBX)
   and 31.9 s (resident ∞, first run). The light tier stayed at 164–193 ms. Every arm fails at the
   same point for the same reason. → [tail_by_tier](out/tables/tail_by_tier.md),
   [figure](out/figures/tail_by_tier_vs_n.png)
5. **The driver's draw explains the AWS knee.** In the replay model, at N=16 four or more heavy
   calls run at once for 2.5% of the window. That is enough to queue on 4 vCPUs. At N=80 this
   happens for 80% of the window, and 96 vCPUs absorb it.
   → [overlap_heavy](out/tables/overlap_heavy.md), [figure](out/figures/overlap_heavy_ccdf.png)
6. **E15 metal (final @7a90a76): resident holds more than SBX.** SBX holds 80, resident ∞ and
   resident 300 s hold 128. Each first failure (N=96 for SBX, N=160 for resident) was the p95
   latency tail, with 0 failed calls and host CPU at 9–13%. The supplementary readings (not
   sealed) give 192 for every arm under a 1 s limit, and 320 / 384 / 448 under conditions 1–3
   only. → [ladders](out/tables/ladders.md),
   [metal_supplementary](out/tables/metal_supplementary.md),
   [figure](out/figures/p95_excess_vs_n.png)
7. **Metal removes most of the tail.** At N=16, SBX's p95 excess falls from 1,545 ms (AWS) to
   198 ms (metal), and resident ∞'s from 15,200 ms to 110 ms. For calls planned ≥ 1 s, SBX's p95
   measured ÷ planned time stays ≤ 1.12 up to N=96 on metal. On AWS at N=16 it was 1.97.
   → [aws_vs_metal](out/tables/aws_vs_metal.md), [slowdown_ge1s](out/tables/slowdown_ge1s.md)
8. **The N=1 overhead matches the baselines.** SBX pays +186.2 ms per call on AWS and +33.7 ms on
   metal. Resident arms pay −16 to −28 ms (faster than the recorded time).
   → [n1_overhead](out/tables/n1_overhead.md)
9. **Bundling has much more to gain on Codex than on Claude (E15b input).** Codex sends 1.78 shell
   calls per LLM turn, 66% of its shell calls share a turn, and 98–99% of same-turn pairs overlap.
   Claude sends 1.07 per turn, and only 12% of its shell calls share a turn.
   → [turns_shell_calls](out/tables/turns_shell_calls.md)

10. **E16 (final @c8dba13): at 1.5% duty the arms do not separate; the hypothesis is falsified.**
    Read three ways (`experiments/e16-low-duty/RESULTS.md` order):
    - **Sealed:** SBX ≥ 1,024 (its sealed ladder's top) against resident ∞ 1,024. A tie, so the
      hypothesis "SBX holds more" is **falsified**.
    - **Post-seal SBX extension** (decided after seeing SBX's ladder): SBX ≥ 1,536 against
      resident's sealed 1,024. Not a sealed verdict: resident's 1,280 failed on seeds 1 and 2 only
      because calls were cut by the run-end burst (finding 12); the latency test passed (249 and
      261 ms against 395).
    - **Staggered end-sessions** (supplementary; the run-end burst removed; every rung valid):
      both arms ≥ 1,536. No separation.
    → [e16_readings](out/tables/e16_readings.md), [e16_ladders](out/tables/e16_ladders.md),
    [e16_rungs](out/tables/e16_rungs.md), [e16_stag](out/tables/e16_stag.md),
    [figure](out/figures/e16_ladder.png)
11. **Lower duty cuts SBX's memory per session, not resident's, and memory never binds.** At each
    arm's n_max, SBX's VMs use 24 MiB per session at 9.5% duty and 12 MiB at 1.5%. Resident ∞
    uses 119 and 98 MiB. At N = 1,024 resident's VMs average 98 GiB (peak 105 GiB, 28% of the host).
    A resident VM levels off near 150 MiB after about an hour and stays there to 3 hours (p95 ~230,
    max 309 MiB), far below its 1,024 MiB guest RAM. → [duty_memory](out/tables/duty_memory.md),
    [e16_vm_age](out/tables/e16_vm_age.md), [figures](out/figures/duty_memory.png),
    [VM age](out/figures/e16_vm_age.png)
12. **The resident failures are a moca worker limit hit by the replay's run-end burst
    ([rossoctl/moca#705](https://github.com/rossoctl/moca/issues/705)).** At window end the driver
    ends every resident session at once. A worker connection admits 320 Execs (256 running + 64
    queued) and refuses the rest with an unlogged "busy: queue full": on every sealed resident rung
    the refused end-sessions are N − 320 (64 at 384 … 576 at 896). From N ≈ 900 the burst of
    refusals and aborts overflows the 16-slot terminal-frame reserve, the connection drops, and
    9–24 in-flight calls fail. Paced at 50/s, no end-session failed and no rung wedged up to
    1,536. → [e16_end_sessions](out/tables/e16_end_sessions.md)

## Open questions

- Both arms are censored at 1,536 at 1.5% duty, so neither true ceiling is known. Above N ≈ 900 the
  456-session band replays each trace two to three times (distinct-trace share 0.30–0.49, below
  SPEC §9's 60%), so the top rungs are weaker evidence than the rungs at or below 1,024.
- Most of SBX's live VMs at E16 N=1,024 are warm standbys (612 of 628 on average), not running
  commands. Its memory count includes them.
- The E15b turn table (SPEC-bundled §1.2) uses absolute counts we cannot reproduce. Its shares
  agree with ours (see REPORT §4).
- The replay model does not use Go's `math/rand` stream. It matches the measured window call
  counts within its 20-seed spread, but it is not the same session draw.
