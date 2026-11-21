# experiments/e17-lease/rig: E17 on the E15 metal host

E17 runs on the E15 metal host (`/srv/e15`, profile `fresh-metal`) with E15's rig, plus switches in
`experiments/e15-session-density/rig` that only the new point and arm names select, and only on `fresh-metal`:

- **points** (`points.sh`) `pycache`, `pycache-low`, `pycache-d64` and `pycache-d768`:
  - library `/srv/e15/src/e17/workload/library.json`;
  - 1536 MiB workspaces;
  - arms `sbx resident-300 lease-30 lease-120`;
  - no fallback;
  - a class-probe cap of 120 000 ms (`E15_P_PROBE_CAP_MS`, in the point signature; E15's points keep 30 000).

  | point | corpus (`/srv/e15/corpora/<corpus>/`) | template |
  |---|---|---|
  | `pycache` | `pycache` (9.5% duty) | `template-pycache-d256` |
  | `pycache-low` | `pycache-low` (1.5% duty) | `template-pycache-d256` |
  | `pycache-d64` | `pycache` | `template-pycache-d64` |
  | `pycache-d768` | `pycache` | `template-pycache-d768` |
- **arms** (`lib.sh`) `lease-30` and `lease-120`: the resident worker (`microvm-worker-resident`) with
  `E15_RESIDENT=1` and `E15_RESIDENT_IDLE_S=30` or `120`. In everything else they behave as
  `resident-300`: standby depth 0, a 1200 s warm-up, end-session Execs, and footprint drift
  (`record.py`).
- **setup.sh step 8c**: checks each staged pycache corpus against its report's `corpus_sha256` and
  records it in `state/artifacts`.

The pycache templates (`/srv/e15/template-pycache-d<D>/workspace.img`) are built by `bringup.sh`
(Task 5) with `experiments/e17-lease/workload/build_pycache_workspace.sh`, not by `setup.sh`. `setup.sh`'s template
loop is E15's, unchanged. Where each script's output lands: `experiments/e17-lease/results/README.md`.

| file | what |
|---|---|
| `gen_corpora.sh [--durations-from CAL.json] [--gate-256 GATE.json]` | laptop: `pycache_corpus.py` into `$E17_CORPORA/pycache/` (duty 0.095) and `pycache-low/` (0.015), 400 sessions, seed 1, min-turns 4, gaps from the E15 default corpus. `--durations-from`: each class's measured N=1 median `run_ms` replaces the placeholder `dur_ms`/`work_ms`. `E17_TMPFS_SHARE` (default 0.5 under `E17B=1`, 0 with `E17B` unset): the share of sessions flagged `tmpfs` (their `py_analyze`/`py_test` caches in guest `/tmp`), and a `py_shmem` reading at the end of every turn; `0` writes the E17a corpora byte for byte. Generate the E17b corpora with `E17B=1`. `--gate-256` (`E17C=1` only, PLAN-E17C Task 10): a passing `gate-256.json`; also writes `pycache-256/`, the corpus of E17c's 256 MiB points (`pycache-d64`, `squeeze-256`, which replay `workload/library-256.json`): pycache's arguments with `py_analyze` at the gate's measured ms, so its own corpus hash. It is refused unless the gate's `chosen_scale` is the one `library-256.json` carries and its `moca_commit` is `E17C_MOCA_PIN`; the corpus report records the gate (`gate_256`: file name, sha256, chosen scale, moca_commit) |
| `sync.sh` | laptop: rsync `experiments/e15-session-density/`, `experiments/e16-low-duty/` and `experiments/e17-lease/` to `/srv/e15/src/`, and install the metal library. Stage the corpora `$E17_CORPORA/{pycache,pycache-low}/` to `/srv/e15/corpora/<point>/`, and the wheels `$E17_WHEELS/` to `/srv/e15/wheels-pycache/` |
| `bringup.sh` | host, idempotent, after `setup.sh`: check the corpora and the wheels against `wheels.lock`; loop-mount the snapshot rootfs that `state/artifacts` records, read-only; build `template-pycache-d{64,256,768}` (and `d192`, point `squeeze-256`, under `E17B=1`); stamp each image's sha256 in `state/template-pycache-d<D>`. Each template is skipped while its inputs stamp matches. Manifest `~/e17-manifest.md` |
| `smoke.sh` | host: `rung.sh ARM 1 pycache` per arm (60 s warm-up, 120 s window, tag `smoke`; under `E17B=1` the arms are `sbx` and `ship-30/120/300` only). On `sbx`: the `py_analyze` calls exit 0, and one `py_analyze` Exec through the relay prints the D=256 `BUILD`'s `dataset_sha256`. Then `warmcold.py` on each rung (`warmcold_lease.py` on the `ship-*` rungs: E17a's join cannot read the shipped worker) |
| `chain-e17b.sh [--list] [--from STAGE] [--to STAGE]` | host (E17b, `PLAN-E17B.md` Tasks 12 and 14): the ordered run list with `E17B=1`, one log and one `.done` per stage in `/srv/e15/e17b/`, resumable at a named stage. Every stage but the smoke and the four calibration baselines needs `predictions-e17b.json` with `"sealed": true`, or nothing runs. Each `ship-*` rung a stage writes is analysed (`warmcold_lease.py`, `lease_ends.py`, `freed_from_shmem.py` (its `shmem.json`), then `vm_age_lease.py`, with `--sbx` the same-named `sbx` rung when it exists); an unknown call, a source disagreement or an unmatched lease end stops the chain (a refused or not-started call with no vm is `failed_no_vm`, a NOTE: criterion 3's refusal check judges it). Every rung a stage writes, `sbx` and `ship-*` alike, is first checked for its own failure (`params.json` `rung_failed`, `record.json` `aborted`, or a non-zero driver exit without a `record.json`; a memory-watchdog abort is a host verdict, not a failure), and any stops the chain. The last stage, `verdict`, runs `analysis/verdict.py` over the runs into `/srv/e15/e17b/verdict.json`: each criterion's value, inputs and `pass`: criteria 1-4 on SPEC §7.5's fixed bars (ruling E17B-R40), criterion 5's `pass` null until Task 13 seals its thresholds. The chain refuses to start while a stage-changing knob (`E15_RUNG`, `E15_MAX_COMMITTED_MB`, `E15_LADDER_EXTRA`, ...; the list is `STAGE_KNOBS` in the script) or, outside its test harness, one of its `E17B_*` test hooks is set (ruling E17B-R36). The `squeeze` stages need `E17B_SQUEEZE_MEMMAX_MB` (point `squeeze`: `pycache-d768`'s workload, arms `ship-300` and `sbx`; the climb stops on `analysis/squeeze_rule.py`); the 256 MiB stages run `pycache-d64` and `squeeze-256` (D=192) with `E17B_GUEST_RAM_MB=256`, the latter under `E17B_SQUEEZE256_MEMMAX_MB` |
| `probe-overhead.sh` | host (E17b, spec §7.4, chain stage `probe-overhead`, `E17B=1`): `baseline.sh default ship-300`, the N = 1 class probes of the shipped lease at the `default` point. The probe's baseline is kept as `runs/default/ship-300/N1/baseline.probe-overhead.json`; the calibration baseline it replaced goes back to `N1/baseline.json` on every exit path (a failed probe too), and an earlier probe's baseline is moved aside (`.prev-<UTC>`). The chain stage runs the `default ship-300` commit preflight first. With `E17B_OVERHEAD_REF` (a staged copy of the reference) it also writes `N1/overhead.json` with `analysis/overhead_compare.py`; otherwise that comparison runs on the laptop against `e15-session-density/results/metal/baseline/default/resident-300/N1/baseline.json` (the resident patch E17a reused at `default`) |
| `ownwalk.sh [--plan] FILES` | host (E17b, spec §7.4, chain stage `ownwalk` at 10000, 100000 and 500000 files, `E17B=1`): one ship-300 worker cycle. Five fresh workspaces, reflinked from a blank ext4 template with enough inodes (`template-ownwalk/F<FILES>-<MB>.img`). Then `e15-driver-e17b ownwalk`: per repeat, `workload/build_tree.sh` as a per-exec Exec (root), `set_mode lease` (epoch 1), A (the first lease Exec: the walk runs), `reset`, then B (a cold lease Exec). The walk is A − B. Writes `runs/ownwalk/ship-300/F<FILES>/ownwalk.json` (A, B, A − B per repeat and the medians, the reset's lease status) and `ownwalk-params.json`. Then `analysis/ownwalk_phases.py` adds the worker log's side: A's and B's phase lines, A − B less the logged phases, the two lease starts, and `walk_observed` (null at this pin: the worker logs no normalise phase). At 500000 files the build time is projected from the largest smaller run; above 25 min the size is skipped (`skipped.json`), because the relay's Exec deadline is 30 min. `--plan` only prints the sizing and the driver command |
| `reprobe.sh ARM` | host (Task 5b): re-run only `classprobe.sh pycache ARM` under the pycache probe cap (`E15_P_PROBE_CAP_MS=120000`, points.sh; E15's 30 s cap made `py_test`'s median +31 s) and recompute `runs/pycache/ARM/N1/baseline.json` with `baseline.py` from the seeded runs `baseline.sh` counted plus the new probes. The old probe is moved aside to `_cap30k-N1-probe-*`, `_cap30k-probe-corpora` and `N1/baseline.cap30k.json`. Refuses while a rung's worker runs, and refuses a second run |

Then, on the host: `rung.sh {sbx|resident-300|lease-30|lease-120} N {pycache|pycache-low|pycache-d64|pycache-d768}`
with `E17B` unset (under `E17B=1` the arms are `sbx` and `ship-*`; the E17a arms are refused).
Rig runs are started by the controller only.

Tests: `bash experiments/e15-session-density/rig/tests/rig.test.sh` (the E17 section, plus golden dumps of the pre-E17 points
and arms in `experiments/e15-session-density/rig/tests/golden/`), `bash experiments/e17-lease/rig/tests/chain-e17b.test.sh`,
`bash experiments/e17-lease/rig/tests/probes.test.sh` and `pytest e17`.

## E17b bring-up order (PLAN-E17B Task 12; ruling E17B-R32)

On a fresh rig, in this order. No step is expected to exit non-zero.

1. `bash /srv/e15/src/e15/rig/setup.sh` with `E17B` unset: the sealed stack (the old pin's checkout, the `e15`
   snapshot leaf and its `snapshot-rootfs` artifact, which `bringup.sh` reads, Redis, the relay, the end-to-end check).
   This build changed `driver/*.go`, so on a rig that already has `e15-driver` or `e15-driver-defer` (an E15/E16 rig)
   their stamps record another source key: the sealed `setup.sh` refuses to rebuild them, naming both keys (ruling
   E17B-R37), and the sealed binaries stay. That is the intended path (E17b runs its own `-e17b` drivers). Only to
   replace them knowingly set `E15_ACK_DRIVER_REBUILD=1`. A fresh rig has no stamp and builds them as before.
2. `E17B=1 bash /srv/e15/src/e15/rig/setup.sh`: the E17b checkout at `E17B_MOCA_PIN` (`moca-e17b`, stamp
   `node-e17b`) and the `-e17b` binaries (`go-stock-e17b`, `go-driver-e17b`). Step 7 (the snapshot) is skipped with
   a log line naming `snapshot-e17b.sh`: `setup.sh` never builds or replaces a snapshot under `E17B=1`. The steps after
   it run. The end-to-end check (step 10) is skipped while the E17b leaf does not exist, and says so.
3. `E17B=1 bash /srv/e15/src/e17/rig/snapshot-e17b.sh --ram-mb 1024 --leaf e17b-<pin8>-1024`, then the same with
   `--ram-mb 256 --leaf e17b-<pin8>-256`: the two new leaves.
4. `E17B=1 bash /srv/e15/src/e15/rig/setup.sh` again: now its end-to-end check runs on the selected E17b leaf
   (`e17b-<pin8>-1024`, stamp `e2e-e17b`), after a restart of the relay from the E17b checkout.
5. `E17B=1 E15_HOST_PROFILE=fresh-metal bash /srv/e15/src/e17/rig/bringup.sh`: the pycache templates, with `d192`
   (point `squeeze-256`) under `E17B=1`.
6. `bash /srv/e15/src/e17/rig/chain-e17b.sh --to cal-pycache-ship-300`: the chain's bring-up stages (the smoke and the
   four calibration baselines), allowed before the seal.

Task 12 carry (ruling E17B-R29): read `py_shmem` on a fresh lease VM (a lease's first turn, an unflagged session) and
record its baseline Shmem. If it is stable at 1 MiB or less, R24 (a lease's first turn is never judged) may be
relaxed for unflagged sessions; that needs a new ruling.

## E17c bring-up: move E17b's runs aside first (PLAN-E17C Task 11; ruling R-z5)

E17c writes to the same `/srv/e15/runs/` as E17b, under the same points and arm names (`pycache/sbx`,
`pycache/ship-300`, `pycache-d64/*`, `squeeze/*`, `default/*`, ...). `chain-e17c.sh`'s commit preflight refuses a
stage while its run directories hold another commit's `params.json`, and a `.prev-*` rung under the arm still counts,
so E17b's arm directories have to leave `runs/` whole. Task 11 Step 1 therefore starts with this controller step,
before the first `E17C=1` stage (`chain-e17c.sh`'s `smoke`):

- For each `/srv/e15/runs/<point>/<arm>` that an E17c stage writes (`chain-e17c.sh --list`) and that holds a
  `params.json` from another commit than `E17C_MOCA_PIN` (E17b's, or older):
  `mkdir -p /srv/e15/runs-e17b/<point> && mv /srv/e15/runs/<point>/<arm> /srv/e15/runs-e17b/<point>/`, and one
  manifest line per move in `~/e17-manifest.md`:
  `- <UTC> E17c Task 11: moved E17b's runs/<point>/<arm> aside to runs-e17b/<point>/<arm> | UNDO: mv /srv/e15/runs-e17b/<point>/<arm> /srv/e15/runs/<point>/`.
  Nothing is deleted. Points and arms that E17c never runs stay where they are.
- `verdict_e17c.py`'s `--moca-commit` filter (the chain passes `E17C_MOCA_PIN`) stays the guard: a rung from another
  commit that is still under `runs/` is listed under `excluded_rungs`, never read.

Then the rest of Task 11 Step 1 (`E17C=1 setup.sh`, the two `snapshot-e17b.sh` leaves `e17c-<pin8>-{1024|256}` under
`E17C=1`, `E17C=1 setup.sh` again, `E17C=1 bringup.sh`) and `chain-e17c.sh --to gate-256` (the stages allowed before
the seal).

## Reproducing E17a (final review M3)

The E17b build changed `workload/project/` (so `bringup.sh` rebuilds the shared `template-pycache-d*` images, also
with `E17B` unset) and the corpora generator's options. Reproducing E17a's templates and corpora needs the E17a tree,
83a4c36. `gen_corpora.sh` with `E17B` unset still writes the E17a corpora (tmpfs share 0), and so does
`pycache_corpus.py` run by hand: its own `--tmpfs-share` default is 0 (E17a's; PR #34), so PLAN.md's E17a command as
written still writes the E17a corpus. `gen_corpora.sh` passes 0.5 under `E17B=1`. E17a and E17b also share
point names and so run paths: `/srv/e15/corpora/pycache`, the templates, and `$E15_RUNS/pycache/sbx`. The point
signature is the same across the two, so only the chain's `moca_commit` preflight keeps an E17a `sbx` rung from being
read as an E17b baseline: it refuses a stage whose run directories hold another commit's `params.json`.

## Known limits for the E17b report

- **M4, refusals while an idle lease existed.** `lease_ends.py` counts a refusal against criterion 3 when
  `leaseVMs - leaseExecuting > 0` at either 1 Hz sample around it. In a closed-loop agent workload that is almost
  always true, so in practice the refusal half of criterion 3 reads "zero refusals". It is also not the worker's own
  notion of reclaimable (gate-held leases, leases past `MaxReclaimsPerScan` or the futility check are skipped). This
  is the conservative direction, so it is reported, not fixed.
- **M5, the level-1 overhead (spec §7.4).** `overhead_compare.py` (ruling E17B-R27) compares `ship-300` at the E17b
  pin with E15 metal's resident patch at the old pin, through a different relay auth path and snapshot, possibly on
  another host instance. `added_ms` is the whole difference: pin, relay path and snapshot included, not only the
  kill, the fresh shell and the privilege drop.
- **M6, slot posture.** Under `E17B=1`, `worker_env` gives `sbx` `WORKER_MAX_CONCURRENT=256` and the ship arms the
  ladder's top N + 256 (1280). It does not bind at the expected `sbx` N, but `params.json` shows two slot postures.
- **Criterion 5, first half (ruling E17B-R29).** `vm_age_lease.py` judges a heavy Exec only when its growth
  (peak - start) is at least 64 MiB, counting the rest as `not_judged_low_growth`, and reports an absolute reading
  (`ceiling_ratio_15s`, `pinned_share` at 0.9 of guest RAM) that a VM pinned at its ceiling cannot pass by being
  pinned. The threshold on it is sealed with the predictions (Task 13).
