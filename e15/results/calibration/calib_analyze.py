"""E15 calibration (SPEC §10.1, §11): the two numbers the predictions need, from N=8 rungs.

  python3 calib_analyze.py sbx RUNG_DIR            -> JSON on stdout
  python3 calib_analyze.py resident RUNG_DIR       -> JSON on stdout
  python3 calib_analyze.py lifecycle BENCH_DIR     -> JSON on stdout (lifecycle_bench.sh output)

Window = [warmup_s, warmup_s + window_s] in the driver's t0 origin (record.py's contract).

sbx: core-seconds per replayed call = (slice_cpu_usec at the last in-window sample - at the first)
     / 1e6 / in-window calls. slice = e15-vms.slice: the worker and every VM it runs (jailer,
     Firecracker vCPU and VMM threads). Also: the per-Exec phase lines (resume_us, destroy_us,
     run_us) of Execs whose log timestamp falls in the window, as wall times.
resident: grown footprint = median of vm_mem (per-VM cgroup memory.current) at the last in-window
     sample; usable = MemAvailable at the first sample at or after t=0 - floor (1536 MiB) - 1 GiB.
lifecycle: Δslice CPU per Exec of a no-op command, idle host, one Exec at a time.
"""
import json
import os
import re
import statistics as st
import sys
from datetime import datetime, timezone

MiB = 1 << 20
LIB = os.environ.get("E15_LIBRARY", "/srv/e15/src/e15/commands/library.json")
PH = re.compile(r"^(\S+)Z vmpool: exec phases (.*)$")


def jl(p):
    out = []
    with open(p) as f:
        for line in f:
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
    return out


def window(d):
    p = json.load(open(os.path.join(d, "params.json")))
    return p, p["warmup_s"], p["warmup_s"] + p["window_s"]


def win_samples(d, a, b):
    return [s for s in jl(os.path.join(d, "samples.jsonl")) if a <= s.get("t", -1e9) <= b]


def phases(d, a_ts, b_ts):
    rows = []
    with open(os.path.join(d, "worker.log"), errors="replace") as f:
        for line in f:
            m = PH.match(line)
            if not m:
                continue
            ts = datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc).timestamp()
            if not (a_ts <= ts <= b_ts + 1):
                continue
            kv = dict(x.split("=", 1) for x in m.group(2).split() if "=" in x)
            rows.append({k: int(v) for k, v in kv.items() if re.fullmatch(r"-?\d+", v)})
    return rows


def med(xs):
    return st.median(xs) if xs else None


def sbx(d):
    p, a, b = window(d)
    ws = win_samples(d, a, b)
    calls = [c for c in jl(os.path.join(d, "calls.jsonl")) if c.get("in_window")]
    ok = [c for c in calls if c.get("status") == "ok"]
    execs = sum(c.get("execs", 0) for c in calls)
    dcpu = (ws[-1]["slice_cpu_usec"] - ws[0]["slice_cpu_usec"]) / 1e6
    de15 = (ws[-1]["e15_cpu_usec"] - ws[0]["e15_cpu_usec"]) / 1e6
    span = ws[-1]["t"] - ws[0]["t"]
    t0 = p["rung_start_ts"]
    ph = phases(d, t0 + a, t0 + b)
    busy = [s["host_cpu_busy_pct"] for s in ws if "host_cpu_busy_pct" in s]
    # Command work, estimated: each in-window call's planned work (planned_dur - chain tail) times
    # its class's measured cpu/run ratio from library.json (stand-in classes use the interpreter's;
    # host_infra is half sleep, half interpreter -- the driver's own split).
    lib = json.load(open(LIB))
    ratio = {c: sum(i["cpu_ms"] for i in l) / float(sum(i["run_ms"] for i in l))
             for c, l in lib["classes"].items()}
    interp = ratio[lib["standin"]["interpreter_class"]]
    infra = (1 - lib["standin"]["infra_sleep_frac"]) * interp
    # work_ms from the corpus (chains: the CPU-carrying part; planned_dur_ms now includes the tail)
    want = {(c["trace"], c["call"]) for c in calls}
    work = {}
    with open(p["corpus"]) as f:
        for line in f:
            sess = json.loads(line)
            for cc in sess["calls"]:
                if (sess["session"], cc["i"]) in want:
                    work[(sess["session"], cc["i"])] = cc["work_ms"]
    cmd_cpu = 0.0
    for c in calls:
        w = work.get((c["trace"], c["call"]), c["planned_dur_ms"]) / 1000.0
        cmd_cpu += w * (infra if c["class"] == "host_infra" else ratio.get(c["class"], interp))
    return {
        "work_matched_calls": len(work),
        "command_cpu_s_est": cmd_cpu,
        "command_core_s_per_call_est": cmd_cpu / len(calls),
        "lifecycle_core_s_per_call_resid": (dcpu - cmd_cpu) / len(calls),
        "lifecycle_core_s_per_exec_resid": (dcpu - cmd_cpu) / execs,
        "rung": d, "n": p["n"], "window_s": p["window_s"], "samples_span_s": span,
        "in_window_calls": len(calls), "in_window_ok": len(ok), "in_window_execs": execs,
        "execs_per_call": execs / len(calls),
        "calls_per_s_per_session": len(calls) / (p["n"] * span),
        "slice_cpu_s": dcpu, "e15_cpu_s": de15,
        "core_s_per_call": dcpu / len(calls),
        "cores_per_session": dcpu / span / p["n"],
        "slice_cores": dcpu / span,
        "host_cpu_busy_pct_mean": st.mean(busy) if busy else None,
        "host_cpu_busy_pct_p95": sorted(busy)[int(0.95 * (len(busy) - 1))] if busy else None,
        "phase_execs": len(ph),
        "phase_median_ms": {k: med([r[k] / 1000.0 for r in ph if k in r and r[k] >= 0])
                            for k in ("acquire_us", "resume_us", "run_us", "destroy_us")},
        "phase_mean_ms": {k: (st.mean([r[k] / 1000.0 for r in ph if k in r and r[k] >= 0]) if ph else None)
                          for k in ("acquire_us", "resume_us", "run_us", "destroy_us")},
    }


