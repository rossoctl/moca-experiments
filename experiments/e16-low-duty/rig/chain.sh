#!/usr/bin/env bash
# experiments/e16-low-duty/rig/chain.sh STAGE [ARM] -- the E16 run chain on the metal host (experiments/e16-low-duty/PLAN.md Task 6).
#
# Stages (each idempotent: a rung whose counted record already exists is skipped, not re-run):
#   baselines [ARM]     baseline.sh lowduty ARM (N=1 seeds + class probes), sbx and resident-inf
#                       (or ARM alone); skipped where runs/lowduty/ARM/N1/baseline.json exists
#   cal [ARM]           one N=256 rung per arm, tag cal (not a ladder rung), + calib_analyze.py
#   long-rung           resident-inf N=256, warm-up 600 s, window 10800 s, tag long (information,
#                       not a ladder rung), + experiments/e16-low-duty/analysis/long_rung.py (vm_age.py + VM life)
#   ladder-sbx          sbx ladder: RUNGS (default 256 384 512), then extend (640 768 896 1024)
#                       while holding, step down (192 160 128 ...) if the first rung fails, then one
#                       bisecting rung between the last hold and the first failure
#   ladder-resident     resident-inf: RUNGS (default 256 384 512 640 768), extend 896 1024, same rules
#   ladder-resident-ext the SEALED resident extension (1280, 1536; sealed with the predictions) for a
#                       ladder that stopped short of it: continues from the assembled sealed n_max when
#                       it is 1024 (the seeds lifted it after ladder-resident stopped at 1024 on seed 1);
#                       seed 1, stops at the first rung where both verdicts are broken. Rerun seeds after.
#   ladder-sbx-ext      POST-SEAL EXTENSION (user decision 2026-11-08, after seeing SBX hold 1024; not
#                       part of the sealed procedure): only if resident-inf's assembled n_max >= 1024,
#                       SBX runs 1280 then 1536 (while holding). The sealed SBX ladder.json is kept as
#                       ladder.sealed.json; ladder.json then includes the extension and says so
#                       (post_seal_extension). Skipped (SKIP line) when resident's n_max < 1024.
#   stag                SUPPLEMENTARY (user decisions 2026-11-09; not the sealed procedure): resident-inf
#                       with the run-end end-session Execs deferred and paced (E15_END_SESSION_DEFER=1):
#                       N=896 and N=1024, seeds 1 and 2 (tags stag, stag-s2), seed 3 (stag-s3) where
#                       they disagree; majority decides. Every rung gets stag_valid.json (no egress
#                       wedge, no aborted Exec before graceEnd, end_sessions_sent == ok); an INVALID
#                       rung is not counted and is re-run once (tag <tag>-r); invalid twice stops the
#                       stage. If 1024 holds: resident 1280, 1536 (stag) while holding, then SBX 1280,
#                       1536 (tag postseal) while holding. Rows in <arm>/e16-supp/, never in the sealed <arm>/e16/; ladder.json
#                       untouched; the stage's own assembly is <arm>/ladder-supp.json.
#   seeds [ARM]         each arm's deciding rungs (n_max and stopped_at) again with E15_SEED=2
#                       (tag s2); E15_SEED=3 (s3) where s1 and s2 disagree; majority decides
#   control             control at N=768 (A2)
#
# Ladder rungs run one at a time through experiments/e15-session-density/rig/ladder.sh with E15_LADDER_RUNGS=<n> (so every E15
# rule applies: unseeded -> K x2, footprint drift -> repeat with warm-up x2 and K x2). ladder.sh
# rewrites ARM/ladder.json on every call (review M4), so each call's file is moved aside to
# ARM/e16/ladder-N<n>[-sK].json, the counted record becomes ARM/e16/N<n>[-sK].json (chainlib.py
# row), and ARM/ladder.json is re-assembled from those rows after every rung (chainlib.py assemble:
# descending step-down, bisect rungs and gaps between run rungs are handled there). A counted record
# that failed only on grace-end cuts (grace_artefact.py) is re-run once with E15_GRACE_S=900 (tag
# <tag>-g900) and the re-run counts; both records are kept (E15 metal ruling 2026-11-06).
#
# Every rung: E15_HOST_PROFILE=fresh-metal E15_MAX_COMMITTED_MB=4194304 E15_MAX_RUNS=4096
# (experiments/e16-low-duty/SPEC.md §5); K x2 from the start (E15_K_MULT=2: the band's 2.5 h sessions start at a random
# call, so slots cycle through more sessions than K's mean-span formula covers -- ruling in the
# ledger); disk check at the per-image delta measured on the previous rung (measured_delta.py, start
# E16_WS_DELTA0_MB=4); perfsample.sh in each measured window; the OOM/disk sentinel (E15 climb.sh):
# a global OOM outside a memory cgroup or /srv/e15 free < 10 GiB writes $L/STOP and kills the rung.
#
# Output: one line per rung on stdout,
#   E16 <stage> <arm> N=<n> holds=<bool> holds_abs=<bool> p95x=<ms> reason=<..>
# plus "E16 <stage> START|DONE|SKIP|FAILED|STOP ..." lines. Exit 0 done, 1 rig error or STOP, 2 usage.
#
# Test hooks: E16_LADDER / E16_RUNG / E16_BASELINE replace ladder.sh / rung-perf.sh / baseline.sh;
# E16_NO_SENTINEL=1, E16_NO_PERF=1, E16_NO_ANALYSIS=1 switch those parts off; E16_RUNS, E16_LOGDIR,
# E16_SRC, E16_DF_PATH move the run, log and source trees and the disk check's filesystem.
set -uo pipefail
export E15_HOST_PROFILE=fresh-metal E15_MAX_COMMITTED_MB=4194304 E15_MAX_RUNS=4096
unset E15_MAX_SESSIONS E15_START_ZERO E15_TAG E15_SEED E15_WARMUP_S E15_WINDOW_S E15_GRACE_S E15_LADDER_RUNGS E15_LADDER_TAG
export PATH=/srv/e15/bin:$PATH
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC=${E16_SRC:-/srv/e15/src}
R=$SRC/e15/rig
POINT=lowduty
RUNS=${E16_RUNS:-/srv/e15/runs}/$POINT
L=${E16_LOGDIR:-/srv/e15/e16}
LADDER_SH=${E16_LADDER:-$R/ladder.sh}
# rung-perf.sh: rung.sh with perfsample.sh in the measured window (also as ladder.sh's E15_RUNG)
RUNG_SH=${E16_RUNG:-$HERE/rung-perf.sh}
export E16_SRC=$SRC
BASELINE_SH=${E16_BASELINE:-$R/baseline.sh}
CL="python3 $HERE/chainlib.py"
VALID_PY=${E16_VALID_PY:-$SRC/e16/analysis/stag_valid.py}
KM=2
FULL=(1 8 16 24 32 40 48 56 64 80 96 128 160 192 256 320 384 448 512 576 640 704 768 896 1024 1280 1536)
# rungs above E15's metal top (1024), sealed with E16's predictions (user decision 2026-11-08)
export E15_LADDER_EXTRA="1280 1536"
mkdir -p "$L"

