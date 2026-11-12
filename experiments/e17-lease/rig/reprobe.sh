#!/usr/bin/env bash
# experiments/e17-lease/rig/reprobe.sh ARM -- re-run one arm's class probe at point pycache under the pycache probe
# cap, and recompute that arm's N=1 baseline from its existing seeded runs (E17 Task 5b).
#
# Why: E15's probe capped every planned duration at 30 s. pycache's py_test runs ~62 s whatever it
# is planned at, so its probe median came out +31 s, and every ladder py_test call (planned 60 s)
# then had a class-matched excess near -29 s: condition 4 could never fail on py_test. points.sh
# now gives the pycache points E15_P_PROBE_CAP_MS=120000 (classprobe.sh passes it to make_probe.py).
# The seeded runs do not depend on the cap (only the probe does), so they are reused, not re-run.
#
# Run by the controller only, as the rig's login user, after sync.sh:
#   bash /srv/e15/src/e17/rig/reprobe.sh ARM      (ARM: sbx resident-300 lease-30 lease-120)
#
#   0. refuses while a rung's worker (e15-worker.service) runs: it never preempts one
#   1. checks, before anything moves (a refusal leaves the arm as it was):
#      - /srv/e15/runs/pycache/ARM is a directory, not a symlink, and N1/baseline.json exists
#      - the evaluable seeded runs, re-derived as baseline.sh counted them: N1-s1, N1-s2, ... (at
#        most E15_BASELINE_MAX_SEEDS=12) until >= 3 evaluable runs and >= 30 pooled in-window ok
#        calls; record.json holds -> evaluable; reason empty_window and clean -> skipped; anything
#        else dies (baseline.sh would have died). Never a listing of N1-s*: a seed past the
#        stopping point is not counted. They must equal the old baseline.json's evaluable and
#        skipped seeds.
#      - those runs' library, driver and corpus hashes are the current files' (else rung.sh would
#        refuse the new baseline), and their point_settings are pycache's current settings, or
#        those settings without the probe_cap_ms term (recorded before the cap existed)
#      - every rename below is a leaf of the arm directory, not a symlink, onto a free name
#   2. moves aside (leaf renames, nothing removed): N1-probe-* -> _cap30k-N1-probe-*,
#      probe-corpora -> _cap30k-probe-corpora, N1/baseline.json -> N1/baseline.cap30k.json
#   3. classprobe.sh pycache ARM (E15_CLASSPROBE overrides it); its probe run directories. Then
#      the environment check: baseline.sh runs its seeded runs and its probe back to back, but
#      here the seeded runs are from earlier, so a template re-stamp or a worker rebuild since
#      would mix two environments. Every new probe's record.json must agree with every counted
#      seeded one on template_sha256, worker_bin_sha256, resident_patch_sha256, snapshot_hash and
#      snapshot_guest_ram_mb (a field absent from both is equal; absent from one is a mismatch).
#   4. analysis/baseline.py exactly as baseline.sh calls it: N1/baseline.json, the evaluable
#      seeded dirs, --probe the new probe dirs, with E15_BASELINE_CORPUS/ARM/SEEDS/SKIPPED
#   5. baseline.py copies point_sig from the seeded records, which may predate the cap: the new
#      baseline.json gets pycache's current point_sig (a cap30k baseline keeps the old one, and
#      rung.sh refuses it), and "reprobe" records the seeded sig, the cap and the cap30k file.
# A failure in steps 3-5 dies with no N1/baseline.json (the old one stays aside). A second run
# is refused (the aside names exist). After a failed run (baseline.cap30k.json but no
# baseline.json) the refusal prints this arm's restore commands: the partial new N1-probe-* and
# probe-corpora moved to _failed-<UTC>-*, then each _cap30k-* back to its old name.
set -euo pipefail
E15_PROG=reprobe.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The staged copy on the rig has e15/ beside e17/ ($HERE/../../e15/rig); a checkout of this
# repo has it at $HERE/../../../experiments/e15-session-density/rig. Use whichever exists.
E15_RIG=$HERE/../../e15/rig
[ -f "$E15_RIG/lib.sh" ] || E15_RIG=$HERE/../../../experiments/e15-session-density/rig
# shellcheck source=SCRIPTDIR/../../experiments/e15-session-density/rig/lib.sh
. "$E15_RIG/lib.sh"
# shellcheck source=SCRIPTDIR/../../experiments/e15-session-density/rig/points.sh
. "$E15_RIG/points.sh"

