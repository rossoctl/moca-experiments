"""Write e15/predictions.json from the calibration outputs (SPEC §11).

  python3 make_predictions.py CAL_DIR OUT_JSON CODE_COMMIT

CAL_DIR holds the copied calibration outputs:
  baseline/<arm>/baseline.json         pooled N=1 baselines (baseline.sh)
  rungs/control-N128/record.json       A2
  rungs/sbx-N8-cal/analysis.json       calib_analyze.py sbx
  rungs/resident-inf-N8-cal/analysis.json  calib_analyze.py resident
  rungs/<arm>-N8-cal/record.json       holds at N=8

Arithmetic (shown verbatim in each prediction's note):
  SBX:      N_cpu = usable_cores / cores_per_session, cores_per_session = c * r, where
            c = core-seconds per replayed call (= per Exec) at N=8, r = calls/s/session (corpus).
            usable_cores = 4 vCPU x [0.80, 0.90] (the CPU wall: 90% busy is the binding threshold;
            80% is where pace degrades first on a 1-vCPU-per-guest nested host).
  Resident: N_mem = usable_MiB / footprint_MiB, footprint = median grown memory.current at the
            window end at N=8, range [median, max] of the N=8 VMs.
  Each N is rounded DOWN to the ladder (the largest rung <= N), since N_max is a ladder value.
"""
import json
import math
import os
import sys

LADDER = [1, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 128]
HOST_VCPU = 4


def on_ladder(n):
    below = [x for x in LADDER if x <= n]
    return below[-1] if below else 0


def load(p):
    with open(p) as f:
        return json.load(f)


def spec_version():
    """`e15/SPEC.md vX.Y` from SPEC.md's own Version line, so the sealed file names what it read."""
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "..", "..", "SPEC.md")) as f:
        for line in f:
            if line.startswith("Version:"):
                return "e15/SPEC.md v" + line.split()[1]
    raise SystemExit("make_predictions: no Version line in SPEC.md")


def p95_factor():
    """SPEC §8 condition 4's factor, from analysis/holds.py (the code that judges the rungs)."""
    here = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, os.path.join(here, "..", "..", "analysis"))
    import holds  # noqa: E402
    return holds.P95_FACTOR, holds.ABS_ADDED_MS, holds.EXCESS_FLOOR_MS