usage() {
  echo "usage: chain.sh baselines|cal|long-rung|ladder-sbx|ladder-resident|ladder-resident-ext|ladder-sbx-ext|stag|seeds|control [ARM]" >&2
  exit 2
}
[ $# -ge 1 ] && [ $# -le 2 ] || usage
STAGE=$1
ARMS="sbx resident-inf"
if [ $# -eq 2 ]; then
  case "$2" in sbx | resident-inf) ARMS=$2 ;; *) usage ;; esac
fi
case "$STAGE" in baselines | cal | long-rung | ladder-sbx | ladder-resident | ladder-resident-ext | ladder-sbx-ext | stag | seeds | control) ;; *) usage ;; esac

stopped() { [ -s "$L/STOP" ]; }

# --- sentinel (E15 climb.sh) -------------------------------------------------------------------
spid=""
if [ "${E16_NO_SENTINEL:-0}" != 1 ]; then
  # a STOP from an earlier stage stands until an operator clears it (rm $L/STOP): host-level failure
  if [ -s "$L/STOP" ]; then
    echo "E16 $STAGE NOT STARTED: STOP present ($(cat "$L/STOP")); clear it by hand after checking the host"
    exit 1
  fi
  since=$(date '+%Y-%m-%d %H:%M:%S')
  (
    while :; do
      if journalctl -k --since "$since" --no-pager 2>/dev/null | grep 'Out of memory: Killed process' | grep -qv 'Memory cgroup'; then
        echo "global_oom $(date -u +%FT%TZ)" >"$L/STOP"
      fi
      free_kb=$(df -Pk /srv/e15 | awk 'NR==2 {print $4}')
      [ "$free_kb" -lt $((10 * 1024 * 1024)) ] && echo "disk_free_${free_kb}kB $(date -u +%FT%TZ)" >"$L/STOP"
      if [ -s "$L/STOP" ]; then
        pkill -f "$R/ladder.sh"
        pkill -f "$R/rung.sh"
        pkill -x e15-driver
        pkill -f "$HERE/perfsample.sh"
        bash -c "source $R/lib.sh; stop_rung_units" >/dev/null 2>&1
        echo "E16 SENTINEL STOP $(cat "$L/STOP")"
        exit 0
      fi
      sleep 20
    done
  ) &
  spid=$!
