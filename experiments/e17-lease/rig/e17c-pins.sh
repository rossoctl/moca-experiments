#!/usr/bin/env bash
# shellcheck disable=SC2034  # read by lib.sh (E17C=1 profile)
# experiments/e17-lease/rig/e17c-pins.sh -- the moca commit every E17c arm runs from (PLAN-E17C.md Task 1).
# Sourced by lib.sh only when E17C=1, never run; no side effects. pins.sh (E15, E16, E17a) and e17b-pins.sh
# (E17b) are untouched: those procedures keep their own pins.
#
# E17C_MOCA_PIN is a full 40-hex sha of moca main with #966, #970 and #974 merged. The all-zero value below is a
# PLACEHOLDER until moca #974 merges: the controller must replace it with that upstream/main sha before any rig run
# (and record it in the commit message). lib.sh e17c_require_pin refuses to start setup.sh or rung.sh while it is
# the placeholder or is not a full sha.
E17C_MOCA_PIN=e5ae5151bbedf47764c0c8e804146c6b1e830fff
