#!/usr/bin/env python3
"""E17d's level-2 readings (PLAN-E17D Task 5, spec §14.3 readings 2-4) for one ship-300-l2 rung.

  python3 experiments/e17-lease/analysis/level2.py RUNG_DIR [--paired SHIP300_RUNG] -> RUNG_DIR/level2.json
  python3 experiments/e17-lease/analysis/level2.py --warm-count py_requery,py_refit RUNG...   (the chain's warm minimum)

Inputs: calls.jsonl (the driver's restart, restart_kind, start_ms, process_list, process_events and lease_events),
lease-tail.jsonl, worker.log, samples.jsonl (vm_fp), params.json. The paired rung is the ship-300 rung of the same
point, N and seed.

  restarts         every restart call (the driver's level-2 restart rule), by kind: lease_cold (the call's first Exec
                   started a new lease) and server_lost (the lease was live, no server answered). Per kind {n,
                   median_ms, p95_ms} of observed_ms (from the first send, the start included) and start_median_ms
                   (the process_start's own time). prev_end_reason: for a lease-cold restart, the reason of the last
                   `end` notice its own call carried (the lease that ended since the session's last call), "first"
                   for the session's first call, null otherwise; counted in prev_end_reasons.
  lease_cold_share warmcold_lease's cold calls over its warm and cold ones, in window (the session's first call
                   included: it is the set warmcold_lease calls cold); paired_lease_cold_share the same at the paired
                   ship-300 rung. Lease-cold restarts follow the gap draw and are reported, not gated (spec §14.4 L2c).
  server_lost_rate L2c's reading: server-lost restarts among the in-window py_requery calls that found their lease
                   live (warmcold_lease warm).
  charge           each lease's vm_fp at +45 s after the end of its last Exec (the sample within 1 s; vm_age_lease's
                   identity replay attributes the cgroups), beside the paired ship-300 lease of the same session (the
                   same corpus trace, its k-th occurrence by first send, and the lease's ordinal in it). null, with
                   its reason, when the mapping is not valid or the samples carry no vm_fp.
  ends             judged ends (reading 4, L2d): a `lease end` line that lists a running tracked process
                   (processes=[id:name:running ...]), less the ends that skip the sync by design (sandbox_deleted,
                   teardown_failed: moca endLeaseLocked), the driver's end-of-run cut ends (E17B-R54), the ends after
                   the status sweep and the carry-overs (lease_ends.py's rules). Each is paired with the key's n-th
                   `end` notice (lease_ends.py's order; a notice whose reason differs is not its notice): notices (0 or
                   1), names_l2srv (the notice's processes name l2srv), sync_line (a `vmpool: lease end sync
                   workspace_key=` line for that key and VM: the sync failed or passed LeaseEndSyncTimeout). At this pin
                   the worker logs no sync duration, so none is computed. pass: every judged end has its one notice
                   naming l2srv and no sync line; null when the rung has no judged end.
  oom_kills        every tracked process seen killed(9): in a server-lost restart's process_list, a lease end line's
                   processes, a notice's tracked table or the lease-tail table, with the state it left;
                   oom_kills_l2srv counts the l2srv ones (L2c).
  refusals         each `vmpool: memory-budget refusal workspace_key=... why=<why>` line (moca #1026), by why.
"""
import argparse
import calendar
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
for _e16 in (os.path.join(HERE, "..", "..", "e16-low-duty", "analysis"), os.path.join(HERE, "..", "..", "e16", "analysis")):
    if os.path.isfile(os.path.join(_e16, "vm_age.py")):
        sys.path.insert(0, _e16)
        break

import latency_report as LR  # noqa: E402
import lease_ends as LE  # noqa: E402
import vm_age_lease as VL  # noqa: E402
import warmcold as W  # noqa: E402
import warmcold_lease as WL  # noqa: E402

