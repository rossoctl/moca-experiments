"""Write e15/results/metal/RESULTS-METAL.md from the pulled metal ladders and the sealed predictions-metal.json.

  python3 results_metal.py E15_DIR

Reads e15/predictions-metal.json (sealed), e15/predictions.json (preliminary, for ratios),
e15/results/metal/<point>/<arm>/ladder.json and rung records, supplementary-1s/climb.json when present.
"""
import glob
import json
import math
import os
import statistics as st
import sys

E = sys.argv[1]
M = os.path.join(E, "results", "metal")
AWS_NMAX = {"sbx": 8, "resident-inf": 8, "resident-300": 8}
AWS_NMAX_ABS = {"sbx": 1, "resident-inf": 8, "resident-300": 8}
LADDER = [1, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 128, 160, 192, 256, 320, 384, 448, 512, 576, 640, 704, 768, 896, 1024]


def load(p):
    with open(p) as f:
        return json.load(f)


def opt(p):
    return load(p) if os.path.exists(p) else None


def q(v, p):
    v = sorted(v)
    return v[max(0, int(math.ceil(p / 100.0 * len(v))) - 1)] if v else None


def rungdir(point, arm, rung):
    return os.path.join(M, point, arm, os.path.basename(rung["dir"]))


def rung_stats(d):
    r = load(os.path.join(d, "record.json"))
    rat = []
    for line in open(os.path.join(d, "calls.jsonl")):
        c = json.loads(line)
        if c.get("in_window") and c.get("status") == "ok":
            pl = c["planned_dur_ms"] - c.get("tail_ms", 0)
            if pl >= 1000:
                rat.append(c["observed_ms"] / pl)
    r1 = opt(os.path.join(d, "record_1s.json"))
    rc = opt(os.path.join(d, "record_cpu.json"))
    return r, rat, r1, rc


def idx(n):
    return LADDER.index(n) if n in LADDER else None


pm = load(os.path.join(E, "predictions-metal.json"))
P = {p["id"]: p for p in pm["predictions"]}
lad = {}
for point, arm in [("default", "sbx"), ("default", "resident-inf"), ("default", "resident-300"),
                   ("mem512", "sbx"), ("mem512", "resident-inf")]:
    lad[(point, arm)] = opt(os.path.join(M, point, arm, "ladder.json"))

out = []
w = out.append
w("# E15 metal run (m7i.metal-24xl): results against the sealed metal predictions\n")
w("Host: AWS m7i.metal-24xl, bare metal, 96 vCPU (48 cores x 2 threads), 377 GiB, EBS gp3 XFS reflink at "
  "/srv/e15. Sealed predictions: `e15/predictions-metal.json` (3d653a2). Procedure as sealed: warm-up 1200 s, "
  "window 900 s, footprint drift on summed VM memory, SH_MAX_RUNS 2048, fresh-metal ladder to 1024. Calibration: "
  "`calibration-summary.md`.\n")
w("## Ladders (sealed verdicts)\n")
w("| point | arm | n_max | n_max_abs | first failed rung | why it failed | host CPU mean at that rung |")
w("|---|---|---|---|---|---|---|")
fails = {}
for (point, arm), L in lad.items():
    if not L:
        w("| %s | %s | (not finished) | | | | |" % (point, arm))
        continue
    stop = L.get("stopped_at")
    why, cpu = "", ""
    if stop is not None:
        rr = [r for r in L["rungs"] if r["n"] == stop][-1]
        d = rungdir(point, arm, rr)
        if os.path.exists(os.path.join(d, "record.json")):
            r = load(os.path.join(d, "record.json"))
            c = r["conditions"]
            failed = [k for k, v in c.items() if not v]
            why = "%s (p95 excess %.0f ms vs %.0f ms; %d failed calls; binding %s)" % (
                ", ".join(failed) or "?", r.get("p95_excess_ms") or -1, r.get("excess_limit_ms") or -1,
                r.get("failed_calls", 0), r.get("binding"))
            import gzip
            sp = os.path.join(d, "samples.jsonl.gz")
            if os.path.exists(sp):
                p_ = load(os.path.join(d, "params.json"))
                ws = [s for s in (json.loads(x) for x in gzip.open(sp, "rt"))
                      if p_["warmup_s"] <= s.get("t", -1) <= p_["warmup_s"] + p_["window_s"]]
                cpu = "%.1f%%" % st.mean(s.get("host_cpu_busy_pct", 0) for s in ws)
            fails[(point, arm)] = r
    w("| %s | %s | %s | %s | %s | %s | %s |" % (point, arm, L.get("n_max"), L.get("n_max_abs"), stop, why, cpu))
