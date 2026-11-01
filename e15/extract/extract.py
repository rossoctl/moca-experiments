#!/usr/bin/env python3
"""E15 corpus extractor: TraceLab v0.0.2 DuckDB -> corpus.jsonl + corpus-report.json.

Implements SPEC §5.2-§5.6:
  stage 1  replayed calls of the sandbox tools, with session, provider and user;
  stage 2  Codex chains: an exec_command and the write_stdin polls that continue it, linked
           within the session, collapsed into one call (lifetime capped at 2 h);
  stage 3  per-call durations with the provider caps;
  stage 4  ordering, gaps (capped at H) and emit offsets;
  then the class of each call (classes.py), the 20-call floor, the optional exclusion, and the
  §5.4 table and §5.5 counts over the written corpus.

Usage: python3 extract.py --db PATH --H 1800 --out DIR [--exclude infra|chains]
"""

import argparse
import hashlib
import itertools
import json
import os
import sys

import duckdb

from classes import classify

DUCKDB_SHA256 = "a7bab286bc640844560850965ccf47975cf66407154132abaab90f27ec9be744"
REAL_DB_NAME = "syfi_coding_trace.duckdb"

REPLAYED_TOOLS = ("exec_command", "Bash", "write_stdin", "shell_command", "shell", "Read",
                  "Write", "Edit", "apply_patch", "Grep", "Glob", "LS", "NotebookEdit",
                  "multiedit")
MIN_CALLS = 20
CHAIN_CAP_MS = 7_200_000
DUR_CAP_MS = {"codex": 120_000, "claude": 30_000}
T300_MS = 300_000
TOOL_LIST = ", ".join("'%s'" % n for n in REPLAYED_TOOLS)
CODEX_CAP_MS, CLAUDE_CAP_MS = DUR_CAP_MS["codex"], DUR_CAP_MS["claude"]

# A command's run time: Codex's internal latency when positive, else the end-to-end time.
RUN_MS = "coalesce(nullif(tool_internal_latency_ms, 0), tool_wall_latency_ms)"

STAGE_CALLS = f"""
CREATE TEMP TABLE calls AS
SELECT t.round_pk, t.tool_index, t.tool_name, t.tool_call_id,
       epoch_ms(t.emitted_at) AS emit, epoch_ms(t.result_at) AS res,
       t.tool_wall_latency_ms AS wall,
       CASE WHEN r.provider = 'codex' THEN {RUN_MS} ELSE t.tool_wall_latency_ms END AS run_ms,
       coalesce(t.is_error, false) AS is_error, coalesce(t.result_chars, 0) AS chars,
       t.continuation_of_tool_call_id AS cont, t.executables,
       coalesce(t.command_skeleton, '') AS skeleton,
       r.session_id, r.provider, r."user"
FROM tool_calls t JOIN rounds r USING (round_pk)
WHERE t.tool_name IN ({TOOL_LIST})
"""

# Polls link to their command within the session. Two Codex sessions of one user share 4,281
# tool_call_ids (the later one re-records the earlier one's history in one hour); a global join
# chains 469 of the earlier session's commands to the later session's polls, days away, and
# those make 468 of the 484 chains a global join caps at 2 h.
STAGE_CHAINS = f"""
CREATE TEMP TABLE chains AS
SELECT e.round_pk, e.tool_index,
       greatest(any_value(e.res), max(w.res)) - any_value(e.emit) AS life_raw,
       coalesce(any_value(e.run_ms), 0) + coalesce(sum(w.run_ms), 0) AS work_raw,
       any_value(e.chars) + sum(w.chars) AS chars
FROM calls e JOIN calls w
  ON w.tool_name = 'write_stdin' AND w.cont = e.tool_call_id AND w.session_id = e.session_id
WHERE e.tool_name = 'exec_command'
GROUP BY e.round_pk, e.tool_index
"""

