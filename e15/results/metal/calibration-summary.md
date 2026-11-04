# E15 metal calibration (SPEC §10.1) — summary

Host: AWS m7i.metal-24xl. It is bare metal with 96 vCPU (48 cores × 2 threads) and 377 GiB RAM.
Storage is an EBS gp3 data volume, XFS `reflink=1`, at `/srv/e15`. Profile `fresh-metal`.
The rig ran from branch `e15/metal-run`: 708d62f for the calibration chain, e964dd0 for the
resident warm-up-1200 repeat. Times are 2026-11-04 UTC, 02:00–18:30.

This is calibration only. No ladder, no `points.sh`, and no rung above N = 8 except control N = 128.

## 1. Command library, re-measured in a metal VM

- Method: Task 8's `measure_library.sh`. One resident 1024 MiB VM, 5 reps of every invocation, timed in the guest.
- Result: all 360 rows ok, every exit code as declared, the project tree clean afterwards.
- The metal library is `library.json` in this directory (sha256 `3c825138…`). It has the same invocations as `commands/library.json` (7c2bdc4b, AWS); only `run_ms`/`cpu_ms` differ.
- On every sync the host's `commands/library.json` is overwritten with it. Every metal rung ran with it, and the baseline hash guard ties all of them to it.
- `test_spread` (≥ 10× per class) passes. `unparsed` still has only 2 distinct `run_ms`, as on AWS.

| class | inv. | distinct run_ms | metal range (ms) | AWS range (ms) | Σmetal/ΣAWS | cpu/run |
|---|---|---|---|---|---|---|
| read | 4 | 3 | 2–52 | 3–72 | 0.73 | 93% |
| write | 8 | 8 | 2–822 | 3–1151 | 0.73 | 77% |
| search | 5 | 4 | 3–238 | 3–239 | 0.99 | 98% |
| test | 6 | 6 | 155–9605 | 152–9151 | 1.05 | 95% |
| interpreter | 5 | 5 | 85–26783 | 85–26087 | 1.03 | 100% |
| lint_check | 5 | 5 | 21–2408 | 22–2252 | 1.07 | 100% |
| vcs | 11 | 9 | 2–2477 | 3–2409 | 1.03 | 99% |
| shell_read | 8 | 6 | 2–496 | 3–517 | 0.95 | 98% |
| file_ops | 5 | 5 | 3–246 | 4–243 | 0.93 | 99% |
| wait | 3 | 3 | 102–10002 | 103–10003 | 1.00 | 0% |
| process | 3 | 3 | 2–1828 | 3–1828 | 1.00 | 2% |
| network | 3 | 3 | 4–4434 | 6–4278 | 1.04 | 100% |
| unparsed | 3 | 2 | 4–1358 | 5–1324 | 1.02 | 100% |
| other | 3 | 3 | 5–1357 | 5–1325 | 1.02 | 100% |

The guest runs the CPU work at about the same speed as on AWS: one guest vCPU either way. Small
invocations are a little faster on metal.

## 2. N=1 baselines and per-class probes

Full timing for every arm: warm-up 600 s, window 900 s. All five baselines skipped seeds 2 and 3
(`empty_window`) and pooled seeds 1, 4 and 5, which gives 40 calls. No class was undercovered and no
probe failed.

| point | arm | B (excess p95) | primary limit max(3B, 50) | abs limit B + 250 | N=1 overhead | n1 median pace |
|---|---|---|---|---|---|---|
| default | sbx | 115.1 ms | 345.2 ms | 365.1 ms | **+33.7 ms** | +0.07% |
| default | resident-inf | 126.2 ms | 378.5 ms | 376.2 ms | −27.8 ms | −0.20% |
| default | resident-300 | 123.8 ms | 371.4 ms | 373.8 ms | −26.0 ms | −0.20% |
| mem512 | sbx | 251.0 ms | 752.9 ms | 501.0 ms | +389.8 ms | +0.37% |
| mem512 | resident-inf | 130.2 ms | 390.7 ms | 380.2 ms | −18.1 ms | +0.03% |

For comparison, AWS (sealed) had SBX B 229 ms with overhead +186 ms, resident B about 285 ms,
and mem512 SBX overhead +1,589 ms.

**SBX per-call cost on metal is a fifth of AWS's.** The SBX class medians are about 0–80 ms;
on AWS they were 120–435 ms. The lifecycle phases are resume 18–20 ms and destroy 19–22 ms; on
AWS they were 73–78 ms and 106–108 ms.

Default class medians of added latency at N=1 (ms):

| class | sbx | sbx (AWS) | resident-inf | resident-300 |
|---|---|---|---|---|
| build | 40 | 309 | −32 | −34 |
| file_ops | −453 | −279 | −527 | −529 |
| host_infra | 54 | 300 | −14 | −14 |
| interpreter | 68 | 314 | −7 | −7 |
| lint_check | 57 | 308 | −26 | −26 |
| network | −28 | 135 | −88 | −89 |
| opaque | 61 | 327 | −12 | −14 |
| other | 1 | 199 | −49 | −48 |
| process | 4 | 189 | −49 | −48 |
| read | 34 | 186 | −13 | −14 |
| search | 22 | 201 | −28 | −26 |
| shell_read | −58 | 119 | −107 | −106 |
| test | 78 | 415 | −13 | −5 |
| unparsed | −58 | 141 | −117 | −107 |
| vcs | 53 | 333 | −14 | −18 |
| wait | −19 | 178 | −61 | −61 |
| write | 55 | 312 | −8 | −9 |

