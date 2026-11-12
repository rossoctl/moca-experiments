# E16 results: low duty cycle (1–2%), SBX vs resident ∞ on the E15 metal host

Host: AWS m7i.metal-24xl (96 vCPU, 377 GiB), E15 metal setup, point `lowduty`: 456 sessions with
duty cycle in (1%, 2%] (1.49% occupied). Worker admission set so it never binds
(`SH_MAX_COMMITTED_MB=4194304`, `SH_MAX_RUNS=4096`). Physical memory is the only memory limit.
Sealed predictions: `experiments/e16-low-duty/predictions.json` (d7271aa). All numbers below come from
`experiments/e16-low-duty/results/summary.json` (`experiments/e16-low-duty/analysis/results.py`) and the rung records under `experiments/e16-low-duty/results/`.

## The hypothesis verdict

1. **Sealed** (SPEC §7.2, sealed ladders only). SBX ≥ 1024 (censored at its sealed top) against
   resident ∞ 1024. That is a tie, so the hypothesis is **FALSIFIED**.
2. **Post-seal SBX extension.** This was decided after seeing SBX's sealed ladder. SBX ≥ 1536 against
   resident ∞'s sealed 1024. **This is not a sealed verdict.**
   - Resident's sealed limit is its failure at 1280 on seed 1 and seed 2. That failure comes from the
     run-end egress wedge. It is not the host.
   - The no-wedge re-judges of both 1280 seeds hold.
   - The latency test passes there with margin: p95 excess 249 and 261 ms against a 395 ms limit.
3. **Supplementary staggered reading.** The run-end burst is removed and every rung is valid.
   Resident ∞ ≥ 1536 and SBX ≥ 1536. On this host and band, the arms **do not separate**.
4. **Bottom line.** At a 1–2% duty cycle, with physical memory as the only memory limit, neither arm
   runs out of anything up to 1,536 sessions. The only difference observed between the arms is the
   instrument's end-of-run burst, which affects resident only.

## Sealed predictions

| # | claim (sealed) | outcome | verdict |
|---|---|---|---|
| 1 | Hypothesis falsified: SBX's N_max ≤ resident ∞'s. Ranges: SBX [576, 768], resident ∞ [768, 1024]. | Sealed: SBX 1024 (censored), resident 1024. | direction **HOLDS** (tie, so falsified); numeric **FALSIFIED** (SBX above its range; resident in range) |
| 2 | Each arm's first failed rung fails on condition 4, with 0 failed calls, no refusal, no memory verdict, and host CPU < 25%. | SBX never failed. Resident's first failure (1280) failed condition 1 (24 failed calls, the run-end wedge); condition 4 passed; host CPU 15.9% mean. | **FALSIFIED** (resident); not tested (SBX) |
| 3 | Resident ∞'s summed VM memory at its N_max stays below 189 GiB, in [109, 163] GiB. | At N_max 1024: 105.9 GiB (slice 107.9). No memory verdict on any resident rung. The largest at 1280 was 142.2 GiB. | **HOLDS** (below 189 GiB, no memory verdict); just under the claimed band |
| 4 | The driver stays under 1% of host CPU (A2). | Max 0.10% over 22 ladder and seed rungs; control N=768 0.005%. | **HOLDS** |

## Ladders

`holds / abs` are the sealed primary and absolute verdicts. The supplementary readings are `1 s`
(condition 4 with a flat 1000 ms limit) and `CPU` (conditions 1–3 only), judged on the same rungs.

| arm | n_max | n_max_abs | n_max_1s | n_max_cpu | first failure | why |
|---|---|---|---|---|---|---|
| SBX, sealed ladder (≤ 1024) | ≥ 1024 | ≥ 1024 | ≥ 1024 | ≥ 1024 | none | censored at the sealed top |
| SBX with the post-seal extension | ≥ 1536 | ≥ 1536 | ≥ 1536 | ≥ 1536 | none | censored at 1536 |
| resident ∞ (sealed, incl. its sealed 1280/1536 extension) | 1024 | 1024 | 1024 | 1024 | 1280 (s1, s2) | condition 1: calls cut by the run-end egress wedge |

