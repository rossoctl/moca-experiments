"""Rung record (SPEC 9.3): parse driver/sampler/worker files, write record.json.

Time-origin contract: samples.jsonl `t` and driver-cpu.jsonl `t` are seconds since the
driver's t0. The driver-cpu header carries `t0_epoch` (wall clock at t0); params may carry
`rung_start_ts` (same instant, from the caller). If both exist and differ by more than 2 s
the record gets time_origin_mismatch=true and holds=false. The measured window is
[warmup_s, warmup_s + window_s] in that origin, for samples, A2 and refusal scoping.
"""
import argparse
import json
import os
import re
import sys
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import holds as H  # noqa: E402

REFUSAL_RE = re.compile(
    r"\b(?P<reason>memory-budget|host-memory|max-runs|spawn-failure): "
    r"|(?P<busy>\bbusy: queue full)|(?P<re>RESOURCE_EXHAUSTED)"
    r"|(?P<oom>Out of memory|oom-kill|OOMKilled)")
BANNER = "microvm-worker: relay="
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


def _reason(m):
    return m.group("reason") or ("busy" if m.group("busy") else
                                 "RESOURCE_EXHAUSTED" if m.group("re") else "oom")


def count_refusals(path, win_start_ts=None, win_end_ts=None):
    """Return (count, scope, by_reason). Timestamp-scoped only if lines carry parseable
    timestamps and the window's absolute bounds are known."""
    if not os.path.exists(path):
        return 0, "none", {}
    with open(path, errors="replace") as f:
        lines = f.read().splitlines()
    stamped = 0
    hits = []
    for ln in lines:
        m = TS_RE.match(ln)
        ts = _parse_ts(m.group(1)) if m else None
        if ts is not None:
            stamped += 1
        if BANNER in ln:
            continue
        r = REFUSAL_RE.search(ln)
        if r:
            hits.append((ts, _reason(r)))
    scoped = win_start_ts is not None and win_end_ts is not None and stamped
    by = {}
    for ts, why in hits:
        if scoped and ts is not None and not (win_start_ts <= ts <= win_end_ts):
            continue
        by[why] = by.get(why, 0) + 1
    return sum(by.values()), ("window" if scoped else "all_lines"), by


def corpus_offsets(path, traces):
    """{trace: {call index i: offset_ms}} for the given corpus session ids only. A missing corpus
    gives {}: every call after a session's first then counts as an offset_join_miss (holds.expected_ms
    falls back to planned dur + gap) and the rung cannot hold."""
    out = {}
    if not path or not os.path.isfile(path):
        return out
    with open(path) as f:
        for line in f:
            if not line.strip():
                continue
            s = json.loads(line)
            if s.get("session") in traces:
                out[s["session"]] = {c["i"]: c["offset_ms"] for c in s.get("calls", [])}
    return out


def window_samples(samples, start, end):
    return [s for s in samples if "t" in s and start <= s["t"] <= end]


def binding_resource(ws, floor_mb, window_end, refusals, disk_read_max_mbs=None):
    """memory_floor, cpu, disk_io, disk, gate, none -- the first that applies, in that order.
    (build() may then turn a failed rung's "none" into memory_high: memory_events_delta.)
    disk_io: mean disk_read_mbs over the window's last 60 s >= 90% of the volume's measured
    sequential read throughput (setup.sh disk_read_max_mbs; skipped when unknown)."""
    if any(s.get("mem_available_kb", 1 << 60) <= floor_mb * 1024 for s in ws):
        return "memory_floor"
    tail = [s["host_cpu_busy_pct"] for s in ws
            if s["t"] >= window_end - 60 and "host_cpu_busy_pct" in s]
    if tail and sum(tail) / len(tail) >= 90:
        return "cpu"
    if disk_read_max_mbs:
        rd = [s["disk_read_mbs"] for s in ws
              if s["t"] >= window_end - 60 and s.get("disk_read_mbs") is not None]
        if rd and sum(rd) / len(rd) >= 0.9 * disk_read_max_mbs:
            return "disk_io"
    if any(s.get("disk_used_pct", 0) >= 90 for s in ws):
        return "disk"
    if refusals > 0:
        return "gate"
    return "none"


