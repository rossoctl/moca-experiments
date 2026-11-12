# E17a report — does a warm guest pay, before the lease is built?

Date: 2026-11-12. Spec: `e17/SPEC.md` v0.5. Predictions: `e17/predictions.json`, sealed
2026-11-12T01:57:57Z. Rig: the E15/E16 metal host (AWS m7i.metal-24xl, 96 vCPU, 377 GiB), profile
`fresh-metal`, 1024 MiB guests. Lease stand-in: the E15 resident patch with a 300 s idle timeout
(`resident-300` = `lease-300`). It reuses the parked shell and kills no process, so every lease number
here is an upper bound on level 1 (spec §3).

**Verdict: E17a misses.** Criterion 2 fails at N = 1 and at N = 128: the stack import gains about 40%
and the venv grep about 0%, against a 50% bar. Short commands gain about 90%. Criterion 1 holds: at
the default point lease-300 holds 128 sessions against per-`Exec`'s 80 (E15 metal, reused). By
spec §7.5 the miss goes to the user before the build. It does not go into a rerun.

## 1. What ran

| Step | Rungs | Where |
|---|---|---|
| N = 1 calibration (`baseline.sh`): seeds 2, 3, 6, 7 evaluable per arm (1, 4, 5 empty windows), 8 class probes | `sbx`, `resident-300` at `pycache` | `calibration/v0.4/` |
| Diagnoses: guest check of `py_import`/`py_grep`, page-cache eviction (`grepdiag`), new-VM host cache (`hostcache`) | one-off guests | rig `~/e17-manifest.md` |
| Latency rung pair, `pycache` N = 128 (1200 s warm-up, 900 s window) | `sbx`, `resident-300` | `e17a/n128/` |
| Capacity at `default` | E15 metal ladders reused: driver `4971f732`, workers `904f7322`/`47a3a7f0`, resident patch `1d0ce8b1`, corpus `24050ae8`, library `3c825138`, template stamp `7d8a638b`, same snapshot and profile | `e15/results/metal/default/` |

Not run, by the user's decision at the seal: `pycache-low`, the gain against `D`, the 256 MiB guest
runs, and the lease-30/lease-120 ladders. Raw run output (calls, samples, worker logs) is on the rig
for the `data-v2` archive. Only summaries are in git.

## 2. Latency (question 1)

Gain = 1 − (lease warm median ÷ per-`Exec` median), in-window ok calls (`e17/analysis/latency_report.py`).

| Class | N = 1 per-`Exec` | N = 1 warm | **N = 1 gain** | N = 128 per-`Exec` | N = 128 warm | **N = 128 gain** | Gated |
|---|---|---|---|---|---|---|---|
| `py_short` (`grep`/`sed`/`head` on project files) | 53 ms | 6 ms | **0.89** | 60 ms | 5 ms | **0.91** | yes, ≥ 0.50: pass |
| `py_import` (numpy, pandas, scipy, sklearn) | 755 ms | 454 ms | **0.40** | 900 ms | 520 ms | **0.42** | yes: **miss** |
| `py_grep` (`grep -r` over the venv) | 1960 ms | 2000 ms | **−0.02** | 2013 ms | 1987 ms | **0.01** | yes: **miss** |
| `py_analyze` (CSV parse + KMeans) | 15.6 s | 14.4 s | 0.08 | 18.5 s | 16.8 s | 0.09 | no |
| `py_test` (numeric pytest) | 61.2 s | 61.0 s | 0.00 | 68.6 s | 67.0 s | 0.02 | no |

Warm share (lease-300): 0.907 at N = 1, 0.870 at N = 128. Neither N = 128 rung holds, both on
condition 4 alone (no failed calls, no refusals). The class-matched p95 excess is 7.35 s for per-`Exec`
(limit 794 ms) and 6.66 s for the lease (limit 335 ms). Both arms' heavy calls ran 10–20% slower at
N = 128 than at N = 1, at about 15% host CPU. The lease's compute classes slowed slightly less (gain
0.09 and 0.02 against 0.08 and 0.00 at N = 1).

### Why

