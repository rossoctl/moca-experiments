# E17a Implementation Plan — the pycache points and the lease-30/-120 arms on the E15 rig

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build everything E17a needs (spec §3: the stage before the lease build), so the E17a rungs can
run on the E15/E16 metal host with E15's driver, rung, ladder and record machinery unchanged.

**Architecture:** `pycache` is modelled exactly like a trace point:
- **corpus:** a generated `corpus.jsonl` of synthetic sessions;
- **library:** a `library.json` whose classes hold the pycache commands;
- **template:** a workspace template that carries the dataset, a Python venv with the heavy stack, and
  the project.

So `rung.sh ARM N pycache` runs with no driver change. The new arms `lease-30` and `lease-120` are the
E15 resident patch with `E15_RESIDENT_IDLE_S` 30 and 120, next to `resident-300`, which is E17's
`lease-300`. Warm and cold are tagged after the run by joining each call with the resident patch's
worker log lines. A small analysis script turns the records into the spec §7.1 latency report.

**Tech Stack:** Python 3 (generators, analysis, pytest), bash (rig), the E15 Go driver (unchanged), cp39
manylinux wheels for numpy 2.0.2, pandas 2.2.3, scikit-learn 1.6.1 and scipy 1.13.1 (the guest's
Python is 3.9).

**Spec:** `experiments/e17-lease/SPEC.md` (v0.2, approved 2026-11-10). Parents: E15 and E16 specs. The design under test
is moca `docs/specs/2026-11-08-sbx-lease-mode-design.md`.

**Branch:** `experiments/e17-lease/lease-spec` (moca-experiments, `/tmp/mx-e17`), on top of the approved spec. Rig: the
E15 metal host `ubuntu@<RIG_IP>` (key `~/.ssh/id_ed25519`), `/srv/e15`, profile `fresh-metal`.

## Global Constraints

- **The sealed E15 and E16 procedures are unchanged.** New rig behaviour is selected only by the new
  point and arm names, and only on `fresh-metal`. `experiments/e15-session-density/rig/tests/rig.test.sh` and `pytest experiments/e16-low-duty/rig` keep
  passing.
- **The guest image is E15's** (`/srv/e15/snapshots/e15`, guest RAM 1024 MiB, Python 3.9, pytest only).
  No rootfs or snapshot change (user decision 2026-11-10: the venv lives in the workspace).
- **The workspace image** for `pycache` is 1536 MiB (`E15_P_IMAGE_MB`). The dataset size `D` defaults to
  256 MiB and is a template parameter (`--dataset-mib`). `D` 64, 256 and 768 each get their own
  template stamp.
- **Determinism.** The corpus, the dataset bytes and every command are functions of their seeds. The same
  seed gives byte-identical files, and a test checks this.
- **Command contract (spec §4.2).** One pycache session turn, in this order:
  1. `analyze`: `cd project && ../venv/bin/python analyze.py`;
  2. `test`: `cd project && ../venv/bin/python -m pytest -x -q tests`;
  3. two to five short commands (`grep`, `read`, `edit` on `project/src/*.py`);
  4. `analyze` again.

  Gaps between calls come from the E15 default corpus's gap distribution (`gap_ms`), scaled so that each
  session's occupied fraction meets the point's duty target: `pycache` 9.5%, `pycache-low` 1.5%.
- **Classes** in the generated corpus and library: `py_analyze`, `py_test`, `py_short`. They are new
  class names, so no E15 class median or probe is reused for them.
- **Warm or cold.** A call is **warm** when the resident patch's worker log shows the call's Exec reused
  the session key's resident VM, and **cold** otherwise. The tag uses only log lines the patch already
  writes (`e15 resident …` and `vmpool: exec … cold=…`). If the log cannot decide a call, it is tagged
  `unknown` and reported. It is never guessed.
- **Rig safety (an incident on the SBX0 host, 2026-11-09):**
  - Every `build-snapshot.sh` or `rm -rf` target is a leaf path that is checked before use.
  - This plan builds no snapshot.
  - Rig runs are started by the controller only, never by an implementer.
- Commits: `git commit -s`, trailer `Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>`. Tests:
  `pytest e17` and `bash experiments/e15-session-density/rig/tests/rig.test.sh`.

## Review Focus

1. **A warm/cold join that misattributes.** Two calls of one session can run back to back within a
   second, and log timestamps have one-second resolution. The join must match on the session's
   `workspace_key` and the call's order, not on time alone. Pinned in Task 4.
