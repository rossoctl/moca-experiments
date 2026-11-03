# E15 — sessions per host: per-Exec microVMs vs resident microVMs, on replayed coding-agent traces

Version: 0.9 (draft for review), 2026-11-03
2026-11-03: fresh-metal host profile for the metal run (§13): bootstrap, guest rootfs from moca v0.9.0's sandbox image, parallel disk read measurement; metal substrate table. Later the same day: the XFS reflink=1 data volume at /srv/e15 is required (no sparse fallback; review abbaa15 H1/H2).
2026-11-03: condition 3 class-matched (user decision before sealing): a session's expected time = the driver's schedule with each call lengthened by its class's N=1 probe median added latency; class pace ≤ 10%; N=1 median pace reported.
2026-11-03: condition 3 relative to the arm's own N=1 median pace (user decision before sealing; at mem512 SBX's N=1 pace is +19.3%); metal run moves to an AWS m7i.metal-24xl (EBS-only), the IBM metal rig being unavailable.
2026-11-03: memory-pressure point mem512 added (user decision after calibration): a 512 MiB per-session dataset, read once per recorded call of the scanning classes; its binding may be disk I/O, reported as a finding; §9.3 lists disk_io.
2026-11-02: condition 4 class-matched (user decision before sealing): per-class N=1 medians, excess p95 ≤ max(3× baseline excess p95, 50 ms); medians from a per-class N=1 probe, 20 calls per class drawn from the corpus distribution (each class alone on an idle worker), every class is probed; a class with fewer than 5 ok probe calls is undercovered and uses the global median; absolute verdict B + 250 ms (user decision 2026-11-02); per-call N=1 overhead reported per arm.
2026-11-02: §8 condition 4 factor 2× → 3× (user decision before sealing; calibration baselines unchanged, they do not depend on the factor).
2026-11-01: §5.3–§5.6 numbers regenerated from e15/extract after fixing a cross-session chain join
and removing re-recorded history.
Status: **Design. Not approved. Nothing is built.**
Stage: **Preliminary**, on one nested-KVM AWS instance. A metal run follows (§13).
Record: `EXPERIMENTS.md` (written when results exist). Predictions: `predictions.json`, written after
calibration and sealed before the first measured rung (§11).

---

## 1. The question

**At equal hardware, does SBX (one fresh microVM per command) hold more concurrent coding-agent
sessions per host than resident microVMs (one VM kept for each session)?**

"Hold" has one definition, given in §8. This experiment produces one number per arm, `N_max`: the
largest session population the host holds. Everything else it measures explains that number.

### 1.1 Why now

- The SWE-bench density runs (2026-10-30/31) showed both container and VM backends hitting a
  **CPU wall**. SWE-bench trajectories run commands back to back. An interactive coding agent does
  not: it waits on the model and on its human between commands.
- A resident VM pays memory for every idle second. A per-Exec VM pays memory only while a command
  runs, but pays a fixed CPU cost for every command (E10: resume plus destroy ≈ 50 ms of the 55 ms
  warm path on metal, about 3.8× that nested).
- Which cost wins depends on how idle real sessions are, and on what the commands are. TraceLab
  records both for 52 developers' real Claude Code and Codex sessions. Until now we had no measured
  workload to settle it.

### 1.2 What success looks like

A preliminary result that says, with its uncertainty stated, which arm's `N_max` is larger **on this
instance**, which resource bounds each arm, and how both bounds move with the parameters that decide
them: how long humans pause (`H`), how fast a resident VM is reclaimed (`T_idle`), and how heavy the
commands are. That is enough to design the metal run and to decide whether to run it.

## 2. Goals, non-goals, anti-goals

**Goals**

- G1. `N_max` for each arm on one host, under the §8 definition.
- G2. The binding resource for each arm at its `N_max`: RAM, CPU, disk, or a moca admission gate.
- G3. The sensitivity of both `N_max` values to `H`, `T_idle` and command weight.
- G4. A reusable instrument (corpus extractor, command library, replay driver, resident-arm patch)
  that runs unchanged on a larger machine.
- G5. Replicable runs: the same seed and the same corpus give the same command stream.

**Non-goals**

- Not a test of agent quality, model latency or agent behaviour. No model and no agent run.
- Not a comparison with containers, qemu/kvm, E2B or any other product. Both microVM arms use the
  same Firecracker build.
- Not a capacity claim for any production deployment. The preliminary host is nested (§4).
- Not a test of SBX's control plane or HTTP front door. The driver speaks `sandbox/v1` to the relay.
- Not a proposal to ship a resident mode. ADR-0035 (2026-10-08 revision) makes per-Exec the only
  product mode. The resident arm is a measurement baseline only and never enters the moca repo (§6.4).

**Anti-goals** (a run that does these has failed, even if it produces numbers)

- A1. **Headroom bought by under-pricing one arm.** Both arms run under the same memory accounting
  (§7.2). An arm that holds more sessions because a moca gate was relaxed for it and not for the
  other is not a result.
- A2. **A knee caused by the instrument.** The driver must use less than 1% of the host's CPU at
  every rung, measured by the control arm (§6.5). E11's first published knee was its driver's.
- A3. **A bias hidden in the workload.** Every exclusion or transformation of the trace is counted
  and reported (§5.5). Sessions that SBX cannot replay as recorded must not silently disappear.