w("")
for (point, arm), L in lad.items():
    if L and L.get("assembled"):
        w("- %s %s: ladder.json assembled after a rig error: %s." % (point, arm, L["assembled"]))
w("")

# verdicts
nm = {k: (v or {}).get("n_max") for k, v in lad.items()}
nma = {k: (v or {}).get("n_max_abs") for k, v in lad.items()}


def verdict(cond):
    return "**HOLDS**" if cond is True else ("**FALSIFIED**" if cond is False else "not decidable")


w("## Sealed predictions\n")
w("| # | claim (sealed) | outcome | verdict |")
w("|---|---|---|---|")
s, ri, r3 = nm.get(("default", "sbx")), nm.get(("default", "resident-inf")), nm.get(("default", "resident-300"))
fs, fr = fails.get(("default", "sbx")), fails.get(("default", "resident-inf"))
b_s = fs and fs.get("binding")
b_r = fr and fr.get("binding")
# prediction 1 falsifiedBy: SBX's first failed rung bound by memory, or resident ∞'s failing on pace/latency with
# binding=cpu while MemAvailable stays above floor + 1 GiB. The measured bindings are "none" for both.
c1 = None
if fs is not None and fr is not None:
    sbx_mem = b_s in ("memory_floor", "memory_high")
    res_cpu = (b_r == "cpu")
    res_mem = b_r in ("memory_floor", "memory_high")
    c1 = (not sbx_mem) and (not res_cpu) and res_mem
w("| 1 | %s | SBX's first failed rung (N=96): condition 4, binding %s, host CPU ~9%% (not memory, not CPU-saturated). Resident ∞'s (N=160): condition 4, binding %s, host CPU ~12%%, MemAvailable 356 GiB (not memory-bound) | %s: neither arm was bound by the resource named; both failed on condition 4 tails of CPU-heavy calls far below any host wall |"
  % (P[1]["claim"], b_s, b_r, verdict(c1)))
c2 = None if s is None or ri is None else (s > ri)
in_s = None if s is None else (384 <= s <= 448)
in_r = None if ri is None else (384 <= ri <= 448)
w("| 2 | %s | n_max SBX %s, resident ∞ %s (ranges: SBX in range %s, resident in range %s) | direction %s; numeric %s |"
  % (P[2]["claim"], s, ri, in_s, in_r, verdict(c2), verdict(None if in_s is None or in_r is None else (in_s and in_r))))
c3 = None if s is None or r3 is None else abs(idx(r3) - idx(s)) <= 1
w("| 3 | %s | n_max resident 300 s %s vs SBX %s (ladder steps apart: %s) | %s |"
  % (P[3]["claim"], r3, s, None if c3 is None else abs(idx(r3) - idx(s)), verdict(c3)))
w("| 4 | %s | not run on metal (SPEC §13 metal procedure) | not tested |" % P[4]["claim"])
w("| 5 | %s | not run on metal (SPEC §13 metal procedure) | not tested |" % P[5]["claim"])
a2 = []
for (point, arm), L in lad.items():
    for rr in (L or {}).get("rungs", []):
        d = rungdir(point, arm, rr)
        if os.path.exists(os.path.join(d, "record.json")):
            a2.append(load(os.path.join(d, "record.json"))["driver"].get("a2_pct_of_host") or 0)
w("| 6 | %s | max a2_pct_of_host over %d ladder rungs = %.4f%% | %s |" % (P[6]["claim"], len(a2), max(a2) if a2 else -1,
                                                                     verdict(bool(a2) and max(a2) < 1.0)))
w("| 7 | method, not a prediction | applied as sealed | n/a |")
ratio = None if not s or not ri else s / float(ri)
w("| 8 | %s | metal n_max(SBX)/n_max(resident ∞) = %s/%s = %s vs preliminary 1.0 (abs: %s/%s vs 0.125) | %s |"
  % (P[8]["claim"], s, ri, None if ratio is None else "%.3f" % ratio, nma.get(("default", "sbx")),
     nma.get(("default", "resident-inf")), verdict(None if ratio is None else ratio > 1.0)))
ms, mr = nm.get(("mem512", "sbx")), nm.get(("mem512", "resident-inf"))
fmr = fails.get(("mem512", "resident-inf"))
mem_bound = None if fmr is None else (fmr.get("binding") in ("memory_floor", "memory_high") or bool(fmr.get("memory_abort")))
c9 = None if ms is None or mr is None or mem_bound is None else (mem_bound and ms > mr)
w("| 9 | %s | n_max SBX %s, resident ∞ %s; resident ∞ first failed rung binding %s (memory-bound: %s) | %s |"
  % (P[9]["claim"], ms, mr, fmr and fmr.get("binding"), mem_bound, verdict(c9)))