2. **A dataset that does not exercise the page cache.** If `analyze.py` reads only part of the dataset,
   or uses mmap without touching every page, "warm" measures nothing. `analyze.py` must read every byte
   (checksum it) and print the checksum, and a test compares it with the generator's. Pinned in Task 2.
3. **A venv that the guest cannot import.** The wheels are manylinux2014 cp39 and the guest is
   Python 3.9 on glibc. A wrong platform tag fails only on the rig. The template build runs a
   `python -c "import numpy, pandas, sklearn"` inside the staged tree's interpreter path check, and a rig
   smoke step imports them in a real guest. Pinned in Tasks 2 and 5.
4. **A duty target that the gap draw cannot meet.** At 1.5% duty with a ~90 s busy turn, gaps average
   about 100 minutes, which exceeds E15's `H` = 1800 s cap on gaps. The generator must apply the same cap
   and report the duty it actually achieved, failing if it misses by more than 20% relative. Pinned in
   Task 1.
5. **Workspace disk per rung.** A 1536 MiB image × N × K reflink copies, each with its own venv, is
   mostly shared. `pycache` writes `__pycache__` and pytest caches into the workspace, so the per-session
   delta is no longer the 2 MiB E16 measured. Before the first ladder, `measured_delta.py` must be rerun
   on a `pycache` rung. Pinned in Task 5.

---

### Task 1: The pycache corpus generator

**Files:**
- Create: `experiments/e17-lease/extract/pycache_corpus.py`, `experiments/e17-lease/extract/test_pycache_corpus.py`

**Interfaces:**
- Produces: `python3 experiments/e17-lease/extract/pycache_corpus.py --gaps-from CORPUS.jsonl --duty 0.095 --sessions 400 --seed 1 --out DIR`. It writes `DIR/corpus.jsonl` (E15's `Session`/`Call` schema: `session`, `user`, `provider`, and `calls[]` with `i`, `class`, `skeleton`, `dur_ms`, `work_ms`, `gap_ms`, `offset_ms`, `out_bytes`, `chain` false) and `DIR/corpus-report.json` (sessions, duty achieved mean and median, calls per class, and the gap source's sha256).
- `dur_ms` and `work_ms` are the N = 1 targets: `py_analyze` 15000, `py_test` 60000, `py_short` 300. These
  are only the planned durations; the library's real commands decide the actual time.
- Users: `pyc-u00` … `pyc-u39` (40 users, round-robin), so E15's 15% per-user cap never binds.
  Provider: `synthetic`.

- [ ] **Step 1: Write the failing tests**
  - `test_turn_order`: every session's calls follow the cycle `py_analyze`, `py_test`, `py_short` × k
    (2 ≤ k ≤ 5), `py_analyze`.
  - `test_seed_is_deterministic`: two runs with seed 1 give byte-identical `corpus.jsonl`, and seed 2
    differs.
  - `test_duty_is_met`: for `--duty 0.095` and `--duty 0.015` on a fixture gap corpus,
    `corpus-report.json`'s mean achieved duty is within 20% relative of the target.
  - `test_gaps_are_capped`: no `gap_ms` exceeds 1_800_000.
  - `test_unmeetable_duty_fails`: with `--duty 0.0001` the generator exits non-zero, and the message
    contains `duty`.
  - `test_schema_loads_in_e15_driver`: run `go test` in `experiments/e15-session-density/driver` with a new tiny test
    (`TestLoadCorpusAcceptsPycache`, added in this task to `experiments/e15-session-density/driver/corpus_test.go`) that calls
    `LoadCorpus` on a 3-session fixture written by the generator into `experiments/e15-session-density/driver/testdata/pycache-corpus.jsonl`.

- [ ] **Step 2: Run, expect FAIL.** Run `pytest experiments/e17-lease/extract -q` and `cd experiments/e15-session-density/driver && go test -run TestLoadCorpusAcceptsPycache ./...`.

- [ ] **Step 3: Implement.** The duty-to-gap scaling algorithm, which the signature does not determine:
  1. Draw gaps from the source corpus's `gap_ms` values, using the seeded RNG.
  2. Compute the session's busy time B (the sum of `dur_ms`).
  3. Scale every drawn gap by s = (B·(1−duty)/duty) / Σgaps.
  4. Clip each gap to 1_800_000.
  5. Re-measure the duty. If it is more than 20% above target after clipping, extend the session by
     whole turns (at most 50), since more turns means more capped gaps. Then fail if it still misses.

  `offset_ms` is cumulative.

- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `feat(e17): pycache corpus generator (synthetic sessions in E15's schema)`

### Task 2: The pycache workspace template and library

**Files:**
- Create: `experiments/e17-lease/workload/build_pycache_workspace.sh`, `experiments/e17-lease/workload/project/` (the Python project:
  `analyze.py`, `src/pyc/*.py`, `tests/test_*.py`), `experiments/e17-lease/workload/library.json`,
  `experiments/e17-lease/workload/wheels.lock` (wheel filenames and sha256), `experiments/e17-lease/workload/test_workload.py`
- Reuse: E15's `data.bin` generator logic (`experiments/e15-session-density/commands/build_workspace.sh`, SHAKE-256 blocks). Call it or
  copy its function; do not change it.

**Interfaces:**
- Produces:
  - `sudo experiments/e17-lease/workload/build_pycache_workspace.sh --image-mb 1536 --dataset-mib D --dataset-seed 1 --wheels DIR OUT_IMG`
    on Linux as root, and `--dir OUTDIR` on any OS without root.
  - Image layout:
    - `/workspace/data/` holds `D` MiB as Parquet shards of 32 MiB each, deterministic from the seed;
    - `/workspace/venv/` is a venv with the wheels in `wheels.lock` installed with no index;
    - `/workspace/project/` holds the project.
- `analyze.py` must:
  - read every shard with pandas (pyarrow is not installed: use `pandas.read_csv` over CSV shards
    instead, if Parquet would need pyarrow, and say which in the report);
  - compute a groupby aggregate and a scikit-learn `KMeans(n_clusters=8, n_init=1, random_state=0)` fit
    on a fixed 200k-row sample;
  - print `rows=<n> sha256=<hex of all shard bytes in order> clusters=<inertia rounded to 3 dp>`.
- The test suite runs about 60 s at N = 1 on the rig. Tune the number of tests and their work in Task 5's
  calibration, not here. Start from 40 tests that each import numpy, pandas and sklearn and do about
  1.5 s of numeric work.