- A4. **A nested result reported as a capacity number.** Preliminary `N_max` values are always
  reported as "on a 4-vCPU nested Nitro instance".
- A5. **Idle time removed from the workload.** The default point keeps the trace's real idle time up
  to a 30-minute cap (§5.4). A run that caps pauses at seconds turns this into a CPU-wall test and
  cannot answer §1.

## 3. Design overview

```
TraceLab v0.0.2 DuckDB ──extract──▶ corpus.jsonl (sessions: real command classes, durations, gaps)
                                         │
                         replay driver (Go, one process)
                         N sessions; closed loop inside a session,
                         population held at N across sessions
                                         │ sandbox/v1 SandboxExec, one gRPC connection
                                         ▼
                          sandbox-relay (moca v0.9.0)
                                         │ attach stream
                 ┌───────────────────────┼──────────────────┐
                 ▼                       ▼                  ▼
            SBX arm                resident arm        control arm
        stock microvm-worker        patched worker     null-responder
        VM per command              VM per session     (no relay, no VM)
```

- One driver process replays a population of `N` sessions.
- **Inside a session the loop is closed**: send a command, wait for its result, sleep the recorded
  gap, send the next one. A slow backend stretches the session; that stretch is the pace metric (§8).
- **The population is held at `N`**: when a session reaches the end of its trace, a new one starts
  at once, whatever the backend is doing.
- **The mocked LLM is the recorded gap.** There is no model call, no agent and no inference queue.
  Given a seed, every run sends the same commands at the same offsets.
- **The commands are real.** Each recorded command is replayed as a real program of the same class
  (`pytest`, `python`, `git`, `grep`, `sed`, file reads and writes, …) against a real project in the
  workspace (§5.6).
- The driver, relay, protocol, Firecracker binary, guest kernel, rootfs and guest RAM are the same in
  both microVM arms. The only difference between them is how long a VM lives.

## 4. Substrate (preliminary)

| | |
|---|---|
| Host | AWS `m8i.xlarge` (Nitro), Intel Xeon 6975P-C, **4 vCPU, 15.3 GiB RAM, no swap** |
| Virtualization | the instance is a KVM guest; Firecracker runs **nested** |
| OS / kernel | Amazon Linux 2023, 6.18.44 |
| Firecracker | v1.17.0; guests have **1 vCPU** (`deploy/microvm/build-snapshot.sh`) |
| Disk | 40 GB root, **~20 GB free** |
| cgroups | v2 (`cpu io memory pids`) |
| Access | `ssh -i ~/gh/experiments/fc/firecracker-key.pem ec2-user@3.235.29.220` |

**The host is shared. Rig rules:**

- The host runs a P6 stack (`sh-relay`, `sh-supervisor`, `sh-control-plane` from
  `/opt/serverless-harness`), a `microvm-worker` (`moca_microvm_0`) and Node services owned by others
  (ports 8080, 8081, 8090, 8787). E15 never touches those services or `/opt/serverless-harness`.
- For the length of a run, E15 stops `microvm-worker.service` and the leftover `bench-redis` /
  `bench-cp` containers (from the 2026-10-30 control-plane benchmark), and starts them again after.
  It deletes none of their data.
- Every change goes into `~/e15-manifest.md` on the host, with the command that undoes it.
- E15's own relay and Redis bind to 127.0.0.1 on ports nothing else uses (default attach 9643, exec
  9644, Redis 6400).
- E15's files live under `/srv/e15/`. The runbook's teardown step removes them.

**What nesting means for the result.** E10 measured the warm path at 52.74 ms on metal and 200.91 ms
nested (resume 2.74×, destroy 5.56× more). Nesting raises the SBX arm's per-command CPU cost about
4×; the resident arm pays it once per session. **Nesting favours the resident arm.** A preliminary
result in SBX's favour is likely to hold on metal. A result in the resident arm's favour may not.

## 5. Workload

### 5.1 Source

TraceLab release **`v0.0.2`** (uw-syfi/TraceLab, published 2026-07-24; dataset licence CC BY 4.0),
file `syfi_coding_trace.duckdb`, SHA-256
`a7bab286bc640844560850965ccf47975cf66407154132abaab90f27ec9be744`. 665,453 LLM rounds and 743,819
tool records from 8,058 Claude Code and Codex sessions of 52 developers. The write-up credits the
dataset.

The dataset's sanitization strips arguments, paths and outputs. What remains for each shell command,
and what this design depends on:

- `executables`: the programs a command ran, one entry per occurrence (`["git","grep","head"]`).
  Names on TraceLab's reviewed public list are kept; every other name becomes `custom_N`. Parse
  status is `success` for 98.9% of shell calls.
- `command_skeleton`: the command's shape without arguments (`git && grep | head`).
- `continuation_of_tool_call_id` and `command_status`: which Codex `write_stdin` calls poll which
  `exec_command`, and whether the command finished.
- Durations, timestamps, result sizes and error flags, as in v0.0.1.

The earlier draft used v0.0.1, which has none of the first three fields.

### 5.2 Which calls are replayed

Only tools that run in the sandbox: `exec_command`, `Bash`, `write_stdin`, `shell_command`, `shell`,
`Read`, `Write`, `Edit`, `apply_patch`, `Grep`, `Glob`, `LS`, `NotebookEdit`, `MultiEdit`. They are
**86.8%** of all tool calls. Every other tool call (`WebFetch`, `Agent`, `TaskUpdate`, …) folds into
the gap that follows it: the sandbox does not see that time.

