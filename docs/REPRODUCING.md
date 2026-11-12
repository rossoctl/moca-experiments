# Reproducing the experiments

Pick the row that matches what you have. Each experiment's own README, `RUNBOOK.md` or
`SPEC.md` has the exact steps; this page says what you need first and where the pieces are.

| You have | You can do |
|---|---|
| A laptop, no cluster, no root | Run the cluster-free tests (`microvm/tests/*.test.sh`, `e15/rig/tests/rig.test.sh`, `e18/test`, the pytest suites under `e15/` and `e16/`). Re-derive the E15/E16 summaries from the raw traces (below). |
| A laptop with Docker or Podman Compose | E18 (crash recovery on the Compose trial): `e18/run.sh`. |
| A Linux KVM host with root | E10–E14: the microVM drivers and the sandbox-service work. |
| An AWS bare-metal instance (E15 and E16 used an m7i.metal-24xl) | E15–E17: the trace-replay ladders on a metal host, via the rig scripts in `e15/rig` and `e16/rig`. |
| A Kind or OpenShift cluster | E1, E3, E4, E6, E7 (archived; the Knative deployment they target is deprecated). |

## Re-deriving E15 and E16 results from raw traces

The summaries in git (`record.json`, `summary.json`, `RESULTS*.md`) are complete. To
recompute them from the raw traces:

```bash
data/fetch-data.sh                       # downloads and verifies; see data/MANIFEST.md
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python -m pytest e15/analysis e16/analysis e15/extract e16/extract e16/rig    # tests
python3 e16/analysis/results.py                 # regenerates e16/results/summary.json
```

E17's derived results are in `e17/results/` (report `E17A-REPORT.md`, per-rung `latency.json` and
`record-*.json`). Its raw rung traces are not published yet; they will be a `data-v2` archive.

If a recomputed number differs from the committed one, the committed `RESULTS` file wins until
the difference is explained; open an issue.

## Rigs

- **Metal host (E15–E17).** AWS m7i.metal-24xl (96 vCPU, 377 GiB), Ubuntu, host profile
  `fresh-metal`, work dir `/srv/e15`. `e15/rig` has the setup and run scripts; `e16/rig` adds the
  E16 chain. The scripts reach the host over SSH and need `RIG_IP` in the environment and a key
  at `~/.ssh/id_ed25519` (override the key path by editing `K=` in the script). Nothing in the
  repo holds a host address.
- **AWS prelim (E15).** A 4 vCPU nested host; the same scripts with the AWS profile.
- **Compose trial (E18).** The MOCA Compose trial from the main repo, `ghcr.io/rossoctl/moca:latest`.

## What the drivers expect from the main repo

