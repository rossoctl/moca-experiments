#!/usr/bin/env python3
"""E16 duty-band filter: keep the sessions of an E15 corpus whose duty cycle is in (min, max].

Duty cycle = occupied time (at least one call running) / span, on the replay timeline (E15 SPEC
§5.4), computed by experiments/e15-session-density/extract/extract.py:timeline. A session whose span is 0 has no duty and is
skipped. Sessions are written in input order, unchanged.

Usage: python3 duty_band.py --in CORPUS.jsonl[.gz] --out DIR --duty-min 0.01 --duty-max 0.02
       [--allow-no-report]   (else the source corpus-report.json beside --in is required)
"""

import argparse
import collections
import gzip
import hashlib
import json
import os
import sys
import types

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..",
                                 "experiments", "e15-session-density", "extract"))
try:
    import duckdb  # noqa: F401  (extract.py imports it at module level; timeline() never uses it)
except ImportError:
    sys.modules["duckdb"] = types.ModuleType("duckdb")
from extract import timeline  # noqa: E402


def duty(calls):
    """Occupied / span on the replay timeline; None when the span is not positive."""
    span, busy, _, _ = timeline(calls)
    if span <= 0:
        return None
    return busy / span


def read_lines(path):
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rb") as f:
        for line in f:
            yield line


def read_source_report(src, allow_missing=False):
    """The source corpus's corpus-report.json beside it. Missing or unreadable: exit 2 (H_s and
    exclude, which rung.sh records, would otherwise be silently null), unless allow_missing, which
    gives {} for a missing one."""
    path = os.path.join(os.path.dirname(os.path.abspath(src)), "corpus-report.json")
    if not os.path.exists(path):
        if allow_missing:
            return {}
        sys.stderr.write("duty_band.py: no %s beside the input corpus (H_s and exclude come from it); "
                         "stage it or pass --allow-no-report\n" % path)
        sys.exit(2)
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        sys.stderr.write("duty_band.py: cannot read %s: %s\n" % (path, e))
        sys.exit(2)


def parse_args(argv):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--in", dest="src", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--duty-min", type=float, required=True, help="exclusive")
    p.add_argument("--duty-max", type=float, required=True, help="inclusive")
    p.add_argument("--allow-no-report", action="store_true",
                   help="run without the source corpus-report.json (H_s and exclude null)")
    return p.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    src_report = read_source_report(args.src, args.allow_no_report)
    h = hashlib.sha256()
    kept = []
    users = collections.Counter()
    by_provider = collections.Counter()
    t = dict(calls=0, work=0, span=0, busy=0)
    for line in read_lines(args.src):
        h.update(line)
        if not line.strip():
            continue
        s = json.loads(line)
        span, busy, _, _ = timeline(s["calls"])
        if span <= 0:
            continue
        d = busy / span
        if not (args.duty_min < d <= args.duty_max):
            continue
        kept.append(line if line.endswith(b"\n") else line + b"\n")
        users[s["user"]] += 1
        by_provider[s["provider"]] += 1
        t["calls"] += len(s["calls"])
        t["work"] += sum(c["work_ms"] for c in s["calls"])
        t["span"] += span
        t["busy"] += busy
    n, span = len(kept), t["span"]
    report = dict(
        source_sha256=h.hexdigest(), duty_min=args.duty_min, duty_max=args.duty_max,
        sessions=n, users=len(users),
        top_user_share=max(users.values()) / n if n else None,
        by_provider=dict(sorted(by_provider.items())),
        occupied_pct=100 * t["busy"] / span if span else None,
        work_pct=100 * t["work"] / span if span else None,
        calls_per_s_per_session=t["calls"] / (span / 1000) if span else None,
        mean_span_h=span / 3_600_000 / n if n else None)
    # The fields rung.sh reads from a point's corpus-report.json (K from table.mean_span_min;
    # H_s and exclude recorded in params.json), H_s and exclude from the source corpus's report.
    report.update(
        H_s=src_report.get("H_s"), exclude=src_report.get("exclude"),
        corpus_sha256=hashlib.sha256(b"".join(kept)).hexdigest(),
        table=dict(occupied_pct=report["occupied_pct"], work_pct=report["work_pct"],
                   calls_per_s=report["calls_per_s_per_session"],
                   mean_span_min=span / 60_000 / n if n else None))
    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "corpus.jsonl"), "wb") as f:
        f.writelines(kept)
    with open(os.path.join(args.out, "corpus-report.json"), "w") as f:
        json.dump(report, f, indent=2)
        f.write("\n")
    return report


if __name__ == "__main__":
    main()
