#!/usr/bin/env python3
"""gate-256: the 256 MiB library's calibration (PLAN-E17C Task 10; SPEC §13.5, R45; ruling R-x).

E17b's py_analyze was OOM-killed in a 256 MiB guest in both arms: a lease command's cap there is about 166 MiB
(MemTotal - max(64 MiB, MemTotal/8)). E17c's 256 MiB points (pycache-d64, squeeze-256) replay
workload/library-256.json, whose py_analyze runs at a lower ANALYZE_WORK_SCALE. Ruling R-z1: the project's sources
(config.py) stay as in E17a/E17b, so an E17C-unset bring-up keeps its templates; the command itself sets the scale
(analyze_cmd: `../venv/bin/python -c` sets the bytecode prefix as analyze.py does, imports pyc.config, sets
ANALYZE_WORK_SCALE and runs analyze.py as __main__). This picks that scale: in a 256 MiB guest, for each candidate scale
and each arm (sbx, ship-300), py_analyze runs 20 times (one probe session, rung.sh at pycache-d64 N=1 with
E17C_GATE_LIBRARY = a gate library); the chosen scale is the LARGEST whose 20 runs in EVERY arm all completed with
exit 0, none OOM-killed, each with a peak RSS reading, and the peak over them <= 120 MiB.

Peak RSS is measured inside the command: the gate library's py_analyze runs analyze_cmd's program as the child of a
../venv/bin/python wrapper (the venv is in every guest; python3 is not certain to be) that prints `peak_rss_kb=<resource.getrusage(RUSAGE_CHILDREN).ru_maxrss>` after it (KiB on Linux, the guest)
and exits as the child did (128 + signal when killed: 137 for the OOM killer's SIGKILL). The guest may have no
/usr/bin/time. The rung records py_analyze's stdout (--record-stdout). The wrapper is in the same cgroup, so it lowers
the command's headroom a little (the gate errs on the safe side).

An OOM kill is a run whose exit or failed_rc (the joined script's failing step's own status) is 137, as E17b's R45
rows were ("exit 90: step 0 exited 137"). Any other failure (a timeout, a refusal) also fails the scale, as "failed".

Subcommands (chain-e17c.sh's gate-256 and ram256 stages call them):

  gate256.py library --base LIB256 --scale S --out FILE
      the gate library for scale S: LIB256 with py_analyze's command the wrapper at S
  gate256.py write --runs RUNS/pycache-d64 --out gate-256.json --moca-commit PIN --scales "32 16 ..." \\
                   --arms "sbx ship-300" --runs-per 20 --rss-max-mib 120 --library LIB256
      reads ARM/N1-g256-s<S>/{params.json,calls.jsonl} for every scale and arm, writes gate-256.json and prints
      "PASS: ..." or "FAIL: ..."; exits non-zero (no file) when a rung is missing, unreadable, not at 256 MiB or has
      another number of py_analyze calls than --runs-per (a rig error, not a fail)
  gate256.py state --gate gate-256.json --moca-commit PIN --library LIB256
      the ram256 stages' check: prints "pass <scale>" (exit 0) only for a passing gate at this moca_commit whose
      chosen scale library-256.json carries; else the reason (exit 1). Ruling R-x: the gate reports the scale and
      library-256.json gets it only through a reviewed, committed change; until then it carries the placeholder 0.
"""

import argparse
import hashlib
import json
import os
import re
import statistics
import sys

RUNS_PER = 20
RSS_MAX_MIB = 120
ARMS = ("sbx", "ship-300")
OOM_RC = 137
PLACEHOLDER = 0
# library-256.json's py_analyze: analyze.py at ANALYZE_WORK_SCALE = <scale>, with no change to the project's sources.
# PYC_CACHE_DIR's bytecode prefix is set before pyc.config is first imported, exactly as analyze.py sets it.
ANALYZE_PROGRAM = ('import os, runpy, sys; d = os.environ.get("PYC_CACHE_DIR"); '
                   'sys.pycache_prefix = os.path.join(d, "pyc") if d else None; sys.path.insert(0, "src"); '
                   'from pyc import config; config.ANALYZE_WORK_SCALE = %d; '
                   'runpy.run_path("analyze.py", run_name="__main__")')
