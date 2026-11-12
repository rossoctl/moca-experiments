# E17 — lease mode: does a warm guest with an idle timeout pay, and does measured admission hold?

Version: 0.6, 2026-11-12
2026-11-12 (later): E17a is built, run and reported — it misses (`experiments/e17-lease/results/E17A-REPORT.md`; §7.5).
Criterion 2 fails at N = 1 and N = 128 (import ~40%, grep ~0%); criterion 1 holds (E15 metal:
lease-300 128 against per-`Exec` 80). The miss went to the user, as sealed: on 2026-11-12 the user
approved the plans 2–5 build (plan 2 is rossoctl/moca#763) with the revised design (rossoctl/moca#718,
lease spec v0.2 and the ADR-0048 revision of 2026-11-12). This version records that decision:
free-page reporting is in v1 and replaces the no-balloon assumption (§1 question 3, §2, §6); E17b's
criterion 2 is re-scoped to level 1's revised targets, short and import-bound commands (§7.5); E17b
measures free-page reporting and the page-cache headroom (§7.1, §7.3), the direct fixes for E17a's
full-guest charge and its cold replacement VMs.
Version: 0.5, 2026-11-12
2026-11-12: predictions sealed (`experiments/e17-lease/predictions.json`). User decision: E17a's latency rungs are cut to one pair,
`pycache` N = 128, `sbx` and `lease-300`; criterion 1 reuses E15's metal `default` ladders when the driver, corpus
and profile match. The N = 1 calibration answers the latency question at N = 1 (§8, §12).
Version: 0.4, 2026-11-11
2026-11-11 (later): `pycache-io` dropped — its feasibility gate failed (§8: `analyze.py` at CPU scale 1, `D` =
768, warm only 3.6% faster than cold; the 768 MiB CSV parse is itself compute). A second probe (§1.1) found
where a warm guest pays: importing the stack (1.98 → 0.53 s) and `grep -r` over the venv (2.17 → 0.08 s).
User decision: add those two operations as classes `py_import` and `py_grep` to every `pycache` turn,
regenerate the corpus and rebuild both N = 1 baselines; criterion 2 is restated per class (§7.5).
Version: 0.3, 2026-11-11
2026-11-11: point `pycache-io` added (§4.3; user decision after the calibration preview in §1.1): the same
project at `D` = 768 MiB with `analyze.py`'s CPU scale at 1, so its time is mostly reading and parsing the
dataset and importing the stack. Criterion 2 is proposed per point (§7.5), sealed with the predictions. A
feasibility gate (§8) runs before its calibration.
Version: 0.2 (draft for review), 2026-11-10
2026-11-10: E16's final result folded in (§1.1). The `lowduty` capacity ladder is dropped: E16 already
answers question 2 at low duty, so E17's rig time goes to the cache-heavy points instead (§7.2, §8). The
level-1 lease guest (moca plan 1, rossoctl/moca#706) is merged, so E17b's guest side exists.
Status: **E17a complete (missed, §7.5). Plans 2–5 approved and in build (user, 2026-11-12); E17b not
started.**
Parents: E15 (`experiments/e15-session-density/SPEC.md`, metal procedure in its §13; results in `experiments/e15-session-density/results/metal/RESULTS-METAL.md`)
and E16 (`experiments/e16-low-duty/SPEC.md`, results under `experiments/e16-low-duty/results/`). E17 reuses their instrument, rig scripts and
metal host unchanged except where this document says so. "E15 §n" and "E16 §n" refer to those specs.
Design under test: moca `docs/specs/2026-11-08-sbx-lease-mode-design.md` (SBX0.3, "the lease spec"),
whose §10 names E17 and its pass criteria.
Rig: the E15/E16 metal host, AWS m7i.metal-24xl (96 vCPU, 377 GiB, bare metal).

---

## 1. The questions

1. **Does lease level 1 pay?** On a workload that re-reads data and reruns CPU-heavy Python in one
   project, is a warm command clearly faster than a per-Exec command, and by how much after host load?
2. **Does it cost capacity?** Does lease mode (idle timeout 30 s, 120 s, 300 s) hold at least as many
   sessions per host as per-Exec at the default point (9.5%)? At low duty (about 1.5%) E16 already
   answers it (§1.1).
3. **Does measured admission hold?** With lease VMs charged measured memory, and with virtio-balloon
   free-page reporting returning the pages the guest has freed (lease spec §6; decision 7 as revised
   2026-11-12), does reclaim keep the host safe when lease VMs grow toward their guest RAM? E17b
   measures what the reporting leaves (§7.3).
4. **Does the shipped lease mode behave as specified?** Reclaim order, fallback to per-Exec, and a
   notice for every lease end.

### 1.1 Why it could go either way

- For: E15 metal showed resident with a 300 s idle timeout at `N_max` 128 against per-Exec 80, with
  per-Exec long calls running slower at equal host CPU (per-VM cold state). Resident 300 s matched
  resident ∞ on every reading.
- Neutral at low duty: E16 (`experiments/e16-low-duty/RESULTS.md`, `c8dba13`) found that at a 1–2% duty cycle, with
  physical memory as the only memory limit, **the arms do not separate**:
  - the sealed verdict is a tie (per-Exec ≥ 1024 censored, resident ∞ 1024);
  - post-seal and staggered, both arms reach ≥ 1536;
  - resident ∞'s only failures were the instrument's run-end egress wedge, not the host;
  - resident ∞ summed VM memory was 106 GiB at N = 1024, against 377 GiB.

  So a warm guest neither gains nor costs capacity at low duty on the trace workload. The case for a
  lease rests on the cache-heavy latency gain (question 1) and on the default point (question 2).
- **Calibration preview (2026-11-11, not sealed; N = 1, `pycache`, 4 seeded `sbx` runs and 1 `resident-300`
  run):** warm `py_analyze` −5% (n = 2), warm `py_test` +1% (n = 1), warm `py_short` +89% (63 → 7 ms,
  n = 5). The heavy calls are CPU-bound by design (`analyze.py` at `ANALYZE_WORK_SCALE` 32 is mostly a
  KMeans fit; `pytest` is numeric work), so a warm page cache and warm imports save ~1–2 s of a 15–60 s
  call. Short calls gain because a VM boot is most of their cost.
- **Feasibility probes (2026-11-11, `resident-300` guests on the `D` = 768 template, cold = first Exec in a
  new VM, warm = the same VM again):** `analyze.py` at CPU scale 1: 14.8 s cold, 14.3 s warm (3.6%; the CSV
  parse is compute). `import numpy, pandas, scipy, sklearn`: 1.98 s cold, 0.49–0.57 s warm (−72%). `grep -r`
  over the venv's site-packages: 2.15–2.18 s cold, 0.08 s warm (−96%; its cold pass ran after the import in
  the same VM, so it was partly warm). `find` over the venv: 0.08 → 0.06 s. A warm guest pays on short
  commands that read many small files or import a large stack, and on VM-boot-bound commands; not on
  long compute.
