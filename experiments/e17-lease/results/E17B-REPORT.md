# E17b report — does the shipped lease mode pay, and does measured admission hold?

Date: 2026-11-19. Spec: `experiments/e17-lease/SPEC.md` v0.6. Plan: `PLAN-E17B.md`. Predictions:
`predictions-e17b.json`, sealed 2026-11-17 (`0688ec6`, code `46cd283`), with the post-seal deviations
R46–R55 in its `deviations` list. Rig: the E15/E16/E17a metal host (AWS m7i.metal-24xl, 96 vCPU,
377 GiB), profile `fresh-metal`, 1024 MiB guests. Code under test: moca `c3adf490` (lease plans 2–5,
all merged), stock `microvm-worker`, lease mode on. Arms: `sbx` (per-`Exec`) and `ship-30`, `ship-120`,
`ship-300` (shipped lease mode, idle timeout 30/120/300 s, standby depth 2, E17B-R44).

**Verdict: criteria 1–4 pass; criterion 5 passes its second half and misses its first.** At the default
point the shipped lease holds 128 sessions against per-`Exec`'s 80. Warm short commands are about 87%
faster and warm imports about 41–47% faster than per-`Exec`, at N = 1 and N = 128. Under a memory squeeze
every one of 551 reclaims took the idle-longest lease, with no refusal while an idle lease existed and no
memory-guard event. Every lease end has its notice. A replacement lease reads its workspace from the
host page cache (0.19–0.88× per-`Exec`'s time). But a lease VM's charge does not fall back to its working
set after a heavy command: free-page reporting returns the command's anonymous memory, and the page cache
stays (pinned share 0.54 against the sealed 0.50 bar). That miss was predicted at the seal.

## 1. What ran

| Step | Rungs | Notes |
|---|---|---|
| Bring-up (Task 12) | smoke, calibration baselines at `default` and `pycache` for `sbx`, `ship-300`; lease KVM gates 56/0/0; ownership-walk smoke | `results/bringup/`; R43 (rootfs tool list), R44 (standby depth 2) |
| Squeeze (criterion 3) | baselines; ship-300 climb N = 1, 8, 16, 24, 32, 40 under `MemoryMax` 24576 MiB; `sbx` at N = 40 | R48 (MemoryMax from three N = 16 checks), R51 (the climb resumed at N = 24 after a disk-preflight rig error; `ladder.json` assembled from both parts) |
| Latency (criteria 2, 5) | `pycache` N = 1 (pooled with the calibration seeds, R52) and N = 128, `sbx` and `ship-300`; N = 128 `ship-30`, `ship-120` | R53 (same-second restores resolved from the samples) |
| Capacity (criterion 1) | default ladders: `sbx` from N = 56, `ship-300` from N = 80 (R50) | R54 (end-of-run cut ends excluded from criterion 4) |
| §7.4 probes | level-1 overhead; ownership walk at 10 000 and 100 000 files | R55 (500 000 files not measurable: moca#907) |

Not run: `pycache-low` (R47: its N = 1 baseline is unattainable as specified), the 256 MiB stages (R45:
`py_analyze` is OOM-killed in a 256 MiB guest in both arms), the optional `ship-30`/`ship-120` ladders, and
the SBX0 smoke (SBX0 down; on hold by the user). The stages were reordered so the release-relevant criteria
came first (R46). Raw run output is on the rig for the next `data-v*` release; only summaries are in git
(`results/e17b/`).

## 2. Criteria

| # | Criterion (SPEC §7.5) | Result | Inputs |
|---|---|---|---|
| 1 | `ship-300` N_max ≥ `sbx` N_max at `default` | **pass**: 128 against 80 | `results/e17b/ladders/default/*/ladder.json` |
| 2 | warm `py_short` gain ≥ 0.50 and `py_import` ≥ 0.30 at `pycache`, N = 1 and 128 | **pass**: 0.86 / 0.47 (N = 1), 0.87 / 0.41 (N = 128) | `verdict.json` criteria.2 |
| 3 | at `squeeze`: zero memory-guard events, zero refusals while an idle lease existed, every reclaim of the idle-longest lease | **pass**: 551 reclaims, 0 wrong, 0 unknown, 0 victim executing; 0 refusals with an idle lease; 0 OOM, 0 memory-floor aborts | criteria.3; memory.high reported, not judged (R49) |
| 4 | every lease end has exactly one matching notice | **pass** (R16 met): 42 rungs true, 0 false, 0 invalid, 55 vacuous | criteria.4; 2 ends by the run's cut excluded (R54) |
| 5a | a lease VM's charge falls back toward its working set after a heavy command | **miss**: share following 1.0 (78 of 78 judged; bar ≥ 0.50) but pinned share 0.536 (709 of 1323 readings at ≥ 0.9 of guest RAM 15 s after; bar ≤ 0.50) | criteria.5 first half |
| 5b | a replacement lease reads its workspace from the host page cache | **pass**: ratio to `sbx` 0.19–0.88 (bar ≤ 1.5) | criteria.5 second half |

## 3. Latency (criterion 2)

Gain = 1 − (lease warm median ÷ `sbx` median), in-window ok calls (`analysis/latency_report.py`).

| Class | N = 1 `sbx` | N = 1 warm | **N = 1 gain** | N = 128 `sbx` | N = 128 warm | **N = 128 gain** | Gated |
|---|---|---|---|---|---|---|---|
| `py_short` | 55 ms | 8 ms | **0.86** | 62 ms | 8 ms | **0.87** | ≥ 0.50: pass |
| `py_import` | 944 ms | 501 ms | **0.47** | 917 ms | 545 ms | **0.41** | ≥ 0.30: pass |
| `py_grep` | 400 ms | 200 ms | 0.50 | 1626 ms | 304 ms | 0.81 | reported |
| `py_analyze` | 16.7 s | 14.6 s | 0.13 | 18.9 s | 16.5 s | 0.13 | reported |
| `py_test` | 63.3 s | 60.9 s | 0.04 | 68.4 s | 66.0 s | 0.04 | reported |

Warm share at `pycache` N = 128: `ship-300` 0.90, `ship-120` 0.84, `ship-30` 0.61. A call that follows an
idle end pays a restore and the ownership walk: `ship-30`'s first `py_short` after idle takes 94 ms
(median, 138 calls) against `sbx`'s 62 ms.

**Against E17a's resident patch:** `py_short` 0.89–0.91 then, 0.86–0.87 now; `py_import` 0.40–0.42 then,
0.41–0.47 now. The level-1 kill, fresh shell and privilege drop cost a few milliseconds (§6). The shipped
lease differs most on `py_grep`: E17a measured −0.02 / 0.01, E17b 0.50 / 0.81. A grep in a replacement
lease now reads the host page cache (§5) instead of a cold image, which E17a's per-VM `memory.max` had
evicted.

## 4. Capacity (criterion 1)

| Arm | N_max | First failed rung | Why it failed |
|---|---|---|---|
| `sbx` | 80 | 96 | added latency: p95 excess 415 ms against a 349 ms limit (no failed calls, no refusals, no binding) |
| `ship-300` | 128 | 160 | condition 4 (added latency); N_max_abs 96 |

E15 on the same host: `sbx` 80, `resident-300` 128. At N = 96 the lease's p95 excess was 243 ms against
`sbx`'s 415 ms: a warm lease skips the restore and the cold workspace reads (disk read p95 3.5 MB/s
against 19 MB/s). No lease VM at `default` peaked above half its guest RAM (N = 80–160). Both ladders
started two steps below E15's N_max (R50); the rungs below are assumed held.

## 5. Memory (criterion 5)

**Charge (5a, miss).** Free-page reporting works: every judged heavy command (growth ≥ 64 MiB, a measured
guest Shmem delta) returned at least half its freed growth within 15 s. But at `pycache` a lease VM settles
at 0.9–1.0 GiB and stays there, also through idle minutes: the guest's page cache (dataset, venv) and the
host page cache of the workspace image charged to the VM's cgroup are never reported free. At N = 128,
62% of `ship-300`'s lease VMs peaked above 90% of their RAM. The budget charges a lease its measured
`memory.current` × 1.25, so on a memory-bound host a lease costs more than a per-`Exec` VM's fixed share.

**Replacement (5b, pass).** A lease that replaced one ended by the idle timeout ran its first `py_grep`
in a median 304 ms at N = 128, against `sbx`'s 1626 ms (ratio 0.19). Across the rungs with an `sbx` pair,
the ratio is 0.19–0.88.

## 6. Reclaim and notices (criteria 3, 4)

| Squeeze rung (the one counted) | N | Reclaims | Wrong | memory.high (reported) |
|---|---|---|---|---|
| N1-repeat | 1 | 0 | 0 | 0 |
| N8-repeat | 8 | 0 | 0 | 0 |
| N16-repeat | 16 | 7 | 0 | 16 |
| N24-repeat | 24 | 97 | 0 | 411 |
| N32-repeat | 32 | 171 | 0 | 835 |
| N40-repeat | 40 | 276 | 0 | 18 026 |

The climb stopped at N = 40, the first rung with a reclaim in every minute of its window. `sbx` at
N = 40: no OOM, no memory abort. No refusal while an idle lease existed, on any rung.

**memory.high (R49).** The squeezed `e15.slice` holds 5–7.5 GiB outside every live VM: page cache that
destroyed VMs' cgroups leave in the slice, which the worker's budget does not see. At a tight squeeze it
reaches the slice's `memory.high` and the kernel throttles the slice. moca's shipped slices are
`MemoryMax=infinity` (`deploy/microvm/microvm-vms.slice`, `deploy/sbx/sbx.slice`), so this cannot happen
in production; by the user's decision before the climb's data it is reported, not counted as a guard
event. Counted, it would fail criterion 3.

**Notices.** Across 97 lease rungs, every end has exactly one notice. Two ends are excluded by the run's
cut (R54): at its end-of-run deadline the driver cut two long in-flight commands and exited, and moca ends a
lease whose Exec was aborted as `agent_dead` (`lease.go` `runLease`, by design). All three `agent_dead`
ends of E17b lie within 1 s of their worker's stop; none happened mid-session.

## 7. §7.4 probes

- **Level-1 overhead:** median 3.1 ms per call over the 17 default probe classes, `ship-300` against the
  E15 metal `resident-300` baseline (`results/e17b/overhead.json`; comparable: same corpus and library).
- **Ownership walk** (A − B, 5 repeats each, inferred not observed: R28): 91 ms at 10 000 files, 756 ms at
  100 000 (about 7.6 µs per file). 500 000 files needs a 4096 MiB workspace, which a guest restored from
  a snapshot with a 2 GiB workspace drive cannot mount (moca#907, R55).

## 8. Predictions (sealed file, scored)

| # | Prediction | Result |
|---|---|---|
| 1 | criterion 2 holds; `py_short` [0.75, 0.95], `py_import` [0.30, 0.50]; reported `py_grep` [0.30, 0.80], `py_analyze` [−0.05, 0.20], `py_test` [−0.05, 0.10] | **holds**, except `py_grep` at N = 128 (0.81, just above its range) |
| 2 | criterion 1 holds; `sbx` [64, 96], `ship-300` [96, 160], at least one step apart | **holds** (80, 128) |
| 3 | warm share `ship-30` [0.50, 0.70], `ship-120` [0.78, 0.90], `ship-300` [0.86, 0.96]; `ship-30` first-after-idle `py_short` ≥ `sbx`'s | **holds** (0.61, 0.84, 0.90; 94 ms ≥ 62 ms) |
| 4 | criterion 5a fails; pooled pinned share [0.60, 1.00], share following ≤ 0.25, half of `ship-300`'s lease VMs above 900 MiB, none above 50% at `default` | **falsified in its ranges**, verdict right: pinned 0.536, following 1.0 (VMs return anonymous growth; the cache stays); 62% above 900 MiB and 0% at `default` hold |
| 5 | criterion 5b holds; ratio [0.4, 1.2] | **falsified low**: 0.19–0.88 (better than predicted under load) |
| 6 | level-1 overhead [0, 20] ms | **holds** (3.1 ms) |
| 7 | criterion 3 holds | **holds** (with R49) |
| 8 | criterion 4 holds | **holds** (with R54) |
| 9 | ownership walk [50, 150] ms at 10k, [0.4, 1.5] s at 100k, [2, 8] s at 500k | **holds** at 10k and 100k; 500k not measured |
| 10 | driver under 1% of host CPU | **holds** (worst rung 0.03%) |

## 9. Findings for moca

1. **The memory charge does not follow the working set** (criterion 5a). Drop the guest's clean page cache
   when a lease goes idle (or inflate the balloon before reporting), and stop charging a lease for the host
   cache of its workspace image. This is the change that would bring lease density toward the resident
   patch's on memory-bound hosts. v0.12.0.
2. **The worker's budget does not see page cache charged to its slice** outside live VMs (the squeeze's
   5–7.5 GiB). Harmless with the shipped `MemoryMax=infinity` slices; it matters to any operator who
   bounds the slice. v0.12.0.
3. **Aborting a lease's running command ends the lease** (`agent_dead`). A client Ctrl-C costs the warm VM
   and its level-2 processes. A softer path would kill the command's cgroup and keep the lease, as the
   guest-timeout path already does. v0.12.0.
4. **A workspace larger than the snapshot's 2 GiB drive leaves the worker unattached** (moca#907):
   `SH_WORKSPACE_IMAGE_MB` / `SBX_WORKSPACE_IMAGE_MB` above 2048 has no guard.
5. **Small guests.** In a 256 MiB guest the lease's per-command cap leaves about 166 MiB, and `py_analyze`
   is OOM-killed in both arms (R45). Not lease-specific, but a lease on small guests needs its workload
   sized for the cap.

## 10. Recommendation

Shipping lease mode in v0.11.0 as opt-in (`SH_SANDBOX_MODES_ALLOWED` defaulting to `per-exec`) is
supported by these results: it is correct under memory pressure (criterion 3), its notices are complete
(criterion 4), it holds more sessions than per-`Exec` at the default point (criterion 1), and it is faster
for the commands it targets (criterion 2). Turning it on for a cohort also needs the SBX0 live smoke and the
security-review §11 sign-off, which E17b does not replace. The decision stays the user's. Items 1–3 above
are v0.12.0 work, with `pycache-low`, the 256 MiB stages and the 500 000-file walk re-run then.
