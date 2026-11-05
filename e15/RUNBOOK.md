# E15 runbook — replicating the preliminary run

How to rebuild what [`EXPERIMENTS.md`](EXPERIMENTS.md) measured. The design is
[`SPEC.md`](SPEC.md); the build plan is [`PLAN.md`](PLAN.md). Every script named here is in this
directory. Run the rig scripts from their staged copy under `/srv/e15/src/e15/rig/`.

The preliminary run used an AWS `m8i.xlarge` with nested KVM, shared with other services (the
`aws-prelim` host profile, the default). The metal run uses `E15_HOST_PROFILE=fresh-metal` on a
dedicated host and starts with `rig/bootstrap.sh` (SPEC §13). This runbook covers the preliminary
profile.

---

## 0. What you need

**The rig:**
- `/dev/kvm`, cgroups v2, no swap, passwordless sudo, an XFS filesystem under `/srv/e15`
  (workspaces are reflinked);
- Go 1.26, Node 22, pnpm 9, podman, Firecracker and the jailer v1.17.0, `grpcurl` on `PATH`;
- a stock moca guest rootfs tree at `/srv/snapshots/default` (setup.sh adds pytest to it).

**The laptop:**
- this repo at the commit you replicate;
- Python 3.9+ with DuckDB (the extractor), Go 1.26 (driver tests), shellcheck (rig tests);
- TraceLab v0.0.2's `syfi_coding_trace.duckdb`, SHA-256
  `a7bab286bc640844560850965ccf47975cf66407154132abaab90f27ec9be744`. The extractor refuses any
  other file;
- pytest and its Python 3.9 dependencies as wheels (`pip download pytest==8.4.2 --python-version 3.9
  --only-binary=:all: -d wheels/`).

**If the host is shared** (the preliminary rig was), know the rig rules first (SPEC §4):
- E15 never touches `/opt/serverless-harness`, `sh-*` units or ports 8080/8081/8090/8787.
- setup.sh stops `microvm-worker.service` and the `bench-cp` / `bench-redis` containers for the
  run; teardown.sh starts them again.
- Every host change goes into `~/e15-manifest.md` with the command that undoes it.
- E15 binds only 127.0.0.1: attach 9643, exec 9644, null responder 9645, worker stats 9646,
  Redis 6400.

---

## 1. Build the corpora (laptop)

One corpus per point (SPEC §10.3):

```bash
cd e15/extract
python3 extract.py --db syfi_coding_trace.duckdb --H 1800 --out out/default
python3 extract.py --db syfi_coding_trace.duckdb --H 300  --out out/short
python3 extract.py --db syfi_coding_trace.duckdb --H 7200 --out out/long
python3 extract.py --db syfi_coding_trace.duckdb --H 1800 --exclude infra  --out out/no-infra
python3 extract.py --db syfi_coding_trace.duckdb --H 1800 --exclude chains --out out/no-chains
```

Each directory holds `corpus.jsonl` and `corpus-report.json` (every transformation, counted). mem512
reuses `default`. The expected SHA-256 of `default/corpus.jsonl` is in `predictions.json`
(`calibration.corpus_sha256_default`).

## 2. Stage and set up (rig)

```bash
RIG=ec2-user@<host>
ssh $RIG 'sudo mkdir -p /srv/e15/{src,corpora,wheels} && sudo chown $USER /srv/e15/{src,corpora,wheels}'
rsync -a --delete --exclude results/ --exclude __pycache__ e15/ $RIG:/srv/e15/src/e15/
git rev-parse HEAD | ssh $RIG 'cat > /srv/e15/src/COMMIT'
rsync -a wheels/ $RIG:/srv/e15/wheels/
for p in default short long no-infra no-chains; do
  ssh $RIG "mkdir -p /srv/e15/corpora/$p"
  rsync -a e15/extract/out/$p/{corpus.jsonl,corpus-report.json} $RIG:/srv/e15/corpora/$p/
done
ssh $RIG 'bash /srv/e15/src/e15/rig/setup.sh'
```

setup.sh is idempotent. It builds moca v0.9.0 (`c13d5564`), the stock and resident workers
(`resident/apply.sh` applies the patch and runs its tests), the driver, the guest snapshot
(1024 MiB), both workspace templates, Redis and E15's relay. It also measures the volume's read
throughput once (`state/disk_read_max_mbs`). It creates `e15.slice` with `MemoryMax` = host RAM − 3 GiB
and `MemoryHigh` 1 GiB below that, so E15 cannot push the host into a global OOM.

**To resync code later**, run teardown → rsync → setup. On a host that is already up, rsync alone
is enough when only `analysis/` or docs changed.

## 3. Calibrate (SPEC §10.1)

1. **Library run times.** `results/calibration/measure_library.sh` runs every invocation 5 times in
   one VM and writes medians into `commands/library.json` (`run_ms`, `cpu_ms`).