fi
finish() {
  [ -z "$spid" ] || kill "$spid" 2>/dev/null
  exit "$1"
}

# emit STAGE ARM N DIR: the one-line rung summary.
emit() {
  local h ha p reason
  read -r h ha p _ reason _ < <($CL summary "$4/record.json")
  echo "E16 $1 $2 N=$3 holds=$h holds_abs=$ha p95x=$p reason=$reason"
}

# delta ARM: the per-image disk delta for the next rung's check (measured on the arm's last rung).
delta() {
  local f=$L/delta-$1
  if [ -s "$f" ]; then cat "$f"; else echo "${E16_WS_DELTA0_MB:-4}"; fi
}
note_delta() { # note_delta ARM DIR
  local d
  d=$(python3 "$HERE/measured_delta.py" "$2" 2>/dev/null) && echo "$d" >"$L/delta-$1"
  return 0
}
# disk_ok ARM N KMAX: N*16*KMAX*delta*1.1 must fit in /srv/e15's free space.
disk_ok() {
  local need free
  need=$(python3 -c 'import sys; print(int(int(sys.argv[1]) * 16 * int(sys.argv[2]) * int(sys.argv[3]) * 1.1 * 1024))' "$2" "$3" "$(delta "$1")")
  free=$(df -Pk "${E16_DF_PATH:-/srv/e15}" | awk 'NR==2 {print $4}')
  [ "$need" -lt "$free" ] && return 0
  echo "E16 $STAGE $1 N=$2 DISK need $((need / 1048576)) GiB free $((free / 1048576)) GiB at K x$3, delta $(delta "$1") MiB: stop"
  return 1
}

# mem_ok ARM N (rungs above 1024, user instruction at the seal): the host must start idle (MemAvailable
# >= E16_MEM_IDLE_MIN_GIB, default 340 GiB, i.e. nothing left over from a previous rung); the projected
# resident memory, N x the per-VM slice memory of the arm's last rung (worker + VMs, window peak / N),
# is logged against host RAM. A projection over the host does not stop the rung: memory binding is a
# measured verdict (the floor, e15.slice limits and the MemAvailable watchdog record it).
mem_ok() {
  local avail proj
  avail=$(awk '/^MemAvailable:/ {print int($2 / 1048576)}' "${E16_MEMINFO:-/proc/meminfo}")
  proj=$(python3 - "$RUNS/$1" "$2" <<'PY' 2>/dev/null || echo unknown
import glob, gzip, json, os, sys
rows = sorted(glob.glob(os.path.join(sys.argv[1], "e16", "N*.json")), key=os.path.getmtime)
d = json.load(open(rows[-1]))["dir"]
p = json.load(open(os.path.join(d, "params.json")))
a = p["warmup_s"]
op = gzip.open if os.path.exists(os.path.join(d, "samples.jsonl.gz")) else open
f = os.path.join(d, "samples.jsonl.gz" if op is gzip.open else "samples.jsonl")
m = max(json.loads(l)["slice_mem_bytes"] for l in op(f, "rt") if l.strip() and json.loads(l).get("t", -1) >= a)
print("%.0f" % (m / float(1 << 30) / p["n"] * int(sys.argv[2])))
PY
)
  echo "E16 $STAGE $1 N=$2 memory check: MemAvailable ${avail} GiB idle, projected slice memory ${proj} GiB of 377"
  [ "$avail" -ge "${E16_MEM_IDLE_MIN_GIB:-340}" ] && return 0
  echo "E16 $STAGE $1 N=$2 MEMORY host not idle (MemAvailable ${avail} GiB < ${E16_MEM_IDLE_MIN_GIB:-340}): stop"
  return 1
}