A session enters the corpus when it has at least 20 replayed calls: **4,147 sessions** after chain
collapsing (§5.3). One pseudonymous user holds 27.2% of all sessions and the top three hold 42.6%;
§5.7 limits how much of a population one user can make up.

### 5.3 Codex polled commands

A Codex agent can start a long-lived process with `exec_command` and then poll it with `write_stdin`
(a dev server, a long test, a training run). v0.0.2 links each poll to its command. SBX cannot keep
a process alive between commands, so each **chain** (a command and its polls) is replayed as **one
command**:

- **Lifetime:** from the `exec_command` emit to the last poll's result, capped at **2 hours**. The VM
  is occupied for the whole lifetime. 36,680 chains; 16 exceed the cap and are cut to it.
- **Work:** the command's own recorded run time plus the polls' run times, at most the lifetime.
  Across all chains, work is **63%** of lifetime; the rest is the model thinking between polls.
- The replayed command runs its real class's program for the work time, then idles until the end of
  its lifetime.

### 5.4 The replay model

For each session, the extractor writes the ordered list of replayed calls. Each call has:

- `class`: one of the command classes in §5.6, from the call's tool and its first non-plumbing
  executable.
- `skeleton`: the recorded `command_skeleton`, kept for reporting and for multi-stage commands.
- `dur_ms`: the command's run time (its lifetime, for a chain).
  - **Codex** records it (`tool_internal_latency_ms`). Used when present and positive, else the
    end-to-end time. Capped at 120 s, except chains (§5.3).
  - **Claude** records only the end-to-end time, which includes approval waits. Used as is, capped
    at **30 s**. (Our call: a 30-second cap keeps real builds and test runs and drops most approval
    waits.)
- `work_ms`: the CPU-carrying part of `dur_ms`. Equal to `dur_ms` except for chains (§5.3).
- `gap_ms`: the time from this call's end to the next replayed call's emit, capped at `H`. The gap
  holds model time and human time; the trace does not split them reliably, so `H` is what bounds the
  human part. A gap longer than `H` reads as "the human left, and came back `H` later".
- `out_bytes`: the recorded result size. It sizes the command's output.
- **Ordering:** each call is sent at its recorded offset from the previous one in the session, not
  grouped by round. Claude's same-round calls were sequential in the trace (100% distinct emit times,
  median round span 4.1× the sum of its calls) and replay that way. Codex's overlap (76% distinct
  emit times, span 0.5× the sum) and replay that way too.

The replay model's own numbers on the full corpus (computed by `e15/extract` from the v0.0.2
DuckDB, 2026-11-01). Each session is laid on its replay timeline: calls at their offsets, each
running for `dur_ms`; session time runs from the first emit to the last call's end. "Occupied" is
the share of session time at least one command is running (the union of running intervals);
"work" is the sum of `work_ms` over session time; "held at T300" is the share of session time a
resident VM with a 300-second idle timeout is alive (an idle stretch between busy periods counts
for at most 300 s); "cold wakes" are the restarts that timeout causes (idle stretches longer than
300 s). All are totals over sessions, so long sessions weigh more:

| `H` | occupied | work | calls/s per session | held at T300 | cold wakes per session-hour | mean session span |
|---|---|---|---|---|---|---|
| 300 s | 16.8% | 14.7% | 0.0313 | 100% | 0 | 69 min |
| **1800 s (default)** | **9.5%** | **8.2%** | **0.0174** | **56%** | **2.3** | **123 min** |
| 7200 s | 6.3% | 5.4% | 0.0115 | 37% | 1.5 | 187 min |

The default `H` of 30 minutes keeps most of the trace's idle time and stops a session from idling for
a whole night. Short caps turn the test into a CPU-wall test (A5); they appear only as sensitivity
points.

### 5.5 Transformations, counted

For each run's corpus, the extractor reports:

1. **Chains collapsed** (§5.3): count, share of sessions affected, and lifetime removed by the cap.
2. **Duration caps**: count and total time removed, per provider.
3. **Gap caps** at `H`: count and total time removed.
4. **Errored calls** (5.1% of corpus calls): replayed as successful commands of the recorded
   duration. The error itself is not reproduced.
5. **Sessions dropped** (fewer than 20 replayed calls): count.
6. **Host-infrastructure calls** (§5.6): count, and share of sessions that use them.
7. **Opaque and unparsed calls**: count and share of busy time.

### 5.6 Command classes and what each replays

Each call is assigned a class from its tool, or for shell calls from its first executable after
shell plumbing (`cd`, `echo`, `true`, `export`, `source`, `timeout`, `env`, `xargs`, `tee`, …) is
skipped. Shares are of replayed calls and of replayed busy time, with chains collapsed (§5.3):

