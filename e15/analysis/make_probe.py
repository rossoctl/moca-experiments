"""Per-class N=1 probe corpora (SPEC §8 condition 4, §10.1 step 3).

    python3 make_probe.py CORPUS LIBRARY OUT_DIR [--per-class 20] [--seed S]

For every class in LIBRARY plus the stand-in classes (opaque, build, host_infra) writes
OUT_DIR/<class>/corpus.jsonl: ONE session (id probe-<class>, user probe, provider probe) of
--per-class calls of that class. Each call's (work_ms, dur_ms) pair is drawn, seeded, from that
class's non-chain calls in CORPUS (chains excluded: their duration is mostly idle tail), dur_ms
capped at 30 000 ms and work_ms at dur_ms; a class
CORPUS has none of falls back to the library's invocation times. gap_ms is 2000 and offset_ms is
the previous call's dur_ms + gap_ms (0 for the first), so the class is measured alone on an idle
worker. Also writes OUT_DIR/<class>/corpus-report.json (the fields rung.sh reads) and
OUT_DIR/classes.txt. The driver's validatePlans accepts a session with >= 3 calls whose class is in
the library or a stand-in class: exactly what is written here.
"""
import argparse
import json
import os
import random

GAP_MS = 2000
CAP_MS = 30000  # a probe measures per-class medians, not tails
STANDIN = ("opaque", "build", "host_infra")


def class_pairs(corpus_path):
    pairs = {}
    with open(corpus_path) as f:
        for line in f:
            if not line.strip():
                continue
            for c in json.loads(line)["calls"]:
                if c.get("chain"):
                    continue
                pairs.setdefault(c["class"], []).append((int(c["work_ms"]), int(c["dur_ms"])))
    return pairs


def library_pairs(lib, cls):
    ms = [int(v.get("run_ms") if v.get("run_ms") is not None else v["nominal_ms"])
          for v in lib["classes"].get(cls, [])]
    return [(m, m) for m in ms] or [(100, 100)]


def probe_session(cls, pairs, per_class, rng):
    calls, prev_dur = [], 0
    for i in range(per_class):
        work, dur = rng.choice(pairs)
        dur = min(max(dur, work), CAP_MS)
        work = min(work, dur)
        calls.append({"i": i, "class": cls, "skeleton": "probe", "dur_ms": dur, "work_ms": work,
                      "gap_ms": GAP_MS, "offset_ms": 0 if i == 0 else prev_dur + GAP_MS,
                      "out_bytes": 0, "chain": False})
        prev_dur = dur
    return {"session": "probe-" + cls, "user": "probe", "provider": "probe", "calls": calls}


def span_ms(session):
    c = session["calls"]
    return sum(x["offset_ms"] for x in c) + c[-1]["dur_ms"]


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("corpus")
    ap.add_argument("library")
    ap.add_argument("out_dir")
    ap.add_argument("--per-class", type=int, default=20)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args(argv)
    with open(a.library) as f:
        lib = json.load(f)
    seen = class_pairs(a.corpus)
    classes = sorted(set(lib["classes"]) | set(STANDIN))
    for cls in classes:
        rng = random.Random("%d/%s" % (a.seed, cls))
        s = probe_session(cls, seen.get(cls) or library_pairs(lib, cls), a.per_class, rng)
        d = os.path.join(a.out_dir, cls)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "corpus.jsonl"), "w") as f:
            f.write(json.dumps(s, separators=(",", ":")) + "\n")
        with open(os.path.join(d, "corpus-report.json"), "w") as f:
            json.dump({"probe_class": cls, "H_s": None, "exclude": None,
                       "table": {"mean_span_min": span_ms(s) / 60000.0},
                       "span_ms": span_ms(s), "from_corpus": cls in seen}, f, indent=2)
    with open(os.path.join(a.out_dir, "classes.txt"), "w") as f:
        f.write("\n".join(classes) + "\n")


if __name__ == "__main__":
    main()