- The trace workload is not cache-heavy. E16's VMs flattened near 150 MiB, but a page-cache-heavy
  Python workload can grow a lease VM toward its guest RAM, which measured admission must then absorb
  by reclaim (question 3).
- Level 1 also pays a cost the E15 resident patch did not: a process kill and a fresh shell at the end
  of every Exec (lease spec §3.1–3.2).

## 2. Goals, non-goals

**Goals**
- The warm-against-cold latency gain on a cache-heavy workload, at N = 1 and under load.
- `N_max` for per-Exec and lease (three idle timeouts) at the default and low-duty points.
- Memory per lease VM against age, per workload, and how close it gets to guest RAM.
- Reclaim and fallback behaviour at a memory-squeeze point.
- Overhead of the level-1 end-of-Exec kill and fresh shell.

**Non-goals**
- Level 2 (tracked processes) capacity. E17b checks only that its gates pass on the rig (§7.4). Its
  latency case is sized by the E17a follow-up spike (lease spec §16 item 6; `experiments/e17-lease/results/followups/`).
- Suspend and snapshot of a lease. The virtio-balloon free-page reporting device is in v1 (decision 7
  as revised 2026-11-12) and is measured, not excluded (§7.1, §7.3); a target-driven balloon is out
  of v1.
- Agent Substrate, SPACE or E2B arms (the assessment's Phase 3a C–E). A later experiment.
- Other hosts.

**Anti-goals**
- A lease win that rests on the resident patch's missing kill (E17a) without E17b confirming it.
- A capacity verdict bound by moca's admission policy rather than by the host (E16 §1.2 applies to the
  per-Exec arm too).

