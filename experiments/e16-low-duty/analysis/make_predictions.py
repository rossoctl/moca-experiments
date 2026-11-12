#!/usr/bin/env python3
"""Write the DRAFT experiments/e16-low-duty/predictions.json (SPEC §10) from the committed calibration.

  python3 experiments/e16-low-duty/analysis/make_predictions.py [--out experiments/e16-low-duty/predictions.json]

Inputs (all committed): experiments/e16-low-duty/results/calibration/<arm>/{N1/baseline.json via baseline/, N256-cal/},
experiments/e16-low-duty/results/vm-age/long-rung.json, experiments/e16-low-duty/results/resident-inf/N256-long/, E15 metal default rungs
(experiments/e15-session-density/results/metal/default/<arm>/, sealed ladder + supplementary climb) for the p95-excess-vs-load
slope. Not sealed: status DRAFT, sealed false, no sealedAt (Task 7 Step 4: the user seals).

Latency model, per arm. Load = e15-vms.slice cores over the measured window (the worker and every
VM). E15 metal gives p95 excess against load; E16's cal rung gives (load, p95 excess) at N=256.
Two readings, both reported:
  (a) slope: least-squares slope of p95 excess on load over E15 metal rungs up to the arm's first
      sealed failure (+1 ladder step); N at limit = 256 * (load_cal + (limit - p95x_cal) / slope) / load_cal
  (b) per-session load ratio: E15 metal n_max (and first failure) x (E15 cores/session at its
      deciding rungs) / (E16 cores/session at cal)
The range is [min, max] of (a) and (b), each snapped to the ladder (lower bound down, upper up).
Memory bound (resident): host usable MiB / per-VM slice memory (long rung, at 2.5 h; p95 VM as the
pessimistic per-VM figure).
"""
import argparse
import gzip
import json
import math
import os

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
LADDER = [1, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 128, 160, 192, 256, 320, 384, 448, 512, 576, 640, 704, 768, 896, 1024]
CAL = os.path.join(ROOT, "e16", "results", "calibration")
E15 = os.path.join(ROOT, "e15", "results", "metal", "default")


def jload(p):
    return json.load(open(p))


def samples(d):
    p = os.path.join(d, "samples.jsonl.gz")
    f = gzip.open(p, "rt") if os.path.exists(p) else open(os.path.join(d, "samples.jsonl"))
    return [json.loads(l) for l in f if l.strip()]


