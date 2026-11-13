#!/usr/bin/env python3
"""E17 latency report (SPEC §7.1): per point, N and arm, per command class, warm and cold wall time,
the gain against the per-Exec arm, the first call after an idle teardown, and the warm share.

  python3 experiments/e17-lease/analysis/latency_report.py RUNG_DIR... [--baseline-arm sbx] [--out DIR]
      -> DIR/latency.json, DIR/latency.md (DIR defaults to .)

Each RUNG_DIR holds params.json (arm, n, point), calls.jsonl[.gz] and worker.log[.gz]. Every rung is
tagged by warmcold.join (the same join warmcold.py writes out); rungs of one (point, N, arm), e.g.
two seeds, are pooled. Rungs whose params.json dataset_mib or snapshot_guest_ram_mb differ within one
(point, N, arm) are never pooled: the report exits non-zero naming the field and both rungs (report
each D, e.g. the gain-against-D runs, in its own invocation).
  - Calls used: in_window and status "ok". The rest is counted, never dropped silently:
    counts = {calls, used (tagged warm or cold), unknown (in-window ok, untagged), not_in_window,
    not_ok (in-window, status not ok)}; calls = used + unknown + not_in_window + not_ok.
  - Per class: warm and cold {n, median_ms, p95_ms}, and all (every in-window ok call, unknown
    included: its wall time is measured even if its tag is not). Median and p95 are E15's
    (experiments/e15-session-density/analysis/holds.py: median, nearest-rank percentile) over observed_ms.
  - Gain (non-baseline arms) = 1 - (warm median / the baseline arm's all median), same point, N and
    class; null when either side has no calls. The baseline group must have the same dataset_mib and
    snapshot_guest_ram_mb as the arm's group: otherwise the report exits non-zero naming the field,
    both values and both rungs (a lease at D=64 is never divided by sbx at D=256).
  - first_after_idle: the calls whose previous Exec on the key was followed by an idle-destroy
    (warmcold cold_reason "idle-destroy"): the cold start a user pays after the lease timed out.
  - warm_share = warm / (warm + cold) over the used calls.
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))            # rig staging: /srv/e15/src
if not os.path.isdir(os.path.join(ROOT, "e15", "analysis")):      # this repo: one level deeper
    ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, HERE)
_E15 = os.path.join(ROOT, "experiments", "e15-session-density", "analysis")
if not os.path.isdir(_E15):
    _E15 = os.path.join(ROOT, "e15", "analysis")  # the rig's staged layout (/srv/e15/src)
sys.path.insert(0, _E15)
import holds as H  # noqa: E402
import warmcold as W  # noqa: E402


def stats(ms):
    return {"n": len(ms), "median_ms": H.median(ms), "p95_ms": H.percentile(ms, 95)}


# Rungs of one (point, N, arm) pool only if these agree: the gain-against-D runs (SPEC §10) share a
# point, N and arm with the default D = 256 MiB runs and differ only in the dataset size.
MUST_MATCH = ("dataset_mib", "snapshot_guest_ram_mb")


def read_params(d):
    p = os.path.join(d, "params.json")
    if not os.path.exists(p):
        raise SystemExit("latency_report.py: no params.json in %s" % d)
    with open(p) as f:
        return json.load(f)


def summarize(rows):
    counts = {"calls": len(rows), "used": 0, "unknown": 0, "not_in_window": 0, "not_ok": 0}
    by_class, after = {}, []
    for r in rows:
        if not r["in_window"]:
            counts["not_in_window"] += 1
            continue
        if r["status"] != "ok":
            counts["not_ok"] += 1
            continue
        c = by_class.setdefault(r["class"], {"warm": [], "cold": [], "all": [], "unknown": 0})
        c["all"].append(r["observed_ms"])
        if r["warm"] == "unknown":
            counts["unknown"] += 1
            c["unknown"] += 1
            continue
        counts["used"] += 1
        c["warm" if r["warm"] else "cold"].append(r["observed_ms"])
        if r["cold_reason"] == "idle-destroy":
            after.append(r)
    classes = {k: {"warm": stats(v["warm"]), "cold": stats(v["cold"]), "all": stats(v["all"]),
                   "unknown": v["unknown"]} for k, v in sorted(by_class.items())}
    n_warm = sum(len(v["warm"]) for v in by_class.values())
    after_by = {}
    for r in after:
        after_by.setdefault(r["class"], []).append(r["observed_ms"])
    return {
        "counts": counts,
        "classes": classes,
        "warm_share": (n_warm / float(counts["used"])) if counts["used"] else None,
        "first_after_idle": {"all": stats([r["observed_ms"] for r in after]),
                             "by_class": {k: stats(v) for k, v in sorted(after_by.items())}},
    }


def build(rung_dirs, baseline_arm="sbx"):
    pooled = {}
    for d in rung_dirs:
        p = read_params(d)
        gk = (p.get("point"), p.get("n"), p.get("arm"))
        g = pooled.setdefault(gk, {"rows": [], "rungs": [], "params": p, "dir": d})
        for f in MUST_MATCH:
            if p.get(f) != g["params"].get(f):
                raise SystemExit("latency_report.py: will not pool point %s N %s arm %s: %s %r in %s, %r in %s"
                                 % (gk + (f, g["params"].get(f), g["dir"], p.get(f), d)))
        rows, summary = W.join(d)
        g["rows"].extend(rows)
        g["rungs"].append({"dir": d, "warmcold": {k: summary[k] for k in (
            "warm", "cold", "unknown", "unknown_keys", "dropped_end_session_execs")}})
    groups, first_dir = [], {}
    for (point, n, arm), g in pooled.items():
        first_dir[(point, n, arm)] = g["dir"]
        s = summarize(g["rows"])
        groups.append(dict(point=point, n=n, arm=arm, rungs=g["rungs"],
                           **{f: g["params"].get(f) for f in MUST_MATCH}, **s))
    base = {(g["point"], g["n"]): g for g in groups if g["arm"] == baseline_arm}
    for g in groups:
        if g["arm"] == baseline_arm:
            continue
        b = base.get((g["point"], g["n"]))
        for f in MUST_MATCH if b else ():
            if g[f] != b[f]:
                raise SystemExit("latency_report.py: will not take the gain of point %s N %s arm %s against %s: "
                                 "%s %r in %s, %r in %s" % (
                                     g["point"], g["n"], g["arm"], baseline_arm, f, g[f],
                                     first_dir[(g["point"], g["n"], g["arm"])], b[f],
                                     first_dir[(b["point"], b["n"], b["arm"])]))
        for cls, c in g["classes"].items():
            bm = b["classes"].get(cls, {}).get("all", {}).get("median_ms") if b else None
            wm = c["warm"]["median_ms"]
            c["baseline_median_ms"] = bm
            c["gain"] = (1.0 - wm / float(bm)) if (bm and wm is not None) else None
    groups.sort(key=lambda g: (str(g["point"]), g["n"] or 0, g["arm"] != baseline_arm, str(g["arm"])))
    return {"baseline_arm": baseline_arm, "groups": groups}


def fmt(v, spec="%.0f"):
    return "-" if v is None else spec % v


def markdown(rep):
    b = rep["baseline_arm"]
    out = ["# E17 latency (SPEC §7.1)", "",
           "Wall time (observed_ms) of in-window ok calls. Gain = 1 - (warm median / %s median)." % b, "",
           "| point | N | arm | class | warm n | warm median ms | warm p95 ms | cold n | cold median ms "
           "| cold p95 ms | unknown | %s median ms | gain |" % b,
           "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for g in rep["groups"]:
        for cls, c in g["classes"].items():
            w, k = c["warm"], c["cold"]
            out.append("| %s | %s | %s | %s | %d | %s | %s | %d | %s | %s | %d | %s | %s |" % (
                g["point"], g["n"], g["arm"], cls, w["n"], fmt(w["median_ms"]), fmt(w["p95_ms"]),
                k["n"], fmt(k["median_ms"]), fmt(k["p95_ms"]), c["unknown"],
                fmt(c["all"]["median_ms"] if g["arm"] == b else c.get("baseline_median_ms")),
                "-" if g["arm"] == b else fmt(c.get("gain"), "%.2f")))
    out += ["", "## Warm share, first call after idle, call counts", "",
            "| point | N | arm | warm share | first call after idle n | median ms | p95 ms "
            "| calls | used | unknown | not in window | not ok |",
            "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for g in rep["groups"]:
        a, c = g["first_after_idle"]["all"], g["counts"]
        out.append("| %s | %s | %s | %s | %d | %s | %s | %d | %d | %d | %d | %d |" % (
            g["point"], g["n"], g["arm"], fmt(g["warm_share"], "%.3f"), a["n"], fmt(a["median_ms"]),
            fmt(a["p95_ms"]), c["calls"], c["used"], c["unknown"], c["not_in_window"], c["not_ok"]))
    return "\n".join(out) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("rungs", nargs="+")
    ap.add_argument("--baseline-arm", default="sbx")
    ap.add_argument("--out", default=".", help="directory for latency.json and latency.md")
    a = ap.parse_args(argv)
    rep = build(a.rungs, baseline_arm=a.baseline_arm)
    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "latency.json"), "w") as f:
        json.dump(rep, f, indent=2, sort_keys=True)
    with open(os.path.join(a.out, "latency.md"), "w") as f:
        f.write(markdown(rep))


if __name__ == "__main__":
    main()
