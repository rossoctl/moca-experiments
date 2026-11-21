#!/usr/bin/env python3
"""E17b lease-aware VM age and the memory-returns reading (PLAN-E17B Task 7, spec §7.3 / criterion 5).

  python3 vm_age_lease.py RUNDIR [--sbx SBX_RUNDIR | --sbx-median-ms MS] [--guest-ram-mib N] -> RUNDIR/vm_age_lease.json
  (reads RUNDIR/shmem.json when it exists: run freed_from_shmem.py RUNDIR first)

E16's vm_age.py replays moca's cgroup allocator as a LIFO free list: every destroyed VM's cgroup name
goes back on it. A LEASE VM's does not (remote-worker/internal/vmpool/cgroup_pool.go `retire`, called from
launcher_firecracker.go Destroy when LeaseCgroup had run): its memory.max was raised to the lease bound,
so the directory is removed and the name is never reissued (`issued` is monotonic). Replaying a lease
VM's destroy as a push assigns the NEXT VM the wrong name. Here the replay retires the cgroups of VMs
that have a `lease start` line, and recycles every other VM's.

Identity (worker.log, SH_DIAG_PHASES=1; read three times per analysis, by this module, by the E16 events reader and by the warm/cold join): `vmpool: restore phases id=vm-N` is a VM birth,
`destroy phases id=vm-N` its end. Lines are replayed in log order, never by timestamp.

WHICH VMs RETIRE. launcher_firecracker.go LeaseCgroup sets `leaseCgroup` BEFORE it writes memory.max, so
a VM is promoted (cgroup retired at Destroy) from the moment LeaseCgroup runs, whatever happens next.
lease.go calls it after the VM is popped and before Resume, then logs `lease start` only at the very end,
so a lease whose start fails after promotion has no `lease start` line. The markers read, per VM:
  - `lease start ... vm=vm-N`                  : promoted AND a real lease (memory statistics, shares);
  - `lease normalise ... vm=vm-N: <why>; the lease start fails`: promoted, start failed (not a lease VM);
  - `lease cgroup ... vm=vm-N: <err>; the VM keeps the per-Exec memory bound`: promoted (the write failed
    after the mark), EXCEPT `no pooled cgroup to lease`, which returns before the mark: not promoted.
RESIDUAL: promotion with no marker in the log: a Resume failure, or a normalise cut by an abort (both
log nothing here). The replay then recycles a retired name and later names shift. That is caught, never
guessed: the samples then show a cgroup holding no live VM, and when that happens after any recycle the
result is mapping_valid=false with the extra reason `lease_start_failed_without_marker_suspected`. Also
invisible in the log, and caught only the same way: a failed restore (its cgroup is released with no
restore line) and a leaked cgroup (never reissued).

SAME-SECOND RESTORES (E17B-R53). Two restores logged in the same whole second are in the order they finished, which
need not be the order the allocator issued their names. When the samples then show a cgroup holding no live VM, the
replay swaps adjacent same-second restores, one at a time and only when the swap lowers that count, and keeps the
result only when every sample is explained (`same_second_reorders` lists the swaps); otherwise nothing changes.

MAPPING VALIDITY. `mapping_valid` is false, with `mapping_reasons`, when: a vm id is restored twice, a
destroy or a lease start or an Exec line names a vm with no restore (zero cgroups), a sampled cgroup
holds no live VM per the replay (samples.jsonl `vm_mem`, beyond a 2 s tolerance for the log's
whole-second stamps), or a VM that lived 5 s with samples in its life never shows in them. When it is
false no cgroup name, memory table or FPR number is written (null): names are never guessed. The
replacement-VM reading uses only the log and the calls, so it is kept.

MEMORY. Per lease VM with samples: memory.current against VM age (since its restore line, not its
promotion: a lease VM promoted from a standby carries its standby time), 60 s bins,
median and p95 over VMs per bin; and the share of lease VMs whose PEAK exceeds 50% and 90% of guest RAM.

MEMORY RETURNS (criterion 5, first half). Per heavy Exec (class in HEAVY_CLASSES, one Exec, on a lease
VM): memory.current at the Exec's end (the sample nearest it, within 1 s), 15 s later, the peak over
the Exec (samples from its send to its end) and its start (the last sample at or before its send, within
1 s). The Exec's end = calls.jsonl `ts` + observed_ms. The guest's FREED amount (ruling E17B-R22):

    freed = max(0, peak - start - dShmem)

where dShmem is the guest's tmpfs growth behind the call, from the `py_shmem` readings (rulings E17B-R23..R25):
RUNDIR/shmem.json `calls` = {"session:call": dShmem bytes or null}, written by freed_from_shmem.py. Its
docstring has the rule: 0 for every heavy call of a turn whose measured Shmem delta is within 1 MiB in a
session the corpus did not flag tmpfs, null otherwise, always null in a lease's first turn (no measured
base) and always null in a flagged session (whose per-turn growth shmem.json reports under `turns`). HEAVY_CLASSES stays py_analyze and py_test, py_shmem is only the source of
dShmem. Tmpfs is guest RAM held until the VM goes, so that growth is not freed. VERDICT
"charge follows the working set": value_15s <= peak - freed/2. With no shmem.json, or a null or missing
dShmem, freed is null and the verdict is null, never false; the raw numbers are still reported. The
verdict is also null when the 15 s sample or the start sample is missing, the VM ended first, or the
session's next call began within 15 s (the later Exec's charge is not "falling back"; a reported-only call,
the turn's py_shmem reading right after its last py_analyze, is not a next call).

NON-VACUITY (ruling E17B-R29). A VM that is already pinned near its ceiling by an earlier heavy call
(E17a's failure: free-page reporting returned nothing) has start ~ peak, so freed ~ 0 and the verdict
reads "value_15s <= peak": a pass for a VM that never gave anything back. So an Exec is judged only when
its growth, peak - start, is at least GROWTH_MIN_BYTES (64 MiB); a smaller one is `not_judged_low_growth`
(why_null), counted beside share_true. And an ABSOLUTE reading that cannot be vacuous is reported: per
heavy Exec, ceiling_ratio_15s = value_15s / guest RAM (the VM's ceiling: params snapshot_guest_ram_mb or
--guest-ram-mib), and `absolute.pinned_share`, the share of readings at or above 0.9 of guest RAM. A
reading needs only the +15 s sample and no next call within 15 s (otherwise the value is the next call's
charge), not dShmem or growth, so it covers the low-growth and first-turn Execs the relative verdict
leaves out: that is where a pinned VM shows. `pinned_share_of_judged` is the same share over the judged
Execs only; `per_vm` has each lease VM's highest ratio. No pass threshold is set here: it is sealed with
the predictions (Task 13), and this module reports the numbers.

E17C FOOTPRINT READINGS (PLAN-E17C Task 6, spec §13.3 reading 1). An E17c sample line carries, beside
`vm_mem`, `vm_fp` (the worker's footprint, LeaseBytes' formula) and `vm_dirty` (file_dirty), keyed by the same
cgroup names and attributed by the same replay. A VM missing from `vm_fp` (or `vm_dirty`) in a line is no reading
there (null), never 0; the two key sets may differ. Per heavy Exec, beside E17b's fields: fp_15s_bytes and
dirty_15s_bytes at +15 s; fp_45s_bytes, mem_45s_bytes and dirty_45s_bytes at a FIXED +45 s after the Exec's end
for every arm (ruling R-o), null when the session's next call began within 45 s (why_null_45s) or no sample is
within 1 s; fp_ceiling_ratio_15s (null when the next call began within 15 s, as ceiling_ratio_15s) and
fp_ceiling_ratio_45s. E17b-R29's relative rule runs again on vm_fp (fp_start/peak/growth/freed_bytes,
follows_fp, why_null_fp; the same dShmem; share_true_fp beside share_true). IDLE TAIL: per lease ended by a
`lease end ... reason=idle` line, its vm_fp in the last sample line before that end (the log's whole second),
provided that line is at least 45 s after the end of the lease's last Exec (the latest of its calls' ends and its
exec lines); otherwise its fp_bytes is null with why_null. Summaries: pinned_share_fp_15s, pinned_share_fp_45s,
pinned_share_fp_idle_tail (share of readings at or above 0.9 of guest RAM, over every reading as E17b's
absolute.pinned_share), with their readings and pinned counts, and the _of_judged variants of the first two
(over the Execs follows_fp judged). A rung whose samples carry no vm_fp at all (every E17b rung) gets none of
these fields: its output is E17b's, byte for byte.

REPLACEMENT VM (criterion 5, second half). A lease whose first call is cold with reason `idle` (the key's
previous lease ended by the idle timeout; warmcold_lease.py's cold_reason): its first ok `py_grep`
observed_ms against the median ok `py_grep` of the `sbx` rung (--sbx) or --sbx-median-ms. Only calls with
in_window true count, on both sides. A VM whose first call is unknown (the join could not place it) has a null
replacement reading: listed under unknown_leases (replacement_unknown counts them), never read as "not a
replacement" from a later call.
"""
import argparse
import bisect
import calendar
import json
import math
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
# E16's analysis, in this repo (experiments/e16-low-duty/analysis) or in the rig's staged layout (/srv/e15/src/e16).
for _e16 in (os.path.join(HERE, "..", "..", "e16-low-duty", "analysis"), os.path.join(HERE, "..", "..", "e16", "analysis")):
    if os.path.isfile(os.path.join(_e16, "vm_age.py")):
        sys.path.insert(0, _e16)
        break