STAGE_DURATIONS = f"""
CREATE TEMP TABLE durs AS
SELECT c.round_pk, c.tool_index, c.tool_name, c.executables, c.skeleton, c.emit, c.is_error,
       c.session_id, c.provider, c."user",
       ch.round_pk IS NOT NULL AS chain,
       coalesce(ch.chars, c.chars) AS out_bytes,
       CASE WHEN ch.round_pk IS NOT NULL THEN ch.life_raw ELSE c.run_ms END AS dur_raw,
       CASE WHEN ch.round_pk IS NOT NULL THEN least(ch.life_raw, {CHAIN_CAP_MS})
            WHEN c.provider = 'codex' THEN least(c.run_ms, {CODEX_CAP_MS})
            ELSE least(c.run_ms, {CLAUDE_CAP_MS}) END AS dur,
       ch.work_raw
FROM calls c LEFT JOIN chains ch USING (round_pk, tool_index)
WHERE c.wall IS NOT NULL
  AND NOT (c.tool_name = 'write_stdin' AND c.cont IS NOT NULL)
"""

STAGE_ORDER = """
CREATE TEMP TABLE ordered AS
WITH o AS (
  SELECT *, CASE WHEN chain THEN least(work_raw, dur) ELSE dur END AS work,
         lead(emit) OVER w - (emit + dur) AS gap_raw,
         row_number() OVER w - 1 AS i,
         count(*) OVER (PARTITION BY session_id) AS n
  FROM durs
  WINDOW w AS (PARTITION BY session_id ORDER BY emit, round_pk, tool_index))
SELECT *, coalesce(least(greatest(gap_raw, 0), $H), 0) AS gap,
       emit - lag(emit, 1, emit) OVER (PARTITION BY session_id ORDER BY i) AS emit_delta
FROM o
"""


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def parse_args(argv):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--db", required=True)
    p.add_argument("--H", type=int, required=True, help="gap cap, seconds")
    p.add_argument("--out", required=True)
    p.add_argument("--exclude", choices=("infra", "chains"))
    p.add_argument("--skip-sha-check", action="store_true",
                   help="test fixtures only; refused for the real DuckDB")
    return p.parse_args(argv)


def check_db(args):
    if args.skip_sha_check:
        if os.path.basename(args.db) == REAL_DB_NAME:
            sys.exit(f"--skip-sha-check is refused for {REAL_DB_NAME}")
        return None
    got = sha256(args.db)
    if got != DUCKDB_SHA256:
        sys.exit(f"{args.db}: sha256 {got} is not TraceLab v0.0.2's {DUCKDB_SHA256}")
    return got


def load(db, H_ms):
    """Run the stages; return (replayed rows ordered by session and index, total sessions)."""
    con = duckdb.connect(db, read_only=True)
    for stage in (STAGE_CALLS, STAGE_CHAINS, STAGE_DURATIONS):
        con.execute(stage)
    con.execute(STAGE_ORDER.replace("$H", str(H_ms)))
    total = con.execute("SELECT count(DISTINCT session_id) FROM rounds").fetchone()[0]
    cur = con.execute("""
        SELECT session_id, provider, "user", i, tool_name, executables, skeleton, dur, dur_raw,
               work, gap, gap_raw, emit_delta, out_bytes, chain, is_error
        FROM ordered ORDER BY session_id, i""")
    cols = [d[0] for d in cur.description]
    rows = [dict(zip(cols, r)) for r in cur.fetchall()]
    con.close()
    return rows, total


def to_call(r):
    # offset_ms is filled in by sessions().
    return {"i": r["i"], "class": classify(r["tool_name"], r["executables"]),
            "skeleton": r["skeleton"], "dur_ms": r["dur"], "work_ms": r["work"],
            "gap_ms": r["gap"], "offset_ms": 0, "out_bytes": r["out_bytes"],
            "chain": r["chain"]}


def sessions(rows):
    for sid, group in itertools.groupby(rows, key=lambda r: r["session_id"]):
        group = list(group)
        calls = [to_call(r) for r in group]
        # Emit offset from the previous call's emit (§5.4 ordering): the recorded one, which
        # equals prev dur + gap, except that a gap capped at H shortens it. A call emitted
        # while the previous one still ran (gap_raw < 0) keeps its recorded, overlapping offset.
        for prev, cur, r in zip(calls, calls[1:], group[1:]):
            cur["offset_ms"] = min(r["emit_delta"], prev["dur_ms"] + prev["gap_ms"])
        yield {"session": sid, "user": group[0]["user"], "provider": group[0]["provider"],
               "calls": calls}, group


