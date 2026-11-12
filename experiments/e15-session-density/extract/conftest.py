"""Fixture DuckDB for the extractor tests.

The fixture has the real DB's table and column names (only the columns the extractor reads).
One round per call keeps the fixture simple; the extractor never groups by round.
"""

import datetime

import duckdb
import pytest

BASE = datetime.datetime(2026, 4, 1, 9, 0, 0)


def call(session, tool="exec_command", emit=0, wall=100, internal=None, *, provider=None,
         user="u1", result_at=None, id=None, cont=None, exes=("ls",), skeleton=None,
         chars=10, error=False):
    """One tool_calls row. `emit` and `result_at` are ms offsets from BASE."""
    if provider is None:
        provider = "claude" if tool[0].isupper() else "codex"
    return dict(session=session, provider=provider, user=user, tool=tool, emit=emit, wall=wall,
                internal=internal, result_at=(emit + (wall or 0)) if result_at is None else result_at,
                id=id, cont=cont, exes=list(exes) if exes is not None else None,
                skeleton=skeleton if skeleton is not None else " | ".join(exes or ()),
                chars=chars, error=error)


def pad(session, n, start, step=1000, **kw):
    """n short calls, `step` ms apart, starting at `start`, to lift a session over the floor."""
    return [call(session, emit=start + k * step, **kw) for k in range(n)]


@pytest.fixture
def make_db(tmp_path):
    def _make(calls, name="fixture.duckdb"):
        path = tmp_path / name
        con = duckdb.connect(str(path))
        con.execute("CREATE TABLE rounds (round_pk BIGINT, session_id VARCHAR, provider VARCHAR,"
                    " \"user\" VARCHAR)")
        con.execute("CREATE TABLE tool_calls (round_pk BIGINT, tool_index BIGINT,"
                    " tool_name VARCHAR, tool_call_id VARCHAR, emitted_at TIMESTAMP,"
                    " result_at TIMESTAMP, tool_wall_latency_ms BIGINT,"
                    " tool_internal_latency_ms BIGINT, is_error BOOLEAN, result_chars BIGINT,"
                    " continuation_of_tool_call_id VARCHAR, command_status VARCHAR,"
                    " executables VARCHAR[], executable_parse_status VARCHAR,"
                    " command_skeleton VARCHAR)")
        ms = lambda v: BASE + datetime.timedelta(milliseconds=v)
        for pk, c in enumerate(calls):
            con.execute("INSERT INTO rounds VALUES (?, ?, ?, ?)",
                        [pk, c["session"], c["provider"], c["user"]])
            con.execute("INSERT INTO tool_calls VALUES (?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL,"
                        " ?, 'success', ?)",
                        [pk, c["tool"], c["id"] or f"call_{pk}", ms(c["emit"]), ms(c["result_at"]),
                         c["wall"], c["internal"], c["error"], c["chars"], c["cont"], c["exes"],
                         c["skeleton"]])
        con.close()
        return path
    return _make