import vm_age as V  # noqa: E402  (E16's reader and helpers, unchanged)
import warmcold as W  # noqa: E402
import warmcold_lease as WL  # noqa: E402

BIN_S = 60
TOL_S = 2.0
MIN_LIFE_S = 5.0
SAMPLE_TOL_S = 1.0
AFTER_S = 15.0
AFTER_DROP_S = 45.0  # ruling R-o: the post-drop reading, fixed for every arm (SH_LEASE_CACHE_DROP_S 30 + 15)
HEAVY_CLASSES = ("py_analyze", "py_test")
GROWTH_MIN_BYTES = 64 << 20  # E17B-R29: less growth than this has nothing to return; not judged
PINNED_FRACTION = 0.9        # E17B-R29: a +15 s charge at or above this share of guest RAM is pinned
LOW_GROWTH = "not_judged_low_growth"
LINE_RE = re.compile(
    r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})Z vmpool: (?:(restore|destroy) phases id=(vm-\d+) "
    r"|lease start workspace_key=\"(?:[^\"\\]|\\.)*\" vm=(?P<start>\S+) "
    r"|lease normalise workspace_key=\"(?:[^\"\\]|\\.)*\" vm=(?P<norm>vm-\d+): "
    r"|lease cgroup workspace_key=\"(?:[^\"\\]|\\.)*\" vm=(?P<cg>vm-\d+): (?P<cgerr>.*))")
