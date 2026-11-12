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
  "absolute verdict the metal ratio n_max_abs(SBX)/n_max_abs(resident ∞) = 80/128 = 0.625 is above the preliminary 1/8 = 0.125, because the preliminary SBX n_max_abs was 1 "
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
w("User decisions 2026-11-04/05/06, recorded before the rungs they judge. They are not part of the sealed procedure, "
  "and predictions-metal.json is untouched. `holds_1s` keeps SPEC §8 conditions 1–3 and replaces condition 4 with "
  "p95 excess ≤ 1000 ms (both verdicts). `holds_cpu` is conditions 1–3 only (no failed call, no refusal, median "
  "class pace ≤ 10%). Each default arm climbs from its sealed first-failed rung (re-judged, not re-run) up the metal "
  "ladder until a rung fails conditions 1–3. New rungs use the sealed rung procedure (tag `1s`, warm-up 1200 s, "
  "sum-drift repeat at 2400 s with K doubled).\n")
w("Grace-end artefact rule (ruling 2026-11-06): a climb rung whose only condition-1 failures are calls cancelled "
  "at the grace deadline is re-run once with a 900 s grace (tag `-g900`); the re-run counts, and both records are "
  "kept. This touches no sealed verdict. Every sealed first failure (all seven ladders) had 0 failed calls and failed "
  "condition 4 only.\n")
SUPN = {"sbx": "", "resident-inf": "", "resident-300": ""}
REASON = {
    "sbx": "N=384 (-g900 re-run; the first run was a grace-end artefact): one interpreter call planned 1,416 s ran "
           "1,536 s (+8.5%) and hit the driver's per-call timeout (planned + 120 s); class pace +0.13%, host CPU 34%, PSI 0",
    "resident-inf": "N=448 (-g900 re-run of the drift repeat; the repeat was a grace-end artefact): one interpreter call "
                    "planned 1,064 s ran 1,185 s (+11%) and hit its timeout; class pace +0.10%, host CPU 40%, PSI 0",
    "resident-300": "N=512: one interpreter call planned 371 s ran 492 s (+33%) and hit its timeout; class pace +0.25%, "
                    "host CPU mean 54% (p95 84%), CPU PSI 0.3 (the first CPU pressure of the run)",
}
w("| arm | n_max (sealed) | n_max_1s | first rung failing 1 s | n_max_cpu | first rung failing conditions 1–3 and why | p95-tail classes at the 1 s failure |")
w("|---|---|---|---|---|---|---|")
import collections
for arm in ("sbx", "resident-inf", "resident-300"):
    base = os.path.join(M, "default", arm, "supplementary-1s")
    cj = opt(os.path.join(base, "climb.json"))
    if not cj:
        w("| %s | %s | (climb not finished) | | | | |" % (arm, nm.get(("default", arm))))
        continue
    rows_ = [json.loads(x) for x in open(os.path.join(base, "climb.jsonl")) if x.strip()]
    tail = ""
    s1 = cj.get("stopped_at_1s")
    r1row = [r for r in rows_ if r["n"] == s1]
    if r1row:
        dname = os.path.basename(r1row[-1]["dir"])
        d = os.path.join(base, dname) if not r1row[-1]["sealed_rung"] else os.path.join(M, "default", arm, dname)
        cp = os.path.join(d, "calls.jsonl")
        bl = opt(os.path.join(M, "baseline", "default", arm, "N1", "baseline.json"))
        if os.path.exists(cp) and bl:
            cm = bl["class_medians"]
            ex = []
            for x in open(cp):
                c = json.loads(x)
                if c.get("in_window") and c.get("status") == "ok":
                    ex.append(((c["observed_ms"] - (c["planned_dur_ms"] - c.get("tail_ms", 0))) - cm.get(c["class"], 0), c["class"]))
            ex.sort()
            top = ex[-max(1, len(ex) // 20):]
            tail = ", ".join("%s %d" % kv for kv in collections.Counter(c for _, c in top).most_common(5))
    capped = cj.get("stopped_at_cpu") is None and cj.get("n_max_cpu") is not None
    ncpu = ("≥ %s" % cj.get("n_max_cpu")) if capped else cj.get("n_max_cpu")
    w("| %s | %s | %s | %s | %s | %s | %s |" % (arm, nm.get(("default", arm)), cj.get("n_max_1s"), s1, ncpu,
                                                REASON.get(arm) or ("N=%s" % cj.get("stopped_at_cpu")), tail))
w("")
w("### SBX vs resident: relative slowdown and host counters by rung\n")
w("Long calls are calls planned at 30 s or more. Slowdown is observed ÷ planned run time. The perf columns are 60 s "
  "`perf stat -a` samples every 300 s in each climb rung's window (climb rungs only). aperf/mperf is about 1.58 on "
  "the idle host, the turbo ratio.\n")
import subprocess
w(subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "compare_slowdown.py"), M],
                 capture_output=True, text=True).stdout)
w("Reading. (1) Every sealed first failure happened far below any host resource wall. Host CPU was 9–13% at the "
  "default point and 2% at mem512, CPU PSI 0, MemAvailable ≥ 356 GiB. perf was sampled only on climb rungs; at the "
  "nearest ones (SBX N=128/160, resident N=192) IPC was ≥ 4.3, LLC miss < 10% and turbo 1.48–1.52× base. Each failed condition 4 on a p95 tail of CPU-heavy calls (interpreter, test, opaque, build): "
  "minutes-long calls running 2–5% slow. Condition 4 is in absolute milliseconds, so a few-percent slowdown on a "
  "4–25 minute call is several seconds of excess. (2) At equal N and equal host CPU (for example N=32, 4.4% in all three "
  "arms) SBX's long calls run slower than resident's: long-call median 1.004 vs 1.000 at N=32, 1.016 vs 1.008/1.004 "
  "at N=96, 1.047 vs 1.019/1.021 at N=160. The gap widens with N while the host counters stay unsaturated. This fits "
  "per-VM cold state (each SBX command starts in a fresh guest with a cold page cache and cold CPU caches), not host "
  "contention. That is why SBX's sealed n_max (80) is below resident's (128). (3) Without condition 4, both arms "
  "climb far higher. n_max_cpu is SBX 320, resident ∞ 384, resident 300 s 448. Each stops on one long interpreter "
  "call stretched 8–33% past its per-call timeout (planned + 120 s), with class pace still ≤ 0.25%. Turbo falls with "
  "load (1.58 idle → 1.33 at N=448–512) and DRAM read rises to 1.5–2.6 GB/s, so frequency loss explains part of every "
  "arm's slowdown at high N. CPU PSI first appears at resident 300 s N=512 (0.3; host CPU p95 84%). (4) The 1 s limit "
  "gives n_max_1s = 192 for all three arms.\n")
with open(os.path.join(M, "RESULTS-METAL.md"), "w") as f:
    f.write("\n".join(out) + "\n")
print("wrote", os.path.join(M, "RESULTS-METAL.md"))
