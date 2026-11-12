# Data sources

Everything here is read-only input. Never modify a source.

## Replay corpora (in this repo)

`data/corpora/<point>/corpus.jsonl.gz` and `corpus-report.json` for the points
`default`, `short`, `long`, `no-infra`, `no-chains`. The `mem512` point replays the
`default` corpus and has no files of its own.

- Extracted from the TraceLab v0.0.2 DuckDB by `e15/extract/extract.py` in
  [rossoctl/moca-experiments](https://github.com/rossoctl/moca-experiments), branch
  `docs/e15-session-density-spec`.
- sha256 of each uncompressed `corpus.jsonl`: see `data/corpora/MANIFEST.md`
  (copied from the export at `/tmp/kagenti/e15-export/`, 2026-11-05). All five were
  verified against that manifest on 2026-11-05.
- One JSON line per session: `session`, `user` (pseudonymous), `provider`
  (`claude`|`codex`), `calls[]` with `i`, `class` (17 command classes), `skeleton`,
  `dur_ms`, `work_ms`, `gap_ms`, `offset_ms`, `out_bytes`, `chain`.

## TraceLab source trace (not in this repo)

- File: `/tmp/kagenti/tracelab/trace/v0.0.2/syfi_coding_trace.duckdb` (153 MB)
- sha256: `a7bab286bc640844560850965ccf47975cf66407154132abaab90f27ec9be744`
  (verified 2026-11-05)
- Tables: `rounds`, `tool_calls`, `timing_events`, `trace_source`. Always open it
  read-only.
- **Do not use** `/tmp/kagenti/tracelab/trace/syfi_coding_trace.duckdb` (no version
  path): it is a different build.
- Source: [uw-syfi/TraceLab](https://github.com/uw-syfi/TraceLab), release v0.0.2
  (published 2026-07-24).
- Licence: **CC BY 4.0**. The trace is 665,453 LLM rounds and 743,819 tool records
  from 8,058 Claude Code and Codex sessions of 52 developers, published by the
  TraceLab project (UW SYFI). Any figure or table in this repo derived from it
  carries that attribution.

## E15 run results (not in this repo; fetched on demand)

- Source repo: [rossoctl/moca-experiments](https://github.com/rossoctl/moca-experiments)
  (public).
  - AWS preliminary run: branch `docs/e15-session-density-spec`, `e15/results/`
    (points, `calibration/`, `default/<arm>/supplementary/`).
  - Metal run (in progress): branch `e15/metal-run`, `e15/results/metal/`.
- Fetch with `scripts/fetch_results.sh` into `data/results/{aws,metal}/`
  (git-ignored). The source commit shas are recorded in `data/results-lock.json`.
- `worker.log.gz` is intentionally not fetched: rung logs may contain tokens.
- Sealed predictions: `e15/predictions.json` (AWS) and `e15/predictions-metal.json`
  (metal). Sealed numbers are never changed; results are reported against them.

## E15 design and record

- Spec: `e15/SPEC.md` (v0.9) and metal changes in SPEC §13 on `e15/metal-run`.
- Record: `e15/EXPERIMENTS.md` (source of truth), `e15/RESULTS-SUMMARY.md`.
- Driver: `e15/driver/replay.go` (session draw, random start index, spread);
  extractor: `e15/extract/extract.py`; rung record: `e15/analysis/record.py`.
