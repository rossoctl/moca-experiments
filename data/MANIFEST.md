# Raw experiment data

The per-run raw traces behind E15 and E16 (call logs, worker logs, CPU samples, per-session
logs) are about 1.4 GB uncompressed and are **not stored in git**. Everything needed to read
the results is in git: the `record.json`, `params.json`, `summary.json` and `RESULTS` files,
the sealed `predictions*.json`, and the analysis code. The raw traces are only needed to
re-derive those summaries from scratch.

They are published as release assets of this repository, one archive per experiment arm.
E17's raw rung traces (from 2026-11-12) are not published yet: they have not been pulled from the experiment host
and will arrive as `data-v2` once pulled. E17's derived results are in git under `e17/results/`.
Archive paths are repo-relative, so extracting at the repo root puts every file back where
the analysis scripts expect it.

| Archive | Files | Size | Extracts under | sha256 |
|---|---|---|---|---|
| `moca-experiments-e15-metal-raw.tar.gz` | 569 | 119 MB | `e15/results/metal/` | `99cfe2d0692600d264ea52d8c5e24c7bfdd4147b01dc02207bd50bb7f7b7dacb` |
| `moca-experiments-e16-resident-inf-raw.tar.gz` | 150 | 212 MB | `e16/results/resident-inf/` | `01719466c3716608e9db65a2dff068dc7c9f6965ebbd336ab825283eae7eb311` |
| `moca-experiments-e16-sbx-raw.tar.gz` | 65 | 170 MB | `e16/results/sbx/` | `3fc449e171882cf1eabd43c0006226387b4c91ad3938c812f410c5dc2a35df81` |

Release: `data-v1`. The file lists inside each archive are in `data/*.files`.

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

Files with the same names under `e15/results/calibration/` and `e16/results/calibration/`,
`e16/results/control/` are small and stay in git.

## Changing an archive

Release assets can be replaced, so the checksum in this table is the source of truth. Never
replace an asset without publishing a new tag (`data-v2`) and updating this table.
