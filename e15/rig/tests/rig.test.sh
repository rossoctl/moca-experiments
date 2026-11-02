#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted $ here are stub bodies, grep patterns and manifest lines
# e15/rig/tests/rig.test.sh
#
# Structural tests for the E15 rig scripts. Cluster-free, rig-free, no root: every external
# command a guard would reach (ss, systemctl, sudo) is a stub on PATH that records its calls.
#
#   - every script passes `bash -n` and `shellcheck`
#   - lib.sh's guards refuse their cases: refuse_shared_paths (/opt/serverless-harness),
#     refuse_ports (a listener already on 9643/9644/6400), refuse_units (systemctl on sh-*)
#   - rung.sh refuses an unknown ARM before touching anything
#   - teardown.sh replays a fixture manifest's UNDO lines in reverse order, only those after the
#     last teardown, and PURGE lines only with --purge
#
# Run: bash e15/rig/tests/rig.test.sh      (SHELLCHECK=/path/to/shellcheck if not on PATH)
set -uo pipefail

RIG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS=(lib.sh setup.sh teardown.sh rung.sh ladder.sh sample.sh tests/rig.test.sh)
fails=0
check() {
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1 (want '$3', got '$2')"
    fails=$((fails + 1))
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- syntax and lint -------------------------------------------------------------------------
SC="${SHELLCHECK:-$(command -v shellcheck || true)}"
for s in "${SCRIPTS[@]}"; do
  if [ ! -f "$RIG/$s" ]; then
    check "$s exists" "missing" "present"
    continue
  fi
  bash -n "$RIG/$s" 2>"$TMP/n.out"
  check "bash -n $s" "$([ -s "$TMP/n.out" ] && echo FAIL || echo clean)" "clean"
  if [ -n "$SC" ]; then
    "$SC" -x -P "$RIG" "$RIG/$s" >"$TMP/sc.out" 2>&1
    check "shellcheck $s" "$([ -s "$TMP/sc.out" ] && echo FAIL || echo clean)" "clean"
    [ -s "$TMP/sc.out" ] && sed 's/^/    /' "$TMP/sc.out" | head -20
  else
    check "shellcheck available" "missing" "present"
  fi
done

# --- stubs -----------------------------------------------------------------------------------
STUB="$TMP/stub"
mkdir -p "$STUB"
CALLS="$TMP/calls.log"
: >"$CALLS"
for c in systemctl sudo docker podman systemd-run; do
  printf '#!/usr/bin/env bash\necho "%s $*" >>"%s"\n' "$c" "$CALLS" >"$STUB/$c"
  chmod +x "$STUB/$c"
done
# ss prints whatever $SS_FIXTURE holds, in `ss -ltnH` shape.
# shellcheck disable=SC2016  # the stub's own variables expand when the stub runs
printf '#!/usr/bin/env bash\n[ -n "${SS_FIXTURE:-}" ] && cat "$SS_FIXTURE"\nexit 0\n' >"$STUB/ss"
chmod +x "$STUB/ss"
SPATH="$STUB:$PATH"

# lib.sh guards run in a subshell so a guard's exit cannot end this test.
guard() { (PATH="$SPATH" E15_MANIFEST="$TMP/m.md" bash -c "source '$RIG/lib.sh'; $1" >"$TMP/g.out" 2>&1) && echo pass || echo refused; }

if [ -f "$RIG/lib.sh" ]; then
  # refuse_shared_paths
  check "refuse_shared_paths: /opt/serverless-harness/x" "$(guard 'refuse_shared_paths /opt/serverless-harness/x')" "refused"
  check "refuse_shared_paths: /opt/serverless-harness itself" "$(guard 'refuse_shared_paths /opt/serverless-harness')" "refused"
  check "refuse_shared_paths: dot-dot into it" "$(guard 'refuse_shared_paths /srv/e15/../../opt/serverless-harness/packages')" "refused"
  check "refuse_shared_paths: one bad among good" "$(guard 'refuse_shared_paths /srv/e15/a /opt/serverless-harness/b')" "refused"
  check "refuse_shared_paths: /srv/e15/x" "$(guard 'refuse_shared_paths /srv/e15/x /srv/e15/workspaces')" "pass"
  check "refuse_shared_paths: a sibling name is not it" "$(guard 'refuse_shared_paths /opt/serverless-harness2/x')" "pass"

  # refuse_ports
  printf 'LISTEN 0 511 127.0.0.1:9644 0.0.0.0:*\n' >"$TMP/ss-busy"
  printf 'LISTEN 0 511 0.0.0.0:9443 0.0.0.0:*\nLISTEN 0 511 127.0.0.1:19644 0.0.0.0:*\n' >"$TMP/ss-free"
  printf 'LISTEN 0 511 [::]:6400 [::]:*\n' >"$TMP/ss-v6"
  check "refuse_ports: 9644 taken" "$(SS_FIXTURE="$TMP/ss-busy" guard 'refuse_ports 9643 9644 6400')" "refused"
  check "refuse_ports: 6400 taken on v6" "$(SS_FIXTURE="$TMP/ss-v6" guard 'refuse_ports 9643 9644 6400')" "refused"
  check "refuse_ports: other ports only" "$(SS_FIXTURE="$TMP/ss-free" guard 'refuse_ports 9643 9644 6400')" "pass"
  check "refuse_ports: nothing listening" "$(guard 'refuse_ports 9643 9644 6400')" "pass"

  # refuse_units, and sctl (the only systemctl entry point) never reaching systemctl for sh-*
  check "refuse_units: stop sh-relay" "$(guard 'refuse_units stop sh-relay')" "refused"
  check "refuse_units: restart sh-supervisor.service" "$(guard 'refuse_units restart sh-supervisor.service')" "refused"
  check "refuse_units: status sh-control-plane" "$(guard 'refuse_units status sh-control-plane')" "refused"
  check "refuse_units: e15-worker" "$(guard 'refuse_units stop e15-worker')" "pass"
  check "refuse_units: microvm-worker" "$(guard 'refuse_units start microvm-worker.service')" "pass"
  : >"$CALLS"
  check "sctl stop sh-relay refused" "$(guard 'sctl stop sh-relay')" "refused"
  check "sctl stop sh-relay reached no systemctl/sudo" "$(wc -l <"$CALLS" | tr -d ' ')" "0"
  : >"$CALLS"
  check "sctl stop e15-worker passes" "$(guard 'sctl stop e15-worker')" "pass"
  check "sctl stop e15-worker reached sudo systemctl" "$(grep -c 'sudo -n systemctl stop e15-worker' "$CALLS")" "1"
fi

# --- rung.sh refuses an unknown ARM ----------------------------------------------------------
if [ -f "$RIG/rung.sh" ]; then
  : >"$CALLS"
  PATH="$SPATH" E15_MANIFEST="$TMP/m.md" bash "$RIG/rung.sh" bogus 8 default >"$TMP/r.out" 2>&1
  rc=$?
  check "rung.sh bogus ARM exits 2" "$rc" "2"
  check "rung.sh names the bad ARM" "$(grep -c "unknown ARM 'bogus'" "$TMP/r.out")" "1"
  check "rung.sh bogus ARM touched nothing" "$(wc -l <"$CALLS" | tr -d ' ')" "0"
  PATH="$SPATH" E15_MANIFEST="$TMP/m.md" bash "$RIG/rung.sh" sbx 0 default >"$TMP/r.out" 2>&1
  check "rung.sh N=0 exits 2" "$?" "2"
  PATH="$SPATH" E15_MANIFEST="$TMP/m.md" bash "$RIG/rung.sh" sbx 8 nowhere >"$TMP/r.out" 2>&1
  check "rung.sh unknown POINT exits 2" "$?" "2"
  check "rung.sh with bad args touched nothing" "$(wc -l <"$CALLS" | tr -d ' ')" "0"
fi
if [ -f "$RIG/ladder.sh" ]; then
  PATH="$SPATH" E15_MANIFEST="$TMP/m.md" bash "$RIG/ladder.sh" default bogus >"$TMP/l.out" 2>&1
  check "ladder.sh bogus ARM exits 2" "$?" "2"
  PATH="$SPATH" E15_MANIFEST="$TMP/m.md" bash "$RIG/ladder.sh" default sbx 12 >"$TMP/l.out" 2>&1
  check "ladder.sh START_N off the ladder exits 2" "$?" "2"
fi

# --- teardown.sh replays UNDO lines in reverse -----------------------------------------------
if [ -f "$RIG/teardown.sh" ]; then
  OUT="$TMP/replayed"
  export OUT
  M="$TMP/fixture-manifest.md"
  cat >"$M" <<'EOF'
# E15 rig manifest
## Setup 2026-11-01T00:00:00Z
- 2026-11-01T00:00:01Z old: an earlier cycle's change | UNDO: echo stale >>"$OUT"
## Teardown 2026-11-01T01:00:00Z
- 2026-11-01T01:00:01Z replayed: echo stale >>"$OUT"
## Setup 2026-11-01T02:00:00Z
- 2026-11-01T02:00:01Z created /srv/e15 | PURGE: echo purge-a >>"$OUT"
- 2026-11-01T02:00:02Z first change | UNDO: echo one >>"$OUT"
- 2026-11-01T02:00:03Z a note with no undo
- 2026-11-01T02:00:04Z second change | UNDO: echo two >>"$OUT"
- 2026-11-01T02:00:05Z built an artifact | PURGE: echo purge-b >>"$OUT"
- 2026-11-01T02:00:06Z third change | UNDO: echo three >>"$OUT"
EOF
  : >"$OUT"
  PATH="$SPATH" E15_MANIFEST="$M" E15_TEARDOWN_VERIFY=0 bash "$RIG/teardown.sh" >"$TMP/t.out" 2>&1
  check "teardown.sh exits 0" "$?" "0"
  check "teardown.sh replayed UNDO in reverse, current cycle only" "$(tr '\n' ' ' <"$OUT")" "three two one "
  check "teardown.sh appended a Teardown section" "$(grep -c '^## Teardown' "$M")" "2"
  : >"$OUT"
  PATH="$SPATH" E15_MANIFEST="$M" E15_TEARDOWN_VERIFY=0 bash "$RIG/teardown.sh" >"$TMP/t.out" 2>&1
  check "second teardown replays nothing" "$(tr '\n' ' ' <"$OUT")" ""
  : >"$OUT"
  PATH="$SPATH" E15_MANIFEST="$M" E15_TEARDOWN_VERIFY=0 bash "$RIG/teardown.sh" --purge >"$TMP/t.out" 2>&1
  check "teardown.sh --purge replays PURGE in reverse" "$(tr '\n' ' ' <"$OUT")" "purge-b purge-a "
  : >"$OUT"
  # shellcheck disable=SC2016  # $OUT expands when teardown.sh replays the line
  printf -- '- x failing | UNDO: false\n- y after | UNDO: echo after >>"$OUT"\n' >"$TMP/m2.md"
  PATH="$SPATH" E15_MANIFEST="$TMP/m2.md" E15_TEARDOWN_VERIFY=0 bash "$RIG/teardown.sh" >"$TMP/t.out" 2>&1
  check "a failing undo is reported (exit 1)" "$?" "1"
  check "a failing undo does not stop the rest" "$(tr '\n' ' ' <"$OUT")" "after "
fi

# --- fix round 1 ------------------------------------------------------------------------------

# (6) E15_ROOT must be under /srv/e15 (or this test's own named scratch root)
check "lib.sh refuses E15_ROOT=/tmp/x" "$( (E15_ROOT=/tmp/x bash -c "source '$RIG/lib.sh'" >/dev/null 2>&1) && echo pass || echo refused)" "refused"
check "lib.sh refuses E15_ROOT=/srv/e15x" "$( (E15_ROOT=/srv/e15x bash -c "source '$RIG/lib.sh'" >/dev/null 2>&1) && echo pass || echo refused)" "refused"
check "lib.sh accepts E15_ROOT=/srv/e15/sub" "$( (E15_ROOT=/srv/e15/sub bash -c "source '$RIG/lib.sh'" >/dev/null 2>&1) && echo pass || echo refused)" "pass"
TROOT="$TMP/e15-rig-test.root"
check "lib.sh refuses a test root not named by E15_TEST_ROOT" "$( (E15_ROOT="$TROOT" bash -c "source '$RIG/lib.sh'" >/dev/null 2>&1) && echo pass || echo refused)" "refused"

# (1) the relay's UNDO is in the manifest before its start can fail
if [ -f "$RIG/setup.sh" ]; then
  relay_undo_line=$(grep -n 'm_change "starting \$E15_UNIT_RELAY' "$RIG/setup.sh" | cut -d: -f1)
  relay_start_line=$(grep -n '^  start_relay$' "$RIG/setup.sh" | cut -d: -f1)
  check "setup.sh records the relay UNDO before start_relay" \
    "$([ -n "$relay_undo_line" ] && [ -n "$relay_start_line" ] && [ "$relay_undo_line" -lt "$relay_start_line" ] && echo yes || echo no)" "yes"
  check "setup.sh stops the relay before dying on a Redis error" \
    "$(grep -A3 "redis client error" "$RIG/setup.sh" | grep -c 'stop_e15_unit "\$E15_UNIT_RELAY"')" "1"
  # start_relay itself: a relay that never listens is stopped before die
  printf '#!/usr/bin/env bash\necho "sudo $*" >>"%s"\n[ "$1 $2 $3" = "-n systemctl is-active" ] && exit 0\nexit 0\n' "$CALLS" >"$STUB/sudo"
  : >"$CALLS"
  (PATH="$SPATH" E15_MANIFEST="$TMP/m.md" bash -c "source '$RIG/lib.sh'; wait_for() { return 1; }; mkdir() { :; }; start_relay" >/dev/null 2>&1)
  check "start_relay: no listener -> exits non-zero" "$?" "1"
  check "start_relay: no listener -> stops e15-relay" "$(grep -c 'systemctl stop e15-relay.service' "$CALLS")" "1"
  printf '#!/usr/bin/env bash\necho "sudo $*" >>"%s"\n' "$CALLS" >"$STUB/sudo"
fi

# (6) the loop mount is undone on failure
check "setup.sh traps the rootfs loop mount" "$(grep -c "trap 'mountpoint -q \"\$mnt\" && sudo -n umount -d" "$RIG/setup.sh")" "1"

# (2) a failed undo is retried by the next teardown, and only it
if [ -f "$RIG/teardown.sh" ]; then
  M3="$TMP/m3.md"
  FLAG="$TMP/flag"
  : >"$OUT"
  # shellcheck disable=SC2016  # $OUT/$FLAG expand when teardown.sh replays the line
  printf -- '## Setup x\n- a | UNDO: echo a >>"$OUT"\n- b | UNDO: [ -e "%s" ] && echo b >>"$OUT"\n- c | UNDO: echo c >>"$OUT"\n' "$FLAG" >"$M3"
  rm -f "$FLAG"
  PATH="$SPATH" E15_MANIFEST="$M3" E15_TEARDOWN_VERIFY=0 bash "$RIG/teardown.sh" >/dev/null 2>&1
  check "first teardown exits 1 on the failed undo" "$?" "1"
  check "first teardown ran the others" "$(tr '\n' ' ' <"$OUT")" "c a "
  : >"$OUT"
  touch "$FLAG"
  PATH="$SPATH" E15_MANIFEST="$M3" E15_TEARDOWN_VERIFY=0 bash "$RIG/teardown.sh" >/dev/null 2>&1
  check "second teardown exits 0" "$?" "0"
  check "second teardown retried only the failed undo" "$(tr '\n' ' ' <"$OUT")" "b "
  : >"$OUT"
  PATH="$SPATH" E15_MANIFEST="$M3" E15_TEARDOWN_VERIFY=0 bash "$RIG/teardown.sh" >/dev/null 2>&1
  check "third teardown replays nothing" "$(tr '\n' ' ' <"$OUT")" ""

  # (6) verify against the PRESTATE setup recorded
  for case in "active:active:0" "inactive:inactive:0" "active:inactive:1" "inactive:active:1"; do
    pre=${case%%:*} rest=${case#*:} now=${rest%%:*} want_rc=${rest#*:}
    printf '#!/usr/bin/env bash\n[ "$1" = is-active ] && [ "$3" = microvm-worker.service ] && exit %s\nexit 1\n' \
      "$([ "$now" = active ] && echo 0 || echo 1)" >"$STUB/systemctl"
    printf '#!/usr/bin/env bash\ncase "$*" in *"docker inspect"*) echo true; exit 0 ;; esac\nexit 1\n' >"$STUB/sudo"
    printf -- '## Setup x\n- t PRESTATE: microvm-worker.service=%s bench-cp=true bench-redis=true\n' "$pre" >"$TMP/m4.md"
    PATH="$SPATH" E15_MANIFEST="$TMP/m4.md" bash "$RIG/teardown.sh" >/dev/null 2>&1
    check "teardown verify: worker was $pre, is $now -> exit $want_rc" "$?" "$want_rc"
  done
  printf '#!/usr/bin/env bash\necho "systemctl $*" >>"%s"\n' "$CALLS" >"$STUB/systemctl"
  printf '#!/usr/bin/env bash\necho "sudo $*" >>"%s"\n' "$CALLS" >"$STUB/sudo"
fi

# (3)(5) ladder.sh against a stub rung.sh writing canned record.json files
if [ -f "$RIG/ladder.sh" ]; then
  mkdir -p "$TROOT"
  STUBRUNG="$TMP/stub-rung.sh"
  # RECS: "N[-tag]=json" lines; the stub writes that record for (N, tag) and logs the call.
  cat >"$STUBRUNG" <<'SH'
#!/usr/bin/env bash
n=$2 tag=${E15_TAG:-}
key="$n${tag:+-$tag}"
echo "$key k=${E15_K_MULT:-1} w=${E15_WARMUP_S:-}" >>"$LADDER_CALLS"
rec=$(grep "^$key=" "$RECS" | head -1 | cut -d= -f2-)
[ -n "$rec" ] || exit 1
d="$E15_ROOT/runs/$3/$1/N$key"
mkdir -p "$d"
printf '%s\n' "$rec" >"$d/record.json"
SH
  ladder() {
    rm -rf "$TROOT/runs"
    : >"$TMP/lcalls"
    E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" E15_RUNG="$STUBRUNG" RECS="$TMP/recs" LADDER_CALLS="$TMP/lcalls" \
      PATH="$SPATH" E15_MANIFEST="$TMP/m.md" bash "$RIG/ladder.sh" default sbx >"$TMP/l.out" 2>&1
  }
  lj() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2]))' "$TROOT/runs/default/sbx/ladder.json" "$1"; }
  ok='{"holds":true,"holds_abs":true,"unseeded_sessions":0}'
  abs_only='{"holds":false,"holds_abs":true,"unseeded_sessions":0}'
  both_bad='{"holds":false,"holds_abs":false,"unseeded_sessions":0}'

  printf '1=%s\n8=%s\n16=%s\n24=%s\n32=%s\n' "$ok" "$ok" "$abs_only" "$abs_only" "$both_bad" >"$TMP/recs"
  ladder
  check "ladder: n_max_abs climb exits 0" "$?" "0"
  check "ladder: n_max is the 2x ladder" "$(lj n_max)" "8"
  check "ladder: stopped_at is the first holds=false" "$(lj stopped_at)" "16"
  check "ladder: n_max_abs keeps climbing" "$(lj n_max_abs)" "24"
  check "ladder: stops where both are false" "$(lj stopped_at_abs)" "32"
  check "ladder: ran 5 rungs" "$(wc -l <"$TMP/lcalls" | tr -d ' ')" "5"

  printf '1=%s\n8=%s\n' "$ok" "$both_bad" >"$TMP/recs"
  ladder
  check "ladder: both fail together -> stop at once" "$(lj n_max)/$(lj n_max_abs)/$(wc -l <"$TMP/lcalls" | tr -d ' ')" "1/1/2"

  printf '1=%s\n8=%s\n' "$ok" '{"holds":false,"holds_abs":false,"aborted":true}' >"$TMP/recs"
  ladder
  check "ladder: aborted rung dies" "$?" "1"
  check "ladder: aborted rung writes no ladder.json" "$([ -f "$TROOT/runs/default/sbx/ladder.json" ] && echo yes || echo no)" "no"
  printf '1=%s\n8=%s\n' "$ok" '{"holds":false,"holds_abs":false,"time_origin_mismatch":true}' >"$TMP/recs"
  ladder
  check "ladder: time_origin_mismatch dies" "$?" "1"
  printf '1=%s\n' "$ok" >"$TMP/recs"
  ladder
  check "ladder: a failing rung.sh (e.g. no baseline) dies" "$?" "1"

  printf '1=%s\n1-k2=%s\n8=%s\n' '{"holds":false,"holds_abs":false,"unseeded_sessions":2}' "$ok" "$both_bad" >"$TMP/recs"
  ladder
  check "ladder: unseeded -> re-run with K doubled, then counts" "$(lj n_max)" "1"
  check "ladder: the re-run had E15_K_MULT=2" "$(grep -c '^1-k2 k=2' "$TMP/lcalls")" "1"
  check "ladder: the rig error is recorded" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["rungs"][0]["rig_errors"])' "$TROOT/runs/default/sbx/ladder.json")" "['unseeded_sessions=2']"
  printf '1=%s\n1-k2=%s\n' '{"unseeded_sessions":2}' '{"unseeded_sessions":1}' >"$TMP/recs"
  ladder
  check "ladder: still unseeded with K doubled dies" "$?" "1"

  printf '1=%s\n1-repeat=%s\n8=%s\n' '{"holds":false,"holds_abs":false,"repeat_required":true,"unseeded_sessions":0}' "$ok" "$both_bad" >"$TMP/recs"
  E15_WARMUP_S=30 ladder
  check "ladder: repeat_required re-runs with warm-up doubled and the repeat counts" "$(lj n_max)/$(grep -c '^1-repeat k=1 w=60' "$TMP/lcalls")" "1/1"