- **Seeds** (sealed rule: s2 on each deciding rung, s3 on disagreement, majority decides):
  - SBX 1024: s1 and s2 hold. SBX 1536 (post-seal): s1 and s2 hold.
  - Resident 896: s1 holds, s2 fails (wedge), s3 holds, so it holds.
  - Resident 1024: s1 fails (wedge), s2 and s3 hold, so it holds.
  - Resident 1280: s1 and s2 fail (wedge both times).
- **Repeats.** The drift repeats (warm-up 2400 s, K ×2) ran at resident 512, 640, 896 s3 and 1280 s2.
  The repeat is the counted record.
- **Order.** SBX ran 256 to 1024. Resident ran 256 to 1024, failing at first on seed 1 at 1024. Then
  the seeds, then the sealed resident extension to 1280, then the SBX post-seal extension to 1536, then
  seeds on the new deciding rungs.

### SBX (sealed ≤ 1024; 1280 and 1536 post-seal)

| N | seed | dir | holds / abs | 1 s / CPU | p95 excess ms (limit) | window calls | failed | host CPU mean / p95 % | live VMs max | VM mem sum GiB | MemAvailable min GiB | replayed duty median | distinct-trace share | egress wedged | no-wedge re-judge |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 256 | 1 | N256 | True / True | True / True | 126 (336) | 3619 | 0 | 3.4 / 6.0 | 182 | 3.3 | 369 | 0.0039 | 0.80 | 0 | - |
| 384 | 1 | N384 | True / True | True / True | 150 (336) | 6173 | 0 | 5.6 / 9.7 | 281 | 6.1 | 368 | 0.0031 | 0.72 | 0 | - |
| 512 | 1 | N512 | True / True | True / True | 134 (336) | 7935 | 0 | 6.2 / 9.9 | 380 | 7.8 | 368 | 0.0031 | 0.64 | 0 | - |
| 640 | 1 | N640 | True / True | True / True | 170 (336) | 9954 | 0 | 8.2 / 12.7 | 441 | 8.8 | 368 | 0.0038 | 0.55 | 0 | - |
| 768 | 1 | N768 | True / True | True / True | 166 (336) | 13361 | 0 | 9.6 / 14.5 | 523 | 11.1 | 367 | 0.0031 | 0.53 | 0 | - |
| 896 | 1 | N896 | True / True | True / True | 210 (336) | 15038 | 0 | 12.0 / 18.0 | 663 | 13.7 | 367 | 0.0033 | 0.48 | 0 | - |
| 1024 | 1 | N1024 | True / True | True / True | 216 (336) | 17819 | 0 | 13.8 / 19.2 | 693 | 14.8 | 366 | 0.0039 | 0.44 | 0 | - |
| 1024 | 2 | N1024-s2 | True / True | True / True | 252 (336) | 16143 | 0 | 14.2 / 20.3 | 681 | 14.9 | 366 | 0.0034 | 0.43 | 0 | - |
| 1280 (post-seal) | 1 | N1280 | True / True | True / True | 263 (336) | 22912 | 0 | 17.9 / 27.8 | 926 | 20.2 | 365 | 0.0035 | 0.36 | 0 | - |
| 1536 (post-seal) | 1 | N1536 | True / True | True / True | 290 (336) | 25514 | 0 | 21.7 / 28.3 | 1034 | 23.0 | 365 | 0.0035 | 0.30 | 0 | - |
| 1536 (post-seal) | 2 | N1536-s2 | True / True | True / True | 305 (336) | 25351 | 0 | 22.6 / 30.9 | 1059 | 22.5 | 365 | 0.0040 | 0.29 | 0 | - |

### resident ∞ (sealed)

