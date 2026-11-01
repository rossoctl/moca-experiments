"""Rung record (SPEC 9.3): parse driver/sampler/worker files, write record.json."""
import argparse
import json
import os
import re
import sys
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import holds as H  # noqa: E402

REFUSAL_RE = re.compile(r"memory-budget|host-floor|busy|queue full|RESOURCE_EXHAUSTED|oom", re.I)
TS_RE = re.compile(r"^\[?(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)\]?")
RESIDENT = ("resident-inf", "resident-300")


def read_jsonl(path):
    out = []
    if not os.path.exists(path):
        return out
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
    return out


def _parse_ts(s):
    s = s.replace("Z", "+00:00").replace(" ", "T")
    s = re.sub(r"([+-]\d{2})(\d{2})$", r"\1:\2", s)
    try:
        return datetime.fromisoformat(s).timestamp()
    except ValueError:
        return None


def count_refusals(path, win_start_ts=None, win_end_ts=None):
    """Return (count, scope). Timestamp-scoped only if lines carry parseable
    timestamps and the window's absolute bounds are known."""
    if not os.path.exists(path):
        return 0, "none"
    lines = open(path, errors="replace").read().splitlines()
    stamped = 0
    hits = []
    for ln in lines:
        m = TS_RE.match(ln)
        ts = _parse_ts(m.group(1)) if m else None
        if ts is not None:
            stamped += 1
        if REFUSAL_RE.search(ln):
            hits.append(ts)
    if win_start_ts is not None and win_end_ts is not None and stamped:
        n = sum(1 for ts in hits if ts is None or win_start_ts <= ts <= win_end_ts)
        # untimestamped hit lines are counted conservatively
        return n, "window"
    return len(hits), "all_lines"


def window_samples(samples, start, end):
    return [s for s in samples if "t" in s and start <= s["t"] <= end]


def binding_resource(ws, floor_mb, window_end, refusals):
    if any(s.get("mem_available_kb", 1 << 60) <= floor_mb * 1024 for s in ws):
        return "memory_floor"
    tail = [s["host_cpu_busy_pct"] for s in ws
            if s["t"] >= window_end - 60 and "host_cpu_busy_pct" in s]
    if tail and sum(tail) / len(tail) >= 90:
        return "cpu"
    if any(s.get("disk_used_pct", 0) >= 90 for s in ws):
        return "disk"
    if refusals > 0:
        return "gate"
    return "none"


def footprint_drift(ws):
    with_vm = [s for s in ws if s.get("vm_mem")]
    if not with_vm:
        return None
    first = H.median(list(with_vm[0]["vm_mem"].values()))
    last = H.median(list(with_vm[-1]["vm_mem"].values()))
    if not first:
        return None
    pct = (last - first) / float(first) * 100
    return {"footprint_drift_pct": pct, "repeat_required": pct > 10}


def driver_cpu(rows, start, end):
    header = next((r for r in rows if r.get("header")), {})
    footer = next((r for r in rows if r.get("footer")), None)
    smp = sorted([r for r in rows if "t" in r], key=lambda r: r["t"])
    out = {"header": header}
    if footer:
        out["end_sessions"] = {k: footer.get(k) for k in
                               ("end_sessions_sent", "end_sessions_ok", "end_sessions_failed")}
    if len(smp) >= 2:
        a = max([r for r in smp if r["t"] <= start] or [smp[0]], key=lambda r: r["t"])
        b = max([r for r in smp if r["t"] <= end] or [smp[-1]], key=lambda r: r["t"])
        delta = (b["utime_ms"] + b["stime_ms"]) - (a["utime_ms"] + a["stime_ms"])
        ncpu = header.get("num_cpu") or 1
        pct = delta / ((end - start) * 1000.0 * ncpu) * 100
        out.update(window_cpu_ms=delta, a2_pct_of_host=pct, a2_ok=pct < 1.0)
    else:
        out.update(window_cpu_ms=None, a2_pct_of_host=None, a2_ok=None)
    return out


def build(rung_dir, params):
    p = dict(params)
    arm = p.get("arm", "sbx")
    warm, win = p["warmup_s"], p["window_s"]
    start, end = warm, warm + win
    calls = read_jsonl(os.path.join(rung_dir, "calls.jsonl"))
    sessions = read_jsonl(os.path.join(rung_dir, "sessions.jsonl"))
    samples = read_jsonl(os.path.join(rung_dir, "samples.jsonl"))
    cpu_rows = read_jsonl(os.path.join(rung_dir, "driver-cpu.jsonl"))
    rs = p.get("rung_start_ts")
    refusals, scope = count_refusals(
        os.path.join(rung_dir, "worker.log"),
        None if rs is None else rs + start, None if rs is None else rs + end)

    ev = H.evaluate(calls, sessions, p.get("baseline_p95_ms"), arm=arm, refusals=refusals)
    ws = window_samples(samples, start, end)
    rec = dict(p)
    rec.update(ev)
    rec["refusal_scope"] = scope
    rec["binding"] = binding_resource(ws, p.get("floor_mb", 1536), end, refusals)
    rec["window_samples"] = len(ws)
    if arm in RESIDENT:
        d = footprint_drift(ws)
        if d:
            rec.update(d)
    rec["driver"] = driver_cpu(cpu_rows, start, end)
    aborted = p.get("driver_exit", 0) != 0
    rec["aborted"] = aborted
    if aborted:
        rec["holds"] = False
    return rec


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("rung_dir")
    ap.add_argument("--params", required=True)
    a = ap.parse_args(argv)
    with open(a.params) as f:
        params = json.load(f)
    rec = build(a.rung_dir, params)
    with open(os.path.join(a.rung_dir, "record.json"), "w") as f:
        json.dump(rec, f, indent=2, sort_keys=True)
    print(rec["holds"])


if __name__ == "__main__":
    main()