fi

# (3) rung.sh refuses N>1 with no baseline before touching anything
if [ -f "$RIG/rung.sh" ]; then
  mkdir -p "$TROOT/corpora/default" "$TROOT/src/e15/commands" "$TROOT/bin" "$TROOT/template"
  : >"$TROOT/corpora/default/corpus.jsonl"
  : >"$TROOT/src/e15/commands/library.json"
  printf '#!/bin/sh\n' >"$TROOT/bin/e15-driver"
  chmod +x "$TROOT/bin/e15-driver"
  : >"$TROOT/template/workspace.img"
  printf '#!/usr/bin/env bash\n[ "$1" = is-active ] && exit 0\nexit 0\n' >"$STUB/systemctl"
  : >"$CALLS"
  rm -rf "$TROOT/runs"
  E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" PATH="$SPATH" E15_MANIFEST="$TMP/m.md" bash "$RIG/rung.sh" sbx 8 default >"$TMP/r.out" 2>&1
  check "rung.sh N=8 with no baseline exits 1" "$?" "1"
  check "rung.sh names the missing baseline" "$(grep -c 'no N=1 baseline' "$TMP/r.out")" "1"
  check "rung.sh with no baseline touched nothing" "$(grep -c . "$CALLS")" "0"
  printf '#!/usr/bin/env bash\necho "systemctl $*" >>"%s"\n' "$CALLS" >"$STUB/systemctl"
fi

# (4) rung.sh puts the e15.slice oom_kill delta in params.json
check "rung.sh reads oom_kill from e15.slice memory.events" "$(grep -c 'oom_kill' "$RIG/rung.sh")" "2"
check "rung.sh writes oom_kills into params" "$(grep -c '"oom_kills": \$oom_after - \$oom_before' "$RIG/rung.sh")" "1"

echo
if [ "$fails" -eq 0 ]; then
  echo "rig.test.sh: all checks passed"
else
  echo "rig.test.sh: $fails check(s) FAILED"
fi
[ "$fails" -eq 0 ]