POINT=pycache
usage() {
  echo "usage: reprobe.sh ARM   (ARM: one of point $POINT's: sbx resident-300 lease-30 lease-120)" >&2
  exit 2
}
[ "$E15_HOST_PROFILE" = fresh-metal ] || die "E15_HOST_PROFILE=$E15_HOST_PROFILE: E17 runs on fresh-metal only"
[ $# -eq 1 ] || usage
ARM=$1
e15_is_arm "$ARM" || usage
case " $(e15_point_arms "$POINT") " in *" $ARM "*) ;; *) usage ;; esac
E17_SRC=$E15_ROOT/src/e17
case "$HERE" in "$E17_SRC"/rig) ;; *) die "run the staged copy: $E17_SRC/rig/reprobe.sh (not $HERE)" ;; esac
refuse_running_rung() { if unit_active "$E15_UNIT_WORKER"; then die "a rung's worker ($E15_UNIT_WORKER) is running; refusing to preempt it"; fi; }
refuse_running_rung
e15_point "$POINT" || die "points.sh: no point $POINT"
[ -n "${E15_P_PROBE_CAP_MS:-}" ] || die "points.sh gives $POINT no E15_P_PROBE_CAP_MS (sync.sh first)"
CUR_SETTINGS=$E15_P_SETTINGS
CUR_SIG=$(e15_point_sig "$POINT")

# --- 1. checks ---------------------------------------------------------------------------------
RUNDIR=$E15_RUNS/$POINT/$ARM
[ "$RUNDIR" = "$E15_ROOT/runs/$POINT/$ARM" ] || die "refusing run directory $RUNDIR"
[ ! -L "$RUNDIR" ] || die "refusing $RUNDIR: a symlink"
[ -d "$RUNDIR" ] || die "no $RUNDIR (run baseline.sh $POINT $ARM)"
refuse_outside_root "$RUNDIR"
OUT=$RUNDIR/N1/baseline.json
OLD=$RUNDIR/N1/baseline.cap30k.json
if [ -f "$OLD" ] && [ ! -e "$OUT" ] && [ ! -L "$OUT" ]; then
  # A previous reprobe moved the cap30k probe aside and then failed: say how to put it back.
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  steps=()
  for p in "$RUNDIR"/N1-probe-* "$RUNDIR/probe-corpora"; do
    [ -e "$p" ] || [ -L "$p" ] || continue
    steps+=("mv -- $p $RUNDIR/_failed-$ts-${p##*/}")
  done
  for p in "$RUNDIR"/_cap30k-*; do
    [ -e "$p" ] || [ -L "$p" ] || continue
    steps+=("mv -- $p $RUNDIR/${p##*/_cap30k-}")
  done
  steps+=("mv -- $OLD $OUT")
  die "a previous reprobe failed after the moves: $OLD exists, $OUT does not. To restore $ARM's cap30k baseline, run in order:$(printf '\n  %s' "${steps[@]}")
then re-run reprobe.sh $ARM"
fi
[ -f "$OUT" ] || die "no $OUT (run baseline.sh $POINT $ARM: there is nothing to re-probe)"
# The only removal: the new baseline.json (and its re-sign temp file) when a later step fails.
drop_out() { rm -f -- "$OUT" "$OUT.tmp"; }