SERVER = "l2srv"
REQUERY = "py_requery"
AFTER_S = 45.0
SKIP_SYNC = ("sandbox_deleted", "teardown_failed")
PROCS_RE = re.compile(r" processes=\[(?P<p>[^\]]*)\]\s*$")
SYNC_RE = re.compile(r'vmpool: lease end sync workspace_key="(?P<key>(?:[^"\\]|\\.)*)" vm=(?P<vm>[^:\s]+):')
REFUSAL_RE = re.compile(r'vmpool: memory-budget refusal workspace_key="(?P<key>(?:[^"\\]|\\.)*)" why=(?P<why>\S+)')
TS_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)")


def stats(xs):
    return LR.stats(xs)


def read_tail(d):
    return LE.read_jsonl(os.path.join(d, "lease-tail.jsonl"))


# --- restarts and shares ---------------------------------------------------------------------------------------

def prev_end_reason(c, first_call):
    ends = [e for e in c.get("lease_events") or [] if e.get("state") == "end"]
    if ends:
        return ends[-1].get("reason")
    return "first" if (c.get("first_lease") or c.get("call") == first_call) else None


def restarts(calls):
    first = {}
    for c in calls:
        k = c.get("session")
        first[k] = min(first.get(k, c.get("call")), c.get("call"))
    rs = []
    for c in sorted(calls, key=lambda c: (str(c.get("session")), c.get("call"))):
        if not c.get("restart"):
            continue
        kind = c.get("restart_kind")
        rs.append({"session": c.get("session"), "call": c.get("call"), "class": c.get("class"), "kind": kind,
                   "observed_ms": c.get("observed_ms"), "start_ms": c.get("start_ms"), "status": c.get("status"),
                   "cause": c.get("cause"), "in_window": bool(c.get("in_window")),
                   "prev_end_reason": prev_end_reason(c, first[c.get("session")]) if kind == "lease_cold" else None})
    by_kind = {}
    for kind in LR.RESTART_KINDS:
        ks = [r for r in rs if r["kind"] == kind]
        st = stats([r["observed_ms"] for r in ks if r["observed_ms"] is not None])
        st["start_median_ms"] = LR.H.median([r["start_ms"] for r in ks if r["start_ms"] is not None])
        by_kind[kind] = st
    reasons = {}
    for r in rs:
        if r["prev_end_reason"] is not None:
            reasons[r["prev_end_reason"]] = reasons.get(r["prev_end_reason"], 0) + 1
    return {"total": len(rs), "by_kind": by_kind, "calls": rs, "prev_end_reasons": reasons}


def cold_share(d):
    rows, _ = WL.join(d)
    rs = [r for r in rows if r["in_window"] and r["warm"] in (True, False)]
    cold = sum(r["warm"] is False for r in rs)
    return {"cold": cold, "calls": len(rs), "share": (cold / float(len(rs))) if rs else None}


def server_lost_rate(d, calls):
    rows, _ = WL.join(d)
    cm = {(c.get("session"), c.get("call")): c for c in calls}
    live = [r for r in rows if r["class"] == REQUERY and r["in_window"] and r["warm"] is True]
    lost = sum((cm.get((r["session"], r["call"])) or {}).get("restart_kind") == "server_lost" for r in live)
    return {"server_lost": lost, "live_requeries": len(live), "rate": (lost / float(len(live))) if live else None}


# --- the level-2 charge ----------------------------------------------------------------------------------------