CMD_256 = re.compile("^" + re.escape("cd project && ../venv/bin/python -c '" + ANALYZE_PROGRAM + "'")
                     .replace(re.escape("%d"), r"(\d+)") + "$")
PEAK = re.compile(r"(?m)^peak_rss_kb=(\d+)$")
RUNG = "N1-g256-s%d"
# The gate library's py_analyze: ANALYZE_PROGRAM as the wrapper's child, its peak RSS printed after it.
WRAPPER = ("cd project && ../venv/bin/python -c 'import resource, subprocess, sys; "
           "r = subprocess.call([\"../venv/bin/python\", \"-c\", %s]); "
           "print(\"peak_rss_kb=%%d\" %% resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss, flush=True); "
           "sys.exit(128 - r if r < 0 else r)'")


def analyze_cmd(scale):
    """library-256.json's py_analyze command at SCALE (PLACEHOLDER 0: fit_repeated refuses it, so it never runs)."""
    return "cd project && ../venv/bin/python -c '" + ANALYZE_PROGRAM % scale + "'"


def wrapper_cmd(scale):
    """The gate library's py_analyze at SCALE: the RSS wrapper around analyze_cmd's program."""
    return WRAPPER % json.dumps(ANALYZE_PROGRAM % scale)


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def library_scale(path):
    """The ANALYZE_WORK_SCALE library-256.json's py_analyze command sets (PLACEHOLDER: not calibrated yet)."""
    with open(path) as f:
        (inv,) = json.load(f)["classes"]["py_analyze"]
    m = CMD_256.match(inv["cmd"])
    if not m:
        raise ValueError("%s: py_analyze's command is not gate256.analyze_cmd(<n>): %r" % (path, inv["cmd"]))
    return int(m.group(1))


def write_gate_library(base, scale, out):
    """BASE (library-256.json) with py_analyze's command the RSS wrapper at SCALE, to OUT."""
    if not isinstance(scale, int) or scale < 1:
        raise ValueError("a gate scale is a positive int, not %r" % (scale,))
    with open(base) as f:
        lib = json.load(f)
    (inv,) = lib["classes"]["py_analyze"]
    inv["cmd"] = wrapper_cmd(scale)
    tmp = out + ".tmp"
    with open(tmp, "w") as f:
        json.dump(lib, f, indent=2)
        f.write("\n")
    os.replace(tmp, out)


def peak_rss_kb(stdout):
    """The wrapper's peak_rss_kb=<n> line from a call's recorded stdout, or None."""
    m = PEAK.search(stdout or "")
    return int(m.group(1)) if m else None


def run_of(row):
    """One py_analyze call row of calls.jsonl -> the run: ok, oom, peak_rss_kb, observed_ms, status, cause."""
    oom = row.get("exit") == OOM_RC or row.get("failed_rc") == OOM_RC
    return {"ok": row.get("status") == "ok" and row.get("exit") == 0, "oom": oom,
            "peak_rss_kb": peak_rss_kb(row.get("stdout")), "observed_ms": row.get("observed_ms"),
            "status": row.get("status"), "cause": row.get("cause")}


def summarize(runs, runs_per=RUNS_PER, rss_max_mib=RSS_MAX_MIB):
    """One candidate scale and arm: its runs -> counts, the peak, pass and why not."""
    if runs is None:
        return {"runs": 0, "pass": False, "reason": "not run"}
    oom = sum(1 for r in runs if r.get("oom"))
    failed = sum(1 for r in runs if not r.get("ok") and not r.get("oom"))
    ok = [r for r in runs if r.get("ok")]
    missing = sum(1 for r in ok if r.get("peak_rss_kb") is None)
    peaks = [r["peak_rss_kb"] for r in ok if r.get("peak_rss_kb") is not None]
    peak = max(peaks) if peaks else None
    ms = [r["observed_ms"] for r in ok if r.get("observed_ms") is not None]
    why = []
    if len(runs) != runs_per:
        why.append("%d run(s), not %d" % (len(runs), runs_per))
    if oom:
        why.append("%d OOM kill(s)" % oom)
    if failed:
        why.append("%d failed run(s) (%s)" % (failed, ", ".join(sorted({str(r.get("cause") or r.get("status"))
                                                                       for r in runs
                                                                       if not r.get("ok") and not r.get("oom")}))))
    if missing:
        why.append("%d run(s) with no peak RSS reading" % missing)
    if peak is not None and peak > rss_max_mib * 1024:
        why.append("peak RSS %.1f MiB > %d MiB" % (peak / 1024.0, rss_max_mib))
    if peak is None and not why:
        why.append("no peak RSS reading")
    return {"runs": len(runs), "ok": len(ok), "oom_kills": oom, "failed": failed, "rss_missing": missing,
            "peak_rss_kb": peak, "peak_rss_mib": round(peak / 1024.0, 1) if peak is not None else None,
            "median_ms": statistics.median(ms) if ms else None,
            "pass": not why, "reason": "; ".join(why) if why else None}


