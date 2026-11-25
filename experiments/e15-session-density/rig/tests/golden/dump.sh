#!/usr/bin/env bash
# shellcheck disable=SC2153  # E15_* come from lib.sh, sourced by the caller's bash -c
# experiments/e15-session-density/rig/tests/golden/dump.sh -- the golden dumps rig.test.sh compares against (E17 Task 3).
# The files beside this one were written by these functions from the tree BEFORE E17 touched
# lib.sh, points.sh and rung.sh (commit 6364d0f), so a diff against them shows any change to a
# pre-existing point or arm. $E15_ROOT is printed as <ROOT>, so the dumps do not depend on the
# scratch root. Sourced after lib.sh and points.sh, never run.
#
#   e15_golden_point POINT   every E15_P_* that e15_point sets, then the point signature
#   e15_golden_arms TMPFILE  for each pre-E17 arm: its default warm-up, worker binary and worker env
#
# Regenerate (only for a deliberate change to a pre-existing point or arm), from a test root:
#   E15_ROOT=$R E15_TEST_ROOT=$R bash -c '. experiments/e15-session-density/rig/lib.sh; . experiments/e15-session-density/rig/points.sh; . experiments/e15-session-density/rig/tests/golden/dump.sh;
#     e15_golden_point default' >experiments/e15-session-density/rig/tests/golden/point-default.txt
#   (R ending in /e15-rig-test.root; arms.<profile>.txt with E15_HOST_PROFILE=<profile> e15_golden_arms "$R/env")
#
#   e15_golden_profile       every E15_*, E17B* and E17C* variable lib.sh leaves defined: its declare flags (export,
#                            array) and value(s), one element per line, independent of the bash version;
#                            $E15_ROOT is printed as <ROOT> and $HOME as <HOME>
# profile-e17b-off.txt (E17B and E17C unset) and profile-e17b-on.txt (E17B=1, E17C unset) were written from the
# tree BEFORE E17c touched lib.sh (e17c/plan, deb53c3), so the E17c profile is pinned off without a git ref:
#   env -u E17B -u E17C E15_ROOT=$R E15_TEST_ROOT=$R bash -c '. experiments/e15-session-density/rig/lib.sh;
#     . experiments/e15-session-density/rig/tests/golden/dump.sh; e15_golden_profile' >.../golden/profile-e17b-off.txt
#   (the same with E17B=1 for profile-e17b-on.txt)
# profile-e17c-on.txt (E17C=1, E17D unset; fresh-metal) and e17c-on.txt (e15_golden_e17c: E17c's points and arms under
# E17C=1 on fresh-metal) were written from the tree BEFORE E17d touched lib.sh and points.sh (e17d/build at 4d0d2e0),
# so the E17d profile is pinned off the same way:
#   env -u E17B -u E17D E17C=1 E15_HOST_PROFILE=fresh-metal E15_ROOT=$R E15_TEST_ROOT=$R bash -c
#     '. .../lib.sh; . .../points.sh; . .../golden/dump.sh; e15_golden_profile' >.../golden/profile-e17c-on.txt
#   (the same with e15_golden_e17c "$R/env" "$R/meminfo" for e17c-on.txt; $R/meminfo says MemTotal: 400000000 kB)

E15_GOLDEN_ARMS="sbx resident-inf resident-300 control"

e15_golden_point() {
  local v x
  e15_point "$1" || return 1
  for v in ARMS CORPUS LIBRARY TEMPLATE TEMPLATE_STAMP IMAGE_MB DATASET_MIB DATASET_SEED SCAN_CLASSES SCAN_CMD FALLBACK SETTINGS; do
    eval "x=\$E15_P_$v"
    printf 'E15_P_%s=%s\n' "$v" "${x//$E15_ROOT/<ROOT>}"
  done
  printf 'point_sig=%s\n' "$(e15_point_sig "$1")"
}

e15_golden_arms() {
  local a
  for a in $E15_GOLDEN_ARMS; do
    echo "== $a warmup=$(e15_default_warmup "$a") bin=$( (worker_bin "$a" 2>/dev/null || true) | sed "s#^$E15_ROOT#<ROOT>#")"
    [ "$a" = control ] && continue
    worker_env "$a" "$1"
    sed "s#$E15_ROOT#<ROOT>#g" "$1"
  done
}

e15_golden_profile() {
  local v flags x vals
  for v in $( (compgen -v E15_; compgen -v E17B; compgen -v E17C; compgen -v E17D) | LC_ALL=C sort -u); do
    flags=$(declare -p "$v" | cut -d' ' -f2)
    case "$flags" in
    *a*)
      eval "vals=(\"\${${v}[@]}\")"
      printf '%s %s (%s)\n' "$flags" "$v" "${#vals[@]}"
      for x in "${vals[@]}"; do printf '  %s\n' "$x"; done
      ;;
    *) printf '%s %s=%s\n' "$flags" "$v" "${!v}" ;;
    esac
  done | sed -e "s#$E15_ROOT#<ROOT>#g" -e "s#$HOME#<HOME>#g"
}

# e15_golden_e17c ENVFILE MEMINFO: under E17C=1, every E17c point's E15_P_* and signature, then each E17c arm's default
# warm-up, worker binary and worker env (the lease arms' admission budget from MEMINFO's MemTotal).
GOLDEN_E17C_POINTS="default smoke pycache pycache-low pycache-d64 pycache-d768 squeeze squeeze-256"
GOLDEN_E17C_ARMS="sbx ship-30 ship-120 ship-300 ship-300-nd"
e15_golden_e17c() {
  local p a
  for p in $GOLDEN_E17C_POINTS; do
    echo "== point $p"
    e15_golden_point "$p"
  done
  for a in $GOLDEN_E17C_ARMS; do
    echo "== $a warmup=$(e15_default_warmup "$a") bin=$( (worker_bin "$a" 2>/dev/null || true) | sed "s#^$E15_ROOT#<ROOT>#") lease=$(e17b_lease_arm "$a" && echo yes || echo no)"
    (E15_MEMINFO=$2 worker_env "$a" "$1")
    sed "s#$E15_ROOT#<ROOT>#g" "$1"
  done
}
