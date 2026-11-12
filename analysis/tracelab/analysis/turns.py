#!/usr/bin/env python3
"""Shell calls per LLM turn, from the TraceLab v0.0.2 DuckDB (PROMPT §3, fourth bullet).

The input of the planned E15b (per-turn bundling). A "turn" is one LLM round
(`rounds.round_pk`): the tool calls one model response emitted. E15b's
extractor bundles consecutive replayed calls of the same `round_pk`
(SPEC-bundled.md §3.1), so this script uses the same unit.

Shell calls: tool_name in exec_command, Bash, shell_command, shell. write_stdin
polls are not new commands (they continue an exec_command, SPEC §5.3) and are
left out. Several scopes are reported, so the number can be matched to whatever
E15b's §1.2 table used:

  all          every shell call in the DuckDB
  dedup        minus copied history (a tool_call_id first seen in an
               earlier-starting session, extract.py STAGE_CALLS)
  corpus       dedup, and only sessions in the E15 default corpus (>= 20
               replayed calls)

Per scope and provider: turns with a shell call, shell calls, mean per turn,
share of shell calls that sit in turns with >= 2, share of turns with >= 2,
and the overlap of same-turn calls (share of consecutive pairs where the next
call is emitted before the previous one has its result).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import (CAT, DUCKDB, PROVIDERS, load_corpus, setup_matplotlib, save_fig,
                    verify_duckdb, write_table, pct)

SHELL = "('exec_command', 'Bash', 'shell_command', 'shell')"

BASE = f"""
CREATE TEMP TABLE sc AS
WITH fe AS (SELECT r.session_id, min(t.emitted_at) AS first_emit
            FROM tool_calls t JOIN rounds r USING (round_pk) GROUP BY 1),
s AS (SELECT t.round_pk, t.tool_index, t.tool_name, t.tool_call_id, t.emitted_at, t.result_at,
             r.provider, r.session_id,
             CASE WHEN t.tool_call_id IS NULL THEN r.session_id
                  ELSE first_value(r.session_id) OVER (PARTITION BY t.tool_call_id
                                                       ORDER BY fe.first_emit, r.session_id)
             END AS owner
      FROM tool_calls t JOIN rounds r USING (round_pk) JOIN fe USING (session_id))
SELECT *, owner <> session_id AS dup FROM s WHERE tool_name IN {SHELL};
"""

PER_TURN = """
WITH x AS (SELECT * FROM sc WHERE {where}),
t AS (SELECT provider, round_pk, count(*) AS n FROM x GROUP BY 1, 2),
o AS (SELECT provider, round_pk, emitted_at,
             lag(result_at) OVER (PARTITION BY round_pk ORDER BY emitted_at, tool_index) AS prev_res
      FROM x)
SELECT t.provider,
       count(*) AS turns,
       sum(n) AS calls,
       sum(n)::DOUBLE / count(*) AS per_turn,
       sum(n) FILTER (WHERE n >= 2)::DOUBLE / sum(n) AS calls_in_multi,
       count(*) FILTER (WHERE n >= 2)::DOUBLE / count(*) AS turns_multi,
       max(n) AS max_n,
       (SELECT count(*) FILTER (WHERE o.prev_res IS NOT NULL AND o.emitted_at < o.prev_res)::DOUBLE
               / nullif(count(*) FILTER (WHERE o.prev_res IS NOT NULL), 0)
        FROM o WHERE o.provider = t.provider) AS overlap_pairs,
       (SELECT count(*) FILTER (WHERE o.prev_res IS NOT NULL) FROM o WHERE o.provider = t.provider)
         AS pairs
FROM t GROUP BY 1 ORDER BY 1
"""

DIST = """
WITH x AS (SELECT * FROM sc WHERE {where}),
t AS (SELECT provider, round_pk, count(*) AS n FROM x GROUP BY 1, 2)
SELECT provider, least(n, 8) AS k, count(*) AS turns, sum(n) AS calls FROM t GROUP BY 1, 2 ORDER BY 1, 2
"""


def main():
    import duckdb
    verify_duckdb()
    con = duckdb.connect(DUCKDB, read_only=True)
    con.execute(BASE)
    corpus_ids = [s["session"] for s in load_corpus("default")]
    # Corpus session ids equal rounds.session_id ("<provider>:<uuid>").
    con.execute("CREATE TEMP TABLE corpus_ids (session_id VARCHAR)")
    con.executemany("INSERT INTO corpus_ids VALUES (?)", [(sid,) for sid in corpus_ids])

    scopes = [("all", "true"),
              ("dedup", "NOT dup"),
              ("corpus", "NOT dup AND session_id IN (SELECT session_id FROM corpus_ids)")]
    rows = []
    dist = {}
    for name, where in scopes:
        res = con.execute(PER_TURN.format(where=where)).fetchall()
        tot_t = sum(r[1] for r in res)
        tot_c = sum(r[2] for r in res)
        multi_c = sum(r[4] * r[2] for r in res)
        multi_t = sum(r[5] * r[1] for r in res)
        for r in res:
            rows.append([name, r[0], r[1], r[2], round(r[3], 2), pct(r[4], 1), pct(r[5], 1), r[6],
                         pct(r[7], 1) if r[7] is not None else None, r[8]])
        rows.append([name, "all", tot_t, tot_c, round(tot_c / tot_t, 2), pct(multi_c / tot_c, 1),
                     pct(multi_t / tot_t, 1), "", "", ""])
        if name == "corpus":
            dist = con.execute(DIST.format(where=where)).fetchall()
    write_table("turns_shell_calls",
                ["scope", "provider", "turns with a shell call", "shell calls", "calls per turn",
                 "calls in turns with >= 2 %", "turns with >= 2 %", "max per turn",
                 "same-turn overlap % of pairs", "same-turn pairs"],
                rows)
    write_table("turns_size_distribution_corpus",
                ["provider", "shell calls in turn (8 = 8+)", "turns", "calls"],
                [list(r) for r in dist])

    # Figure: share of shell calls by turn size, per provider (corpus scope).
    plt = setup_matplotlib()
    fig, ax = plt.subplots(figsize=(5.4, 3.0))
    width = 0.38
    ks = list(range(1, 9))
    for j, prov in enumerate(PROVIDERS):
        tot = float(sum(r[3] for r in dist if r[0] == prov))
        vals = [100 * sum(r[3] for r in dist if r[0] == prov and r[1] == k) / tot for k in ks]
        ax.bar([k + (j - 0.5) * (width + 0.02) for k in ks], vals, width=width, color=CAT[j],
               label=prov)
    ax.set_xticks(ks)
    ax.set_xticklabels([str(k) for k in ks[:-1]] + ["8+"])
    ax.set_xlabel("shell calls in the same LLM turn")
    ax.set_ylabel("share of the provider's shell calls (%)")
    ax.grid(axis="x", visible=False)
    ax.legend()
    ax.set_title("Shell calls per turn (E15 default-corpus sessions, dedup)")
    save_fig(plt, fig, "turns_size_distribution")


if __name__ == "__main__":
    main()