| N | seed | dir | holds / abs | 1 s / CPU | p95 excess ms (limit) | window calls | failed | host CPU mean / p95 % | live VMs max | VM mem sum GiB | MemAvailable min GiB | replayed duty median | distinct-trace share | egress wedged | no-wedge re-judge |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 256 | 1 | N256 | True / True | True / True | 101 (395) | 3556 | 0 | 2.8 / 5.2 | 256 | 25.8 | 350 | 0.0025 | 0.82 | 0 | - |
| 384 | 1 | N384 | True / True | True / True | 132 (395) | 5974 | 0 | 5.2 / 8.9 | 384 | 38.6 | 340 | 0.0020 | 0.73 | 0 | - |
| 512 | 1 | N512-repeat | True / True | True / True | 174 (395) | 7941 | 0 | 6.4 / 10.5 | 512 | 58.8 | 325 | 0.0028 | 0.59 | 0 | - |
| 640 | 1 | N640-repeat | True / True | True / True | 187 (395) | 10873 | 0 | 9.0 / 14.2 | 640 | 72.8 | 314 | 0.0028 | 0.53 | 0 | - |
| 768 | 1 | N768 | True / True | True / True | 159 (395) | 12438 | 0 | 8.5 / 13.6 | 768 | 78.1 | 309 | 0.0022 | 0.51 | 0 | - |
| 896 | 1 | N896 | True / True | True / True | 203 (395) | 14684 | 0 | 11.2 / 18.9 | 896 | 92.1 | 298 | 0.0025 | 0.49 | 0 | - |
| 896 | 2 | N896-s2 | False / False | False / False | 196 (395) | 14927 | 9 | 10.9 / 17.6 | 896 | 89.7 | 300 | 0.0021 | 0.48 | 1 | holds (9 excluded) |
| 896 | 3 | N896-s3-repeat | True / True | True / True | 207 (395) | 13044 | 0 | 10.2 / 15.3 | 896 | 99.3 | 295 | 0.0024 | 0.42 | 0 | - |
| 1024 | 1 | N1024 | False / False | False / False | 203 (395) | 16299 | 14 | 12.0 / 17.3 | 1024 | 105.9 | 287 | 0.0026 | 0.44 | 1 | holds (14 excluded) |
| 1024 | 2 | N1024-s2 | True / True | True / True | 214 (395) | 17058 | 0 | 13.2 / 20.0 | 1024 | 104.8 | 288 | 0.0025 | 0.43 | 0 | - |
| 1024 | 3 | N1024-s3 | True / True | True / True | 202 (395) | 16962 | 0 | 11.9 / 18.0 | 1024 | 102.3 | 291 | 0.0021 | 0.42 | 0 | - |
| 1280 | 1 | N1280 | False / False | False / False | 249 (395) | 20420 | 24 | 15.9 / 23.5 | 1280 | 129.3 | 268 | 0.0024 | 0.35 | 1 | holds (24 excluded) |
| 1280 | 2 | N1280-s2-repeat | False / False | False / False | 261 (395) | 20522 | 13 | 17.1 / 23.8 | 1280 | 142.2 | 262 | 0.0032 | 0.34 | 1 | holds (13 excluded) |

Every resident rung that failed did so on condition 1 only, and every one of those rungs has an egress
wedge at the run's end. No rung without a wedge failed in either arm. Class pace stayed at or below +0.06%
everywhere.

Limits come from each arm's lowduty N=1 baseline (3 seeds plus class probes):
- SBX: B 111.9 ms, primary limit 335.7 ms.
- Resident: B 131.8 ms, primary limit 395.4 ms.

## The run-end egress wedge (why resident's sealed ladder stops at 1280)

- **The burst.** At warm-up + window, the driver ends every live session. For the resident arm it
  sends one end-session Exec per session at once, so about N Execs within a second. SBX sends none.
- **The refusal.** The worker admits 320 Execs per relay connection: `WORKER_MAX_CONCURRENT` 256
  running plus the session queue `QueueCap` 64 (moca `remote-worker/internal/session/loop.go`,
  `enqueueAdmitted`). The rest are refused with an ExecError frame, "busy: queue full", which the worker
  never logs.
- **The evidence.** On every sealed resident rung from N=384 to 896, exactly 320 run-end end-sessions
  succeed, and failed = N − 320 (64, 192, 320, 448, 576; N=256: 0).
