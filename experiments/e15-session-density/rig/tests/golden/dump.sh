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
  for v in $( (compgen -v E15_; compgen -v E17B; compgen -v E17C) | sort -u); do
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