Several drivers use code that lives in [rossoctl/moca](https://github.com/rossoctl/moca) because
it is production code, not experiment code. Run them from a checkout of that repo, or from a
sibling with `REMOTE_WORKER_DIR`, `PROTO_FILE` and `PROTO_IMPORT_PATH` set. Which commit of the
main repo each result was measured against is recorded in that experiment's results document.

## Notes by experiment family

- `microvm/` — E10 (lifecycle), E11 (density/replenishment), E12 (vsock egress), E13 (restore
  capacity/telemetry): bare-metal microVM experiments, their `EXPERIMENTS.md`/`METAL-RUNBOOK.md`
  write-ups, `predictions.json`, and their tests. **Start at
  [`microvm/RESULTS-SUMMARY.md`](microvm/RESULTS-SUMMARY.md)** — the acceptance bar and the
  decision it produced, the latency decomposition, the instrument defects the density
  conclusions rested on, and which published numbers were retracted. `EXPERIMENTS.md`
  remains the source of truth.

**A note on `microvm/` (E10/E11) too:** their cluster-free structural tests (`e10-lifecycle.test.sh`,
`e11-density.test.sh`, `e12-vsock-egress-probe.test.sh`, `e13-*.test.sh`) run standalone here —
those are what CI actually gates on. The drivers themselves (`e10-lifecycle.sh`, `e11-density.sh`)
are bare-metal/root-only regardless of repo, and additionally need: a sibling checkout of the
main repo's `remote-worker/` Go module and `proto/` (override with `REMOTE_WORKER_DIR`,
`PROTO_FILE`, `PROTO_IMPORT_PATH` — real overrides now, not just path arithmetic) for the Go
exec-driver path; and the main repo's own pnpm workspace (`pnpm --filter @moca/sandbox-relay
start`) to launch the sandbox-relay both the container and microvm arms need — that part cannot
be satisfied by an env var at all, since `pnpm --filter` resolves workspace packages from the
current repo's own `pnpm-workspace.yaml`. In practice: run the drivers from a checkout of the
main repo (or a sibling of it with `REMOTE_WORKER_DIR`/`PROTO_FILE`/`PROTO_IMPORT_PATH` set --
`VMPOOLCTL` derives from `REMOTE_WORKER_DIR` automatically unless set separately),
same caveat as `knative/`'s cluster experiments and `experiments/`'s E2/E5. `e11-density.test.sh`'s
Go seam-closure check specifically skips gracefully (like its "no go on PATH" check) when no
`remote-worker/` checkout is found, rather than failing.
- `sbx/` — E14: stock coding agents (Claude Code, OpenCode) whose every command runs in a fresh
  microVM, reached through the sandbox-service prototype (SBX1 wave 0). Three rounds, ending in
  a 40-run SWE-bench Verified comparison of stock against remote. **Start at
  [`sbx/RESULTS-SUMMARY.md`](sbx/RESULTS-SUMMARY.md)**; `EXPERIMENTS.md` is the record,
  `RUNBOOK.md` the replication steps, and `HARNESS.md` every script and config used, embedded
  as markdown.
- `experiments/` — the original `@sh/experiments` workspace package: M6's E2/E5 in-process
  experiment runners, the E11 density-analysis module (`src/microvm-density.ts`, consumed by
  `microvm/e11-density.sh`), and `swebench/` — the SWE-bench sandbox-sharing evaluation harness
  (`gen_swebench_deck.py` for bake-list/deck generation, prediction merging, report summarizing,
  and its own `RUNBOOK.md`).

**A note on the `knative/` experiments (E1/E3/E4/E6/E7):** these require a live Kind/OpenShift
cluster and the main repo's deployment manifests to actually run — they're preserved here as a
point-in-time record of what was measured, not necessarily guaranteed to stay runnable
standalone. The main repo's own direction is moving off Kubernetes entirely (see its
`docs/specs/`, track `RA1`).


## What stays in the main repo


Some things this content depends on are production code or infrastructure, not experiments,
and stayed behind:

- `harness/src/swebench-setup.ts` — real production code, imported by `harness/src/run-leaf.ts`
  (SWE-bench-as-a-workload provisioning inside the live leaf-execution path).
- `remote-worker/` (the whole Go module, including `cmd/exec-driver` and `cmd/null-responder`,
  which `microvm/tests/e11-density.test.sh`'s seam-closure check wants) — kept as one coherent
  module rather than fragmented across two repos. `cmd/vmpoolctl` specifically cannot leave it
  at all: it imports a Go `internal/` package, which no other module may ever import.
- `deploy/knative/swebench-sandbox-buildconfig.yaml` and `swebench-sandbox-pool.yaml` — K8s
  deployment manifests, validated by a production test
  (`packages/knative-server/test/swebench-sandbox-pool.test.ts`, which reads `-pool.yaml`
  specifically).
- `deploy/knative/setup-ocp.sh` and the *original* `lib.sh` — general OpenShift deployment
  tooling, shared by demos and smoke tests that also did not move.
- `deploy/knative/session-usage.py` — a per-leaf cost-calculation utility referenced by the
  main repo's `lib.sh`; the copy of `lib.sh` here calls it too, but the call is guarded (`||
  true`), so cost-report output silently comes out empty here rather than erroring.

`experiments/swebench/RUNBOOK.md` and the code here that references any of the above use paths
relative to the main repo and are marked inline (`# [main repo]`) as such.

