#!/usr/bin/env bash
# shellcheck disable=SC2034  # read by lib.sh (E17D=1 profile)
# experiments/e17-lease/rig/e17d-pins.sh -- the moca commit every E17d arm runs from (PLAN-E17D.md Task 1, spec §14.2).
# Sourced by lib.sh only when E17D=1, never run; no side effects. pins.sh (E15, E16, E17a), e17b-pins.sh (E17b) and
# e17c-pins.sh (E17c) are untouched: those procedures keep their own pins.
#
# E17D_MOCA_PIN is a full 40-hex sha of moca main with #1026 (the memory-budget refusal's why=, #1005) merged: the merge
# commit of #1026, which also contains #1027. lib.sh e17d_require_pin refuses to start setup.sh or rung.sh while it is
# the all-zero placeholder or is not a full sha; replace it only with another reviewed main sha, before any rig run.
E17D_MOCA_PIN=a9a11a228b6f5ba0200ca3ecdf66feb771adba47