- **The wedge.** From about N=896 on, the refusal frames can exhaust the connection's 16-slot
  terminal-frame reserve (`TerminalReserve = QueueCap / 4`). The worker then ends the stream ("egress
  wedged: the terminal-frame reserve could not be queued") and reconnects. Window calls still in flight
  at that moment get exit −1.
  - The sealed N=1024 s1 rung shows it at 00:33:29 UTC: 119 end-sessions, 137 aborted Execs and 133
    destroys in one second.
- **Scope.** The effect is per connection, not host-wide. MemAvailable stayed ≥ 262 GiB and host CPU
  ≤ 24% p95 on every resident rung.

## Supplementary readings (not voted)

**No-wedge re-judges** (`record_nowedge.json` beside `record.json`, `experiments/e16-low-duty/analysis/nowedge.py`). They
drop in-window calls with `exit_mismatch` / exit −1 that were in flight within ±2 s of a worker
"egress wedged" line, then run record.py unchanged. All five wedged resident rungs hold both verdicts
this way:

| rung | calls excluded |
|---|---|
| 896 s2 | 9 |
| 1024 s1 | 14 |
| 1280 s1 | 24 |
| 1280 s2 | 13 |

**Staggered re-run** (tag `stag`; driver `--end-session-defer`, a separate binary `e15-driver-defer`;
the sealed `e15-driver` is unchanged).
- **What changes.** End-session Execs for sessions the run's end stopped are sent after the grace
  deadline, in slot order, at 50/s. Natural session ends are unchanged.
- **Validity.** Each rung has a `stag_valid.json` with three checks: no egress-wedged line, no aborted
  Exec before graceEnd, and end_sessions_sent == end_sessions_ok. Every stag rung is valid, with 100%
  of end-sessions ok.
- **Counted runs.** The resident rungs ran their drift repeats, which are the counted runs.

| arm | N | seed | p95 excess ms (limit) | failed | end-sessions sent / ok / deferred | host CPU mean % | VM mem sum GiB | distinct-trace share | verdict |
|---|---|---|---|---|---|---|---|---|---|
| resident ∞ | 896 | 1 | 191 (395) | 0 | 3478 / 3478 / 896 | 11.2 | 100.1 | 0.41 | holds |
| resident ∞ | 896 | 2 | 208 (395) | 0 | 3434 / 3434 / 896 | 11.0 | 100.6 | 0.43 | holds |
| resident ∞ | 1024 | 1 | 214 (395) | 0 | 3963 / 3963 / 1024 | 12.1 | 115.9 | 0.39 | holds |
| resident ∞ | 1024 | 2 | 277 (395) | 0 | 3988 / 3988 / 1024 | 13.0 | 114.2 | 0.36 | holds |
| resident ∞ | 1280 | 1 | 281 (395) | 0 | 4919 / 4919 / 1280 | 17.2 | 144.0 | 0.34 | holds |
| resident ∞ | 1536 | 1 | 275 (395) | 0 | 5927 / 5927 / 1536 | 19.9 | 172.7 | 0.30 | holds |
| SBX | 1280 | 1 | 266 (336) | 0 | (none sent) | 17.0 | 19.6 | 0.36 | holds |
| SBX | 1536 | 1 | 272 (336) | 0 | (none sent) | 20.7 | 23.0 | 0.30 | holds |

Without the run-end burst, resident ∞ holds every rung up to 1536 (≥ 1536, censored).

## Mechanism

- **Latency.** In both arms, p95 excess rises slowly with N:
  - SBX: 126 ms at 256, 216 at 1024, 290–305 at 1536 (limit 336).
  - Resident: 101 at 256, about 210 at 1024, 249–281 at 1280–1536 (limit 395).
  - SBX uses more of its headroom per session (its limit is lower: B 112 vs 132 ms). At 1536 it sits at
    86–91% of its limit, against resident's 70% for the stag 1536 rung. Neither crosses it.
- **CPU.** Host CPU is at most 22.6% mean and 31% p95 (SBX 1536 s2). There was no CPU pressure.
- **Memory.**
  - Resident holds one VM per session: 105.9 GiB summed at 1024, 172.7 GiB at the stag 1536 rung.
    That is 46% of host RAM, about 106–115 MiB per VM. This is consistent with the long rung's VM age
    profile, since most windowed VMs are under an hour old.
  - SBX holds 15 GiB at 1024 and 23 GiB at 1536.
  - MemAvailable never fell below 262 GiB on a sealed rung. There was no memory verdict, no
    e15.slice OOM and no host-memory refusal.
- **Live VMs.** SBX peaked at 693 at 1024 and about 1,060 at 1536 (0.67–0.74 per session across its
  rungs). Resident holds N.
- **VM memory against age** (long rung, resident ∞, N=256, 3 h window; `experiments/e16-low-duty/results/vm-age/long-rung.md`):
  - Median by age: 61.9 MiB at 0 min, 118.4 at 20, 142.4 at 60, 147.9 at 120, 147.1 at 180. It levels
    off after about an hour.
  - At 2.5 h, 256 VMs were alive: median 148.9 MiB, p95 233, max 292, sum 36.5 GiB.
  - Kept-forever VMs whose session ended on its own were destroyed within 1 s of their last Exec. Fix
    round 1's "outlive their last call by 12 min" was a run-end-cut artefact.
- **Driver (A2).** At most 0.10% of host CPU on any ladder or seed rung, and 0.005% on control N=768
  (11,944 calls, 0 failed).

## Admission as a calculation (SPEC §7.3; not a verdict)

This uses moca's default no-overcommit admission: 1,056 MiB per VM against 377 GiB, which is at most
365 live VMs.
- **Resident ∞** holds one VM per session, so default admission refuses it above N ≈ 365.
- **SBX** peaks at 0.67–0.74 live VMs per session in the window (693 at N=1024; 1,059 at 1536).
  Default admission refuses it above N ≈ 490–545.
- **Start-up spread.** The 60 s spread at the run's start peaked higher still (703 live VMs at the
  N=256 cal rung).