At mem512, SBX's scanning classes are +390 to +542 ms (AWS: +1,589 to +1,844 ms). That is the
512 MiB re-read from the host page cache.

## 3. Control N=128 (A2)

The control rung holds, with 2,997 window calls and 0 failures. **A2 = 0.0016% of host CPU**
(AWS: 0.056%). The driver used 1.41 core-s over the window.

## 4. Inputs to the predictions

| input | sbx | resident-inf | how |
|---|---|---|---|
| core-s per call, default N=8 (warm-up 600) | **3.599** | **3.548** | Δ e15-vms.slice CPU ÷ 132 window calls (same seed, same calls in both arms) |
| SBX − resident per call | 0.052 | | AWS: 0.218 |
| lifecycle no-op bench | **0.031 core-s/Exec** | | 100 × `true`, idle host (AWS 0.099). Resume 17.9 ms, destroy 19.4 ms |
| VM footprint, default N=8, warm-up 600 | | median **97.2**, max 184.9 MiB | VMs 40, 59, 60, 76, 119, 149, 177, 185 |
| VM footprint, default N=8, warm-up 1200 (e964dd0) | | median **114.1**, max 184.9 MiB | VMs 39, 60, 63, 75, 153, 173, 177, 185 |
| VM footprint, mem512 N=8 | | median **1,023.7**, max 1,023.9 MiB | at the 1024 MiB guest cap (data.bin cached) |
| core-s per call, mem512 N=8 | 4.060 | 3.620 | |
| usable memory (MemAvailable at t0 − 1536 − 1024) | | 377,575 MiB | |
| disk_read_max | 1,017.2 MB/s (4 × direct) | | bring-up measurement, kept |
| host CPU mean at N=8 | 0.6% | | |

The N=8 calibration rungs:

| rung | holds / holds_abs | p95 excess | primary / abs limit | failures | class pace | footprint drift |
|---|---|---|---|---|---|---|
| default sbx N8 | true / true | 131.8 ms | 345.2 / 365.1 | 0 | +0.01% | n/a |
| default resident-inf N8 (600) | true / true | 94.0 ms | 378.5 / 376.2 | 0 | 0.0% | median **+29.5%** (repeat), sum +7.2% (no repeat) |
| default resident-inf N8 (1200, e964dd0) | true / true | 88.3 ms | 378.5 / 376.2 | 0 | 0.0% | sum +7.6% (basis), median +17.6% |
| mem512 sbx N8 | **false / false** | **1,894.8 ms** | 752.9 / 501.0 | 0 | +0.01% | n/a |
| mem512 resident-inf N8 | true / true | 96.0 ms | 390.7 / 380.2 | 0 | 0.0% | −0.01% |

## 5. The resident drift concern from bring-up

- **It recurs with the full 600 s warm-up when judged on the median.** At N=1, seeds 4 and 5
  drifted +19.9% and +16.2%. At N=8 the drift was +29.5%. AWS N=1 showed the same pattern
  (+16.7% on seed 4).
- **The cause is the median, not runaway growth.**
  - The worker reuses VM cgroup names (`pool-k`) across sessions, so the median of a few VMs
    of mixed ages jumps whenever one session starts a heavier command.
  - A VM reaches 90% of its final size at a median age of about 380 s, with a range of 55–970 s.
  - The **summed** VM memory settles to within 10% over the next 900 s from t ≈ 480 s.
  - At N=8 the sum moved +7.2% over the window, while the median moved +29.5%.
- **Decision (user, 2026-11-04), implemented in 07ab661 and e964dd0, fresh-metal only:**
  - drift is judged on the summed VM memory, and the median drift is still reported;
  - resident rungs warm up 1200 s.
- **Live check:** the e964dd0 repeat warmed up 1200 s. It drifted +7.6% on the sum (no repeat)
  and +17.6% on the median.

## 6. mem512 SBX fails at N=8 on an idle host

- Host CPU was 0.7% and the disk mean 5.6 MB/s. There were 0 failures.
- The p95 is set by about 8 of 132 calls. Each is the **first scan of a new session**: it reads
  that session's fresh 512 MiB `data.bin` from EBS at about 230 MB/s and adds about 2.5 s. Later
  scans are served from the host page cache in about 0.5 s.
- The per-class probe shows the same: call 1 of every scanning class is about 2.5 s, and the
  rest are about 0.5 s. So the class median absorbs only the warm cost.
- Sessions keep starting through the window, because a slot replaces a finished session with a
  fresh workspace. A longer warm-up therefore does not remove the effect.