def window_load(d):
    p = jload(os.path.join(d, "params.json"))
    a, b = p["warmup_s"], p["warmup_s"] + p["window_s"]
    ws = [s for s in samples(d) if a <= s.get("t", -1) <= b and "slice_cpu_usec" in s]
    cores = (ws[-1]["slice_cpu_usec"] - ws[0]["slice_cpu_usec"]) / 1e6 / (ws[-1]["t"] - ws[0]["t"])
    busy = sorted(s["host_cpu_busy_pct"] for s in ws if "host_cpu_busy_pct" in s)
    live = sorted(len(s.get("vm_mem") or {}) for s in ws)
    vmsum = max(sum((s.get("vm_mem") or {}).values()) for s in ws) / float(1 << 30)
    return {"cores": cores, "host_busy_mean": sum(busy) / len(busy), "host_busy_p95": busy[int(0.95 * (len(busy) - 1))],
            "live_vms_median": live[len(live) // 2], "live_vms_p99": live[int(0.99 * (len(live) - 1))],
            "live_vms_max": live[-1], "vm_mem_sum_max_gib": vmsum,
            "mem_available_min_gib": min(s["mem_available_kb"] for s in ws) / 1048576.0}


def e15_rungs(arm):
    out = []
    dirs = [os.path.join(E15, arm, x) for x in os.listdir(os.path.join(E15, arm))]
    sup = os.path.join(E15, arm, "supplementary-1s")
    dirs += [os.path.join(sup, x) for x in os.listdir(sup) if x.startswith("N")]
    for d in dirs:
        if not os.path.exists(os.path.join(d, "record.json")):
            continue
        r = jload(os.path.join(d, "record.json"))
        if r["n"] < 8 or r.get("p95_excess_ms") is None:
            continue
        out.append({"n": r["n"], "dir": os.path.relpath(d, ROOT), "cores": window_load(d)["cores"],
                    "p95x": r["p95_excess_ms"], "holds": r["holds"]})
    return sorted(out, key=lambda x: (x["n"], x["dir"]))


def slope(rows):
    xs = [r["cores"] for r in rows]
    ys = [r["p95x"] for r in rows]
    mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sum((x - mx) ** 2 for x in xs)


def down(n):
    return max([x for x in LADDER if x <= n], default=LADDER[0])


def up(n):
    return min([x for x in LADDER if x >= n], default=LADDER[-1])


def arm_model(arm, e15_nmax, e15_stop):
    cal_d = os.path.join(CAL, arm, "N256-cal")
    rec = jload(os.path.join(cal_d, "record.json"))
    bl = jload(os.path.join(CAL, "baseline", arm, "N1", "baseline.json"))
    ld = window_load(cal_d)
    rows = e15_rungs(arm)
    upto = LADDER[LADDER.index(e15_stop) + 1]
    fit = [r for r in rows if r["n"] <= upto]
    s = slope(fit)
    lim = rec["excess_limit_ms"]
    cores_at_lim = ld["cores"] + (lim - rec["p95_excess_ms"]) / s
    n_a = 256.0 * cores_at_lim / ld["cores"]
    cps16 = ld["cores"] / 256.0
    dec = [r for r in rows if r["n"] in (e15_nmax, e15_stop) and "/supplementary-1s/" not in r["dir"]]
    cps15 = sum(r["cores"] / r["n"] for r in dec) / len(dec)
    n_b_hold, n_b_fail = e15_nmax * cps15 / cps16, e15_stop * cps15 / cps16
    lo, hi = min(n_a, n_b_hold), max(n_a, n_b_fail)
    return {
        "B_ms": bl["excess_p95_ms"], "limit_ms": lim, "limit_abs_ms": rec.get("p95_limit_abs_ms"),
        "n1_overhead_ms": bl["overhead_ms"], "n1_median_pace": bl.get("n1_median_pace"),
        "undercovered": bl.get("undercovered"), "probe_failed": bl.get("probe_failed"),
        "cal_rung": {"dir": os.path.relpath(cal_d, ROOT), "holds": rec["holds"], "holds_abs": rec["holds_abs"],
                     "p95_excess_ms": rec["p95_excess_ms"], "window_calls": rec["window_calls"],
                     "median_class_pace": rec["median_class_pace"], "failed_calls": rec["failed_calls"],
                     "refusals": rec["refusals"], "footprint_drift_pct": rec.get("footprint_drift_pct"),
                     "repeat_required": rec.get("repeat_required"), "a2_pct_of_host": rec["driver"]["a2_pct_of_host"],
                     "replayed_duty": rec.get("replayed_duty"), "distinct_trace_share": rec.get("distinct_trace_share"),
                     "slice_cores": ld["cores"], "cores_per_session": cps16,
                     "host_cpu_busy_pct_mean": ld["host_busy_mean"], "host_cpu_busy_pct_p95": ld["host_busy_p95"],
                     "live_vms_window": {"median": ld["live_vms_median"], "p99": ld["live_vms_p99"], "max": ld["live_vms_max"]},
                     "vm_mem_sum_max_gib": ld["vm_mem_sum_max_gib"], "mem_available_min_gib": ld["mem_available_min_gib"]},
        "model": {"e15_slope_ms_per_core": s, "e15_fit_rungs": len(fit), "e15_fit_upto_n": upto,
                  "cores_at_limit": cores_at_lim, "n_at_limit_slope": n_a,
                  "e15_n_max": e15_nmax, "e15_stopped_at": e15_stop, "e15_cores_per_session_deciding": cps15,
                  "n_hold_ratio": n_b_hold, "n_fail_ratio": n_b_fail},
        "range": [down(lo), up(hi)],
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(ROOT, "e16", "predictions.json"))
    a = ap.parse_args()
    sbx = arm_model("sbx", 80, 96)
    res = arm_model("resident-inf", 128, 160)
    lr = jload(os.path.join(ROOT, "e16", "results", "vm-age", "long-rung.json"))
    long_d = os.path.join(ROOT, "e16", "results", "resident-inf", "N256-long")
    ll = [s for s in samples(long_d) if s.get("t", -1) >= 600]
    slice_max = max(s["slice_mem_bytes"] for s in ll) / float(1 << 20)
    per_vm_slice = slice_max / 256.0
    snap = lr["at_2_5h"]["rung_time"]
    # e15.slice MemoryMax = host RAM - 3 GiB; the worker's host-memory floor 1536 MiB on top
    host_usable_mib = 377 * 1024 - 3 * 1024 - 1536
    p95_vm = snap["p95"] + (per_vm_slice - snap["sum"] / snap["n"])  # p95 VM plus the per-VM worker share
    mem_bound = [int(host_usable_mib / p95_vm), int(host_usable_mib / per_vm_slice)]
    adm = 377 * 1024 / 1056.0
    sbx_peak_all = max(len(x.get("vm_mem") or {}) for x in samples(os.path.join(CAL, "sbx", "N256-cal")))
    sbx_live_per_s = sbx["cal_rung"]["live_vms_window"]["p99"] / 256.0
    draft = {
        "status": "DRAFT", "sealed": False, "spec": "e16/SPEC.md v0.1", "section": "10",
        "recordedAt": None, "codeCommit": None,
        "note": "DRAFT E16 predictions from the lowduty calibration (N=1 baselines + class probes, one N=256 cal rung per arm) and the long rung (SPEC §6 step 2). To be reviewed and sealed with the user before the first measured ladder rung (PLAN Task 7 Step 4). Generated by e16/analysis/make_predictions.py.",
        "calibration": {
            "host": "AWS m7i.metal-24xl, 96 vCPU, 377 GiB, /srv/e15 XFS reflink",
            "corpus_sha256_lowduty": "0790d748aff79df6fc0f60897b41bbaabb238131d6b1cafb84b6cffce36a0588",
            "worker_admission": {"SH_MAX_COMMITTED_MB": 4194304, "SH_MAX_RUNS": 4096},
            "sbx": sbx, "resident-inf": res,
            "long_rung": {"dir": os.path.relpath(long_d, ROOT), "holds": lr["holds"], "p95_excess_ms": lr["p95_excess_ms"],
                          "median_mib_at_age_min": lr["median_mib_at_age_min"], "growth_20_to": lr["growth_20_to_60_120_180"],
                          "at_2_5h": lr["at_2_5h"], "slice_mem_max_mib": slice_max, "per_vm_slice_mib": per_vm_slice},
        },
        "predictions": [
            {"id": 1,
             "claim": "The hypothesis (SPEC §7.2) is FALSIFIED: SBX's N_max is at or below resident ∞'s. Predicted ranges: SBX N_max in [%d, %d]; resident ∞ N_max in [%d, %d] (ladder top 1024)." % (tuple(sbx["range"]) + tuple(res["range"])),
             "metric": "assembled ladder.json n_max per arm at point lowduty (primary verdict, seeds by majority; e16/rig/chainlib.py)",
             "falsifiedBy": "n_max(SBX) ≥ one ladder step above n_max(resident ∞) (the hypothesis holds); separately, either arm's n_max outside its range falsifies the numeric part",
             "note": ("Both arms are latency-limited and memory is far from binding (prediction 3). At N=256 both cal rungs hold with wide margins (SBX p95 excess %.0f ms vs limit %.0f; resident %.0f vs %.0f) on %.2f / %.2f slice cores. "
                      "SBX: slope reading %.0f, per-session-load reading [%.0f, %.0f]. Resident ∞: slope reading %.0f, per-session-load reading [%.0f, %.0f]. "
                      "The E15 metal ordering (resident 128 > SBX 80, both on condition 4) is expected to persist: at equal cores resident's p95 excess is lower (no per-call cold VM), and low duty lowers both arms' load per session alike (cores/session SBX %.4f vs resident %.4f), so it does not change who reaches the limit first. "
                      "The ranges overlap; a tie within one ladder step also falsifies the hypothesis.") % (
                 sbx["cal_rung"]["p95_excess_ms"], sbx["limit_ms"], res["cal_rung"]["p95_excess_ms"], res["limit_ms"],
                 sbx["cal_rung"]["slice_cores"], res["cal_rung"]["slice_cores"],
                 sbx["model"]["n_at_limit_slope"], sbx["model"]["n_hold_ratio"], sbx["model"]["n_fail_ratio"],
                 res["model"]["n_at_limit_slope"], res["model"]["n_hold_ratio"], res["model"]["n_fail_ratio"],
                 sbx["cal_rung"]["cores_per_session"], res["cal_rung"]["cores_per_session"])},
            {"id": 2,
             "claim": "Each arm's first failed rung fails on condition 4 (added latency, class-matched p95 excess over the limit) with 0 failed calls, no refusal, and no memory verdict; host CPU mean below 25% there.",
             "metric": "record.json at each arm's first failed rung (stopped_at): conditions, failed_calls, refusals, binding/reason, samples host_cpu_busy_pct mean",
             "falsifiedBy": "either arm's first failed rung failing any other condition, any memory verdict (memory_floor, memory_high, host-memory refusal, OOM in e15.slice), or host CPU mean ≥ 25%",
             "note": "E15 metal: every first failure was condition 4 at 9–13%% host CPU. At lowduty N=256 host CPU is %.1f%% (SBX) and %.1f%% (resident) mean. If an arm's ladder tops out at 1024 without failing, this prediction is not tested for that arm." % (
                 sbx["cal_rung"]["host_cpu_busy_pct_mean"], res["cal_rung"]["host_cpu_busy_pct_mean"])},
            {"id": 3,
             "claim": "Resident ∞'s physical memory at its N_max stays below 50%% of host RAM (189 GiB): summed VM memory.current at the N_max rung's window peak in [%d, %d] GiB at the predicted N_max range." % (
                 int(res["range"][0] * (snap["sum"] / snap["n"]) / 1024), math.ceil(res["range"][1] * per_vm_slice / 1024)),
             "metric": "max over the N_max rung's window of sum(samples.jsonl vm_mem) (GiB), and of slice_mem_bytes",
             "falsifiedBy": "summed VM memory ≥ 189 GiB at resident ∞'s N_max rung, or any memory verdict on a resident rung",
             "note": ("Long rung (N=256, 3 h): median VM memory 0 min %.1f, 20 min %.1f, 60 min %.1f, 120 min %.1f, 180 min %.1f MiB (a plateau after ~60 min; the paired 20→180 min +%.0f%% is selection: long-lived sessions are lighter at 20 min). "
                      "At 2.5 h: %d VMs, median %.1f, p95 %.1f, max %.1f MiB, sum %.1f GiB; slice (worker + VMs) peak %.0f MiB = %.0f MiB per VM. "
                      "The band's session spans: median 5 min, p90 5.2 h; a session replayed from a random call has 82 min left on average, so few VMs pass 3 h (memory beyond 3 h is extrapolated flat). "
                      "Physical memory bound: %d (every VM at the p95) to %d (at the measured per-VM slice) sessions, above the 1024 ladder top: memory does not bind resident ∞ at this duty.") % (
                 lr["median_mib_at_age_min"].get("0"), lr["median_mib_at_age_min"].get("20"), lr["median_mib_at_age_min"].get("60"),
                 lr["median_mib_at_age_min"].get("120"), lr["median_mib_at_age_min"].get("180"),
                 lr["growth_20_to_60_120_180"]["180"]["pct"], snap["n"], snap["median"], snap["p95"], snap["max"], snap["sum"] / 1024,
                 slice_max, per_vm_slice, mem_bound[0], mem_bound[1])},
            {"id": 4,
             "claim": "The driver uses less than 1% of host CPU at every E16 rung (A2).",
             "metric": "record.json driver.a2_pct_of_host, max over every E16 rung",
             "falsifiedBy": "any rung with a2_pct_of_host ≥ 1",
             "note": "N=256 cal rungs: %.4f%% (SBX), %.4f%% (resident); E15 metal max 0.0229%% over 43 rungs. Linear to N=1024 gives < 0.1%%." % (
                 sbx["cal_rung"]["a2_pct_of_host"], res["cal_rung"]["a2_pct_of_host"])},
        ],
        "admission_note": ("SPEC §7.3, a calculation, not a verdict: moca's default no-overcommit admission charges each VM 1056 MiB against host RAM (377 GiB), i.e. at most %d live VMs. "
                           "Resident ∞ holds one VM per session, so default admission would refuse it above N ≈ %d. SBX's live VMs at N=256 were %d median / %d p99 in the window (%.2f per session at p99; window max %d; the run's start, all 256 sessions launched within the 60 s spread, peaked at %d live VMs), so in steady state it would be refused above N ≈ %d, and the start-up burst would be refused earlier. "
                           "With admission as configured by default, SBX would hold more sessions than resident ∞ — the effect E16's 4 TiB budget removes on purpose (SPEC §1.2).") % (
            int(adm), int(adm), sbx["cal_rung"]["live_vms_window"]["median"], sbx["cal_rung"]["live_vms_window"]["p99"],
            sbx_live_per_s, sbx["cal_rung"]["live_vms_window"]["max"], sbx_peak_all, int(adm / sbx_live_per_s)),
    }
    with open(a.out, "w") as f:
        json.dump(draft, f, indent=1, ensure_ascii=False)
        f.write("\n")
    print(json.dumps({"sbx": sbx["range"], "resident-inf": res["range"], "sbx_model": sbx["model"], "res_model": res["model"],
                      "mem_bound": mem_bound, "per_vm_slice": per_vm_slice}, indent=1))


if __name__ == "__main__":
    main()
