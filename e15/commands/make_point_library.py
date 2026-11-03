"""A point's command library derived from the default one (SPEC §10.3, point mem512).

    python3 make_point_library.py SRC DST --scan-classes CSV --scan-cmd CMD

Writes DST as SRC with every invocation of the listed classes prefixed `CMD && ` and its id
suffixed `+scan`. exit, nominal_ms, run_ms and cpu_ms are kept: the driver plans each call by
run_ms, so a scanned call replays the same invocations as at the default point and the scan's own
time is added on top (it shows in the probe's per-class medians, which use this library). Every
other class, the stand-in table and the version are copied unchanged. A listed class SRC lacks is
an error.

The committed e15/commands/library-mem512.json is
    python3 make_point_library.py library.json library-mem512.json \
      --scan-classes read,shell_read,search,test,interpreter,lint_check \
      --scan-cmd 'cat /workspace/data.bin >/dev/null'
and test_points.py checks it still is.
"""
import argparse
import copy
import json
import sys


def point_library(src, scan_classes, scan_cmd):
    missing = [c for c in scan_classes if c not in src["classes"]]
    if missing:
        sys.exit("make_point_library.py: classes not in the library: %s" % ", ".join(missing))
    out = copy.deepcopy(src)
    for cls in scan_classes:
        for inv in out["classes"][cls]:
            inv["cmd"] = "%s && %s" % (scan_cmd, inv["cmd"])
            inv["id"] = inv["id"] + "+scan"
    return out


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--scan-classes", required=True, help="comma-separated class names")
    ap.add_argument("--scan-cmd", required=True)
    a = ap.parse_args(argv)
    classes = [c for c in a.scan_classes.split(",") if c]
    if not classes:
        sys.exit("make_point_library.py: --scan-classes is empty")
    with open(a.src) as f:
        src = json.load(f)
    out = point_library(src, classes, a.scan_cmd)
    with open(a.dst, "w") as f:
        json.dump(out, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