w("")

w("Notes. Prediction 8 is stated on the primary verdict: metal 0.625 is not above the preliminary 1.0. On the "
  "absolute verdict the metal ratio (0.625) is above the preliminary 0.125, because the preliminary SBX n_max_abs was 1 "
  "(nested lifecycle overhead against B + 250); that is information, not the sealed claim. Prediction 9's SBX range "
  "[1, 1] is also missed (SBX held N=8): the calibration rung's 600 s warm-up drew a window with 8 cold first scans "
  "in 132 calls, the ladder's 1200 s warm-up 3 in 100. Both mem512 arms fail N=16 on the same cold-first-scan tail "
  "(a new session's scan #1 reads its own fresh 512 MiB data.bin from EBS); neither is memory-bound (resident VMs at "
  "the 1024 MiB cap, MemAvailable 370 GiB, e15.slice memory.events high 0).\n")
w("## Per-rung detail: relative slowdown (supplementary, not sealed)\n")
w("Condition 4 is in absolute milliseconds. A call that runs for minutes fails it on a slowdown of a few percent: "
  "3% of a 240 s pytest run is 7 s of excess. The table gives, per rung, the median and p95 of observed ÷ planned "
  "run time over window calls planned at ≥ 1 s, beside the p95 excess the sealed rule judges.\n")
for (point, arm), L in lad.items():
    if not L:
        continue
    w("### %s / %s\n" % (point, arm))
    w("| N | window calls | p95 excess (ms) | primary limit (ms) | calls ≥ 1 s | slowdown median | slowdown p95 | sealed holds / abs | holds_1s | holds_cpu |")
    w("|---|---|---|---|---|---|---|---|---|---|")
    for rr in L["rungs"]:
        d = rungdir(point, arm, rr)
        if not os.path.exists(os.path.join(d, "record.json")):
            continue
        r, rat, r1, rc = rung_stats(d)
        f3 = lambda x: "" if x is None else "%.3f" % x  # noqa: E731
        w("| %s | %d | %s | %s | %d | %s | %s | %s / %s | %s | %s |" % (
            rr["n"], r["window_calls"], "" if r.get("p95_excess_ms") is None else "%.0f" % r["p95_excess_ms"],
            "" if r.get("excess_limit_ms") is None else "%.0f" % r["excess_limit_ms"], len(rat), f3(q(rat, 50)),
            f3(q(rat, 95)), str(r["holds"]).lower(), str(r["holds_abs"]).lower(),
            "" if r1 is None else str(r1["holds"]).lower(), "" if rc is None else str(rc["holds"]).lower()))
    w("")

w("## Supplementary (not sealed): 1-second limit and CPU wall\n")
w("User decisions 2026-11-04/05, recorded before the rungs they judge. Not part of the sealed procedure; "
  "predictions-metal.json is untouched. `holds_1s`: SPEC §8 conditions 1–3 unchanged, condition 4 = p95 excess "
  "≤ 1000 ms (both verdicts). `holds_cpu`: conditions 1–3 only. Each default arm climbs from its sealed "
  "first-failed rung (re-judged, not re-run) up the metal ladder until a rung fails conditions 1–3; rungs run "
  "with the sealed procedure (tag 1s).\n")
w("| arm | n_max (sealed) | n_max_1s | n_max_cpu | first rung failing 1–3 | its reason |")
w("|---|---|---|---|---|---|")
for arm in ("sbx", "resident-inf", "resident-300"):
    cj = opt(os.path.join(M, "default", arm, "supplementary-1s", "climb.json"))
    if not cj:
        w("| %s | %s | (climb not finished) | | | |" % (arm, nm.get(("default", arm))))
        continue
    reason = ""
    stop = cj.get("stopped_at_cpu")
    if stop:
        cands = glob.glob(os.path.join(M, "default", arm, "supplementary-1s", "N%d-1s*" % stop))
        for d in sorted(cands):
            rc = opt(os.path.join(d, "record_cpu.json"))
            if rc:
                reason = "failed calls %d, refusals %s, class pace %s, binding %s" % (
                    rc["failed_calls"], rc.get("refusals"), rc.get("median_class_pace"), rc.get("binding"))
    w("| %s | %s | %s | %s | %s | %s |" % (arm, nm.get(("default", arm)), cj.get("n_max_1s"), cj.get("n_max_cpu"),
                                           stop, reason or ("ladder top reached" if stop is None else "")))
w("")
with open(os.path.join(M, "RESULTS-METAL.md"), "w") as f:
    f.write("\n".join(out) + "\n")
print("wrote", os.path.join(M, "RESULTS-METAL.md"))
