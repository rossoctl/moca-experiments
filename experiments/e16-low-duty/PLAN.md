# E16 Low-Duty Density Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Measure, on the E15 metal host, whether SBX holds more concurrent coding-agent sessions than resident ∞ when every session's duty cycle is in (1%, 2%].

**Architecture:** E15's instrument unchanged (`experiments/e15-session-density/driver`, `experiments/e15-session-density/rig`, `experiments/e15-session-density/analysis`) plus: a duty-band corpus filter (`experiments/e16-low-duty/extract/`), a `lowduty` point, per-run worker admission overrides, an explicit rung list for `ladder.sh`, two new per-rung fields in `record.py`, and a VM-memory-against-age analysis (`experiments/e16-low-duty/analysis/`). New rig switches are fresh-metal-only; sealed E15 procedures (aws-prelim and E15 metal records) re-judge identically.

**Tech Stack:** Python 3 (pytest), bash (shellcheck, `experiments/e15-session-density/rig/tests/rig.test.sh`), Go driver (unchanged), metal host `ubuntu@<RIG_IP>`.

**Spec:** `experiments/e16-low-duty/SPEC.md` (approved 2026-11-07). E15's spec `experiments/e15-session-density/SPEC.md` (§5.4 duty definition, §8 holds N, §13 metal procedure) is the parent.

## Global Constraints

- Band: duty in **(0.01, 0.02]** (occupied ÷ span on the H = 1800 s replay timeline, E15 §5.4) of the E15 default corpus (sha256 `24050ae8ac96b4cd25e211ebaa961333009bdc6fa083b667909f1ae3ce8a3132`). Expected: **456 sessions, 40 users**.
- Arms: **sbx** and **resident-inf** only; control once at N = 768.
- Worker on E16 rungs: `SH_MAX_COMMITTED_MB=4194304`, `SH_MAX_RUNS=4096`; `SH_HOST_MEM_FLOOR_MB=1536`, e15.slice limits and the MemAvailable watchdog unchanged.
- Rungs: sbx **256, 384, 512** + one bisecting rung; resident-inf **256, 384, 512, 640, 768** + one bisecting rung (896, 1024 if 768 holds; 1280, 1536 if 1024 holds). Below 256 on failure: 192, 160, 128, … (E15 ladder).
- Deciding rungs (last hold, first failure per arm) re-run with **seed 2**; seed 3 on disagreement; majority decides.
- E15 metal procedure: warm-up 1200 s, window 900 s, sum-basis drift > 10% → repeat (warm-up 2400 s, K × 2), grace-end-only failures → re-run with grace 900 s; both records kept.
- Hypothesis decided on the primary verdict: **holds** iff n_max(sbx) ≥ one ladder step above n_max(resident-inf); otherwise **falsified**.
- Predictions sealed (user approval) **before the first measured rung**.
- Commits: `git commit -s`, trailer exactly `Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>`; never `Co-Authored-By`. Push after every commit (the /tmp checkout is cleaned externally).
- Local env (nono sandbox): write only /tmp and <moca-checkout>; `GOWORK=off GOPATH=/tmp/kagenti/gopath GOMODCACHE=/tmp/kagenti/gomodcache-8a GOCACHE=/tmp/kagenti/gocache`; `PYTHONPATH=/tmp/kagenti/pylibs-r`; `SHELLCHECK=/tmp/kagenti/scpkg/bin/shellcheck`. Re-check each exists before use; reinstall into a new /tmp dir if the cleaner removed it.
- Never print tokens; scan committed results for `Bearer `, `MOCA_RELAY_EXEC_TOKEN=`, `exec.token`, private-key headers.
- Never stop the metal instance; the user does.

## Review Focus

