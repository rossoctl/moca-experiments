#!/usr/bin/env bash
# Fetch the E15/E16 run results and replay corpora from the release assets of
# rossoctl/moca-experiments into data/results/{aws,metal,e16}/ and data/corpora/
# (both git-ignored), verifying every archive's sha256, and record the releases
# in data/results-lock.json (committed).
#
#   data-v1: E15 metal, E16 resident-inf and E16 sbx raw traces
#   data-v2: E15 AWS preliminary results, replay corpora
#
# The archives carry worker.log.gz; it is deliberately NOT copied into
# data/results (the PROMPT rule in the archives' manifest flags these logs, and
# the analysis never reads them). If a script needs a field from one, fetch that
# file separately.
#
# Usage: scripts/fetch_results.sh
set -eu

REPO="rossoctl/moca-experiments"
BASE="https://github.com/$REPO/releases/download"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/data/results"
CORP="$ROOT/data/corpora"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tracelab-fetch.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# fetch <asset> <tag> <sha256>; prints the local path
fetch() {
    asset="$1"; tag="$2"; want="$3"
    echo "fetching $tag/$asset" >&2
    curl -fL --retry 3 --progress-bar -o "$TMP/$asset" "$BASE/$tag/$asset"
    got="$(sha256 "$TMP/$asset")"
    if [ "$got" != "$want" ]; then
        echo "checksum mismatch for $asset: expected $want, got $got" >&2
        exit 1
    fi
    printf '%s\n' "$TMP/$asset"
}

# Raw files the analysis reads from a rung/point directory.
RAW_FILES=(
    -name record.json -o -name params.json -o -name baseline.json
    -o -name calls.jsonl.gz -o -name calls.jsonl -o -name sessions.jsonl
    -o -name samples.jsonl.gz -o -name samples.jsonl -o -name driver-cpu.jsonl
    -o -name shared-host.json -o -name 'ladder*.json' -o -name fine.json -o -name perf.jsonl -o -name bench.json -o -name record_1s.json
    -o -name record_cpu.json -o -name record_nowedge.json -o -name stag_valid.json
    -o -name corpus-report.json -o -name 'RESULTS*.md' -o -name summary.json
    -o -name '*.md' -o -name '*report.json' -o -name task8.out
    -o \( -name '*.json' -path './vm-age/*' \)
)

# copy_filtered <src> <dest>: copy the raw files under <src> into <dest>,
# preserving paths. worker.log.gz and *.out are not in the list on purpose.
copy_filtered() {
    src="$1"; dest="$2"
    [ -d "$src" ] || return 0
    mkdir -p "$dest"
    ( cd "$src" && find . -type f \( "${RAW_FILES[@]}" \) -print ) > "$TMP/files.txt"
    ( cd "$src" && rsync -a --files-from="$TMP/files.txt" . "$dest/" )
}

mkdir -p "$OUT" "$CORP"

# 1. The non-raw records, summaries and calibration that stay in git.
copy_filtered "$ROOT/../../experiments/e15-session-density/results/metal" "$OUT/metal"
copy_filtered "$ROOT/../../experiments/e16-low-duty/results" "$OUT/e16"
cp "$ROOT/../../experiments/e16-low-duty/predictions.json" "$ROOT/../../experiments/e16-low-duty/RESULTS.md" "$OUT/e16/"

# 2. The raw traces from data-v1, filtered on top.
E15_METAL="$(fetch moca-experiments-e15-metal-raw.tar.gz data-v1 \
    99cfe2d0692600d264ea52d8c5e24c7bfdd4147b01dc02207bd50bb7f7b7dacb)"
E16_RI="$(fetch moca-experiments-e16-resident-inf-raw.tar.gz data-v1 \
    01719466c3716608e9db65a2dff068dc7c9f6965ebbd336ab825283eae7eb311)"
E16_SBX="$(fetch moca-experiments-e16-sbx-raw.tar.gz data-v1 \
    3fc449e171882cf1eabd43c0006226387b4c91ad3938c812f410c5dc2a35df81)"
mkdir -p "$TMP/src"
for a in "$E15_METAL" "$E16_RI" "$E16_SBX"; do tar -xzf "$a" -C "$TMP/src"; done
copy_filtered "$TMP/src/e15/results/metal" "$OUT/metal"
copy_filtered "$TMP/src/e16/results/resident-inf" "$OUT/e16/resident-inf"
copy_filtered "$TMP/src/e16/results/sbx" "$OUT/e16/sbx"

# 3. The AWS preliminary results and the replay corpora from data-v2.
AWS="$(fetch moca-experiments-tracelab-aws.tar.gz data-v2 \
    d07f2dac5801b84c2e346f9562bdf922227da087bb39d4b5e7dde519ef29f821)"
CORPORA="$(fetch moca-experiments-tracelab-corpora.tar.gz data-v2 \
    5a9ab88b51a2493f73680edaa8a05fad8bb941c34bb1ea805db8eee649a5e5a7)"
mkdir -p "$OUT/aws"
tar -xzf "$AWS" -C "$TMP"
rsync -a "$TMP/analysis/tracelab/data/results/aws/" "$OUT/aws/"
tar -xzf "$CORPORA" -C "$TMP"
rsync -a "$TMP/analysis/tracelab/data/corpora/" "$CORP/"

cat > "$ROOT/data/results-lock.json" <<EOF
{
  "source": "https://github.com/$REPO",
  "fetched_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "aws": {
    "branch": "docs/e15-session-density-spec",
    "commit": "3c295c9d17da449354ea179503fef958a013234e",
    "release": "data-v2",
    "asset": "moca-experiments-tracelab-aws.tar.gz",
    "sha256": "d07f2dac5801b84c2e346f9562bdf922227da087bb39d4b5e7dde519ef29f821",
    "path": "-> data/results/aws"
  },
  "metal": {
    "branch": "experiments/e15-session-density/metal-run",
    "commit": "7a90a7653d21dcb14ab58d189dc735062d0fc6b9",
    "release": "data-v1",
    "asset": "moca-experiments-e15-metal-raw.tar.gz",
    "sha256": "99cfe2d0692600d264ea52d8c5e24c7bfdd4147b01dc02207bd50bb7f7b7dacb",
    "path": "experiments/e15-session-density/results/metal -> data/results/metal",
    "status": "final"
  },
  "e16": {
    "branch": "experiments/e16-low-duty/low-duty-spec",
    "commit": "c8dba135b7d0f514ae21d2d4dd0ccaf77008952d",
    "release": "data-v1",
    "assets": ["moca-experiments-e16-resident-inf-raw.tar.gz", "moca-experiments-e16-sbx-raw.tar.gz"],
    "sha256": {
      "moca-experiments-e16-resident-inf-raw.tar.gz": "01719466c3716608e9db65a2dff068dc7c9f6965ebbd336ab825283eae7eb311",
      "moca-experiments-e16-sbx-raw.tar.gz": "3fc449e171882cf1eabd43c0006226387b4c91ad3938c812f410c5dc2a35df81"
    },
    "path": "experiments/e16-low-duty/results -> data/results/e16",
    "status": "final"
  },
  "corpora": {
    "release": "data-v2",
    "asset": "moca-experiments-tracelab-corpora.tar.gz",
    "sha256": "5a9ab88b51a2493f73680edaa8a05fad8bb941c34bb1ea805db8eee649a5e5a7",
    "path": "-> data/corpora"
  }
}
EOF

echo "results in $OUT and corpora in $CORP (both git-ignored)"
