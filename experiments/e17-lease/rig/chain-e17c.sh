#!/usr/bin/env bash
# experiments/e17-lease/rig/chain-e17c.sh [--list] [--from STAGE] [--to STAGE] -- the E17c run list on the metal host
# (experiments/e17-lease/PLAN-E17C.md Task 4; SPEC §13.6), in order, one stage at a time. chain-e17b.sh's pattern:
# the same stage table, seal check, knob refusal, analysis gate and per-stage files, for E17c's stages.
#
# Run by the controller only, as the rig's login user, from the staged copy, after bring-up (E17C=1 setup.sh, the two
# snapshot-e17b.sh leaves e17c-<pin8>-{1024|256} under E17C=1, E17C=1 setup.sh again, E17C=1 bringup.sh):
#   bash /srv/e15/src/e17/rig/chain-e17c.sh               # from the first stage not done yet
#   bash /srv/e15/src/e17/rig/chain-e17c.sh --from lat-pycache-sbx-n128 [--to squeeze-sbx]
#   bash /srv/e15/src/e17/rig/chain-e17c.sh --list        # the stages, in order, with what each needs
#
# Every stage runs with E17C=1 (the profile: E17B=1 semantics with E17C_MOCA_PIN, the moca-e17c checkout and the
# e17c-<pin8>-<ram> snapshot leaves), on fresh-metal, with the manifest at ~/e17-manifest.md (E15_MANIFEST overrides).
# The caller's environment cannot change a stage (E17B-R36, ruling R-h): the per-rung knobs a stage sets itself
# (E15_TAG, E15_SEED, E15_START_ZERO, E15_WINDOW_S, ...) are unset below, and the chain REFUSES to start (exit 1, each
# named) while any other stage-changing knob is set, even to "" (STAGE_KNOBS, chain-e17b.sh's list). E17b's switches
# E17B_OPTIONAL and E17B_RAM256 are refused too (E17c's are E17C_OPTIONAL and E17C_RAM256), and so is an
# E17B_SQUEEZE_MEMMAX_MB other than 24576 (the squeeze's MemoryMax is fixed at 24576 MiB, as in E17b: SPEC §13.2). The
# operator's own inputs are E17C_OPTIONAL, E17C_RAM256, E17B_SQUEEZE_START_N (resume a squeeze climb at the rung that
# failed, E17B-R51), E17B_SQUEEZE256_MEMMAX_MB (the 256 MiB squeeze's MemoryMax, from its own short climb) and
# E15_MANIFEST.
#
# THE SEAL. No measured rung runs before the predictions are sealed (spec §9): a stage that needs "seal" (and every
# "ram256" and "opt" stage) runs only when experiments/e17-lease/predictions-e17c.json (staged beside this directory)
# exists, parses, and has "sealed": true (the JSON boolean). The chain refuses up front -- nothing runs -- when any
# selected stage needs the seal and the file does not say so, and checks again right before each such stage. Before
# the seal ("-"): the bring-up smoke, the calibration at pycache (cal-*) and the two calibration gates.
#
# Each stage writes its own log, $L/<stage>.log (L = /srv/e15/e17c), and on success $L/<stage>.done. Without --from
# the chain starts at the first selected stage that has no .done; --from STAGE starts there whatever is done; --to
# STAGE stops after it. The first failing stage stops the chain with "resume with --from <stage>". "opt" stages run
# only with E17C_OPTIONAL=1, "ram256" stages only with E17C_RAM256=1 (if Task 10's gate passed), else SKIP.
#
# The stages (SPEC §13.6):
#   smoke: smoke.sh under E17C=1 (sbx ship-300 ship-300-nd at pycache N=1).
#   cal-pycache-ARM: the N = 1 baseline at pycache with E15_START_ZERO=1 (baseline.sh: seeded runs, then the class
#     probes), then topped up to 4 evaluable seeds (SPEC §13.5, R52): while fewer than 4 N1-s<k> rungs have a record
#     that is not empty_window, the next seed runs (rung.sh ARM 1 pycache, E15_SEED=k, E15_TAG=sk, E15_START_ZERO=1),
#     at most 12 seeds in all.
#   gate-pycache-low (Task 9; SPEC §13.5, R47): pycache-low's N = 1 seeds from the first call, as its baselines will
#     run them: for sbx then ship-300, seeds k = 1..4 (rung.sh ARM 1 pycache-low, E15_START_ZERO=1, E15_WINDOW_S=1800,
#     E15_SEED=k, E15_TAG=gk: N1-g<k>, calibration only, apart from the baselines' N1-s<k>). Counted calls are the
#     in-window ok ones (holds.window_ok_calls, baseline.sh's population) of the classes criterion 2 reads, py_short
#     and py_import. It passes only when (R-t) every seed has at least 3 of them combined AND at least 1 of each class,
#     and (R-u, the N = 128 rungs' class-matched baseline) each arm's seeds pooled have at least holds.MIN_CLASS_CALLS
#     (5) of EACH class. Pass or fail, it writes $E15_RUNS/pycache-low/gate-pycache-low.json (ruling R-q: per arm and
#     seed the counts by class, per arm the pooled counts, pass and reason) and is DONE; a rung that fails is a rig
#     error and fails the stage (no file). An old gate file is removed before anything else, the preflight included.
#     Every pycache-low stage (base-pycache-low-*, lat-pycache-low-*) reads that file first: none, an unreadable one,
#     or one whose moca_commit, window_s or start_zero differ from the chain's (R-w) refuses the stage, naming why; a
#     failed gate makes it a SKIP, "pycache-low cut by gate-pycache-low: <reason>" (exit 0, ruling R-n's form), so the
#     chain goes on; a passed gate runs it. The baselines run with the gate's E15_START_ZERO=1 and 1800 s window
#     (baseline-low); the N = 128 rungs as before.
#   gate-256 (Task 10; SPEC §13.5, R45; ruling R-x): the 256 MiB library's calibration. For each candidate scale
#     (G256_SCALES, descending from config.py's ANALYZE_WORK_SCALE 32: 32 16 8 4 2 1) and each arm (sbx, ship-300),
#     py_analyze runs 20 times in a 256 MiB guest: one probe session of 20 py_analyze calls (make_probe.py from the
#     pycache corpus, as classprobe.sh), rung.sh ARM 1 pycache-d64 with E17B_GUEST_RAM_MB=256, E15_START_ZERO=1,
#     E15_MAX_SESSIONS=1, no warm-up or spread, a 3600 s window (20 runs at the 136 s Exec timeout fit; the run ends
#     with its session), E15_TAG=g256-s<scale> and E17C_GATE_LIBRARY = library-256.json with py_analyze the RSS
#     wrapper at that scale (analysis/gate256.py: analyze_cmd's program as a ../venv/bin/python child, then peak_rss_kb from
#     getrusage(RUSAGE_CHILDREN), exit 137 when OOM-killed). analysis/gate256.py write then picks the largest scale
#     whose runs in both arms are all ok, none OOM-killed (exit or failed_rc 137), with peak RSS <= 120 MiB, and writes
#     $E15_RUNS/pycache-d64/gate-256.json (per scale and arm: runs, OOM kills, peak RSS, pass and reason; the chosen
#     scale, pass, reason, py_analyze_ms and moca_commit), pass or fail, and is DONE; a rung that fails is a rig error
#     and fails the stage (no file). An old gate file is removed before anything else, the preflight included. Its
#     rungs are calibration only: no lease analysis runs on them (an OOM-killed py_analyze is the measurement).
#     The gate REPORTS the scale; it never edits library-256.json. The controller commits it there (a reviewed
#     change: gate256.analyze_cmd(<scale>), replacing the placeholder 0; config.py is never edited, R-z1), runs gen_corpora.sh --gate-256 (the
#     pycache-256 corpus), sync.sh and E17C=1 setup.sh, then the ram256 stages.
#   seal: first the gated pycache N = 1 seeds (ruling R-z2; SPEC §13.6 puts them after the seal): for each arm, sbx
#     first, then ship-300 and ship-300-nd (lat-pycache-ARM-n1), SEAL_SEEDS (11 12 13 14) fresh seeds, rung.sh ARM 1
#     pycache with E15_SEED=k, E15_TAG=lk (rung N1-l<k>) and E15_START_ZERO=1, all set by the chain (R-h); exactly 4,
#     never topped up (verdict_e17c.py judges the N = 1 half on the evaluable ones, >= 4 per arm, else null; the cal-*
#     seeds N1-s<k> stay calibration). sbx runs first, so each ship rung's analysis finds the same-named sbx rung
#     (--sbx, R-z3). Then the pycache N=128 rungs (three arms); pycache-low's baselines and N=128 rungs (sbx, ship-300); the squeeze
#     baselines, the ship-300 climb at E17B_SQUEEZE_MEMMAX_MB 24576 (fixed by the chain, passed to ladder.sh as
#     E15_SQUEEZE_MEMMAX_MB) and sbx at its stop N; ownwalk 10000 100000.
#   ram256: pycache-d64 N=1 and the squeeze-256 point at 256 MiB guests (E17B_GUEST_RAM_MB=256), as E17b's, on
#     library-256.json and the pycache-256 corpus (points.sh under E17C=1). Each reads gate-256.json first
#     (analysis/gate256.py state): none, an unreadable one, one from another moca_commit, one that did not pass, or a
#     library-256.json whose scale is not the gate's chosen one (the placeholder 0 included) refuses the stage, naming why.
#   opt: the default baselines (base-default-ARM: baseline.sh default ARM at the pin, ruling R-z4, as chain-e17b.sh's
#     cal-default-*: ladder.sh needs default/ARM/N1/baseline.json), then the default ladders (sbx, ship-300); ownwalk-500k, which needs a snapshot whose workspace drive is >= 4 GiB
#     (moca #907's open half): the snapshot manifest records no workspace drive size yet, so it is SKIPPED with that
#     reason (ruling R-n: exit 0, its .done and .log say skipped), and the chain goes on to verdict.
#   verdict (last, seal): analysis/verdict_e17c.py over $E15_RUNS at the pin to $L/verdict.json (Task 7 writes it; a
#     missing script fails the stage, naming it).
#
# Before a stage, its run directories must hold no params.json from another moca commit than E17C_MOCA_PIN. After a
# stage, chain-e17b.sh's gate: every rung it wrote is checked for its own failure, and every ship-* rung (ship-300-nd
# included) is analysed: warmcold_lease.py, lease_ends.py, freed_from_shmem.py, vm_age_lease.py (--sbx the same-named
# sbx rung). After a measured stage (not "-"), latency_report.py runs to $L/<stage>.latency/ (informational).
#
# Output: "E17C <stage> START|DONE|FAILED|SKIP ..." lines. Exit 0 when every selected stage is done, 1 on a refusal or
# a failed stage, 2 on bad usage.
# Test hooks: E17C_RUNG, E17C_LADDER, E17C_BASELINE, E17C_SMOKE, E17C_OWNWALK replace rung.sh, ladder.sh, baseline.sh,
# smoke.sh, ownwalk.sh; E17C_ANALYSIS the analysis directory. They are honoured only with E17C_TEST_HARNESS=1 (set by
# tests/chain-e17c.test.sh); otherwise any of them set refuses the chain like a knob.
set -uo pipefail
E15_PROG=chain-e17c.sh
# E17B-R36 / ruling R-h: refuse to start while a stage-changing knob, or (outside the test harness) a test hook, is set.
STAGE_KNOBS=(E15_RUNG E15_MAX_COMMITTED_MB E15_MAX_RUNS E15_LADDER_EXTRA E15_SPREAD_S E15_MEMAVAIL_FLOOR_MIB
  E15_END_SESSION_RATE E15_ATTACH_TIMEOUT_S E15_BASELINE_MAX_SEEDS E15_WS_DELTA_MB E15_CLASSPROBE E15_PROBE_CALLS
  E15_PROBE_SEED E15_MEMINFO E15_OS_RELEASE E15_SLICE_DIR E15_STATS_URL E15_PROC E15_DISK_DEV E15_DISK_PATH
  E15_SQUEEZE_ACTIVE E15_SQUEEZE_RESTORED E15_SQUEEZE_ORIG_MAX E15_SQUEEZE_ORIG_HIGH E15_SQUEEZE_MAX E15_SQUEEZE_HIGH
  E17C_GATE_LIBRARY)