# The seeded runs baseline.sh counted: its loop, verdict and pooled-call count, over the existing
# record.json files (no rung is run).
MAX_SEEDS=${E15_BASELINE_MAX_SEEDS:-12}
MIN_RUNS=3
MIN_CALLS=30
dirs=()
seeds=()
skipped=()
calls=0
s=0
while [ "${#dirs[@]}" -lt "$MIN_RUNS" ] || [ "$calls" -lt "$MIN_CALLS" ]; do
  [ "$s" -lt "$MAX_SEEDS" ] ||
    die "$MAX_SEEDS seeds gave ${#dirs[@]} evaluable runs and $calls pooled calls: not the seeded runs of a baseline"
  s=$((s + 1))
  d=$RUNDIR/N1-s$s
  [ -f "$d/record.json" ] || die "no $d/record.json: the seeded runs baseline.sh counted are not all there"
  verdict=$(python3 -c '
import json, sys
r = json.load(open(sys.argv[1]))
clean = not r.get("failed_calls") and not r.get("refusals") and not r.get("aborted") \
    and not r.get("time_origin_mismatch")
if r.get("reason") == "empty_window" and clean:
    print("skip")
elif r.get("holds") is True:
    print("ok")
else:
    print("fail")' "$d/record.json")
  case "$verdict" in
  skip)
    skipped+=("$s:s$s:empty_window")
    continue
    ;;
  ok) ;;
  *) die "N=1 run $d does not hold: baseline.sh would have made no baseline from it" ;;
  esac
  dirs+=("$d")
  seeds+=("$s")
  n=$(python3 -c 'import os,sys; sys.path.insert(0, sys.argv[1]); import holds as H; from record import read_jsonl
print(len(H.window_added_ms(read_jsonl(os.path.join(sys.argv[2], "calls.jsonl")))))' "$E15_SRC/analysis" "$d")
  calls=$((calls + n))
done
sha_of() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
python3 - "$OUT" "${seeds[*]}" "${skipped[*]}" "$CUR_SETTINGS" " probe_cap_ms=$E15_P_PROBE_CAP_MS" \
  "$(sha_of "$E15_P_LIBRARY")" "$(sha_of "$E15_BIN/e15-driver")" "$(sha_of "$E15_CORPORA/$E15_P_CORPUS/corpus.jsonl")" "${dirs[@]}" <<'PY' ||
import hashlib, json, os, sys
out, seeds, skipped, cur, term, lib, drv, corpus = sys.argv[1:9]
dirs = sys.argv[9:]
b = json.load(open(out))
old_seeds = " ".join(str(e.get("seed")) for e in b.get("evaluable", []))
old_skipped = " ".join("%s:%s:%s" % (e.get("seed"), e.get("tag"), e.get("reason")) for e in b.get("skipped", []))
if (seeds, skipped) != (old_seeds, old_skipped):
    sys.exit("reprobe.sh: re-derived evaluable seeds %s (skipped %s), but the old baseline.json has %s (skipped %s)"
             % (seeds, skipped or "none", old_seeds or "none", old_skipped or "none"))
bare = cur[:-len(term)] if cur.endswith(term) else cur
for d in dirs:
    r = json.load(open(os.path.join(d, "record.json")))
    for k, want in (("library_sha256", lib), ("driver_bin_sha256", drv), ("corpus_sha256", corpus)):
        if r.get(k) != want:
            sys.exit("reprobe.sh: %s has %s %s, the current file has %s: rung.sh would refuse the baseline "
                     "(re-run baseline.sh)" % (d, k, r.get(k), want))
    st = r.get("point_settings")
    if st not in (cur, bare):
        sys.exit("reprobe.sh: %s was recorded with point settings '%s', not pycache's ('%s') or those "
                 "without its probe cap" % (d, st, cur))
    if r.get("point_sig") != hashlib.sha256(st.encode()).hexdigest():
        sys.exit("reprobe.sh: %s's point_sig is not the sha256 of its point_settings" % d)
PY
  exit 1

# Every rename, checked before the first one: a leaf of the arm directory (or of N1/), not a
# symlink, onto a name that does not exist.
srcs=()
tgts=()
for p in "$RUNDIR"/N1-probe-* "$RUNDIR/probe-corpora"; do
  [ -e "$p" ] || [ -L "$p" ] || continue
  srcs+=("$p")
  tgts+=("$RUNDIR/_cap30k-${p##*/}")
done
srcs+=("$OUT")
tgts+=("$OLD")
for i in "${!srcs[@]}"; do
  src=${srcs[$i]}
  tgt=${tgts[$i]}
  case "${src%/*}" in "$RUNDIR" | "$RUNDIR/N1") ;; *) die "refusing $src: not a leaf of $RUNDIR" ;; esac
  [ "${tgt%/*}" = "${src%/*}" ] || die "refusing $tgt: not beside $src"
  [ ! -L "$src" ] || die "refusing $src: a symlink"
  if [ -e "$tgt" ] || [ -L "$tgt" ]; then die "refusing to move $src aside: $tgt already exists (a reprobe ran before?)"; fi
  refuse_outside_root "$src" "$tgt"
