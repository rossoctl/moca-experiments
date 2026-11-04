"""Write the DRAFT e15/predictions-metal.json from the metal calibration (SPEC §11, §13).

  python3 make_predictions_metal.py METAL_DIR PRELIM_PREDICTIONS OUT_JSON CODE_COMMIT

METAL_DIR (e15/results/metal) holds:
  baseline/<point>/<arm>/N1/baseline.json            pooled N=1 baselines (baseline.sh)
  rungs/default-control-N128-cal/record.json         A2
  rungs/<point>-<arm>-N8-cal/{record,analysis}.json  the N=8 calibration rungs (calib_analyze.py)
  rungs/default-resident-inf-N8-cal-repeat/          the warm-up-1200 resident repeat (if present)
  lifecycle/summary.json                             the no-op lifecycle bench
  burst-model/summary.json                           burst_model.py fit (AWS) and metal grid
  state-disk_read_max_mbs.txt                        setup's 4-stream direct read (MB/s)
PRELIM_PREDICTIONS is the sealed e15/predictions.json (format, corpus rates, scan share).

Ranges, per the coordinator's ruling (2026-11-04):
  RECOMMENDED: the burst-aware model (burst_model.py). It is a processor-sharing replay of the
    default corpus; each call's CPU demand comes from the library cpu/run ratio, scaled to the
    measured core-s per call; the 1-vCPU guests share V_eff = eff x vCPU cores; the p95 of added
    latency is judged against the arm's primary limit max(3B, 50 ms). Its one free parameter, eff,
    is fitted on the preliminary records (default and long: all arms hold N=8, fail N=16; short: sbx
    and resident-inf fail N=8; no-infra: sbx fails N=8). No single eff explains all 11 outcomes; the
    range of best-matching eff (9 of 11) is used, applied to 96 vCPU.
  PESSIMISTIC: the average-CPU bound (96 vCPU x [0.80, 0.90] / (c x r)) times the preliminary
    over-prediction factor 8 / (4 vCPU x [0.80, 0.90] / (c_aws x r)).
  INFORMATION: the plain average-CPU bound.
Every N is rounded down onto the fresh-metal ladder (lib.sh E15_LADDER, e964dd0). DRAFT only.
"""
import json
import os
import sys

LADDER = [1, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 128, 160, 192, 256, 320, 384, 448, 512, 576, 640, 704,
          768, 896, 1024]
HOST_VCPU = 96
FLOOR_MIB, HEADROOM_MIB = 1536, 1024
AWS_N_MAX = {"sbx": 8, "resident-inf": 8, "resident-300": 8}       # Task 9 default, primary
AWS_N_MAX_ABS = {"sbx": 1, "resident-inf": 8, "resident-300": 8}   # Task 9 default, absolute


def L(n):
    below = [x for x in LADDER if x <= n]
    return below[-1] if below else 0


def load(p):
    with open(p) as f:
        return json.load(f)


def f(x):
    return "n/a" if x is None else "%.4g" % x


