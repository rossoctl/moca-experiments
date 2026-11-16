#!/usr/bin/env bash
# experiments/e17-lease/rig/probe-overhead.sh -- the level-1 overhead probe (spec §7.4, PLAN-E17B Task 11 and Task 14
# Step 4) on the metal host: the N = 1 per-call added latency of the shipped lease (arm ship-300) over the E17a resident
# patch, on the `default` point's probe classes.
#
# Run by chain-e17b.sh (stage probe-overhead, after the seal), from the staged copy, with E17B=1 (required: the E17b
# pin, checkout and -e17b binaries) on fresh-metal. It runs `baseline.sh default ship-300` (seeded N = 1 runs, then
# classprobe.sh: each default class alone, 20 calls, on an idle worker), whose class medians are the per-call added
# latency of each class, then experiments/e17-lease/analysis/overhead_compare.py against the reference.
#
# Records. baseline.sh writes $E15_RUNS/default/ship-300/N1/baseline.json, where the calibration baseline
# (stage cal-default-ship-300) is, and rung.sh moves the calibration's N1-s* and N1-probe-* directories aside
# (*.prev-<UTC>). So the probe's baseline is kept as N1/baseline.probe-overhead.json and the one it replaced is put
# back as N1/baseline.json: what the default ship-300 ladder's rungs read stays where their params.json points.
# Its runs are the N1-s* / N1-probe-* directories this probe wrote.
# The comparison goes to N1/overhead.json. Its reference (overhead_compare.py's default, the resident patch's own N = 1
# default probe in e15-session-density/results/metal/) is not on the rig, since sync.sh excludes results/: it runs
# here only when E17B_OVERHEAD_REF names a staged copy; otherwise the log says the laptop command to run on the
# copied N1/baseline.probe-overhead.json.
#
# Exit 0 when the probe's baseline.json was written (the comparison, when run, too); 1 on a rig error; 2 on bad usage.
# Test hook: E17B_BASELINE replaces baseline.sh (as in chain-e17b.sh).
set -euo pipefail
E15_PROG=probe-overhead.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ $# -eq 0 ] || {
  echo "usage: probe-overhead.sh   (no arguments; E17B=1, fresh-metal, the staged copy)" >&2
  exit 2
}
# Before lib.sh: with E17B unset lib.sh resolves the sealed pin, and this probe is the E17b arm's.
[ "${E17B:-}" = 1 ] || {
  echo "probe-overhead.sh: E17B=1 is required (the probe measures ship-300 at the E17b pin); chain-e17b.sh sets it" >&2
  exit 1
}
E15_RIG=$HERE/../../e15/rig
[ -f "$E15_RIG/lib.sh" ] || {
  printf '%s: no %s/lib.sh: run the staged copy (/srv/e15/src/e17/rig/probe-overhead.sh)\n' "$E15_PROG" "$E15_RIG" >&2
  exit 1
}
# shellcheck source=SCRIPTDIR/../../e15-session-density/rig/lib.sh
. "$E15_RIG/lib.sh"
E17_SRC=$E15_ROOT/src/e17
case "$HERE" in "$E17_SRC"/rig) ;; *) die "run the staged copy: $E17_SRC/rig/probe-overhead.sh (not $HERE)" ;; esac
[ "$E15_HOST_PROFILE" = fresh-metal ] || die "the E17b probes run on fresh-metal only (this host: $E15_HOST_PROFILE)"
e17b_require_pin
e17b_require_build

POINT=default
ARM=ship-300
BASELINE=${E17B_BASELINE:-$E15_SRC/rig/baseline.sh}
N1=$E15_RUNS/$POINT/$ARM/N1
ts=$(date -u +%Y%m%dT%H%M%SZ)
saved=""
if [ -f "$N1/baseline.json" ]; then
  saved=$N1/baseline.before-probe-overhead-$ts.json
  cp -p "$N1/baseline.json" "$saved"
  log "the calibration baseline $N1/baseline.json is kept as $saved while the probe runs"
fi
log "level-1 overhead probe: baseline.sh $POINT $ARM (E17B=1, pin $E15_MOCA_PIN)"
bash "$BASELINE" "$POINT" "$ARM" || die "baseline.sh $POINT $ARM failed: rig error, no overhead reading"
[ -f "$N1/baseline.json" ] || die "baseline.sh $POINT $ARM wrote no $N1/baseline.json"
mv -f "$N1/baseline.json" "$N1/baseline.probe-overhead.json"
if [ -n "$saved" ]; then
  mv -f "$saved" "$N1/baseline.json"
  log "the calibration baseline is back at $N1/baseline.json; the probe's is $N1/baseline.probe-overhead.json"
fi

REF=${E17B_OVERHEAD_REF:-}
if [ -n "$REF" ]; then
  [ -f "$REF" ] || die "E17B_OVERHEAD_REF=$REF does not exist"
  python3 "$E17_SRC/analysis/overhead_compare.py" "$N1/baseline.probe-overhead.json" "$REF" --out "$N1/overhead.json" ||
    die "overhead_compare.py failed"
  log "level-1 overhead against $REF: $N1/overhead.json"
else
  log "no reference staged (E17B_OVERHEAD_REF unset; sync.sh excludes results/): copy $N1/baseline.probe-overhead.json to the laptop and run python3 experiments/e17-lease/analysis/overhead_compare.py <that copy> --out <results dir>/overhead.json"
fi