def lease_charges(d):
    """(valid, reason, [lease readings]) for d: each lease VM's vm_fp at +45 s after its last Exec."""
    m = VL.mapping(d)
    if m["error"] is not None:
        return False, m["error"], None
    if m["reasons"]:
        return False, "mapping not valid: " + "; ".join(m["reasons"]), None
    if not any(isinstance(r.get("vm_fp"), dict) for r in m["samples"]):
        return False, "the samples carry no vm_fp (not an E17c/E17d sampler)", None
    vms, times = m["vms"], m["times"]
    keep = {v["id"] for v in vms if v["lease"]}
    fp = VL.attribute(d, vms, times, keep, m["samples"], "vm_fp")[0]
    calls = W.read_calls(d)
    rows, _ = WL.join(d)
    last = VL.last_exec_ends(rows, calls, m["wl_events"])
    end_of = {v["id"]: (times[v["end_i"]] if v["end_i"] is not None else None) for v in vms}
    trace = {c.get("session"): c.get("trace") for c in calls}
    first_send = {}
    for c in calls:
        t = W.call_epoch(c.get("ts"))
        k = c.get("session")
        if t is not None and (k not in first_send or t < first_send[k]):
            first_send[k] = t
    occ, seen = {}, {}
    for k in sorted(first_send, key=lambda k: (first_send[k], k)):
        tr = trace.get(k)
        seen[tr] = seen.get(tr, 0) + 1
        occ[k] = seen[tr]
    out, ordinal = [], {}
    with W.open_rung_file(d, "worker.log") as f:
        for line in f:
            s = WL.START_RE.search(line)
            if not s or s.group("vm") not in keep:
                continue
            key, vm = s.group("key"), s.group("vm")
            ordinal[key] = ordinal.get(key, 0) + 1
            e = {"session": key, "vm": vm, "trace": trace.get(key), "occurrence": occ.get(key), "lease": ordinal[key],
                 "last_exec_end": last.get(vm), "fp_45s_bytes": None, "why_null": None}
            if e["last_exec_end"] is None:
                e["why_null"] = "the lease has no Exec"
            else:
                t = e["last_exec_end"] + AFTER_S
                if end_of.get(vm) is not None and end_of[vm] < t:
                    e["why_null"] = "the VM ended before +45 s"
                else:
                    e["fp_45s_bytes"] = VL._nearest(fp.get(vm, []), t, VL.SAMPLE_TOL_S)
                    if e["fp_45s_bytes"] is None:
                        e["why_null"] = "no vm_fp sample within 1 s of +45 s"
            out.append(e)
    return True, None, out


def charge(d, paired=None):
    ok, why, leases = lease_charges(d)
    res = {"valid": ok, "reason": why, "leases": leases, "median_fp_45s_bytes": None,
           "paired_valid": None, "paired_reason": None, "paired_median_fp_45s_bytes": None}
    if not ok:
        return res
    res["median_fp_45s_bytes"] = LR.H.median([e["fp_45s_bytes"] for e in leases if e["fp_45s_bytes"] is not None])
    if paired:
        pok, pwhy, pl = lease_charges(paired)
        res["paired_valid"], res["paired_reason"] = pok, pwhy
        idx = {(e["trace"], e["occurrence"], e["lease"]): e for e in (pl or [])}
        for e in leases:
            p = idx.get((e["trace"], e["occurrence"], e["lease"]))
            e["paired_fp_45s_bytes"] = p["fp_45s_bytes"] if p else None
        if pok:
            res["paired_median_fp_45s_bytes"] = LR.H.median(
                [e["fp_45s_bytes"] for e in pl if e["fp_45s_bytes"] is not None])
    return res


# --- judged ends, OOM kills, refusals --------------------------------------------------------------------------

def parse_procs(text):
    """[(id, name, state)] of a lease end line's processes=[id:name:state ...] field."""
    out = []
    for part in text.split():
        bits = part.split(":")
        if len(bits) >= 3:
            out.append((bits[0], ":".join(bits[1:-1]), bits[-1]))
    return out


def read_end_lines(d):
    """Per key, its end lines in log order (carry-overs marked) with their processes, and the sync lines."""
    ends, started, syncs = {}, set(), []
    with W.open_rung_file(d, "worker.log") as f:
        for line in f:
            m = WL.START_RE.search(line)
            if m:
                started.add(m.group("key"))
                continue
            m = WL.END_RE.search(line)
            if m:
                key = m.group("key")
                p = PROCS_RE.search(line)
                ends.setdefault(key, []).append({
                    "vm": m.group("vm"), "reason": m.group("reason"), "ts": LE._ts(line),
                    "carryover": m.group("reason") == LE.WORKER_RESTART and key not in started,
                    "procs": parse_procs(p.group("p")) if p else [], "sync_line": False})
                continue
            m = SYNC_RE.search(line)
            if m:
                for e in reversed(ends.get(m.group("key"), [])):
                    if e["vm"] == m.group("vm"):
                        e["sync_line"] = True
                        break
                syncs.append({"key": m.group("key"), "vm": m.group("vm")})
    return ends, syncs


