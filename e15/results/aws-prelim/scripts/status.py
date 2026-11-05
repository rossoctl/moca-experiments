#!/usr/bin/env python3
# status.py: one line per finished rung under /srv/e15/runs/<point>/<arm>/N*/record.json (non-probe, non-prev)
import glob, json, os
for p in sorted(glob.glob("/srv/e15/runs/*/*/N*/record.json")):
    d = os.path.dirname(p); b = os.path.basename(d)
    if "probe" in b or "prev" in b or b.startswith("N1-s") or "/_" in d: continue
    try: r = json.load(open(p))
    except Exception: continue
    pt, arm = d.split("/")[-3:-1]
    sh = {}
    try: sh = json.load(open(os.path.join(d, "shared-host.json")))
    except Exception: pass
    c4 = r.get("p95_excess_ms")
    print("%-9s %-12s %-10s holds=%-5s abs=%-5s cpace=%s p95x=%s fail=%s ref=%s bind=%s cpu=%s a2=%s mtime=%s" % (
        pt, arm, b, r.get("holds"), r.get("holds_abs"),
        None if r.get("median_class_pace") is None else round(r["median_class_pace"], 4),
        None if c4 is None else round(c4), r.get("failed_calls"), r.get("refusals"), r.get("binding"),
        (json.load(open(os.path.join(d,"shared-host.json"))).get("host_busy_pct_mean") if os.path.exists(os.path.join(d,"shared-host.json")) else None),
        (r.get("driver") or {}).get("a2_pct_of_host") and round(r["driver"]["a2_pct_of_host"], 3),
        __import__("time").strftime("%H:%MZ", __import__("time").gmtime(os.path.getmtime(p)))))