# grace_rerun ARM N DIR SEED: re-run DIR once with grace 900 s if its only condition-1 failures are
# grace-end cuts. Prints the counted directory; returns 1 on a rig error.
grace_rerun() {
  local arm=$1 n=$2 d=$3 seed=$4 tag wu km
  if [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("holds") is True)' "$d/record.json")" = True ] ||
    [ "$(python3 "$HERE/grace_artefact.py" "$d" 2>/dev/null)" != yes ]; then
    printf '%s\n' "$d"
    return 0
  fi
  tag=$(basename "$d" | sed "s/^N$n-\{0,1\}//")
  tag=${tag:+$tag-}g900
  wu=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["warmup_s"])' "$d/params.json")
  km=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("workspaces_k_mult") or 1)' "$d/params.json")
  echo "E16 $STAGE $arm N=$n grace-end artefact in $d: re-run with E15_GRACE_S=900 (tag $tag)" >&2
  E15_TAG=$tag E15_SEED=$seed E15_GRACE_S=900 E15_WARMUP_S=$wu E15_K_MULT=$km E15_WS_DELTA_MB=$(delta "$arm") \
    bash "$RUNG_SH" "$arm" "$n" "$POINT" >"$L/$arm-N$n-$tag.log" 2>&1 || return 1
  printf '%s\n' "$RUNS/$arm/N$n-$tag"
}

# ladder_rung STAGE ARM N SEED: one ladder rung (skipped when its row exists). 0 ran or skipped,
# 1 rig error / stop.
ladder_rung() {
  local stage=$1 arm=$2 n=$3 seed=$4 sfx="" row inv first d art=false
  [ "$seed" = 1 ] || sfx=-s$seed
  row=$RUNS/$arm/e16/N$n$sfx.json
  mkdir -p "$RUNS/$arm/e16"
  if [ -f "$row" ]; then
    echo "E16 $stage $arm N=$n SKIP (row exists: $row)"
    return 0
  fi
  stopped && return 1
  disk_ok "$arm" "$n" $((KM * 2)) || return 1
  [ "$n" -le 1024 ] || mem_ok "$arm" "$n" || return 1
  inv=$RUNS/$arm/e16/ladder-N$n$sfx.json
  local envs=(E15_LADDER_RUNGS="$n" E15_K_MULT="$KM" E15_WS_DELTA_MB="$(delta "$arm")" E15_RUNG="$RUNG_SH")
  [ "$seed" = 1 ] || envs+=(E15_SEED="$seed" E15_LADDER_TAG="s$seed")
  env "${envs[@]}" bash "$LADDER_SH" "$POINT" "$arm" >"$L/$arm-N$n$sfx.ladder.log" 2>&1 || {
    echo "E16 $stage $arm N=$n RIG_ERROR $(tail -1 "$L/$arm-N$n$sfx.ladder.log")"
    return 1
  }
  mv "$RUNS/$arm/ladder.json" "$inv"
  # the counted record: the ladder's directory for this rung (the repeat / k2 when they ran)
  first=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["rungs"][-1]["dir"])' "$inv")
  d=$(grace_rerun "$arm" "$n" "$first" "$seed") || {
    echo "E16 $stage $arm N=$n grace re-run RIG_ERROR"
    return 1
  }
  [ "$d" = "$first" ] || art=true
  $CL row "$row" "$n" "$seed" "$d" "$inv" "$art" "$first"
  if [ "$stage" = ladder-sbx-ext ] || { [ "$arm" = sbx ] && [ "$n" -gt 1024 ]; }; then
    python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["post_seal_extension"]=True; json.dump(d,open(p,"w"),indent=2)' "$row"
  fi
  note_delta "$arm" "$d"
  emit "$stage" "$arm" "$n$sfx" "$d"
  $CL assemble "$RUNS/$arm" "$POINT" "$arm" "${FULL[@]}" >/dev/null
  return 0
}