def judge(results, arms=ARMS, runs_per=RUNS_PER, rss_max_mib=RSS_MAX_MIB):
    """results: {scale: {arm: [run, ...] or None}} -> the gate's verdict (chosen_scale: the largest passing one)."""
    cands = sorted((int(s) for s in results), reverse=True)
    out, chosen, fails = {}, None, []
    for s in cands:
        per = {a: summarize((results[s] or {}).get(a), runs_per, rss_max_mib) for a in arms}
        out[str(s)] = per
        bad = ["%s: %s" % (a, per[a]["reason"]) for a in arms if not per[a]["pass"]]
        if bad:
            fails.append("scale %d (%s)" % (s, "; ".join(bad)))
        elif chosen is None:
            chosen = s
    if chosen is not None:
        reason = ("scale %d: %d runs per arm (%s), zero OOM kills, peak RSS <= %d MiB (%s)"
                  % (chosen, runs_per, ", ".join(arms), rss_max_mib,
                     ", ".join("%s %.1f MiB" % (a, out[str(chosen)][a]["peak_rss_mib"]) for a in arms)))
        if fails:
            reason += "; larger scales failed: " + "; ".join(f for f in fails if int(f.split()[1]) > chosen)
    else:
        reason = "no candidate scale passed: " + "; ".join(fails)
    return {"candidates": cands, "arms": list(arms), "runs_per_arm": runs_per, "rss_max_mib": rss_max_mib,
            "results": out, "chosen_scale": chosen, "pass": chosen is not None, "reason": reason,
            # the corpus's py_analyze duration (gen_corpora.sh --gate-256): the chosen scale's sbx median, as
            # results/calibration/durations-v0.4.md took the 1024 MiB one (sbx N = 1 in-window calls)
            "py_analyze_ms": out[str(chosen)][arms[0]]["median_ms"] if chosen is not None else None}


def choose_scale(results, arms=ARMS, runs_per=RUNS_PER, rss_max_mib=RSS_MAX_MIB):
    """The selection rule alone: the largest scale whose runs pass in every arm, or None."""
    return judge(results, arms, runs_per, rss_max_mib)["chosen_scale"]


def read_rung(root, arm, scale, runs_per):
    """ARM/N1-g256-s<scale>'s py_analyze runs; SystemExit on a rig error."""
    d = os.path.join(root, arm, RUNG % scale)
    try:
        params = json.load(open(os.path.join(d, "params.json")))
        rows = [json.loads(line) for line in open(os.path.join(d, "calls.jsonl")) if line.strip()]
    except (OSError, ValueError) as e:
        sys.exit("gate256.py: %s is missing or unreadable (%s): no gate" % (d, e))
    if params.get("guest_ram_mb") != 256:
        sys.exit("gate256.py: %s ran at guest_ram_mb %s, not 256: no gate" % (d, params.get("guest_ram_mb")))
    runs = [run_of(r) for r in rows if r.get("class") == "py_analyze"]
    if len(runs) != runs_per:
        sys.exit("gate256.py: %s has %d py_analyze call(s), expected exactly %d (the probe corpus's): no gate"
                 % (d, len(runs), runs_per))
    return runs, {"rung": "pycache-d64/%s/%s" % (arm, RUNG % scale),
                  "gate_library": params.get("library"), "gate_library_sha256": params.get("library_sha256")}