def names_server(pe):
    return any(str(p).split(" ")[0] == SERVER for p in pe.get("processes") or []) or \
        any(t.get("name") == SERVER for t in pe.get("tracked") or [])


def judged_ends(d, calls, tails):
    ends, _ = read_end_lines(d)
    log = LE.read_log(d)
    nm = LE.match_notices(log, calls, tails)
    cut = {(e["key"], e["n"]) for e in nm["ended_by_run_cut_ends"]}
    swept = {(e["key"], e["n"]) for e in nm["ended_after_sweep_ends"]}
    by_key = {}
    for c in calls:
        by_key.setdefault(c.get("session"), []).append(c)
    tail_by = {t.get("key"): t for t in tails}
    procs_at = {}
    for c in calls:
        for pe in c.get("process_events") or []:
            procs_at[(c.get("session"), pe.get("at_unix_ms"))] = pe
    for t in tails:
        p = t.get("pending") or {}
        if p and (t.get("pending_processes") or t.get("pending_tracked")):
            procs_at[(t.get("key"), p.get("at_unix_ms"))] = {"processes": t.get("pending_processes"),
                                                             "tracked": t.get("pending_tracked")}
    judged, excluded, running = [], {"skip_sync": 0, "run_cut": 0, "after_sweep": 0, "carryover": 0}, 0
    for key in sorted(ends):
        notices = []
        for c in sorted(by_key.get(key, []), key=lambda c: c.get("call", 0)):
            notices += [e for e in c.get("lease_events") or [] if e.get("state") == "end"]
        pend = (tail_by.get(key) or {}).get("pending")
        if pend and pend.get("state") == "end":
            notices.append(pend)
        uniq, sig = [], set()
        for e in notices:
            s = (e.get("at_unix_ms"), e.get("reason"))
            if e.get("at_unix_ms") and s in sig:
                continue
            sig.add(s)
            uniq.append(e)
        n = 0
        for e in ends[key]:
            if e["carryover"]:
                if any(st == "running" for _, _, st in e["procs"]):
                    running += 1
                    excluded["carryover"] += 1
                continue
            n += 1
            if not any(st == "running" for _, _, st in e["procs"]):
                continue
            running += 1
            if e["reason"] in SKIP_SYNC:
                excluded["skip_sync"] += 1
                continue
            if (key, n) in cut:
                excluded["run_cut"] += 1
                continue
            if (key, n) in swept:
                excluded["after_sweep"] += 1
                continue
            note = uniq[n - 1] if n - 1 < len(uniq) and uniq[n - 1].get("reason") == e["reason"] else None
            pe = procs_at.get((key, note.get("at_unix_ms"))) if note else None
            j = {"key": key, "n": n, "vm": e["vm"], "reason": e["reason"], "ts": e["ts"],
                 "processes": ["%s:%s:%s" % p for p in e["procs"]], "notices": 1 if note else 0,
                 "notice_at_unix_ms": note.get("at_unix_ms") if note else None,
                 "names_l2srv": bool(pe and names_server(pe)), "sync_line": e["sync_line"]}
            j["pass"] = j["notices"] == 1 and j["names_l2srv"] and not j["sync_line"]
            judged.append(j)
    return {"judged": judged, "excluded": excluded, "ends_with_running_process": running,
            "with_sync_line": sum(j["sync_line"] for j in judged),
            "pass": all(j["pass"] for j in judged) if judged else None}


