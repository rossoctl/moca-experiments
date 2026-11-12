# Raw experiment data

The per-run raw traces behind E15 and E16 (call logs, worker logs, CPU samples, per-session
logs) are about 1.4 GB uncompressed and are **not stored in git**. Everything needed to read
the results is in git: the `record.json`, `params.json`, `summary.json` and `RESULTS` files,
the sealed `predictions*.json`, and the analysis code. The raw traces are only needed to
re-derive those summaries from scratch.

They are published as release assets of this repository, one archive per experiment arm.
E17's raw rung traces (from 2026-11-12) are not published yet: they have not been pulled from the
experiment host and will arrive as `data-v3` once pulled. E17's derived results are in git under
`experiments/e17-lease/results/`.
The `data-v1` and `data-v2` archives were built before the 2026-11 experiments/ reorganization,
so their members still use the old paths (`e15/results/...`, `e16/results/...`). The fetch
scripts map them to the current layout, shown in the **Extracts under** column.

| Archive | Files | Size | Extracts under | sha256 |
|---|---|---|---|---|
| `moca-experiments-e15-metal-raw.tar.gz` | 569 | 119 MB | `experiments/e15-session-density/results/metal/` | `99cfe2d0692600d264ea52d8c5e24c7bfdd4147b01dc02207bd50bb7f7b7dacb` |
| `moca-experiments-e16-resident-inf-raw.tar.gz` | 150 | 212 MB | `experiments/e16-low-duty/results/resident-inf/` | `01719466c3716608e9db65a2dff068dc7c9f6965ebbd336ab825283eae7eb311` |
| `moca-experiments-e16-sbx-raw.tar.gz` | 65 | 170 MB | `experiments/e16-low-duty/results/sbx/` | `3fc449e171882cf1eabd43c0006226387b4c91ad3938c812f410c5dc2a35df81` |

Release: `data-v1`. The file lists inside each archive are in `data/*.files`.

### Analysis inputs (`data-v2`)

The tracelab analysis (`analysis/tracelab/`) also needs the E15 AWS preliminary results and the
replay corpora. They are not in git either; they are release `data-v2`:

| Archive | Size | Extracts under | sha256 |
|---|---|---|---|
| `moca-experiments-tracelab-aws.tar.gz` | 11 MB | `analysis/tracelab/data/results/aws/` | `d07f2dac5801b84c2e346f9562bdf922227da087bb39d4b5e7dde519ef29f821` |
| `moca-experiments-tracelab-corpora.tar.gz` | 42 MB | `analysis/tracelab/data/corpora/` | `5a9ab88b51a2493f73680edaa8a05fad8bb941c34bb1ea805db8eee649a5e5a7` |

`analysis/tracelab/scripts/fetch_results.sh` downloads `data-v1` and `data-v2`, verifies every
checksum, and unpacks them into `analysis/tracelab/data/`. That is the supported way to reproduce
the analysis; `data/fetch-data.sh` covers the per-experiment archives only.

## Fetch

```bash
data/fetch-data.sh            # all archives
data/fetch-data.sh e16-sbx    # one archive (e15-metal, e16-resident-inf, e16-sbx)
```

The script downloads from the release, verifies the sha256 against this table, and extracts
at the repo root. It refuses to extract an archive whose checksum does not match.

## What the raw files are

| File | Content |
|---|---|
| `calls.jsonl`, `calls.jsonl.gz` | one row per replayed command: start, end, latency, outcome |
| `sessions.jsonl` | per-session summary written by the driver |
| `samples.jsonl.gz` | periodic host and VM resource samples |
| `driver-cpu.jsonl` | driver process CPU samples |
| `worker.log.gz` | worker log for the run |

Files with the same names under `experiments/e15-session-density/results/calibration/` and `experiments/e16-low-duty/results/calibration/`,
`experiments/e16-low-duty/results/control/` are small and stay in git.

## Changing an archive

Release assets can be replaced, so the checksum in this table is the source of truth. Never
replace an asset without publishing a new tag (`data-v3`) and updating this table.