# supp_rung ARM N TAG SEED [ENV...]: one supplementary ladder rung (rung dir N<n>-TAG) into
# <arm>/e16-supp/N<n>-TAG.json; the sealed rows and ladder.json are kept aside and restored around it.
# The counted directory gets stag_valid.json (experiments/e16-low-duty/analysis/stag_valid.py; SBX: checks a, b only).
# 0 ran or skipped, 1 rig error.
supp_rung() {
  local arm=$1 n=$2 tag=$3 seed=$4 row inv first d art=false
  shift 4
  local sd=$RUNS/$arm/e16-supp
  row=$sd/N$n-$tag.json
  mkdir -p "$sd"
  if [ -f "$row" ]; then
    echo "E16 stag $arm N=$n-$tag SKIP (row exists)"
    return 0
  fi
  stopped && return 1
  disk_ok "$arm" "$n" $((KM * 2)) || return 1
  [ "$n" -le 1024 ] || mem_ok "$arm" "$n" || return 1
  inv=$sd/ladder-N$n-$tag.json
  [ -f "$RUNS/$arm/ladder.json" ] && cp "$RUNS/$arm/ladder.json" "$sd/.ladder.sealed.tmp"
  env "$@" E15_SEED="$seed" E15_LADDER_RUNGS="$n" E15_LADDER_TAG="$tag" E15_K_MULT="$KM" E15_WS_DELTA_MB="$(delta "$arm")" E15_RUNG="$RUNG_SH" \
    bash "$LADDER_SH" "$POINT" "$arm" >"$L/$arm-N$n-$tag.ladder.log" 2>&1
  local lrc=$?
  [ -f "$RUNS/$arm/ladder.json" ] && mv "$RUNS/$arm/ladder.json" "$inv"
  [ -f "$sd/.ladder.sealed.tmp" ] && mv "$sd/.ladder.sealed.tmp" "$RUNS/$arm/ladder.json"
  [ $lrc = 0 ] || {
    echo "E16 stag $arm N=$n-$tag RIG_ERROR $(tail -1 "$L/$arm-N$n-$tag.ladder.log")"
    return 1
  }
  first=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["rungs"][-1]["dir"])' "$inv")
  d=$(grace_rerun "$arm" "$n" "$first" "$seed") || {
    echo "E16 stag $arm N=$n-$tag grace re-run RIG_ERROR"
    return 1
  }
  [ "$d" = "$first" ] || art=true
  local vflag=()
  [ "$arm" != sbx ] || vflag=(--no-end-sessions)
  local valid
  valid=$(python3 "$VALID_PY" "${vflag[@]}" "$d")
  $CL row "$row" "$n" "$seed" "$d" "$inv" "$art" "$first"
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); v=json.load(open(sys.argv[3] + "/stag_valid.json"))
d.update(supplementary=sys.argv[2], valid=v["valid"], invalid_reasons=v["reasons"]); json.dump(d,open(p,"w"),indent=2)' "$row" "$tag" "$d"
  note_delta "$arm" "$d"
  emit stag "$arm" "$n-$tag" "$d"
  echo "E16 stag $arm N=$n-$tag validity: $valid"
  return 0
}
# supp_field ARM N TAG KEY
supp_field() {
  python3 -c 'import json,sys; print(str(json.load(open(sys.argv[1]))[sys.argv[2]]).lower())' "$RUNS/$1/e16-supp/N$2-$3.json" "$4"
}
# supp_valid ARM N TAG SEED [ENV...]: run the rung; if INVALID, re-run it once (tag TAG-r); prints
# the counted tag; returns 1 on a rig error, 3 when invalid twice.
supp_valid() {
  local arm=$1 n=$2 tag=$3 seed=$4
  shift 4
  supp_rung "$arm" "$n" "$tag" "$seed" "$@" >&2 || return 1
  if [ "$(supp_field "$arm" "$n" "$tag" valid)" = true ]; then
    echo "$tag"
    return 0
  fi
  echo "E16 stag $arm N=$n-$tag INVALID ($(supp_field "$arm" "$n" "$tag" invalid_reasons)): not counted; re-running once as $tag-r" >&2
  supp_rung "$arm" "$n" "$tag-r" "$seed" "$@" >&2 || return 1
  if [ "$(supp_field "$arm" "$n" "$tag-r" valid)" = true ]; then
    echo "$tag-r"
    return 0
  fi
  echo "E16 stag $arm N=$n-$tag-r INVALID again ($(supp_field "$arm" "$n" "$tag-r" invalid_reasons)): stopping the stag stage" >&2
  return 3
}
# stag_pair ARM N [ENV...]: seeds 1 and 2 (tags T, T-s2), seed 3 (T-s3) when they disagree; prints
# the majority primary verdict (true/false); returns non-zero on a rig error / double invalid.
stag_pair() {
  local arm=$1 n=$2 base=$3 t1 t2 t3 h1 h2 h3
  shift 3
  t1=$(supp_valid "$arm" "$n" "$base" 1 "$@") || return $?
  t2=$(supp_valid "$arm" "$n" "$base-s2" 2 "$@") || return $?
  h1=$(supp_field "$arm" "$n" "$t1" holds)
  h2=$(supp_field "$arm" "$n" "$t2" holds)
  if [ "$h1" = "$h2" ]; then
    echo "$h1"
    return 0
  fi
  echo "E16 stag $arm N=$n seeds 1 and 2 disagree ($h1 / $h2): seed 3" >&2
  t3=$(supp_valid "$arm" "$n" "$base-s3" 3 "$@") || return $?
  h3=$(supp_field "$arm" "$n" "$t3" holds)
  if [ "$h3" = "$h1" ]; then echo "$h1"; else echo "$h2"; fi
}