| class | executables (examples) | calls | busy time | replays as |
|---|---|---|---|---|
| interpreter | `python`, `python-script`, `uv`, `conda`, `node`, `uvicorn` | 10.4% | 31.4% | a Python script from the workspace's script set, chosen by `dur_ms` |
| host infra | `docker`, `nvidia-smi`, `ssh`, `sshpass`, `perf`, `nsys` | 5.0% | 11.6% | a stand-in (below) |
| opaque | `custom_N` (names TraceLab withheld) | 1.7% | 14.5% | the interpreter stand-in, for its recorded time |
| shell read | `grep`, `rg`, `sed`, `cat`, `head`, `tail`, `ls`, `find`, `wc`, `awk` | 40.5% | 12.5% | the same tools over the workspace, piped per the skeleton |
| wait | `sleep`, `wait` | 1.1% | 7.7% | `sleep` for the recorded time |
| file ops | `cp`, `mv`, `rm`, `mkdir`, `tar` | 1.4% | 5.2% | the same tools on workspace files |
| test | `pytest` | 1.0% | 2.2% | `pytest` on a subset of the workspace's tests, chosen by `dur_ms` |
| write | `Write`, `Edit`, `apply_patch` | 13.8% | 2.5% | a file write or patch in the workspace |
| build | `cargo`, `make`, `npm`, `pip`, `go` | 1.2% | 2.0% | the interpreter stand-in, for its recorded time (no compilers in the template) |
| vcs | `git` | 6.2% | 1.6% | `git status`, `git diff`, `git log` or `git commit` in the workspace |
| other, process, network, lint, read, search | | 17.3% | 8.4% | the closest real tool in the template (`ps`, `python -m py_compile`, `cat`, `rg`), else the interpreter stand-in |

**Real command, recorded duration.** A real command almost never takes exactly the recorded time.
The command library holds, for each class, a set of real invocations with measured run times on the
rig (calibration, §10.1). For each call, the replayer picks the invocation of that class whose run
time is closest to `work_ms` without exceeding it, runs it, and, if time remains, repeats invocations
until the remainder is under 50 ms. A chain then idles to the end of its lifetime. A command shorter
than the shortest invocation of its class runs that invocation once.

**Host infrastructure.** `docker`, `nvidia-smi`, `ssh` and the like reach things a sandbox does not
have: a container engine, a GPU, other hosts. They are replayed as a stand-in of the same duration:
`sleep` for the share of their time spent waiting on the remote side, and the interpreter stand-in
for the rest. Our call: half and half. 21.5% of sessions use them at all, and 2.2% spend more than
half their busy time in them. The run reports results with and without those sessions (§10.3).

**The workspace project.** Every session's workspace holds the same project, a real open-source
Python repository with its git history and its test suite, plus a small set of generated scripts of
graded run time for the interpreter class. (Which repository is the builder's choice, §14. It must
need only what the template has: Python, git, `rg`, coreutils.) Each workspace image is built once on
the host disk before the rung starts, with the project already in place, and copied for each session.
Seeding is not part of the measured load. The worker reuses any `workspace.img` that is already an
ext4 filesystem, so no worker change is needed.

### 5.7 Steady state, not session starts

Sessions are long (mean 123 min at the default) and a rung is not (§10.2). If every session started
at its first call, a rung would only ever measure session openings. So each session the driver
starts begins at a **random call index** in its trace (seeded), and the population is spread over the
trace's whole length.

A session that joins mid-trace has no VM history in the resident arm. The 10-minute warm-up (§10.2)
lets resident VMs reach their working footprint. The run checks it: the median resident VM's memory
at the start and end of the measured window must agree within 10%, or the warm-up is lengthened and
the rung repeated.

