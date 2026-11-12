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
| `gen_corpora.sh [--durations-from CAL.json]` | laptop: `pycache_corpus.py` into `$E17_CORPORA/pycache/` (duty 0.095) and `pycache-low/` (0.015), 400 sessions, seed 1, min-turns 4, gaps from the E15 default corpus. `--durations-from`: each class's measured N=1 median `run_ms` replaces the placeholder `dur_ms`/`work_ms` |
| `sync.sh` | laptop: rsync `experiments/e15-session-density/`, `experiments/e16-low-duty/` and `experiments/e17-lease/` to `/srv/e15/src/`, and install the metal library. Stage the corpora `$E17_CORPORA/{pycache,pycache-low}/` to `/srv/e15/corpora/<point>/`, and the wheels `$E17_WHEELS/` to `/srv/e15/wheels-pycache/` |
| `bringup.sh` | host, idempotent, after `setup.sh`: check the corpora and the wheels against `wheels.lock`; loop-mount the snapshot rootfs that `state/artifacts` records, read-only; build `template-pycache-d{64,256,768}`; stamp each image's sha256 in `state/template-pycache-d<D>`. Each template is skipped while its inputs stamp matches. Manifest `~/e17-manifest.md` |
| `smoke.sh` | host: `rung.sh ARM 1 pycache` per arm (60 s warm-up, 120 s window, tag `smoke`). On `sbx`: the `py_analyze` calls exit 0, and one `py_analyze` Exec through the relay prints the D=256 `BUILD`'s `dataset_sha256`. Then `warmcold.py` on each rung |
| `reprobe.sh ARM` | host (Task 5b): re-run only `classprobe.sh pycache ARM` under the pycache probe cap (`E15_P_PROBE_CAP_MS=120000`, points.sh; E15's 30 s cap made `py_test`'s median +31 s) and recompute `runs/pycache/ARM/N1/baseline.json` with `baseline.py` from the seeded runs `baseline.sh` counted plus the new probes. The old probe is moved aside to `_cap30k-N1-probe-*`, `_cap30k-probe-corpora` and `N1/baseline.cap30k.json`. Refuses while a rung's worker runs, and refuses a second run |

Then, on the host: `rung.sh {sbx|resident-300|lease-30|lease-120} N {pycache|pycache-low|pycache-d64|pycache-d768}`.
Rig runs are started by the controller only.

Tests: `bash experiments/e15-session-density/rig/tests/rig.test.sh` (the E17 section, plus golden dumps of the pre-E17 points
and arms in `experiments/e15-session-density/rig/tests/golden/`) and `pytest e17`.