TEST_HOOKS=(E17C_RUNG E17C_LADDER E17C_BASELINE E17C_SMOKE E17C_OWNWALK E17C_ANALYSIS)
SQUEEZE_MB=24576 # SPEC §13.2: the squeeze's MemoryMax, as in E17b
knobs_set=()
for v in "${STAGE_KNOBS[@]}"; do [ -z "${!v+x}" ] || knobs_set+=("$v"); done
if [ "${E17C_TEST_HARNESS:-}" != 1 ]; then
  for v in "${TEST_HOOKS[@]}"; do [ -z "${!v+x}" ] || knobs_set+=("$v"); done
fi
if [ ${#knobs_set[@]} -gt 0 ]; then
  echo "E17C REFUSED: stage-changing variable(s) set in the environment: ${knobs_set[*]}; unset them (a leftover from an E16 or probe shell would change a sealed measurement silently; E17C_* hooks are for tests/chain-e17c.test.sh only)" >&2
  exit 1
fi
e17b_set=()
for v in E17B_OPTIONAL E17B_RAM256; do [ -z "${!v+x}" ] || e17b_set+=("$v"); done
if [ ${#e17b_set[@]} -gt 0 ]; then
  echo "E17C REFUSED: E17b's switch(es) set in the environment: ${e17b_set[*]}; E17c's are E17C_OPTIONAL and E17C_RAM256" >&2
  exit 1
fi
if [ -n "${E17B_SQUEEZE_MEMMAX_MB+x}" ] && [ "$E17B_SQUEEZE_MEMMAX_MB" != "$SQUEEZE_MB" ]; then
  echo "E17C REFUSED: E17B_SQUEEZE_MEMMAX_MB=$E17B_SQUEEZE_MEMMAX_MB; E17c's squeeze runs at $SQUEEZE_MB MiB (SPEC §13.2), set by the chain: unset it" >&2
  exit 1
fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export E17C=1 E17B=1
export E15_HOST_PROFILE=fresh-metal
export E15_MANIFEST=${E15_MANIFEST:-$HOME/e17-manifest.md}
SQUEEZE256_MB=${E17B_SQUEEZE256_MEMMAX_MB:-}
unset E15_MAX_SESSIONS E15_START_ZERO E15_TAG E15_SEED E15_WARMUP_S E15_WINDOW_S E15_GRACE_S E15_LADDER_RUNGS \
  E15_LADDER_TAG E15_K_MULT E15_CORPUS_OVERRIDE E15_END_SESSION_DEFER E15_SQUEEZE_MEMMAX_MB E17B_GUEST_RAM_MB
E15_RIG=$HERE/../../e15/rig
[ -f "$E15_RIG/lib.sh" ] || {
  printf '%s: no %s/lib.sh: run the staged copy (/srv/e15/src/e17/rig/chain-e17c.sh)\n' "$E15_PROG" "$E15_RIG" >&2
  exit 1
}
# shellcheck source=SCRIPTDIR/../../e15-session-density/rig/lib.sh
. "$E15_RIG/lib.sh"
E17_SRC=$E15_ROOT/src/e17
case "$HERE" in "$E17_SRC"/rig) ;; *) die "run the staged copy: $E17_SRC/rig/chain-e17c.sh (not $HERE)" ;; esac
PREDICTIONS=$E17_SRC/predictions-e17c.json
RUNG=${E17C_RUNG:-$E15_SRC/rig/rung.sh}
LADDER=${E17C_LADDER:-$E15_SRC/rig/ladder.sh}
BASELINE=${E17C_BASELINE:-$E15_SRC/rig/baseline.sh}
SMOKE=${E17C_SMOKE:-$E17_SRC/rig/smoke.sh}
OWNWALK=${E17C_OWNWALK:-$E17_SRC/rig/ownwalk.sh}
ANALYSIS=${E17C_ANALYSIS:-$E17_SRC/analysis}
L=$E15_ROOT/e17c
CAL_SEEDS=4      # SPEC §13.5 (R52): at least 4 seeds per arm at N = 1
CAL_MAX_SEEDS=12 # baseline.sh's own cap
SEAL_SEEDS="11 12 13 14" # ruling R-z2: the gated N = 1 seeds, after the seal (N1-l<k>), apart from cal's N1-s<k>
SKIP_MARK="E17C-STAGE-SKIPPED: skipped:" # a stage's log line that turns its success into a SKIP (ownwalk-500k, R-n)
GATE_MARK="E17C-GATE:"                   # a gate stage's log line with its verdict, shown on the DONE line
# gate-pycache-low (SPEC §13.5, R47): its seeds, window, threshold, classes (criterion 2's) and arms
LOW_SEEDS=4
LOW_WINDOW_S=1800
LOW_MIN_CALLS=3
LOW_CLASSES="py_short py_import"
LOW_ARMS="sbx ship-300"
LOW_GATE=$E15_RUNS/pycache-low/gate-pycache-low.json # ruling R-q: verdict_e17c.py reads it here
# gate-256 (Task 10; SPEC §13.5, R45): candidate scales (descending), arms, runs per arm and scale, the RSS bar
G256=$E15_RUNS/pycache-d64/gate-256.json # ruling R-x
G256_SCALES="32 16 8 4 2 1"
G256_ARMS="sbx ship-300"
G256_RUNS=20
G256_RSS_MIB=120
G256_WINDOW_S=3600
LIB256=$E17_SRC/workload/library-256.json
GATE256=$E17_SRC/analysis/gate256.py

# name|needs|command[|note]: needs is "-" (allowed before the seal), "seal", "ram256" (seal, and E17C_RAM256=1) or
# "opt" (seal, and E17C_OPTIONAL=1).
STAGES=(
  # bring-up and calibration (SPEC §13.6), before the seal: the predictions are drafted from these
  "smoke|-|smoke"
  "cal-pycache-sbx|-|cal pycache sbx"
  "cal-pycache-ship-300|-|cal pycache ship-300"
  "cal-pycache-ship-300-nd|-|cal pycache ship-300-nd"
  "gate-pycache-low|-|gate-pycache-low|Task 9: pycache-low's baseline gate (E15_START_ZERO=1, 1800 s window; per seed >= 3 in-window py_short+py_import with >= 1 of each, per arm >= MIN_CLASS_CALLS of each pooled)"
  "gate-256|-|gate-256|Task 10: the 256 MiB library's calibration (peak RSS <= 120 MiB, zero OOM kills in 20 runs per arm)"
  # pycache N = 1 after the seal (ruling R-z2, SPEC §13.6): 4 fresh seeds per arm, the gated N = 1 half; sbx first
  "lat-pycache-sbx-n1|seal|seal-seeds pycache sbx|seeds 11-14 (N1-l<k>), E15_START_ZERO=1 (R-z2)"
  "lat-pycache-ship-300-n1|seal|seal-seeds pycache ship-300|seeds 11-14 (N1-l<k>), E15_START_ZERO=1 (R-z2)"
  "lat-pycache-ship-300-nd-n1|seal|seal-seeds pycache ship-300-nd|seeds 11-14 (N1-l<k>), E15_START_ZERO=1 (R-z2)"
  # pycache N = 128, three arms
  "lat-pycache-sbx-n128|seal|rung sbx 128 pycache"
  "lat-pycache-ship-300-n128|seal|rung ship-300 128 pycache"
  "lat-pycache-ship-300-nd-n128|seal|rung ship-300-nd 128 pycache"
  # pycache-low: its baselines, then N = 128 (sbx, ship-300)
  "base-pycache-low-sbx|seal|baseline-low pycache-low sbx|E15_START_ZERO=1, 1800 s window; cut if gate-pycache-low failed"
  "base-pycache-low-ship-300|seal|baseline-low pycache-low ship-300|E15_START_ZERO=1, 1800 s window; cut if gate-pycache-low failed"
  "lat-pycache-low-sbx-n128|seal|rung sbx 128 pycache-low|cut if gate-pycache-low failed"
  "lat-pycache-low-ship-300-n128|seal|rung ship-300 128 pycache-low|cut if gate-pycache-low failed"
  # squeeze: its baselines, the ship-300 climb at 24576 MiB, sbx at its stop N
  "base-squeeze-sbx|seal|baseline squeeze sbx"
  "base-squeeze-ship-300|seal|baseline squeeze ship-300"
  "squeeze-ship-300|seal|squeeze-ladder squeeze ship-300|E17B_SQUEEZE_MEMMAX_MB 24576, fixed by the chain (SPEC §13.2, as in E17b); budget = MemoryMax - 8192 (E17B-R20)"
  "squeeze-sbx|seal|squeeze-rung squeeze sbx"
  # the ownership walk (Q7), 10 000 and 100 000 files
  "ownwalk|seal|ownwalk 10000 100000|normalise_us per size from the phase line, beside A - B"
  # the 256 MiB guests (if Task 10's gate passed), D scaled to the same dataset-to-RAM ratio
  "ram256-pycache-sbx-n1|ram256|rung256 sbx 1 pycache-d64"
  "ram256-pycache-ship-300-n1|ram256|rung256 ship-300 1 pycache-d64"
  "ram256-base-squeeze-sbx|ram256|baseline256 squeeze-256 sbx"
  "ram256-base-squeeze-ship-300|ram256|baseline256 squeeze-256 ship-300"
  "ram256-squeeze-ship-300|ram256|squeeze-ladder squeeze-256 ship-300|budget = MemoryMax - 8192 (its own E17B_SQUEEZE256_MEMMAX_MB)"
  "ram256-squeeze-sbx|ram256|squeeze-rung squeeze-256 sbx"
  # optional: the default ladder pair (SPEC §13.2), each after its baseline at the pin (R-z4), and the 500 000-file walk
  "base-default-sbx|opt|baseline default sbx"
  "base-default-ship-300|opt|baseline default ship-300"
  "ladder-default-sbx|opt|ladder default sbx 56"
  "ladder-default-ship-300|opt|ladder default ship-300 80"
  "ownwalk-500k|opt|ownwalk-big 500000|needs a snapshot whose workspace drive is >= 4 GiB (moca #907's open half); skipped until the manifest records one"
  # the criteria, computed by code from every rung (Task 7): $L/verdict.json
  "verdict|seal|verdict|analysis/verdict_e17c.py over the runs (Task 7)"
)

usage() {
  echo "usage: chain-e17c.sh [--list] [--from STAGE] [--to STAGE]" >&2
  exit 2
}
s_name() { printf '%s' "${1%%|*}"; }
s_needs() {
  local r=${1#*|}
  printf '%s' "${r%%|*}"
}
s_cmd() { # the third field: the command (an optional fourth field is a note, never part of the command)
  local r=${1#*|}
  r=${r#*|}
  printf '%s' "${r%%|*}"
}
s_note() { # the optional fourth field, shown by --list only
  local r=${1#*|}
  r=${r#*|}
  case "$r" in *"|"*) printf '%s' "${r#*|}" ;; esac
}
stage_index() { # NAME -> its index, or return 1
  local i
  for i in "${!STAGES[@]}"; do [ "$(s_name "${STAGES[$i]}")" = "$1" ] && echo "$i" && return 0; done
  return 1
}

# sealed: predictions-e17c.json parses and says "sealed": true (the boolean).
sealed() {
  python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("sealed") is True else 1)' "$PREDICTIONS" 2>/dev/null
}
seal_state() {
  if [ ! -f "$PREDICTIONS" ]; then
    echo "missing ($PREDICTIONS)"
  elif sealed; then
    echo sealed
  else
    echo "not sealed ($PREDICTIONS has no \"sealed\": true)"
  fi
}

LIST=0 FROM="" TO=""
while [ $# -gt 0 ]; do
  case "$1" in
  --list) LIST=1 ;;
  --from)
    [ $# -ge 2 ] || usage
    FROM=$2
    shift
    ;;
  --to)
    [ $# -ge 2 ] || usage
    TO=$2
    shift
    ;;
  *) usage ;;
  esac
  shift
done
if [ -n "$FROM" ]; then stage_index "$FROM" >/dev/null || {
  echo "chain-e17c.sh: no stage '$FROM' (--list shows them)" >&2
  exit 2
}; fi
if [ -n "$TO" ]; then stage_index "$TO" >/dev/null || {
  echo "chain-e17c.sh: no stage '$TO' (--list shows them)" >&2
  exit 2
}; fi

if [ "$LIST" = 1 ]; then
  echo "E17C stages (predictions: $(seal_state)); needs: - before the seal, seal, opt (E17C_OPTIONAL=1), ram256 (E17C_RAM256=1)"
  for st in "${STAGES[@]}"; do
    n=$(s_name "$st")
    printf '%-32s %-6s %-5s %s%s\n' "$n" "$(s_needs "$st")" "$([ -f "$L/$n.done" ] && echo "done" || echo -)" "$(s_cmd "$st")" "$(n2=$(s_note "$st"); [ -n "$n2" ] && printf '  # %s' "$n2")"
  done
  exit 0
fi

# --- the selection: [first, last]; opt and ram256 stages only with their switch ------------------------------------
last=$((${#STAGES[@]} - 1))
[ -z "$TO" ] || last=$(stage_index "$TO")
selected() {
  case "$(s_needs "${STAGES[$1]}")" in
  opt) [ "${E17C_OPTIONAL:-0}" = 1 ] ;;
  ram256) [ "${E17C_RAM256:-0}" = 1 ] ;;
  *) true ;;
  esac
}
if [ -n "$FROM" ]; then
  first=$(stage_index "$FROM")
else
  first=""
  for i in $(seq 0 "$last"); do
    if selected "$i" && [ ! -f "$L/$(s_name "${STAGES[$i]}").done" ]; then
      first=$i
      break
    fi
  done
  if [ -z "$first" ]; then
    echo "E17C every selected stage up to $(s_name "${STAGES[$last]}") is done ($L/*.done)"
    exit 0
  fi
  echo "E17C resuming at $(s_name "${STAGES[$first]}") (the first selected stage without $L/<stage>.done)"
fi
[ "$first" -le "$last" ] || {
  echo "chain-e17c.sh: --from $(s_name "${STAGES[$first]}") comes after --to $(s_name "${STAGES[$last]}")" >&2
  exit 2
}

# --- refusals before anything runs -------------------------------------------------------------------------------
need_seal=()
for i in $(seq "$first" "$last"); do
  selected "$i" || continue
  [ "$(s_needs "${STAGES[$i]}")" = - ] || need_seal+=("$(s_name "${STAGES[$i]}")")
done
if [ ${#need_seal[@]} -gt 0 ] && ! sealed; then
  echo "E17C REFUSED: predictions $(seal_state); no measured rung runs before the predictions are sealed (spec §9)." >&2
  echo "E17C REFUSED: stages that need the seal: ${need_seal[*]} (stop before them with --to gate-256)" >&2
  exit 1
fi
e17c_require_pin
e17b_require_pin
e17b_require_build
refuse_outside_root "$L"
mkdir -p "$L"
if unit_active "$E15_UNIT_WORKER"; then die "a rung's worker ($E15_UNIT_WORKER) is running; refusing to preempt it"; fi

# preflight POINT ARM...: no params.json under $E15_RUNS/POINT/ARM from another moca commit.
preflight() {
  local point=$1 bad
  shift
  bad=$(python3 - "$E15_RUNS/$point" "$E15_MOCA_PIN" "$@" <<'PY'
import glob, json, os, sys
root, pin, arms = sys.argv[1], sys.argv[2], sys.argv[3:]
for arm in arms:
    for p in sorted(glob.glob(os.path.join(root, arm, "*", "params.json"))):
        try:
            c = json.load(open(p)).get("moca_commit")
        except (OSError, ValueError):
            c = "unreadable"
        if c != pin:
            print("%s (moca_commit %s)" % (p, c))
            sys.exit(0)
PY
  ) || die "preflight check failed under $E15_RUNS/$point (${bad:-no output}): refusing, not passing"
  [ -z "$bad" ] || die "$bad is not from E17C_MOCA_PIN $E15_MOCA_PIN: a result that mixes commits is not one arm; move that arm's runs aside first"
}

# rung_flags DIR: why the rung itself failed, "" when it did not (chain-e17b.sh's, I3).
rung_flags() {
  python3 - "$1" <<'PY'
import json, os, sys
d = sys.argv[1]
p = json.load(open(os.path.join(d, "params.json")))
rp = os.path.join(d, "record.json")
r = json.load(open(rp)) if os.path.exists(rp) else None
why = []
rf = p.get("rung_failed")
if rf is not None and (not p.get("memory_abort") or str(rf).startswith("set_mode_failed")):
    why.append("rung_failed %s" % rf)
de = p.get("driver_exit") or 0
if r is not None and r.get("aborted") is True:
    why.append("record.json aborted (driver_exit %s)" % de)
elif r is None and de != 0 and not p.get("memory_abort"):
    why.append("driver_exit %s (no memory abort)" % de)
print("; ".join(why))
PY
}

# gate MARKER: check every rung written since MARKER for its own failure flags (every arm), then analyse each ship-*
# rung (ship-300-nd included); 1 when the chain must stop. chain-e17b.sh's gate, unchanged.
gate() {
  local marker=$1 rc=0 d arm f out sbxd extra note
  while IFS= read -r f; do
    d=$(dirname "$f")
    out=$(rung_flags "$d" 2>/dev/null) || out="the rung flags are unreadable ($f)"
    if [ -n "$out" ]; then
      echo "E17C $STAGE STOP ${d#"$E15_RUNS"/}: $out (the rung failed: goes to the user)"
      rc=1
      continue
    fi
    arm=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("arm", ""))' "$f" 2>/dev/null)
    case "$arm" in ship-*) ;; *) continue ;; esac
    # gate-256's rungs are calibration only: an OOM-killed py_analyze is its measurement, not a lease failure
    [ "$STAGE" != gate-256 ] || continue
    sbxd=$(dirname "$(dirname "$d")")/sbx/$(basename "$d")
    for a in warmcold_lease.py lease_ends.py freed_from_shmem.py vm_age_lease.py; do
      extra=()
      [ "$a" != vm_age_lease.py ] || [ ! -f "$sbxd/params.json" ] || extra=(--sbx "$sbxd")
      out=$(python3 "$ANALYSIS/$a" "$d" ${extra[@]+"${extra[@]}"} 2>&1) || {
        echo "E17C $STAGE ANALYSIS $a failed on $d: $(printf '%s' "$out" | tail -1)"
        rc=1
        continue 2
      }
      echo "E17C $STAGE $a ${d#"$E15_RUNS"/}: $out"
    done
    out=$(python3 - "$d" <<'PY'
import json, sys
d = sys.argv[1]
w = json.load(open(d + "/warmcold-report.json"))
e = json.load(open(d + "/lease_ends.json"))
v = json.load(open(d + "/vm_age_lease.json"))
why = []
if w.get("unknown"):
    why.append("%d unknown call(s)" % w["unknown"])
if w.get("disagreements"):
    why.append("%d source disagreement(s)" % w["disagreements"])
if w.get("config_refusals"):
    why.append("%d configuration refusal(s) %s" % (w["config_refusals"],
                                                    json.dumps(w.get("config_refusals_by_cause") or {}, sort_keys=True)))
if w.get("valid") is False:
    why.append("warmcold-report valid false")
un = (e.get("notices") or {}).get("unmatched_ends") or []
if un:
    why.append("%d unmatched lease end(s)" % len(un))
if e.get("valid") is False:
    why.append("lease_ends.json valid false (%s)" % "; ".join(e.get("invalid_reasons") or []))
if e.get("criterion4_pass") is False:
    why.append("criterion 4 failed")
if v.get("mapping_valid") is False:
    why.append("vm_age_lease mapping_valid false (%s)" % "; ".join(v.get("mapping_reasons") or []))
print("; ".join(why))
PY
    ) || out="the analysis outputs are unreadable"
    if [ -n "$out" ]; then
      echo "E17C $STAGE STOP ${d#"$E15_RUNS"/}: $out (goes to the user)"
      rc=1
    fi
    note=$(python3 -c 'import json,sys; w=json.load(open(sys.argv[1] + "/warmcold-report.json")); n=w.get("failed_no_vm") or 0
print("%d failed_no_vm call(s) %s by cause %s" % (n, json.dumps(w.get("failed_no_vm_by_reason") or {}, sort_keys=True),
                                                  json.dumps(w.get("failed_no_vm_by_cause") or {}, sort_keys=True)) if n else "")' "$d" 2>/dev/null) || note=""
    [ -z "$note" ] || echo "E17C $STAGE NOTE ${d#"$E15_RUNS"/}: $note (reported, not a stop: criterion 3's refusal check judges them)"
  done < <(find "$E15_RUNS" -name params.json -newer "$marker" 2>/dev/null | sort)
  return "$rc"
}

# latency MARKER OUT: latency_report.py over every rung written since MARKER (every arm), to OUT. Informational.
latency() {
  local dirs=() f out
  while IFS= read -r f; do dirs+=("$(dirname "$f")"); done < <(find "$E15_RUNS" -name params.json -newer "$1" 2>/dev/null | sort)
  [ ${#dirs[@]} -gt 0 ] || return 0
  if out=$(python3 "$ANALYSIS/latency_report.py" "${dirs[@]}" --out "$2" 2>&1); then
    echo "E17C $STAGE latency_report.py: $2"
  else
    echo "E17C $STAGE latency_report.py FAILED (not a stop): $(printf '%s' "$out" | tail -1)"
  fi
}

# sq_point POINT: the squeeze point's MemoryMax (sq_mb, from the variable sq_var) and guest RAM (sq_ram; empty: 1024).
sq_point() {
  case "$1" in
  squeeze) sq_var=E17B_SQUEEZE_MEMMAX_MB sq_mb=$SQUEEZE_MB sq_ram="" ;;
  squeeze-256) sq_var=E17B_SQUEEZE256_MEMMAX_MB sq_mb=$SQUEEZE256_MB sq_ram=256 ;;
  *) die "sq_point: $1 is not a squeeze point" ;;
  esac
}

# cal_seeds POINT ARM: "<evaluable> <highest k>" over $E15_RUNS/POINT/ARM/N1-s<k>: a seed is evaluable when its
# record.json exists and its reason is not empty_window (baseline.sh's rule).
cal_seeds() {
  python3 - "$E15_RUNS/$1/$2" <<'PY'
import json, os, re, sys
root, ok, top = sys.argv[1], 0, 0
for n in os.listdir(root) if os.path.isdir(root) else []:
    m = re.fullmatch(r"N1-s([0-9]+)", n)
    if not m:
        continue
    top = max(top, int(m.group(1)))
    rp = os.path.join(root, n, "record.json")
    if os.path.exists(rp) and json.load(open(rp)).get("reason") != "empty_window":
        ok += 1
print(ok, top)
PY
}

# gate_low_write: gate-pycache-low's verdict over its seed rungs N1-g<k> at pycache-low, written to LOW_GATE (ruling
# R-q); prints "PASS: ..." or "FAIL: ...". Exits non-zero (no file) on a missing or unreadable record.json/calls.jsonl.
gate_low_write() {
  python3 - "$E15_SRC/analysis" "$E15_RUNS/pycache-low" "$LOW_GATE" "$E15_MOCA_PIN" "$LOW_WINDOW_S" "$LOW_SEEDS" \
    "$LOW_MIN_CALLS" "$LOW_CLASSES" "$LOW_ARMS" <<'PY'
import json, os, sys
an, root, out, pin, window, seeds, need, classes, arms = sys.argv[1:]
sys.path.insert(0, an)
import holds as H  # noqa: E402
from record import read_jsonl  # noqa: E402
window, seeds, need, classes, arms = int(window), int(seeds), int(need), classes.split(), arms.split()
res, fails = {}, []
for arm in arms:
    res[arm] = []
    for k in range(1, seeds + 1):
        name = "N1-g%d" % k
        d = os.path.join(root, arm, name)
        try:
            rec = json.load(open(os.path.join(d, "record.json")))
        except (OSError, ValueError) as e:
            sys.exit("%s/record.json is missing or unreadable (%s): no gate" % (d, e))
        if not os.path.exists(os.path.join(d, "calls.jsonl")):
            sys.exit("%s has no calls.jsonl: no gate" % d)
        ok = H.window_ok_calls(read_jsonl(os.path.join(d, "calls.jsonl")))
        by = {c: sum(1 for x in ok if x.get("class") == c) for c in classes}
        n = sum(by.values())
        why = None
        if n < need or min(by.values()) < 1:  # R-t: >= need combined AND >= 1 of each class
            rr = rec.get("reason")
            why = "%s seed %d (%s): %d in-window %s call(s) (%s%s), need %d with at least 1 of each" % (
                arm, k, name, n, "/".join(classes), ", ".join("%s %d" % (c, by[c]) for c in classes),
                "; record reason %s" % rr if rr and rr != "ok" else "", need)
            fails.append(why)
        res[arm].append({"seed": k, "rung": "pycache-low/%s/%s" % (arm, name), "record_reason": rec.get("reason"),
                         "in_window": by, "calls": n, "pass": why is None, "reason": why})
# R-u: the N = 128 rungs' class-matched baseline needs MIN_CLASS_CALLS of each class per arm, pooled over its seeds
pooled = {}
for arm in arms:
    by = {c: sum(s["in_window"][c] for s in res[arm]) for c in classes}
    short = [c for c in classes if by[c] < H.MIN_CLASS_CALLS]
    why = None
    if short:
        why = "%s pooled over its %d gate seeds: %s, need %d of each (holds.MIN_CLASS_CALLS: the N=128 rungs' " \
              "class-matched baseline)" % (arm, seeds, ", ".join("%s %d" % (c, by[c]) for c in short),
                                           H.MIN_CLASS_CALLS)
        fails.append(why)
    pooled[arm] = {"in_window": by, "pass": why is None, "reason": why}
passed = not fails
reason = ("every seed of %s has >= %d in-window %s calls with >= 1 of each, and each arm pools >= %d of each" % (
    " and ".join(arms), need, "/".join(classes), H.MIN_CLASS_CALLS) if passed else "; ".join(fails))
doc = {"stage": "gate-pycache-low", "spec": "SPEC §13.5 (R47)", "point": "pycache-low", "moca_commit": pin,
       "start_zero": True, "window_s": window, "seeds_per_arm": seeds, "min_calls": need, "min_per_class_per_seed": 1,
       "min_class_calls_pooled": H.MIN_CLASS_CALLS, "classes": classes,
       "counted": "in-window calls with status ok (holds.window_ok_calls)", "arms": res, "pooled": pooled,
       "pass": passed, "reason": reason}
tmp = out + ".tmp"
with open(tmp, "w") as f:
    json.dump(doc, f, indent=1, sort_keys=True)
    f.write("\n")
os.replace(tmp, out)
print(("PASS: " + reason) if passed else ("FAIL: %s; pycache-low is cut (its baselines and N=128 rungs are skipped)" % reason))
PY
}

# low_gate_state: "pass", "cut <reason>" or "refuse <why>" from LOW_GATE: refused when the file is unreadable, has no
# boolean "pass", or (R-w) was written for another moca_commit, window_s or start_zero than the chain's.
low_gate_state() {
  python3 - "$LOW_GATE" "$E15_MOCA_PIN" "$LOW_WINDOW_S" <<'PY'
import json, sys
path, pin, window = sys.argv[1], sys.argv[2], int(sys.argv[3])
try:
    g = json.load(open(path))
except (OSError, ValueError):
    g = None
if not isinstance(g, dict) or not isinstance(g.get("pass"), bool):
    print("refuse %s is unreadable (no boolean \"pass\"): re-run gate-pycache-low" % path)
    sys.exit(1)
want = {"moca_commit": pin, "window_s": window, "start_zero": True}
bad = ["%s %s, not %s" % (k, json.dumps(g.get(k)), json.dumps(v)) for k, v in want.items()
       if json.dumps(g.get(k)) != json.dumps(v)]  # strict: 1 is not true
if bad:
    print("refuse %s is not this chain's gate (%s): re-run gate-pycache-low" % (path, "; ".join(bad)))
    sys.exit(1)
print("pass" if g["pass"] else "cut %s" % (g.get("reason") or "no reason recorded"))
PY
}

# run_cmd KIND ARGS...: one stage's work (its output goes to the stage log).
run_cmd() {
  local kind=$1 n mm ok top out arm k s gin prev
  shift
  # E17B-R51: 8 MiB per workspace at the pycache family and the squeeze points (run_cmd runs in a subshell).
  case " $* " in *" pycache"* | *" squeeze"*) export E15_WS_DELTA_MB=8 ;; esac
  # Task 9: a pycache-low stage runs only after gate-pycache-low passed; a failed gate cuts it (a SKIP, R-n's form).
  case " $* " in *" pycache-low "*)
    [ -f "$LOW_GATE" ] || die "no $LOW_GATE: run gate-pycache-low first (SPEC §13.5: pycache-low runs only after its gate)"
    out=$(low_gate_state) || die "${out:+${out#refuse }}${out:-$LOW_GATE could not be checked: re-run gate-pycache-low}"
    if [ "$out" != pass ]; then
      echo "$SKIP_MARK pycache-low cut by gate-pycache-low: ${out#cut } ($LOW_GATE; SPEC §13.5, R47)"
      return 0
    fi
    ;;
  esac
  # Task 10 (ruling R-x): a 256 MiB stage runs only after gate-256 passed at this pin and its scale is committed.
  case " $* " in *" pycache-d64 "* | *" squeeze-256 "*)
    out=$(python3 "$GATE256" state --gate "$G256" --moca-commit "$E15_MOCA_PIN" --library "$LIB256") ||
      die "${out:-$G256 could not be checked: re-run gate-256}"
    echo "gate-256: passed, scale ${out#pass } ($G256), carried by $LIB256"
    ;;
  esac
  case "$kind" in
  smoke)
    preflight pycache sbx ship-300 ship-300-nd
    bash "$SMOKE"
    ;;
  cal) # POINT ARM: the N = 1 baseline from the first call (E15_START_ZERO=1), then seeds up to CAL_SEEDS evaluable
    preflight "$1" "$2"
    E15_START_ZERO=1 bash "$BASELINE" "$1" "$2" || die "baseline.sh $1 $2 failed"
    while :; do
      # review fix 1: an unreadable record.json must fail the stage, never pass as "enough seeds"
      out=$(cal_seeds "$1" "$2") || die "the seeds under $E15_RUNS/$1/$2 are unreadable (a corrupt N1-s*/record.json?): no calibration"
      read -r ok top <<<"$out"
      [[ ${ok:-} =~ ^[0-9]+$ && ${top:-} =~ ^[0-9]+$ ]] ||
        die "the seeds under $E15_RUNS/$1/$2 are unreadable (seed count '${out}'): no calibration"
      [ "$ok" -lt "$CAL_SEEDS" ] || break
      [ "$top" -lt "$CAL_MAX_SEEDS" ] ||
        die "$CAL_MAX_SEEDS seeds gave $ok evaluable N=1 runs at $1 $2 (need $CAL_SEEDS, SPEC §13.5): no calibration"
      n=$((top + 1))
      echo "cal: $2 at $1 has $ok evaluable seed(s); seed $n (E15_START_ZERO=1)"
      E15_START_ZERO=1 E15_SEED=$n E15_TAG=s$n bash "$RUNG" "$2" 1 "$1" || die "rung.sh $2 1 $1 (seed $n) failed"
    done
    ;;
  seal-seeds) # POINT ARM: the gated N = 1 seeds after the seal (ruling R-z2), SEAL_SEEDS, exactly these
    preflight "$1" "$2"
    for k in $SEAL_SEEDS; do
      echo "seal-seeds: $2 at $1 seed $k (E15_START_ZERO=1, tag l$k)"
      E15_START_ZERO=1 E15_SEED=$k E15_TAG=l$k bash "$RUNG" "$2" 1 "$1" || die "rung.sh $2 1 $1 (seed $k) failed"
    done
    ;;
  gate-pycache-low) # pycache-low's N = 1 seeds from the first call, 1800 s window; LOW_GATE either way (Task 9)
    rm -f "$LOW_GATE" # R-w: before the preflight, so a refused one leaves no old gate behind
    # shellcheck disable=SC2086 # LOW_ARMS is a word list
    preflight pycache-low $LOW_ARMS
    for arm in $LOW_ARMS; do
      for k in $(seq 1 "$LOW_SEEDS"); do
        echo "gate-pycache-low: $arm seed $k (E15_START_ZERO=1, E15_WINDOW_S=$LOW_WINDOW_S, tag g$k)"
        E15_START_ZERO=1 E15_WINDOW_S=$LOW_WINDOW_S E15_SEED=$k E15_TAG=g$k bash "$RUNG" "$arm" 1 pycache-low ||
          die "rung.sh $arm 1 pycache-low (seed $k) failed: a rig error, not a cut; no gate"
      done
    done
    mkdir -p "$(dirname "$LOW_GATE")"
    out=$(gate_low_write) || die "gate-pycache-low: $out"
    echo "$GATE_MARK gate-pycache-low: $out ($LOW_GATE)"
    ;;
  gate-256) # the 256 MiB library's calibration (Task 10); G256 either way
    rm -f "$G256" # before the preflight, so a refused one leaves no old gate behind
    # shellcheck disable=SC2086 # G256_ARMS is a word list
    preflight pycache-d64 $G256_ARMS
    [ -f "$LIB256" ] || die "no $LIB256 (sync.sh stages experiments/e17-lease/workload/)"
    gin=$E15_RUNS/pycache-d64/gate-256-inputs
    # an earlier gate run's inputs (its probe corpus and gate libraries, which its moved-aside N1-g256-s*.prev-* rungs
    # name) are moved aside, never deleted; the leaf is checked first, as every other path the chain writes
    refuse_outside_root "$gin"
    if [ -e "$gin" ] || [ -L "$gin" ]; then
      [ -d "$gin" ] && [ ! -L "$gin" ] || die "$gin is not a directory (or is a symlink): refusing to move it aside"
      prev="$gin.prev-$(date -u +%Y%m%dT%H%M%SZ)"
      [ ! -e "$prev" ] || die "$prev exists: refusing to overwrite it"
      mv -- "$gin" "$prev" || die "could not move $gin aside to $prev"
      echo "gate-256: the earlier gate inputs moved aside to $prev"
    fi
    mkdir -p "$gin"
    # one session of G256_RUNS py_analyze calls, drawn from the pycache corpus as classprobe.sh draws a class probe
    python3 "$E15_SRC/analysis/make_probe.py" "$E15_CORPORA/pycache/corpus.jsonl" "$LIB256" "$gin/probe" \
      --per-class "$G256_RUNS" --seed 1 --cap-ms 120000 || die "make_probe.py failed: no gate"
    for s in $G256_SCALES; do
      python3 "$GATE256" library --base "$LIB256" --scale "$s" --out "$gin/library-s$s.json" ||
        die "gate256.py library --scale $s failed: no gate"
      for arm in $G256_ARMS; do
        echo "gate-256: $arm at scale $s ($G256_RUNS py_analyze runs in a 256 MiB guest, tag g256-s$s)"
        E17B_GUEST_RAM_MB=256 E17C_GATE_LIBRARY="$gin/library-s$s.json" E15_CORPUS_OVERRIDE="$gin/probe/py_analyze/corpus.jsonl" \
          E15_START_ZERO=1 E15_MAX_SESSIONS=1 E15_WARMUP_S=0 E15_SPREAD_S=0 E15_WINDOW_S=$G256_WINDOW_S E15_TAG=g256-s$s \
          bash "$RUNG" "$arm" 1 pycache-d64 || die "rung.sh $arm 1 pycache-d64 (scale $s) failed: a rig error, not a fail; no gate"
      done
    done
    out=$(python3 "$GATE256" write --runs "$E15_RUNS/pycache-d64" --out "$G256" --moca-commit "$E15_MOCA_PIN" \
      --scales "$G256_SCALES" --arms "$G256_ARMS" --runs-per "$G256_RUNS" --rss-max-mib "$G256_RSS_MIB" --library "$LIB256" 2>&1) ||
      die "gate-256: $out"
    echo "$GATE_MARK gate-256: $out ($G256)"
    ;;
  baseline)
    preflight "$1" "$2"
    bash "$BASELINE" "$1" "$2"
    ;;
  baseline-low) # POINT ARM: the baseline as gate-pycache-low ran its seeds (SPEC §13.5)
    preflight "$1" "$2"
    E15_START_ZERO=1 E15_WINDOW_S=$LOW_WINDOW_S bash "$BASELINE" "$1" "$2"
    ;;
  rung)
    preflight "$3" "$1"
    E15_TAG=lat bash "$RUNG" "$1" "$2" "$3"
    ;;
  rung256)
    preflight "$3" "$1"
    E17B_GUEST_RAM_MB=256 E15_TAG=ram256 bash "$RUNG" "$1" "$2" "$3"
    ;;
  ladder) # POINT ARM [START_N]
    preflight "$1" "$2"
    bash "$LADDER" "$1" "$2" ${3:+"$3"}
    ;;
  baseline256)
    preflight "$1" "$2"
    E17B_GUEST_RAM_MB=256 bash "$BASELINE" "$1" "$2"
    ;;
  squeeze-ladder) # POINT ARM
    sq_point "$1"
    [ -n "$sq_mb" ] || die "the $1 climb needs $sq_var (MiB, from a first short climb)"
    preflight "$1" "$2"
    env ${sq_ram:+E17B_GUEST_RAM_MB=$sq_ram} E15_SQUEEZE_MEMMAX_MB="$sq_mb" bash "$LADDER" "$1" "$2" ${E17B_SQUEEZE_START_N:+"$E17B_SQUEEZE_START_N"}
    ;;
  squeeze-rung) # POINT ARM
    sq_point "$1"
    local lj=$E15_RUNS/$1/ship-300/ladder.json
    [ -f "$lj" ] || die "no $lj: run the $1 ship-300 climb first"
    n=$(python3 -c 'import json,sys; s=json.load(open(sys.argv[1])).get("squeeze") or {}; print(s.get("stop_n") or "null", s.get("memmax_mb") or "null")' "$lj") ||
      die "$lj is unreadable: refusing (no N or MemoryMax to run $2 at)"
    read -r n mm <<<"$n"
    [ -n "$n" ] && [ -n "${mm:-}" ] || die "$lj is unreadable (no stop_n/memmax_mb): refusing"
    [ "$n" != null ] || die "the ship-300 $1 climb stopped at no N ($lj): nothing to run $2 at"
    [ "$mm" != null ] || die "$lj records no memmax_mb"
    [ -z "$sq_mb" ] || [ "$sq_mb" = "$mm" ] ||
      die "$sq_var=$sq_mb, but the ship-300 climb ran under $mm: $2 runs under the climb's value"
    preflight "$1" "$2"
    echo "squeeze: $2 at N=$n on $1 (the ship-300 climb's stop), E15_SQUEEZE_MEMMAX_MB=$mm${sq_ram:+, E17B_GUEST_RAM_MB=$sq_ram}"
    env ${sq_ram:+E17B_GUEST_RAM_MB=$sq_ram} E15_SQUEEZE_MEMMAX_MB="$mm" E15_TAG=sq bash "$RUNG" "$2" "$n" "$1"
    ;;
  ownwalk) # FILES...: one ownwalk.sh (its own worker cycle) per workspace size, in order
    for n in "$@"; do
      bash "$OWNWALK" "$n" || die "ownwalk.sh $n failed (its ownwalk.json and driver.log: $E15_RUNS/ownwalk/ship-300/F$n)"
    done
    ;;
  ownwalk-big) # FILES: the walk that needs a workspace drive >= 4 GiB (moca #907's open half)
    # The snapshot manifest (build-snapshot.sh) records no workspace drive size today, so no snapshot can show it has
    # one: never run until moca #907 lands and its manifest field is checked here. Ruling R-n: a SKIP with its reason
    # (exit 0, the main loop reads the SKIPPED line), so a resume goes on to verdict.
    echo "$SKIP_MARK ownwalk $1 needs a snapshot whose workspace drive is >= 4 GiB (moca #907's open half), and the snapshot manifest $E15_SNAPDIR/$(worker_snapimg)/manifest.json records no workspace drive size; deferred again (SPEC §13.1)"
    ;;
  verdict) # the criteria from every rung at the pin (Task 7)
    [ -f "$ANALYSIS/verdict_e17c.py" ] || die "no $ANALYSIS/verdict_e17c.py (Task 7 writes it): no verdict"
    python3 "$ANALYSIS/verdict_e17c.py" "$E15_RUNS" --moca-commit "$E15_MOCA_PIN" --out "$L/verdict.json"
    ;;
  *) die "unknown stage kind $kind" ;;
  esac
}