- **Short commands:** a VM start is most of their cost. The lease removes it.
- **Import:** about 450 ms of a warm import is Python unpacking and initialising the stack, which no
  cache removes. The lease saves only per-`Exec`'s fresh VM and cold guest cache, about 300 ms.
- **Grep:**
  - A per-`Exec` VM reads the workspace through the **host** page cache. Its later greps on a workspace
    took 388 ms, against about 2.2 s for the first touch of a freshly copied workspace. A warm
    lease guest took 112 ms (medians of the 20-call class probes).
  - A lease keeps a file set warm only while one guest lives from one grep to the next, which is a
    whole agent turn. On the corpus's gaps (median 18 s, p90 234 s), 32% of a session's greps would do
    so at 300 s (corpus calculation).
  - At N = 128, most in-window greps in both arms were a workspace's first touch: each rung starts from
    fresh copies, and a session runs about one grep per 15-minute window. That puts both medians on the
    2 s cold read.
- **Replaced lease VMs read cold.** In the calibration, a lease VM that replaced one ended by the idle
  timeout took about 2 s for a grep that per-`Exec` served in 388 ms. A clean check where the ended VM
  had run only two greps gave 0.49 s. The probable cause, not measured directly, is the per-VM cgroup
  `memory.max` (`PerVMBytes`). The ended VM had filled it, so the host page cache charged to it was
  reclaimed. This is not specific to the patch: the shipped lease runs in the same cgroups.

## 3. Capacity (question 2)

E15 metal at `default` (9.5% duty, trace corpus), reused under the spec's rule: per-`Exec` `N_max` 80,
lease-300 128. **Criterion 1 holds.** That workload's VMs stay near 150 MiB (E16).

## 4. Memory

Lease VMs fill their guest RAM on this workload:
- **N = 1:** every lease VM peaked at 1023.98 MiB (5 of 6 above 900 MiB).
- **N = 128:** median peak 1024 MiB, with 79% of 128 VMs above 900 MiB.

After `analyze.py` and `pytest` the guest still had about 800 MiB available, so most of the peak was
memory the guest had already freed. No balloon is configured, so nothing returns it to the host. On
this workload, a measured charge therefore comes out close to a full guest-RAM charge.

## 5. Predictions against results

| # | Prediction (short) | Result | Verdict |
|---|---|---|---|
| 1 | Criterion 2 fails | Fails at N = 1 and N = 128 (import, grep) | **Holds** (verdict part) |
| 1 | Numeric: `py_short` [0.75, 0.95]; `py_import` [0.25, 0.50); `py_analyze` [−0.05, 0.15]; `py_test` [−0.05, 0.05] | 0.89/0.91; 0.40/0.42; 0.08/0.09; 0.00/0.02 | Holds |
| 1 | Numeric: `py_grep` gain < 0, lease warm median [1500, 2500] ms, per-`Exec` median [300, 700] ms | gain −0.02/0.01; warm 2000/1987 ms; per-`Exec` 1960/2013 ms | **Falsified**: the per-`Exec` median and the N = 128 gain sign. The rung's first-touch share was not modelled |
| 2 | `sbx` [64, 96], lease-300 [112, 160], lease-300 ≥ `sbx` + one step | 80, 128 (E15 reuse) | Holds. lease-30/lease-120 not run |
| 3 | lease-300 warm share [0.86, 0.95] | 0.907 / 0.870 | Holds. The lease-30 part was not run |
| 4 | ≥ 80% of lease VMs > 900 MiB, median peak [950, 1024] MiB | N = 1: 83%, 1024; N = 128: 79%, 1024 | **Falsified at N = 128 by one point** (share); median holds |
| 5 | E17b level-1 overhead [2, 50] ms | — | Not judged (E17b) |
| 6 | Driver < 1% of host CPU | 0.0016% / 0.0014% | Holds |

## 6. What this means for the build

The lease design was revised in response (rossoctl/moca#718, lease spec v0.2 and the ADR-0048 revision
of 2026-11-12):
- level 1 is re-scoped to short and import-bound commands and to capacity at mid duty;
- free-page reporting is in v1;
- lease VMs get page-cache headroom in their cgroup;
- the idle timeout and the memory model are set together;
- level 2 is named as the latency case, to be sized before its security review.

The build decision for plans 2–5 is the user's (spec §7.5).
