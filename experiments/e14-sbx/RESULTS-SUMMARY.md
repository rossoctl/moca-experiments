# E14 — coding agents on per-Exec microVM hands: results summary

**An entry point, not a source of truth.** Every number here is copied from
[`EXPERIMENTS.md`](EXPERIMENTS.md). On any disagreement **`EXPERIMENTS.md` wins**: fix it there,
then here.
- To replicate, follow [`RUNBOOK.md`](RUNBOOK.md).
- Every script and config is in [`HARNESS.md`](HARNESS.md).

---

## The headline

**Stock Claude Code and OpenCode, with every command running in a fresh Firecracker microVM, solved
about as many SWE-bench issues as when they ran on the laptop: no measurable difference at this
sample size.**

- 10 SWE-bench Verified issues (5 sympy, 5 django), each agent in two modes:
  - **stock:** all its tools, on a laptop;
  - **remote:** its shell restricted to a sandbox CLI.
- 40 runs, all graded the same way in a fresh VM by the issue's hidden tests.

| | Stock (laptop) | Remote (microVM per command) |
| --- | --- | --- |
| Claude Code | **8/10** | **8/10** |
| OpenCode | **7/10** | **8/10** |

- **The two issues every variant missed are genuine wrong fixes, the same in every mode.** No
  failure came from the sandbox or the environment.
- **OpenCode's one-issue gap** (`sympy-17318`, missed on the laptop only) is noise at one run per
  cell.
→ [Round 3](EXPERIMENTS.md#5-round-3--swe-bench-verified-subset-stock-vs-remote)

## Where the time goes

| Variant | Median wall clock | Median model time | Median sandbox time |
| --- | --- | --- | --- |
| Claude Code, stock | 112 s | 106 s | — |
| Claude Code, remote | 123 s | 117 s | **2.1 s** |
| OpenCode, stock | 90 s | 59 s | — |
| OpenCode, remote | 113 s | 82 s | **6.5 s** |

**Median sandbox time is 2–6% of median wall clock, and the model sets the pace.** Summed over all
runs it is higher: 7.3% for OpenCode remote (139 s of 1,915 s), and single runs reach 17%. Remote
runs are 10–26% slower at the median. That gap is model-time variance, not VMs.

**Cost of one command:**

| Rig | Warm Exec | Cold first Exec | Per tool call, laptop to rig |
| --- | --- | --- | --- |
| Bare metal | 68–91 ms | 214 ms | 70–200 ms |
| AWS, nested virtualization | about 150 ms | — | about 220 ms |

→ [Latency](EXPERIMENTS.md#2-per-call-latency-and-the-per-exec-claims)

## What surprised us

- **Stock agents barely use their file tools.** Across 10 stock runs, Claude Code made 36 `Bash`
  calls against 7 `Edit` and 1 `Read`; OpenCode was similar. A sandboxed shell takes away little they
  rely on.
- **Remote runs used about 24% fewer input tokens**, and Claude Code cost 11% less. Told that every
  call is a fresh VM, the agents batched more work per call. The instruction, not the sandbox, is
  the likely cause.
- **No agent sent parallel calls** where we measured it (rounds 1–2, MCP path call logs). Read
  coalescing (SBX1 D15) would have saved nothing there. What mattered was **VMs per call**: MOCA's Pi file tools spent a
  VM on every pre-check (`read` 3, `ls` 3 + one per entry). Merging them made every tool one VM
  (`edit` two), and a small directory listing went from 1.9 s to 0.23 s.
  → [Findings](EXPERIMENTS.md#6-findings-from-building-it)
- **No fork, but some configuration traps:**
  - Claude Code ignores a project's `permissions.allow` until the folder is trusted, and still
    offers its worktree and workflow tools when the built-ins are denied.
  - Both CLIs need stdin closed to run headless.

## The per-Exec claims, checked

- A background process started in one call is **gone** in the next.
- `/tmp` is reset between calls, and `/workspace` **persists**.
- The guest has **no network**: DNS fails, and only `lo` exists.
- A client token cannot reach another workspace, another worker, or another client's command
  (`PERMISSION_DENIED`).

## Read with care

- **Small sample:** 10 issues and one run per cell. Only large differences are signal.
- **No network in the guest:** dependencies were pre-baked. Package installs need allowlisted
  egress (E12).
- **Demo-grade access:** SSH tunnels and static, scoped relay tokens, not the SBX1 lifecycle API.
- **One outage:** the gateway and tunnel dropped mid-batch; the 8 affected runs were discarded and
  rerun. [Details](EXPERIMENTS.md#the-outage-and-the-reruns).
- **Wall clock** is comparable only within a batch: gateway latency varied by more than 10× over
  the four days.

## Rounds 1–2, briefly

| Round | Task | Runs | Result |
| --- | --- | --- | --- |
| 1 | Two toy repos: a bug fix plus a feature, and a root cause two modules away | 8 (MCP and gRPC paths) | all correct |
| 2 | Python-Markdown (499 files): add a `strikethrough` extension with tests and docs | 8 (2 per agent per path) | all 8 pass 10/10 hidden checks, suite at baseline |

→ [Round 1](EXPERIMENTS.md#3-round-1--smoke-tasks), [Round 2](EXPERIMENTS.md#4-round-2--a-real-project-feature-python-markdown)