NO_POOLED = "no pooled cgroup to lease"


def read_log(d):
    """One pass over worker.log. Returns (events [(epoch s, "restore"|"destroy", vm id)] in log order,
    started: vm ids with a `lease start` line, retired: vm ids whose cgroup LeaseCgroup promoted per the
    markers in the module docstring). Raises SystemExit when there are no restore lines."""
    events, started, norm, cg, nopool = [], set(), set(), set(), set()
    with V._open(d, "worker.log") as f:
        for line in f:
            m = LINE_RE.match(line)
            if not m:
                continue
            if m.group(2):
                ts = float(calendar.timegm(time.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S")))
                events.append((ts, m.group(2), m.group(3)))
            elif m.group("start"):
                started.add(m.group("start"))
            elif m.group("norm"):
                norm.add(m.group("norm"))
            elif NO_POOLED in m.group("cgerr"):
                nopool.add(m.group("cg"))
            else:
                cg.add(m.group("cg"))
    if not any(k == "restore" for _, k, _ in events):
        raise SystemExit("no 'restore phases' lines in worker.log (SH_DIAG_PHASES=1 is needed)")
    return events, started, (started | norm | cg) - nopool


def vm_table_lease(events, retired_ids, started=None):
    """Replay (kind, vm) events through the allocator with promoted (retired_ids) cgroups retired.
    `started` (default: retired_ids) are the VMs that are real leases. Returns (vms [{id, name, lease,
    retired, born_i, end_i}], problems [str], recycled: names popped off the free list). Only order matters."""
    started = retired_ids if started is None else started
    free, issued, live, seen, vms, problems, recycled = [], 0, {}, set(), [], [], 0
    for i, (kind, vid) in enumerate(events):
        if kind == "restore":
            if vid in seen:
                problems.append("%s restored twice (event %d)" % (vid, i))
                continue
            seen.add(vid)
            if free:
                name = free.pop()
                recycled += 1
            else:
                name, issued = "pool-%d" % issued, issued + 1
            v = {"id": vid, "name": name, "lease": vid in started, "retired": vid in retired_ids,
                 "born_i": i, "end_i": None}
            live[vid] = v
            vms.append(v)
        else:
            v = live.pop(vid, None)
            if v is None:
                problems.append("%s destroyed with no live restore (event %d)" % (vid, i))
                continue
            v["end_i"] = i
            if not v["retired"]:
                free.append(v["name"])
    for vid in sorted((retired_ids | started) - seen):
        problems.append("a lease marker names %s, which has no restore line" % vid)
    return vms, problems, recycled


def resolve_same_second(events, retired, started, d, samples):
    """E17B-R53: restores logged in the same whole second are in log order, which need not be the order the
    allocator issued their cgroup names (two concurrent restores: the one that finishes first logs first). When
    the replay leaves samples in a cgroup that holds no live VM, swap ADJACENT restore events that share a second,
    keeping a swap only when it lowers that count, until none is left or no swap helps. Returns (events, swaps
    [(vm, vm, epoch)]); the caller accepts the result only when nothing is left unattributed."""
    def unatt_count(evs):
        vms, _, _ = vm_table_lease([(k, v) for _, k, v in evs], retired, started)
        _, _, un, _ = attribute(d, vms, [t for t, _, _ in evs], set(), samples)
        return len(un)
    best, swaps = list(events), []
    cur = unatt_count(best)
    while cur:
        improved = False
        for i in range(len(best) - 1):
            a, b = best[i], best[i + 1]
            if a[1] == b[1] == "restore" and a[0] == b[0]:
                cand = best[:i] + [b, a] + best[i + 2:]
                n = unatt_count(cand)
                if n < cur:
                    best, cur, improved = cand, n, True
                    swaps.append((a[2], b[2], a[0]))
                    break
        if not improved:
            break
    return best, swaps


def _nearest(series, t, tol):
    """Value of the sample of [(ts, val)] (sorted) closest to t, within tol; else None."""
    i = bisect.bisect_left(series, (t,))
    best = None
    for j in (i - 1, i):
        if 0 <= j < len(series) and abs(series[j][0] - t) <= tol:
            if best is None or abs(series[j][0] - t) < abs(best[0] - t):
                best = series[j]
    return None if best is None else best[1]


def attribute(d, vms, times, keep, samples=None, field="vm_mem"):
    """Attribute each sample of each cgroup name (in the line's `field`, default vm_mem) to the VM that held
    the name then.
    Returns (obs {vm id: [(ts, val)]} for the VMs in `keep` only, seen {vm id: number of samples},
    unattributed [(ts, name)], sample_ts sorted). `samples` (pre-read rows) saves re-reading samples.jsonl."""
    by_name = {}
    for v in vms:
        by_name.setdefault(v["name"], []).append(v)
    for vs in by_name.values():
        vs.sort(key=lambda v: times[v["born_i"]])
    borns = {n: [times[v["born_i"]] - TOL_S for v in vs] for n, vs in by_name.items()}
    obs = {i: [] for i in keep}
    seen = {v["id"]: 0 for v in vms}
    unatt, rows = [], []
    for r in (V.read_samples(d) if samples is None else samples):
        ts = r.get("ts")
        if ts is None:
            continue
        rows.append(ts)
        for name, val in (r.get(field) or {}).items():
            if val is None:
                continue
            i = bisect.bisect_right(borns.get(name, []), ts) - 1
            v = by_name[name][i] if i >= 0 else None
            if v is None or (v["end_i"] is not None and ts > times[v["end_i"]] + TOL_S):
                unatt.append((ts, name))
                continue
            seen[v["id"]] += 1
            if v["id"] in obs:
                obs[v["id"]].append((ts, val))
    for s in obs.values():
        s.sort()
    rows.sort()
    return obs, seen, unatt, rows


def _median(xs):
    return V._median(xs)


def mem_vs_age(lease_vms, obs, born_ts):
    bins = {}
    for v in lease_vms:
        per = {}
        for ts, val in obs[v["id"]]:
            per.setdefault(int(max(0.0, ts - born_ts[v["id"]]) // BIN_S) * BIN_S, []).append(val / float(1 << 20))
        for b, xs in per.items():
            bins.setdefault(b, []).append(_median(xs))
    keys = sorted(bins)
    return {"bin_s": BIN_S, "age": "seconds since the VM's restore line, not its promotion (a lease VM promoted from a standby carries its standby time)",
            "bins_s": keys, "vms_per_bin": [len(bins[b]) for b in keys],
            "median_mib": [_median(bins[b]) for b in keys], "p95_mib": [V._p95(bins[b]) for b in keys]}


def share_above(lease_vms, obs, guest_ram_mib):
    peaks = [max(val for _, val in obs[v["id"]]) / float(1 << 20) for v in lease_vms if obs[v["id"]]]
    n = len(peaks)
    out = {"guest_ram_mib": guest_ram_mib, "lease_vms": n, "basis": "peak memory.current of each lease VM"}
    for pct in (50, 90):
        k = sum(p > guest_ram_mib * pct / 100.0 for p in peaks)
        out["above_%d_pct" % pct] = {"vms": k, "share": (k / float(n)) if n else None}
    return out


def _at_or_before(series, t, tol):
    """Value of the last sample of [(ts, val)] (sorted) at or before t, within tol; else None."""
    i = bisect.bisect_right(series, (t, math.inf)) - 1
    return series[i][1] if i >= 0 and t - series[i][0] <= tol else None


FREED_DEFINITION = "freed = max(0, peak - start - dShmem); follows: value_15s <= peak - freed/2"


def absolute_reading(out, guest_ram_bytes):
    """The E17B-R29 absolute reading over the heavy Execs that have a ceiling_ratio_15s."""
    got = [e for e in out if e["ceiling_ratio_15s"] is not None]
    judged = [e for e in got if e["follows"] is not None]

    def pinned(es):
        return sum(e["ceiling_ratio_15s"] >= PINNED_FRACTION for e in es)
    per = {}
    for e in got:
        per.setdefault(e["vm"], []).append(e["ceiling_ratio_15s"])
    per_vm = [{"vm": vm, "readings": len(xs), "max_ceiling_ratio_15s": max(xs),
               "pinned": max(xs) >= PINNED_FRACTION} for vm, xs in sorted(per.items())]
    n_pin, n_jpin, n_vpin = pinned(got), pinned(judged), sum(v["pinned"] for v in per_vm)
    return {"guest_ram_bytes": guest_ram_bytes, "pinned_fraction": PINNED_FRACTION,
            "basis": "value_15s / guest RAM per heavy Exec with a +15 s sample and no next call within 15 s "
                     "(growth and dShmem not needed)",
            "readings": len(got), "pinned": n_pin, "pinned_share": (n_pin / float(len(got))) if got else None,
            "judged_readings": len(judged),
            "pinned_share_of_judged": (n_jpin / float(len(judged))) if judged else None,
            "per_vm": per_vm, "pinned_vms": n_vpin,
            "pinned_vm_share": (n_vpin / float(len(per_vm))) if per_vm else None}


def _fp_reading(e, end, start, fs, ds, obs_s, nxt, guest_ram_bytes):
    """The E17c fields of one heavy Exec `e` (E17B-R29's rules, on vm_fp)."""
    e["fp_15s_bytes"] = _nearest(fs, end + AFTER_S, SAMPLE_TOL_S)
    e["dirty_15s_bytes"] = _nearest(ds, end + AFTER_S, SAMPLE_TOL_S)
    near15 = nxt is not None and nxt < end + AFTER_S
    near45 = nxt is not None and nxt < end + AFTER_DROP_S
    if not near45:
        e["fp_45s_bytes"] = _nearest(fs, end + AFTER_DROP_S, SAMPLE_TOL_S)
        e["mem_45s_bytes"] = _nearest(obs_s, end + AFTER_DROP_S, SAMPLE_TOL_S)
        e["dirty_45s_bytes"] = _nearest(ds, end + AFTER_DROP_S, SAMPLE_TOL_S)
    if near45:
        e["why_null_45s"] = "the session's next call began within 45 s"
    elif e["fp_45s_bytes"] is None:
        e["why_null_45s"] = ("no sample at +45 s (VM ended?)" if e["mem_45s_bytes"] is None else
                             "the VM is not in vm_fp at +45 s (its memory.stat lacked a field)")
    if e["fp_15s_bytes"] is not None and not near15:
        e["fp_ceiling_ratio_15s"] = e["fp_15s_bytes"] / float(guest_ram_bytes)
    if e["fp_45s_bytes"] is not None:
        e["fp_ceiling_ratio_45s"] = e["fp_45s_bytes"] / float(guest_ram_bytes)
    within = [val for ts, val in fs if start <= ts <= end]
    e["fp_peak_bytes"] = max(within) if within else None
    e["fp_start_bytes"] = _at_or_before(fs, start, SAMPLE_TOL_S)
    if None not in (e["fp_peak_bytes"], e["fp_start_bytes"]):
        e["fp_growth_bytes"] = e["fp_peak_bytes"] - e["fp_start_bytes"]
        if e["delta_shmem_bytes"] is not None:
            e["fp_freed_bytes"] = max(0, e["fp_growth_bytes"] - e["delta_shmem_bytes"])
    if e["fp_15s_bytes"] is None or e["fp_peak_bytes"] is None:
        e["why_null_fp"] = "no vm_fp at +15 s (VM ended, or not in vm_fp) or within the Exec"
    elif near15:
        e["why_null_fp"] = "the session's next call began within 15 s"
    elif e["fp_start_bytes"] is None:
        e["why_null_fp"] = "no vm_fp at or before the Exec's start"
    elif e["fp_growth_bytes"] < GROWTH_MIN_BYTES:
        e["why_null_fp"] = LOW_GROWTH
    elif e["delta_shmem_bytes"] is None:
        e["why_null_fp"] = "no dShmem (see why_null)"
    else:
        e["follows_fp"] = e["fp_15s_bytes"] <= e["fp_peak_bytes"] - e["fp_freed_bytes"] / 2.0


FP_FIELDS = ("fp_15s_bytes", "fp_45s_bytes", "mem_45s_bytes", "dirty_15s_bytes", "dirty_45s_bytes",
             "fp_ceiling_ratio_15s", "fp_ceiling_ratio_45s", "why_null_45s", "fp_start_bytes", "fp_peak_bytes",
             "fp_growth_bytes", "fp_freed_bytes", "follows_fp", "why_null_fp")


def _share(es, key):
    got = [e for e in es if e[key] is not None]
    n = sum(e[key] >= PINNED_FRACTION for e in got)
    return len(got), n, (n / float(len(got))) if got else None


def fp_summary(out, idle_tail):
    """The E17c summaries over the heavy Execs `out` and the idle-tail list."""
    judged = [e for e in out if e["follows_fp"] is not None]
    n_t = sum(e["follows_fp"] is True for e in out)
    n_f = sum(e["follows_fp"] is False for e in out)
    s = {"fp_basis": "vm_fp (the worker's footprint) / guest RAM; pinned at or above pinned_fraction %.1f; +15 s "
                     "readings need no next call within 15 s, +45 s (fixed, R-o) none within 45 s; idle tail: "
                     "last sample before an idle lease end, at least 45 s after the lease's last Exec"
                     % PINNED_FRACTION,
         "after_drop_s": AFTER_DROP_S,
         "follows_fp_true": n_t, "follows_fp_false": n_f, "follows_fp_null": len(out) - n_t - n_f,
         "not_judged_low_growth_fp": sum(e["why_null_fp"] == LOW_GROWTH for e in out),
         "share_true_fp": (n_t / float(n_t + n_f)) if n_t + n_f else None,
         "idle_tail": idle_tail, "idle_tail_leases": len(idle_tail)}
    for tag in ("15s", "45s"):
        key = "fp_ceiling_ratio_" + tag
        s["fp_%s_readings" % tag], s["fp_%s_pinned" % tag], s["pinned_share_fp_" + tag] = _share(out, key)
        s["fp_%s_judged_readings" % tag], _, s["pinned_share_fp_%s_of_judged" % tag] = _share(judged, key)
    s["fp_idle_tail_readings"], s["fp_idle_tail_pinned"], s["pinned_share_fp_idle_tail"] = \
        _share(idle_tail, "fp_ceiling_ratio")
    return s


def fpr_reading(rows, calls, obs, vm_by_id, shmem, guest_ram_bytes=1024 << 20, fp_obs=None, dirty_obs=None,
                idle_tail=None):
    """E17b's reading; with fp_obs (a rung whose samples carry vm_fp) also the E17c fields and summaries."""
    by_key = {}
    for c in calls:
        by_key.setdefault(c.get("session"), []).append(c)
    next_start = {}
    for k, cs in by_key.items():
        cs = sorted((c for c in cs if c.get("class") not in WL.REPORTED_ONLY), key=lambda c: c.get("call"))
        for a, b in zip(cs, cs[1:]):
            next_start[(k, a.get("call"))] = W.call_epoch(b.get("ts"))
    cmap = {(c.get("session"), c.get("call")): c for c in calls}
    out = []
    for r in rows:
        if r["class"] not in HEAVY_CLASSES:
            continue
        c = cmap[(r["session"], r["call"])]
        e = {"session": r["session"], "call": r["call"], "class": r["class"], "vm": r["vm"],
             "end_bytes": None, "after_15s_bytes": None, "peak_bytes": None, "start_bytes": None,
             "delta_shmem_bytes": None, "freed_bytes": None, "growth_bytes": None, "ceiling_ratio_15s": None,
             "follows": None, "why_null": None}
        if fp_obs is not None:
            e.update({k: None for k in FP_FIELDS})
        out.append(e)
        v = vm_by_id.get(r["vm"])
        if c.get("execs") != 1 or v is None or not v["lease"]:
            e["why_null"] = "not a single-Exec call on a lease VM"
            if fp_obs is not None:
                e["why_null_45s"] = e["why_null_fp"] = e["why_null"]
            continue
        start = W.call_epoch(c.get("ts"))
        if start is None or c.get("observed_ms") is None:
            e["why_null"] = "call has no usable send time or duration"
            if fp_obs is not None:
                e["why_null_45s"] = e["why_null_fp"] = e["why_null"]
            continue
        end = start + c["observed_ms"] / 1000.0
        s = obs[r["vm"]]
        e["end_bytes"] = _nearest(s, end, SAMPLE_TOL_S)
        e["after_15s_bytes"] = _nearest(s, end + AFTER_S, SAMPLE_TOL_S)
        within = [val for ts, val in s if start <= ts <= end]
        e["peak_bytes"] = max(within) if within else None
        e["start_bytes"] = _at_or_before(s, start, SAMPLE_TOL_S)
        e["delta_shmem_bytes"] = ((shmem or {}).get("calls") or {}).get("%s:%s" % (r["session"], r["call"]))
        if None not in (e["peak_bytes"], e["start_bytes"], e["delta_shmem_bytes"]):
            e["freed_bytes"] = max(0, e["peak_bytes"] - e["start_bytes"] - e["delta_shmem_bytes"])
        if None not in (e["peak_bytes"], e["start_bytes"]):
            e["growth_bytes"] = e["peak_bytes"] - e["start_bytes"]
        nxt = next_start.get((r["session"], r["call"]))
        near = nxt is not None and nxt < end + AFTER_S
        if e["after_15s_bytes"] is not None and not near:
            e["ceiling_ratio_15s"] = e["after_15s_bytes"] / float(guest_ram_bytes)
        if e["after_15s_bytes"] is None or e["peak_bytes"] is None:
            e["why_null"] = "no sample at +15 s (VM ended?) or within the Exec"
        elif near:
            e["why_null"] = "the session's next call began within 15 s"
        elif e["start_bytes"] is None:
            e["why_null"] = "no sample at or before the Exec's start"
        elif e["growth_bytes"] < GROWTH_MIN_BYTES:
            e["why_null"] = LOW_GROWTH
        elif e["delta_shmem_bytes"] is None:
            e["why_null"] = "no dShmem (shmem.json absent, or null for this call: a tmpfs session, or a turn " \
                            "without a usable delta or over 1 MiB; freed_from_shmem.py)"
        else:
            e["follows"] = e["after_15s_bytes"] <= e["peak_bytes"] - e["freed_bytes"] / 2.0
        if fp_obs is not None:
            _fp_reading(e, end, start, fp_obs.get(r["vm"], []), (dirty_obs or {}).get(r["vm"], []), s, nxt,
                        guest_ram_bytes)
    n_t = sum(e["follows"] is True for e in out)
    n_f = sum(e["follows"] is False for e in out)
    res = {"definition": FREED_DEFINITION, "heavy_classes": list(HEAVY_CLASSES),
            "growth_min_bytes": GROWTH_MIN_BYTES,
            "judged_when": "peak - start >= growth_min_bytes (E17B-R29), with dShmem, start, +15 s samples "
                           "and no next call within 15 s",
            "heavy_execs": len(out), "follows_true": n_t, "follows_false": n_f,
            "follows_null": len(out) - n_t - n_f,
            "not_judged_low_growth": sum(e["why_null"] == LOW_GROWTH for e in out),
            "share_true": (n_t / float(n_t + n_f)) if n_t + n_f else None,
            "absolute": absolute_reading(out, guest_ram_bytes), "execs": out}
    if fp_obs is not None:
        res.update(fp_summary(out, idle_tail or []))
    return res


def read_lease_ends(d):
    """[(epoch s, key, vm, reason)] of worker.log's `lease end` lines, in log order (the relay probe's key
    left out)."""
    out = []
    with W.open_rung_file(d, "worker.log") as f:
        for line in f:
            m = WL.END_RE.search(line)
            t = W.LOG_TS_RE.match(line) if m else None
            if m and t and m.group("key") != W.PROBE_KEY:
                out.append((float(calendar.timegm(time.strptime(t.group(1), "%Y-%m-%dT%H:%M:%S"))),
                            m.group("key"), m.group("vm"), m.group("reason")))
    return out


def last_exec_ends(rows, calls, wl_events):
    """{vm id: epoch s of the end of its last Exec}: the latest of its calls' ends (send + observed_ms, the
    calls the join placed on it) and its exec lines' stamps."""
    cmap = {(c.get("session"), c.get("call")): c for c in calls}
    last = {}

    def see(vm, t):
        if vm and t is not None and (vm not in last or t > last[vm]):
            last[vm] = float(t)
    for r in rows:
        c = cmap.get((r["session"], r["call"])) or {}
        t = W.call_epoch(c.get("ts"))
        if t is not None and c.get("observed_ms") is not None:
            see(r["vm"], t + c["observed_ms"] / 1000.0)
    for ev in wl_events.values():
        for e in ev:
            if e["kind"] == "exec":
                see(e["vm"], e.get("ts"))
    return last


def idle_tail_reading(ends, lease_ids, last_end, fp_obs, sample_ts, guest_ram_bytes):
    """Per lease ended `idle`: its vm_fp in the last sample line before the end, when that line is at least
    AFTER_DROP_S after the lease's last Exec; else fp_bytes null with why_null."""
    out = []
    for t_end, key, vm, reason in ends:
        if reason != "idle" or vm not in lease_ids:
            continue
        e = {"vm": vm, "session": key, "end": t_end, "sample_ts": None, "last_exec_end": last_end.get(vm),
             "fp_bytes": None, "fp_ceiling_ratio": None, "why_null": None}
        out.append(e)
        i = bisect.bisect_left(sample_ts, t_end) - 1
        if i < 0:
            e["why_null"] = "no sample line before the end"
            continue
        e["sample_ts"] = sample_ts[i]
        if e["last_exec_end"] is None:
            e["why_null"] = "the lease has no Exec"
        elif e["sample_ts"] - e["last_exec_end"] < AFTER_DROP_S:
            e["why_null"] = "the last sample before the end is under 45 s after the lease's last Exec"
        else:
            e["fp_bytes"] = dict(fp_obs.get(vm, [])).get(e["sample_ts"])
            if e["fp_bytes"] is None:
                e["why_null"] = "the VM is not in vm_fp in the last sample line before the end"
            else:
                e["fp_ceiling_ratio"] = e["fp_bytes"] / float(guest_ram_bytes)
    return out


def sbx_median_grep(d):
    xs = [c["observed_ms"] for c in W.read_calls(d)
          if c.get("class") == "py_grep" and c.get("status") == "ok" and c.get("in_window")
          and c.get("observed_ms") is not None]
    return _median(xs) if xs else None


def replacement_reading(rows, sbx_median):
    by_sess = {}
    for r in rows:
        by_sess.setdefault(r["session"], []).append(r)
    leases = []
    for key in sorted(by_sess):
        seen = {}
        for r in sorted(by_sess[key], key=lambda r: r["call"]):
            if r["vm"] and r["warm"] in (True, False, "unknown"):
                if r["vm"] not in seen:
                    # The VM's FIRST call says whether it replaced an idle lease. When that call is unknown the
                    # answer is not known: null, never "not a replacement" from a later call (PR #34 nit).
                    seen[r["vm"]] = {"session": key, "vm": r["vm"],
                                     "replacement": None if r["warm"] == "unknown" else r["cold_reason"] == "idle",
                                     "first_grep_ms": None}
                    leases.append(seen[r["vm"]])
                l = seen[r["vm"]]
                if r["warm"] in (True, False) and l["first_grep_ms"] is None and r["class"] == "py_grep" \
                        and r["status"] == "ok" and r["in_window"]:
                    l["first_grep_ms"] = r["observed_ms"]
    rep = [l for l in leases if l["replacement"] is True]
    unknown = [l for l in leases if l["replacement"] is None]
    got = [l for l in rep if l["first_grep_ms"] is not None]
    med = _median([l["first_grep_ms"] for l in got]) if got else None
    return {"replacement_leases": len(rep), "with_first_py_grep": len(got), "leases": rep,
            "replacement_unknown": len(unknown), "unknown_leases": unknown,
            "median_first_py_grep_ms": med, "sbx_median_py_grep_ms": sbx_median,
            "ratio_to_sbx": (med / sbx_median) if med is not None and sbx_median else None}


def analyse(d, sbx_median_ms=None, shmem=None, guest_ram_mib=None):
    params = {}
    if os.path.exists(os.path.join(d, "params.json")):
        params = json.load(open(os.path.join(d, "params.json")))
    arm = params.get("arm")
    if guest_ram_mib is None:
        guest_ram_mib = params.get("snapshot_guest_ram_mb") or 1024
    out = {"rung": d, "arm": arm, "mapping_valid": False, "mapping_reasons": [], "vms": None,
           "memory_vs_age": None, "share_above": None, "fpr": None, "replacement": None,
           "rules": {"identity": "worker.log restore/destroy phases; lease VMs (lease start line) retire "
                                 "their cgroup (cgroup_pool.go retire), all others recycle it LIFO",
                     "tolerance_s": TOL_S, "bin_s": BIN_S}}
    try:
        events, started, retired = read_log(d)
    except SystemExit as e:
        out["mapping_reasons"].append(str(e))
        return out
    samples = list(V.read_samples(d))
    vms, problems, recycled = vm_table_lease([(k, v) for _, k, v in events], retired, started)
    times = [t for t, _, _ in events]
    obs, seen, unatt, sample_ts = attribute(d, vms, times, {v["id"] for v in vms if v["lease"]}, samples)
    out["same_second_reorders"] = []
    if unatt and not problems:
        ev2, swaps = resolve_same_second(events, retired, started, d, samples)
        vms2, problems2, recycled2 = vm_table_lease([(k, v) for _, k, v in ev2], retired, started)
        times2 = [t for t, _, _ in ev2]
        obs2, seen2, unatt2, ts2 = attribute(d, vms2, times2, {v["id"] for v in vms2 if v["lease"]}, samples)
        if swaps and not unatt2 and not problems2:
            events, vms, recycled, times = ev2, vms2, recycled2, times2
            obs, seen, unatt, sample_ts = obs2, seen2, unatt2, ts2
            out["same_second_reorders"] = [{"vms": [a, b], "at": t} for a, b, t in swaps]
    reasons = list(problems)
    known = {v["id"] for v in vms}
    wl_events = WL.read_events(d)
    for ev in wl_events.values():
        for e in ev:
            if e["kind"] == "exec" and e["vm"] and e["vm"] not in known:
                reasons.append("an Exec line names %s, which has no restore line" % e["vm"])
    if unatt:
        reasons.append("%d sample(s) of cgroups holding no live VM per the replay (first: %s at %.0f)"
                       % (len(unatt), unatt[0][1], unatt[0][0]))
        if recycled:
            reasons.append("lease_start_failed_without_marker_suspected: the replay recycled %d cgroup name(s); "
                           "a promoted VM whose lease start failed without a log marker (Resume failure, "
                           "aborted normalise) would shift the names" % recycled)
    for v in vms:
        born = times[v["born_i"]]
        end = times[v["end_i"]] if v["end_i"] is not None else (sample_ts[-1] if sample_ts else None)
        if end is None or end - born < MIN_LIFE_S:
            continue
        inside = bisect.bisect_right(sample_ts, end) - bisect.bisect_left(sample_ts, born)
        if inside >= 3 and not seen[v["id"]]:
            reasons.append("%s (%s) lived %.0f s with %d samples and never shows in them"
                           % (v["id"], v["name"], end - born, inside))
    reasons = sorted(set(reasons))
    out["mapping_reasons"] = reasons
    out["mapping_valid"] = not reasons
    out["lease_vms"] = len([v for v in vms if v["lease"]])
    # the replacement-VM reading needs only the log and the calls
    rows, summary = WL.join(d)
    out["warmcold"] = {k: summary[k] for k in ("valid", "countable", "disagreements")}
    out["replacement"] = replacement_reading(rows, sbx_median_ms)
    if reasons:
        return out
    born_ts = {v["id"]: times[v["born_i"]] for v in vms}
    lease_vms = [v for v in vms if v["lease"]]
    out["vms"] = [{"id": v["id"], "cgroup": v["name"], "lease": v["lease"], "born": born_ts[v["id"]],
                   "end": times[v["end_i"]] if v["end_i"] is not None else None,
                   "samples": seen[v["id"]]} for v in vms]
    out["memory_vs_age"] = mem_vs_age(lease_vms, obs, born_ts)
    out["share_above"] = share_above(lease_vms, obs, guest_ram_mib)
    calls = W.read_calls(d)
    ram = int(guest_ram_mib * (1 << 20))
    fp_obs = dirty_obs = idle_tail = None
    if any(isinstance(r.get("vm_fp"), dict) for r in samples):  # E17c; an E17b rung's output is unchanged
        keep = {v["id"] for v in lease_vms}
        fp_obs = attribute(d, vms, times, keep, samples, "vm_fp")[0]
        dirty_obs = attribute(d, vms, times, keep, samples, "vm_dirty")[0]
        idle_tail = idle_tail_reading(read_lease_ends(d), keep, last_exec_ends(rows, calls, wl_events), fp_obs,
                                      sample_ts, ram)
    out["fpr"] = fpr_reading(rows, calls, obs, {v["id"]: v for v in vms}, shmem, ram, fp_obs, dirty_obs, idle_tail)
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("rundir")
    ap.add_argument("--sbx", default=None, help="the sbx rung dir: its median ok py_grep is the baseline")
    ap.add_argument("--sbx-median-ms", type=float, default=None)
    ap.add_argument("--guest-ram-mib", type=float, default=None)
    a = ap.parse_args(argv)
    med = a.sbx_median_ms if a.sbx_median_ms is not None else (sbx_median_grep(a.sbx) if a.sbx else None)
    shmem = None
    fp = os.path.join(a.rundir, "shmem.json")
    if os.path.exists(fp):
        with open(fp) as f:
            shmem = json.load(f)
    r = analyse(a.rundir, med, shmem, a.guest_ram_mib)
    with open(os.path.join(a.rundir, "vm_age_lease.json"), "w") as f:
        json.dump(r, f, indent=2, sort_keys=True)
        f.write("\n")
    print("mapping_valid %s lease_vms %s%s" % (str(r["mapping_valid"]).lower(), r.get("lease_vms"),
                                               "" if r["mapping_valid"] else "; " + "; ".join(r["mapping_reasons"])))
    return r


if __name__ == "__main__":
    main()