def build(rows, total_sessions, H_ms, exclude):
    """Apply the floor and the exclusion; return (corpus, report counts and table)."""
    corpus, dropped, excluded = [], 0, 0
    rc = dict(chains_collapsed=0, chains_capped=0, chains_capped_ms=0,
              dur_capped={"claude": 0, "codex": 0}, dur_capped_ms={"claude": 0, "codex": 0},
              gap_capped=0, gap_capped_ms=0, errored=0, infra_calls=0, infra_sessions=0,
              chain_sessions=0, opaque_calls=0, unparsed_calls=0)
    busy = {"total": 0, "opaque": 0, "unparsed": 0}
    t = dict(calls=0, dur=0, work=0, span=0, held=0, wakes=0)
    by_provider = {"claude": 0, "codex": 0}
    for s, group in sessions(rows):
        calls = s["calls"]
        if len(calls) < MIN_CALLS:
            dropped += 1
            continue
        has_infra = any(c["class"] == "host_infra" for c in calls)
        has_chain = any(c["chain"] for c in calls)
        if (exclude == "infra" and has_infra) or (exclude == "chains" and has_chain):
            excluded += 1
            continue
        corpus.append(s)
        by_provider[s["provider"]] += 1
        rc["infra_sessions"] += has_infra
        rc["chain_sessions"] += has_chain
        for c, r in zip(calls, group):
            if c["chain"]:
                rc["chains_collapsed"] += 1
                if r["dur_raw"] > CHAIN_CAP_MS:
                    rc["chains_capped"] += 1
                    rc["chains_capped_ms"] += r["dur_raw"] - CHAIN_CAP_MS
            elif r["dur_raw"] > r["dur"]:
                rc["dur_capped"][s["provider"]] += 1
                rc["dur_capped_ms"][s["provider"]] += r["dur_raw"] - r["dur"]
            if r["gap_raw"] is not None and r["gap_raw"] > H_ms:
                rc["gap_capped"] += 1
                rc["gap_capped_ms"] += r["gap_raw"] - H_ms
            rc["errored"] += r["is_error"]
            rc["infra_calls"] += c["class"] == "host_infra"
            busy["total"] += c["dur_ms"]
            for cls in ("opaque", "unparsed"):
                if c["class"] == cls:
                    rc[cls + "_calls"] += 1
                    busy[cls] += c["dur_ms"]
            t["calls"] += 1
            t["dur"] += c["dur_ms"]
            t["work"] += c["work_ms"]
            t["span"] += c["dur_ms"] + c["gap_ms"]
            t["held"] += c["dur_ms"] + min(c["gap_ms"], T300_MS)
            t["wakes"] += c["gap_ms"] > T300_MS
    n, span = len(corpus), t["span"]
    table = dict(
        occupied_pct=100 * t["dur"] / span if span else None,
        work_pct=100 * t["work"] / span if span else None,
        calls_per_s=t["calls"] / (span / 1000) if span else None,
        held_t300_pct=100 * t["held"] / span if span else None,
        wakes_per_session_h=t["wakes"] / (span / 3_600_000) if span else None,
        mean_span_min=span / 60_000 / n if n else None)
    report = dict(sessions=n, by_provider=by_provider, total_sessions=total_sessions,
                  dropped_lt20=dropped, excluded=excluded, **rc,
                  chain_sessions_pct=100 * rc["chain_sessions"] / n if n else None,
                  infra_sessions_pct=100 * rc["infra_sessions"] / n if n else None,
                  opaque_busy_pct=100 * busy["opaque"] / busy["total"] if busy["total"] else None,
                  unparsed_busy_pct=(100 * busy["unparsed"] / busy["total"]
                                     if busy["total"] else None),
                  table=table)
    return corpus, report


def main(argv=None):
    args = parse_args(argv)
    digest = check_db(args)
    H_ms = args.H * 1000
    rows, total = load(args.db, H_ms)
    corpus, report = build(rows, total, H_ms, args.exclude)
    report.update(duckdb_sha256=digest, H_s=args.H, exclude=args.exclude)
    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "corpus.jsonl"), "w") as f:
        for s in corpus:
            f.write(json.dumps(s, separators=(",", ":")) + "\n")
    with open(os.path.join(args.out, "corpus-report.json"), "w") as f:
        json.dump(report, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