# verdict ARM N [SEED]: "true"/"false" primary, from the row.
row_field() { # row_field ARM N SEED KEY
  local sfx=""
  [ "$3" = 1 ] || sfx=-s$3
  python3 -c 'import json,sys; print(str(json.load(open(sys.argv[1]))[sys.argv[2]]).lower())' "$RUNS/$1/e16/N$2$sfx.json" "$4"
}
alive_row() { # either verdict holds
  [ "$(row_field "$1" "$2" 1 holds)" = true ] || [ "$(row_field "$1" "$2" 1 holds_abs)" = true ]
}

ladder_stage() { # ladder_stage STAGE ARM "RUNGS" "EXTEND"
  local stage=$1 arm=$2 n lo="" hi="" b down
  echo "E16 $stage $arm START $(date -u +%FT%TZ)"
  for n in $3 $4; do
    # the extension rungs only after every requested rung held (primary)
    case " $4 " in *" $n "*) [ -z "$hi" ] || break ;; esac
    ladder_rung "$stage" "$arm" "$n" 1 || return 1
    # lo: the last primary hold below the first primary failure (hi)
    if [ "$(row_field "$arm" "$n" 1 holds)" = true ]; then [ -n "$hi" ] || lo=$n; else [ -n "$hi" ] || hi=$n; fi
    alive_row "$arm" "$n" || break
  done
  local first=${3%% *}
  if [ "$(row_field "$arm" "$first" 1 holds)" != true ]; then
    # the first rung failed: step down the ladder until a rung holds
    hi=$first
    for down in $(printf '%s\n' "${FULL[@]}" | sort -rn); do
      [ "$down" -lt "$first" ] || continue
      ladder_rung "$stage" "$arm" "$down" 1 || return 1
      if [ "$(row_field "$arm" "$down" 1 holds)" = true ]; then
        lo=$down
        break
      fi
      hi=$down
    done
  fi
  if [ -n "$lo" ] && [ -n "$hi" ]; then
    b=$($CL bisect "$lo" "$hi" "${FULL[@]}")
    if [ -n "$b" ]; then
      echo "E16 $stage $arm bisect between $lo and $hi: N=$b"
      ladder_rung "$stage" "$arm" "$b" 1 || return 1
    fi
  fi
  echo "E16 $stage $arm DONE $(date -u +%FT%TZ) :: n_max n_max_stopped n_max_abs stopped_abs = $($CL assemble "$RUNS/$arm" "$POINT" "$arm" "${FULL[@]}")"
}

# one_rung STAGE ARM N TAG WARMUP WINDOW KMULT: a non-ladder rung (cal, long, control).
one_rung() {
  local stage=$1 arm=$2 n=$3 tag=$4 wu=$5 win=$6 km=$7 d
  d=$RUNS/$arm/N$n-$tag
  if [ -f "$d/record.json" ]; then
    echo "E16 $stage $arm N=$n SKIP ($d/record.json exists)"
    emit "$stage" "$arm" "$n" "$d"
    return 0
  fi
  stopped && return 1
  disk_ok "$arm" "$n" "$km" || return 1
  E15_TAG=$tag E15_WARMUP_S=$wu E15_WINDOW_S=$win E15_K_MULT=$km E15_WS_DELTA_MB=$(delta "$arm") \
    bash "$RUNG_SH" "$arm" "$n" "$POINT" >"$L/$arm-N$n-$tag.log" 2>&1 || {
    echo "E16 $stage $arm N=$n RIG_ERROR $(tail -1 "$L/$arm-N$n-$tag.log")"
    return 1
  }
  [ "$arm" = control ] || note_delta "$arm" "$d"
  emit "$stage" "$arm" "$n" "$d"
}

rc=0
echo "E16 $STAGE START $(date -u +%FT%TZ) src $(cat "$SRC/COMMIT" 2>/dev/null || echo unknown)"
case "$STAGE" in
baselines)
  for arm in $ARMS; do
    stopped && break
    if [ -f "$RUNS/$arm/N1/baseline.json" ]; then
      echo "E16 baselines $arm SKIP ($RUNS/$arm/N1/baseline.json exists)"
      continue
    fi
    bash "$BASELINE_SH" "$POINT" "$arm" >"$L/baseline-$arm.log" 2>&1 || {
      echo "E16 baselines $arm FAILED $(tail -2 "$L/baseline-$arm.log" | tr '\n' ' ' | cut -c1-300)"
      rc=1
      break
    }
    echo "E16 baselines $arm DONE $(date -u +%FT%TZ) :: $(python3 -c '