- **So:** under the default admission rule SBX would hold more sessions than resident ∞. E16's 4 TiB
  budget removes that effect on purpose (SPEC §1.2).

## Caveats

- **Distinct-trace share.**
  - It is 0.30–0.49 at N ≥ 896 in both arms, below SPEC §9's 60% flag.
  - The band has 456 sessions, so above about N=450 many recorded sessions replay twice or more at once.
  - At N=1536 only 30% of the sessions replayed in a window are distinct traces.
- **Censoring.** Both arms are censored at 1536, the top of the extended ladder: SBX on its post-seal
  rungs, resident on the staggered rungs. Neither arm's true limit on this host is known. Both are above
  1536.
- **What is sealed.** Only the sealed reading (§7.2: tie, so falsified) is a sealed verdict. These are
  supplementary:
  - the post-seal SBX extension;
  - the staggered resident re-run (an instrument change, opt-in);
  - the no-wedge re-judges.
- **Seed agreement.** Resident's sealed 896 and 1024 verdicts rest on seed majorities. In each case the
  dissenting seed was a wedged run.
- **Ranges.** The sealed numeric ranges (SBX [576, 768], resident [768, 1024]) were extrapolated from
  E15's p95-excess-vs-load slope. Both arms were far more linear and flatter than E15's default point
  predicted.

## Upstream moca findings

1. **Silent refusal.** "busy: queue full" is sent but never logged. The worker admits 256 + 64 = 320
   Execs per relay connection. The rest get an ExecError frame with no log line on either side: the
   relay audits only sandbox-token callers, and the E16 driver uses the exec token. 64 to 576 Execs per
   rung were refused with no trace in any log.
2. **A refusal burst drops the connection.** When more than 16 terminal frames are queued, the
   per-connection `TerminalReserve` (`QueueCap / 4`) overflows. `accept` returns `ErrEgressWedged`, and
   the worker ends the stream and reconnects. Every Exec in flight on that connection, unrelated to the
   burst, then fails with exit −1. Any caller that ends many workspaces at once can trigger it; here it
   was about 900 or more end-session Execs within a second.

## Files

- **Sealed ladders:** `experiments/e16-low-duty/results/{sbx,resident-inf}/ladder.json`; SBX's sealed assembly is
  `experiments/e16-low-duty/results/sbx/ladder.sealed.json`.
- **Per-rung rows:** `<arm>/e16/`.
- **Rungs:** `<arm>/N*/` (record, re-judges, params, calls/samples/worker logs gzipped, perf).
- **Supplementary:**
  - `<arm>/e16-supp/` and `<arm>/ladder-supp.json`;
  - `record_nowedge.json` and `stag_valid.json` beside the rungs they judge.
- **Calibration:** `experiments/e16-low-duty/results/calibration/`. **Long rung:** `experiments/e16-low-duty/results/resident-inf/N256-long/` and
  `experiments/e16-low-duty/results/vm-age/long-rung.{json,md}`. **Control:** `experiments/e16-low-duty/results/control/N768-a2/`.
- **Summary:** `experiments/e16-low-duty/results/summary.json` (`python3 experiments/e16-low-duty/analysis/results.py`).
- **Chain and tools:** `experiments/e16-low-duty/rig/` (`chain.sh` stages, `chainlib.py`, `pull.sh`, `sync.sh`).