done

# --- 2. move the cap30k probe and baseline aside ----------------------------------------------
refuse_running_rung
for i in "${!srcs[@]}"; do
  mv -- "${srcs[$i]}" "${tgts[$i]}"
  log "reprobe $ARM: ${srcs[$i]#"$RUNDIR"/} -> ${tgts[$i]#"$RUNDIR"/}"
done

# --- 3. the class probe at the pycache cap -----------------------------------------------------
probe_out=$(bash "${E15_CLASSPROBE:-$E15_SRC/rig/classprobe.sh}" "$POINT" "$ARM") ||
  die "classprobe.sh $POINT $ARM failed: rig error, no baseline (the cap30k one is $OLD)"
probes=()
while IFS= read -r line; do
  [ -z "$line" ] || probes+=("$line")
done <<<"$probe_out"
[ "${#probes[@]}" -gt 0 ] || die "classprobe.sh $POINT $ARM produced no probe runs"
python3 - "${#dirs[@]}" "${dirs[@]}" "${probes[@]}" <<'PY' ||
import json, os, sys
n = int(sys.argv[1])
seeded, probes = sys.argv[2:2 + n], sys.argv[2 + n:]
FIELDS = ("template_sha256", "worker_bin_sha256", "resident_patch_sha256", "snapshot_hash", "snapshot_guest_ram_mb")
missing = object()


def rec(d):
    p = os.path.join(d, "record.json")
    try:
        with open(p) as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        sys.exit("reprobe.sh: cannot read %s: %s" % (p, e))


seen = [(d, rec(d)) for d in seeded]
for p in probes:
    r = rec(p)
    for d, s in seen:
        for k in FIELDS:
            a, b = r.get(k, missing), s.get(k, missing)
            if a != b:
                show = lambda v: "(absent)" if v is missing else json.dumps(v)  # noqa: E731
                sys.exit("reprobe.sh: %s differs: the new probe %s has %s, the seeded run %s has %s: "
                         "the environment changed since the seeded runs" % (k, p, show(a), d, show(b)))
PY
  die "environment check failed: no baseline (the cap30k one is $OLD)"

# --- 4. baseline.py, as baseline.sh calls it ---------------------------------------------------
p95=$(E15_BASELINE_CORPUS="$E15_CORPORA/$E15_P_CORPUS/corpus.jsonl" E15_BASELINE_ARM="$ARM" E15_BASELINE_SEEDS="${seeds[*]}" E15_BASELINE_SKIPPED="${skipped[*]}" \
  python3 "$E15_SRC/analysis/baseline.py" "$OUT" "${dirs[@]}" --probe "${probes[@]}") || {
  drop_out
  die "baseline.py failed for ${dirs[*]}: no baseline (the cap30k one is $OLD)"
}

# --- 5. the point's current signature ----------------------------------------------------------
python3 - "$OUT" "$OLD" "$CUR_SIG" "$E15_P_PROBE_CAP_MS" <<'PY' || {
import json, os, sys
out, old, sig, cap = sys.argv[1:5]
b = json.load(open(out))
b["reprobe"] = {"probe_cap_ms": int(cap), "seeded_point_sig": b.get("point_sig"), "cap30k_baseline": old}
b["point_sig"] = sig
tmp = out + ".tmp"
with open(tmp, "w") as f:
    json.dump(b, f, indent=2, sort_keys=True)
os.replace(tmp, out)
PY
  drop_out
  die "could not re-sign $OUT: no baseline (the cap30k one is $OLD)"
}
log "reprobe $ARM probe_failed: $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["probe_failed"] or "none")' "$OUT")"
log "reprobe $ARM class medians (cap30k -> cap ${E15_P_PROBE_CAP_MS}): $(python3 -c 'import json,sys
o, n = (json.load(open(p)).get("class_medians", {}) for p in sys.argv[1:3])
print(", ".join("%s %s -> %s" % (k, o.get(k), n.get(k)) for k in sorted(set(o) | set(n))))' "$OLD" "$OUT")"
log "reprobe $ARM point=$POINT: p95 added ${p95} ms over ${#dirs[@]} evaluable N=1 runs, $calls calls, ${#probes[@]} class probes (seeds ${seeds[*]}; skipped ${skipped[*]:-none}) ($OUT)"