def resident(d):
    p, a, b = window(d)
    all_s = jl(os.path.join(d, "samples.jsonl"))
    ws = win_samples(d, a, b)
    with_vm = [s for s in ws if s.get("vm_mem")]
    last = with_vm[-1]["vm_mem"]
    first = with_vm[0]["vm_mem"]
    start = next(s for s in all_s if s.get("t", -1) >= 0)
    floor = p["floor_mb"] * MiB
    usable = start["mem_available_kb"] * 1024 - floor - 1024 * MiB
    calls = [c for c in jl(os.path.join(d, "calls.jsonl")) if c.get("in_window")]
    dcpu = (ws[-1]["slice_cpu_usec"] - ws[0]["slice_cpu_usec"]) / 1e6
    span = ws[-1]["t"] - ws[0]["t"]
    vals = sorted(last.values())
    return {
        "rung": d, "n": p["n"],
        "vms_at_window_end": len(last),
        "vm_mem_window_end_mib": [round(v / MiB, 1) for v in vals],
        "footprint_median_mib": med(vals) / MiB,
        "footprint_max_mib": vals[-1] / MiB,
        "footprint_median_window_start_mib": med(list(first.values())) / MiB,
        "mem_available_at_start_mib": start["mem_available_kb"] / 1024.0,
        "mem_available_at_start_t": start["t"],
        "usable_mib": usable / MiB,
        "slice_mem_window_end_mib": ws[-1]["slice_mem_bytes"] / MiB,
        "in_window_calls": len(calls),
        "calls_per_s_per_session": len(calls) / (p["n"] * span),
        "slice_cpu_s": dcpu, "core_s_per_call": dcpu / len(calls),
        "cores_per_session": dcpu / span / p["n"],
    }


def lifecycle(d):
    r = json.load(open(os.path.join(d, "bench.json")))
    r["core_s_per_exec"] = (r["slice_cpu_usec_after"] - r["slice_cpu_usec_before"]) / 1e6 / r["execs"]
    ph = []
    with open(os.path.join(d, "worker.log"), errors="replace") as f:
        for line in f:
            if "vmpool: exec phases" in line:
                kv = dict(x.split("=", 1) for x in line.split() if "=" in x)
                ph.append({k: int(v) for k, v in kv.items() if re.fullmatch(r"-?\d+", v)})
    ph = ph[r.get("warm_skip", 0):]
    r["phase_median_ms"] = {k: med([x[k] / 1000.0 for x in ph if k in x and x[k] >= 0])
                            for k in ("acquire_us", "resume_us", "run_us", "destroy_us")}
    return r


if __name__ == "__main__":
    fn = {"sbx": sbx, "resident": resident, "lifecycle": lifecycle}[sys.argv[1]]
    print(json.dumps(fn(sys.argv[2]), indent=2))