def main(cal, out, commit):
    factor, abs_ms, floor_ms = p95_factor()
    ARMS = ("sbx", "resident-inf", "resident-300")
    b = {a: load(os.path.join(cal, "baseline", a, "baseline.json"))
         for a in ("sbx", "resident-inf", "resident-300")}
    ctl = load(os.path.join(cal, "rungs", "control-N128", "record.json"))
    sa = load(os.path.join(cal, "rungs", "sbx-N8-cal", "analysis.json"))
    ra = load(os.path.join(cal, "rungs", "resident-inf-N8-cal", "analysis.json"))
    # The N=8 records judged by the current analysis (record.py re-run on the same rung dirs
    # against the current baselines) when present; the numbers themselves are the rung's.
    def rec_of(name):
        rj = os.path.join(cal, "rungs", name, "record.rejudged-617ebb7.json")
        return load(rj) if os.path.exists(rj) else load(os.path.join(cal, "rungs", name, "record.json"))
    srec = rec_of("sbx-N8-cal")
    rrec = rec_of("resident-inf-N8-cal")
    m5 = os.path.join(cal, "mem512-smoke")
    mb = {a: load(os.path.join(cal, "baseline-mem512", a, "baseline.json")) for a in ("sbx", "resident-inf")}
    ms_sbx = load(os.path.join(m5, "sbx-N8-cal", "analysis.json"))
    ms_res = load(os.path.join(m5, "resident-inf-N8-cal", "analysis.json"))
    mr = {k: load(os.path.join(m5, "smoke-mem512-%s.readings.json" % k))
          for k in ("sbx-N8", "resident-inf-N8", "sbx-N32", "resident-inf-N32-guard")}
    disk_max = load(os.path.join(m5, "sbx-N32-cal", "params.json")).get("disk_read_max_mbs")
    # MemAvailable minimum over the WHOLE guard rung (warm-up included): the squeeze came at t≈250 s
    guard_min = load(os.path.join(m5, "guard-rung-memavail.json"))
    rep = load(os.path.join(cal, "corpus-reports", "default.json"))
    lcp = os.path.join(cal, "lifecycle", "summary.json")
    lc = load(lcp) if os.path.exists(lcp) else None
    rep_long = load(os.path.join(cal, "corpus-reports", "long.json"))

    r = rep["table"]["calls_per_s"]
    r_long = rep_long["table"]["calls_per_s"]
    c = sa["core_s_per_call"]
    cps = c * r
    lo_c, hi_c = HOST_VCPU * 0.80, HOST_VCPU * 0.90
    n_sbx_lo, n_sbx_hi = lo_c / cps, hi_c / cps
    held300 = rep["table"]["held_t300_pct"] / 100.0

    fp_med = ra["footprint_median_mib"]
    fp_max = ra["footprint_max_mib"]
    usable = ra["usable_mib"]
    n_res_mem_lo, n_res_mem_hi = usable / fp_max, usable / fp_med
    # resident ∞ also burns CPU: its own measured per-call CPU at N=8 (commands + guest, no lifecycle)
    c_res = ra["core_s_per_call"]
    n_res_cpu_lo, n_res_cpu_hi = lo_c / (c_res * r), hi_c / (c_res * r)
    n_res_lo, n_res_hi = min(n_res_mem_lo, n_res_cpu_lo), min(n_res_mem_hi, n_res_cpu_hi)
    lc_direct = lc["core_s_per_exec"] if lc else None
    lc_diff = c - c_res

    # resident 300: memory bound with 56% held; CPU bound at the resident's measured per-call CPU
    cmd_c = sa["command_core_s_per_call_est"]
    n300_mem = usable / (fp_med * held300)
    n300_cpu_lo, n300_cpu_hi = n_res_cpu_lo, n_res_cpu_hi
    n300_lo = min(n300_mem, n300_cpu_lo)
    n300_hi = min(n300_mem, n300_cpu_hi)
    # long gaps: SBX scales with 1/r
    n_sbx_long_lo, n_sbx_long_hi = lo_c / (c * r_long), hi_c / (c * r_long)

    L = on_ladder
    # --- mem512 (prediction 9) ---
    SCAN_SHARE = 0.6403          # share of default-corpus calls in the scanning classes
    DATASET_MIB = 512
    m_fp_med, m_fp_max = ms_res["footprint_median_mib"], ms_res["footprint_max_mib"]
    m_usable = ms_res["usable_mib"]
    m_res_lo, m_res_hi = m_usable / m_fp_max, m_usable / m_fp_med
    m_c_sbx = ms_sbx["core_s_per_call"]
    m_sbx_cpu_lo, m_sbx_cpu_hi = lo_c / (m_c_sbx * r), hi_c / (m_c_sbx * r)
    read_mib_s = DATASET_MIB * SCAN_SHARE * r              # MiB/s per SBX session once uncached
    m_sbx_disk = disk_max * 1e6 / (1 << 20) / read_mib_s
    page_cache_mib = mr["sbx-N8"]["page_cache_max_mib"]
    m_sbx_cache_n = page_cache_mib / DATASET_MIB
    m_sbx_lo = min(m_sbx_cpu_lo, max(m_sbx_disk, m_sbx_cache_n))
    m_sbx_hi = min(m_sbx_cpu_hi, max(m_sbx_disk, m_sbx_cache_n))
    sbx_rng = [L(n_sbx_lo), L(n_sbx_hi)]
    res_rng = [L(n_res_lo), L(n_res_hi)]
    r300_rng = [L(n300_lo), L(n300_hi)]

    cal_obj = {
        "library_sha256": sa.get("library_sha256") or srec.get("library_sha256"),
        "driver_bin_sha256": srec.get("driver_bin_sha256"),
        "corpus_sha256_default": srec.get("corpus_sha256"),
        "snapshot_hash": srec.get("snapshot_hash"),
        "baseline_p95_ms": {a: b[a]["baseline_p95_ms"] for a in b},
        "baseline_excess_p95_ms": {a: b[a].get("excess_p95_ms") for a in b},
        "n1_overhead_ms": {a: b[a].get("overhead_ms") for a in b},
        "class_medians_ms": {a: b[a].get("class_medians") for a in b},
        "undercovered": {a: b[a].get("undercovered") for a in b},
        "probe_failed": {a: b[a].get("probe_failed") for a in b},
        "excess_limit_ms": {a: max(factor * b[a]["excess_p95_ms"], floor_ms) for a in b},
        "excess_limit_abs_ms": {a: b[a]["excess_p95_ms"] + abs_ms for a in b},
        "baseline_pooled_calls": {a: b[a]["calls"] for a in b},
        "baseline_seeds": {a: {"evaluable": [e["seed"] for e in b[a]["evaluable"]],
                               "skipped": [k["seed"] for k in b[a]["skipped"]]} for a in b},
        "a2_control_n128_pct_of_host": ctl["driver"]["a2_pct_of_host"],
        "sbx_n8": {"holds": srec["holds"], "holds_abs": srec.get("holds_abs"),
                   "p95_excess_ms": srec.get("p95_excess_ms"),
                   "lifecycle_core_s_per_exec_direct": lc_direct,
                   "sbx_minus_resident_core_s_per_call": lc_diff,
                   "core_s_per_call": c, "calls_in_window": sa["in_window_calls"],
                   "execs_per_call": sa["execs_per_call"],
                   "command_core_s_per_call_est_library_ratio": cmd_c,
                   "phase_median_ms": sa["phase_median_ms"],
                   "host_cpu_busy_pct_mean": sa["host_cpu_busy_pct_mean"]},
        "resident_inf_n8": {"holds": rrec["holds"], "holds_abs": rrec.get("holds_abs"),
                            "p95_excess_ms": rrec.get("p95_excess_ms"),
                            "footprint_median_mib": fp_med, "footprint_max_mib": fp_max,
                            "vms_at_window_end": ra["vms_at_window_end"],
                            "mem_available_at_start_mib": ra["mem_available_at_start_mib"],
                            "usable_mib": usable,
                            "core_s_per_call": ra["core_s_per_call"]},
        "corpus_calls_per_s_per_session": {"default": r, "long": r_long},
        "mem512": {
            "baseline_excess_p95_ms": {a: mb[a]["excess_p95_ms"] for a in mb},
            "n1_overhead_ms": {a: mb[a].get("overhead_ms") for a in mb},
            "n1_median_pace": {a: mb[a].get("n1_median_pace") for a in mb},
            "class_medians_ms": {a: mb[a]["class_medians"] for a in mb},
            "excess_limit_ms": {a: max(factor * mb[a]["excess_p95_ms"], floor_ms) for a in mb},
            "excess_limit_abs_ms": {a: mb[a]["excess_p95_ms"] + abs_ms for a in mb},
            "seeds": {a: {"evaluable": [e["seed"] for e in mb[a]["evaluable"]],
                          "skipped": [k["seed"] for k in mb[a]["skipped"]]} for a in mb},
            "disk_read_max_mbs": disk_max, "scan_share_of_calls": SCAN_SHARE, "dataset_mib": DATASET_MIB,
            "sbx_core_s_per_call_n8": m_c_sbx,
            "resident_footprint_n8_median_mib": m_fp_med, "resident_footprint_n8_max_mib": m_fp_max,
            "resident_usable_mib_n8": m_usable,
            "smoke": {k: {kk: v.get(kk) for kk in ("holds", "holds_abs", "binding", "p95_excess_ms",
                                                    "excess_limit_ms", "median_class_pace", "failed",
                                                    "vm_mem_end_median_mib", "vm_mem_end_max_mib",
                                                    "disk_read_mbs_mean", "disk_read_mbs_p95",
                                                    "disk_await_ms_mean", "mem_available_min_mib",
                                                    "page_cache_max_mib", "host_cpu_busy_mean")}
                      for k, v in mr.items()},
        },
        "held_t300_pct_default": rep["table"]["held_t300_pct"],
        "host_vcpu": HOST_VCPU, "floor_mib": 1536, "headroom_mib": 1024,
        "p95_factor": factor, "abs_added_ms": abs_ms, "excess_floor_ms": floor_ms,
        "lifecycle_bench": lc,
    }

    f = lambda x: "%.4g" % x  # noqa: E731
    preds = [
        {"id": 1,
         "claim": "SBX is bound by CPU. Resident ∞ is bound by memory.",
         "metric": "record.json `binding` and the failed §8 condition at each arm's first failed default-point rung "
                   "(SBX: host CPU busy ≥ 90% or pace/latency failing with MemAvailable well above the floor; "
                   "resident ∞: memory_floor, a host-memory/memory-budget refusal or an OOM kill)",
         "falsifiedBy": "SBX's first failed rung bound by memory (memory_floor, host-memory refusal or OOM), or "
                        "resident ∞'s first failed rung failing on pace/latency with binding=cpu while MemAvailable "
                        "stays above floor + 1 GiB",
         "note": ("Direction fixed by SPEC §11. Calibration: SBX at N=8 uses %s core-s per call; resident VMs grow "
                  "to a median %s MiB (max %s) at N=8. CALIBRATION CONCERN, recorded before measurement: resident "
                  "∞'s CPU bound (N ≈ [%s, %s]) is below its memory bound (N ≈ [%s, %s]), so calibration expects "
                  "resident ∞ to be CPU-bound too; the resident half of this prediction is expected to be "
                  "falsified.") % (f(c), f(fp_med), f(fp_max), f(n_res_cpu_lo), f(n_res_cpu_hi),
                                    f(n_res_mem_lo), f(n_res_mem_hi))},
        {"id": 2,
         "claim": "SBX holds more sessions than resident ∞ at the default point. Predicted ranges: SBX N_max in "
                  "[%d, %d]; resident ∞ N_max in [%d, %d]." % (sbx_rng[0], sbx_rng[1], res_rng[0], res_rng[1]),
         "metric": "ladder.json n_max (SPEC §8, class-matched condition 4, primary rule) per arm, default point",
         "falsifiedBy": "n_max(SBX) ≤ n_max(resident ∞); separately, either arm's n_max outside its range "
                        "falsifies the numeric part",
         "note": ("SBX: cores/session = c × r = %s core-s/call × %s calls/s = %s cores; usable = 4 vCPU × "
                  "[0.80, 0.90] = [%s, %s]; N = [%s, %s] → ladder [%d, %d]. Resident ∞: memory: usable = "
                  "MemAvailable at t0 %s MiB − 1536 floor − 1024 headroom = %s MiB, N_mem = usable / footprint ∈ "
                  "[%s / %s max, %s / %s median] = [%s, %s]; CPU: its own measured %s core-s/call × %s calls/s, "
                  "N_cpu = [%s, %s]; N = min(N_mem, N_cpu) = [%s, %s] → ladder [%d, %d]. CALIBRATION CONCERN, "
                  "recorded before measurement: the two ranges overlap -- both arms meet the same CPU wall within "
                  "%s core-s/call of each other (SBX − resident at N=8; direct lifecycle bench %s core-s/Exec), "
                  "and resident ∞'s memory bound is not the tighter one. The direction is SPEC §11's and is not "
                  "changed; calibration suggests it may be falsified or tie.")
                 % (f(c), f(r), f(cps), f(lo_c), f(hi_c), f(n_sbx_lo), f(n_sbx_hi), sbx_rng[0], sbx_rng[1],
                    f(ra["mem_available_at_start_mib"]), f(usable), f(usable), f(fp_max), f(usable), f(fp_med),
                    f(n_res_mem_lo), f(n_res_mem_hi), f(c_res), f(r), f(n_res_cpu_lo), f(n_res_cpu_hi),
                    f(n_res_lo), f(n_res_hi), res_rng[0], res_rng[1], f(lc_diff), f(lc_direct))},
        {"id": 3,
         "claim": "Resident 300 s comes within one ladder step of SBX, in either direction. Predicted range: "
                  "resident 300 s N_max in [%d, %d]." % (r300_rng[0], r300_rng[1]),
         "metric": "ladder.json n_max, resident 300 s vs SBX, default point; ladder index difference",
         "falsifiedBy": "|ladder index(n_max resident 300) − ladder index(n_max SBX)| > 1",
         "note": ("Memory: usable / (median footprint × held share) = %s / (%s × %s) = %s. CPU: the resident "
                  "per-call CPU measured at N=8 (%s core-s/call; resident 300 s runs the same commands on a "
                  "resident VM), N = [%s, %s]. N = min(memory, CPU) = [%s, %s] → ladder [%d, %d]. Cold wakes "
                  "(2.3/session-hour) are not costed; each costs about one lifecycle (direct bench %s core-s), so "
                  "they lower the CPU bound by well under 1%%.")
                 % (f(usable), f(fp_med), f(held300), f(n300_mem), f(c_res), f(n300_cpu_lo), f(n300_cpu_hi),
                    f(n300_lo), f(n300_hi), r300_rng[0], r300_rng[1], f(lc_direct))},
        {"id": 4,
         "claim": "Longer gaps help SBX and resident 300 s, not resident ∞. At H = 7200 s, SBX's and resident "
                  "300 s's N_max rise; resident ∞ stays within one ladder step of its default.",
         "metric": "ladder.json n_max at the long point vs the default point, per arm",
         "falsifiedBy": "SBX or resident 300 s n_max at H=7200 not above its default n_max, or resident ∞ moving "
                        "more than one ladder step",
         "note": ("SBX scales with 1/r: r(7200) = %s vs r(1800) = %s calls/s/session, so N_cpu ≈ [%s, %s] → "
                  "ladder [%d, %d] at the same per-call cost. Resident ∞ holds one VM per session whatever the "
                  "gaps, so its memory bound (≈ [%s, %s]) does not move. CALIBRATION CONCERN, recorded before "
                  "measurement: resident ∞ is expected to be CPU-bound here (see 1-2), and its CPU bound also "
                  "scales with 1/r, ≈ [%s, %s] → ladder [%d, %d] at H = 7200 s, so the 'resident ∞ stays within "
                  "one step' half is expected to be falsified unless memory binds first.")
                 % (f(r_long), f(r), f(n_sbx_long_lo), f(n_sbx_long_hi), L(n_sbx_long_lo), L(n_sbx_long_hi),
                    f(n_res_mem_lo), f(n_res_mem_hi), f(lo_c / (c_res * r_long)), f(hi_c / (c_res * r_long)),
                    L(min(n_res_mem_lo, lo_c / (c_res * r_long))), L(min(n_res_mem_hi, hi_c / (c_res * r_long))))},
        {"id": 5,
         "claim": "Removing host-infrastructure sessions and chains moves both arms the same way. Neither point "
                  "reverses the default result.",
         "metric": "sign of n_max(SBX) − n_max(resident ∞) at the no-infra and no-chains points vs the default",
         "falsifiedBy": "the sign at no-infra or no-chains opposite to the default point's",
         "note": "Direction fixed by SPEC §11; no numeric range (the points start two steps below each default "
                 "N_max)."},
        {"id": 6,
         "claim": "The driver uses less than 1% of host CPU at every N (A2).",
         "metric": "record.json driver.a2_pct_of_host on every rung",
         "falsifiedBy": "any rung with a2_pct_of_host ≥ 1.0",
         "note": "Calibration: control N=128 a2_pct_of_host = %s%%." % f(ctl["driver"]["a2_pct_of_host"])},
        {"id": 7,
         "notAPrediction": True,
         "claim": "METHOD, NOT A PREDICTION: the two verdicts reported per arm and point, fixed before "
                  "measurement.",
         "metric": "ladder.json n_max (PRIMARY) and n_max_abs",
         "falsifiedBy": "n/a (a method, not a claim)",
         "note": ("Both verdicts use SPEC §8 conditions 1-2 unchanged, a class-matched pace condition "
                  "(a session's expected time = the driver's schedule re-simulated over its window calls with each "
                  "call's duration lengthened by its class's N=1 probe median added latency M[class], each send "
                  "at max(previous send + the call's recorded offset, previous end), offsets joined from the "
                  "corpus by trace and call index -- a join miss refuses the rung; class pace = observed / "
                  "expected − 1; condition 3 = median class pace ≤ 0.10; the N=1 rung skips it and reports its "
                  "raw median pace) and a class-matched condition 4. A call's "
                  "excess = its added latency − M[class], M = the median added latency of its class in the arm's "
                  "per-class N=1 probe (each class alone on an idle worker, 20 calls drawn from the class's "
                  "corpus distribution; baseline.json class_medians). B = the probe's own within-class excess "
                  "p95. n_max (PRIMARY): the largest ladder N that holds, every smaller rung holding, with "
                  "condition 4 = p95(excess) ≤ max(%g × B, %g ms). n_max_abs (secondary): the same, with "
                  "condition 4 = p95(excess) ≤ B + %g ms. The ladder climbs while either is unbroken and stops "
                  "at the first rung where both fail. Per arm (B; primary limit; absolute limit; N=1 per-call "
                  "overhead, information only): %s. Predictions 2-4 and 8 are stated against n_max.")
                 % (factor, floor_ms, abs_ms, "; ".join(
                     "%s B %s ms, limit %s ms, abs limit %s ms, overhead %s ms" % (
                         a, f(b[a]["excess_p95_ms"]), f(max(factor * b[a]["excess_p95_ms"], floor_ms)),
                         f(b[a]["excess_p95_ms"] + abs_ms), f(b[a].get("overhead_ms")))
                     for a in ARMS))},
        {"id": 8,
         "claim": "The metal rig shows the largest SBX gain: on the metal run, SBX's N_max ÷ resident ∞'s N_max is "
                  "larger than on this nested instance.",
         "metric": "n_max(SBX) / n_max(resident ∞) at the default point, metal run (SPEC §13) vs this preliminary "
                   "run",
         "falsifiedBy": "a metal ratio no larger than the preliminary one",
         "note": ("Added by user decision after calibration, before the first measured rung. The metal run is on an "
                  "AWS m7i.metal-24xl (SPEC §13; no nesting, 96 vCPU, EBS-only). Basis: SPEC §4 -- "
                  "nesting raises SBX's per-Exec lifecycle cost (E10: resume 2.74×, destroy 5.56×) while the "
                  "resident arm pays it once per session. Here the SBX lifecycle cost per "
                  "call: direct no-op bench %s core-s per Exec; SBX − resident ∞ per-call CPU at N=8 = %s core-s.") % (f(lc_direct), f(lc_diff))},
        {"id": 9,
         "claim": "At mem512, resident ∞ is bound by memory and SBX holds more sessions than resident ∞. "
                  "Predicted ranges: resident ∞ N_max in [%d, %d]; SBX N_max in [%d, %d]."
                  % (L(m_res_lo), L(m_res_hi), L(m_sbx_lo), L(m_sbx_hi)),
         "metric": "ladder.json n_max (primary) per arm at the mem512 point; record.json binding of each arm's "
                   "first failed mem512 rung (with e15.slice memory.events high/oom for resident ∞)",
         "falsifiedBy": "resident ∞'s first failed mem512 rung not bound by memory (neither memory_floor, a "
                        "memory-watchdog abort, nor e15.slice MemoryHigh throttling with Exec timeouts), or "
                        "n_max(SBX) ≤ n_max(resident ∞) at mem512",
         "note": ("Resident ∞: a VM keeps data.bin in its guest page cache, so it grows to near its 1024 MiB guest "
                  "RAM: at N=8 the median VM is %s MiB (max %s). usable = MemAvailable at t0 %s − 1536 floor − "
                  "1024 headroom = %s MiB; N = usable / footprint ∈ [%s, %s] → ladder [%d, %d]. Calibration "
                  "smoke: N=8 holds (p95 excess %s ≤ %s ms); N=32 (with the 617ebb7 guards) does not: e15.slice "
                  "was throttled at MemoryHigh (memory.events high 265,316), MemAvailable min %s MiB at t = %s s "
                  "(above the 1024 MiB watchdog floor, so no abort), VMs stalled "
                  "into Exec timeouts -- the slice limit contained it (no global OOM), so record.py reads binding "
                  "'%s', not memory_floor; this prediction counts MemoryHigh throttling as memory-bound. "
                  "SBX: CPU %s core-s/call × %s calls/s → N_cpu = [%s, %s]. Disk: each SBX call of a scanning "
                  "class (%.0f%% of calls) reads the %d MiB dataset afresh, = %s MiB/s per session; the host page "
                  "cache serves those reads while the working set fits (per-inode cache: each session's data.bin "
                  "is a distinct inode in its own workspace image, so caching does not share across sessions; "
                  "about %s GiB cache / %d MiB ≈ %s sessions), and past that the volume does (disk_read_max %s "
                  "MB/s ÷ %s MiB/s ≈ %s sessions). N_sbx = min(N_cpu, max(N_disk, N_cache)) = [%s, %s] → ladder "
                  "[%d, %d]. Smoke: N=8 fails condition 4 narrowly (p95 excess %s > %s ms, a tail of ~7 of 135 "
                  "calls; disk %s MB/s mean); N=32 is disk-bound (%s MB/s mean, await %s ms). CALIBRATION CONCERN, "
                  "recorded before measurement: SBX's N=8 smoke did not hold, so n_max(SBX) may be 1 and the "
                  "comparison may be a tie or reversed. Per-VM memory at mem512 includes host page cache for "
                  "workspace.img (charged to the VM cgroup) and is not comparable with the default point's 74 MiB.")
                 % (f(m_fp_med), f(m_fp_max), f(ms_res["mem_available_at_start_mib"]), f(m_usable),
                    f(m_res_lo), f(m_res_hi), L(m_res_lo), L(m_res_hi),
                    f(mr["resident-inf-N8"]["p95_excess_ms"]), f(mr["resident-inf-N8"]["excess_limit_ms"]),
                    f(guard_min["mem_available_min_mib"]), f(guard_min["t"]), mr["resident-inf-N32-guard"]["binding"],
                    f(m_c_sbx), f(r), f(m_sbx_cpu_lo), f(m_sbx_cpu_hi),
                    100 * SCAN_SHARE, DATASET_MIB, f(read_mib_s), f(page_cache_mib / 1024), DATASET_MIB,
                    f(m_sbx_cache_n), f(disk_max), f(read_mib_s), f(m_sbx_disk), f(m_sbx_lo), f(m_sbx_hi),
                    L(m_sbx_lo), L(m_sbx_hi), f(mr["sbx-N8"]["p95_excess_ms"]), f(mr["sbx-N8"]["excess_limit_ms"]),
                    f(mr["sbx-N8"]["disk_read_mbs_mean"]), f(mr["sbx-N32"]["disk_read_mbs_mean"]),
                    f(mr["sbx-N32"]["disk_await_ms_mean"]))},
    ]
    doc = {
        "spec": spec_version(),
        "section": "11",
        "recordedAt": "2026-11-04",
        "note": "Written after calibration (SPEC §10.1) and BEFORE the first measured ladder rung. Directions 1-6 are "
                "SPEC §11's, 8 is the user's; numeric ranges are computed from the calibration object below (arithmetic in each "
                "note). Entry 7 is not a prediction: it records both verdict rules before measurement.",
        "codeCommit": commit,
        "replayFixCommit": "6f344a8",
        "calibration": cal_obj,
        "predictions": preds,
    }
    with open(out, "w") as fh:
        json.dump(doc, fh, indent=2, ensure_ascii=False)
        fh.write("\n")


if __name__ == "__main__":
    main(*sys.argv[1:4])
