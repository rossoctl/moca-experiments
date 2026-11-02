#!/usr/bin/env bash
# e15/rig/teardown.sh [--purge] -- undo setup.sh (SPEC §4).
#
# Replays, in reverse order, every "| UNDO: <cmd>" line the manifest (~/e15-manifest.md, or
# E15_MANIFEST) recorded since its last "## Teardown" section, then appends a Teardown section
# naming each command replayed and its exit code. With --purge it then replays the "| PURGE:" lines
# (E15's built artifacts and /srv/e15 itself) in reverse, after the UNDO lines.
#
# A failing undo is reported and the rest still run; the exit code is 1 if any failed.
# Afterwards (unless E15_TEARDOWN_VERIFY=0) it checks the host is as E15 found it:
# microvm-worker.service active, bench-cp and bench-redis running, nothing E15's on its ports.
set -uo pipefail
E15_PROG=teardown.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

purge=0
case "${1:-}" in
"") ;;
--purge) purge=1 ;;
*)
  echo "usage: teardown.sh [--purge]" >&2
  exit 2
  ;;
esac
[ -f "$E15_MANIFEST" ] || die "no manifest at $E15_MANIFEST: nothing to undo"

# Lines after the last Teardown section are this cycle's.
last=$(grep -n '^## Teardown' "$E15_MANIFEST" | tail -1 | cut -d: -f1)
start=$((${last:-0} + 1))
mapfile -t undo < <(tail -n +"$start" "$E15_MANIFEST" | sed -n 's/^- .* | UNDO: //p')
# The host's state before this cycle's first setup (setup.sh PRESTATE note); verify restores it.
prestate=$(tail -n +"$start" "$E15_MANIFEST" | sed -n 's/^- .* PRESTATE: //p' | head -1)
purges=()
if [ "$purge" = 1 ]; then
  # PURGE lines from the whole manifest: built artifacts outlive teardown/setup cycles.
  mapfile -t purges < <(sed -n 's/^- .* | PURGE: //p' "$E15_MANIFEST" | awk '!seen[$0]++')
fi

rc=0
results=()
failed=()
replay() {
  local cmd=$1 r
  log "replay: $cmd"
  bash -c "$cmd"
  r=$?
  results+=("- $(utc) replayed (exit $r): $cmd")
  [ "$r" -eq 0 ] || {
    log "FAILED (exit $r): $cmd"
    failed+=("$cmd")
    rc=1
  }
}
for ((i = ${#undo[@]} - 1; i >= 0; i--)); do replay "${undo[i]}"; done
for ((i = ${#purges[@]} - 1; i >= 0; i--)); do replay "${purges[i]}"; done

# The manifest itself may have been under a purged path only in tests; never recreate it there.
if [ -f "$E15_MANIFEST" ] || [ -d "$(dirname "$E15_MANIFEST")" ]; then
  {
    printf '\n## Teardown %s\n' "$(utc)"
    [ ${#results[@]} -gt 0 ] && printf '%s\n' "${results[@]}"
    [ "$purge" = 1 ] && printf -- '- %s purge: built artifacts removed\n' "$(utc)"
    # A failed undo is carried past this Teardown section, in the original order (failed[] is
    # in replay order, i.e. reversed), so the next teardown retries it.
    if [ ${#failed[@]} -gt 0 ]; then
      printf '\n## Retry %s\n' "$(utc)"
      for ((i = ${#failed[@]} - 1; i >= 0; i--)); do
        printf -- '- %s retry after failed teardown | UNDO: %s\n' "$(utc)" "${failed[i]}"
      done
    fi
  } >>"$E15_MANIFEST"
fi

if [ "${E15_TEARDOWN_VERIFY:-1}" = 1 ]; then
  ok=1
  # Expected state: what setup recorded before it changed anything; without a PRESTATE line
  # (a manifest from before fix round 1), SPEC §4's normal state: worker active, bench running.
  want_hw=active
  case " $prestate " in *" $E15_HOST_WORKER=inactive "*) want_hw=inactive ;; esac
  if systemctl is-active --quiet "$E15_HOST_WORKER"; then have_hw=active; else have_hw=inactive; fi
  if [ "$have_hw" != "$want_hw" ]; then
    log "VERIFY: $E15_HOST_WORKER is $have_hw, was $want_hw before setup"
    ok=0
  fi
  for c in "${E15_BENCH_CTRS[@]}"; do
    want=true
    case " $prestate " in *" $c=false "* | *" $c=absent "*) want=false ;; esac
    have=$(sudo -n docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || echo false)
    [ "$have" = true ] || have=false
    if [ "$have" != "$want" ]; then
      log "VERIFY: container $c running=$have, was running=$want before setup"
      ok=0
    fi
  done
  for u in "$E15_UNIT_RELAY" "$E15_UNIT_WORKER" "$E15_UNIT_NULL"; do
    if systemctl is-active --quiet "$u"; then
      log "VERIFY: $u still active"
      ok=0
    fi
  done
  if sudo -n podman container exists "$E15_REDIS_CTR" 2>/dev/null; then
    log "VERIFY: container $E15_REDIS_CTR still exists"
    ok=0
  fi
  for p in "${E15_PORTS[@]}"; do
    if ss -ltnH | awk '{print $4}' | grep -Eq ":$p\$"; then
      log "VERIFY: port $p still has a listener"
      ok=0
    fi
  done
  if [ "$ok" = 1 ]; then
    printf -- '- %s verified: %s %s, bench as before setup (%s), E15 units/ports gone\n' "$(utc)" \
      "$E15_HOST_WORKER" "$want_hw" "${prestate:-no PRESTATE: expected all running}" >>"$E15_MANIFEST"
    log "teardown: verified"
  else
    printf -- '- %s VERIFY FAILED (see teardown output)\n' "$(utc)" >>"$E15_MANIFEST"
    rc=1
  fi
fi
exit "$rc"