import json, sys
b = json.load(open(sys.argv[1]))
print(json.dumps({k: (round(b[k], 2) if isinstance(b.get(k), float) else b.get(k)) for k in
  ("excess_p95_ms", "overhead_ms", "n1_median_pace", "undercovered", "probe_failed")}
  | {"evaluable": [e.get("seed") for e in b.get("evaluable", [])], "skipped": [s.get("seed") for s in b.get("skipped", [])]}))' "$RUNS/$arm/N1/baseline.json")"
  done
  ;;
cal)
  for arm in $ARMS; do
    one_rung cal "$arm" 256 cal 1200 900 "$KM" || {
      rc=1
      break
    }
    d=$RUNS/$arm/N256-cal
    if [ "${E16_NO_ANALYSIS:-0}" != 1 ]; then
      kind=sbx
      [ "$arm" = sbx ] || kind=resident
      E15_LIBRARY=$SRC/e15/commands/library.json python3 "$HERE/calib_analyze.py" "$kind" "$d" >"$d/analysis.json" 2>"$L/cal-$arm.analyze.err" || true
    fi
  done
  ;;
long-rung)
  # K x3: 3.2 h of warm-up + window cycles a slot through up to ~37 band sessions (simulated)
  one_rung long-rung resident-inf 256 long 600 10800 3 || rc=1
  if [ $rc = 0 ] && [ "${E16_NO_ANALYSIS:-0}" != 1 ]; then
    d=$RUNS/resident-inf/N256-long
    python3 "$SRC/e16/analysis/long_rung.py" "$d" --out "$d/long-rung" --label "resident-inf, lowduty, N=256, 3 h window" >/dev/null 2>"$L/long-vm-age.err" ||
      echo "E16 long-rung long_rung.py FAILED: $(tail -1 "$L/long-vm-age.err")"
  fi
  ;;
ladder-sbx)
  ladder_stage ladder-sbx sbx "${RUNGS:-256 384 512}" "${EXTEND:-640 768 896 1024}" || rc=1
  ;;
ladder-resident)
  ladder_stage ladder-resident resident-inf "${RUNGS:-256 384 512 640 768}" "${EXTEND:-896 1024 1280 1536}" || rc=1
  ;;
ladder-resident-ext)
  rn=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("n_max") or 0)' "$RUNS/resident-inf/ladder.json" 2>/dev/null || echo 0)
  if [ "$rn" != 1024 ]; then
    echo "E16 ladder-resident-ext SKIP: resident-inf sealed n_max=$rn (the extension continues only from 1024)"
  else
    echo "E16 ladder-resident-ext resident-inf START (sealed extension 1280 1536) $(date -u +%FT%TZ)"
    for n in 1280 1536; do
      ladder_rung ladder-resident-ext resident-inf "$n" 1 || {
        rc=1
        break
      }
      alive_row resident-inf "$n" || break
    done
    echo "E16 ladder-resident-ext resident-inf DONE $(date -u +%FT%TZ) :: n_max n_max_stopped n_max_abs stopped_abs = $($CL assemble "$RUNS/resident-inf" "$POINT" resident-inf "${FULL[@]}")"
  fi
  ;;
ladder-sbx-ext)
  rn=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("n_max") or 0)' "$RUNS/resident-inf/ladder.json" 2>/dev/null || echo 0)
  if [ "$rn" -lt 1024 ]; then
    echo "E16 ladder-sbx-ext SKIP: resident-inf n_max=$rn < 1024 (the comparison is decided without it)"
  else
    sb=$RUNS/sbx
    [ -f "$sb/ladder.sealed.json" ] || cp "$sb/ladder.json" "$sb/ladder.sealed.json"
    echo "E16 ladder-sbx-ext sbx START (post-seal extension; resident-inf n_max=$rn) $(date -u +%FT%TZ)"
    for n in 1280 1536; do
      ladder_rung ladder-sbx-ext sbx "$n" 1 || {
        rc=1
        break
      }
      alive_row sbx "$n" || break
    done
    python3 - "$sb/ladder.json" "$rn" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["post_seal_extension"] = {
    "rungs": [1280, 1536],
    "decided": "user, 2026-11-08, after SBX held 1024 (its sealed ladder top); run only because resident-inf n_max=%s >= 1024" % sys.argv[2],
    "sealed": False,
    "sealed_ladder": "ladder.sealed.json (n_max 1024, censored at the top)",
}
json.dump(d, open(p, "w"), indent=2)
PY
    echo "E16 ladder-sbx-ext sbx DONE $(date -u +%FT%TZ) :: $(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("n_max", d["n_max"], "stopped_at", d["stopped_at"], "n_max_abs", d["n_max_abs"], "stopped_at_abs", d["stopped_at_abs"])' "$sb/ladder.json")"
  fi
  ;;