No single pseudonymous user makes up more than **15%** of the sessions in a population; draws beyond
that are redrawn. (Our call: one user holds 27% of the corpus, and an unbounded draw would measure
one developer's habits.)

### 5.8 Determinism

- Sessions are drawn from the corpus with a seeded PRNG, without replacement until the corpus runs
  out.
- Every replayed command is a pure function of `(seed, session id, call index)` and the command
  library.
- The run record (§9.3) holds the seed, the corpus hash, the command library's hash, the commit of
  every component and every parameter.

## 6. Components

All new code, the patch and all results live in **moca-experiments**, under `e15/`. Nothing is added
to the moca repo. Components that come from moca are pinned to **v0.9.0** (`c13d5564`), the release
the SBX deployment runs.

### 6.1 Corpus extractor: `e15/extract/`

A Python script that reads the v0.0.2 DuckDB and writes `corpus.jsonl` (one session per line) and
`corpus-report.json` (the §5.5 counts and the §5.4 table for the chosen `H`). It refuses a DuckDB
whose SHA-256 differs from §5.1.

### 6.2 Command library: `e15/commands/`

The project choice, the per-class invocations with their measured run times (§10.1), the stand-ins,
and the generated scripts. It is versioned and hashed into the run record.

### 6.3 Replay driver: `e15/driver/`

A standalone Go module that imports moca's generated `sandbox/v1` stubs
(`github.com/rossoctl/moca/gen/go`, pinned to v0.9.0). It follows the method of
`remote-worker/cmd/exec-driver`: one process for the whole run, one `grpc.ClientConn` reused for
every Exec, one goroutine per session.

- **Input:** corpus file, command library, seed, `N`, rung timing (§10.2), target address, exec
  token.
- **Session identity:** each session gets a fresh `workspace_key` (`e15-<run>-<n>`). The resident arm
  binds its VM to that key; the SBX arm keeps its workspace under it.
- **Start-up:** the `N` sessions start spread over the first 60 s of the rung, not at one instant.
- **Output:** one JSON line per call (`ts, session, call, class, planned_dur_ms, planned_gap_ms,
  observed_ms, status, cause`) and one line per session per window (the §8 pace inputs).
- **Self-measurement:** the driver samples its own CPU (`/proc/self/stat`) at 1 Hz into the run
  record.

### 6.4 Resident arm: `e15/resident/`

A patch against `remote-worker/internal/vmpool` at v0.9.0. It is applied and built only on the rig,
never enters the moca repo, and is never seen by moca's CI, so `TestGateNoVMReuse` is untouched.

Behaviour:

- The first command for a `workspace_key` acquires a VM exactly as today (standby pop or cold
  restore) and **keeps it** after the command ends.
- Later commands for that key run on the same VM, each on a new vsock connection to the guest agent,
  which already serves one connection per command (`internal/guestagent/agent.go`, `Serve`).
- **Commands for one key run one at a time.** The guest agent runs every command without stdin on one
  parked shell, whose output readers it shares (`runOnParkedShell`), so two commands at once on one VM
  would corrupt each other. The patch keeps today's per-workspace exec gate, which already serialises
  SBX. Both arms therefore run a session's overlapping Codex calls one after another, and neither
  gets an advantage from it.
- The VM is destroyed when its key has been idle for `T_idle`, or when the driver ends the session.
  The next command after such a destroy acquires a fresh VM (a cold wake).
- Admission is unchanged code: a resident VM is admitted once, at acquire, against the same budget
  and host floor as SBX (§7.2).
- A command whose timeout killed the guest's parked shell retires the VM, as today; the next command
  gets a fresh one.

Every result names the patch's commit. The patch carries its own tests, run on the rig before any
measured rung: reuse across commands, destroy at `T_idle`, serialised commands on one VM, retire
after a killed shell.

### 6.5 Control arm

The driver against `remote-worker/cmd/null-responder` (v0.9.0): no relay, no worker, no VM. It
measures the driver's own cost at each `N` (A2).

### 6.6 Stack

- `sandbox-relay` v0.9.0, run from a v0.9.0 checkout under `/srv/e15/moca`, with its own Redis.
- One worker at a time, under its own systemd slice (`e15.slice`), so its CPU and memory are counted
  apart from the host's other services.
- The SBX arm runs the stock `microvm-worker` binary at v0.9.0. The resident arm runs the patched
  build of the same commit.

## 7. Configuration

### 7.1 Both arms

| setting | SBX | resident | why |
|---|---|---|---|
| guest RAM (`SH_GUEST_RAM_MB`) | **1024** | **1024** | a coding agent's toolchain (git, rg, python, pytest) and the project's tests |
| snapshot | one 1024 MiB snapshot from the rig's `default` image, with `pytest` added, built with `deploy/microvm/build-snapshot.sh` | same | same guest in both arms |
| `SH_STANDBY_DEPTH` | **2** | **0** | each arm in its natural setting: SBX needs warm standbys for its per-command restores; a resident session has its VM, and its cold wakes are real cold restores |
| `WORKER_MAX_CONCURRENT` | 256 | 256 | the slot count must never bind first (E11, #305) |
| `SH_MAX_RUNS` | 512 | 512 | must not bind |
| `SH_STANDBY_HEADROOM` | 4 (default) | n/a | |
| workspace image (`SH_WORKSPACE_IMAGE_MB`) | 256, sparse | 256, sparse | holds the project; fits ~20 GB of free disk at N=128 |
| `SH_WORKSPACE_IDLE` | longer than the run | longer than the run | no workspace is reclaimed during a rung |

### 7.2 Memory accounting: the same in both arms

moca's admission budget charges every running VM its full template RAM, whatever it uses (the CB
runs measured ~390 MB used against 2,080 MiB charged). Left as is, the budget, not the host, would
set `N_max`, and it would favour SBX, which holds fewer VMs at once. To measure the host instead:

- `SH_MAX_COMMITTED_MB` is **1048576** in both arms, so the budget never refuses.
- `SH_HOST_MEM_FLOOR_MB` is **1536** in both arms. The worker refuses a new VM when host
  `MemAvailable` falls below it. **This floor is the memory limit for both arms.**
- The worker's slice has `MemoryMax` = host RAM minus 2 GiB, as a backstop. An OOM kill in either
  arm fails the rung.

The resident arm is admitted once per session, and its VMs keep growing after admission: the guest
keeps its page cache, the Python interpreter's memory and the pages earlier commands freed. That
growth is a real cost of keeping a VM alive and is what the resident arm is meant to pay. If it takes
the host past the floor, the next admission is refused or the backstop kills a VM; either fails the
rung. No balloon and no guest-side reclaim run in either arm.

### 7.3 Resident idle timeout `T_idle`

Two values:

- **∞**: the VM lives as long as its session. This is the plain resident baseline.
- **300 s**: the VM is destroyed after 5 minutes without a command and restored cold on the next
  one. This is a resident arm that tries to save memory, at the cost of a cold start after each
  long pause (2.3 per session-hour at the default `H`).

These are our settings, not a product's. E2B's default 5-minute timeout, for example, is a fixed
lifetime that commands do not extend ([E2B docs](https://docs.e2b.dev/sandbox/auto-resume)), not an
idle timeout.

## 8. The "holds N" test

The host **holds** a population of `N` sessions in an arm when, over the measured window of that
rung, all four conditions are true:

1. **No call fails.** Every command returns `End` with the exit code the command library expects
   for it.
2. **No call is refused.** No `memory-budget`, host-floor, `busy` or `queue full` refusal, no
   `RESOURCE_EXHAUSTED`, and no OOM kill.
3. **Sessions keep their pace, class by class.** For each session with at least 3 calls in the
   window, expected time = the time the driver's schedule takes for the calls in the window (each next
   call is sent at its planned offset, or when the previous call ends if that is later) with each
   call lengthened by the `N = 1` probe median added latency of its command class (§8.4), from the
   first call's send to the last call's `End`. Class pace = (observed
   time from its first to its last completed call in the window) ÷ expected time − 1. The **median
   class pace is at most 10%**. The `N = 1` rung skips this condition and reports its raw median pace.
   Sessions with fewer than 3 calls in the window, or a non-positive expected time, are excluded from
   this condition and counted.
4. **Added latency stays bounded, class by class.** Per call, added latency = observed time from send
   to `End`, minus the planned duration. From the arm's per-class `N = 1` probe (§10.1: each class alone on an idle
   worker, 20 calls drawn from the corpus's distribution for that class) take the median added
   latency of each command class; a class with fewer than 5
   ok probe calls uses the median of all probe calls. A call's **excess** is its added latency minus the `N = 1` median of its own class. The
   **p95 of excess is at most the larger of 3× the arm's own probe excess p95 (each probe call
   measured against its own class median) and 50 ms**. The absolute verdict asks only that the p95
   of excess is at most the arm's own `N = 1` within-class excess p95 plus 250 ms.

`N_max` for an arm is the largest `N` on the ladder for which the host holds, with every smaller rung
having held too. A failed rung ends the ladder for that arm.

## 9. Measurements

### 9.1 Host

Sampled at 1 Hz inside the measured window, never after it (E11's #291 defect):

- `MemAvailable`, slice `memory.current`, page-cache size;
- CPU per slice and for the whole host (`/proc/stat`), and `cpu.pressure` / `memory.pressure` PSI;
- disk use under `/srv/e15`;
- process count.

### 9.2 Worker

- VMs resident, VMs executing, standbys; resident VM memory (each VM cgroup's `memory.current`);
- each Exec's phases (acquire, resume, run, destroy) from the worker's per-Exec log line;
- every refusal line, by reason; every cold wake (resident arm).

### 9.3 Run record

One JSON record per rung, in E11's style: arm, `N`, seed, corpus hash, command library hash,
component commits (moca, moca-experiments, patch), every parameter in §5, §7 and §10, the driver's
CPU, the four §8 conditions with their values, results split by provider and by command class, and
the binding resource at the end of the window (the first of: memory floor reached, CPU ≥ 90% busy,
disk reads ≥ 90% of the volume's measured sequential read throughput (`disk_io`), disk ≥ 90% full, a
moca gate refusal; and for a rung that does not hold with none of these, `memory_high`: e15.slice's
MemoryHigh reclaim throttled it, its `memory.events` `high` counter rose over the window), and the
arm's per-call overhead at N = 1 (corpus-weighted median of class medians).

## 10. Procedure

### 10.1 Calibration (once per host)

1. Build the snapshot and the workspace image (§5.6, §7.1).
2. Inside a VM, run every invocation in the command library 5 times and record its median run time
   and CPU time. This fills the library's run-time table.
3. Bring up the stack and run each arm at `N = 1` for at least 3 seeded sessions and 30 calls (pace
   sanity check and evidence), then the per-class probe: each command class alone, 20 calls drawn
   from the corpus's distribution for that class. The probe gives each arm's per-class median
   added latency and its excess p95 (§8.4).
4. Run the control arm at `N = 128` and confirm A2 (driver below 1% of host CPU).
5. Write the predictions from these numbers (§11) and seal them.

### 10.2 Rungs

- Ladder of `N`: **1, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 128**, ascending, ending at an arm's
  first failed rung.
- Each rung: a **10-minute warm-up** (not measured), then a **15-minute measured window**.
- Between rungs, the worker is restarted and `/srv/e15/workspaces` is reset from the prepared image,
  so no rung inherits another's VMs or workspace state.

### 10.3 Points

| point | `H` | sessions | arms |
|---|---|---|---|
| **default** | 1800 s | all | SBX, resident ∞, resident 300 s, control |
| short gaps | 300 s | all | SBX, resident ∞ |
| long gaps | 7200 s | all | SBX, resident ∞, resident 300 s |
| no host infra | 1800 s | sessions that never call a host-infrastructure tool | SBX, resident ∞, resident 300 s |
| no chains | 1800 s | sessions with no Codex polled command | SBX, resident ∞, resident 300 s |
| **mem512** (memory pressure) | 1800 s | all (the default point's corpus); 512 MiB dataset per session, read once per call of the scanning classes | SBX, resident ∞ |

(At `H` = 300 s no gap reaches 300 s, so resident 300 s equals resident ∞ there and is not run.)

**mem512.** Calibration measured a resident VM at a median of 74 MiB, so at the default point both
arms meet the CPU wall of 4 vCPUs before memory binds, and SBX's memory advantage cannot show. At
mem512 every session holds a large working set. Every workspace holds `/workspace/data.bin`, 512 MiB
of incompressible bytes generated from a fixed seed, on a 1024 MiB workspace image; the file stays
on the image in both arms. Every recorded call of the classes read, shell read, search, test,
interpreter and lint first reads the whole file once (`cat /workspace/data.bin >/dev/null`, one step
at the head of the call's script, however many invocations the call repeats), then runs its
commands as at the default point. In a resident VM the guest's page cache keeps the file after the
first read, so each resident VM holds about 512 MiB more for as long as it lives. In SBX each such
call reads the file again in a fresh VM, whose memory is freed when the call ends. Guest RAM stays
1024 MiB. The command library is the default one; the point has its own N = 1 baseline, and the
default point's baseline is never used here.
mem512's binding may be disk I/O (`disk_io`: the volume's read throughput, measured once at setup,
saturated): that is reported as a finding — the cost of a per-session dataset re-read for every
command — not as an artefact.

- The default point runs the full ladder.
- Each other point starts its ladder two steps below that arm's default `N_max` and runs to failure.
- One run per cell. The preliminary stage does not claim a difference smaller than one ladder step.
- Rig time: about 11 hours for the default point and about 18 for the rest, so **about a day and a
  half**.

## 11. Predictions (written after calibration, sealed before the first measured rung)

The predictions are written into `predictions.json` after calibration (§10.1), each with what would
falsify it, and committed before any measured rung runs. Calibration supplies the two numbers they
depend on: the CPU time of the replayed command mix, and a resident VM's grown footprint.

The direction of each prediction is fixed now:

1. **SBX is bound by CPU. Resident ∞ is bound by memory.**
2. **SBX holds more sessions than resident ∞ at the default point.** Sketch with today's numbers: if
   a resident VM grows to 250–450 MiB, about 11.5 GiB usable gives resident ∞ an `N_max` of 26–47.
   SBX's CPU per session is the commands' own work (at most 8.2% of a core, less where commands wait)
   plus lifecycle (0.0174 calls/s × ~0.31 core-seconds nested ≈ 0.005 cores), at most about 0.088
   cores; about 3.5 usable vCPUs gives at least 39. The sealed version replaces these with measured
   values.
3. **Resident 300 s comes within one ladder step of SBX, in either direction.** It holds only 56% of
   its VMs at a time, and its CPU per session is the commands' own work alone. Both then meet the
   same CPU wall.
4. **Longer gaps help SBX and resident 300 s, not resident ∞.** At `H` = 7200 s, SBX's and
   resident 300 s's `N_max` rise; resident ∞ stays within one ladder step of its default.
5. **Removing host-infrastructure sessions and chains moves both arms the same way.** Neither point
   reverses the default result.
6. **The driver uses less than 1% of host CPU at every `N`** (A2).
8. **The m7i.metal-24xl run shows the largest SBX gain.** On the metal run (§13), SBX's N_max divided by resident ∞'s N_max is larger than on this nested instance. Falsified by a metal ratio no larger than the preliminary one.
9. **At mem512, resident ∞ is bound by memory and SBX holds more sessions than resident ∞.** Falsified by resident ∞'s first failed mem512 rung not bound by memory, or by n_max(SBX) ≤ n_max(resident ∞) at mem512.

Prediction 3 matters most for SBX: an idle-reclaiming resident VM is the strongest baseline, and on a
4-vCPU host both may meet the same CPU wall. If it holds, the metal run, where CPU is not scarce, is
where the arms separate.

## 12. Risks and open items

- **The resident patch is new code with no production review.** Its tests (§6.4) must pass on the rig
  before any measured rung. If state left by one command breaks the next in a reused VM, the resident
  arm is broken, not slow, and the run stops.
- **Nested Firecracker restore under load.** E13's 128-restore probe failed for reasons traced to the
  probe itself. SBX at high `N` restores often. A restore failure fails the rung under §8 and is
  reported as one, not retried away.
- **Claude durations are approximate.** The 30-second cap keeps real long commands and drops most
  approval waits, but not all. The run reports results per provider.
- **Stand-ins carry a third of the busy time.** Host infrastructure, opaque and build calls (29.5% of
  busy time) replay as stand-ins, not as the recorded program. The "no host infra" point bounds
  their effect; opaque and build calls stay stand-ins everywhere and are reported as such.
- **The project choice shapes the read and test classes.** Read and search commands over a different
  repository take different times. The run-time table (§10.1) absorbs most of this, since each call
  is matched by duration, not by program alone.
- **Free disk** (about 20 GB) bounds the ladder near N = 128 with 256 MiB sparse workspaces. The
  ladder stops at 128.
- **The rig is shared.** Other services' CPU and memory are sampled and reported. A rung whose window
  overlaps a spike in their use (more than 10% of host CPU) is repeated.
- **4 vCPU is very little CPU.** Every arm may hit the same CPU wall. That outcome still answers the
  preliminary question: it bounds the answer on this shape of host and says what the metal run must
  show.

## 13. After the preliminary run

The metal run reuses the instrument unchanged, on an AWS m7i.metal-24xl with EBS-only storage,
with the ladder extended until one arm fails. Its predictions are written from the preliminary
results and sealed before it runs. Metal removes the nesting penalty, the term most likely to change
the answer (§4), and gives CPU room for the memory difference between the arms to show.
Its disk bound depends on the provisioned EBS throughput and the instance's EBS bandwidth, and
`disk_read_max` is re-measured with parallel streams before that run.

The rig scripts bring the stack up on that host under the host profile `E15_HOST_PROFILE=fresh-metal`
(the default, `aws-prelim`, is the preliminary rig's behaviour, unchanged). The metal host is fresh and
dedicated, so the profile drops the shared-host rules of §4. Instead E15 writes nothing outside
`/srv/e15` except the package installs, the `kvm` group membership and its two slice unit files, each
recorded in the manifest with its undo. `e15/rig/bootstrap.sh` installs the toolchain first:
Go 1.26.0, Node 22 with pnpm 9 through corepack, Firecracker v1.17.0 with its jailer, and grpcurl, all
under `/srv/e15`, plus podman from Ubuntu's apt. Each is pinned by version and checksum in
`e15/rig/pins.sh`, and the script refuses to run while any pin is empty. The guest is built the way
moca v0.9.0 documents it: `deploy/microvm/build-rootfs.sh` exports the v0.9.0 sandbox image
(`ghcr.io/rossoctl/moca-remote-worker:0.9.0`, pinned by digest) as the rootfs tree. The same pytest
wheels are then added, and `build-snapshot.sh --guest-ram-mb 1024` runs with the pinned Firecracker CI
kernel `vmlinux-6.18.44`, the version the preliminary rig ran. Every artifact's sha256 goes in
`/srv/e15/state/artifacts`. Workspaces need reflink, which the ext4 root volume lacks, so the host has
a second EBS gp3 volume. `bootstrap.sh` (`E15_DATA_DEV`) formats it XFS (`mkfs.xfs -m reflink=1`) and
mounts it at `/srv/e15`, the whole E15 root. A volume the operator already formatted XFS with
`reflink=1` and mounted at `/srv/e15` is accepted as it is: bootstrap without `E15_DATA_DEV` leaves it
alone, it is never reformatted, and teardown empties it but keeps the mount. Mounting it only at `workspaces/` is not enough: moca's
worker hardlinks the snapshot files and each workspace image into the jail, so snapshots, workspaces
and jail must share one device (it refuses to start otherwise), and a reflink of the template
cannot cross filesystems. Setup refuses any other layout: the five directories must be on one
device, and that device must be XFS with `reflink=1`. It probes a reflink copy from each template
directory into `workspaces/` on every run, and there is no sparse fallback. Each rung's copies are
estimated at the per-session delta: the template's allocated size, less the read-only `data.bin`. A
rung is refused when N × K deltas plus 10% exceed the free space. `disk_read_max_mbs` is measured in
`workspaces/` as the sum of 4 concurrent direct-I/O readers of separate 2 GiB files; one stream does not
saturate an EBS volume. The single-stream figure is kept as `disk_read_single_mbs`.

| | |
|---|---|
| Host | AWS `m7i.metal-24xl`, **bare metal** (`systemd-detect-virt`: none), **96 vCPU, 377 GiB RAM, no swap** |
| Virtualization | none; Firecracker runs directly on KVM (`/dev/kvm` root:kvm 0660) |
| OS / kernel | Ubuntu 24.04.5 LTS, 7.0.0-1014-aws |
| Firecracker | v1.17.0 (bootstrap.sh); guests have **1 vCPU** (`deploy/microvm/build-snapshot.sh`) |
| Disk | 200 GB EBS root volume (`/dev/nvme0n1`, ext4) + an EBS gp3 data volume, XFS `reflink=1`, mounted at `/srv/e15` |
| cgroups | v2 |
| Software | fresh: no docker, podman, go, node, pnpm or firecracker before bootstrap; stock services only |
| Access | user `ubuntu`, passwordless sudo |

## 14. Left to the builder

- Which open-source Python project the workspace holds, within §5.6's constraints.
- The command library's invocations per class, and the generated scripts' run-time grades.
- The driver's internal structure, flags and log format, beyond the fields in §6.3 and §9.3.
- How the worker's stats are collected (log lines or a stats endpoint).
- Whether the patch's tests are Go tests or a shell harness, as long as they run on the rig before
  the first measured rung.
- The runbook's step-by-step form.

## 15. Decisions taken during design

| question | decision | by |
|---|---|---|
| What drives the load | a small replay driver, no agent and no model | Paolo |
| Resident arm's build | matched Firecracker build, same stack as SBX | Paolo |
| Where the resident arm lives | a rig-only patch in moca-experiments, never in the moca repo | Paolo |
| What the result decides | whether SBX holds more sessions per host than resident VMs | Paolo |
| Where the spec and artifacts live | moca-experiments | Paolo |
| What "holds N" means | §8 | Paolo |
| Standby depth | SBX 2, resident 0 | Paolo |
| Polled Codex commands | real lifetime (2 h cap); CPU only for recorded work time | Paolo |
| Commands | real commands of the recorded class, from TraceLab v0.0.2's executable lists | Paolo |
| Default human-gap cap `H` | 30 minutes | our call |
| Claude duration cap | 30 s | our call |
| Overlapping calls on one VM | run one at a time in both arms (guest agent has one parked shell) | our call |
| Workspace seeding | built on host disk before the rung, outside the measured load | our call |
| Results per provider | split inside mixed runs, no separate ladders | our call |
| Host-infrastructure stand-in | half `sleep`, half interpreter | our call |
| Per-user share of a population | at most 15% | our call |
| Predictions | direction fixed now; numbers sealed after calibration | our call |

---

_Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>_