- `library.json` (E15's schema, `version` 1) has these classes:
  - `py_analyze`: one invocation, `cd project && ../venv/bin/python analyze.py`;
  - `py_test`: one invocation, the pytest command;
  - `py_short`: about 8 invocations (`grep -rn def src`, `head -n 80 src/pyc/model.py`, `sed -n` reads, and
    one `edit` written as a `python3 -c` that rewrites a constant in `src/pyc/config.py` and reverts it in
    the same command, so repeated runs stay deterministic).

  Every invocation's `exit` is 0. `nominal_ms` takes the Task 1 targets, and `run_ms`/`cpu_ms` are null
  until Task 5 measures them.

- [ ] **Step 1: Write the failing tests** (`pytest experiments/e17-lease/workload`, laptop, with `--dir` staging):
  - `test_dataset_is_deterministic`: two stagings with seed 1 give identical shard bytes, and the total
    size equals `D` MiB ± one shard.
  - `test_analyze_reads_every_byte`: run `analyze.py` with the host Python (skip if pandas is missing) on a
    `D`=8 staging, and check that its printed `sha256` equals the generator's own hash of the shards.
  - `test_library_matches_classes`: the library has exactly `py_analyze`, `py_test` and `py_short`, every
    command starts with `cd project`, and every `exit` is 0.
  - `test_wheels_lock_pins_sha256`: every wheel in `wheels.lock` has a 64-hex sha256, and staging refuses
    a wheel whose hash differs.
  - `test_edit_is_idempotent`: run the `py_short` edit command twice on a staging, and
    `src/pyc/config.py` is byte-identical before and after.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
  - The venv install is `python3.9 -m venv`, then `pip install --no-index --find-links DIR -r` from
    `wheels.lock`, run in a chroot of E15's rootfs on the rig. The guest's Python must build the venv,
    and the laptop's does not match: the laptop has 3.15.
  - The script finds the rootfs through `--rootfs-tree PATH`. On the rig that is the E15 snapshot's
    rootfs, mounted read-only, as `experiments/e15-session-density/rig/setup.sh` step 7 does.
  - The `--dir` path skips the venv and records `venv: skipped (no rootfs)` in a `BUILD` file.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `feat(e17): pycache workspace (dataset, venv, project) and library`

### Task 3: The rig wiring — points, arms, sync

**Files:**
- Modify: `experiments/e15-session-density/rig/points.sh` (new `pycache`, `pycache-low`, `pycache-d64`, `pycache-d768` cases,
  fresh-metal only), `experiments/e15-session-density/rig/lib.sh` (arms `lease-30` and `lease-120` next to `resident-300`: the same
  binary, worker env `E15_RESIDENT=1`, `E15_RESIDENT_IDLE_S=30` or `120`, and warm-up as `resident-300`),
  `experiments/e15-session-density/rig/setup.sh` (build the pycache templates when the profile is fresh-metal and `E17=1`)
- Create: `experiments/e17-lease/rig/sync.sh` (laptop rsync of `experiments/e15-session-density/`, `experiments/e16-low-duty/` and `experiments/e17-lease/`, the pycache corpora, the library and
  the wheels, in the style of `experiments/e16-low-duty/rig/sync.sh`), `experiments/e17-lease/rig/README.md`
- Test: `experiments/e15-session-density/rig/tests/rig.test.sh` (new cases)

**Interfaces:**
- Consumes:
  - Task 1's `corpus.jsonl` per point: `pycache` duty 0.095, and `pycache-low` duty 0.015, under
    `/srv/e15/corpora/<point>/`;
  - Task 2's template and library.
- Produces: `rung.sh {sbx|resident-300|lease-30|lease-120} N {pycache|pycache-low|pycache-d64|pycache-d768}`.
  The points use `E15_P_LIBRARY=/srv/e15/src/e17/workload/library.json`, `E15_P_IMAGE_MB=1536` and the
  template `/srv/e15/template-pycache-d<D>/workspace.img`, with `E15_P_FALLBACK=0`. The `pycache` arms
  are `sbx resident-300 lease-30 lease-120`.

- [ ] **Step 1: Write the failing rig tests**:
  - `points.sh pycache` sets the library, image size, template and arms above;
  - `points.sh pycache` on a non-fresh-metal profile refuses;
  - `lib.sh` worker env for `lease-30` prints `E15_RESIDENT=1` and `E15_RESIDENT_IDLE_S=30`;
  - the existing `default`, `lowduty` and `mem512` cases are byte-identical to before (a golden diff of
    their `e15_point` output).
- [ ] **Step 2: Run** `bash experiments/e15-session-density/rig/tests/rig.test.sh`, **expect FAIL** on the new cases.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS.** The existing cases must stay green.
- [ ] **Step 5: Commit** `feat(e17): rig points pycache*, arms lease-30/lease-120, sync`

### Task 4: The warm/cold join and the latency report

**Files:**
- Create: `experiments/e17-lease/analysis/warmcold.py`, `experiments/e17-lease/analysis/latency_report.py`, `experiments/e17-lease/analysis/test_warmcold.py`,
  `experiments/e17-lease/analysis/test_latency_report.py`, `experiments/e17-lease/analysis/testdata/` (a small real-format `calls.jsonl` and
  `worker.log` slice)

**Interfaces:**
- Consumes:
  - a rung directory (E15 layout: `calls.jsonl.gz`, `sessions.jsonl` and `worker.log.gz`);
  - the resident patch's log lines `vmpool: exec req=… workspace_key="…" vm=vm-N cold="…"` (stock) and
    `vmpool: e15 resident {retire|idle-destroy|end-session} workspace_key="…" vm=…` (patch).
- Produces:
  - `warmcold.py RUNG_DIR` writes `RUNG_DIR/warmcold.jsonl`: one line per call, holding `session`,
    `call`, `class`, `observed_ms`, `warm` (`true`, `false` or `unknown`), `vm` and `prev_vm`.
  - `latency_report.py RUNG_DIR... --baseline-arm sbx` writes the spec §7.1 table as `latency.json` and
    `latency.md`:
    - per arm, point and N, for each class: the median and p95, warm and cold;
    - Gain = 1 − (lease warm median ÷ sbx median);
    - first-call-after-idle latency;
    - the warm share.

- [ ] **Step 1: Write the failing tests**:
  - `test_join_by_key_and_order`: a fixture holds two calls of one key within the same second on the same
    VM. The second call is warm and the first is cold, and the join must not depend on the timestamps.
  - `test_idle_destroy_makes_next_cold`: a fixture with an `idle-destroy` line between two calls gives
    `warm=false` for the call after it.
  - `test_sbx_arm_is_never_warm`: on a stock-worker log every call is `false`.
  - `test_unmatched_is_unknown_not_guessed`: a call with no exec line gets `unknown`, and the report
    counts it.
  - `test_gain_formula`: a fixture where lease warm `py_analyze` has median 6 s and sbx has 10 s gives
    gain 0.4.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** The join algorithm, which the signature does not determine:
  1. Group the worker `exec` lines by `workspace_key`, ordered by their position in the log, not by
     time.
  2. Group calls by the session's key, ordered by `call` and then exec index. A chain call has several
     Execs; use its first Exec.
  3. Zip the two sequences. If the lengths differ, mark every call of that key `unknown`.
  4. A call is warm when its `vm` equals the previous call's `vm` and no retire, idle-destroy or
     end-session line for that key comes between them.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `feat(e17): warm/cold join from the worker log, latency report (spec §7.1)`

### Task 5: Rig bring-up — sync, templates, smoke, delta, calibration (controller-run)

The controller runs this task on the rig. The implementer writes the scripts and the checklist only.

**Files:**
- Create: `experiments/e17-lease/rig/bringup.sh` (idempotent: it stages the wheels, builds the four pycache templates, and
  writes the manifest lines), `experiments/e17-lease/rig/smoke.sh` (one `rung.sh … N=1` per arm at `pycache`, with a 120 s
  window and a 60 s warm-up), `experiments/e17-lease/results/README.md` (where results land)

- [ ] **Step 1: Bring-up (controller, rig).** Run `experiments/e17-lease/rig/sync.sh`, then `bringup.sh`, and record
  `~/e17-manifest.md` on the rig. This creates the templates under `/srv/e15/template-pycache-d*` and the
  corpora under `/srv/e15/corpora/pycache*`. Its undo is the `rm -rf` of those leaf paths, written in the
  manifest.
- [ ] **Step 2: Guest import check (controller).** `smoke.sh` at N=1 for `sbx` must show `analyze` exit
  0, with the printed `sha256` equal to the generator's for D=256.
- [ ] **Step 3: Per-session delta (controller).** Run `experiments/e16-low-duty/rig/measured_delta.py` on the smoke rung. If the
  delta is above 64 MiB, set the pycache rungs' disk check to use it, as E15's supplementary climb did.
- [ ] **Step 4: Calibration (controller).** Run N=1 baselines and per-class probes for `sbx` and
  `resident-300` at `pycache` (E15 `baseline.sh` and `classprobe.sh`). Then tune the test-suite size so
  that `py_test` is 50–70 s at N=1 on `sbx`. If it is retuned, re-stamp the templates and repeat Step 2.
- [ ] **Step 5: Write the predictions (controller drafts, user seals).** Draft `experiments/e17-lease/predictions.json`
  from the calibration, using spec §9's six items, then **stop for the user's seal**.
- [ ] **Step 6: Commit** each script as it lands, plus the calibration results under `experiments/e17-lease/results/`.

## After this plan

The E17a measured rungs come next, as spec §8's table lists. Each is a `chain.sh`-style stage run by the
controller after the seal. The E17a report then goes to the user, who makes the build decision (spec
§7.5). That is a separate, short run plan once the predictions are sealed.

## Self-review notes

- **Spec coverage:**
  - §4.2 is Tasks 1 and 2.
  - §5 arms are Task 3.
  - §6's E17a config needs no change: the never-binding budget comes from the E16 env, which the points
    inherit.
  - §7.1 is Task 4.
  - §7.2 at `default` needs no new code: it uses existing `ladder.sh` on the `resident-300` and new
    `lease-*` arms.
  - §8's bring-up is Task 5.
  - §10's gain-against-D is the d64 and d768 points from Task 3.
  - The 256 MiB guest-RAM runs need a second snapshot. They are **not** in this plan; they move to the run
    plan, because this plan builds no snapshot (Global Constraints).
- **Decided here, not in the spec:**
  - the class names;
  - the 1536 MiB image;
  - CSV-or-Parquet left to the implementer, depending on whether pyarrow is installed (pyarrow is not
    among the downloaded wheels);
  - the wheel versions;
  - warm/cold taken from the worker log, with no driver change.