1. A session whose span is 0 (one call of `dur_ms` 0) — the filter must skip it, not divide by zero. Test in Task 1.
2. Band edges exactly at 0.01 and 0.02 — 0.01 excluded, 0.02 included. Test in Task 1.
3. `E15_LADDER_RUNGS` naming a rung not on the fresh-metal ladder — `ladder.sh` refuses with a message, runs nothing. Test in Task 3.
4. aws-prelim with `E15_MAX_COMMITTED_MB` set — ignored (sealed value 1048576 kept); fresh-metal unset — E15 metal value kept. Test in Task 2.
5. A rung whose calls.jsonl has no in-window calls — `replayed_duty` and `distinct_trace_share` are `null`, not an error. Test in Task 4.

---

### Task 1: Duty-band corpus filter

**Files:**
- Create: `experiments/e16-low-duty/extract/duty_band.py`, `experiments/e16-low-duty/extract/test_duty_band.py`

**Interfaces:**
- Consumes: E15 corpus JSONL (one session per line: `session`, `user`, `provider`, `calls[]` with `offset_ms`, `dur_ms`, `work_ms`, `gap_ms`, `class`), and its `corpus-report.json`.
- Produces: `duty(calls: list[dict]) -> float | None` (occupied ÷ span; `None` when span ≤ 0), computed exactly as `experiments/e15-session-density/extract/extract.py:timeline` (import it from there: `sys.path` insert of `experiments/e15-session-density/extract`); CLI `python3 experiments/e16-low-duty/extract/duty_band.py --in CORPUS.jsonl[.gz] --out DIR --duty-min 0.01 --duty-max 0.02` writing `DIR/corpus.jsonl` and `DIR/corpus-report.json` with keys `source_sha256`, `duty_min`, `duty_max`, `sessions`, `users`, `top_user_share`, `by_provider`, `occupied_pct`, `work_pct`, `calls_per_s_per_session`, `mean_span_h`.

- [ ] **Step 1: Write the failing tests** in `experiments/e16-low-duty/extract/test_duty_band.py`:
  - `test_duty_matches_e15_timeline`: for a 3-call session with offsets `[0, 10000, 5000]`, durs `[1000, 1000, 2000]`, `duty == (1000+1000+2000) / 17000`.
  - `test_zero_span_is_none`: one call, `dur_ms 0` → `duty(...) is None`, and the CLI skips it.
  - `test_band_edges`: sessions with duty exactly 0.01, 0.015, 0.02, 0.0201 → kept: 0.015 and 0.02 only.
  - `test_report_counts`: report `sessions`, `users`, `by_provider` match the kept sessions; `source_sha256` is the input file's sha256 (uncompressed bytes).
- [ ] **Step 2:** `PYTHONPATH=/tmp/kagenti/pylibs-r python3 -m pytest experiments/e16-low-duty/extract -q` → FAIL (module missing).
- [ ] **Step 3:** Implement `duty_band.py` (gzip input supported; sessions written in input order, unchanged).
- [ ] **Step 4:** Tests pass; then run on the real corpus (`/tmp/kagenti/e15-export/corpora/default/corpus.jsonl.gz`, or re-extract it with `experiments/e15-session-density/extract` if the cleaner removed it — verify the sha256 above) and check the report: **456 sessions, 40 users, occupied ≈ 1.49%**. A different count is a bug, not a finding: stop and report.
- [ ] **Step 5:** Commit `feat(e16): duty-band corpus filter` and push. Copy `corpus-report.json` to `experiments/e16-low-duty/results/corpus/lowduty-report.json` in the same commit (not the corpus itself).

### Task 2: `lowduty` point and per-run worker admission overrides

**Files:**
- Modify: `experiments/e15-session-density/rig/points.sh` (add point `lowduty`), `experiments/e15-session-density/rig/lib.sh` (worker env at `SH_MAX_RUNS` / `SH_MAX_COMMITTED_MB`, ~line 754), `experiments/e15-session-density/rig/setup.sh` (ship the `lowduty` corpus to `$E15_CORPORA/lowduty/`)
- Test: `experiments/e15-session-density/rig/tests/rig.test.sh`