2. **N=1 baselines per arm and point:**
   ```bash
   bash rig/baseline.sh default sbx
   bash rig/baseline.sh default resident-inf
   bash rig/baseline.sh default resident-300
   bash rig/baseline.sh mem512 sbx
   bash rig/baseline.sh mem512 resident-inf
   ```
   Each one draws seeded N=1 sessions until it has 3 evaluable runs and 30 pooled calls, then runs
   the per-class probe (`classprobe.sh`: 17 classes, 20 calls each). Each writes
   `runs/<point>/<arm>/N1/baseline.json`. Each takes about 2.5–3 h.
3. **A2.** `bash rig/rung.sh control 128 default`. The control arm needs no baseline. The driver
   must stay below 1% of host CPU.
4. **N=8 inputs.** One rung per arm (`rung.sh sbx 8 default`, `rung.sh resident-inf 8 default`),
   then `results/calibration/calib_analyze.py` for core-seconds per call and the VM footprint.
5. **Write and seal** `predictions.json` before any measured rung
   (`results/calibration/make_predictions.py`), and commit it.

The other points (short, long, no-infra, no-chains) borrow the default point's baseline. mem512
never does: the point signature in each baseline refuses it.

## 4. The measured ladders (SPEC §10.2–10.3)

```bash
bash rig/ladder.sh default sbx
bash rig/ladder.sh default resident-inf
bash rig/ladder.sh default resident-300
# then each other point, from two ladder steps below that arm's default N_max:
bash rig/ladder.sh short     sbx          <start>
bash rig/ladder.sh short     resident-inf <start>
bash rig/ladder.sh long      sbx|resident-inf|resident-300 <start>
bash rig/ladder.sh no-infra  sbx|resident-inf|resident-300 <start>
bash rig/ladder.sh no-chains sbx|resident-inf|resident-300 <start>
bash rig/ladder.sh mem512    sbx|resident-inf <start>
```

Start the ladders with `grpcurl` on `PATH`: rung.sh needs it for the relay attach check.

Each rung: fresh workspaces, a relay restart, a fresh worker, an attach probe, a 10-minute warm-up and a
15-minute window. Then `analysis/record.py` writes `record.json` with both verdicts (`holds`,
`holds_abs`) and the binding resource. The ladder stops when both verdicts have failed and writes
`runs/<point>/<arm>/ladder.json` (`n_max`, `n_max_abs`).

The ladder repeats a rung by itself in two cases:
- an unseeded session: it re-runs with K doubled (`-k2`);
- footprint drift over 10% (resident arms): it re-runs with the warm-up doubled (`-repeat`).

**The shared-host rule (SPEC §12)** is not in ladder.sh. After each ladder, run the check
on each rung directory:

```bash
python3 results/aws-prelim/scripts/shared_host.py runs/<point>/<arm>/N<n>
```

It flags a rung when non-E15 CPU has a 10 s rolling mean above 10% of host CPU in the window. Re-run
the ladder from the lowest flagged rung.

**Watch the first mem512 resident-inf rung.** Afterwards run
`journalctl -k | grep "Out of memory: Killed process"`. Any line since the rung started means the
memory guards did not hold: stop.

The preliminary run drove all of this with `results/aws-prelim/scripts/chain.sh`. It runs the
ladders in order, applies the shared-host check, steps a failing start rung down, and stops
everything on a global OOM line.

Rig time: about 25 minutes per rung.

## 5. Pull the results (laptop)

```bash
bash results/aws-prelim/scripts/pull.sh   # edit its host/key lines first
```

Before you commit, check for secrets. The rung dirs hold `worker.env`, and the rig's tokens live in
`/srv/e15/secrets`. `results/aws-prelim/scripts/pull.sh` does the pull, then greps the pulled tree, gzipped files
included, for each token's value and for common key patterns. It copies nothing if anything matches.

**Supplementary rungs** (not sealed; outside SPEC §10.2's ladder), for a finer look between two
ladder steps:

```bash
bash rig/fine.sh default sbx 10 12 14   # writes runs/default/sbx/fine.json; never ladder.json
```

**Both readings of the resident results.** `results/aws-prelim/scripts/readings.py /srv/e15/runs`
prints each ladder's sealed reading and its first-run-only reading (footprint-drift repeats
ignored). §12 re-runs of a single rung are merged into `ladder.json` by `merge_shared.py`.

## 6. Tear down

```bash
ssh $RIG 'bash /srv/e15/src/e15/rig/teardown.sh --purge'
```

It replays the manifest's UNDO lines in reverse. Then it verifies `microvm-worker.service` is
active, the bench containers are running, and no E15 unit, port or cgroup is left. `--purge` also
removes `/srv/e15`.

---

_Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>_