def oom_kills(d, calls, tails):
    out, seen = [], set()

    def add(source, session, p, at=None):
        st, code = p.get("state"), p.get("code")
        if st != "killed" or code != 9:
            return
        k = (session, p.get("id"), p.get("pid"))
        if k in seen:
            return
        seen.add(k)
        out.append({"source": source, "session": session, "id": p.get("id"), "name": p.get("name"),
                    "pid": p.get("pid"), "state": "killed(9)", "memory_bytes": p.get("memory_bytes"), "at": at})
    for c in sorted(calls, key=lambda c: (str(c.get("session")), c.get("call"))):
        try:
            table = json.loads(c["process_list"]) if c.get("process_list") else []
        except ValueError:
            table = []
        for p in table if isinstance(table, list) else []:
            add("process_list", c.get("session"), p, c.get("ts"))
        for pe in c.get("process_events") or []:
            for p in pe.get("tracked") or []:
                add("process_events", c.get("session"), p, pe.get("at_unix_ms"))
    ends, _ = read_end_lines(d)
    for key, es in sorted(ends.items()):
        for e in es:
            for pid, name, st in e["procs"]:
                if st == "killed(9)":
                    add("lease_end", key, {"id": pid, "name": name, "state": "killed", "code": 9}, e["ts"])
    for t in tails:
        for p in t.get("processes") or []:
            add("lease_tail", t.get("key"), p)
    return out


def refusals(d):
    lines, by = [], {}
    with W.open_rung_file(d, "worker.log") as f:
        for line in f:
            m = REFUSAL_RE.search(line)
            if m:
                t = TS_RE.match(line)
                lines.append({"key": m.group("key"), "why": m.group("why"), "ts": t.group(1) if t else None})
                by[m.group("why")] = by.get(m.group("why"), 0) + 1
    return {"total": len(lines), "by_why": by, "lines": lines}


def analyse(d, paired=None):
    pp = os.path.join(d, "params.json")
    params = json.load(open(pp)) if os.path.exists(pp) else {}
    calls = W.read_calls(d)
    tails = read_tail(d)
    ks = oom_kills(d, calls, tails)
    return {
        "rung": d, "arm": params.get("arm"), "point": params.get("point"), "n": params.get("n"),
        "paired": paired,
        "restarts": restarts(calls),
        "lease_cold_share": cold_share(d),
        "paired_lease_cold_share": cold_share(paired) if paired else None,
        "server_lost_rate": server_lost_rate(d, calls),
        "charge": charge(d, paired),
        "ends": judged_ends(d, calls, tails),
        "oom_kills": ks,
        "oom_kills_l2srv": sum(k["name"] == SERVER for k in ks),
        "refusals": refusals(d),
    }


def warm_count(rungs, classes):
    """{class: pooled warm n (latency_report's warm: a live lease and no restart), "min": the smallest}."""
    rep = LR.build(rungs)
    groups = [g for g in rep["groups"] if g["arm"] != rep["baseline_arm"]]
    if len(groups) != 1:
        raise SystemExit("level2.py --warm-count: want the rungs of one lease arm, point and N, got %d group(s)" % len(groups))
    out = {c: groups[0]["classes"].get(c, {}).get("warm", {}).get("n", 0) for c in classes}
    out["min"] = min(out[c] for c in classes)
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("rungs", nargs="+")
    ap.add_argument("--paired", help="the paired ship-300 rung")
    ap.add_argument("--warm-count", metavar="CLASSES", help="comma-separated classes: print their pooled warm counts")
    a = ap.parse_args(argv)
    if a.warm_count:
        print(json.dumps(warm_count(a.rungs, a.warm_count.split(",")), sort_keys=True))
        return
    if len(a.rungs) != 1:
        raise SystemExit("usage: level2.py RUNG_DIR [--paired SHIP300_RUNG]")
    r = analyse(a.rungs[0], a.paired)
    with open(os.path.join(a.rungs[0], "level2.json"), "w") as f:
        json.dump(r, f, indent=2, sort_keys=True)
        f.write("\n")
    print("restarts %d (lease_cold %d, server_lost %d); judged ends %d pass %s; oom_kills %d; refusals %d" % (
        r["restarts"]["total"], r["restarts"]["by_kind"]["lease_cold"]["n"], r["restarts"]["by_kind"]["server_lost"]["n"],
        len(r["ends"]["judged"]), r["ends"]["pass"], len(r["oom_kills"]), r["refusals"]["total"]))
    return r


if __name__ == "__main__":
    main()
