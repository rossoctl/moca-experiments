# E14 — coding agents on per-Exec microVM hands

**What was tested.** Can stock coding agents, Claude Code and OpenCode, do real work when every
command they run goes to a fresh Firecracker microVM, and what does it cost?

- **The idea:** "brain stays local, hands go remote", the wave-0 premise of the SBX1 sandbox-service
  design: coding agents reach a per-Exec microVM tier through a hosted MCP server or a thin client.
  SBX1 is an internal draft, not yet published; where this record cites it (§N, D15, O12), those
  are its section, decision and open-question numbers.
- **The agents:** unmodified, run from a developer laptop.
- **The sandbox:** the P4 microVM tier, with an exploratory sandbox-service front door in front of it.

**Status.** A spike, run 2026-10-09 to 2026-10-12. The code is prototype grade. Every number below
comes from the run logs. One run per cell throughout, so treat differences of one task or one
issue as noise.

**Reading order.**
- [`RESULTS-SUMMARY.md`](RESULTS-SUMMARY.md) is the short version.
- This file is the record. On any disagreement, it wins.
- [`RUNBOOK.md`](RUNBOOK.md) is how to replicate it, and [`HARNESS.md`](HARNESS.md) holds every
  script and config used.

---

## Contents

1. [Setup](#1-setup)
2. [Per-call latency and the per-Exec claims](#2-per-call-latency-and-the-per-exec-claims)
3. [Round 1 — smoke tasks](#3-round-1--smoke-tasks)
4. [Round 2 — a real-project feature (Python-Markdown)](#4-round-2--a-real-project-feature-python-markdown)
5. [Round 3 — SWE-bench Verified subset, stock vs remote](#5-round-3--swe-bench-verified-subset-stock-vs-remote)
6. [Findings from building it](#6-findings-from-building-it)
7. [Limits and caveats](#7-limits-and-caveats)

---

## 1. Setup

### The two ways in

| | MCP path | gRPC path |
| --- | --- | --- |
| **What the agent sees** | `read`, `write`, `edit`, `bash`, `grep`, `find`, `ls` as MCP tools | its own shell, allowed to run only `sbx run` / `sbx put` |
| **Client** | `sandbox-mcp`: a streamable-HTTP MCP server next to the relay, serving Pi's seven tools over `GrpcRelayTransport` | `sbx`: a ~110-line Python CLI over `sandbox/v1` `SandboxExec` |
| **Laptop needs** | nothing but the agent | the `sbx` CLI, Python, gRPC stubs |
| **Push / pull of the tree** | `sbx-push.sh` / `sbx-pull.sh` over HTTP | `sbx push` / `sbx pull` |
| **Used in** | rounds 1–2 (AWS rig) | rounds 1–3 (bare-metal rig) |

Both paths use the same sandbox semantics:
- **Push:** replaces `/workspace` with the laptop tree (git-tracked plus untracked, minus ignored),
  then commits it in the sandbox as a baseline.
- **Pull:** returns `git diff --binary` against that baseline, untracked files included. Common
  build output (`__pycache__`, `node_modules`, `.venv`, …) is excluded through `.git/info/exclude`.

### Agent configuration

**MCP path.**
- Claude Code: `.mcp.json` (`"type": "http"`) plus a `.claude/settings.json` that allows
  `mcp__sandbox__*` and denies `Bash Read Edit Write Glob Grep NotebookEdit WebFetch WebSearch Agent
  Task EnterWorktree ExitWorktree Workflow`.
- OpenCode: an `opencode.json` `mcp` entry (`"type": "remote"`), with every built-in tool set to
  `false`.

**gRPC path.**
- Claude Code: `--allowedTools 'Bash(sbx run:*)' 'Bash(sbx put:*)'`, with every file tool in
  `--disallowedTools`.
- OpenCode: a `bash` permission map, `"*": "deny"`, allowing `"sbx run*"` and `"sbx put *"`, with
  the other built-ins disabled.

**Instructions to the model, both paths.** `AGENTS.md` / `CLAUDE.md` says:
- the code is in a remote sandbox at `/workspace`;
- every call is a fresh VM, and no process survives it;
- files under `/workspace` persist;
- there is no network, and one command runs at a time, so batch work.

All exact files are in [`HARNESS.md`](HARNESS.md) §2–3.

**Versions and model.** Claude Code 2.1.286 and OpenCode 1.18.35, both driving
`aws/claude-sonnet-5-5` (Claude Sonnet 5.5) through a LiteLLM gateway. OpenCode uses an
`@ai-sdk/openai-compatible` provider.

**Gotchas found while setting up:**
- **Claude Code project trust.** Claude Code ignores a project `.claude/settings.json`
  `permissions.allow` until the folder has been trusted interactively. Headless runs therefore pass
  everything as flags.
- **Leftover laptop tools on the MCP path.** With the built-ins denied, Claude Code still offered
  `EnterWorktree`, `ExitWorktree` and `Workflow`, which act on the laptop. They are now in the
  deny list.
- **Headless stdin.** Both CLIs need stdin closed (`< /dev/null`). Without it, OpenCode hung for
  10 minutes.

### Rigs

| | AWS rig (rounds 1–2, MCP path) | Bare-metal rig (rounds 1–3, gRPC path) |
| --- | --- | --- |
| Host | EC2 instance with nested KVM | Supermicro SYS-7049GP-TRT: Xeon Gold 6150, 72 cores, 754 GB, Ubuntu 24.04, kernel 6.8 |
| Sandbox tier | P4 under the host's P6 install. `sh-relay` swapped onto a copy carrying client tokens, through a systemd drop-in | a standalone backend beside the host's P6, sharing nothing with it: its own relay (attach `:9543`, exec `127.0.0.1:9544`), Redis (`:6390`), `microvm-worker` and `/srv/sbx/*` |
| Firecracker | v1.17.0, CI kernel 6.18.44 | v1.17.0, CI kernel 6.18.51 |
| Guest | rootfs of `ghcr.io/rossoctl/moca-remote-worker:latest` (bash, git, rg, Python 3.9.25; no tar), 256 MiB RAM, no network device | same image, and for round 3 also mpmath, asgiref, typing_extensions, sqlparse, pytz, tzdata, and a `workspace.pth` putting `/workspace` on `sys.path` |
| Worker | standby depth 2, guest 256 MiB, 8 GiB budget | standby depth 2, guest 256 MiB, 24 GiB budget, 16 slots |
| Reached by | SSH tunnel to the MCP server (`127.0.0.1:8787`) | SSH tunnel through a jump host to the relay's exec port |

**Relay client tokens.** Main repo, `pdettori/moca` branch `feat/relay-client-tokens`, commit
`467b874` (based on `73f1bf4`).
- `MOCA_RELAY_CLIENT_TOKENS` entries have the form `<sandbox_id>:<workspace_key_prefix>:<token>`.
- A client token may only Exec on its worker, only with a key under its prefix, and may only Abort
  its own Execs. Anything else gets `PERMISSION_DENIED`, before the call reaches a worker.
- The harness's `MOCA_RELAY_EXEC_TOKEN` is unchanged.
- Every run used one token for worker `moca_microvm_0`, prefix `sbx-exec-`.
- The branch also carries `docs/api/sandbox-v1-direct-client.md`, a guide for direct clients.

---

## 2. Per-call latency and the per-Exec claims

**AWS rig, through the MCP server.** p50 of 5 calls, laptop to rig, including about 80 ms of
tunnel round trip. Measured after the [pre-check fix](#61-every-pre-check-was-a-vm).

| Tool | p50 | VMs per call |
| --- | --- | --- |
| `bash` | 218 ms | 1 |
| `read` | 229 ms | 1 |
| `ls` | 228 ms | 1 |
| `grep` | 238 ms | 1 |
| `find` | 229 ms | 1 |
| `write` | 241 ms | 1 |
| `edit` | ~450 ms | 2 |
| push (5 files) | 570 ms | 1 |

So a fresh VM costs roughly **150 ms per call** on the nested-virt host. **Six parallel reads took
1.17 s**: they ran one after another, because the ext4 workspace image can be mounted read-write by
only one VM at a time.

**Bare-metal rig, through `grpcurl` on the host, client token:**
- the cold first Exec of a new workspace took **214 ms**;
- warm Execs took **68–91 ms**;
- through the jump-host tunnel from the laptop, `sbx` calls took **70–200 ms**;
- the guide's 3-call Python example took 573 ms end to end, against 1.3 s on the AWS rig.

**The per-Exec claims, checked on the AWS rig:**

| Claim | Check | Result |
| --- | --- | --- |
| No process survives a call | `nohup sleep 600 &` in one call, count `sleep` in `/proc` in the next | 1, then **0** |
| Only `/workspace` persists | write `/tmp/marker` and `/workspace/.marker`, read both next call | `/tmp` gone, **`/workspace` kept** |
| No network | DNS lookup, list interfaces | **DNS fails, only `lo`** |

**Client-token enforcement, checked on both rigs:**
- another workspace's key, the bare prefix, another worker id: `PERMISSION_DENIED`;
- an unknown token: `UNAUTHENTICATED`;
- the harness token: still unrestricted.

---

## 3. Round 1 — smoke tasks

**Repos.** Two toy Python repos:
- `calc`: `add` returns `a - b`.
- `inventory`: 3 failing tests whose root cause is in `pricing.apply_discount`, two modules away.

**Tasks.**
- **T1:** "Fix the failing test… add `subtract`… with a test… run the tests."
- **T2:** "The test suite fails. Find the root cause… minimal change… don't modify the tests."

| Task | Agent | Path | Tool calls | Sandbox calls | Sandbox time | Wall clock | Result |
| --- | --- | --- | --- | --- | --- | --- | --- |
| T1 | Claude Code | MCP | 2 | 2 | 0.5 s | 26 s | correct |
| T1 | OpenCode | MCP | 4 | 4 | 1.0 s | 43 s | correct |
| T2 | Claude Code | MCP | 3 | 3 | 0.8 s | 47 s | correct, the one-line fix |
| T2 | OpenCode | MCP | 3 | 3 | 0.9 s | 19 s | correct, the one-line fix |
| T1 | Claude Code | gRPC | 2 | 4 | 0.5 s | 102 s | correct |
| T1 | OpenCode | gRPC | 2 | 4 | 0.5 s | 65 s | correct |
| T2 | Claude Code | gRPC | 3 | 3 | 0.4 s | 154 s | correct, the one-line fix |
| T2 | OpenCode | gRPC | 3 | 3 | 0.4 s | 498 s | correct, the one-line fix |

- **Wall clock across paths is not comparable.** On the gRPC day the gateway was slow: one
  OpenCode model call took 340 s, and Claude Code's T1 spent 97 of its 102 s in model API time.
- **There are more sandbox calls than tool calls on the gRPC path** because one shell call
  sometimes chained several `sbx` commands.
- **No agent ran anything locally.** There were zero permission denials, but a denial count cannot show
  that on its own: a command the allow-list wrongly admits runs instead of being denied. The evidence
  is the commands themselves. All 134 shell commands from the 29 remote-mode runs of all three rounds
  consist only of `sbx run` / `sbx put` segments, once heredoc bodies (the script sent to the
  sandbox) are set aside (`audit_commands.py`, `HARNESS.md` §5).

---

## 4. Round 2 — a real-project feature (Python-Markdown)

**Project.** Python-Markdown 3.7: 499 files, 951 tests, stdlib only.

**Environment.**
- Markdown needs the `importlib_metadata` backport on Python < 3.10, which an offline Python 3.9
  sandbox cannot install. A small shim (`HARNESS.md` §4) reads the entry points from
  `pyproject.toml`, as an editable install would, so an extension the agent registers there works.
  It was committed before the baseline, so it is never part of a patch.
- **Baseline:** 9 pre-existing problems. `test_apis` needs PyYAML, and 8 HTML tests differ under
  Python 3.9.25's `html.parser`. The prompt names them.

**Task.** Add a built-in `strikethrough` extension (`~~text~~` → `<del>`), following the project's
conventions: implementation, registration, tests, docs page, index link. Run the suite at the end.
Each agent ran twice per path.

**Grading.** Each patch was applied to a clean copy and checked in the sandbox with:
- the full suite, against the baseline;
- 10 hidden behaviour checks: basic, inline, dotted module name, code span untouched, single `~`
  untouched, nested emphasis, not enabled by default, two on a line, unclosed left alone, fenced
  code untouched.

| Path | Run | Tool calls | Sandbox calls | Sandbox time | Wall clock | Input / output tokens | Patch | Result |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| MCP | Claude Code a | 6 | 6 | 3.0 s | 108 s | 154k / 4.8k ($0.15) | 6 files, 14 tests | 10/10, suite at baseline |
| MCP | Claude Code b | 6 | 6 | 3.2 s | 104 s | 150k / 5.1k ($0.12) | 6 files, 17 tests | 10/10, suite at baseline |
| MCP | OpenCode a | 13 | 13 | 5.4 s | 163 s | 278k / 10.6k | 7 files, 23 tests | 10/10, suite at baseline |
| MCP | OpenCode b | 8 | 8 | 3.8 s | 119 s | 153k / 7.8k | 7 files, 17 tests | 10/10, suite at baseline |
| gRPC | Claude Code a | 6 | 6 | 3.7 s | 141 s | 181k / 4.8k ($0.16) | 7 files, 10 tests | 10/10, suite at baseline |
| gRPC | Claude Code b | 4 | 7 | 3.4 s | 336 s | 100k / 5.0k ($0.13) | 7 files, 12 tests | 10/10, suite at baseline |
| gRPC | OpenCode a | 12 | 14 | 4.6 s | 301 s | 231k / 8.9k | 7 files, 24 tests | 10/10, suite at baseline |
| gRPC | OpenCode b | 10 | 13 | 3.0 s | 285 s | 191k / 11.7k | 7 files, 29 tests | 10/10, suite at baseline |

- **All 8 implementations are correct**, and all follow the conventions: an entry point in
  `pyproject.toml`, the `mkdocs.yml` nav entry, the docs index, and usually the changelog.
- **Neither agent ever used `read`, `grep`, `find` or `ls` on the MCP path, and there were no
  parallel calls.** Both explored through `bash`, printing several files per call. For these
  agents with these instructions, read coalescing would have saved nothing.
- **gRPC OpenCode a was a rerun.** The first attempt hit the runner's 900 s limit with 694 s spent
  waiting on the gateway (one wait was 332 s). It had already written the extension, registration
  and tests. Its logs are kept; the rerun used a 2400 s limit.

---

## 5. Round 3 — SWE-bench Verified subset, stock vs remote

### Instances

From SWE-bench Verified (`princeton-nlp/SWE-bench_Verified`):
- **Filter:** sympy 1.5–1.12 and django 3.2–4.2, all of which run on Python 3.9.
- **Draw:** shuffled with `random_state=7`. Per project, the first 2 "<15 min fix" and the first 3
  "15 min – 1 hour" instances whose gold patch verified ([Grading and verification](#grading-and-verification)).
- **Dropped:**
  - `django-13658`: a test downloads a project template from a URL, and there is no network.
  - `django-16315`: 4 `PASS_TO_PASS` `bulk_create` tests fail even with the gold patch.

| Issue | Version | Difficulty | Files in the gold patch | FAIL_TO_PASS | PASS_TO_PASS |
| --- | --- | --- | --- | --- | --- |
| sympy-19637 | 1.7 | <15 min | 1 | 1 | 40 |
| sympy-18189 | 1.6 | <15 min | 1 | 1 | 41 |
| sympy-18211 | 1.6 | 15 min – 1 h | 1 | 1 | 54 |
| sympy-20438 | 1.8 | 15 min – 1 h | 3 | 2 | 93 |
| sympy-17318 | 1.5 | 15 min – 1 h | 2 | 1 | 10 |
| django-14534 | 4.0 | <15 min | 1 | 2 | 118 |
| django-14765 | 4.0 | <15 min | 1 | 1 | 64 |
| django-13012 | 3.2 | 15 min – 1 h | 1 | 2 | 137 |
| django-14034 | 4.0 | 15 min – 1 h | 1 | 1 | 12 |
| django-15098 | 4.1 | 15 min – 1 h | 1 | 2 | 88 |

### Grading and verification

**The grader** (`grade.py`), for every run:
1. push the history-free base tree to a fresh sandbox workspace;
2. apply the run's patch;
3. reset the test files the hidden test patch touches;
4. apply the hidden test patch;
5. run SWE-bench's own test command:
   - sympy: `bin/test -C --verbose <files>`;
   - django: `tests/runtests.py --verbosity 2 --settings=test_sqlite --parallel 1 <labels>`;
6. parse the output the way SWE-bench's `parse_log_sympy` / `parse_log_django` do.

**Resolved** = every `FAIL_TO_PASS` and `PASS_TO_PASS` test passes. Every run, stock or remote, was
graded the same way, in the sandbox.

After review, the grader was hardened on its failure paths: a failed `sbx` call is now an error,
not a wrong fix, and errored grades are never cached. All 40 runs were re-graded with it, and every
outcome was identical, including the counts of failing `FAIL_TO_PASS` and `PASS_TO_PASS` tests.

**Verification before any agent ran:** 16 of the 18 candidates resolved with their gold patch, and
their untouched base failed every `FAIL_TO_PASS` test. The two that did not were dropped (above).

**Two environment fixes this needed:**
- **Django needs to be importable.** SWE-bench installs it editable. Here a `workspace.pth` in the
  guest puts `/workspace` on `sys.path`, and stock runs set `PYTHONPATH` to their checkout.
- **Timezone data.** Django's tests need zoneinfo data and the rootfs has none, so the `tzdata`
  wheel provides it.

### Modes

| | Stock | Remote (gRPC path) |
| --- | --- | --- |
| Where commands run | the laptop | a fresh microVM per call, bare-metal rig |
| Agent tools | all its own (Claude Code: `--permission-mode bypassPermissions`; OpenCode: `"*": "allow"`) | shell restricted to `sbx run` / `sbx put` |
| Python | 3.9.21 venv with the same pins; `PYTHONPATH` = the checkout | guest 3.9.25 with the same pins; `/workspace` on `sys.path` |
| Both | web tools denied; subagents allowed; a fresh history-free checkout per run | |

- **Prompt:** the issue text, plus "Resolve the issue above by changing the source code. Make the
  minimal change to non-test files… Do not modify existing tests: hidden tests will check your
  fix", a line on Python and imports, and the project's test command. Exact text: `run.sh`.
- **Scheduling:** each issue's four variants (2 agents × 2 modes) ran concurrently, so every mode
  saw the same gateway conditions. Issues ran one after another.

### Results

| Issue | Claude Code, stock | Claude Code, remote | OpenCode, stock | OpenCode, remote |
| --- | --- | --- | --- | --- |
| sympy-19637 | ✓ | ✓ | ✓ | ✓ |
| sympy-18189 | ✓ | ✓ | ✓ | ✓ |
| sympy-18211 | ✓ | ✓ | ✓ | ✓ |
| sympy-20438 | ✗ | ✗ | ✗ | ✗ |
| sympy-17318 | ✓ | ✓ | ✗ | ✓ |
| django-14534 | ✓ | ✓ | ✓ | ✓ |
| django-14765 | ✓ | ✓ | ✓ | ✓ |
| django-13012 | ✓ | ✓ | ✓ | ✓ |
| django-14034 | ✗ | ✗ | ✗ | ✗ |
| django-15098 | ✓ | ✓ | ✓ | ✓ |
| **Resolved** | **8/10** | **8/10** | **7/10** | **8/10** |

| Variant | Mean tool calls | Median wall clock | Median model time | Median sandbox time | Mean input / output tokens | Cost (10 runs) |
| --- | --- | --- | --- | --- | --- | --- |
| Claude Code, stock | 4.4 | 112 s | 106 s | — | 102k / 1.2k | $0.91 |
| Claude Code, remote | 3.5 | 123 s | 117 s | 2.1 s | 78k / 1.1k | $0.81 |
| OpenCode, stock | 6.0 | 90 s | 59 s | — | 89k / 2.4k | — |
| OpenCode, remote | 4.8 | 113 s | 82 s | 6.5 s | 67k / 2.5k | — |

How these are measured:
- **Model time:** Claude Code's reported `duration_api_ms`. For OpenCode, the sum of waits before
  each model step, since its stream emits `step_start` only after the model answers.
- **Sandbox time:** the sum of `sbx` call durations from the client log.
- **Input tokens** include cache reads and writes.
- **Cost** is Claude Code's own `total_cost_usd`. OpenCode reports none through the gateway.

**Findings:**
- **No measurable difference in solve rate at this sample size.**
  - Claude Code resolved the same 8 issues in both modes.
  - OpenCode resolved one more remotely (`sympy-17318`): the stock run changed only `radsimp.py`,
    while the gold patch also changes `sqrtdenest.py`. At one run per cell that is noise.
- **Every failure is a genuine wrong fix, and the two shared ones are the same in every mode.** None
  came from the environment or the sandbox.
  - `django-14034`: every variant patched `django/forms/fields.py`; the gold patch changes
    `forms/boundfield.py`.
  - `sympy-20438`: every variant made a partial fix of a 3-file change.
- **Stock agents barely use their file tools.** Across the 10 stock runs:
  - Claude Code: 36 `Bash`, 7 `Edit`, 1 `Read`.
  - OpenCode: 51 `bash`, 5 `edit`, 3 `grep`, 1 `read`.

  Restricting them to a sandboxed shell removes little that they rely on.
- **It is slightly slower, and not because of the VMs.** Median wall clock is 10% higher for Claude
  Code and 26% higher for OpenCode (113 s against 89.5 s). The sandbox itself took a median of
  2–7 s per run; the rest is model-time variance between runs. Measured as median sandbox time over
  median wall clock, the sandbox is 2–6% of a run. Summed over all runs it is higher: 7.3% for
  OpenCode remote (139 s of 1,915 s), and single runs reach 17% (`oc-sbx` on `sympy-18211`,
  20.6 s of 124 s).
- **Remote runs used about 24% fewer input tokens**, and Claude Code cost 11% less. The agents
  batched more per call, as the remote `AGENTS.md` asks, so there are fewer turns re-sending
  context. That instruction, not the sandbox, is the likely cause.

### Per run

| Issue | Variant | Resolved | Tool calls | Sandbox calls | Sandbox s | Model s | Wall s | Input tok | Output tok | Cost |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| django-13012 | cc-stock | yes | 3 | 0 | 0.0 | 28 | 32 | 55k | 0.7k | $0.041 |
| django-13012 | cc-sbx | yes | 2 | 2 | 2.0 | 460 | 465 | 48k | 0.6k | $0.096 |
| django-13012 | oc-stock | yes | 5 | 0 | 0.0 | 73 | 105 | 59k | 0.9k | - |
| django-13012 | oc-sbx | yes | 2 | 2 | 2.3 | 32 | 56 | 29k | 0.6k | - |
| django-14034 | cc-stock | no | 4 | 0 | 0.0 | 56 | 61 | 75k | 1.0k | $0.076 |
| django-14034 | cc-sbx | no | 5 | 5 | 5.2 | 376 | 385 | 104k | 1.6k | $0.107 |
| django-14034 | oc-stock | no | 6 | 0 | 0.0 | 89 | 130 | 88k | 3.2k | - |
| django-14034 | oc-sbx | no | 9 | 9 | 11.2 | 181 | 218 | 128k | 7.8k | - |
| django-14534 | cc-stock | yes | 5 | 0 | 0.0 | 106 | 112 | 92k | 1.0k | $0.079 |
| django-14534 | cc-sbx | yes | 2 | 2 | 0.4 | 78 | 82 | 61k | 0.4k | $0.069 |
| django-14534 | oc-stock | yes | 5 | 0 | 0.0 | 30 | 52 | 60k | 1.4k | - |
| django-14534 | oc-sbx | yes | 3 | 3 | 6.9 | 78 | 102 | 38k | 1.1k | - |
| django-14765 | cc-stock | yes | 2 | 0 | 0.0 | 755 | 760 | 54k | 0.5k | $0.063 |
| django-14765 | cc-sbx | yes | 2 | 2 | 0.5 | 73 | 77 | 60k | 0.5k | $0.038 |
| django-14765 | oc-stock | yes | 3 | 0 | 0.0 | 12 | 42 | 45k | 0.6k | - |
| django-14765 | oc-sbx | yes | 2 | 2 | 5.5 | 59 | 100 | 26k | 0.6k | - |
| django-15098 | cc-stock | yes | 7 | 0 | 0.0 | 88 | 105 | 168k | 2.5k | $0.120 |
| django-15098 | cc-sbx | yes | 9 | 9 | 12.8 | 1178 | 1195 | 171k | 2.6k | $0.178 |
| django-15098 | oc-stock | yes | 12 | 0 | 0.0 | 515 | 584 | 187k | 7.1k | - |
| django-15098 | oc-sbx | yes | 5 | 5 | 6.1 | 398 | 426 | 74k | 2.4k | - |
| sympy-17318 | cc-stock | yes | 7 | 0 | 0.0 | 129 | 137 | 145k | 2.0k | $0.106 |
| sympy-17318 | cc-sbx | yes | 3 | 3 | 4.7 | 401 | 409 | 72k | 1.6k | $0.110 |
| sympy-17318 | oc-stock | no | 6 | 0 | 0.0 | 443 | 532 | 97k | 3.4k | - |
| sympy-17318 | oc-sbx | yes | 9 | 9 | 67.9 | 464 | 573 | 126k | 6.7k | - |
| sympy-18189 | cc-stock | yes | 4 | 0 | 0.0 | 105 | 111 | 95k | 0.8k | $0.051 |
| sympy-18189 | cc-sbx | yes | 3 | 3 | 1.7 | 97 | 103 | 65k | 0.7k | $0.043 |
| sympy-18189 | oc-stock | yes | 5 | 0 | 0.0 | 39 | 56 | 61k | 1.2k | - |
| sympy-18189 | oc-sbx | yes | 3 | 3 | 1.7 | 49 | 81 | 41k | 0.6k | - |
| sympy-18211 | cc-stock | yes | 4 | 0 | 0.0 | 257 | 264 | 137k | 1.1k | $0.110 |
| sympy-18211 | cc-sbx | yes | 2 | 2 | 1.9 | 105 | 111 | 50k | 1.1k | $0.046 |
| sympy-18211 | oc-stock | yes | 4 | 0 | 0.0 | 42 | 66 | 59k | 1.4k | - |
| sympy-18211 | oc-sbx | yes | 4 | 4 | 20.6 | 86 | 124 | 49k | 1.4k | - |
| sympy-19637 | cc-stock | yes | 3 | 0 | 0.0 | 98 | 104 | 71k | 0.7k | $0.069 |
| sympy-19637 | cc-sbx | yes | 4 | 4 | 2.3 | 129 | 135 | 80k | 0.9k | $0.069 |
| sympy-19637 | oc-stock | yes | 4 | 0 | 0.0 | 44 | 74 | 56k | 0.7k | - |
| sympy-19637 | oc-sbx | yes | 4 | 4 | 3.9 | 62 | 87 | 47k | 0.8k | - |
| sympy-20438 | cc-stock | no | 5 | 0 | 0.0 | 754 | 765 | 129k | 1.4k | $0.197 |
| sympy-20438 | cc-sbx | no | 3 | 3 | 9.3 | 58 | 71 | 70k | 1.3k | $0.054 |
| sympy-20438 | oc-stock | no | 10 | 0 | 0.0 | 106 | 206 | 178k | 3.8k | - |
| sympy-20438 | oc-sbx | no | 7 | 7 | 12.9 | 109 | 148 | 110k | 2.9k | - |

The per-run wall clocks above 700 s (`cc-stock` on 14765 and 20438, `cc-sbx` on 15098) are model
time, not sandbox or agent time. Two runs, `cc-stock-20438` and `cc-sbx-18189`, logged gateway
retries but completed, and they count.

### The outage, and the reruns

Partway through the batch, the laptop's VPN dropped for about 25 minutes. That took both the gateway and the
jump-host tunnel with it.
- **What failed:** `sbx` calls failed in about 3 ms with exit 125, and Claude Code retried the API.
- **What was discarded:** the 8 runs of `sympy-17318` and `django-14534`, which were rerun after
  the gateway came back.
- **What changed in the batch:** before each issue it now checks that the gateway answers and an
  `sbx run true` succeeds, reopening the tunnel if needed. Afterwards it discards and reruns (once)
  any run with an exit-125 sandbox call or exhausted gateway retries.
- **The remaining 32 runs** have no failed sandbox calls.

---

## 6. Findings from building it

### 6.1 Every pre-check was a VM

Measured through the MCP server, which runs MOCA's own Pi tool implementations. Pi's file tools probe
before they act, and on this tier every probe is a whole VM.

| Tool | As first built | After merging pre-checks |
| --- | --- | --- |
| `read` | 3 (access, MIME probe, `cat`) | 1 |
| `edit` | 3 (access, read, write) | 2 |
| `write` | 2 (`mkdir`, write) | 1 |
| `find` | 2 (exists, glob) | 1 |
| `ls` | 3 + one per entry | 1 |

Listing a small directory went from **1.9 s to 0.23 s**.
- **The fix:** `packages/sandbox-mcp/src/fewer-execs.ts`, `HARNESS.md` §3.
- **Still open:** the SBX1 spec's single-Exec `edit` would make `edit` one VM too.

In every MCP-path run of rounds 1–2, calls arrived one at a time (the call logs' maximum concurrency
was 1); round 3 did not measure it. That makes per-call cost the lever for these agents, ahead of
read coalescing (SBX1 D15).

### 6.2 Defects found and fixed in the client layer

- **Wrong `find` paths.** `find` returned paths built from the server's working directory
  (`../Users/…`). Pi relativizes glob results with `path.relative`, which resolves against the
  process working directory. MOCA never hits this, because its process directory always matches the
  workspace.
- **Search walked `.git/`.** `grep`/`find` searched `.git/`, because the pod tools' ripgrep runs
  with `--hidden`. The sandbox always has a `.git` (the push baseline).
- **macOS archive junk.** macOS `tar` adds `._*` AppleDouble files; `COPYFILE_DISABLE=1` stops it.
- **Build output in pull patches.** Pull patches included `__pycache__` in repos without a
  `.gitignore` (SBX1 O12). The baseline now excludes common build output.
- **No `tar` in the image.** The sandbox image ships `python3` and `git` but not `tar`/`gzip`, so
  push extracts with Python's `tarfile`.
- **`req_id` and JavaScript numbers.** `req_id` is `uint64` in `sandbox.proto`, but the TypeScript
  relay decodes it as a JavaScript `number`. A client sending a value ≥ 2^53 gets `INTERNAL`
  (`Value is larger than Number.MAX_SAFE_INTEGER`) before auth even runs. Clients must stay below
  2^53.

---

## 7. Limits and caveats

- **Sample size.** One run per cell, and only 10 SWE-bench issues. A difference of one issue is
  noise; about 30 issues × 3 runs would be the next step.
- **No network in the guest.** Every dependency was pre-baked, so these results say nothing about
  installing packages. That needs allowlisted egress (experiment E12, SBX1 sub-project 5a).
- **Demo-grade access.** SSH tunnels and static, scoped relay tokens, not the SBX1 lifecycle API,
  signed per-sandbox tokens or OAuth.
- **The agents ran with deliberately broad permissions.** Know where each boundary sits before
  reusing the setup:
  - **Stock mode:** Claude Code ran with `--permission-mode bypassPermissions`, and OpenCode with
    `"*": "allow"`. Agent commands executed on the laptop unprompted, in scratch checkouts.
  - **Remote mode:** the agent's shell allow-list is the only thing keeping commands off the laptop:
    Claude Code's `Bash(sbx run:*)` and `Bash(sbx put:*)`, OpenCode's `"sbx run*"` and `"sbx put *"`.
    A matcher that admits a compound command (`sbx run … && <local command>`) would run its other half
    locally, and that would not show up as a denial. OpenCode's glob is the case at risk. The command
    audit found no such command in any remote-mode run (round 1 findings above).
  - **MCP path:** the MCP server's HTTP endpoint has no authentication. It binds `127.0.0.1` and is
    reached only through an SSH tunnel; anyone who can reach that port can run commands in its
    workspace.
- **Wall clock is only comparable within a batch.** Gateway latency varied by more than 10× across
  the four days.
- **Python patch versions differ.** The stock venv was Python 3.9.21 and the guest 3.9.25. All
  grading ran in the guest, so scores are unaffected.