stag)
  echo "E16 stag START (SUPPLEMENTARY: end-session defer; not the sealed procedure) $(date -u +%FT%TZ)"
  D=(E15_END_SESSION_DEFER=1)
  v896=$(stag_pair resident-inf 896 stag "${D[@]}")
  src=$?
  if [ $src = 0 ]; then
    echo "E16 stag resident-inf N=896 verdict (majority of valid seeds): holds=$v896"
    v1024=$(stag_pair resident-inf 1024 stag "${D[@]}")
    src=$?
  fi
  if [ $src = 0 ]; then
    echo "E16 stag resident-inf N=1024 verdict (majority of valid seeds): holds=$v1024"
    echo "E16 stag PAIR resident-inf 896=$v896 1024=$v1024 $(date -u +%FT%TZ)"
    if [ "$v1024" = true ]; then
      for n in 1280 1536; do
        t=$(supp_valid resident-inf "$n" stag 1 "${D[@]}") || {
          src=$?
          break
        }
        [ "$(supp_field resident-inf "$n" "$t" holds)" = true ] || [ "$(supp_field resident-inf "$n" "$t" holds_abs)" = true ] || break
      done
      if [ $src = 0 ]; then
        for n in 1280 1536; do
          t=$(supp_valid sbx "$n" postseal 1) || {
            src=$?
            break
          }
          [ "$(supp_field sbx "$n" "$t" holds)" = true ] || [ "$(supp_field sbx "$n" "$t" holds_abs)" = true ] || break
        done
      fi
    else
      echo "E16 stag resident-inf N=1024 fails with the deferral too: no further stag rungs"
    fi
  fi
  [ $src = 0 ] || rc=1
  python3 - "$RUNS" <<'PY'
import glob, json, os, sys
for arm in ("resident-inf", "sbx"):
    rows = [json.load(open(p)) for p in sorted(glob.glob(os.path.join(sys.argv[1], arm, "e16-supp", "N*.json")))]
    if not rows:
        continue
    by = {}
    for r in rows:
        if r.get("valid"):
            by.setdefault(r["n"], []).append(r)
    verdict = {}
    for n, rs in sorted(by.items()):
        rs = sorted(rs, key=lambda r: r["seed"])
        hs = [r["holds"] for r in rs][:3]
        ha = [r["holds_abs"] for r in rs][:3]
        verdict[n] = {"holds": sum(hs) * 2 > len(hs) if len(hs) != 2 else (hs[0] if hs[0] == hs[1] else None),
                      "holds_abs": sum(ha) * 2 > len(ha) if len(ha) != 2 else (ha[0] if ha[0] == ha[1] else None),
                      "seeds": [r["seed"] for r in rs]}
    json.dump({"supplementary": True, "voted": False,
               "rule": "valid rungs only (stag_valid.json); a rung's verdict = majority of its valid seeds; "
                       "two disagreeing seeds without a third: null",
               "verdicts": {str(k): v for k, v in verdict.items()},
               "rows": sorted(rows, key=lambda r: (r["n"], r["seed"], r.get("supplementary", "")))},
              open(os.path.join(sys.argv[1], arm, "ladder-supp.json"), "w"), indent=2)
PY
  echo "E16 stag DONE rc=$rc $(date -u +%FT%TZ)"
  ;;
seeds)
  for arm in $ARMS; do
    [ -f "$RUNS/$arm/ladder.json" ] || {
      echo "E16 seeds $arm SKIP (no assembled ladder.json)"
      continue
    }
    read -r nm st < <($CL deciding "$RUNS/$arm")
    for n in $nm $st; do
      [ "$n" != null ] || continue
      ladder_rung seeds "$arm" "$n" 2 || {
        rc=1
        break 2
      }
      if [ "$(row_field "$arm" "$n" 1 holds)" != "$(row_field "$arm" "$n" 2 holds)" ]; then
        echo "E16 seeds $arm N=$n s1 and s2 disagree: seed 3"
        ladder_rung seeds "$arm" "$n" 3 || {
          rc=1
          break 2
        }
      fi
    done
    echo "E16 seeds $arm DONE :: $($CL assemble "$RUNS/$arm" "$POINT" "$arm" "${FULL[@]}")"
  done
  ;;
control)
  one_rung control control 768 a2 1200 900 "$KM" || rc=1
  ;;
esac
stopped && {
  echo "E16 $STAGE STOP $(cat "$L/STOP")"
  rc=1
}
echo "E16 $STAGE END rc=$rc $(date -u +%FT%TZ)"
finish "$rc"