def cmd_write(a):
    scales = [int(s) for s in a.scales.split()]
    arms = a.arms.split()
    results, rungs = {}, {}
    for s in scales:
        results[s], rungs[s] = {}, {}
        for arm in arms:
            results[s][arm], rungs[s][arm] = read_rung(a.runs, arm, s, a.runs_per)
    doc = judge(results, arms, a.runs_per, a.rss_max_mib)
    if [int(s) for s in doc["candidates"]] != scales:
        sys.exit("gate256.py: --scales must be in descending order: %s" % a.scales)
    for s in scales:
        for arm in arms:
            doc["results"][str(s)][arm].update(rungs[s][arm])
    doc.update(stage="gate-256", spec="SPEC §13.5 (R45); PLAN-E17C Task 10", point="pycache-d64",
               moca_commit=a.moca_commit, guest_ram_mb=256,
               measured=("peak RSS: resource.getrusage(RUSAGE_CHILDREN).ru_maxrss of analyze.py (KiB), printed by "
                         "the gate library's ../venv/bin/python wrapper inside the command; OOM kill: exit or failed_rc 137"),
               library_256={"path": a.library, "sha256": sha256(a.library), "scale": library_scale(a.library)},
               next=("commit chosen_scale into library-256.json's py_analyze (gate256.analyze_cmd(<scale>)), then "
                     "gen_corpora.sh --gate-256 this file, sync.sh and E17C=1 setup.sh before the ram256 stages"))
    tmp = a.out + ".tmp"
    with open(tmp, "w") as f:
        json.dump(doc, f, indent=1, sort_keys=True)
        f.write("\n")
    os.replace(tmp, a.out)
    print(("PASS: " if doc["pass"] else "FAIL: ") + doc["reason"])


def cmd_state(a):
    path = a.gate
    if not os.path.exists(path):
        print("no %s: run gate-256 first (SPEC §13.5: the 256 MiB stages run only after its calibration)" % path)
        return 1
    try:
        g = json.load(open(path))
    except (OSError, ValueError):
        g = None
    if not isinstance(g, dict) or not isinstance(g.get("pass"), bool):
        print("%s is unreadable (no boolean \"pass\"): re-run gate-256" % path)
        return 1
    if g.get("moca_commit") != a.moca_commit:
        print("%s is not this chain's gate (moca_commit %s, not %s): re-run gate-256"
              % (path, json.dumps(g.get("moca_commit")), a.moca_commit))
        return 1
    if g["pass"] is not True or not isinstance(g.get("chosen_scale"), int):
        print("gate-256 did not pass (%s): no scale fits a 256 MiB guest; the ram256 stages do not run"
              % (g.get("reason") or "no reason recorded"))
        return 1
    try:
        have = library_scale(a.library)
    except (OSError, ValueError, KeyError) as e:
        print("%s is unreadable (%s)" % (a.library, e))
        return 1
    want = g["chosen_scale"]
    if have == PLACEHOLDER:
        print("%s still has the placeholder scale %d: commit gate-256's scale %d into it (a reviewed change, ruling "
              "R-x), then sync.sh" % (a.library, PLACEHOLDER, want))
        return 1
    if have != want:
        print("%s has scale %d, but gate-256 chose %d (%s): commit the gate's scale, or re-run gate-256"
              % (a.library, have, want, path))
        return 1
    print("pass %d" % want)
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    lib = sub.add_parser("library")
    lib.add_argument("--base", required=True)
    lib.add_argument("--scale", type=int, required=True)
    lib.add_argument("--out", required=True)
    w = sub.add_parser("write")
    w.add_argument("--runs", required=True)
    w.add_argument("--out", required=True)
    w.add_argument("--moca-commit", required=True)
    w.add_argument("--scales", required=True)
    w.add_argument("--arms", default=" ".join(ARMS))
    w.add_argument("--runs-per", type=int, default=RUNS_PER)
    w.add_argument("--rss-max-mib", type=int, default=RSS_MAX_MIB)
    w.add_argument("--library", required=True)
    st = sub.add_parser("state")
    st.add_argument("--gate", required=True)
    st.add_argument("--moca-commit", required=True)
    st.add_argument("--library", required=True)
    a = p.parse_args(argv)
    if a.cmd == "library":
        try:
            write_gate_library(a.base, a.scale, a.out)
        except ValueError as e:
            sys.exit("gate256.py: %s" % e)
        return 0
    if a.cmd == "write":
        cmd_write(a)
        return 0
    return cmd_state(a)


if __name__ == "__main__":
    sys.exit(main())
