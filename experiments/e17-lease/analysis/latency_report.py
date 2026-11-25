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
  - Reported-only classes (REPORTED_ONLY: py_shmem, E17b's guest Shmem reading, PLAN-E17B Task 10) are
    in none of the above: not a class, not in the counts, the warm share, the first call after idle or
    the gain, so never in a latency gate or a per-class median. Their in-window ok calls are
    reported apart, under reported_only[class].all. A reported-only call tagged first_lease (a session
    drawn to start at its py_shmem) is filed under first_lease like any first call: it carries the walk.
  - by_tmpfs (E17B-R26, reported only, never gated): py_short and py_import warm and all {n, median_ms,
    p95_ms}, split by the session's tmpfs flag (calls.jsonl `tmpfs`) into flagged and unflagged, so the
    report shows whether flagged sessions' bytecode recompiles slowed the gated classes. Only in a group
    with a flagged session (an E15/E16/E17a group keeps its exact shape).
  - warm_by_cache (E17c, SPEC §13.3 criterion 2, ruling R-g; reported beside the gain, never in it): per
    class, the warm calls split by warmcold_lease's `cache` tag into after_drop (the session's previous call
    ended more than the rung's lease_cache_drop before: the guest had dropped its page cache) and kept, each
    {n, median_ms, p95_ms}, and ratio = after_drop median / kept median (null when either group is empty).
    The gain stays over all warm calls, as in E17b. Only in a group with a tagged row (ship-300-nd, sbx and
    every E17b group keep their exact shape, latency.md included).
  - E17d (spec §14.3 reading 1; PLAN-E17D Task 5): a call the driver recorded as a level-2 restart (calls.jsonl
    `restart`, ship-300-l2's --l2-restart) is never warm: "warm" there means a live lease AND a server that answered
    the probe. A server-lost restart (its lease was live) is in neither warm nor cold; a lease-cold one stays cold.
    Per class, `restart` gives {all, lease_cold, server_lost} {n, median_ms, p95_ms} (only in a group with a
    restart). In a report with a ship-300-l2 group, every non-baseline class carries gain_n {warm, baseline_all},
    and ship-300-l2's classes the warm-against-warm gain against L1_ARM (ship-300) at the same point, N and class:
    gain_vs_l1 = 1 - (warm median / ship-300's warm median), with l1_warm_median_ms and gain_vs_l1_n {warm,
    l1_warm} (null when either side has no warm call). latency.md then adds a "Level 2 against level 1" table. A
    report with no ship-300-l2 group keeps its exact shape.
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
import warmcold_lease as WL  # noqa: E402


def stats(ms):
    return {"n": len(ms), "median_ms": H.median(ms), "p95_ms": H.percentile(ms, 95)}


# Classes that are measured only for what they print (py_shmem: the guest's Shmem after a turn's
# last py_analyze), never for their latency: warmcold_lease's one definition.
REPORTED_ONLY = WL.REPORTED_ONLY
# E17B-R26: the gated classes' medians split by the session's tmpfs flag (reported only).
BY_TMPFS_CLASSES = ("py_short", "py_import")

# Rungs of one (point, N, arm) pool only if these agree: the gain-against-D runs (SPEC §10) share a
# point, N and arm with the default D = 256 MiB runs and differ only in the dataset size.
MUST_MATCH = ("dataset_mib", "snapshot_guest_ram_mb")
# E17d: the level-2 arm and the level-1 arm its warm-against-warm gain is taken against (spec §14.3).
L2_ARM, L1_ARM = "ship-300-l2", "ship-300"
RESTART_KINDS = ("lease_cold", "server_lost")


def read_params(d):
    p = os.path.join(d, "params.json")
    if not os.path.exists(p):
        raise SystemExit("latency_report.py: no params.json in %s" % d)
    with open(p) as f:
        return json.load(f)


def join_rung(d, arm):
    """The arm map: the shipped-lease arms (ship-*) are joined on the shipped worker's lease log
    (warmcold_lease); every other arm, E17a's included, on warmcold.join, unchanged."""
    return (WL if str(arm).startswith("ship-") else W).join(d)


def summarize(rows):
    # Calls tagged first_lease (the first-lease ownership walk, Review Focus 6) are reported on their
    # own and kept out of the counts and the warm/cold classes. Rows of other arms never carry the tag.
    firsts, rest, reported = [], [], {}
    for r in rows:
        if r["warm"] == "set_mode_failed":
            continue  # never sent: reported by the join's set_mode_failed count, in no class
        if r.get("first_lease"):  # before the reported-only check: a first py_shmem carries the walk
            firsts.append(r)
        elif r["class"] in REPORTED_ONLY:
            reported.setdefault(r["class"], [])
            if r["in_window"] and r["status"] == "ok":
                reported[r["class"]].append(r["observed_ms"])
        else:
            rest.append(r)
    rows = rest
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
        if r.get("restart") and r["warm"] is True:
            pass  # E17d: a server-lost restart ran in a live lease but is not warm (no server answered)
        else:
            c["warm" if r["warm"] else "cold"].append(r["observed_ms"])
        if r["cold_reason"] in ("idle-destroy", "idle"):
            after.append(r)
    classes = {k: {"warm": stats(v["warm"]), "cold": stats(v["cold"]), "all": stats(v["all"]),
                   "unknown": v["unknown"]} for k, v in sorted(by_class.items())}
    if any(r.get("restart") for r in rows):  # E17d: only a group with a level-2 restart
        for k, c in classes.items():
            rs = [r for r in rows if r["class"] == k and r["in_window"] and r["status"] == "ok" and r.get("restart")]
            c["restart"] = dict({"all": stats([r["observed_ms"] for r in rs])},
                                **{kind: stats([r["observed_ms"] for r in rs if r.get("restart_kind") == kind])
                                   for kind in RESTART_KINDS})
    if any("cache" in r for r in rows):  # E17c, ruling R-g: only a rung with the guest's drop on
        for k, c in classes.items():
            tagged = [r for r in rows if r["class"] == k and r["in_window"] and r["status"] == "ok"
                      and r["warm"] is True]
            wc = {t: stats([r["observed_ms"] for r in tagged if r.get("cache") == t])
                  for t in (WL.AFTER_DROP, WL.KEPT)}
            a, b = wc[WL.AFTER_DROP]["median_ms"], wc[WL.KEPT]["median_ms"]
            wc["ratio"] = (a / float(b)) if (a is not None and b) else None
            c["warm_by_cache"] = wc
    split = {}
    for r in rows:
        if r["class"] in BY_TMPFS_CLASSES and r["in_window"] and r["status"] == "ok":
            s = split.setdefault(r["class"], {"flagged": {"warm": [], "all": []},
                                               "unflagged": {"warm": [], "all": []}})["flagged" if r.get("tmpfs") else "unflagged"]
            s["all"].append(r["observed_ms"])
            if r["warm"] is True:
                s["warm"].append(r["observed_ms"])
    n_warm = sum(len(v["warm"]) for v in by_class.values())
    after_by = {}
    for r in after:
        after_by.setdefault(r["class"], []).append(r["observed_ms"])
    fl = [r["observed_ms"] for r in firsts if r["in_window"] and r["status"] == "ok"]
    fl_by = {}
    for r in firsts:
        if r["in_window"] and r["status"] == "ok":
            fl_by.setdefault(r["class"], []).append(r["observed_ms"])
    out = {
        "counts": counts,
        "classes": classes,
        "warm_share": (n_warm / float(counts["used"])) if counts["used"] else None,
        "first_after_idle": {"all": stats([r["observed_ms"] for r in after]),
                             "by_class": {k: stats(v) for k, v in sorted(after_by.items())}},
    }
    if firsts:  # only ship arms: an E17a group keeps its exact shape
        out["first_lease"] = {"calls": len(firsts), "all": stats(fl),
                              "by_class": {k: stats(v) for k, v in sorted(fl_by.items())}}
    if reported:  # only E17b corpora have py_shmem: an E17a group keeps its exact shape
        out["reported_only"] = {k: {"all": stats(v)} for k, v in sorted(reported.items())}
    if any(r.get("tmpfs") for r in rows):  # only E17b corpora flag sessions: the same
        out["by_tmpfs"] = {k: {f: {"warm": stats(v[f]["warm"]), "all": stats(v[f]["all"])} for f in v}
                           for k, v in sorted(split.items())}
    return out


def build(rung_dirs, baseline_arm="sbx", arms=None):
    pooled = {}
    for d in rung_dirs:
        p = read_params(d)
        if arms and p.get("arm") not in arms and p.get("arm") != baseline_arm:
            continue
        gk = (p.get("point"), p.get("n"), p.get("arm"))
        g = pooled.setdefault(gk, {"rows": [], "rungs": [], "params": p, "dir": d})
        for f in MUST_MATCH:
            if p.get(f) != g["params"].get(f):
                raise SystemExit("latency_report.py: will not pool point %s N %s arm %s: %s %r in %s, %r in %s"
                                 % (gk + (f, g["params"].get(f), g["dir"], p.get(f), d)))
        rows, summary = join_rung(d, p.get("arm"))
        # E17B-R26: a row's session flag (the driver writes tmpfs on every row of a flagged session)
        flagged = {c.get("session") for c in W.read_calls(d) if c.get("tmpfs")}
        restarts = {(c.get("session"), c.get("call")): c for c in W.read_calls(d) if c.get("restart")}
        for r in rows:
            if r["session"] in flagged:
                r["tmpfs"] = True
            c = restarts.get((r["session"], r["call"]))
            if c:  # E17d: the driver's level-2 restart record
                r["restart"], r["restart_kind"] = True, c.get("restart_kind")
        keys = ("warm", "cold", "unknown", "unknown_keys", "dropped_end_session_execs")
        if str(p.get("arm")).startswith("ship-"):
            # A ship rung the join cannot vouch for is listed, never pooled (E17B-R9).
            why = [k + "=%s" % summary[k] for k in ("disagreements", "set_mode_failed") if summary[k]]
            if why or not summary["valid"] or not summary["countable"]:
                g.setdefault("excluded", []).append({"dir": d, "reason": ", ".join(why) or "not valid"})
                continue
            keys += ("valid", "countable", "disagreements", "set_mode_failed", "failed_no_vm")
        g["rows"].extend(rows)
        g["rungs"].append({"dir": d, "warmcold": {k: summary[k] for k in keys}})
    groups, first_dir = [], {}
    for (point, n, arm), g in pooled.items():
        first_dir[(point, n, arm)] = g["dir"]
        s = summarize(g["rows"])
        extra = {}
        if str(arm).startswith("ship-"):
            extra = {"excluded_rungs": g.get("excluded", []), "countable": not g.get("excluded")}
        groups.append(dict(point=point, n=n, arm=arm, rungs=g["rungs"],
                           **{f: g["params"].get(f) for f in MUST_MATCH}, **extra, **s))
    base = {(g["point"], g["n"]): g for g in groups if g["arm"] == baseline_arm}
    has_l2 = any(g["arm"] == L2_ARM for g in groups)
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
            if has_l2:  # E17d: each gain carries its n
                c["gain_n"] = {"warm": c["warm"]["n"],
                               "baseline_all": (b["classes"].get(cls, {}).get("all", {}).get("n") or 0) if b else 0}
    for g in groups if has_l2 else ():
        if g["arm"] != L2_ARM:
            continue
        l1 = next((h for h in groups if (h["point"], h["n"], h["arm"]) == (g["point"], g["n"], L1_ARM)), None)
        for cls, c in g["classes"].items():
            lw = l1["classes"].get(cls, {}).get("warm", {}) if l1 else {}
            lm, wm = lw.get("median_ms"), c["warm"]["median_ms"]
            c["l1_warm_median_ms"] = lm
            c["gain_vs_l1"] = (1.0 - wm / float(lm)) if (lm and wm is not None) else None
            c["gain_vs_l1_n"] = {"warm": c["warm"]["n"], "l1_warm": lw.get("n") or 0}
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
    split = [(g, cls, c["warm_by_cache"]) for g in rep["groups"] for cls, c in g["classes"].items()
             if "warm_by_cache" in c]
    if split:  # E17c (ruling R-g): only when a group has the guest's drop on
        out += ["", "## Warm calls by the guest's page-cache drop", "",
                "Warm calls whose session's previous call ended more than the rung's lease_cache_drop before "
                "(after drop) and the rest (kept). Reported beside the gain, which stays over all warm calls.", "",
                "| point | N | arm | class | after drop n | after drop median ms | kept n | kept median ms "
                "| after drop / kept |",
                "|---|---|---|---|---|---|---|---|---|"]
        for g, cls, wc in split:
            a, k = wc[WL.AFTER_DROP], wc[WL.KEPT]
            out.append("| %s | %s | %s | %s | %d | %s | %d | %s | %s |" % (
                g["point"], g["n"], g["arm"], cls, a["n"], fmt(a["median_ms"]), k["n"], fmt(k["median_ms"]),
                fmt(wc["ratio"], "%.2f")))
    l2 = [(g, cls, c) for g in rep["groups"] if g["arm"] == L2_ARM for cls, c in g["classes"].items()]
    if l2:  # E17d: only a report with a level-2 group
        out += ["", "## Level 2 against level 1", "",
                "Warm against warm: gain = 1 - (%s warm median / %s warm median), same point, N and class." % (
                    L2_ARM, L1_ARM), "",
                "| point | N | arm | class | warm n | warm median ms | %s warm n | %s warm median ms | gain |" % (
                    L1_ARM, L1_ARM),
                "|---|---|---|---|---|---|---|---|---|"]
        for g, cls, c in l2:
            out.append("| %s | %s | %s | %s | %d | %s | %d | %s | %s |" % (
                g["point"], g["n"], g["arm"], cls, c["warm"]["n"], fmt(c["warm"]["median_ms"]),
                c["gain_vs_l1_n"]["l1_warm"], fmt(c["l1_warm_median_ms"]), fmt(c["gain_vs_l1"], "%.2f")))
    return "\n".join(out) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("rungs", nargs="+")
    ap.add_argument("--baseline-arm", default="sbx")
    ap.add_argument("--arms", help="comma-separated arms to report besides the baseline (default: all)")
    ap.add_argument("--out", default=".", help="directory for latency.json and latency.md")
    a = ap.parse_args(argv)
    rep = build(a.rungs, baseline_arm=a.baseline_arm, arms=a.arms.split(",") if a.arms else None)
    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "latency.json"), "w") as f:
        json.dump(rep, f, indent=2, sort_keys=True)
    with open(os.path.join(a.out, "latency.md"), "w") as f:
        f.write(markdown(rep))


if __name__ == "__main__":
    main()