## 3. Two stages

| stage | when | lease under test | what it decides |
|---|---|---|---|
| **E17a** | before the build | E15's resident patch (`experiments/e15-session-density/resident/`), `E15_RESIDENT_IDLE_S` = 30, 120, 300 | Whether level 1 pays enough to build (questions 1–2) |
| **E17b** | after the lease spec's worker lands (the guest agent is merged: rossoctl/moca#706) | the shipped lease mode (`mode = lease`) | Questions 1–4 on the real thing |

E17a's resident patch reuses the parked shell, runs Execs as root, and kills no process at the end of
an Exec. It therefore
measures an upper bound on level 1's gain. The E17a report states this beside every number. E17b is the
verdict.

Two other differences between the patch and the shipped lease, both neutral for E17a by construction:

- The patch keeps a resident VM in `inFlight` for its whole life, so it is charged full `PerVMBytes`
  and holds a concurrency slot while idle. The shipped lease charges measured memory and holds no slot
  when idle (lease spec §6). E17a runs with E16's never-binding budget and run cap, and with
  `WORKER_MAX_CONCURRENT` raised above every N, so neither accounting difference can bind.
- The E17 driver is a non-keepalive client: its leases end by the idle timeout only (lease spec §4).

## 4. Workloads

### 4.1 Trace replay

The E15 default corpus (point `default`, 9.5% occupied), unchanged. It answers question 2. E16's
(1%, 2%] band (point `lowduty`) is not re-run; its result stands (§1.1).

### 4.2 Cache-heavy Python workload (new, point `pycache`)

A synthetic session that stands in for the use case the lease spec was written for. Each session owns a
workspace with:

- a dataset of `D` MiB (default 256, a parameter) in Parquet or NumPy files;
- a Python project that imports a heavy stack (`numpy`, `pandas`, `scikit-learn`; pinned in the
  template image, and the venv in the workspace);
- a test suite of about 60 s at N = 1.