- Cold scans are about 6% of window calls at any N, since session starts and window calls both
  scale with N. So SBX is expected to fail mem512 at every N above 1.
- The AWS calibration saw a narrow N=8 failure as well (912 vs 896 ms).

## 7. Burst-aware N_max model (coordinator item 1)

- **Why.** On AWS the average-CPU model predicted SBX N_max of 40–48, but every arm measured
  n_max = 8. The rungs failed on the p95 tail at about 41% mean host CPU, with 0 failed calls.
- **What the model is** (`burst_model.py`, logs in `burst-model/`):
  - a processor-sharing replay of the default corpus;
  - CPU demand per call from the library's cpu/run, scaled to the measured core-s per call;
  - at most 1 core per call, because guests have 1 vCPU;
  - `eff × vCPU` cores shared between the calls in service;
  - the p95 of added latency judged against each arm's primary limit.
- **The fit.** `eff` is the one free parameter. It is fitted on the preliminary result: all
  arms hold at N=8 and fail at N=16. That gives eff 0.50–0.60, about the number of physical
  cores per vCPU (the hosts have 2 threads per core).

| method | sbx | resident-inf |
|---|---|---|
| **burst model (recommended)**, eff 0.50–0.60 × 96 | **[448, 576]** | **[448, 576]** |
| pessimistic: avg-CPU × AWS factor (8 ÷ avg bound = 0.15–0.17) | [187, 236] → ladder [160, 192] | [179, 226] → ladder [160, 192] |
| average-CPU bound, 96 × [0.8, 0.9] (information) | [1223, 1376] | [1241, 1396] |
| resident memory bound | | [2042, 3309] |

The two arms differ by 0.052 core-s per call (1.5%), so calibration expects a CPU tie at the
default point.

## 8. Caps on the extended metal ladder (coordinator item 2)

| cap | value | binds at N |
|---|---|---|
| `SH_MAX_RUNS` (unparked runs) | 2048 (d80c1c7; was 512) | resident-inf 2048; SBX about 4500 (0.45 unparked runs per session) |
| `WORKER_MAX_CONCURRENT` + QueueCap 64 | 256 | concurrent Execs > 320 ("busy: queue full"); 0.09 in flight per session gives about 3500; reached only in collapse |
| `SH_MAX_COMMITTED_MB` | 1 TiB | resident-inf 992 (1056 MiB per VM); SBX about 1100 |
| host memory, resident footprint | 377 GiB usable | default about 2040; mem512 **368** |
| disk free (N × 16 deltas + 10%) | 289.5 GiB | default 753, mem512 434 (rung.sh refuses) |
| EBS 1017 MB/s (mem512, uncached) | | SBX about 170, but only past the page cache (about 737 sessions of datasets) |
| relay `SH_SANDBOX_MAX_INFLIGHT` | 1024 | concurrent Execs > 1024 |
| relay CPU (one Node thread) | 0.0116 core-s/call | about 4900 |
| driver, fds, pids | NOFILE 1048576, pid_max 4M, TasksMax ∞ | none below 1024 |
| ladder top | 1024 (e964dd0) | 1024 |

The metal ladder (e964dd0) runs 1 … 128, then 160, 192, 256, 320, 384, 448, 512, 576, 640, 704,
768, 896 and 1024. Below about 750, no cap binds before the predicted CPU wall.

## 9. Draft metal N_max (predictions-metal.json, NOT sealed, not committed)

| prediction | draft |
|---|---|
| 1 binding | SBX CPU. Resident ∞ is also expected CPU-bound (concern: the resident half is expected to be falsified) |
| 2 default N_max | SBX [448, 576], resident ∞ [448, 576]; pessimistic [160, 192] each. Concern: a tie |
| 3 resident 300 s | [448, 576], within one step of SBX |
| 4, 5 | not run on metal (SPEC §13 metal procedure) |
| 6 A2 | < 1%; measured 0.0016% at N=128 |
| 7 method | unchanged, plus the metal procedure. Abs test: SBX overhead +34 ms against B + 250 = 365 ms, so n_max_abs is expected to track n_max |
| 8 ratio | AWS ratio 8/8 = **1.0** primary (abs 1/8 = 0.125). Metal draft [0.78, 1.29]. Concern: about 1, so it is expected to tie or be falsified on the primary verdict and to rise on abs |
| 9 mem512 | resident ∞ [320, 320], memory-bound (368 VMs at 1 GiB); SBX **[1, 1]** (N=8 measured fail, cold first scan). Concern: the "SBX holds more" half is expected to be falsified |

## 10. Notes for the metal ladder

- Setup at e964dd0 rebuilt both workspace templates. Their stamp is `src_key(commands/)`, and
  that now includes the metal library. The project commit (8c1a6ef), the sizes and the seed are
  the same, but the template sha256 differs from the one the baselines ran on. The baseline guard
  does not check it.
- AWS Task 9 records were not reachable from here. The AWS fit uses the coordinator-reported
  n_max values. Refit when Task 9 pulls its records.
- The host is left set up: relay, Redis and the slices are running, with no worker and no VMs.