**Interfaces:**
- Produces: point `lowduty` (`E15_P_ARMS="sbx resident-inf control"`, corpus `lowduty`, default library/template, `E15_P_FALLBACK=0`); env `E15_MAX_COMMITTED_MB`, `E15_MAX_RUNS` honoured **only under `E15_HOST_PROFILE=fresh-metal`**.

- [ ] **Step 1: Failing rig.test checks:**
  - `e15_point_arms lowduty` → `sbx resident-inf control`; `e15_point_sig lowduty` differs from `default`'s.
  - fresh-metal, `E15_MAX_COMMITTED_MB=4194304 E15_MAX_RUNS=4096`: worker env contains `SH_MAX_COMMITTED_MB=4194304` and `SH_MAX_RUNS=4096`.
  - fresh-metal, both unset: `SH_MAX_COMMITTED_MB=1048576`, `SH_MAX_RUNS=2048` (E15 metal, unchanged).
  - aws-prelim with both set: `SH_MAX_COMMITTED_MB=1048576`, `SH_MAX_RUNS=512` (sealed, ignored).
- [ ] **Step 2:** `SHELLCHECK=… bash experiments/e15-session-density/rig/tests/rig.test.sh` → the new checks FAIL.
- [ ] **Step 3:** Implement. setup.sh copies `lowduty/corpus.jsonl` from the rig's staging dir like the other corpora and records its sha256 in the artifacts file.
- [ ] **Step 4:** rig.test passes (all prior checks too); shellcheck clean on changed scripts.
- [ ] **Step 5:** Commit `feat(e16): lowduty point; fresh-metal admission overrides` and push.

### Task 3: Explicit rung list for `ladder.sh`

**Files:**
- Modify: `experiments/e15-session-density/rig/ladder.sh`
- Test: `experiments/e15-session-density/rig/tests/rig.test.sh`

**Interfaces:**
- Produces: env `E15_LADDER_RUNGS="256 384 512"` (fresh-metal only) — the ladder climbs exactly these N in order, with every E15 rule unchanged (repeats, K × 2 on repeats, grace re-run via the existing climb tooling is NOT in ladder.sh — see Task 6), stops at the first rung where both verdicts are broken, writes `ladder.json` with an added field `rungs_requested`. A requested N not in `E15_LADDER` → exit 2 with `ladder.sh: E15_LADDER_RUNGS: N=<n> is not on the ladder`. Unset → behaviour unchanged.

- [ ] **Step 1: Failing rig.test checks** (stub rung.sh as the existing ladder tests do): requested `256 384 512` with 384 failing → rung.sh called for 256, 384 only; `ladder.json` `n_max` 256, `rungs_requested` `[256,384,512]`; requested `300` → exit 2 and the message; aws-prelim ignores the variable.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** rig.test passes; shellcheck clean.
- [ ] **Step 5:** Commit `feat(e16): ladder.sh explicit rung list (fresh-metal)` and push.

### Task 4: Per-rung replayed duty and distinct-trace share

**Files:**
- Modify: `experiments/e15-session-density/analysis/record.py` (`build`)
- Test: `experiments/e15-session-density/analysis/test_holds.py`

**Interfaces:**
- Produces: two new record fields, informational only (no verdict uses them): `replayed_duty` = `{"median": float, "mean": float}` over sessions with ≥ 1 in-window call, each session's (union of its in-window calls' `[ts_start, ts_start+observed_ms]` clipped to the window) ÷ window length; `distinct_trace_share` = distinct `trace` ÷ distinct `session` among in-window calls. Both `null` when no in-window calls.

- [ ] **Step 1: Failing tests:** `test_replayed_duty_basic` (2 sessions, known intervals in a 900 s window → exact median/mean); `test_distinct_trace_share` (4 sessions on 3 traces → 0.75); `test_no_window_calls_null` (both `None`); `test_existing_records_unchanged` (re-build an E15 fixture rung: every pre-existing field identical).
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement (call start = `ts` minus `observed_ms`, matching how calls.jsonl stamps `ts` at completion — confirm against `experiments/e15-session-density/driver/record.go` and say which in the code comment).
- [ ] **Step 4:** `python3 -m pytest experiments/e15-session-density/analysis -q` all pass (≥ 104 prior + 4).
- [ ] **Step 5:** Commit `feat(e16): record replayed duty and distinct-trace share` and push.

