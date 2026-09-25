# moca-experiments

Reproducible performance/behaviour experiments and benchmark drivers for
[MOCA](https://github.com/rossoctl/serverless-harness) (Micro Orchestrator for Cloud Agents;
renaming from `serverless-harness` is in progress) — split out so people deploying MOCA aren't
exposed to research/experiment clutter in the main repo.

## Layout

- `knative/` — E1 (economics/benefit), E3 (mobility), E4 (recovery), E6 (saturation), E7
  (converge-contention): early Kind/OCP cluster experiments, `run-experiments.sh` (E1/E3/E4
  orchestrator), their `EXPERIMENTS.md` write-up, the SWE-bench sandbox-build/measure scripts
  those experiments and `experiments/swebench/` both use, and `lib.sh` — a point-in-time copy of
  the main repo's deployment helper library these scripts need (see the note at the top of that
  file; it is not independently maintained here).
- `microvm/` — E10 (lifecycle), E11 (density/replenishment), E12 (vsock egress), E13 (restore
  capacity/telemetry): bare-metal microVM experiments, their `EXPERIMENTS.md`/`METAL-RUNBOOK.md`
  write-ups, `predictions.json`, and their tests.

**A note on `microvm/` (E10/E11) too:** their cluster-free structural tests (`e10-lifecycle.test.sh`,
`e11-density.test.sh`, `e12-vsock-egress-probe.test.sh`, `e13-*.test.sh`) run standalone here —
those are what CI actually gates on. The drivers themselves (`e10-lifecycle.sh`, `e11-density.sh`)
are bare-metal/root-only regardless of repo, and additionally need: a sibling checkout of the
main repo's `remote-worker/` Go module and `proto/` (override with `REMOTE_WORKER_DIR`,
`PROTO_FILE`, `PROTO_IMPORT_PATH` — real overrides now, not just path arithmetic) for the Go
exec-driver path; and the main repo's own pnpm workspace (`pnpm --filter @sh/sandbox-relay
start`) to launch the sandbox-relay both the container and microvm arms need — that part cannot
be satisfied by an env var at all, since `pnpm --filter` resolves workspace packages from the
current repo's own `pnpm-workspace.yaml`. In practice: run the drivers from a checkout of the
main repo (or a sibling of it with `REMOTE_WORKER_DIR`/`PROTO_FILE`/`PROTO_IMPORT_PATH` set),
same caveat as `knative/`'s cluster experiments and `experiments/`'s E2/E5. `e11-density.test.sh`'s
Go seam-closure check specifically skips gracefully (like its "no go on PATH" check) when no
`remote-worker/` checkout is found, rather than failing.
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

## What did *not* move (stays in the main `moca` repo)

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

## History

Git history for every file here except `knative/lib.sh` (a deliberate point-in-time copy, see
above) was preserved via `git filter-repo` from the main repo at the point of the split
(2026-09-25) — `git log` and `git blame` work as if these files always lived here.

## Relationship to the main repo

This repo holds research/benchmark code only. Production code, deployment automation, and design
docs live in [rossoctl/serverless-harness](https://github.com/rossoctl/serverless-harness) (see
that repo's `docs/specs/` for the architecture and re-architecture plans, track `RA1`).
