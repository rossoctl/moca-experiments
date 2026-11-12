# microVM sandbox tier — results summary

**An entry point, not a source of truth.** Every number here is copied from
[`EXPERIMENTS.md`](EXPERIMENTS.md), which is 2,100+ lines because it records each
conclusion *and* every later correction to it, in date order. On any disagreement
**`EXPERIMENTS.md` wins** — if you find one, fix it there and then fix this file.

This exists because that record is written for whoever picks the work up next, and
answers an outside reader's first question ("so what happened?") only after a long read.

---

## The headline

**We built a microVM sandbox tier, measured it against a bar set in advance, and stopped.**

The bar and the decision rule were written into the design spec before the first
measurement ([spec §7.2][spec], recorded 2026-09-09; sealed predictions in
[`predictions.json`](predictions.json), committed 2026-09-10).

| | Measured | Bar | Verdict |
|---|---|---|---|
| Warm hot path p50, bare metal | **52.74 ms** | 15 ms | **STOP** |
| Same, against the container baseline | **1.29x** (baseline 41 ms) | within 2x | prediction 2 supported |

Both are true at once, and the combination is the finding: the warm path is inside 2x of
the container baseline **and** 3.5x the bar, *because the baseline is itself 41 ms*.
"Within 2x of the baseline" and "fast enough" are not the same claim.
→ [E10 — the lifecycle primitive ladder](EXPERIMENTS.md#e10--the-lifecycle-primitive-ladder)

### Where the time goes

```
acquire 0.00 ms   resume 28.58 ms   run 2.85 ms   destroy 21.31 ms   total 55.32 ms
```

A warm acquire is **free** (median 0.00 ms — a standby pop). **Resume and destroy are
49.9 of 55.3 ms.** The design had already moved machine *building* off the hot path; what
remained on it was the whole cost. `total` is the rung's own measured p50, not the sum of
the four — percentiles do not add.

### Nesting taxes destroy harder than resume

| | Metal | Nested | Penalty |
|---|---|---|---|
| resume | 28.58 ms | 78.34 ms | **2.74x** |
| destroy | 21.31 ms | 118.45 ms | **5.56x** |
| warm hot path p50 | 52.74 ms | 200.91 ms | 3.81x |

More specific than the design's own hypothesis, which expected nesting to tax
VM-exit-heavy work evenly. **If you benchmark microVMs in nested CI you will be misled
about which half to optimise.**

---

## The part that did not survive, and why it matters more than the part that did

Three density conclusions were published, then found to rest on a defective instrument
([#291]). The re-run **upheld the STOP** and the knee's position, and **overturned the
reasons given for both**.

| Instrument defect | What it produced | Fix |
|---|---|---|
| Host resources sampled **after** the load stopped | `hostCpuFraction` **0.001**, read as "no CPU ceiling" — a comparison that could never fire, since the threshold is 0.9. In-rung means are **0.067** (microVM) and **0.093** (container); the no-backend arm peaked at **0.9598** | [#291], in-rung 1 Hz sampling |
| Load generator cost inside the timed window — one `execve` per operation (`grpcurl` re-parsing the proto descriptor set per call) | up to **23.7%** of measured p95 | persistent-connection Go client; its share is **<0.4%** |
| An application constant mistaken for a platform ceiling — the worker admitted 4 concurrent Execs whatever concurrency was offered | the entire `c>4` plateau | [#305], [#312] |

**The no-backend control arm is what exposed it.** An arm with no VM, no container, no
worker and a responder that executes nothing **reproduced the published knee** at the same
concurrency, reaching `coresBusy` 64.13 of 72 and `hostCpuFractionPeak` 0.9598 — while the
old sampling method reported 0.0006–0.0010 on that same run. A result your harness
reproduces with the backend removed is a result about your harness.

**What the knee actually measured.** Four slots at the measured 61.4 ms per Exec predicts
**65.1** Exec/s against **62.99** measured — within 3.4%, and it predicts the rest of the
plateau too. Lifting the cap on the same host:

| | Exec/s | p95 | coresBusy /72 |
|---|---|---|---|
| 4 slots, offered concurrency 64 | 62.28 | 1033.82 ms | 4.81 |
| 64 slots | **577.55** | 145 ms | 47.74 |

**9.3x the throughput at one seventh the p95.** The peak is 64 slots, not 8.
→ [Issue #291 — the re-run](EXPERIMENTS.md#issue-291--the-re-run-the-knee-holds-at-c8-and-it-is-the-4-slot-cap)

One rung still resists the model: at offered concurrency 8, four slots predict 64.3
against **80.62** measured — a 20% under-prediction, recorded as open rather than
explained.

---

## Retracted — do not cite

Listed because these numbers were published and are still reachable in the history. Each
is annotated in place in `EXPERIMENTS.md` rather than deleted, which is what makes the
correction auditable.

| Claim | Status |
|---|---|
| "`hostCpuFraction` is 0.001 flat across the entire ladder" — often paraphrased as "host CPU stayed flat at 0.001 through c=64" | **Artifact of the sampling method**, not a measurement: idle host, after the window closed. Re-measured in-rung, the true under-load means are **0.067** (microVM) and **0.093** (container), from 20–284 ticks per rung. |
| "nothing resembling a CPU or memory ceiling was reached" | **Still true, but it was not a finding when first published** — it restated the sampling bug, since `crosses('cpu')` needs `hostCpuFraction >= 0.9` and a post-load 0.0006 can never fire it. It is a real finding *after* the re-run, and the mechanism is the 4-slot cap: `coresBusy` 4.81 of 72 because the server admitted 4 Execs at a time. |
| "`bound` is replenishment **on both arms**" | **Half retracted.** It holds on the **microVM** arm as a genuine crossing at the same `c` as the knee. It does **not** hold on the container arm, where it is `attributeBound`'s fallback rather than a crossing. Separately, the *plateau* is the 4-slot cap, not replenishment: replenishment supplies ~4.5 VMs/s against ~62 Exec/s — 14x apart, so both cannot bound the same ladder. |
| "the knee is at c=8" (as a capacity property) | **Position reproduces; meaning does not.** It locates the slot count and moves when the slot count moves. |
| `coldAcquireRate` | **Wrong by 13x** at c=8 and ~250x beyond (true rates 0.056 and 0.0039). Any argument resting on it is void. |
| Any knee established on a **nested** substrate | Nested runs cannot establish the knee; see the [E11 preamble](EXPERIMENTS.md#e11--density-the-replenishment-ceiling-and-the-write-up). |

---

## Correctness gates, before any of the above

Ten gates plus a static privilege pin, run against real KVM and a real golden snapshot.
A gate with **any** failing subtest counts as failed.

- **Firecracker: 10/10 PASS.**
- **Cloud Hypervisor: 3/10 PASS, 7 FAIL** — every gate that restores a paused VM and runs
  a command in it times out in `Restore()`. A documented stopping point, not a bug still
  being chased.

`TestGateClock` **failed first, correctly**, catching a real shipped defect that no
performance number would have surfaced.
→ [Correctness gates](EXPERIMENTS.md#correctness-gates-spec-8)

---

## One prediction was falsified

Sealed prediction 7 claimed that concurrent-restore failures at N=128 were host memory
exhaustion. Both candidate causes were eliminated on the same host, in the same 40-second
window, under one sampler:

| Run | Result | MemAvailable floor | OOM events |
|---|---|---|---|
| Control (no second port) | **128/128 pass** | 14.06 GiB | 0 |
| The real probe | 90/128, **38 failures** | 12.32 GiB | **0** |

Zero OOM events and memory never near exhaustion falsifies the memory claim; a clean
128/128 control falsifies "128 concurrent restores are too many". What remains is
contention from the probe apparatus itself, degrading the *pre-existing* channel rather
than the one under test. The conclusion had to stand on different evidence.

---

## What shipped instead

The microVM tier did not ship. MOCA kept pod-level brain/hands isolation — the agent never
executes tools in its own process — and the effort went to scale-to-zero, where an
idle-heavy workload measured a **0.25 pod-seconds ratio against a pre-set 0.6 gate**
(`E1_RESULT persistent=380 serverless=95 ratio=0.25 pass=yes`).
→ [`experiments/e01-e07-knative/EXPERIMENTS.md`](../experiments/e01-e07-knative/EXPERIMENTS.md)

---

## Reading order

- **Deciding whether to use microVMs for this?** The headline table, then the nesting
  table, then "Retracted".
- **Reviewing the method?** [`predictions.json`](predictions.json) and [spec §7.2][spec]
  first — both predate the measurements — then the instrument-defect table.
- **Reproducing it?** [`METAL-RUNBOOK.md`](METAL-RUNBOOK.md); the drivers are
  bare-metal/root-only.
- **Checking a specific number?** [`EXPERIMENTS.md`](EXPERIMENTS.md). It is long on
  purpose.

[spec]: https://github.com/rossoctl/moca/blob/main/docs/specs/2026-09-09-p4-microvm-sandbox-design.md
[#291]: https://github.com/rossoctl/moca/issues/291
[#305]: https://github.com/rossoctl/moca/issues/305
[#312]: https://github.com/rossoctl/moca/pull/312