### Task 5: VM memory against age, from E15's records (SPEC §6 step 1)

**Files:**
- Create: `experiments/e16-low-duty/analysis/vm_age.py`, `experiments/e16-low-duty/analysis/test_vm_age.py`, output `experiments/e16-low-duty/results/vm-age/e15-metal.json` and `.md`

**Interfaces:**
- Consumes: E15 metal resident-inf rung dirs (`samples.jsonl[.gz]` VM cgroup `vm_mem` per sample; VM first-seen time = age 0). Fetch them from `origin/e15/metal-run` `experiments/e15-session-density/results/metal/default/resident-inf/` (git sparse checkout under /tmp).
- Produces: `vm_age.py RUNG_DIR... --out PREFIX` → JSON `{"bins_min": [...], "median_mib": [...], "p95_mib": [...], "growth_20_60_pct": float, "vms": int}`; age bins of 5 min; `growth_20_60_pct` = median VM memory at 60 min ÷ at 20 min − 1, over VMs observed at both ages; `null` if fewer than 20 such VMs.

- [ ] **Step 1: Failing tests:** synthetic samples with 3 VMs growing linearly → exact bin medians and growth; a VM name reused after a gap (E15: pool cgroup names are reused) starts a new VM at age 0 when its memory drops by > 50% between samples or it disappears for > 60 s.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Pass; run on every E15 metal resident-inf rung ≥ N=64 (first runs and repeats).
- [ ] **Step 5:** Commit results + code, push. **Decision rule (SPEC §6):** if `growth_20_60_pct > 10` or `null` (too few old VMs), Task 8 runs the long rung; else it is skipped. State which in the commit message.

### Task 6: Metal bring-up for E16

**Files:**
- Create: `experiments/e16-low-duty/rig/chain.sh` (the E16 run chain on the host), `experiments/e16-low-duty/rig/README.md`
- Reuse: `experiments/e15-session-density/results/metal/tools/{climb4.sh,grace_artefact.py,measured_delta.py,perfsample.sh,sync.sh,pull.sh,tokscan.sh}` — copy what the chain needs under `experiments/e16-low-duty/rig/` rather than editing E15's.

**Interfaces:**
- `experiments/e16-low-duty/rig/chain.sh STAGE` with stages `baselines`, `ladder-sbx`, `ladder-resident`, `seeds`, `control`, `long-rung`; each stage idempotent (skips rungs whose record exists), runs the OOM/disk sentinel from climb4.sh, applies the grace-end artefact re-run (grace 900 s) and the measured-delta disk check, exports `E15_HOST_PROFILE=fresh-metal E15_MAX_COMMITTED_MB=4194304 E15_MAX_RUNS=4096`, and prints one `E16 <stage> <arm> N=<n> holds=<bool> holds_abs=<bool> p95x=<ms> reason=<..>` line per rung.

- [ ] **Step 1:** Check access (`nc -z <RIG_IP> 22`). If closed, report BLOCKED with the laptop egress IP (`curl https://checkip.amazonaws.com`) — the user updates the security group.
- [ ] **Step 2:** Resync the host to this branch's HEAD (E15's `sync.sh` pattern), stage the `lowduty` corpus, run `experiments/e15-session-density/rig/setup.sh` (fresh-metal); confirm in its output the lowduty corpus sha256, admission overrides live in the worker env, 0 Firecracker, ≥ 250 GiB free on /srv/e15.
- [ ] **Step 3:** `rig.test.sh` for `chain.sh` stage dispatch with stubs (stage names, idempotent skip, the one-line output format).
- [ ] **Step 4:** Commit `feat(e16): metal chain` and push.

