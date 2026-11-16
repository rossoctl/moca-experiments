#!/usr/bin/env bash
# shellcheck disable=SC2034  # read by lib.sh (E17B=1 profile)
# experiments/e17-lease/rig/e17b-pins.sh -- the moca commit every E17b arm (sbx and ship-*) runs from.
# Sourced by lib.sh only when E17B=1, never run; no side effects. experiments/e15-session-density/rig/pins.sh
# is untouched: E15, E16 and E17a keep their own pin.
#
# E17B_MOCA_PIN is a full 40-hex sha of upstream/main. The all-zero value below is a PLACEHOLDER:
# the controller must replace it with the chosen upstream/main sha before any rig run (and record it
# in the build commit message). lib.sh e17b_require_pin refuses to start setup.sh or rung.sh while it
# is the placeholder or is not a full sha.
E17B_MOCA_PIN=c3adf4909df48aa9d167d366ee95278b3aff87ff