def memory_events_delta(ws):
    """e15.slice memory.events counters (sample.sh e15_mem_events) over the window: the delta
    between the window's first and last sample carrying them, per counter, or None when no
    sample carries them (a rung recorded before the field existed)."""
    ev = [s["e15_mem_events"] for s in ws if isinstance(s.get("e15_mem_events"), dict)]
    if not ev:
        return None
    out = {}
    for k in ("high", "max", "oom_kill"):
        a, b = ev[0].get(k), ev[-1].get(k)
        out[k] = (b - a) if isinstance(a, int) and isinstance(b, int) else None
    return out


def disk_read_stats(ws):
    """Mean and p95 (nearest rank) of disk_read_mbs over the window's samples, and mean await."""
    rd = sorted(s["disk_read_mbs"] for s in ws if s.get("disk_read_mbs") is not None)
    aw = [s["disk_await_ms"] for s in ws if s.get("disk_await_ms") is not None]
    if not rd:
        return {"disk_read_mean_mbs": None, "disk_read_p95_mbs": None,
                "disk_await_mean_ms": (sum(aw) / len(aw)) if aw else None}
    k = max(0, -(-95 * len(rd) // 100) - 1)
    return {"disk_read_mean_mbs": sum(rd) / len(rd), "disk_read_p95_mbs": rd[k],
            "disk_await_mean_ms": (sum(aw) / len(aw)) if aw else None}


def footprint_drift(ws, basis="median"):
    """Resident footprint drift over the window, first to last sample with VMs (SPEC §5.7).

    basis "median" (the default; the sealed preliminary procedure): the median VM's memory.current.
    basis "sum" (fresh-metal, user decision 2026-11-04): the summed memory.current of all live VMs.
    The worker reuses VM cgroup names across sessions, so a median over a few VMs of mixed ages
    steps whenever one VM's session starts a heavier command; the sum is the host-level footprint.
    Both are reported; repeat_required follows the chosen basis.
    """
    with_vm = [s for s in ws if s.get("vm_mem")]
    if not with_vm:
        return None

    def pct(f):
        first = f(list(with_vm[0]["vm_mem"].values()))
        last = f(list(with_vm[-1]["vm_mem"].values()))
        return None if not first else (last - first) / float(first) * 100

    med, tot = pct(H.median), pct(sum)
    chosen = tot if basis == "sum" else med
    if chosen is None:
        return None
    return {"footprint_drift_pct": chosen, "footprint_drift_basis": basis,
            "footprint_drift_median_pct": med, "footprint_drift_sum_pct": tot,
            "repeat_required": chosen > 10}


def driver_cpu(rows, start, end):
    header = next((r for r in rows if r.get("header")), {})
    footer = next((r for r in rows if r.get("footer")), None)
    smp = sorted([r for r in rows if "t" in r and "utime_ms" in r], key=lambda r: r["t"])
    out = {"header": header}
    if footer:
        out["end_sessions"] = {k: footer.get(k) for k in
                               ("end_sessions_sent", "end_sessions_ok", "end_sessions_failed")}
    a = max([r for r in smp if r["t"] <= start] or smp[:1] or [None], key=lambda r: r["t"] if r else 0)
    b = max([r for r in smp if r["t"] <= end] or smp[-1:] or [None], key=lambda r: r["t"] if r else 0)
    if a is None or b is None or a is b or a["t"] == b["t"]:
        out.update(window_cpu_ms=None, a2_pct_of_host=None, a2_ok=False)
        return out
    delta = (b["utime_ms"] + b["stime_ms"]) - (a["utime_ms"] + a["stime_ms"])
    ncpu = header.get("num_cpu") or 1
    pct = delta / ((end - start) * 1000.0 * ncpu) * 100
    out.update(window_cpu_ms=delta, a2_pct_of_host=pct, a2_ok=pct < 1.0)
    return out


def _median(xs):
    xs = sorted(xs)
    n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0


def replayed_duty(calls, start_s, end_s):
    """E16 (informational, no verdict uses it): the duty cycle replayed in the window, per session.

    A call runs [send, send + observed_ms]. The driver stamps a call's `ts` and `t_ms` when it is
    SENT, not when it completes (e15/driver/replay.go runCall: Ts/TMs from `send`, before the
    Exec), so the start is `t_ms` (ms since the driver's t0, the window's origin) and the end is
    t_ms + observed_ms. Over sessions with at least one in-window call: the union of their
    in-window calls' intervals clipped to [start_s, end_s], divided by the window length.
    Returns {"median", "mean", "sessions"}, or None when no call is in the window."""
    lo, hi = start_s * 1000.0, end_s * 1000.0
    per = {}
    for c in calls:
        if not c.get("in_window") or c.get("t_ms") is None:
            continue
        a = max(lo, float(c["t_ms"]))
        b = min(hi, float(c["t_ms"]) + float(c.get("observed_ms") or 0.0))
        per.setdefault(c.get("session"), []).append((a, max(a, b)))
    if not per or hi <= lo:
        return None
    duties = []
    for iv in per.values():
        iv.sort()
        busy, cs, ce = 0.0, iv[0][0], iv[0][1]
        for a, b in iv[1:]:
            if a > ce:
                busy += ce - cs
                cs, ce = a, b
            else:
                ce = max(ce, b)
        busy += ce - cs
        duties.append(busy / (hi - lo))
    return {"median": _median(duties), "mean": sum(duties) / len(duties), "sessions": len(duties)}


def distinct_trace_share(calls):
    """E16 (informational): distinct recorded traces / distinct sessions among in-window calls
    (below 1 when the sampler replays a recorded session more than once at a time); None when no
    call is in the window."""
    win = [c for c in calls if c.get("in_window")]
    sessions = {c.get("session") for c in win}
    if not sessions:
        return None
    return len({c.get("trace") for c in win}) / float(len(sessions))


def build(rung_dir, params, p95_limit_ms=None, ignore_c4=False):
    p = dict(params)
    arm = p.get("arm", "sbx")
    warm, win = p["warmup_s"], p["window_s"]
    start, end = warm, warm + win
    calls = read_jsonl(os.path.join(rung_dir, "calls.jsonl"))
    sessions = read_jsonl(os.path.join(rung_dir, "sessions.jsonl"))
    samples = read_jsonl(os.path.join(rung_dir, "samples.jsonl"))
    cpu_rows = read_jsonl(os.path.join(rung_dir, "driver-cpu.jsonl"))
    rs = p.get("rung_start_ts")
    refusals, scope, by_reason = count_refusals(
        os.path.join(rung_dir, "worker.log"),
        None if rs is None else rs + start, None if rs is None else rs + end)
    # OOM kills in e15.slice over the rung (rung.sh: memory.events oom_kill delta). The kernel
    # line may not reach worker.log, so this counter is the authority (SPEC §8 condition 2).
    oom = int(p.get("oom_kills") or 0)
    if oom > 0:
        refusals += oom
        by_reason["oom_kill"] = by_reason.get("oom_kill", 0) + oom
    # rung.sh's memory watchdog aborted the rung: one host-memory refusal (SPEC §8 condition 2).
    if p.get("memory_abort"):
        refusals += 1
        by_reason["memory_floor_abort"] = 1

    baseline = None
    if p.get("baseline_path"):
        with open(p["baseline_path"]) as f:
            baseline = json.load(f)
        if "excess_p95_ms" not in baseline or "global_median_ms" not in baseline:
            raise SystemExit("record.py: %s is not a class-matched baseline.json" % p["baseline_path"])
    offsets = corpus_offsets(p.get("corpus"), {c.get("trace") for c in calls}) if baseline else None
    ev = H.evaluate(calls, sessions, baseline, arm=arm, refusals=refusals, offsets=offsets,
                    p95_limit_ms=p95_limit_ms, ignore_c4=ignore_c4)
    ws = window_samples(samples, start, end)
    rec = dict(p)
    rec.update(ev)
    n_ok = len(H.window_ok_calls(calls))
    rec["fallback_share"] = (ev["fallback_calls"] / float(n_ok)) if n_ok else None
    rec["undercovered"] = baseline.get("undercovered") if baseline else None
    rec["n1_median_pace"] = baseline.get("n1_median_pace") if baseline else None
    rec["n1_overhead_ms"] = baseline.get("overhead_ms") if baseline else None
    rec["probe_failed"] = baseline.get("probe_failed") if baseline else None
    rec["refusal_scope"] = scope
    rec["refusals_by_reason"] = by_reason
    rec["binding"] = binding_resource(ws, p.get("floor_mb", 1536), end, refusals,
                                      p.get("disk_read_max_mbs"))
    rec.update(disk_read_stats(ws))
    rec["window_samples"] = len(ws)
    if arm in RESIDENT:
        d = footprint_drift(ws, p.get("drift_basis") or "median")
        if d:
            rec.update(d)
    rec["driver"] = driver_cpu(cpu_rows, start, end)
    rec["replayed_duty"] = replayed_duty(calls, start, end)
    rec["distinct_trace_share"] = distinct_trace_share(calls)
    h_epoch = rec["driver"]["header"].get("t0_epoch")
    mismatch = rs is not None and h_epoch is not None and abs(h_epoch - rs) > 2
    rec["time_origin_mismatch"] = bool(mismatch)
    if mismatch:
        rec["holds"] = False
        rec["holds_abs"] = False
    # rung.sh's memory watchdog (host MemAvailable below its floor for 3 s) killed the VMs and
    # stopped the driver: the host could not hold N, bound by memory -- a measured result, not a
    # rig error, so it is not "aborted" and the ladder reads it as a failed rung.
    mem_abort = p.get("memory_abort")
    rec["memory_abort"] = mem_abort
    if mem_abort:
        rec["holds"] = False
        rec["holds_abs"] = False
        rec["binding"] = "memory_floor"
        rec["reason"] = "memory_floor"
    aborted = p.get("driver_exit", 0) != 0 and not mem_abort
    rec["aborted"] = aborted
    if aborted:
        rec["holds"] = False
        rec["holds_abs"] = False
    # Under e15.slice's MemoryHigh, memory pressure shows as reclaim throttling (memory.events
    # "high"), not as a floor hit: a failed rung with no other binding and throttling in the window
    # is bound by memory_high. memory_floor (incl. memory_abort) and every other binding win; a
    # rig error (aborted) is not given a binding; no events data leaves the binding as it was.
    mev = memory_events_delta(ws)
    rec["memory_events_window"] = mev
    if (not rec["holds"] and not aborted and rec["binding"] == "none"
            and mev and (mev.get("high") or 0) > 0):
        rec["binding"] = "memory_high"
    return rec


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("rung_dir")
    ap.add_argument("--params", required=True)
    ap.add_argument("--p95-limit-ms", type=float, default=None,
                    help="supplementary re-judge: flat condition-4 limit for both verdicts (needs --out)")
    ap.add_argument("--ignore-c4", action="store_true",
                    help="supplementary re-judge: conditions 1-3 only (needs --out)")
    ap.add_argument("--out", default=None, help="write the record here instead of RUNG_DIR/record.json")
    a = ap.parse_args(argv)
    out = a.out or os.path.join(a.rung_dir, "record.json")
    if (a.p95_limit_ms is not None or a.ignore_c4) and os.path.abspath(out) == os.path.abspath(os.path.join(a.rung_dir, "record.json")):
        raise SystemExit("record.py: --p95-limit-ms/--ignore-c4 never write record.json; pass --out (e.g. record_1s.json)")
    with open(a.params) as f:
        params = json.load(f)
    rec = build(a.rung_dir, params, p95_limit_ms=a.p95_limit_ms, ignore_c4=a.ignore_c4)
    with open(out, "w") as f:
        json.dump(rec, f, indent=2, sort_keys=True)
    print(rec["holds"])


if __name__ == "__main__":
    main()