rc=0
echo "E17C chain START $(date -u +%FT%TZ) src $(cat "$E15_ROOT/src/COMMIT" 2>/dev/null || echo unknown) pin $E15_MOCA_PIN predictions $(seal_state)"
for i in $(seq "$first" "$last"); do
  st=${STAGES[$i]}
  STAGE=$(s_name "$st")
  if ! selected "$i"; then
    case "$(s_needs "$st")" in
    ram256) echo "E17C $STAGE SKIP (ram256: E17C_RAM256=1 runs it)" ;;
    *) echo "E17C $STAGE SKIP (optional: E17C_OPTIONAL=1 runs it)" ;;
    esac
    continue
  fi
  if [ "$(s_needs "$st")" != - ] && ! sealed; then
    echo "E17C $STAGE REFUSED: predictions $(seal_state)"
    rc=1
    break
  fi
  echo "E17C $STAGE START $(date -u +%FT%TZ) :: $(s_cmd "$st")"
  rm -f "$L/$STAGE.done"
  : >"$L/$STAGE.start"
  read -r -a words <<<"$(s_cmd "$st")" # the command's words (split, never globbed)
  (run_cmd "${words[@]}") >"$L/$STAGE.log" 2>&1
  src=$?
  if [ "$src" != 0 ]; then
    echo "E17C $STAGE FAILED rc=$src $(tail -1 "$L/$STAGE.log" | cut -c1-300) (log $L/$STAGE.log); resume with --from $STAGE"
    rc=1
    break
  fi
  if ! gate "$L/$STAGE.start"; then
    echo "E17C $STAGE FAILED its analysis (above); resume with --from $STAGE after the user decides"
    rc=1
    break
  fi
  why=$(grep -m1 "^$SKIP_MARK" "$L/$STAGE.log")
  if [ -n "$why" ]; then # the stage ran nothing and said why: SKIP, recorded as such in its .done
    why=${why#"$SKIP_MARK" }
    echo "$(date -u +%FT%TZ) skipped: $why" >"$L/$STAGE.done"
    echo "E17C $STAGE SKIP ($why)"
    continue
  fi
  [ "$(s_needs "$st")" = - ] || latency "$L/$STAGE.start" "$L/$STAGE.latency"
  date -u +%FT%TZ >"$L/$STAGE.done"
  note=$(grep -m1 "^$GATE_MARK" "$L/$STAGE.log")
  echo "E17C $STAGE DONE $(date -u +%FT%TZ)${note:+ (${note#"$GATE_MARK" })}"
done
echo "E17C chain END rc=$rc $(date -u +%FT%TZ)"
exit "$rc"
