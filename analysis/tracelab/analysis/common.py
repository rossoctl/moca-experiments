"""Shared helpers for the tracelab analysis scripts.

Every script under analysis/ is runnable on its own:
    /path/to/venv/bin/python analysis/<name>.py
Figures land in out/figures/, tables (CSV + Markdown) in out/tables/.
"""
import gzip
import hashlib
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORPORA = os.path.join(ROOT, "data", "corpora")
RESULTS = os.path.join(ROOT, "data", "results")
OUT_FIG = os.path.join(ROOT, "out", "figures")
OUT_TAB = os.path.join(ROOT, "out", "tables")

# TraceLab v0.0.2 source trace (see data/SOURCES.md; not copied into the repo).
DUCKDB = "/tmp/kagenti/tracelab/trace/v0.0.2/syfi_coding_trace.duckdb"
DUCKDB_SHA256 = "a7bab286bc640844560850965ccf47975cf66407154132abaab90f27ec9be744"

POINTS = ["default", "short", "long", "no-infra", "no-chains"]
PROVIDERS = ["claude", "codex"]

# Categorical palette (dataviz reference instance, light surface, fixed slot order).
CAT = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#6250d6", "#e34948"]
ARM_COLOR = {"sbx": CAT[0], "resident-inf": CAT[1], "resident-300": CAT[2], "control": CAT[3]}
ARM_LABEL = {"sbx": "SBX", "resident-inf": "resident ∞", "resident-300": "resident 300 s",
             "control": "control"}
PROV_COLOR = {"claude": CAT[0], "codex": CAT[1]}


def load_corpus(point):
    """The replay corpus of a point: list of {session, user, provider, calls[]}, in file order."""
    path = os.path.join(CORPORA, point, "corpus.jsonl.gz")
    out = []
    with gzip.open(path, "rt") as f:
        for line in f:
            out.append(json.loads(line))
    return out


def load_report(point):
    with open(os.path.join(CORPORA, point, "corpus-report.json")) as f:
        return json.load(f)


def verify_duckdb(path=None):
    path = path or DUCKDB
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    got = h.hexdigest()
    if got != DUCKDB_SHA256:
        raise SystemExit("%s: sha256 %s is not TraceLab v0.0.2's %s" % (path, got, DUCKDB_SHA256))
    return got


def setup_matplotlib():
    """Import matplotlib headlessly with a writable cache dir; return (plt, fig helpers)."""
    os.environ.setdefault("MPLCONFIGDIR", "/tmp/kagenti/tracelab-analysis/mplcache")
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    plt.rcParams.update({
        "figure.dpi": 150, "savefig.dpi": 150,
        "font.size": 9, "axes.titlesize": 10, "axes.labelsize": 9,
        "axes.spines.top": False, "axes.spines.right": False,
        "axes.grid": True, "grid.color": "#e6e6e3", "grid.linewidth": 0.6,
        "axes.axisbelow": True,
        "legend.frameon": False,
    })
    return plt


def _md_table(header, rows):
    """A GitHub-flavoured Markdown table from a header list and row lists."""
    def esc(v):
        return str(v).replace("|", "\\|").replace("\n", " ")
    out = ["| " + " | ".join(esc(h) for h in header) + " |",
           "|" + "|".join("---" for _ in header) + "|"]
    for r in rows:
        out.append("| " + " | ".join(esc(v) for v in r) + " |")
    return "\n".join(out) + "\n"


def write_table(name, header, rows):
    """Write out/tables/<name>.csv and .md (same content, two formats)."""
    os.makedirs(OUT_TAB, exist_ok=True)
    import csv
    with open(os.path.join(OUT_TAB, name + ".csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)
    with open(os.path.join(OUT_TAB, name + ".md"), "w") as f:
        f.write(_md_table(header, rows))
    print("table %s: %d rows" % (name, len(rows)))


def save_fig(plt, fig, name):
    os.makedirs(OUT_FIG, exist_ok=True)
    path = os.path.join(OUT_FIG, name + ".png")
    fig.savefig(path, bbox_inches="tight")
    plt.close(fig)
    print("figure %s" % path)


def pct(x, digits=1):
    return None if x is None else round(100.0 * x, digits)


def quantile(values, q):
    """Nearest-rank quantile (matches record.py's p95 convention)."""
    if not values:
        return None
    s = sorted(values)
    k = max(0, -(-int(q * 100) * len(s) // 100) - 1)
    return s[k]