def main(md, prelim_p, out, commit):
    pre = load(prelim_p)
    pc = pre["calibration"]
    P = {p["id"]: p for p in pre["predictions"]}
    r = pc["corpus_calls_per_s_per_session"]["default"]
    r_long = pc["corpus_calls_per_s_per_session"]["long"]
    held300 = pc["held_t300_pct_default"] / 100.0
    scan_share = pc["mem512"]["scan_share_of_calls"]
    dataset = pc["mem512"]["dataset_mib"]
    factor, abs_ms, floor_ms = pc["p95_factor"], pc["abs_added_ms"], pc["excess_floor_ms"]
    c_aws = {"sbx": pc["sbx_n8"]["core_s_per_call"], "resident-inf": pc["resident_inf_n8"]["core_s_per_call"]}

    def bl(point, arm):
        return load(os.path.join(md, "baseline", point, arm, "N1", "baseline.json"))

    def rung(name):
        d = os.path.join(md, "rungs", name)
        if not os.path.isdir(d):
            return None, None
        return load(os.path.join(d, "record.json")), load(os.path.join(d, "analysis.json"))

    ARMS = ("sbx", "resident-inf", "resident-300")
    b = {a: bl("default", a) for a in ARMS}
    mb = {a: bl("mem512", a) for a in ("sbx", "resident-inf")}
    ctl = load(os.path.join(md, "rungs", "default-control-N128-cal", "record.json"))
    srec, sa = rung("default-sbx-N8-cal")
    rrec, ra = rung("default-resident-inf-N8-cal")
    rprec, rpa = rung("default-resident-inf-N8-cal-repeat")
    rsum = os.path.join(md, "rungs", "default-resident-inf-N8-cal", "record.rejudged-sum-07ab661.json")
    rrec_sum = load(rsum) if os.path.exists(rsum) else None
    msrec, msa = rung("mem512-sbx-N8-cal")
    mrrec, mra = rung("mem512-resident-inf-N8-cal")
    lc = load(os.path.join(md, "lifecycle", "summary.json"))
    bm = load(os.path.join(md, "burst-model", "summary.json"))
    disk_max = float(open(os.path.join(md, "state-disk_read_max_mbs.txt")).read().split()[0])

    def lim(bb):
        return max(factor * bb["excess_p95_ms"], floor_ms), bb["excess_p95_ms"] + abs_ms

    lo_c, hi_c = HOST_VCPU * 0.80, HOST_VCPU * 0.90
    c = {"sbx": sa["core_s_per_call"], "resident-inf": ra["core_s_per_call"]}
    avg = {a: (lo_c / (c[a] * r), hi_c / (c[a] * r)) for a in c}
    aws_avg = {a: (4 * 0.80 / (c_aws[a] * r), 4 * 0.90 / (c_aws[a] * r)) for a in c_aws}
    fac = {a: (8 / aws_avg[a][1], 8 / aws_avg[a][0]) for a in c_aws}
    pess = {a: (avg[a][0] * fac[a][0], avg[a][1] * fac[a][1]) for a in c}
    burst = {"sbx": bm["metal_n_max_range_at_fitted_eff"]["SBX"],
             "resident-inf": bm["metal_n_max_range_at_fitted_eff"]["RES"]}
    eff = bm["fitted_eff_range"]

    # footprint: the later (warm-up 1200) resident rung when present, else the 600 s one
    fpa = rpa or ra
    fp_med, fp_max, usable = fpa["footprint_median_mib"], fpa["footprint_max_mib"], fpa["usable_mib"]
    n_res_mem = (usable / fp_max, usable / fp_med)
    n300_mem = usable / (fp_med * held300)

    # resident 300 s: the resident per-call CPU (same commands, same VM type); the burst model's resident
    # range applies; memory is far above it. Cold wakes add ~1 lifecycle per wake (2.3/session-h).
    res_rng = [L(x) for x in burst["resident-inf"]]
    res_rng = [min(res_rng[0], L(n_res_mem[0])), min(res_rng[1], L(n_res_mem[1]))]
    sbx_rng = burst["sbx"]
    r300_rng = [min(res_rng[0], L(n300_mem)), min(res_rng[1], L(n300_mem))]
    ratio_rng = (sbx_rng[0] / float(res_rng[1]), sbx_rng[1] / float(res_rng[0]))
    aws_ratio = AWS_N_MAX["sbx"] / float(AWS_N_MAX["resident-inf"])
    aws_ratio_abs = AWS_N_MAX_ABS["sbx"] / float(AWS_N_MAX_ABS["resident-inf"])

    # long gaps: CPU per session scales with r; the burst bound scales ~1/r too (same per-call mix)
    long_scale = r / r_long
    sbx_long = [L(x * long_scale) for x in sbx_rng]
    res_long_cpu = [L(x * long_scale) for x in burst["resident-inf"]]
    res_long = [min(res_long_cpu[0], L(n_res_mem[0])), min(res_long_cpu[1], L(n_res_mem[1]))]

    # mem512
    m = {}
    if msa and mra:
        m_fp_med, m_fp_max, m_usable = mra["footprint_median_mib"], mra["footprint_max_mib"], mra["usable_mib"]
        m_res = (m_usable / m_fp_max, m_usable / m_fp_med)
        m_c = msa["core_s_per_call"]
        m_scale = c["sbx"] / m_c                      # mem512 SBX costs m_c per call: bound shrinks
        m_sbx_cpu = [L(x * m_scale) for x in sbx_rng]
        read_mib_s = dataset * scan_share * r       # MiB/s per SBX session once its dataset is uncached
        m_sbx_disk = disk_max * 1e6 / (1 << 20) / read_mib_s
        m_cache_mib = msa.get("usable_mib") or (fpa["mem_available_at_start_mib"] - FLOOR_MIB - HEADROOM_MIB)
        if not msa.get("usable_mib"):
            m_cache_mib = fpa["mem_available_at_start_mib"] - FLOOR_MIB - HEADROOM_MIB
        m_sbx_cache = m_cache_mib / dataset         # per-inode page cache: one dataset per session
        m_sbx_io = max(m_sbx_disk, m_sbx_cache)
        m_sbx_cap = [min(m_sbx_cpu[0], L(m_sbx_io)), min(m_sbx_cpu[1], L(m_sbx_io))]
        m_sbx_bind = "CPU (burst)" if m_sbx_cpu[1] <= L(m_sbx_io) else "page cache, then disk"
        # the measured N=8 rung decides when it fails: the cold-first-scan tail (see note) is not a
        # capacity effect, so the capacity bound is information and n_max is 1
        m_sbx = m_sbx_cap if msrec["holds"] else [1, 1]
        m_res_rng = [L(m_res[0]), L(m_res[1])]
        m.update(m_fp_med=m_fp_med, m_fp_max=m_fp_max, m_usable=m_usable, m_res=m_res, m_c=m_c,
                 m_sbx_cpu=m_sbx_cpu, read_mib_s=read_mib_s, m_sbx_disk=m_sbx_disk, m_cache_mib=m_cache_mib,
                 m_sbx_cache=m_sbx_cache, m_sbx=m_sbx, m_sbx_cap=m_sbx_cap, m_sbx_bind=m_sbx_bind,
                 m_res_rng=m_res_rng)

    caps = [
        {"cap": "SH_MAX_RUNS (unparked runs)", "value": 2048, "binds_at_n": {"resident-inf": 2048, "sbx": "~4500 (0.45 unparked runs/session at N=8)"},
         "note": "d80c1c7; 512 would bind resident-inf at N=512"},
        {"cap": "WORKER_MAX_CONCURRENT (dispatch goroutines) + QueueCap 64", "value": 256,
         "binds_at_n": "concurrent Execs > 320 ('busy: queue full'); 0.09 Execs in flight per session at N=8 → ~3500 at the measured mix; reached only in CPU collapse"},
        {"cap": "SH_MAX_COMMITTED_MB", "value": 1048576, "binds_at_n": {"resident-inf": 992, "sbx": "~1100 (0.9 VMs/session incl. standbys)"},
         "note": "1056 MiB charged per running VM (1024 guest + 32 overhead)"},
        {"cap": "host memory (resident footprint)", "binds_at_n": {"resident-inf default": int(n_res_mem[0]), "resident-inf mem512": int(m["m_res"][0]) if m else None}},
        {"cap": "disk free (N x K=16 per-session deltas + 10%)", "value": "289.5 GiB free",
         "binds_at_n": {"default": 753, "mem512": 434}, "note": "rung.sh refuses the rung; 22 MiB / 38 MiB delta"},
        {"cap": "EBS read 1017 MB/s (mem512, uncached datasets)", "binds_at_n": {"sbx mem512": int(m["m_sbx_disk"]) if m else None},
         "note": "only after the per-session datasets exceed page cache"},
        {"cap": "relay SH_SANDBOX_MAX_INFLIGHT", "value": 1024, "binds_at_n": "concurrent Execs > 1024"},
        {"cap": "relay CPU (one Node thread)", "binds_at_n": "~4900 (0.0116 core-s/call at N=8)"},
        {"cap": "driver, fds, pids", "binds_at_n": "none below 1024 (NOFILE 1048576, pid_max 4M, TasksMax infinity; A2 0.0016% at N=128)"},
        {"cap": "ladder top", "value": 1024, "binds_at_n": 1024},
    ]

    cal = {
        "host": "AWS m7i.metal-24xl, bare metal, 96 vCPU (48C x 2T), 377 GiB, EBS gp3 data volume XFS reflink=1 at /srv/e15",
        "library_sha256": srec.get("library_sha256"),
        "library_note": "metal-measured e15/results/metal/library.json (invocations as 7c2bdc4b; run_ms/cpu_ms are metal in-guest medians of 5)",
        "driver_bin_sha256": srec.get("driver_bin_sha256"),
        "corpus_sha256_default": srec.get("corpus_sha256"),
        "snapshot_hash": srec.get("snapshot_hash"),
        "baseline_excess_p95_ms": {a: b[a]["excess_p95_ms"] for a in ARMS},
        "n1_overhead_ms": {a: b[a].get("overhead_ms") for a in ARMS},
        "n1_median_pace": {a: b[a].get("n1_median_pace") for a in ARMS},
        "class_medians_ms": {a: b[a].get("class_medians") for a in ARMS},
        "excess_limit_ms": {a: lim(b[a])[0] for a in ARMS},
        "excess_limit_abs_ms": {a: lim(b[a])[1] for a in ARMS},
        "baseline_seeds": {a: {"evaluable": [e["seed"] for e in b[a]["evaluable"]],
                               "skipped": [k["seed"] for k in b[a]["skipped"]]} for a in ARMS},
        "undercovered": {a: b[a].get("undercovered") for a in ARMS},
        "probe_failed": {a: b[a].get("probe_failed") for a in ARMS},
        "a2_control_n128_pct_of_host": ctl["driver"]["a2_pct_of_host"],
        "lifecycle_bench": lc,
        "sbx_n8": {"holds": srec["holds"], "holds_abs": srec.get("holds_abs"), "p95_excess_ms": srec.get("p95_excess_ms"),
                   "core_s_per_call": c["sbx"], "calls_in_window": sa["in_window_calls"],
                   "phase_median_ms": sa["phase_median_ms"], "host_cpu_busy_pct_mean": sa["host_cpu_busy_pct_mean"],
                   "sbx_minus_resident_core_s_per_call": c["sbx"] - c["resident-inf"]},
        "resident_inf_n8": {"holds": rrec["holds"], "holds_abs": rrec.get("holds_abs"), "p95_excess_ms": rrec.get("p95_excess_ms"),
                            "footprint_median_mib": ra["footprint_median_mib"], "footprint_max_mib": ra["footprint_max_mib"],
                            "footprint_drift_median_pct": rrec.get("footprint_drift_pct"),
                            "footprint_drift_sum_pct": rrec_sum and rrec_sum.get("footprint_drift_sum_pct"),
                            "repeat_required_median_basis": rrec.get("repeat_required"),
                            "repeat_required_sum_basis": rrec_sum and rrec_sum.get("repeat_required"),
                            "vm_mem_window_end_mib": ra.get("vm_mem_window_end_mib"),
                            "mem_available_at_start_mib": ra["mem_available_at_start_mib"], "usable_mib": ra["usable_mib"],
                            "core_s_per_call": c["resident-inf"]},
        "resident_inf_n8_warmup1200": None if not rpa else {
            "holds": rprec["holds"], "holds_abs": rprec.get("holds_abs"), "p95_excess_ms": rprec.get("p95_excess_ms"),
            "footprint_median_mib": rpa["footprint_median_mib"], "footprint_max_mib": rpa["footprint_max_mib"],
            "footprint_drift_basis": rprec.get("footprint_drift_basis"),
            "footprint_drift_sum_pct": rprec.get("footprint_drift_sum_pct"),
            "footprint_drift_median_pct": rprec.get("footprint_drift_median_pct"),
            "repeat_required": rprec.get("repeat_required"), "core_s_per_call": rpa["core_s_per_call"]},
        "footprint_used": "warm-up 1200 rung" if rpa else "warm-up 600 rung",
        "corpus_calls_per_s_per_session": {"default": r, "long": r_long},
        "held_t300_pct_default": pc["held_t300_pct_default"],
        "cpu_models": {
            "average_cpu_bound": {a: list(avg[a]) for a in avg},
            "preliminary_overprediction_factor": {a: list(fac[a]) for a in fac},
            "pessimistic_factor_bound": {a: list(pess[a]) for a in pess},
            "burst_model": {"fitted_eff_range": eff, "aws_consistent_eff": bm["aws_consistent_eff"],
                            "metal_n_max_ladder": burst, "limits_ms": bm["limits_ms"],
                            "script": "e15/results/metal/burst_model.py"},
        },
        "caps": caps,
        "mem512": {} if not m else {
            "baseline_excess_p95_ms": {a: mb[a]["excess_p95_ms"] for a in mb},
            "n1_overhead_ms": {a: mb[a].get("overhead_ms") for a in mb},
            "n1_median_pace": {a: mb[a].get("n1_median_pace") for a in mb},
            "class_medians_ms": {a: mb[a]["class_medians"] for a in mb},
            "excess_limit_ms": {a: lim(mb[a])[0] for a in mb},
            "excess_limit_abs_ms": {a: lim(mb[a])[1] for a in mb},
            "seeds": {a: {"evaluable": [e["seed"] for e in mb[a]["evaluable"]],
                          "skipped": [k["seed"] for k in mb[a]["skipped"]]} for a in mb},
            "disk_read_max_mbs": disk_max, "scan_share_of_calls": scan_share, "dataset_mib": dataset,
            "sbx_n8": {"holds": msrec["holds"], "holds_abs": msrec.get("holds_abs"),
                       "p95_excess_ms": msrec.get("p95_excess_ms"), "excess_limit_ms": msrec.get("excess_limit_ms"),
                       "p95_limit_abs_ms": msrec.get("p95_limit_abs_ms"), "core_s_per_call": m["m_c"],
                       "phase_median_ms": msa.get("phase_median_ms"),
                       "capacity_bound_ladder": m["m_sbx_cap"], "capacity_binding": m["m_sbx_bind"],
                       "tail_mechanism": "cold first scan per new session: ~2.5 s added (EBS read of a fresh 512 MiB data.bin) vs ~0.5 s warm",
                       "disk_read_mean_mbs": msrec.get("disk_read_mean_mbs")},
            "resident_inf_n8": {"holds": mrrec["holds"], "holds_abs": mrrec.get("holds_abs"),
                                "p95_excess_ms": mrrec.get("p95_excess_ms"),
                                "footprint_median_mib": m["m_fp_med"], "footprint_max_mib": m["m_fp_max"],
                                "footprint_drift_pct": mrrec.get("footprint_drift_pct"),
                                "usable_mib": m["m_usable"], "core_s_per_call": mra["core_s_per_call"]},
        },
        "host_vcpu": HOST_VCPU, "usable_cpu_fraction": [0.80, 0.90], "floor_mib": FLOOR_MIB, "headroom_mib": HEADROOM_MIB,
        "ladder": LADDER, "p95_factor": factor, "abs_added_ms": abs_ms, "excess_floor_ms": floor_ms,
        "preliminary_n_max": AWS_N_MAX, "preliminary_n_max_abs": AWS_N_MAX_ABS,
    }

    def rng(a):
        return "burst model [%d, %d] (RECOMMENDED; eff %s–%s of 96 vCPU, refitted on the preliminary default, long, short and no-infra outcomes -- no single eff explains all 11, the best match 9 of 11); " \
               "pessimistic factor bound [%s, %s] → ladder [%d, %d]; average-CPU bound [%s, %s] (information)" % (
                   burst[a][0], burst[a][1], f(eff[0]), f(eff[1]), f(pess[a][0]), f(pess[a][1]), L(pess[a][0]),
                   L(pess[a][1]), f(avg[a][0]), f(avg[a][1]))

    n8x = {"sbx": srec.get("p95_excess_ms"), "resident-inf": rrec.get("p95_excess_ms"), "resident-300": None}
    abs_note = "; ".join("%s: N=1 overhead %s ms vs abs limit B + 250 = %s ms%s" % (
        a, f(b[a].get("overhead_ms")), f(lim(b[a])[1]),
        "" if n8x[a] is None else ", N=8 p95 excess %s ms" % f(n8x[a])) for a in ARMS)

    preds = [
        {"id": 1, "claim": "SBX is bound by CPU. Resident ∞ is bound by memory.",
         "metric": P[1]["metric"], "falsifiedBy": P[1]["falsifiedBy"],
         "note": ("Metal: SBX %s core-s/call, resident ∞ %s core-s/call at N=8; both CPU walls at about N = %d–%d (burst model). "
                  "Resident ∞'s memory bound is %s–%s sessions (usable %s MiB ÷ footprint %s max / %s median MiB), far above "
                  "its CPU wall. CALIBRATION CONCERN, recorded before measurement: calibration expects resident ∞ to be "
                  "CPU-bound on metal too, so the resident half is expected to be falsified at the default point.")
                 % (f(c["sbx"]), f(c["resident-inf"]), min(burst["sbx"][0], burst["resident-inf"][0]),
                    max(burst["sbx"][1], burst["resident-inf"][1]), f(n_res_mem[0]), f(n_res_mem[1]), f(usable),
                    f(fp_max), f(fp_med))},
        {"id": 2, "claim": ("SBX holds more sessions than resident ∞ at the default point. Predicted ranges: SBX N_max in "
                            "[%d, %d]; resident ∞ N_max in [%d, %d].") % (sbx_rng[0], sbx_rng[1], res_rng[0], res_rng[1]),
         "metric": P[2]["metric"], "falsifiedBy": P[2]["falsifiedBy"],
         "note": ("SBX: %s. Resident ∞: %s; memory bound [%s, %s]. CALIBRATION CONCERN, recorded before measurement: the "
                  "ranges coincide -- the arms differ by %s core-s/call (%.1f%%), within the model's resolution, so "
                  "calibration expects a tie within one ladder step; the direction is SPEC §11's and is kept.")
                 % (rng("sbx"), rng("resident-inf"), f(n_res_mem[0]), f(n_res_mem[1]),
                    f(c["sbx"] - c["resident-inf"]), 100 * (c["sbx"] - c["resident-inf"]) / c["resident-inf"])},
        {"id": 3, "claim": ("Resident 300 s comes within one ladder step of SBX, in either direction. Predicted range: "
                            "resident 300 s N_max in [%d, %d].") % (r300_rng[0], r300_rng[1]),
         "metric": P[3]["metric"], "falsifiedBy": P[3]["falsifiedBy"],
         "note": ("CPU: the resident per-call CPU and the burst model's resident range [%d, %d]; cold wakes (2.3/session-h) "
                  "cost about one lifecycle each (%s core-s, metal bench), under 0.1%% of the per-session CPU. Memory: "
                  "%s ÷ (%s × %s) = %s sessions, not binding.")
                 % (res_rng[0], res_rng[1], f(lc["core_s_per_exec"]), f(usable), f(fp_med), f(held300), f(n300_mem))},
        {"id": 4, "claim": P[4]["claim"], "metric": P[4]["metric"], "falsifiedBy": P[4]["falsifiedBy"],
         "note": ("NOT RUN ON METAL (SPEC §13 metal procedure: default and mem512 only); carried for completeness. "
                  "Estimate: r(7200)/r(1800) = %s, so SBX ≈ ladder [%d, %d]; resident ∞ CPU-bound ≈ [%d, %d] -- the "
                  "'resident ∞ stays' half would be falsified.")
                 % (f(1 / long_scale), sbx_long[0], sbx_long[1], res_long[0], res_long[1])},
        {"id": 5, "claim": P[5]["claim"], "metric": P[5]["metric"], "falsifiedBy": P[5]["falsifiedBy"],
         "note": "NOT RUN ON METAL (SPEC §13 metal procedure: default and mem512 only); carried for completeness."},
        {"id": 6, "claim": P[6]["claim"], "metric": P[6]["metric"], "falsifiedBy": P[6]["falsifiedBy"],
         "note": "Metal calibration: control N=128 a2_pct_of_host = %s%% (96 vCPU)." % f(ctl["driver"]["a2_pct_of_host"])},
        {"id": 7, "notAPrediction": True, "claim": P[7]["claim"], "metric": P[7]["metric"],
         "falsifiedBy": "n/a (a method, not a claim)",
         "note": ("The preliminary method, unchanged, plus the metal procedure (SPEC §13: ladder to 1024, resident "
                  "warm-up 1200 s, footprint drift on summed VM memory, SH_MAX_RUNS 2048). Metal per-arm values "
                  "(B; primary limit; absolute limit; N=1 overhead): %s. ABSOLUTE-TEST EXPECTATION: %s -- unlike the "
                  "preliminary run (SBX N=1 overhead +186 ms against an abs limit of 479 ms; SBX n_max_abs 1), SBX's "
                  "overhead on metal is small beside B + 250, so n_max_abs is expected to track n_max for every arm.")
                 % ("; ".join("%s B %s ms, limit %s, abs %s, overhead %s ms" % (a, f(b[a]["excess_p95_ms"]), f(lim(b[a])[0]),
                                                                             f(lim(b[a])[1]), f(b[a].get("overhead_ms")))
                              for a in ARMS), abs_note)},
        {"id": 8,
         "claim": ("The m7i.metal-24xl run shows the largest SBX gain: n_max(SBX) / n_max(resident ∞) at the default point "
                   "on metal is larger than on the preliminary nested instance, where it was %s (8 / 8, primary)."
                   % f(aws_ratio)),
         "metric": "n_max(SBX) / n_max(resident ∞), default point, primary verdict; metal vs preliminary",
         "falsifiedBy": "a metal ratio ≤ %s (the preliminary primary ratio)" % f(aws_ratio),
         "threshold": aws_ratio, "threshold_abs": aws_ratio_abs,
         "note": ("Preliminary default n_max: SBX 8, resident ∞ 8, resident 300 s 8 (primary); absolute SBX 1, resident ∞ 8 "
                  "(ratio %s). Draft metal ratio from 2: [%s, %s]. Lifecycle on metal: no-op bench %s core-s/Exec "
                  "(preliminary 0.0991, 3.2×); SBX − resident ∞ per-call CPU at N=8 %s core-s (preliminary 0.218). "
                  "CALIBRATION CONCERN, recorded before measurement: the lifecycle term is now ~%.1f%% of SBX's per-call "
                  "CPU, so both arms meet the same CPU wall and calibration expects a ratio of about 1 -- the primary "
                  "claim (ratio > 1.0) is expected to be falsified or tie; on the absolute verdict the metal ratio is "
                  "expected to rise from 0.125 to about 1.")
                 % (f(aws_ratio_abs), f(ratio_rng[0]), f(ratio_rng[1]), f(lc["core_s_per_exec"]),
                    f(c["sbx"] - c["resident-inf"]), 100 * (c["sbx"] - c["resident-inf"]) / c["sbx"])},
    ]
    if m:
        preds.append({
            "id": 9,
            "claim": ("At mem512, resident ∞ is bound by memory and SBX holds more sessions than resident ∞. Predicted ranges: "
                      "resident ∞ N_max in [%d, %d]; SBX N_max in [%d, %d].") % (m["m_res_rng"][0], m["m_res_rng"][1],
                                                                                m["m_sbx"][0], m["m_sbx"][1]),
            "metric": P[9]["metric"], "falsifiedBy": P[9]["falsifiedBy"],
            "note": ("Resident ∞: footprint at N=8 median %s MiB (max %s), usable %s MiB → N = [%s, %s] → ladder [%d, %d], "
                     "bound by memory (its CPU wall is ~%d). SBX: %s core-s/call at N=8 → CPU (burst model scaled by "
                     "%s/%s) ladder [%d, %d]; page cache: %s MiB ÷ %d MiB = %s sessions (per-inode, no sharing); "
                     "EBS once uncached: %d MiB × %.1f%% × %s calls/s = %s MiB/s per session, %s MB/s ÷ that = %s sessions. "
                     "Capacity bound N_sbx = min(CPU, max(cache, disk)) → ladder [%d, %d] (%s), information only. "
                     "SBX mem512 N=8 calibration rung: holds %s (p95 excess %s ms vs primary %s / abs %s ms; 0 failures; "
                     "host CPU <1%%; disk mean %s MB/s). CALIBRATION CONCERN, recorded before measurement: each new SBX "
                     "session's FIRST scan reads its own fresh 512 MiB data.bin from EBS (~2.5 s added; later scans hit "
                     "the host page cache, ~0.5 s), the class medians absorb only the warm cost, and ~6%% of window "
                     "calls are such cold scans at any N (session starts and window calls both scale with N), so "
                     "calibration expects SBX to fail mem512 at every N > 1: the predicted SBX range is [1, 1], and "
                     "prediction 9's 'SBX holds more' half is expected to be falsified (resident ∞ holds N=8, p95 "
                     "excess %s ms).")
                    % (f(m["m_fp_med"]), f(m["m_fp_max"]), f(m["m_usable"]), f(m["m_res"][0]), f(m["m_res"][1]),
                       m["m_res_rng"][0], m["m_res_rng"][1], burst["resident-inf"][0], f(m["m_c"]), f(c["sbx"]), f(m["m_c"]),
                       m["m_sbx_cpu"][0], m["m_sbx_cpu"][1], f(m["m_cache_mib"]), dataset, f(m["m_sbx_cache"]), dataset,
                       100 * scan_share, f(r), f(m["read_mib_s"]), f(disk_max), f(m["m_sbx_disk"]), m["m_sbx_cap"][0],
                       m["m_sbx_cap"][1], m["m_sbx_bind"], msrec["holds"], f(msrec.get("p95_excess_ms")),
                       f(msrec.get("excess_limit_ms")), f(msrec.get("p95_limit_abs_ms")), f(msrec.get("disk_read_mean_mbs")),
                       f(mrrec.get("p95_excess_ms")))})
    doc = {
        "status": "DRAFT, NOT SEALED",
        "sealed": False,
        "spec": pre["spec"], "section": "11, 13", "recordedAt": None,
        "note": ("DRAFT metal predictions from the metal calibration (SPEC §10.1 on the m7i.metal-24xl) and the preliminary "
                 "n_max. Ranges are the burst-aware model's (recommended), with the factor bound as pessimistic. To be "
                 "reviewed and sealed with the user before the first metal ladder rung."),
        "codeCommit": commit,
        "preliminaryPredictions": "e15/predictions.json (sealed 708d62f)",
        "calibration": cal,
        "predictions": preds,
    }
    with open(out, "w") as fh:
        json.dump(doc, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    print(json.dumps({"sbx": sbx_rng, "resident-inf": res_rng, "resident-300": r300_rng,
                      "pessimistic": {a: [L(x) for x in pess[a]] for a in pess}, "ratio": ratio_rng,
                      "mem512": {k: m[k] for k in ("m_res_rng", "m_sbx", "m_sbx_cap", "m_sbx_bind", "m_sbx_cpu", "m_sbx_cache", "m_sbx_disk")} if m else None}))


if __name__ == "__main__":
    main(*sys.argv[1:5])