A session is a loop of turns, each a fixed sequence of Execs separated by recorded think gaps (drawn
from the E15 corpus's gap distribution):

1. `python analyze.py` (loads the dataset, about 10–20 s of CPU);
2. `pytest -x -q` (about 60 s);
3. two to five short Execs (`grep`, `read`, `edit` on a source file);
4. `python analyze.py` again.

Turn gaps are drawn so that the session's duty matches a target (default 9.5%; `pycache-low` at 1.5%).
`experiments/e17-lease/workload/` builds the template and the session schedule from a seed, so a rung is repeatable.

**As built (calibration, 2026-11-10):** CSV shards, not Parquet (no pyarrow in the wheel set);
`ANALYZE_WORK_SCALE` 32 (≈ 17.7 s at N = 1 on the rig) and the test suite's `WORK_SCALE` 0.35 (≈ 62 s).

**Measured per Exec:** wall time, and whether the Exec ran warm (in a guest that had served this
session before) or cold. Warm and cold are reported per command kind.

### 4.3 Cache-bound classes (v0.4)

Each `pycache` turn gains two classes, after `pytest` and before the short Execs:

- `py_import`: `cd project && ../venv/bin/python -c 'import numpy, pandas, scipy, sklearn'` (the stack's
  import, ~2 s cold);
- `py_grep`: `cd project && grep -rc --include='*.py' 'def ' ../venv/lib/python3.9/site-packages | wc -l`
  (a search that reads every `.py` file of the venv, ~2.2 s cold; one line of output).

A turn is then: `py_analyze`, `py_test`, `py_import`, `py_grep`, two to five `py_short`, `py_analyze`. The
templates do not change (the venv is already in the workspace); the corpus and the library do, so both
arms' N = 1 baselines are rebuilt. `pycache-io` (v0.3) is not built.

## 5. Arms

| arm | stage | sandbox | idle timeout |
|---|---|---|---|
| **sbx** | a, b | per-Exec (stock) | — |
| **lease-30**, **lease-120**, **lease-300** | a | E15 resident patch | 30 s, 120 s, 300 s |
| **lease-30**, **lease-120**, **lease-300** | b | shipped `mode = lease` | 30 s, 120 s, 300 s |
| control | a, b | no sandbox | once at a top rung, for A2 |

Guest RAM 1024 MiB in every arm (E15/E16). Standby depth sbx 2, lease 0 (E15). The SBX0 cohort host
runs 256 MiB guests, so the `pycache` latency rungs at N = 1 and the `squeeze` point also run once at
256 MiB, with `D` scaled to keep the same dataset-to-RAM ratio.

## 6. Configuration

E16 §5 unchanged (admission and run cap never bind, physical guards kept), except:

| setting | E16 | E17 | why |
|---|---|---|---|
| point | `lowduty` | `default`, `pycache`, `pycache-low`, `squeeze` (§7.3) | §4; `lowduty` not re-run (§7.2) |
| lease admission (E17b only) | — | the lease spec v0.2 defaults: `SH_LEASE_START_MB` 192, `SH_LEASE_HEADROOM` 1.25, `SH_LEASE_RECLAIM_FREE_MB` 2 × `PerVMBytes` + max(2 GiB, 2 × (the lease charge bound − `SH_LEASE_START_MB`)) | the thing under test; the v0.2 headroom target is sized against the larger lease charge bound (decision 18) |
| `SH_LEASE_PAGECACHE_MB` (E17b only) | — | 256 MiB (the lease spec's default) | decision 18: the lease cgroup's `memory.max` = `PerVMBytes` + this, so a full guest leaves room for the host's cache of its workspace |
| balloon (E17b only) | — | virtio-balloon free-page reporting in the golden snapshot (`balloon-fpr-v1`, rossoctl/moca#763) | decision 7 as revised 2026-11-12; §7.3 measures what it returns |
| `SH_MAX_COMMITTED_MB` (E17b lease arms) | 4 TiB | **host RAM − 8 GiB** (369 GiB on this host), the no-overcommit sizing a cohort host would use | question 3 needs the real admission path, against a budget the host can actually honour |

The E17b per-Exec arm keeps E16's never-binding budget for the capacity ladders, so that its verdict is
bound by the host and not by policy (anti-goal 2).

The `pycache` latency rungs and the `squeeze` point also measure the page-cache headroom directly
(§7.1, §7.3): E17a's replacement lease VM read its workspace from disk (about 2 s against 388 ms for
per-`Exec`), and decisions 7 and 18 are the fix.

## 7. Measurements and verdicts

### 7.1 Latency (question 1)

Points `pycache` and `pycache-low`, rungs N = 1, 32, 128.

- Per command kind: median and p95 wall time, warm and cold, per arm.
- **Gain** = 1 − (lease warm median ÷ sbx median), per command kind, per rung.
- First-Exec-after-idle latency per lease arm (the cold start the user pays).
- Share of Execs that ran warm, per lease arm (how often the idle timeout lost the guest).
- **Replacement-VM read (decision 18):** the wall time of the first `py_grep` in a lease VM that
  replaced one ended by the idle timeout, against the same command in `sbx`. E17a's replacement VM
  took about 2 s where `sbx` took 388 ms; the page-cache headroom should close that gap.

### 7.2 Capacity (question 2)

Point `default` only. E15 §8 "holds N" unchanged (and E16 §7.1's memory verdicts). Ladders as E16 §8
(start at 64; first failure, one bisecting rung, two seeds on the deciding rungs). `lowduty` is not
re-run: E16's sealed and supplementary readings stand for it (§1.1), and a lease with an idle timeout
holds no more memory than resident ∞, which already reached ≥ 1536 there. Supplementary readings (1 s limit, conditions 1–3 only, no-wedge) as in E15
and E16.

### 7.3 Memory and reclaim (questions 3–4, E17b only)

- **Memory against age** per workload, per lease arm: E16's `vm_age.py`, plus the share of lease VMs
  above 50% and above 90% of guest RAM.
- **Free-page reporting (decision 7):** the lease VM's `memory.current` at the end of each Exec and
  15 s later, against its peak in the same Exec, from the same samples. E17a left every lease VM at
  its 1024 MiB ceiling after one `analyze.py`; the reporting is validated when the freed peak returns
  and the measured charge follows the working set.
- **Guest tmpfs** (`/tmp`, `/var`): the guest's `Shmem` from `/proc/meminfo`, sampled by the agent at
  the end of each Exec. It is reported beside `memory.current`, because tmpfs files are guest RAM held
  until the lease ends (lease spec §3). `pycache` writes its dependency and dataset caches to
  `/tmp/pycache-*` in half of its sessions (`tmpfs_share` 0.5, a parameter), so that this cost is
  measured, not assumed away.
- **Point `squeeze`:** `pycache` with `D` = 768 MiB, so that warm guests fill their page cache. N is
  raised until reclaim is active for the whole window. Host cgroup `MemoryMax` is lowered so the squeeze
  is reached at a moderate N. The point records:
  - reclaims per minute, and each reclaim's chosen lease (it must be the idle-longest one);
  - Execs that fell back to per-Exec, and Execs refused (`memory-budget`) while an idle lease existed
    (must be 0);
  - memory-guard events (`memory_floor`, `memory_high`, OOM kills; must be 0);
  - notices: every lease end in the worker log matched to exactly one notice seen by the driver.

### 7.4 Level-1 overhead and level-2 gates (E17b only)

- The cost of the end-of-Exec kill, the fresh shell and the privilege drop (lease spec §3.1–3.3):
  N = 1 per-call added latency, `lease-300` against the E17a resident patch, on the `default` probe
  classes. E17a's patch runs Execs as root. E17b's lease Execs run as the unprivileged uid, and its
  per-Exec arm as root (the lease spec's v1).
- The ownership walk at the start of a lease after root writes (lease spec §3.3): its time against
  workspace size (10k, 100k and 500k files), measured as part of the first Exec's latency after a
  `per-exec` → `lease` switch.
- The lease spec's §9 gates run on the rig's real launcher, level 1 and level 2. Pass or fail, reported.

### 7.5 The pass criteria (lease spec §10; E17b's set revised in v0.6 before any E17b rung runs)

E17b passes if all hold:

1. **Capacity:** `lease-300` `N_max` ≥ `sbx` `N_max` at `default` (primary verdict). At `lowduty`, E16
   stands.
2. **Latency (per class; revised for E17b after the E17a miss, user decision 2026-11-12):** at
   `pycache` N = 1 and N = 128, the median warm `py_short` is at least 50% faster in `lease-300` than
   in `sbx`, and the median warm `py_import` at least 30% faster. Level 1 is re-scoped to short and
   import-bound commands (ADR-0048 decision 14 as revised): about 450 ms of a warm import is Python
   unpacking that no cache removes, so E17a measured about 40% on the resident patch; the 30% bar
   leaves room for the level-1 kill and fresh shell (§7.4). `py_grep`, `py_analyze` and `py_test` are
   reported, not gated: per-`Exec` already reads the workspace through the host page cache, and level 1
   is not a page-cache accelerator for compute. The sealed E17a criterion — 50% on each of
   `py_import`, `py_grep` and `py_short` — stays the record of the miss; it is not E17b's gate, because
   as written it would fail by construction.
3. **Reclaim:** at `squeeze`, zero memory-guard events, zero refusals while an idle lease existed, and
   every reclaim of the idle-longest lease.
4. **Notices:** every lease end has exactly one matching notice.
5. **Memory returns and the workspace stays cached (decisions 7 and 18):** at `pycache`, a lease VM's
   measured charge falls back toward its working set after a heavy command (E17a: pinned at its
   1024 MiB ceiling), and a lease VM that replaces one ended by the idle timeout reads its workspace
   from the host page cache (E17a: about 2 s against 388 ms for `sbx`).

E17a passed if criterion 1 held or missed by at most one ladder step, and the sealed criterion 2 held
on the resident patch. It missed: criterion 2 failed on `py_import` (0.40/0.42) and `py_grep`
(−0.02/0.01), while criterion 1 held (E15 metal: 128 against 80). The miss went to the user, as this
section required. The user approved the plans 2–5 build on 2026-11-12 with the revised design
(rossoctl/moca#718), and this version re-scopes E17b's criteria to it. E17a's results are final; they
are not re-run.

## 8. Rungs and rig time

| step | stage | hours |
|---|---|---|
| `pycache` template and schedule, resync, setup | a | 3 |
| N = 1 baselines + per-class probes: sbx, lease-300 (default, pycache) | a | 5 |
| **Predictions sealed (user approval)** | a | — |
| `pycache` and `pycache-low` latency rungs (4 arms × 3 N × 2 points) | a | 6 |
| Capacity ladders: sbx and lease-300 at default (sbx's E15 metal ladder reused if the rig and commit match), lease-30 and lease-120 at default only | a | 10 |
| `pycache` gain against `D` (N = 1, `D` = 64, 256, 768 MiB, §10) and the 256 MiB guest-RAM runs (§5) | a | 3 |
| `pycache-io` feasibility gate (failed, 3.6% < 10%) and the import/grep probe | a | 0.5 |
| v0.4: corpus and library with `py_import`/`py_grep`; rebuild both N = 1 baselines + probes | a | 9 |
| v0.5 (sealed plan): `pycache` N = 128, `sbx` and `lease-300`; `default` ladders reused from E15 metal or re-run for those two arms. Replaces the latency, capacity and gain-against-D rows above for E17a | a | 2–8 |
| **E17a report, build decision (user)** | a | — |
| E17b: the re-scoped latency and capacity rungs, plus the FPR and page-cache-headroom readings, shipped lease | b | 18 |
| `squeeze` point | b | 3 |
| §7.4 overhead probe and gates | b | 2 |
| **Total** | | **about 37 h (a) + 23 h (b)** |

Reuse of earlier ladders is allowed only when the moca commit, rig profile and corpus hash match, and
the record says so.

## 9. Predictions (written after calibration, sealed before the first measured rung)

In E15's `predictions.json` format, each with `metric` and `falsifiedBy`. At least:

1. The latency gain per command kind at `pycache` N = 1 and N = 128 (§7.1).
2. `N_max` ranges per arm at `default`, and the order `lease-300` against `sbx`.
3. Whether `lease-30` loses most of the gain (share of warm Execs).
4. Peak lease VM memory at `pycache` against guest RAM, and the share above 900 MiB.
5. (E17b) The level-1 overhead of the kill and fresh shell, in ms per Exec.
6. The driver stays under 1% of host CPU (A2).

## 10. Risks and open items

- **E17a overstates the gain** (no kill, shared shell). E17b is the verdict. §7.4 measures the gap.
- **`pycache` is synthetic.** Its parameters (`D`, the test suite length, the gap draw) set the gain.
  The report gives the gain against `D` from three N = 1 runs (`D` = 64, 256, 768 MiB) so that a reader
  can map it to their own workload.
- **E16's run-end egress wedge** (resident ∞ at 896–1280) can reappear in lease arms at high N. The
  no-wedge re-judge and the staggered end-session reading from E16 are applied, reported beside the
  primary verdict.
- **Cohort admission sizing (§6)** depends on how the lease spec's defaults land. If they change
  during the build, `squeeze` uses the shipped values and the record says which.

## 11. What's built

New code lives under `experiments/e17-lease/`. Changes to E15/E16 rig scripts are fresh-metal-only and leave the sealed
E15 and E16 procedures unchanged.

1. `experiments/e17-lease/workload/`: the `pycache` template (Python stack, dataset generator, `analyze.py`, test suite)
   and the schedule generator (seeded, duty target). Tests.
2. Driver support for a synthetic schedule beside the trace corpus, with warm and cold tagging per Exec
   (from the worker's lease events in E17b, from the resident patch's reuse counter in E17a).
3. Points `pycache`, `pycache-low`, `squeeze` in the rig's points table.
4. Arms `lease-30`, `lease-120` (resident patch `E15_RESIDENT_IDLE_S`) for E17a, and `mode = lease`
   arms for E17b (sandbox created through the shipped path).
5. `experiments/e17-lease/analysis/`: the warm/cold latency report, the reclaim and notice matcher, memory against age
   per workload (extends `experiments/e16-low-duty/analysis/vm_age.py`).

## 12. Decisions taken during design

| decision | value | source |
|---|---|---|
| A separate spec from the lease spec | yes | user, 2026-11-08 |
| Cache-heavy Python as the target workload | yes | user, 2026-11-08 |
| ~~No balloon; measure growth~~ → free-page reporting in v1; no target-driven balloon | revised | user, 2026-11-08; superseded 2026-11-12 after E17a |
| Two stages (resident patch, then the shipped lease) | yes | our call: an early answer before the build |
| Idle timeouts 30, 120, 300 s | yes | our call: the assessment's Phase 3a arms B1–B3, with 300 s in place of 10 min after E15's resident-300 |
| Per-Exec arm keeps the never-binding budget; lease arms use stock admission | yes | our call: question 3 needs the real admission path |
| Drop the `lowduty` capacity ladder | yes | user, 2026-11-10, after E16's result (arms do not separate at 1–2% duty) |
| Add a cache-bound variant `pycache-io` (§4.3) after the calibration preview | yes | user, 2026-11-11 |
| `pycache-io` at `D` = 768, `ANALYZE_WORK_SCALE` 1, its own corpus and baselines; a 10% feasibility gate before its calibration | gate failed (3.6%); dropped | our call, 2026-11-11 |
| Add `py_import` and `py_grep` to every `pycache` turn; rebuild both baselines | yes | user, 2026-11-11 |
| Criterion 2 per class: `py_import`, `py_grep`, `py_short` ≥ 50% faster warm; compute classes reported (E17a) | yes | user, 2026-11-11 |
| Seal the predictions; cut E17a to `pycache` N = 128 (`sbx`, `lease-300`) and reuse E15's `default` ladders | yes | user, 2026-11-12 |
| E17a misses criterion 2 (`py_import` 0.40/0.42, `py_grep` −0.02/0.01); criterion 1 holds (128 against 80) | reported | `experiments/e17-lease/results/E17A-REPORT.md`, 2026-11-12 |
| E17b criterion 2 re-scoped: `py_short` ≥ 50%, `py_import` ≥ 30%; `py_grep` and compute reported | yes | user, 2026-11-12, after the E17a miss |
| Build plans 2–5 with the revised design (FPR, page-cache headroom, level 1 re-scoped) | yes | user, 2026-11-12, after the E17a miss; plan 2 is rossoctl/moca#763 |