### Task 7: Calibration and sealed predictions

- [ ] **Step 1:** `chain.sh baselines`: N = 1 baselines (3 seeds, as `experiments/e15-session-density/rig/baseline.sh`) and per-class probes (`classprobe.sh`) for sbx and resident-inf at `lowduty`. Record B, primary/abs limits, N=1 overhead per arm; undercovered classes listed.
- [ ] **Step 2:** One calibration rung per arm at N = 256 tagged `cal` (not a ladder rung): core-s per call, resident VM footprint (median/max), live-VM peak, host CPU, p95 excess. These feed the ranges.
- [ ] **Step 3:** Write `experiments/e16-low-duty/predictions.json` in E15's format (`claim`, `metric`, `falsifiedBy`, `note`): SPEC §10 items 1–4, with numeric N_max ranges from Step 2 (latency scaling from the N=256 cal rung's p95 excess against the limit, using E15 metal's measured p95-excess-vs-N slope per arm; memory bound from Task 5's growth), and the admission calculation (SPEC §7.3) as a note. Commit as **unsealed draft** and push.
- [ ] **Step 4:** STOP. Report to the controller: B, limits, overhead, cal-rung numbers, draft ranges. The controller brings them to the user; seal only on the user's go-ahead (commit `docs(e16): sealed predictions`, add `sealedAt`, `codeCommit`).

### Task 8: Measured ladders, seeds, control, record

- [ ] **Step 1 (only if Task 5 said so):** `chain.sh long-rung`: resident-inf, N = 256, warm-up 600 s, window 10800 s, tag `long`; then `vm_age.py` on it → `experiments/e16-low-duty/results/vm-age/long-rung.json`.
- [ ] **Step 2:** `chain.sh ladder-sbx` with `E15_LADDER_RUNGS="256 384 512"`; then one bisecting rung between last hold and first failure (448 if 512 failed, 576 if 512 held and the next requested failed — extend with 640, 768 while holding). If 256 fails: 192, 160, 128 … until a hold, then bisect.
- [ ] **Step 3:** `chain.sh ladder-resident` with `E15_LADDER_RUNGS="256 384 512 640 768"` (+ 896, 1024 if 768 holds; + 1280, 1536 if 1024 holds), then one bisecting rung (704 or 896).
- [ ] **Step 4:** `chain.sh seeds`: each arm's last-hold and first-failure rung with `E15_SEED=2` (tag `s2`); a third seed (`s3`) where seeds 1 and 2 disagree; majority decides that rung's verdict.
- [ ] **Step 5:** `chain.sh control` at N = 768 (A2).
- [ ] **Step 6:** Pull results into `experiments/e16-low-duty/results/<arm>/N<n>[-tag]/` (token scan), commit per stage, push.
- [ ] **Step 7:** Write `experiments/e16-low-duty/RESULTS.md`: ladders (n_max, n_max_abs, n_max_1s, n_max_cpu per arm, seeds per deciding rung), each sealed prediction's verdict, the hypothesis verdict (§7.2), replayed duty and distinct-trace share per rung, live-VM peak and resident physical memory at N_max, the admission calculation (§7.3), VM memory against age. Plain short sentences.
- [ ] **Step 8:** Leave the host set up (no teardown; never stop the instance). Commit and push. Report to the controller.

---

## Self-review (done while writing)

- Spec coverage: §3 → Task 1, 4; §4/§5 → Task 2, 6; §6 → Task 5, 8.1; §7 → Task 4 (fields), 7, 8.7; §8 rungs/seeds → Task 3, 8; §8.1 time → Tasks 6–8; §10 → Task 7; §11 items 1–6 → Tasks 1, 2, 2, 3, 4, 5.
- Names consistent: `duty`, `E15_MAX_COMMITTED_MB`, `E15_MAX_RUNS`, `E15_LADDER_RUNGS`, `replayed_duty`, `distinct_trace_share`, `vm_age.py`, `chain.sh` stages.
