#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted $ here are stub bodies, grep patterns and manifest lines
# experiments/e15-session-density/rig/tests/rig.test.sh
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
# Run: bash experiments/e15-session-density/rig/tests/rig.test.sh      (SHELLCHECK=/path/to/shellcheck if not on PATH)
set -uo pipefail

RIG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS=(lib.sh points.sh setup.sh teardown.sh rung.sh ladder.sh sample.sh baseline.sh classprobe.sh tests/rig.test.sh tests/golden/dump.sh)
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
echo "$key k=${E15_K_MULT:-1} w=${E15_WARMUP_S:-} ms=${E15_MAX_SESSIONS:-unset} sz=${E15_START_ZERO:-unset}" >>"$LADDER_CALLS"
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

  # E16: E15_LADDER_RUNGS, an explicit rung list (fresh-metal only)
  ladder_rungs() { # PROFILE RUNGS
    rm -rf "$TROOT/runs"
    : >"$TMP/lcalls"
    E15_LADDER_RUNGS="$2" E15_HOST_PROFILE="$1" E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" E15_RUNG="$STUBRUNG" RECS="$TMP/recs" \
      LADDER_CALLS="$TMP/lcalls" PATH="$SPATH" E15_MANIFEST="$TMP/m.md" bash "$RIG/ladder.sh" default sbx >"$TMP/l.out" 2>&1
  }
  ljj() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d.get(sys.argv[2], "absent"), separators=(",", ":")))' "$TROOT/runs/default/sbx/ladder.json" "$1"; }
  printf '256=%s
384=%s
512=%s
' "$ok" "$both_bad" "$ok" >"$TMP/recs"
  ladder_rungs fresh-metal "256 384 512"
  check "E16 ladder: explicit rungs exit 0" "$?" "0"
  check "E16 ladder: rung.sh called for 256, 384 only" "$(cut -d' ' -f1 "$TMP/lcalls" | tr '\n' ' ')" "256 384 "
  check "E16 ladder: n_max 256, stopped_at 384" "$(lj n_max)/$(lj stopped_at)" "256/384"
  check "E16 ladder: rungs_requested [256,384,512]" "$(ljj rungs_requested)" "[256,384,512]"
  check "E16 ladder: start_n is the first requested rung" "$(lj start_n)" "256"
  printf '256=%s
384=%s
512=%s
' "$ok" "$abs_only" "$both_bad" >"$TMP/recs"
  ladder_rungs fresh-metal "256 384 512"
  check "E16 ladder: climbs while either verdict holds" "$(cut -d' ' -f1 "$TMP/lcalls" | tr '\n' ' ')/$(lj n_max)/$(lj n_max_abs)" "256 384 512 /256/384"
  printf '256=%s
256-repeat=%s
384=%s
' '{"holds":true,"holds_abs":true,"unseeded_sessions":0,"repeat_required":true}' "$ok" "$both_bad" >"$TMP/recs"
  ladder_rungs fresh-metal "256 384"
  check "E16 ladder: repeats keep the E15 rule (warm-up x2, K x2)" "$(grep -c '^256-repeat k=2 w=2400' "$TMP/lcalls")/$(lj n_max)" "1/256"
  ladder_rungs fresh-metal "256 300 512"
  check "E16 ladder: a rung not on the ladder exits 2" "$?" "2"
  check "E16 ladder: ... with the message" "$(grep -c '^ladder.sh: E15_LADDER_RUNGS: N=300 is not on the ladder$' "$TMP/l.out")" "1"
  check "E16 ladder: ... and runs nothing" "$(wc -l <"$TMP/lcalls" | tr -d ' ')/$([ -f "$TROOT/runs/default/sbx/ladder.json" ] && echo yes || echo no)" "0/no"
  ladder_rungs fresh-metal "384 256"
  check "E16 ladder: a descending list exits 2, runs nothing" "$?/$(wc -l <"$TMP/lcalls" | tr -d ' ')" "2/0"
  ladder_rungs fresh-metal "256 x"
  check "E16 ladder: a non-number exits 2" "$?" "2"
  printf '1=%s
8=%s
' "$ok" "$both_bad" >"$TMP/recs"
  ladder_rungs aws-prelim "256 384 512"
  check "E16 ladder: aws-prelim ignores E15_LADDER_RUNGS (climbs from 1)" "$?/$(cut -d' ' -f1 "$TMP/lcalls" | tr '\n' ' ')/$(ljj rungs_requested)" "0/1 8 /\"absent\""
  ladder_rungs fresh-metal ""
  check "E16 ladder: unset on fresh-metal -> the ladder from 1, no rungs_requested" "$?/$(cut -d' ' -f1 "$TMP/lcalls" | tr '\n' ' ')/$(ljj rungs_requested)" "0/1 8 /\"absent\""

  # probe-only knobs exported in the caller's shell never reach a measured rung
  printf '1=%s\n8=%s\n' "$ok" "$both_bad" >"$TMP/recs"
  rm -rf "$TROOT/runs"
  : >"$TMP/lcalls"
  E15_MAX_SESSIONS=1 E15_START_ZERO=1 E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" E15_RUNG="$STUBRUNG" RECS="$TMP/recs" \
    LADDER_CALLS="$TMP/lcalls" PATH="$SPATH" E15_MANIFEST="$TMP/m.md" bash "$RIG/ladder.sh" default sbx >"$TMP/l.out" 2>&1
  check "ladder: exported E15_MAX_SESSIONS/E15_START_ZERO never reach rung.sh" \
    "$(grep -c 'ms=unset sz=unset' "$TMP/lcalls")/$(wc -l <"$TMP/lcalls" | tr -d ' ')" "2/2"

  printf '1=%s\n8=%s\n' "$ok" "$both_bad" >"$TMP/recs"
  ladder
  check "ladder: both fail together -> stop at once" "$(lj n_max)/$(lj n_max_abs)/$(wc -l <"$TMP/lcalls" | tr -d ' ')" "1/1/2"
  printf '1=%s\n8=%s\n' "$ok" '{"holds":false,"holds_abs":false,"unseeded_sessions":0,"median_class_pace":0.0}' >"$TMP/recs"
  ladder
  check "ladder.json rungs carry median_class_pace" "$(python3 -c 'import json,sys; print([r["median_class_pace"] for r in json.load(open(sys.argv[1]))["rungs"]])' "$TROOT/runs/default/sbx/ladder.json")" "[None, 0.0]"
  printf '1=%s\n8=%s\n' "$ok" '{"holds":false,"holds_abs":false,"offset_join_misses":2,"reason":"corpus_join_miss"}' >"$TMP/recs"
  ladder
  check "ladder: offset_join_misses > 0 is a rig error (dies, no ladder.json)" "$?/$([ -f "$TROOT/runs/default/sbx/ladder.json" ] && echo yes || echo no)" "1/no"
  check "ladder: the death names offset_join_misses" "$(grep -c 'offset_join_misses=2' "$TMP/l.out")" "1"
  printf '1=%s\n8=%s\n' "$ok" '{"holds":false,"holds_abs":false,"offset_join_misses":0,"unseeded_sessions":0}' >"$TMP/recs"
  ladder
  check "ladder: offset_join_misses 0 is fine" "$?" "0"

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
  mkdir -p "$TROOT/runs/default/sbx/N1"
  echo '{"overhead_ms": 12.5}' >"$TROOT/runs/default/sbx/N1/baseline.json"
  check "ladder.json would read n1_overhead_ms from N1/baseline.json (rule text mentions B + 250)" "$(grep -v '^#' "$RIG/ladder.sh" | grep -c 'B + 250 ms')/$(grep -v '^#' "$RIG/ladder.sh" | grep -c 'n1_overhead_ms')/$(grep -c '"n1_median_pace": n1_pace' "$RIG/ladder.sh")/$(grep -v '^#' "$RIG/ladder.sh" | grep -c 'median_class_pace')" "1/1/1/2"
  rm -f "$TROOT/runs/default/sbx/N1/baseline.json"
  check "ladder: the rig error is recorded" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["rungs"][0]["rig_errors"])' "$TROOT/runs/default/sbx/ladder.json")" "['unseeded_sessions=2']"
  printf '1=%s\n1-k2=%s\n' '{"unseeded_sessions":2}' '{"unseeded_sessions":1}' >"$TMP/recs"
  ladder
  check "ladder: still unseeded with K doubled dies" "$?" "1"

  printf '1=%s\n1-repeat=%s\n8=%s\n' '{"holds":false,"holds_abs":false,"repeat_required":true,"unseeded_sessions":0}' "$ok" "$both_bad" >"$TMP/recs"
  E15_WARMUP_S=30 ladder
  check "ladder: repeat_required re-runs with warm-up doubled and the repeat counts" "$(lj n_max)/$(grep -c '^1-repeat k=1 w=60' "$TMP/lcalls")" "1/1"
  # fresh-metal resident arm, no E15_WARMUP_S: the repeat doubles the 1200 s default
  printf '1=%s\n1-repeat=%s\n8=%s\n' '{"holds":false,"holds_abs":false,"repeat_required":true,"unseeded_sessions":0}' "$ok" "$both_bad" >"$TMP/recs"
  rm -rf "$TROOT/runs"; : >"$TMP/lcalls"
  E15_HOST_PROFILE=fresh-metal E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" E15_RUNG="$STUBRUNG" RECS="$TMP/recs" LADDER_CALLS="$TMP/lcalls" \
    PATH="$SPATH" E15_MANIFEST="$TMP/m.md" bash "$RIG/ladder.sh" default resident-inf >"$TMP/l.out" 2>&1
  check "ladder: fresh-metal resident repeat runs with warm-up 2400 (2 x 1200) and K doubled" "$(grep -c '^1-repeat k=2 w=2400' "$TMP/lcalls")" "1"
  # aws-prelim keeps K x1 on the repeat (sealed preliminary procedure)
  check "ladder: aws-prelim repeat keeps K x1" "$(E15_WARMUP_S=30 ladder; grep -c '^1-repeat k=1 w=60' "$TMP/lcalls")" "1"
  # fresh-metal: a repeat still unseeded with K x2 is re-run once with K doubled again (tag repeat-k2) and counts
  printf '1=%s\n1-repeat=%s\n1-repeat-k2=%s\n8=%s\n' '{"holds":false,"holds_abs":false,"repeat_required":true,"unseeded_sessions":0}' \
    '{"holds":false,"holds_abs":false,"unseeded_sessions":3}' "$ok" "$both_bad" >"$TMP/recs"
  rm -rf "$TROOT/runs"; : >"$TMP/lcalls"
  E15_HOST_PROFILE=fresh-metal E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" E15_RUNG="$STUBRUNG" RECS="$TMP/recs" LADDER_CALLS="$TMP/lcalls" \
    PATH="$SPATH" E15_MANIFEST="$TMP/m.md" bash "$RIG/ladder.sh" default resident-inf >"$TMP/l.out" 2>&1
  check "ladder: fresh-metal unseeded repeat -> repeat-k2 with K x4, which counts" "$?/$(grep -c '^1-repeat-k2 k=4 w=2400' "$TMP/lcalls")/$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["n_max"])' "$TROOT/runs/default/resident-inf/ladder.json")" "0/1/1"
  check "ladder.json records the repeat's unseeded rig error" "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["rungs"][0]["rig_errors"]))' "$TROOT/runs/default/resident-inf/ladder.json")" "1"
fi

# classprobe.sh: one sequential rung per class, override corpus, tag probe-<class>, warm-up 0
if [ -f "$RIG/classprobe.sh" ]; then
  PRUNG="$TMP/stub-rung-p.sh"
  cat >"$PRUNG" <<'SH'
#!/usr/bin/env bash
echo "$1 $2 $3 tag=$E15_TAG warm=$E15_WARMUP_S win=$E15_WINDOW_S zero=$E15_START_ZERO max=$E15_MAX_SESSIONS sessions=$(grep -c . "$E15_CORPUS_OVERRIDE")" >>"$P_CALLS"
d="$E15_ROOT/runs/$3/$1/N$2-$E15_TAG"
mkdir -p "$d"
: >"$d/calls.jsonl"
n=20
[ "$E15_TAG" = "$P_SHORT" ] && n=19
for ((i = 0; i < n; i++)); do echo '{"in_window": true, "status": "ok"}' >>"$d/calls.jsonl"; done
echo '{"in_window": false, "status": "ok"}' >>"$d/calls.jsonl"
SH
  mkdir -p "$TROOT/src/e15/commands" "$TROOT/corpora/default" "$TROOT/src/e15"
  ln -sfn "$RIG/../analysis" "$TROOT/src/e15/analysis"
  printf '%s\n' '{"session":"s","user":"u","provider":"claude","calls":[{"i":0,"class":"read","work_ms":5,"dur_ms":50,"chain":false}]}' >"$TROOT/corpora/default/corpus.jsonl"
  printf '%s\n' '{"version":1,"classes":{"read":[{"id":"r","cmd":"x","exit":0,"nominal_ms":30,"run_ms":3}],"test":[{"id":"t","cmd":"y","exit":0,"nominal_ms":900,"run_ms":None}]},"standin":{}}' | sed 's/None/null/' >"$TROOT/src/e15/commands/library.json"
  : >"$TMP/pcalls"
  out=$(env E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" E15_RUNG="$PRUNG" P_SHORT=none P_CALLS="$TMP/pcalls" PATH="$SPATH" E15_MANIFEST="$TMP/m.md" bash "$RIG/classprobe.sh" default sbx 2>"$TMP/p.err")
  check "classprobe.sh exits 0" "$?" "0"
  check "classprobe.sh: one sequential rung per class (library + stand-ins)" "$(cut -d' ' -f1-4 "$TMP/pcalls" | tr '\n' '|')" "sbx 1 default tag=probe-build|sbx 1 default tag=probe-host_infra|sbx 1 default tag=probe-opaque|sbx 1 default tag=probe-read|sbx 1 default tag=probe-test|"
  check "classprobe.sh: warm-up 0, start at zero, one session each, window >= span + 60" "$(awk '{print $5,$7,$8,$9}' "$TMP/pcalls" | sort -u | tr '\n' '|')" "warm=0 zero=1 max=1 sessions=1|"
  check "classprobe.sh: prints the probe run dirs" "$(echo "$out" | wc -l | tr -d ' ')/$(echo "$out" | head -1)" "5/$TROOT/runs/default/sbx/N1-probe-build"
  check "classprobe.sh: window is 2 x span + 120 s (>= 2*38+120)" "$(grep 'probe-read' "$TMP/pcalls" | sed 's/.*win=\([0-9]*\).*/\1/' | awk '{print ($1 >= 2*38+120) ? "ok" : "short"}')" "ok"
fi

if [ -f "$RIG/classprobe.sh" ]; then
  : >"$TMP/pcalls"
  env E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" E15_RUNG="$PRUNG" P_SHORT=probe-test P_CALLS="$TMP/pcalls" PATH="$SPATH" E15_MANIFEST="$TMP/m.md" bash "$RIG/classprobe.sh" default sbx >"$TMP/p.out" 2>"$TMP/p.err"
  check "classprobe.sh: a probe with != 20 in-window calls dies" "$?" "1"
  check "classprobe.sh: the death names the class and counts" "$(grep -c 'probe test: 19 in-window calls.*expected exactly 20' "$TMP/p.err")" "1"
  check "classprobe.sh: prints per-class planned spans and the total first" "$(grep -c 'planned span' "$TMP/p.err")" "6"
fi

# rung.sh: K has a floor of 16 workspaces per slot
if [ -f "$RIG/rung.sh" ]; then
  check "rung.sh K floor: max(16, formula) (aws-prelim, sealed)" "$(grep -c 'print(max(16, (int(math.ceil' "$RIG/rung.sh")" "1"
  check "rung.sh K: fresh-metal multiplies the floored K" "$(grep -c 'print(max(16, int(math.ceil(w / s)) + 3) \* int(sys.argv\[3\]))' "$RIG/rung.sh")" "1"
  kf=$(sed -n '/^K=\$(python3/p' "$RIG/rung.sh" | sed 's/^K=\$(//; s/)$//')
  kfm=$(sed -n '/^  K=\$(python3/p' "$RIG/rung.sh" | sed 's/^  K=\$(//; s/)$//')
  # shellcheck disable=SC2001
  check "rung.sh K: short run gets 16" "$(eval "$(echo "$kf" | sed 's/"\$((WARMUP + WINDOW))" "\$span_min" "\$K_MULT"/"1500" "30" "1"/')")" "16"
  # K_MULT multiplies the floored K: a doubled pool on a short-formula run is 32, not the floor 16 again
  # shellcheck disable=SC2001
  check "rung.sh K: fresh-metal K_MULT=2 at the default span (3300 s, 123 min) gets 32" "$(eval "$(echo "$kfm" | sed 's/"\$((WARMUP + WINDOW))" "\$span_min" "\$K_MULT"/"3300" "123" "2"/')")" "32"
  # shellcheck disable=SC2001
  # shellcheck disable=SC2001
  check "rung.sh K: aws-prelim K_MULT=2 at the default span stays 16 (sealed)" "$(eval "$(echo "$kf" | sed 's/"\$((WARMUP + WINDOW))" "\$span_min" "\$K_MULT"/"3300" "123" "2"/')")" "16"
  # shellcheck disable=SC2001
  check "rung.sh K: fresh-metal K_MULT=1 equals the sealed formula (long run)" "$(eval "$(echo "$kfm" | sed 's/"\$((WARMUP + WINDOW))" "\$span_min" "\$K_MULT"/"36000" "30" "1"/')")" "23"
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

# --- fix round 2 ------------------------------------------------------------------------------

# stub_rec FILE KEY VALUE [k=v ...]: a record/baseline JSON whose library, driver and corpus hashes
# match the test root's (as rung.sh computes them for POINT=default), with overrides.
psig() { E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; source "$2"; e15_point_sig "$3"' _ "$RIG/lib.sh" "$RIG/points.sh" "$1"; }
sha_f() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
stub_rec() {
  local f=$1 key=$2 val=$3
  shift 3
  mkdir -p "$(dirname "$f")"
  local sp=${STUB_POINT:-default} cdir
  cdir=$(E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; source "$2"; e15_point "$3"; echo "$E15_P_CORPUS"' _ "$RIG/lib.sh" "$RIG/points.sh" "$sp")
  python3 - "$f" "$key" "$val" "$(sha_f "$TROOT/src/e15/commands/library.json")" "$(sha_f "$TROOT/bin/e15-driver")" \
    "$(sha_f "$TROOT/corpora/$cdir/corpus.jsonl")" "$(psig "$sp")" "$@" <<'PY2'
import json, sys
f, key, val, lib, drv, corpus, sig = sys.argv[1:8]
d = {key: float(val), "library_sha256": lib, "driver_bin_sha256": drv, "corpus_sha256": corpus, "point_sig": sig}
for kv in sys.argv[8:]:
    k, v = kv.split("=", 1)
    d[k] = v
json.dump(d, open(f, "w"))
PY2
}

# --- Task 8a ---------------------------------------------------------------------------------

# rung.sh's baseline lookup: pooled N1/baseline.json (this point, then default), no other source
if [ -f "$RIG/rung.sh" ]; then
  printf '#!/usr/bin/env bash\n[ "$1" = is-active ] && exit 0\nexit 0\n' >"$STUB/systemctl"
  mkdir -p "$TROOT/corpora/short"
  echo short-corpus >"$TROOT/corpora/short/corpus.jsonl"
  base_at() { # POINT [ARM] [N]
    E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" PATH="$SPATH" E15_MANIFEST="$TMP/m.md" bash -c '
      set -e; source "$1"; source "${1%/lib.sh}/points.sh"; E15_PROG=t
      N=${4:-8} POINT=$3 ARM=${5:-sbx}; e15_point "$POINT"
      eval "$(sed -n "/^WINDOW=\${E15_WINDOW_S:-900}/,/^# end baseline resolution/p" "$2")"
      echo "$baseline_path|$baseline_src"' _ "$RIG/lib.sh" "$RIG/rung.sh" "$1" "${2:-8}" "${3:-sbx}" 2>"$TMP/base.err"
  }
  rm -rf "$TROOT/runs"
  base_at default >/dev/null
  check "baseline lookup: none present -> rung dies" "$?" "1"
  check "baseline lookup: the death says run baseline.sh" "$(grep -c 'run baseline.sh default sbx' "$TMP/base.err")" "1"
  STUB_POINT=default stub_rec "$TROOT/runs/default/sbx/N1-repeat/record.json" p95_added_ms 300
  base_at default >/dev/null
  check "baseline lookup: an N1 record.json is no longer a baseline" "$?" "1"
  GOOD='class_medians={} global_median_ms=1 excess_p95_ms=2 n1_median_pace=0.1'
  # stub_rec stores string values; rung.sh only checks the keys
  # shellcheck disable=SC2086
  STUB_POINT=default stub_rec "$TROOT/runs/default/sbx/N1/baseline.json" baseline_p95_ms 42.5 $GOOD
  check "baseline lookup: the default point's baseline.json" "$(base_at default)" "\"$TROOT/runs/default/sbx/N1/baseline.json\"|$TROOT/runs/default/sbx/N1/baseline.json"
  check "baseline lookup: short falls back to default's when it has no pooled runs" "$(base_at short | cut -d'|' -f2)" "$TROOT/runs/default/sbx/N1/baseline.json"
  # shellcheck disable=SC2086
  STUB_POINT=short stub_rec "$TROOT/runs/short/sbx/N1/baseline.json" baseline_p95_ms 17 $GOOD
  check "baseline lookup: this point's baseline.json first" "$(base_at short | cut -d'|' -f2)" "$TROOT/runs/short/sbx/N1/baseline.json"
  check "baseline lookup: N=1 needs none" "$(base_at default 1 | cut -d'|' -f2)" "none"

  # stale-baseline guard: die with the reason
  rm -rf "$TROOT/runs"
  # shellcheck disable=SC2086
  STUB_POINT=default stub_rec "$TROOT/runs/default/sbx/N1/baseline.json" baseline_p95_ms 50 library_sha256=old $GOOD
  base_at default >/dev/null
  check "stale guard: a baseline.json from another library -> rung dies" "$?" "1"
  check "stale guard: the death names the reason" "$(grep -c 'stale N=1 baseline .*library_sha256 old' "$TMP/base.err")" "1"
  # shellcheck disable=SC2086
  STUB_POINT=default stub_rec "$TROOT/runs/default/sbx/N1/baseline.json" baseline_p95_ms 50 driver_bin_sha256=old $GOOD
  base_at default >/dev/null
  check "stale guard: another driver binary -> dies" "$?" "1"
  # a baseline without class medians (an old pooled-p95 one) is stale too
  STUB_POINT=default stub_rec "$TROOT/runs/default/sbx/N1/baseline.json" baseline_p95_ms 50
  base_at default >/dev/null
  check "stale guard: a baseline.json without class medians -> dies" "$?" "1"
  check "stale guard: names the missing key" "$(grep -c 'no class_medians' "$TMP/base.err")" "1"
  # a null N=1 pace is refused (condition 3 cannot be evaluated)
  # shellcheck disable=SC2086
  STUB_POINT=default stub_rec "$TROOT/runs/default/sbx/N1/baseline.json" baseline_p95_ms 50 $GOOD
  python3 - "$TROOT/runs/default/sbx/N1/baseline.json" <<'PY3'
import json, sys
d = json.load(open(sys.argv[1]))
d["n1_median_pace"] = None
json.dump(d, open(sys.argv[1], "w"))
PY3
  base_at default >/dev/null
  check "stale guard: a null n1_median_pace -> rung dies" "$?" "1"
  check "stale guard: names n1_median_pace" "$(grep -c 'n1_median_pace missing or null' "$TMP/base.err")" "1"
  # corpus: checked for this point's own baseline, not for the default point's fallback
  rm -rf "$TROOT/runs"
  # shellcheck disable=SC2086
  STUB_POINT=default stub_rec "$TROOT/runs/short/sbx/N1/baseline.json" baseline_p95_ms 11 $GOOD
  base_at short >/dev/null
  check "stale guard: this point's baseline from another corpus -> dies" "$?" "1"
  check "stale guard: corpus named" "$(grep -c 'corpus_sha256' "$TMP/base.err")" "1"
  rm -rf "$TROOT/runs"
  # shellcheck disable=SC2086
  STUB_POINT=default stub_rec "$TROOT/runs/default/sbx/N1/baseline.json" baseline_p95_ms 22 $GOOD
  check "stale guard: default's corpus is not checked" "$(base_at short | cut -d'|' -f2)" "$TROOT/runs/default/sbx/N1/baseline.json"
  # a point with its own pooled runs never falls back to the default point
  mkdir -p "$TROOT/runs/short/sbx/N1-s1"
  base_at short >/dev/null
  check "no default fallback once this point has pooled runs" "$?" "1"
  # control is exempt at every N, with no baseline present
  rm -rf "$TROOT/runs"
  check "control N=128 needs no baseline" "$(base_at default 128 control)" "null|none (control: A2 and transport only)"
  printf '#!/usr/bin/env bash\necho "systemctl $*" >>"%s"\n' "$CALLS" >"$STUB/systemctl"
fi

# a re-run N=1 rung (ladder.sh) keeps baseline.sh's pooled baseline.json in N1/
if [ -f "$RIG/rung.sh" ]; then
  mv_block=$(sed -n '/^prev_dir=""$/,/^# baseline.sh.s pooled/{/^# baseline/!p;}; /^# baseline.sh.s pooled/,/^fi$/p' "$RIG/rung.sh")
  rm -rf "$TMP/keep" && mkdir -p "$TMP/keep/N1"
  echo '{"baseline_p95_ms": 1}' >"$TMP/keep/N1/baseline.json"
  echo old >"$TMP/keep/N1/calls.jsonl"
  (export DIR="$TMP/keep/N1" && eval "$mv_block")
  check "rung.sh re-run of N1 keeps baseline.json" "$(cat "$TMP/keep/N1/baseline.json" 2>/dev/null)" '{"baseline_p95_ms": 1}'
  check "rung.sh re-run of N1 moves the old run aside" "$([ -e "$TMP/keep/N1/calls.jsonl" ] && echo stale || echo fresh)/$(find "$TMP/keep" -name calls.jsonl -path '*N1.prev-*' | wc -l | tr -d ' ')" "fresh/1"
fi

# baseline.sh POINT ARM: three seeded N=1 rungs, pooled into N1/baseline.json; dies if one fails to hold
if [ -f "$RIG/baseline.sh" ]; then
  BRUNG="$TMP/stub-rung-b.sh"
  # Logs "ARM N POINT seed tag"; writes a record (holds from $HOLDS_<tag>, default true) and calls.
  cat >"$BRUNG" <<'SH'
#!/usr/bin/env bash
echo "$1 $2 $3 ${E15_SEED:-} ${E15_TAG:-}" >>"$B_CALLS"
d="$E15_ROOT/runs/$3/$1/N$2${E15_TAG:+-$E15_TAG}"
mkdir -p "$d"
var="HOLDS_${E15_TAG}"
rvar="REASON_${E15_TAG}"
fvar="FAILED_${E15_TAG}"
cvar="CALLS_${E15_TAG}"
reason=${!rvar:-${REASON_ALL:-}}
holds=${!var:-true}
[ -n "$reason" ] && holds=false
printf '{"holds": %s, "seed": %s, "failed_calls": %s, "refusals": 0%s}\n' "$holds" "$E15_SEED" "${!fvar:-0}" \
  "${reason:+, \"reason\": \"$reason\"}" >"$d/record.json"
add=$(( ${E15_SEED} * 10 ))
echo '{"session": "s", "window_calls": 5, "planned_ms": 1000, "observed_ms": 1100}' >"$d/sessions.jsonl"
: >"$d/calls.jsonl"
for ((i = 0; i < ${!cvar:-${CALLS_ALL:-10}}; i++)); do
  printf '{"in_window": true, "status": "ok", "class": "a", "observed_ms": %s, "planned_dur_ms": 0, "tail_ms": 0}\n' "$add" >>"$d/calls.jsonl"
done
SH
  BPROBE="$TMP/stub-probe-b.sh"
  # Prints two probe run dirs: class a (20 calls, added 10 ms) and b (20 calls, added 100 ms; 3 when PROBE_B_FEW)
  cat >"$BPROBE" <<'SH'
#!/usr/bin/env bash
echo "classprobe $1 $2" >>"$B_CALLS.probe"
for c in a b; do
  d="$E15_ROOT/runs/$1/$2/N1-probe-$c"
  mkdir -p "$d"
  add=10; n=20
  [ "$c" = b ] && add=100 && n=${PROBE_B_N:-20}
  : >"$d/calls.jsonl"
  for ((i = 0; i < n; i++)); do
    printf '{"in_window": true, "status": "ok", "class": "%s", "observed_ms": %s, "planned_dur_ms": 0, "tail_ms": 0}\n' "$c" "$add" >>"$d/calls.jsonl"
  done
  echo "$d"
done
SH
  mkdir -p "$TROOT/src/e15"
  ln -sfn "$RIG/../analysis" "$TROOT/src/e15/analysis"
  bl() {
    rm -rf "$TROOT/runs"
    : >"$TMP/bcalls"
    : >"$TMP/bcalls.probe"
    env E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" E15_RUNG="$BRUNG" E15_CLASSPROBE="$BPROBE" B_CALLS="$TMP/bcalls" \
      PATH="$SPATH" E15_MANIFEST="$TMP/m.md" "$@" bash "$RIG/baseline.sh" default sbx >"$TMP/b.out" 2>&1
  }
  bl
  check "baseline.sh exits 0 when all three hold" "$?" "0"
  check "baseline.sh ran three N=1 rungs, seeds 1-3, tags s1-s3" "$(tr '\n' '|' <"$TMP/bcalls")" "sbx 1 default 1 s1|sbx 1 default 2 s2|sbx 1 default 3 s3|"
  bj="$TROOT/runs/default/sbx/N1/baseline.json"
  check "baseline.sh pooled the three into N1/baseline.json" \
    "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["baseline_p95_ms"], d["calls"], len(d["runs"]))' "$bj" 2>&1)" "30 30 3"
  bjf() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(*[eval(e, {"d": d}) for e in sys.argv[2:]])' "$bj" "$@" 2>&1; }
  # Task 8 ruling: an empty_window run is not evaluable -- skipped, recorded, not a failure
  bl REASON_s2=empty_window
  check "baseline.sh: an empty_window seed is skipped, not a failure" "$?" "0"
  check "baseline.sh: after a skip it draws the next seed" "$(tr '\n' '|' <"$TMP/bcalls")" "sbx 1 default 1 s1|sbx 1 default 2 s2|sbx 1 default 3 s3|sbx 1 default 4 s4|"
  check "baseline.json lists evaluable and skipped seeds" \
    "$(bjf '[e["seed"] for e in d["evaluable"]]' '[(k["seed"], k["tag"], k["reason"]) for k in d["skipped"]]')" "[1, 3, 4] [(2, 's2', 'empty_window')]"
  check "baseline.sh ran the class probe after the seeds" "$(cat "$TMP/bcalls.probe")" "classprobe default sbx"
  check "baseline.json: medians and B come from the probe" "$(bjf 'd["class_medians"]' 'd["excess_p95_ms"]' 'd["undercovered"]' 'len(d["probe_runs"])')" "{'a': 10.0, 'b': 100.0} 0.0 [] 2"
  bl PROBE_B_N=3
  check "baseline.json: a class with < 5 ok probe calls is undercovered" "$(bjf 'd["undercovered"]' 'd["class_medians"]')" "['b'] {'a': 10.0}"
  bl
  check "baseline.json pools only the evaluable runs" "$(bjf 'd["calls"]' 'len(d["runs"])')" "30 3"
  # the pooled-call floor: >= 30 in-window ok calls, not just >= 3 runs
  bl CALLS_ALL=7
  check "baseline.sh: 3 runs of 7 calls are not enough; stops once >= 30 pooled" "$(tr '\n' '|' <"$TMP/bcalls")" "sbx 1 default 1 s1|sbx 1 default 2 s2|sbx 1 default 3 s3|sbx 1 default 4 s4|sbx 1 default 5 s5|"
  check "baseline.sh: floor run pooled 35 calls over 5 runs" "$(bjf 'd["calls"]' 'len(d["evaluable"])')" "35 5"
  bl CALLS_ALL=40
  check "baseline.sh: 3 runs is the minimum even when calls suffice" "$(grep -c . "$TMP/bcalls")" "3"
  # at most 12 seeds
  bl REASON_ALL=empty_window E15_BASELINE_MAX_SEEDS=12
  check "baseline.sh dies after 12 seeds without enough" "$?" "1"
  check "baseline.sh drew exactly 12 seeds" "$(grep -c . "$TMP/bcalls")" "12"
  check "baseline.sh writes no baseline.json after 12 seeds" "$([ -f "$bj" ] && echo yes || echo no)" "no"
  # an empty window that still saw a failed call is a failure, not a skip
  bl REASON_s1=empty_window FAILED_s1=1
  check "baseline.sh dies on an empty_window run with a failed call" "$?" "1"
  check "baseline.sh drew no seed after that run" "$(grep -c . "$TMP/bcalls")" "1"
  bl HOLDS_s2=false
  check "baseline.sh dies when one run does not hold" "$?" "1"
  check "baseline.sh names the run that did not hold" "$(grep -c 'N1-s2' "$TMP/b.out")" "1"
  check "baseline.sh writes no baseline.json after a failed run" "$([ -f "$bj" ] && echo yes || echo no)" "no"
  bl HOLDS_s3=null
  check "baseline.sh dies on holds=null" "$?" "1"
  PATH="$SPATH" E15_MANIFEST="$TMP/m.md" bash "$RIG/baseline.sh" default >"$TMP/b.out" 2>&1
  check "baseline.sh bad usage exits 2" "$?" "2"
  PATH="$SPATH" E15_MANIFEST="$TMP/m.md" bash "$RIG/baseline.sh" default bogus >"$TMP/b.out" 2>&1
  check "baseline.sh unknown ARM exits 2" "$?" "2"
fi

# --- Task 8c: points.sh, mem512, PRESTATE kept -------------------------------------------------

# points.sh: every point's corpus, library, template, image size and scan settings
if [ -f "$RIG/points.sh" ]; then
  pt() {
    E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; source "$2"; e15_point "$3" || exit 1
      echo "$E15_P_ARMS|$E15_P_CORPUS|${E15_P_LIBRARY#"$E15_ROOT"/}|${E15_P_TEMPLATE#"$E15_ROOT"/}|$E15_P_TEMPLATE_STAMP|$E15_P_IMAGE_MB|$E15_P_DATASET_MIB|$E15_P_DATASET_SEED|$E15_P_SCAN_CLASSES|$E15_P_SCAN_CMD"' \
      _ "$RIG/lib.sh" "$RIG/points.sh" "$1" 2>&1
  }
  plain='src/e15/commands/library.json|template/workspace.img|template|256|0|1||'
  check "points: default" "$(pt default)" "sbx resident-inf resident-300 control|default|$plain"
  check "points: short" "$(pt short)" "sbx resident-inf|short|$plain"
  check "points: long" "$(pt long)" "sbx resident-inf resident-300|long|$plain"
  check "points: no-infra" "$(pt no-infra)" "sbx resident-inf resident-300|no-infra|$plain"
  check "points: no-chains" "$(pt no-chains)" "sbx resident-inf resident-300|no-chains|$plain"
  check "points: smoke" "$(pt smoke)" "sbx resident-inf resident-300 control|smoke|$plain"
  check "points: mem512" "$(pt mem512)" \
    "sbx resident-inf|default|src/e15/commands/library.json|template-mem512/workspace.img|template-mem512|1024|512|1|read,shell_read,search,test,interpreter,lint_check|cat /workspace/data.bin >/dev/null"
  check "points: unknown point fails" "$(pt nowhere >/dev/null && echo pass || echo refused)" "refused"
  check "points: e15_point_arms mem512" "$(E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; source "$2"; e15_point_arms mem512' _ "$RIG/lib.sh" "$RIG/points.sh")" "sbx resident-inf"
  check "points: setup builds the default and mem512 templates" "$(E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; source "$2"; e15_templates' _ "$RIG/lib.sh" "$RIG/points.sh" | tr '\n' ' ')" "default mem512 "
  # the point signature: distinct per point, stable, and mem512's differs from default's
  sigs=$(for p in default short long no-infra no-chains smoke mem512; do psig "$p"; echo; done | sort -u | grep -c .)
  check "point_sig: seven points, seven signatures" "$sigs" "7"
  check "point_sig: stable" "$(psig mem512)" "$(psig mem512)"
  check "point_sig: 64 hex chars" "$(psig default | grep -cE '^[0-9a-f]{64}$')" "1"
  check "point_sig: default and mem512 share library and corpus, not the signature" \
    "$([ "$(psig default)" != "$(psig mem512)" ] && echo apart || echo same)" "apart"
  check "points: only non-default, non-mem512 points may fall back" "$(for p in default short long no-infra no-chains smoke mem512; do
    E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; source "$2"; e15_point "$3"; printf "%s=%s " "$3" "$E15_P_FALLBACK"' _ "$RIG/lib.sh" "$RIG/points.sh" "$p"; done)" \
    "default=0 short=1 long=1 no-infra=1 no-chains=1 smoke=1 mem512=0 "
  check "rung.sh passes the scan flags to the driver" "$(grep -c 'scan_flag=(--scan-cmd "\$E15_P_SCAN_CMD" --scan-classes "\$E15_P_SCAN_CLASSES")' "$RIG/rung.sh")/$(grep -c '"\${scan_flag\[@\]}"' "$RIG/rung.sh")" "1/1"
  # worker_env follows the point's image size
  wenv() { E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; worker_env sbx "$2" $3; grep "^SH_WORKSPACE_IMAGE_MB=" "$2"' _ "$RIG/lib.sh" "$TMP/wenv" "${1:-}"; }
  check "worker_env: SH_WORKSPACE_IMAGE_MB default 256" "$(wenv)" "SH_WORKSPACE_IMAGE_MB=256"
  check "worker_env: SH_WORKSPACE_IMAGE_MB follows the point (1024)" "$(wenv 1024)" "SH_WORKSPACE_IMAGE_MB=1024"
  # SH_MAX_RUNS: 512 on the preliminary rig; 2048 on fresh-metal (resident-inf holds one unparked run per
  # session, so 512 would refuse a metal resident rung above N=512 before any host resource binds)
  wruns() { E15_HOST_PROFILE="$1" E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; worker_env "$3" "$2"; grep "^SH_MAX_RUNS=" "$2"' _ "$RIG/lib.sh" "$TMP/wenv" "$2"; }
  # fresh-metal ladder, resident warm-up and drift basis (user decision 2026-11-04); aws-prelim unchanged
  lprof() { E15_HOST_PROFILE="$1" E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c "source '$RIG/lib.sh'; $2"; }
  check "profile: aws-prelim ladder unchanged" "$(lprof aws-prelim 'echo ${E15_LADDER[*]}')" "1 8 16 24 32 40 48 56 64 80 96 128"
  check "profile: fresh-metal ladder extended to 1024" "$(lprof fresh-metal 'echo ${E15_LADDER[*]}')" \
    "1 8 16 24 32 40 48 56 64 80 96 128 160 192 256 320 384 448 512 576 640 704 768 896 1024"
  check "profile: E15_LADDER_EXTRA appends rungs on fresh-metal (E16)" \
    "$(E15_LADDER_EXTRA='1280 1536' lprof fresh-metal 'echo ${E15_LADDER[*]: -3}')" "1024 1280 1536"
  check "profile: E15_LADDER_EXTRA ignored on aws-prelim" \
    "$(E15_LADDER_EXTRA='1280 1536' lprof aws-prelim 'echo ${E15_LADDER[*]: -1}')" "128"
  check "profile: default warm-up aws-prelim 600 for every arm" "$(lprof aws-prelim 'for a in sbx resident-inf resident-300 control; do e15_default_warmup $a; done | tr "\n" " "')" "600 600 600 600 "
  check "profile: default warm-up fresh-metal 1200 for sbx and resident arms, 600 for control" "$(lprof fresh-metal 'for a in sbx resident-inf resident-300 control; do e15_default_warmup $a; done | tr "\n" " "')" "1200 1200 1200 600 "
  check "profile: drift basis aws-prelim median, fresh-metal sum" "$(lprof aws-prelim 'echo $E15_DRIFT_BASIS') $(lprof fresh-metal 'echo $E15_DRIFT_BASIS')" "median sum"
  check "rung.sh: warm-up default from e15_default_warmup" "$(grep -c 'WARMUP=\${E15_WARMUP_S:-\$(e15_default_warmup "\$ARM")}' "$RIG/rung.sh")" "1"
  check "ladder.sh: warm-up default from e15_default_warmup" "$(grep -c 'WARMUP=\${E15_WARMUP_S:-\$(e15_default_warmup "\$ARM")}' "$RIG/ladder.sh")" "1"
  check "rung.sh writes drift_basis into params" "$(grep -c '"drift_basis": "\$E15_DRIFT_BASIS"' "$RIG/rung.sh")" "1"
  check "worker_env: SH_MAX_RUNS 512 on aws-prelim (sbx, resident-inf)" "$(wruns aws-prelim sbx) $(wruns aws-prelim resident-inf)" "SH_MAX_RUNS=512 SH_MAX_RUNS=512"
  check "worker_env: SH_MAX_RUNS 2048 on fresh-metal (sbx, resident-inf, resident-300)" "$(wruns fresh-metal sbx) $(wruns fresh-metal resident-inf) $(wruns fresh-metal resident-300)" "SH_MAX_RUNS=2048 SH_MAX_RUNS=2048 SH_MAX_RUNS=2048"
  check "setup.sh records the fresh-metal SH_MAX_RUNS in the manifest" "$(grep -c 'm_note "worker SH_MAX_RUNS=' "$RIG/setup.sh")" "1"
  # E16: per-run admission overrides E15_MAX_COMMITTED_MB / E15_MAX_RUNS, fresh-metal only
  wadm() { # PROFILE COMMITTED RUNS ARM ("" leaves a variable unset)
    env -u E15_MAX_COMMITTED_MB -u E15_MAX_RUNS ${2:+E15_MAX_COMMITTED_MB=$2} ${3:+E15_MAX_RUNS=$3} \
      E15_HOST_PROFILE="$1" E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; worker_env "$3" "$2"; grep -E "^SH_MAX_(COMMITTED_MB|RUNS)=" "$2" | sort | tr "\n" " "' _ "$RIG/lib.sh" "$TMP/wenv" "${4:-resident-inf}" 2>&1
  }
  check "E16: fresh-metal honours E15_MAX_COMMITTED_MB and E15_MAX_RUNS" "$(wadm fresh-metal 4194304 4096)" "SH_MAX_COMMITTED_MB=4194304 SH_MAX_RUNS=4096 "
  check "E16: fresh-metal overrides reach the sbx worker too" "$(wadm fresh-metal 4194304 4096 sbx)" "SH_MAX_COMMITTED_MB=4194304 SH_MAX_RUNS=4096 "
  check "E16: fresh-metal, both unset -> E15 metal values" "$(wadm fresh-metal "" "")" "SH_MAX_COMMITTED_MB=1048576 SH_MAX_RUNS=2048 "
  check "E16: aws-prelim ignores both overrides (sealed values)" "$(wadm aws-prelim 4194304 4096)" "SH_MAX_COMMITTED_MB=1048576 SH_MAX_RUNS=512 "
  check "E16: aws-prelim, both unset -> sealed values" "$(wadm aws-prelim "" "")" "SH_MAX_COMMITTED_MB=1048576 SH_MAX_RUNS=512 "
  check "E16: fresh-metal refuses a non-integer override (exit 3)" \
    "$(E15_MAX_RUNS=lots E15_HOST_PROFILE=fresh-metal E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"' _ "$RIG/lib.sh" >/dev/null 2>&1; echo $?)/$(E15_MAX_COMMITTED_MB=0 E15_HOST_PROFILE=fresh-metal E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"' _ "$RIG/lib.sh" >/dev/null 2>&1; echo $?)" "3/3"
  check "E16: fresh-metal refuses leading zeros (00, 0100) (exit 3)" \
    "$(E15_MAX_RUNS=00 E15_HOST_PROFILE=fresh-metal E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"' _ "$RIG/lib.sh" >/dev/null 2>&1; echo $?)/$(E15_MAX_COMMITTED_MB=0100 E15_HOST_PROFILE=fresh-metal E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"' _ "$RIG/lib.sh" >/dev/null 2>&1; echo $?)" "3/3"
  check "E16: fresh-metal accepts 1 and 4096" "$(wadm fresh-metal 1 4096)" "SH_MAX_COMMITTED_MB=1 SH_MAX_RUNS=4096 "
  check "setup.sh records the fresh-metal SH_MAX_COMMITTED_MB in the manifest" "$(grep -c 'm_note "worker SH_MAX_RUNS=$E15_MAX_RUNS SH_MAX_COMMITTED_MB=$E15_MAX_COMMITTED_MB' "$RIG/setup.sh")" "1"
  # E16: point lowduty (the (1%, 2%] duty band of the default corpus)
  check "points: lowduty" "$(pt lowduty)" "sbx resident-inf control|lowduty|$plain"
  check "points: e15_point_arms lowduty" "$(E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; source "$2"; e15_point_arms lowduty' _ "$RIG/lib.sh" "$RIG/points.sh")" "sbx resident-inf control"
  check "point_sig: lowduty differs from default" "$([ -n "$(psig lowduty)" ] && [ "$(psig default)" != "$(psig lowduty)" ] && echo apart || echo same)" "apart"
  check "points: lowduty does not fall back to default's baseline" "$(E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; source "$2"; e15_point lowduty; echo "$E15_P_FALLBACK"' _ "$RIG/lib.sh" "$RIG/points.sh")" "0"
  check "setup.sh: lowduty corpus checked against its report and recorded as an artifact (fresh-metal)" \
    "$(grep -c 'e15_artifact corpus-lowduty "\$ldsha" "\$ld/corpus.jsonl"' "$RIG/setup.sh")/$(grep -c '\[ "\$ldsha" = "\$ldwant" \] || die' "$RIG/setup.sh")/$(grep -B4 'ld=\$E15_CORPORA/lowduty' "$RIG/setup.sh" | grep -c '^if \[ "\$METAL" = 1 \]; then$')" "1/1/1"
  check "points: lowduty builds no template of its own" "$(E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; source "$2"; e15_templates' _ "$RIG/lib.sh" "$RIG/points.sh" | grep -c lowduty)" "0"
  check "rung.sh starts the worker with the point's image size" "$(grep -c 'start_worker "\$ARM" "\$DIR" "\$E15_P_IMAGE_MB"' "$RIG/rung.sh")" "1"
  check "rung.sh copies the point's template, not E15_TEMPLATE" "$(grep -c 'E15_TEMPLATE' "$RIG/rung.sh")/$(grep -c '"\$TEMPLATE" "\$RUN_ID"' "$RIG/rung.sh")" "0/1"
fi

# rung.sh at mem512: the default point's baseline is never accepted (same library and corpus hashes;
# the point signature keeps them apart)
if [ -f "$RIG/rung.sh" ] && [ -f "$RIG/points.sh" ]; then
  printf '#!/usr/bin/env bash\n[ "$1" = is-active ] && exit 0\nexit 0\n' >"$STUB/systemctl"
  rm -rf "$TROOT/runs"
  GOOD='class_medians={} global_median_ms=1 excess_p95_ms=2 n1_median_pace=0.1'
  # shellcheck disable=SC2086
  STUB_POINT=default stub_rec "$TROOT/runs/default/sbx/N1/baseline.json" baseline_p95_ms 42.5 $GOOD
  check "mem512 control: the default baseline is valid for default" "$(base_at default | cut -d'|' -f2)" "$TROOT/runs/default/sbx/N1/baseline.json"
  base_at mem512 >/dev/null
  check "mem512: no own baseline -> the default point's is not taken (rung dies)" "$?" "1"
  check "mem512: the death says run baseline.sh mem512" "$(grep -c 'run baseline.sh mem512 sbx' "$TMP/base.err")" "1"
  # default's baseline copied into mem512/N1: library, driver and corpus all match; point_sig does not
  mkdir -p "$TROOT/runs/mem512/sbx/N1"
  cp "$TROOT/runs/default/sbx/N1/baseline.json" "$TROOT/runs/mem512/sbx/N1/baseline.json"
  base_at mem512 >/dev/null
  check "mem512: default's baseline in mem512/N1 (same lib+corpus) -> stale, dies" "$?" "1"
  check "mem512: the stale reason is point_sig" "$(grep -c 'stale N=1 baseline .*point_sig' "$TMP/base.err")" "1"
  # and the reverse: mem512's baseline is never accepted at default
  # shellcheck disable=SC2086
  STUB_POINT=mem512 stub_rec "$TROOT/runs/mem512/sbx/N1/baseline.json" baseline_p95_ms 9 $GOOD
  check "mem512: its own baseline is accepted" "$(base_at mem512 | cut -d'|' -f2)" "$TROOT/runs/mem512/sbx/N1/baseline.json"
  cp "$TROOT/runs/mem512/sbx/N1/baseline.json" "$TROOT/runs/default/sbx/N1/baseline.json"
  base_at default >/dev/null
  check "default: mem512's baseline in default/N1 -> stale on point_sig" "$?/$(grep -c 'stale N=1 baseline .*point_sig' "$TMP/base.err")" "1/1"
  # a baseline without point_sig (pre-fix) is stale
  STUB_POINT=default stub_rec "$TROOT/runs/default/sbx/N1/baseline.json" baseline_p95_ms 1 point_sig=None class_medians={} global_median_ms=1 excess_p95_ms=2
  base_at default >/dev/null
  check "a baseline with no point_sig is stale" "$?" "1"
  : >"$CALLS"
  E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" PATH="$SPATH" E15_MANIFEST="$TMP/m.md" bash "$RIG/rung.sh" resident-300 8 mem512 >"$TMP/r.out" 2>&1
  check "rung.sh: mem512 does not run resident-300 (exit 2)" "$?/$(grep -c 'does not run ARM resident-300' "$TMP/r.out")" "2/1"
  rm -rf "$TROOT/runs"
  printf '#!/usr/bin/env bash\necho "systemctl $*" >>"%s"\n' "$CALLS" >"$STUB/systemctl"
fi

# classprobe.sh mem512: the default corpus and library; the rung runs at mem512 (scan flags, template)
if [ -f "$RIG/classprobe.sh" ] && [ -f "$RIG/points.sh" ]; then
  printf '%s\n' '{"session":"s","user":"u","provider":"claude","calls":[{"i":0,"class":"read","work_ms":5,"dur_ms":50,"chain":false}]}' >"$TROOT/corpora/default/corpus.jsonl"
  printf '%s\n' '{"version":1,"classes":{"read":[{"id":"r","cmd":"x","exit":0,"nominal_ms":30,"run_ms":3}],"test":[{"id":"t","cmd":"y","exit":0,"nominal_ms":900,"run_ms":null}]},"standin":{}}' >"$TROOT/src/e15/commands/library.json"
  : >"$TMP/pcalls"
  env E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" E15_RUNG="$PRUNG" P_SHORT=none P_CALLS="$TMP/pcalls" PATH="$SPATH" E15_MANIFEST="$TMP/m.md" bash "$RIG/classprobe.sh" mem512 sbx >"$TMP/p.out" 2>"$TMP/p.err"
  check "classprobe.sh mem512 exits 0" "$?" "0"
  check "classprobe.sh mem512: library classes + stand-ins, rung at mem512" "$(cut -d' ' -f1-4 "$TMP/pcalls" | tr '\n' '|')" "sbx 1 mem512 tag=probe-build|sbx 1 mem512 tag=probe-host_infra|sbx 1 mem512 tag=probe-opaque|sbx 1 mem512 tag=probe-read|sbx 1 mem512 tag=probe-test|"
  check "classprobe.sh mem512: read drawn from the default corpus (work 5)" "$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["calls"][0]["work_ms"])' "$TROOT/runs/mem512/sbx/probe-corpora/read/corpus.jsonl")" "5"
fi

# sample.sh: disk_read_mbs and disk_await_ms from a fixture /proc/diskstats
if [ -f "$RIG/sample.sh" ]; then
  FP="$TMP/fproc"
  mkdir -p "$FP/pressure"
  printf 'MemTotal: 1 kB\nMemAvailable: 100 kB\nCached: 5 kB\n' >"$FP/meminfo"
  printf 'cpu  1 0 1 10 0 0 0 0 0 0\n' >"$FP/stat"
  mkdir -p "$FP/101" "$FP/202" "$FP/303"
  # fields: major minor name reads_done reads_merged sectors_read ms_reading writes_done ...
  ds() { printf '   8       0 sda 0 0 0 0 0 0 0 0 0 0 0\n 259       0 nvme0n1 %s 0 %s %s %s 0 0 %s 0 0 0\n' "$1" "$2" "$3" "$4" "$5" >"$FP/diskstats"; }
  ds 100 0 0 0 0
  OUTS="$TMP/samples.jsonl"
  rm -f "$OUTS"
  ( E15_PROC="$FP" E15_DISK_DEV=nvme0n1 E15_SLICE_DIR="$TMP/nocg" E15_STATS_URL=http://127.0.0.1:1/x \
    bash "$RIG/sample.sh" "$OUTS" "$(date +%s)" 30 ) &
  spid=$!
  for _ in $(seq 50); do [ -s "$OUTS" ] && break; sleep 0.1; done
  # +200 MB worth of sectors (390625 x 512 B), 10 more I/Os (1 read + 9 writes) taking 50 ms in all
  ds 101 390625 20 9 30
  for _ in $(seq 40); do [ "$(grep -c . "$OUTS" 2>/dev/null)" -ge 2 ] && break; sleep 0.1; done
  kill "$spid" 2>/dev/null
  wait "$spid" 2>/dev/null
  check "sample.sh: first sample has no disk_read_mbs" "$(head -1 "$OUTS" | grep -c disk_read_mbs)" "0"
  check "sample.sh: disk_read_mbs = 200 MB / the two samples' ts delta" \
    "$(python3 -c 'import json,sys; a,b=[json.loads(l) for l in open(sys.argv[1]).readlines()[:2]]; w=200/(b["ts"]-a["ts"]); print("ok" if abs(b["disk_read_mbs"]-w) < 0.01*w else (b["disk_read_mbs"], w))' "$OUTS")" "ok"
  check "sample.sh: procs counted from E15_PROC (3 fixture pids)" "$(head -1 "$OUTS" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["procs"])')" "3"
  check "sample.sh: disk_await_ms = 50 ms / 10 I/Os" "$(sed -n 2p "$OUTS" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["disk_await_ms"])')" "5.0"
  rm -f "$OUTS"
  E15_PROC="$FP" E15_DISK_DEV=nosuch E15_SLICE_DIR="$TMP/nocg" E15_STATS_URL=http://127.0.0.1:1/x \
    bash "$RIG/sample.sh" "$OUTS" "$(date +%s)" 2.5 >/dev/null 2>&1
  check "sample.sh: an unknown device gives samples, no disk_read_mbs" "$([ "$(grep -c . "$OUTS")" -ge 2 ] && echo n)/$(grep -c disk_read_mbs "$OUTS")" "n/0"
  # memory_high binding: e15.slice memory.events high/max/oom_kill in every sample (record.py deltas)
  check "sample.sh: no memory.events -> no e15_mem_events" "$(grep -c e15_mem_events "$OUTS")" "0"
  mkdir -p "$TMP/fcg"
  printf 'low 0\nhigh 42\nmax 3\noom 1\noom_kill 1\noom_group_kill 0\n' >"$TMP/fcg/memory.events"
  rm -f "$OUTS"
  E15_PROC="$FP" E15_DISK_DEV=nosuch E15_SLICE_DIR="$TMP/fcg" E15_STATS_URL=http://127.0.0.1:1/x \
    bash "$RIG/sample.sh" "$OUTS" "$(date +%s)" 1.5 >/dev/null 2>&1
  check "sample.sh: e15_mem_events = e15.slice memory.events high, max, oom_kill" \
    "$(head -1 "$OUTS" | python3 -c 'import json,sys; print(json.dumps(json.loads(sys.stdin.read())["e15_mem_events"], sort_keys=True))')" '{"high": 42, "max": 3, "oom_kill": 1}'
fi

# setup.sh: the volume's read throughput, measured once (dd direct I/O), kept in state
if [ -f "$RIG/lib.sh" ]; then
  ddout='2147483648 bytes (2.1 GB, 2.0 GiB) copied, 10.7374 s, 200 MB/s'
  check "dd_mbs: bytes / seconds in MB/s" "$(printf '%s\n' "$ddout" | bash -c 'source "$1"; dd_mbs' _ "$RIG/lib.sh")" "200.0"
  check "dd_mbs: GNU 'seconds' spelling" "$(printf '1000000 bytes (1 MB) copied, 0.5 seconds, 2 MB/s\n' | bash -c 'source "$1"; dd_mbs' _ "$RIG/lib.sh")" "2.0"
  check "dd_mbs: no summary -> fails" "$(echo junk | bash -c 'source "$1"; dd_mbs' _ "$RIG/lib.sh" >/dev/null 2>&1 && echo pass || echo fail)" "fail"
  # measure_disk_read with a stub dd: writes with oflag=direct, reads with iflag=direct, removes the file
  DDS="$TMP/ddstub"
  mkdir -p "$DDS"
  printf '#!/usr/bin/env bash\necho "dd $*" >>"%s"\ncase "$*" in *iflag=direct*) echo "%s" >&2 ;; *of=*) for a; do case "$a" in of=*) : >"${a#of=}" ;; esac; done ;; esac\n' "$TMP/dd.calls" "$ddout" >"$DDS/dd"
  chmod +x "$DDS/dd"
  : >"$TMP/dd.calls"
  got=$(PATH="$DDS:$PATH" bash -c 'source "$1"; measure_disk_read "$2" 2048' _ "$RIG/lib.sh" "$TMP/probe.bin")
  check "measure_disk_read: MB/s from the direct read" "$got" "200.0"
  check "measure_disk_read: write 512 x 4M direct, then read direct" "$(grep -c 'bs=4M count=512 oflag=direct' "$TMP/dd.calls")/$(grep -c 'bs=4M iflag=direct' "$TMP/dd.calls")" "1/1"
  check "measure_disk_read: the probe file is removed" "$([ -e "$TMP/probe.bin" ] && echo left || echo removed)" "removed"
  check "setup.sh measures once into state/disk_read_max_mbs" "$(grep -c 'if \[ ! -s "\$E15_STATE/disk_read_max_mbs" \]' "$RIG/setup.sh")/$(grep -c 'measure_disk_read "\$E15_STATE/.disk-read-probe" 2048' "$RIG/setup.sh")" "1/1"
  check "rung.sh puts disk_read_max_mbs into params" "$(grep -c '"disk_read_max_mbs": ' "$RIG/rung.sh")" "1"
fi

# setup.sh keeps the cycle's first PRESTATE (a setup while E15 is up must not record E15's own stops)
if [ -f "$RIG/setup.sh" ]; then
  check "setup.sh records PRESTATE through m_prestate only" "$(grep -c 'm_prestate "\$E15_HOST_WORKER=' "$RIG/setup.sh")/$(grep -c 'm_note "PRESTATE' "$RIG/setup.sh")" "1/0"
  mp() { E15_MANIFEST="$1" bash -c 'source "$1"; m_prestate "$2"' _ "$RIG/lib.sh" "$2"; }
  M6="$TMP/m6.md"
  printf -- '# m\n\n## Setup 1\n' >"$M6"
  mp "$M6" "microvm-worker.service=active bench-cp=true bench-redis=true"
  printf -- '\n## Setup 2\n' >>"$M6"
  mp "$M6" "microvm-worker.service=inactive bench-cp=false bench-redis=false"
  check "m_prestate: first setup of a cycle writes PRESTATE" "$(grep -c ' PRESTATE: microvm-worker.service=active' "$M6")" "1"
  check "m_prestate: a second setup in the cycle writes no PRESTATE" "$(grep -c ' PRESTATE: ' "$M6")" "1"
  check "m_prestate: the second setup notes what it saw" "$(grep -c 'PRESTATE kept: .*microvm-worker.service=inactive' "$M6")" "1"
  # teardown then verifies against the first setup's state (worker was active, is active again)
  printf '#!/usr/bin/env bash\n[ "$1" = is-active ] && [ "$3" = microvm-worker.service ] && exit 0\nexit 1\n' >"$STUB/systemctl"
  printf '#!/usr/bin/env bash\ncase "$*" in *"docker inspect"*) echo true; exit 0 ;; esac\nexit 1\n' >"$STUB/sudo"
  PATH="$SPATH" E15_MANIFEST="$M6" bash "$RIG/teardown.sh" >"$TMP/t6.out" 2>&1
  check "teardown after two setups verifies against the first PRESTATE (exit 0)" "$?" "0"
  # the next cycle (after that Teardown) records its own PRESTATE again
  printf -- '\n## Setup 3\n' >>"$M6"
  mp "$M6" "microvm-worker.service=inactive bench-cp=true bench-redis=true"
  check "m_prestate: a new cycle after teardown writes PRESTATE again" "$(grep -c ' PRESTATE: ' "$M6")" "2"
  printf '#!/usr/bin/env bash\necho "systemctl $*" >>"%s"\n' "$CALLS" >"$STUB/systemctl"
  printf '#!/usr/bin/env bash\necho "sudo $*" >>"%s"\n' "$CALLS" >"$STUB/sudo"
fi

# kill_vm_cgroups: on cgroupfs every file reports size 0, so `[ -s cgroup.procs ]` is always false
# and a populated pool was never killed (Task 8: 27 Firecracker VMs left after an OOM-killed worker).
# Behaviour (regular files stand in for cgroupfs): a populated pool gets cgroup.kill, an empty pool
# does not, the worker's service cgroup is never touched. The cgroupfs property itself (size 0) is
# pinned by the second check: the populated test reads the file's content.
kv_root="$TMP/kvcg"
rm -rf "$kv_root"
mkdir -p "$kv_root/pool-a" "$kv_root/pool-b" "$kv_root/e15-worker.service"
for d in pool-a pool-b e15-worker.service; do : >"$kv_root/$d/cgroup.kill"; : >"$kv_root/$d/cgroup.procs"; done
echo 4242 >"$kv_root/pool-a/cgroup.procs"
echo 4243 >"$kv_root/e15-worker.service/cgroup.procs"
kv_out=$(env PATH="$SPATH" bash -c '
  sudo() { [ "$1" = -n ] && shift; "$@"; }
  export -f sudo
  E15_VMCG=$1
  eval "$(sed -n "/^kill_vm_cgroups() {/,/^}/p" "$2")"
  kill_vm_cgroups
  printf "a=%s b=%s svc=%s\n" "$(cat "$1/pool-a/cgroup.kill")" "$(cat "$1/pool-b/cgroup.kill")" "$(cat "$1/e15-worker.service/cgroup.kill")"
' _ "$kv_root" "$RIG/lib.sh" 2>&1)
check "kill_vm_cgroups kills a populated pool only, never the worker's service cgroup" "$kv_out" "a=1 b= svc="
check "kill_vm_cgroups tests cgroup.procs by content, not size (cgroupfs reports size 0)" \
  "$(sed -n '/^kill_vm_cgroups() {/,/^}/p' "$RIG/lib.sh" | grep -c -- '-n "\$(cat "\$d/cgroup.procs"')/$(sed -n '/^kill_vm_cgroups() {/,/^}/p' "$RIG/lib.sh" | grep -c -- '-s "\$d/cgroup.procs"')" "1/0"

# --- memory guards (Task 8 mem512 OOM incident, user decision a+b) ---------------------------
# (a) e15.slice limits: MemoryMax = MemTotal - 3 GiB, MemoryHigh = MemoryMax - 1 GiB
check "e15_slice_limits: 16082476 kB host -> MemoryMax MemTotal-3GiB, MemoryHigh 1 GiB below" \
  "$(bash -c '. "$1" >/dev/null 2>&1; e15_slice_limits 16082476' _ "$RIG/lib.sh")" \
  "$(((16082476 / 1024 - 3072) * 1048576)) $(((16082476 / 1024 - 4096) * 1048576))"
check "setup.sh writes MemoryHigh into e15.slice and reads MemTotal through E15_MEMINFO" \
  "$(grep -c 'MemoryMax=%s\\nMemoryHigh=%s' "$RIG/setup.sh")/$(grep -c 'e15_slice_limits "$mem_kb"' "$RIG/setup.sh")/$(grep -c "'/^MemTotal:/{print \$2}' \"\$E15_MEMINFO\"" "$RIG/setup.sh")" "1/1/1"
check "setup.sh records MemoryMax and MemoryHigh in the manifest" "$(grep -c 'm_note "e15.slice MemoryMax=$slice_max MemoryHigh=$slice_high' "$RIG/setup.sh")" "1"
# (b) the watchdog, against a fake meminfo: trips after 3 consecutive samples below the floor,
# writes the marker and kills the E15 VMs; never trips when MemAvailable recovers in between
wd_mem="$TMP/wd-meminfo"
wd_run() { # SEQ (MemAvailable kB per sample) FLOOR_MIB -> "<marker word> <kill_vm_cgroups calls>"
  # Each sample reads the real E15_MEMINFO path; the stubbed sleep rewrites that file with the next
  # value, so the watchdog sees the sequence through the same file read it uses on the rig.
  rm -f "$TMP/wd-marker" "$TMP/wd-kills"
  tr ' ' '\n' <<<"$1" >"$TMP/wd-seq"
  printf 'MemAvailable: %s kB\n' "$(head -1 "$TMP/wd-seq")" >"$wd_mem"
  env E15_MEMINFO="$wd_mem" E15_MEMAVAIL_FLOOR_MIB="$2" PATH="$SPATH" bash -c '
    . "$1" >/dev/null 2>&1
    wd_seq=$2 wd_kills=$3 n=1
    sleep() {
      n=$((n + 1))
      v=$(sed -n "${n}p" "$wd_seq")
      [ -n "$v" ] || exit 0          # sequence exhausted without a trip
      printf "MemAvailable: %s kB\n" "$v" >"$E15_MEMINFO"
    }
    kill_vm_cgroups() { echo kill >>"$wd_kills"; }
    memavail_watchdog "$4"
  ' _ "$RIG/lib.sh" "$TMP/wd-seq" "$TMP/wd-kills" "$TMP/wd-marker" >/dev/null 2>&1
  printf '%s %s\n' "$(cut -d' ' -f1 "$TMP/wd-marker" 2>/dev/null || echo none)" "$(grep -c kill "$TMP/wd-kills" 2>/dev/null || echo 0)"
}
check "memavail_watchdog trips on 3 consecutive samples below the floor and kills the VMs" \
  "$(wd_run '2000000 900000 800000 700000' 1024)" "memory_floor 1"
check "memavail_watchdog does not trip when MemAvailable recovers between low samples" \
  "$(wd_run '900000 900000 2000000 900000 900000 2000000' 1024)" "none 0"
check "memavail_watchdog honours E15_MEMAVAIL_FLOOR_MIB" \
  "$(wd_run '1500000 1500000 1500000' 2048)/$(wd_run '1500000 1500000 1500000' 1024)" "memory_floor 1/none 0"
printf 'MemTotal:       16082476 kB\nMemFree:          100000 kB\nMemAvailable:     733400 kB\n' >"$wd_mem"
check "memavail_kb reads MemAvailable from E15_MEMINFO (the fake path)" \
  "$(env E15_MEMINFO="$wd_mem" bash -c '. "$1" >/dev/null 2>&1; memavail_kb' _ "$RIG/lib.sh")" "733400"
check "rung.sh runs the watchdog beside the driver and kills it on a trip" \
  "$(grep -c '(memavail_watchdog "$memabort_marker" && kill "$driver_pid"' "$RIG/rung.sh")/$(grep -c 'kill "$watchdog_pid"' "$RIG/rung.sh")" "1/2"
check "rung.sh records memory_abort in params.json" "$(grep -c '"memory_abort": json.loads' "$RIG/rung.sh")" "1"

# (2) a retry-only teardown verifies against the last PRESTATE anywhere in the manifest
if [ -f "$RIG/teardown.sh" ]; then
  printf '#!/usr/bin/env bash\n[ "$1" = is-active ] && [ "$3" = microvm-worker.service ] && exit 1\nexit 1\n' >"$STUB/systemctl"
  printf '#!/usr/bin/env bash\ncase "$*" in *"docker inspect"*) echo true; exit 0 ;; esac\nexit 1\n' >"$STUB/sudo"
  M5="$TMP/m5.md"
  printf -- '## Setup 1\n- t PRESTATE: microvm-worker.service=active bench-cp=true bench-redis=true\n## Teardown 1\n## Setup 2\n- t PRESTATE: microvm-worker.service=inactive bench-cp=true bench-redis=true\n## Teardown 2\n## Retry 2\n- t retry | UNDO: true\n' >"$M5"
  PATH="$SPATH" E15_MANIFEST="$M5" bash "$RIG/teardown.sh" >"$TMP/t5.out" 2>&1
  check "retry-only teardown uses the last PRESTATE (worker was inactive)" "$?" "0"
  check "retry-only teardown names that PRESTATE" "$(grep -c 'microvm-worker.service=inactive' "$M5")" "2"
  printf '#!/usr/bin/env bash\necho "systemctl $*" >>"%s"\n' "$CALLS" >"$STUB/systemctl"
  printf '#!/usr/bin/env bash\necho "sudo $*" >>"%s"\n' "$CALLS" >"$STUB/sudo"
fi

# --- fresh-metal host profile (SPEC §13) ------------------------------------------------------

for s in pins.sh bootstrap.sh; do
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
  fi
done

# Profile selection: aws-prelim is the default and keeps its paths, guards and measurement.
prof() { E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; eval "$2"' _ "$RIG/lib.sh" "$1" 2>&1; }
rm -rf "$TROOT/state"
check "profile: default is aws-prelim" "$(prof 'echo $E15_HOST_PROFILE')" "aws-prelim"
check "profile: aws-prelim Firecracker in /usr/local/bin, base snapshot, Redis by tag" \
  "$(prof 'echo $E15_FIRECRACKER $E15_JAILER $E15_BASE_SNAPSHOT $E15_REDIS_IMAGE')" \
  "/usr/local/bin/firecracker /usr/local/bin/jailer /srv/snapshots/default docker.io/library/redis:7-alpine"
check "profile: aws-prelim relay node and PATH unchanged" "$(prof 'e15_node; e15_path' | tr '\n' ' ')" "/usr/bin/node /usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin "
check "profile: aws-prelim goenv has no PATH" "$(prof 'e15_goenv user | grep -c ^PATH=')" "0"
check "profile: aws-prelim podman is plain sudo podman" "$(prof 'e15_podman_str')" "sudo -n podman"
check "profile: fresh-metal Firecracker, jailer from /srv/e15/bin; no base snapshot; Redis by digest" \
  "$(E15_HOST_PROFILE=fresh-metal prof 'echo ${E15_FIRECRACKER#$E15_ROOT/} ${E15_JAILER#$E15_ROOT/} base=$E15_BASE_SNAPSHOT ${E15_REDIS_IMAGE%%@*}')" \
  "bin/firecracker bin/jailer base= docker.io/library/redis"
check "profile: fresh-metal node, PATH and goenv are bootstrap.sh's" \
  "$(E15_HOST_PROFILE=fresh-metal prof 'e15_node | sed "s#^$E15_ROOT/##"; e15_path | cut -d: -f1-3 | sed "s#$E15_ROOT/##g"; e15_goenv user | grep -c "^PATH=$E15_ROOT/bin:"' | tr '\n' ' ')" \
  "node/bin/node bin:go-toolchain/bin:node/bin 1 "
check "profile: fresh-metal keeps npm/corepack/XDG caches under the root" \
  "$(E15_HOST_PROFILE=fresh-metal prof 'e15_userenv user | grep -E "^(npm_config_cache|COREPACK_HOME|XDG_CACHE_HOME)=" | grep -c "=$E15_ROOT/"')" "3"
check "profile: fresh-metal podman uses storage under the root" \
  "$(E15_HOST_PROFILE=fresh-metal prof 'e15_podman_str; e15_podman_conf_body | grep -c "root = \"$E15_ROOT/containers/"' | tr '\n' ' ')" \
  "sudo -n env CONTAINERS_STORAGE_CONF=$TROOT/containers/storage.conf podman 2 "
check "profile: an unknown profile is refused (exit 3)" "$(E15_HOST_PROFILE=bogus prof 'echo x' >/dev/null; echo $?)" "3"
mkdir -p "$TROOT/state" && echo fresh-metal >"$TROOT/state/host_profile"
check "profile: the recorded profile is the default" "$(prof 'echo $E15_HOST_PROFILE')" "fresh-metal"
check "profile: a different explicit profile than the recorded one is refused" \
  "$(E15_HOST_PROFILE=aws-prelim prof 'echo x' >/dev/null; echo $?)" "3"
rm -f "$TROOT/state/host_profile"

# fresh-metal guards: no shared-host rules; nothing outside the root but the manifest
mguard() { (E15_HOST_PROFILE=fresh-metal E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" PATH="$SPATH" E15_MANIFEST="$TMP/m.md" bash -c "source '$RIG/lib.sh'; $1" >"$TMP/g.out" 2>&1) && echo pass || echo refused; }
check "fresh-metal: a path under the root passes" "$(mguard "refuse_shared_paths '$TROOT/x' '$TROOT/workspaces'")" "pass"
check "fresh-metal: the manifest passes" "$(mguard "refuse_shared_paths '$TMP/m.md'")" "pass"
check "fresh-metal: /usr/local/bin is refused" "$(mguard 'refuse_shared_paths /usr/local/bin/firecracker')" "refused"
check "fresh-metal: dot-dot out of the root is refused" "$(mguard "refuse_shared_paths '$TROOT/../elsewhere'")" "refused"
mkdir -p "$TROOT/sub" && ln -sfn /etc "$TROOT/sub/out"
check "fresh-metal: a symlink out of the root is refused" "$(mguard "refuse_shared_paths '$TROOT/sub/out'")" "refused"
rm -f "$TROOT/sub/out"
check "fresh-metal: sctl on an E15 unit passes" "$(mguard 'sctl stop e15-worker.service')" "pass"
check "fresh-metal: sctl daemon-reload passes" "$(mguard 'sctl daemon-reload')" "pass"
check "fresh-metal: sctl on a host unit is refused" "$(mguard 'sctl stop ssh.service')" "refused"
check "fresh-metal: sctl on microvm-worker (not E15's) is refused" "$(mguard 'sctl stop microvm-worker.service')" "refused"
check "aws-prelim: sctl on microvm-worker still passes" "$(guard 'sctl stop microvm-worker.service')" "pass"

# Ubuntu path selection: package manager from os-release, unit dir, no /etc/serverless-harness
printf 'ID=ubuntu\nVERSION_ID="24.04"\n' >"$TMP/os-ubuntu"
printf 'ID="amzn"\nVERSION_ID="2023"\n' >"$TMP/os-amzn"
osq() { E15_OS_RELEASE="$1" E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; e15_os_id; e15_pkg_mgr; e15_pkg_remove_cmd podman' _ "$RIG/lib.sh" | tr '\n' '|'; }
check "ubuntu: apt (purge: conffiles too)" "$(osq "$TMP/os-ubuntu")" "ubuntu|apt|sudo -n env DEBIAN_FRONTEND=noninteractive apt-get purge -y podman|"
check "al2023: dnf" "$(osq "$TMP/os-amzn")" "amzn|dnf|sudo -n dnf remove -y podman|"
check "unit files go to /etc/systemd/system on both" "$(prof 'echo $E15_UNIT_DIR')/$(E15_HOST_PROFILE=fresh-metal prof 'echo $E15_UNIT_DIR')" "/etc/systemd/system//etc/systemd/system"
check "no rig script writes /etc/serverless-harness" "$(cat "$RIG"/*.sh | grep -v '^ *#' | grep -c '/etc/serverless-harness')" "0"
check "setup.sh writes its unit files to \$E15_UNIT_DIR" "$(grep -c 'f=\$E15_UNIT_DIR/\$unit' "$RIG/setup.sh")" "1"
check "pins.sh: no pin is empty" "$(E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; for n in "${E15_PINS[@]}"; do [ -n "${!n}" ] || echo "$n"; done' _ "$RIG/lib.sh" | grep -c .)" "0"
check "pins.sh: every sha256 pin is 64 hex" "$(grep -E '^E15_[A-Z_]*SHA256=' "$RIG/pins.sh" | grep -cvE '=[0-9a-f]{64}$')" "0"
check "pins.sh: the sandbox image is pinned by digest" "$(E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; echo "$E15_SANDBOX_IMAGE"' _ "$RIG/lib.sh" | grep -cE '^ghcr.io/rossoctl/moca-remote-worker@sha256:[0-9a-f]{64}$')" "1"

# bootstrap.sh: stubbed downloads, idempotent, refuses empty pins
if [ -f "$RIG/bootstrap.sh" ]; then
  BR="$TMP/e15-rig-test.boot"
  BS="$TMP/bstub"
  FIX="$TMP/bfix"
  rm -rf "$BR" "$BS" "$FIX"
  mkdir -p "$BR/src/e15" "$BS" "$FIX"
  cp -R "$RIG" "$BR/src/e15/rig"
  # Fixture tarballs, laid out like the real ones; each fake binary prints its version.
  mk() { mkdir -p "$FIX/$1/$2" && printf '#!/bin/sh\n%s\n' "$4" >"$FIX/$1/$2/$3" && chmod +x "$FIX/$1/$2/$3"; }
  mk go go/bin go 'echo "go version go1.26.0 linux/amd64"'
  mk node node-v22/bin node 'echo v22.23.4'
  mk node node-v22/bin corepack 'case "$1" in enable) shift; [ "$1" = --install-directory ] && printf "#!/bin/sh\necho 9.15.9\n" >"$2/pnpm" && chmod +x "$2/pnpm" ;; esac; echo "corepack $*" >>"$CP_LOG"'
  mk fc release-v1.17.0-x86_64 firecracker-v1.17.0-x86_64 'echo "Firecracker v1.17.0"'
  mk fc release-v1.17.0-x86_64 jailer-v1.17.0-x86_64 'echo "Jailer v1.17.0"'
  mk grpcurl . grpcurl 'echo "grpcurl 1.9.4"'
  tar -czf "$FIX/go.tgz" -C "$FIX/go" go
  tar -czf "$FIX/node.tgz" -C "$FIX/node" node-v22
  tar -czf "$FIX/fc.tgz" -C "$FIX/fc" release-v1.17.0-x86_64
  tar -czf "$FIX/grpcurl.tgz" -C "$FIX/grpcurl" grpcurl
  sh_() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
  cat >"$TMP/test-pins.sh" <<EOF
E15_GO_URL=https://fixture.invalid/go.tgz
E15_GO_SHA256=$(sh_ "$FIX/go.tgz")
E15_NODE_URL=https://fixture.invalid/node.tgz
E15_NODE_SHA256=$(sh_ "$FIX/node.tgz")
E15_FC_URL=https://fixture.invalid/fc.tgz
E15_FC_SHA256=$(sh_ "$FIX/fc.tgz")
E15_GRPCURL_URL=https://fixture.invalid/grpcurl.tgz
E15_GRPCURL_SHA256=$(sh_ "$FIX/grpcurl.tgz")
EOF
  # The downloader stub: copies the fixture named by the URL's basename, logs the call.
  printf '#!/usr/bin/env bash\necho "fetch $1" >>"%s"\ncp "%s/$(basename "$1")" "$2"\n' "$TMP/fetch.log" "$FIX" >"$TMP/fetch.sh"
  chmod +x "$TMP/fetch.sh"
  # sudo runs the command (no root needed for the test root); apt/dpkg/usermod/getent are stubs.
  printf '#!/usr/bin/env bash\n[ "$1" = -n ] && shift\necho "sudo $*" >>"%s"\n[ $# -eq 0 ] || [ "$1" = true ] && exit 0\nexec "$@"\n' "$TMP/bsudo.log" >"$BS/sudo"
  # apt-get: logs; install adds each package (podman also its dependency conmon, and enables
  # podman-restart.service); APT_FAIL=1 fails after the first package, like a broken download.
  cat >"$BS/apt-get" <<SH
#!/usr/bin/env bash
echo "apt-get \$*" >>"$TMP/apt.log"
echo "apt-get \$*" >>"$TMP/order.log"
# APT_LOCK_N=k: the first k updates fail on the lists lock; APT_UPDATE_FAIL=1: update fails otherwise
case " \$* " in *" update "*)
  if [ -n "\${APT_LOCK_N:-}" ]; then
    n=\$(cat "$TMP/aptlock.n" 2>/dev/null || echo 0)
    if [ "\$n" -lt "\$APT_LOCK_N" ]; then
      echo \$((n + 1)) >"$TMP/aptlock.n"
      echo "E: Could not get lock /var/lib/apt/lists/lock. It is held by process 4242 (apt-get)" >&2
      exit 100
    fi
  fi
  [ "\${APT_UPDATE_FAIL:-0}" = 1 ] && { echo "E: Failed to fetch http://archive.ubuntu.com/x  404" >&2; exit 100; } ;;
esac
inst=0
for a; do
  case "\$a" in
  install) inst=1 ;;
  -* | DPkg::* | update) ;;
  *) [ "\$inst" = 1 ] || continue
    echo "\$a" >>"$TMP/dpkg.db"
    [ "\$a" = podman ] && echo conmon >>"$TMP/dpkg.db" && echo podman-restart.service >>"$TMP/units.db"
    [ "\${APT_FAIL:-0}" = 1 ] && exit 100 ;;
  esac
done
exit 0
SH
  printf '#!/usr/bin/env bash\nif [ "$1" = -W ] && [ "$2" = -f ] && [ "$3" = "\\${Status}" ]; then grep -qx "$4" "%s" 2>/dev/null && printf "install ok installed"; exit 0; fi\nsed "s/^/ii  /" "%s" 2>/dev/null; exit 0\n' "$TMP/dpkg.db" "$TMP/dpkg.db" >"$BS/dpkg-query"
  printf '#!/usr/bin/env bash\necho "systemctl $*" >>"%s"\ncase "$1" in is-active|is-failed) exit 1 ;; esac\n[ "$1" = list-unit-files ] && sed "s/$/ enabled enabled/" "%s" 2>/dev/null\nexit 0\n' "$TMP/bsctl.log" "$TMP/units.db" >"$BS/systemctl"
  printf '#!/usr/bin/env bash\necho "cloud-init $*" >>"%s"\n' "$TMP/order.log" >"$BS/cloud-init"
  printf 'ssh.service\n' >"$TMP/units.db"
  printf '#!/usr/bin/env bash\necho "usermod $*" >>"%s"\necho "$3" >"%s"\n' "$TMP/usermod.log" "$TMP/kvm.members" >"$BS/usermod"
  printf '#!/usr/bin/env bash\n[ "$2" = kvm ] && echo "kvm:x:992:$(cat "%s" 2>/dev/null)"\n' "$TMP/kvm.members" >"$BS/getent"
  printf '#!/bin/sh\necho x86_64\n' >"$BS/uname"
  chmod +x "$BS"/*
  : >"$TMP/kvm-dev"
  boot() {
    env E15_HOST_PROFILE=fresh-metal E15_ROOT="$BR" E15_TEST_ROOT="$BR" E15_TEST_PINS="$TMP/test-pins.sh" \
      E15_FETCH="$TMP/fetch.sh" E15_OS_RELEASE="$TMP/os-ubuntu" E15_KVM_DEV="$TMP/kvm-dev" CP_LOG="$TMP/cp.log" \
      E15_MANIFEST="$TMP/boot-m.md" PATH="$BS:$PATH" "$@" bash "$BR/src/e15/rig/bootstrap.sh" >"$TMP/boot.out" 2>&1
  }
  : >"$TMP/fetch.log"
  : >"$TMP/order.log"
  printf 'git\ncurl\npython3\niproute2\n' >"$TMP/dpkg.db"
  : >"$TMP/kvm.members"
  rm -f "$TMP/boot-m.md"
  boot
  check "bootstrap: first run exits 0" "$?" "0"
  [ -s "$TMP/boot.out" ] && grep -q 'bootstrap.sh:' "$TMP/boot.out" && sed 's/^/    /' "$TMP/boot.out" | tail -5
  check "bootstrap: downloads go, node, firecracker, grpcurl once each" "$(sort "$TMP/fetch.log" | uniq -c | awk '{print $1}' | tr -d '\n')/$(grep -c . "$TMP/fetch.log")" "1111/4"
  check "bootstrap: go into go-toolchain, node into node, firecracker+jailer+grpcurl+pnpm into bin" \
    "$(cd "$BR" && for f in go-toolchain/bin/go node/bin/node bin/firecracker bin/jailer bin/grpcurl bin/pnpm; do [ -x "$f" ] && printf y || printf n; done)" "yyyyyy"
  check "bootstrap: installs only the missing apt packages" "$(grep ' install ' "$TMP/apt.log" | sed 's/.* -q //')" "podman unzip e2fsprogs xfsprogs"
  # M4: cloud-init first, then apt with a dpkg lock timeout on both calls
  check "bootstrap: waits for cloud-init before apt" "$(head -2 "$TMP/order.log" | cut -d' ' -f1-3 | tr '\n' '|')" "cloud-init status --wait|apt-get -o DPkg::Lock::Timeout=600|"
  check "bootstrap: apt update and install both carry DPkg::Lock::Timeout=600" "$(grep -c '^apt-get -o DPkg::Lock::Timeout=600 \(update\|install\) ' "$TMP/apt.log")" "2"
  # M5: exactly what apt added (the dependency too), the unit it enabled, purge of that list
  check "bootstrap: LEFTOVER names exactly the packages apt added, and the unit they enabled" \
    "$(grep -c 'LEFTOVER: apt packages added by E15 (asked for podman unzip e2fsprogs xfsprogs): conmon e2fsprogs podman unzip xfsprogs; units they enabled: podman-restart.service;' "$TMP/boot-m.md")" "1"
  check "bootstrap: the package undo disables the unit, then purges exactly that list (no autoremove)" \
    "$(grep -c 'undo: sudo -n systemctl disable --now podman-restart.service; sudo -n env DEBIAN_FRONTEND=noninteractive apt-get purge -y conmon e2fsprogs podman unzip xfsprogs$' "$TMP/boot-m.md")/$(grep -c autoremove "$TMP/boot-m.md")" "1/0"
  check "bootstrap: adds the user to kvm, with a PURGE that undoes it" "$(grep -c '^usermod -aG kvm' "$TMP/usermod.log")/$(grep -c "PURGE: sudo -n gpasswd -d $(id -un) kvm" "$TMP/boot-m.md")" "1/1"
  check "bootstrap: pnpm via corepack, pinned by version and sha512" "$(grep -c 'corepack install -g pnpm@9.15.9+sha512.68046141' "$TMP/cp.log")" "1"
  check "bootstrap: records each artifact's sha256 in state/artifacts" "$(awk '{print $1}' "$BR/state/artifacts" | sort | tr '\n' ' ')" "firecracker go grpcurl node pnpm "
  check "bootstrap: go's recorded sha256 is the tarball's" "$(awk '$1=="go"{print $2}' "$BR/state/artifacts")" "$(sh_ "$FIX/go.tgz")"
  check "bootstrap: records the host profile" "$(cat "$BR/state/host_profile")" "fresh-metal"
  check "bootstrap: PURGE of the root (contents only if a mount point) and podman storage" "$(grep -c "PURGE: sudo -n bash -c 'if mountpoint -q \"\$1\"; then find \"\$1\" -mindepth 1 -maxdepth 1 -exec rm -rf {} +; else rm -rf \"\$1\"; fi' _ $BR\$" "$TMP/boot-m.md")/$(grep -c 'PURGE: .*podman system reset' "$TMP/boot-m.md")" "1/1"
  cp "$TMP/boot-m.md" "$TMP/boot-m.1"
  : >"$TMP/fetch.log"
  : >"$TMP/apt.log"
  : >"$TMP/usermod.log"
  boot
  check "bootstrap: second run exits 0" "$?" "0"
  check "bootstrap: second run downloads, installs and adds nothing" "$(grep -c . "$TMP/fetch.log")/$(grep -c . "$TMP/apt.log")/$(grep -c . "$TMP/usermod.log")" "0/0/0"
  check "bootstrap: second run leaves the manifest unchanged" "$(cmp -s "$TMP/boot-m.md" "$TMP/boot-m.1" && echo same || echo changed)" "same"
  check "bootstrap: second run says nothing to change" "$(grep -c 'nothing to change' "$TMP/boot.out")" "1"
  # M5: an install that fails part way still records what it added (EXIT trap)
  cp "$TMP/dpkg.db" "$TMP/dpkg.full"
  printf 'git\ncurl\npython3\niproute2\nunzip\ne2fsprogs\nxfsprogs\n' >"$TMP/dpkg.db"
  cp "$TMP/boot-m.md" "$TMP/boot-m.pre-fail"
  boot APT_FAIL=1
  check "bootstrap: a failed apt install exits 1" "$?/$(grep -c 'apt-get install podman failed' "$TMP/boot.out")" "1/1"
  check "bootstrap: a failed install still records the packages it added, with their purge" \
    "$(diff "$TMP/boot-m.pre-fail" "$TMP/boot-m.md" | grep -c 'LEFTOVER: apt packages added by E15 (asked for podman): conmon podman; .*apt-get purge -y conmon podman$')" "1"
  check "bootstrap: the intent line precedes the install" "$(diff "$TMP/boot-m.pre-fail" "$TMP/boot-m.md" | grep -c 'apt: installing podman (the packages added are recorded next, even if this fails)')" "1"
  cp "$TMP/dpkg.full" "$TMP/dpkg.db"
  cp "$TMP/boot-m.pre-fail" "$TMP/boot-m.md"
  # L1: apt-get update retries while the lists lock is held, and only then
  printf 'git\ncurl\npython3\niproute2\nunzip\ne2fsprogs\nxfsprogs\n' >"$TMP/dpkg.db"
  rm -f "$TMP/aptlock.n"; : >"$TMP/apt.log"
  boot APT_LOCK_N=2 E15_APT_RETRY_S=0
  check "bootstrap: apt-get update retries on the lists lock, then succeeds" \
    "$?/$(grep -c ' update ' "$TMP/apt.log")/$(grep -c 'the lists lock is held' "$TMP/boot.out")" "0/3/2"
  cp "$TMP/dpkg.full" "$TMP/dpkg.db"; cp "$TMP/boot-m.pre-fail" "$TMP/boot-m.md"
  printf 'git\ncurl\npython3\niproute2\nunzip\ne2fsprogs\nxfsprogs\n' >"$TMP/dpkg.db"
  rm -f "$TMP/aptlock.n"; : >"$TMP/apt.log"
  boot APT_LOCK_N=9 E15_APT_RETRY_S=0 E15_APT_RETRIES=3
  check "bootstrap: a lists lock held past the retries dies, without installing" \
    "$?/$(grep -c 'the apt lists lock stayed held (3 tries' "$TMP/boot.out")/$(grep -c ' install ' "$TMP/apt.log")" "1/1/0"
  rm -f "$TMP/aptlock.n"; : >"$TMP/apt.log"
  boot APT_UPDATE_FAIL=1 E15_APT_RETRY_S=0
  check "bootstrap: an update failure that is not the lock dies at once (no retry)" \
    "$?/$(grep -c ' update ' "$TMP/apt.log")/$(grep -c 'apt-get update failed: E: Failed to fetch' "$TMP/boot.out")" "1/1/1"
  check "bootstrap: no apt-update temp file is left" "$(find /tmp -maxdepth 1 -name 'e15-apt-update.*' -newer "$TMP/boot-m.pre-fail" 2>/dev/null | grep -c .)" "0"
  cp "$TMP/dpkg.full" "$TMP/dpkg.db"; cp "$TMP/boot-m.pre-fail" "$TMP/boot-m.md"
  # L1: grpcurl's check is its version and its installed binary's sha256, not only -x
  printf '#!/bin/sh\necho "grpcurl 1.9.4"\n# another build\n' >"$BR/bin/grpcurl"
  : >"$TMP/fetch.log"
  boot
  check "bootstrap: a grpcurl binary that is not the installed one is reinstalled" "$?/$(grep -c 'bootstrap: grpcurl from' "$TMP/boot.out")/$(cmp -s "$BR/bin/grpcurl" "$FIX/grpcurl/grpcurl" && echo pinned)" "0/1/pinned"
  check "bootstrap: install helpers check every step (no bare tar/install)" \
    "$(sed -n '/^untar_into()/,/^install_tarball go/p' "$BR/src/e15/rig/bootstrap.sh" | grep -E '^\s+(tar|install|rm|mkdir|mv) ' | grep -cvE '\|\| return 1$|&&( r=0)?$|^\s+mv "\$dir.new" "\$dir"$|^\s+rm -rf "\$t"$')" "0"
  cp "$TMP/boot-m.pre-fail" "$TMP/boot-m.md"

  # --- H1: the E15 data volume (E15_DATA_DEV): XFS reflink=1 mounted at the WHOLE root ---------
  # Fake block device /dev/e15fake, state in $DV: sig (blkid), parts, uuid, reflink, mounts
  # ("target source fstype"), vol/ (the filesystem's contents while unmounted), mkfs.log.
  DS="$TMP/dstub"
  mkdir -p "$DS"
  cat >"$DS/lsblk" <<'SH'
#!/usr/bin/env bash
case "$*" in *TYPE*) echo disk ;; *NAME*) echo e15fake; cat "$DV/parts" 2>/dev/null ;; esac
SH
  cat >"$DS/blkid" <<'SH'
#!/usr/bin/env bash
case "$*" in *"-s UUID"*) cat "$DV/uuid" 2>/dev/null ;; *) cat "$DV/sig" 2>/dev/null ;; esac
exit 0
SH
  cat >"$DS/mkfs.xfs" <<'SH'
#!/usr/bin/env bash
echo "mkfs.xfs $*" >>"$DV/mkfs.log"
printf 'TYPE=xfs\n' >"$DV/sig"; echo fake-uuid-1 >"$DV/uuid"
case "$*" in *"-m reflink=1"*) echo 1 >"$DV/reflink" ;; esac
SH
  cat >"$DS/mount" <<'SH'
#!/usr/bin/env bash
t=${!#}; echo "$t /dev/e15fake xfs" >>"$DV/mounts"
mkdir -p "$DV/vol"; (shopt -s dotglob nullglob; for f in "$DV/vol"/*; do mv "$f" "$t/"; done)
SH
  cat >"$DS/umount" <<'SH'
#!/usr/bin/env bash
t=$1; mkdir -p "$DV/vol"; (shopt -s dotglob nullglob; for f in "$t"/*; do mv "$f" "$DV/vol/"; done)
grep -v "^$t " "$DV/mounts" >"$DV/mounts.new"; mv "$DV/mounts.new" "$DV/mounts"
SH
  cat >"$DS/mountpoint" <<'SH'
#!/usr/bin/env bash
grep -q "^${!#} " "$DV/mounts" 2>/dev/null
SH
  cat >"$DS/findmnt" <<'SH'
#!/usr/bin/env bash
col="" src="" mp=""
while [ $# -gt 0 ]; do case "$1" in -S) src=$2; shift ;; --mountpoint) mp=$2; shift ;; -*o|-no|-rno) ;; *) col=$1 ;; esac; shift; done
[ -n "$src" ] && { awk -v s="$src" '$2==s{print $1}' "$DV/mounts" 2>/dev/null; exit 0; }
awk -v m="$mp" -v c="$col" '$1==m{print (c=="SOURCE")?$2:$3}' "$DV/mounts" 2>/dev/null
SH
  cat >"$DS/xfs_info" <<'SH'
#!/usr/bin/env bash
echo "meta-data=${1} crc=1 finobt=1, sparse=1, rmapbt=0 reflink=$(cat "$DV/reflink" 2>/dev/null || echo 0)"
SH
  chmod +x "$DS"/*
  dvreset() {
    DV=$TMP/dv.$1
    rm -rf "$DV"
    mkdir -p "$DV/vol"
    : >"$DV/mounts"
    : >"$DV/fstab"
    printf 'LABEL=cloudimg-rootfs / ext4 discard 0 1\n' >"$DV/fstab"
    export DV
  }
  dboot() { # ROOT MANIFEST [VAR=...]: bootstrap with E15_DATA_DEV from ROOT's staged copy
    local r=$1 m=$2
    shift 2
    env E15_HOST_PROFILE=fresh-metal E15_ROOT="$r" E15_TEST_ROOT="$r" E15_TEST_PINS="$TMP/test-pins.sh" \
      E15_FETCH="$TMP/fetch.sh" E15_OS_RELEASE="$TMP/os-ubuntu" E15_KVM_DEV="$TMP/kvm-dev" CP_LOG="$TMP/cp.log" \
      E15_DATA_DEV=/dev/e15fake E15_TEST_FSTAB="$DV/fstab" E15_MANIFEST="$m" PATH="$DS:$BS:$PATH" "$@" \
      bash "$r/src/e15/rig/bootstrap.sh" >"$TMP/dboot.out" 2>&1
  }
  stage() { rm -rf "$1" && mkdir -p "$1/src/e15" && cp -R "$RIG" "$1/src/e15/rig"; }
  # a blank disk: formatted, mounted at the root before anything is written there
  DR="$TMP/e15-rig-test.data"
  stage "$DR"
  dvreset blank
  rm -f "$TMP/boot-d.md"
  dboot "$DR" "$TMP/boot-d.md"
  check "data volume: a blank disk bootstraps (exit 0)" "$?" "0"
  grep -q 'bootstrap.sh:' "$TMP/dboot.out" && sed 's/^/    /' "$TMP/dboot.out" | tail -5
  check "data volume: mkfs.xfs -m reflink=1 on the disk, once" "$(cat "$DV/mkfs.log")" "mkfs.xfs -q -m reflink=1 /dev/e15fake"
  check "data volume: mounted at the WHOLE root (not workspaces/)" "$(cat "$DV/mounts")" "$DR /dev/e15fake xfs"
  check "data volume: fstab line by UUID, nofail, passno 0 (as the operator's)" "$(grep -c "^UUID=fake-uuid-1 $DR xfs defaults,nofail 0 0\$" "$DV/fstab")/$(grep -c . "$DV/fstab")" "1/2"
  check "data volume: the staged tree moved onto the volume" "$([ -f "$DR/src/e15/rig/bootstrap.sh" ] && echo staged)" "staged"
  check "data volume: everything bootstrap writes lands on the volume" "$([ -f "$DR/state/host_profile" ] && [ -x "$DR/bin/grpcurl" ] && echo on-volume)" "on-volume"
  check "data volume: mounted before anything is written under the root (mount line before the root PURGE)" "$(awk '/mounted \/dev\/e15fake/{a=NR} /\(all E15 files\) \| PURGE/{b=NR} END{print (a && b && a<b) ? "before" : "after"}' "$TMP/boot-d.md")" "before"
  check "data volume: PURGE lines for umount, the fstab line and the mount point; none wipes the disk" \
    "$(grep -c 'PURGE: ! mountpoint -q .* || sudo -n umount ' "$TMP/boot-d.md")/$(grep -c "PURGE: sudo -n sh -c 'grep -v .* $DV/fstab fake-uuid-1 && sudo -n systemctl daemon-reload" "$TMP/boot-d.md")/$(grep -c 'PURGE: \[ ! -e .* \] || sudo -n rmdir ' "$TMP/boot-d.md")/$(grep -cE 'PURGE: .*(mkfs|wipefs|dd )' "$TMP/boot-d.md")" "1/1/1/0"
  cp "$TMP/boot-d.md" "$TMP/boot-d.1"
  : >"$TMP/fetch.log"
  dboot "$DR" "$TMP/boot-d.md"
  check "data volume: a second run (already XFS reflink=1 at the root) changes nothing" \
    "$?/$(grep -c . "$DV/mkfs.log")/$(cmp -s "$TMP/boot-d.md" "$TMP/boot-d.1" && echo same)/$(grep -c . "$TMP/fetch.log")" "0/1/same/0"
  # M3: --purge replays the root's contents removal, then umount, fstab line, mount point; verify passes
  E15_ROOT="$DR" E15_TEST_ROOT="$DR" E15_TEST_FSTAB="$DV/fstab" E15_MANIFEST="$TMP/boot-d.md" PATH="$DS:$BS:$SPATH" \
    bash "$RIG/teardown.sh" --purge >"$TMP/td.out" 2>&1
  check "data volume purge: exit 0, verified" "$?/$(grep -c 'verified (fresh-metal)' "$TMP/boot-d.md")" "0/1"
  grep -q 'VERIFY\|FAILED' "$TMP/td.out" && sed 's/^/    /' "$TMP/td.out" | grep 'VERIFY\|FAILED' | head -5
  check "data volume purge: unmounted, fstab line gone (rest kept), mount point removed" \
    "$(grep -c . "$DV/mounts")/$(cat "$DV/fstab")/$([ -e "$DR" ] && echo present || echo gone)" "0/LABEL=cloudimg-rootfs / ext4 discard 0 1/gone"
  check "data volume purge: the disk is never wiped (still formatted, no second mkfs), contents removed" \
    "$(cat "$DV/sig")/$(grep -c . "$DV/mkfs.log")/$(find "$DV/vol" -mindepth 1 | grep -c .)" "TYPE=xfs/1/0"
  # refusals: a disk with a filesystem, a partitioned disk, E15 files already on the root fs
  stage "$DR"
  dvreset ext4
  printf 'TYPE=ext4\n' >"$DV/sig"
  dboot "$DR" "$TMP/boot-r.md"
  check "data volume: a disk with a filesystem is refused, not formatted" "$?/$(grep -c '/dev/e15fake is not blank (TYPE=ext4); refusing to format it' "$TMP/dboot.out")/$([ -s "$DV/mkfs.log" ] && echo mkfs || echo none)" "1/1/none"
  dvreset gpt
  printf 'PTTYPE=gpt\n' >"$DV/sig"
  dboot "$DR" "$TMP/boot-r.md"
  check "data volume: a disk with a partition table is refused" "$?/$(grep -c 'not blank (PTTYPE=gpt)' "$TMP/dboot.out")/$([ -s "$DV/mkfs.log" ] && echo mkfs || echo none)" "1/1/none"
  dvreset parts
  echo e15fake1 >"$DV/parts"
  dboot "$DR" "$TMP/boot-r.md"
  check "data volume: a disk with partitions is refused" "$?/$(grep -c 'has partitions; refusing to format it' "$TMP/dboot.out")/$([ -s "$DV/mkfs.log" ] && echo mkfs || echo none)" "1/1/none"
  dvreset e15files
  mkdir -p "$DR/state"
  dboot "$DR" "$TMP/boot-r.md"
  check "data volume: E15 files already on the root filesystem are refused (would be hidden)" "$?/$(grep -c 'already holds E15 files on the root filesystem (state)' "$TMP/dboot.out")/$([ -s "$DV/mkfs.log" ] && echo mkfs || echo none)" "1/1/none"
  rm -rf "$DR/state"
  # mounted at the root already: accepted only as XFS reflink=1 (the operator's own mount)
  dvreset ext4mounted
  printf 'TYPE=ext4\n' >"$DV/sig"
  echo "$DR /dev/e15fake ext4" >"$DV/mounts"
  dboot "$DR" "$TMP/boot-r.md"
  check "data volume: a non-XFS filesystem mounted at the root is refused" "$?/$(grep -c 'is mounted at .* but is not XFS with reflink=1 (ext4); refusing to touch it' "$TMP/dboot.out")" "1/1"
  dvreset opmounted
  printf 'TYPE=xfs\n' >"$DV/sig"; echo 1 >"$DV/reflink"
  echo "$DR /dev/e15fake xfs" >"$DV/mounts"
  rm -f "$TMP/boot-o.md"
  dboot "$DR" "$TMP/boot-o.md"
  check "data volume: the operator's XFS reflink=1 mount is accepted, untouched" "$?/$(grep -c . "$DV/mkfs.log" 2>/dev/null || echo 0)/$(grep -c 'already XFS reflink=1 and mounted (by the operator; nothing changed, no undo)' "$TMP/boot-o.md")/$(grep -c 'PURGE: .*umount' "$TMP/boot-o.md")" "0/0/1/0"
  # M3: with no recorded umount, --purge empties the mount point and verify accepts it
  E15_ROOT="$DR" E15_TEST_ROOT="$DR" E15_MANIFEST="$TMP/boot-o.md" PATH="$DS:$BS:$SPATH" \
    bash "$RIG/teardown.sh" --purge >"$TMP/td.out" 2>&1
  check "teardown --purge: a mounted root is emptied, the mount point kept, verify passes" \
    "$?/$(find "$DR" -mindepth 1 | grep -c .)/$(grep -c "$DR /dev/e15fake xfs" "$DV/mounts")/$(grep -c 'emptied (still a mount point: no recorded umount)' "$TMP/boot-o.md")" "0/0/1/1"
  # L2: an older manifest's `rm -rf <root>` PURGE line is never replayed on a mount point
  for prof in fresh-metal aws-prelim; do
    mkdir -p "$DR/state" "$DR/junk/deep"
    echo "$DR /dev/e15fake xfs" >"$DV/mounts"
    printf -- '## Bootstrap 1\n- t created %s | PURGE: sudo -n rm -rf %s\n- t created %s | PURGE: %s\n' "$DR" "$DR" "$DR" \
      "$(E15_HOST_PROFILE=fresh-metal E15_ROOT="$DR" E15_TEST_ROOT="$DR" bash -c 'source "$1"; e15_root_purge_cmd' _ "$RIG/lib.sh")" >"$TMP/legacy.md"
    E15_HOST_PROFILE=$prof E15_TEARDOWN_VERIFY=0 E15_ROOT="$DR" E15_TEST_ROOT="$DR" E15_MANIFEST="$TMP/legacy.md" PATH="$DS:$BS:$SPATH" \
      bash "$RIG/teardown.sh" --purge >"$TMP/td.out" 2>&1
    check "teardown --purge ($prof): a legacy rm -rf of a mounted root empties it instead (exit 0, mount point kept)" \
      "$?/$([ -d "$DR" ] && echo kept)/$(find "$DR" -mindepth 1 | grep -c .)/$(grep -c "is a mount point; its contents only, not: sudo -n rm -rf $DR" "$TMP/td.out")" "0/kept/0/1"
  done
  : >"$DV/mounts"
  mkdir -p "$DR/x"
  printf -- '- t created | PURGE: sudo -n rm -rf %s\n' "$DR" >"$TMP/legacy.md"
  E15_HOST_PROFILE=aws-prelim E15_TEARDOWN_VERIFY=0 E15_ROOT="$DR" E15_TEST_ROOT="$DR" E15_MANIFEST="$TMP/legacy.md" PATH="$DS:$BS:$SPATH" \
    bash "$RIG/teardown.sh" --purge >"$TMP/td.out" 2>&1
  check "teardown --purge (aws-prelim): rm -rf of a root that is not a mount point is replayed as is" \
    "$?/$([ -e "$DR" ] && echo present || echo gone)/$(grep -c 'replay: sudo -n rm -rf ' "$TMP/td.out")/$(grep -c 'is a mount point' "$TMP/td.out")" "0/gone/1/0"
  mkdir -p "$DR"
  : >"$DV/mounts"
  mkdir -p "$DR/leftover"
  E15_ROOT="$DR" E15_TEST_ROOT="$DR" E15_MANIFEST="$TMP/boot-o.md" PATH="$DS:$BS:$SPATH" E15_HOST_PROFILE=fresh-metal \
    bash "$RIG/teardown.sh" --purge >"$TMP/td.out" 2>&1
  check "teardown --purge: a root that is not a mount point is removed whole (rm -rf), verified" "$?/$([ -e "$DR" ] && echo present || echo gone)" "0/gone"
  rm -rf "$DR"
  # a tarball that does not match its pin is refused and not installed
  printf 'E15_GRPCURL_SHA256=%064d\n' 0 >>"$TMP/test-pins.sh"
  rm -f "$BR/bin/grpcurl" "$BR/state/bootstrap-grpcurl" "$BR/downloads/grpcurl.tgz"
  boot
  check "bootstrap: a checksum mismatch fails" "$?/$(grep -c 'checksum mismatch for https://fixture.invalid/grpcurl.tgz' "$TMP/boot.out")" "1/1"
  check "bootstrap: the mismatched download is not kept" "$(find "$BR/downloads" -name 'grpcurl*' | grep -c .)/$([ -e "$BR/bin/grpcurl" ] && echo installed || echo absent)" "0/absent"
  # refusal on an empty checksum constant, before touching anything
  printf 'E15_FC_SHA256=\nE15_KERNEL_SHA256=\n' >>"$TMP/test-pins.sh"
  : >"$TMP/fetch.log"
  : >"$TMP/bsudo.log"
  cp "$TMP/boot-m.md" "$TMP/boot-m.2"
  boot
  check "bootstrap: an empty pin refuses the run (exit 1)" "$?" "1"
  check "bootstrap: the refusal names every empty pin" "$(grep -c 'empty pin(s) in pins.sh, the operator must fill them: E15_FC_SHA256 E15_KERNEL_SHA256' "$TMP/boot.out")" "1"
  check "bootstrap: the refusal touched nothing" "$(grep -c . "$TMP/fetch.log")/$(grep -c . "$TMP/bsudo.log")/$(cmp -s "$TMP/boot-m.md" "$TMP/boot-m.2" && echo same)" "0/0/same"
  # M2: no recorded profile, so lib.sh defaults to aws-prelim and bootstrap's own guard refuses it
  rm -rf "$BR/state"
  E15_ROOT="$BR" E15_TEST_ROOT="$BR" E15_MANIFEST="$TMP/boot-x.md" E15_OS_RELEASE="$TMP/os-ubuntu" \
    PATH="$BS:$PATH" bash "$BR/src/e15/rig/bootstrap.sh" >"$TMP/boot.out" 2>&1
  check "bootstrap: aws-prelim refuses it (clean profile state, its own message)" "$?/$(grep -c '^bootstrap.sh: fresh-metal only (E15_HOST_PROFILE=aws-prelim); aws-prelim needs no bootstrap$' "$TMP/boot.out")" "1/1"
  E15_HOST_PROFILE=aws-prelim E15_ROOT="$BR" E15_TEST_ROOT="$BR" E15_MANIFEST="$TMP/boot-x.md" E15_OS_RELEASE="$TMP/os-ubuntu" \
    PATH="$BS:$PATH" bash "$BR/src/e15/rig/bootstrap.sh" >"$TMP/boot.out" 2>&1
  check "bootstrap: explicit aws-prelim refuses it too" "$?/$(grep -c 'fresh-metal only (E15_HOST_PROFILE=aws-prelim)' "$TMP/boot.out")" "1/1"
  check "bootstrap: a non-Ubuntu host is refused" "$(boot E15_TEST_PINS= E15_OS_RELEASE="$TMP/os-amzn"; echo $?)/$(grep -c 'expects Ubuntu' "$TMP/boot.out")" "1/1"
  check "setup.sh: fresh-metal refuses empty pins too" "$(grep -c '^  e15_require_pins$' "$RIG/setup.sh")" "1"
  check "e15_fetch: no checksum -> refuses" "$(E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; e15_fetch https://x.invalid/a "" "$2"' _ "$RIG/lib.sh" "$TMP/nofetch" >/dev/null 2>&1; echo "$?/$([ -e "$TMP/nofetch" ] && echo file || echo none)")" "1/none"
fi

# reflink probe -> sparse fallback
if [ -f "$RIG/lib.sh" ]; then
  CPS="$TMP/cpstub"
  mkdir -p "$CPS" "$TMP/rprobe"
  printf '#!/usr/bin/env bash\nfor a; do [ "$a" = --reflink=always ] && { echo "cp: failed to clone: Operation not supported" >&2; exit 1; }; done\nexec /bin/cp "$@"\n' >"$CPS/cp"
  chmod +x "$CPS/cp"
  rp() { PATH="$1:$PATH" E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; probe_reflink "$2"' _ "$RIG/lib.sh" "$TMP/rprobe"; }
  check "probe_reflink: cp --reflink=always fails (ext4) -> sparse" "$(rp "$CPS")" "sparse"
  printf '#!/usr/bin/env bash\nargs=(); for a; do [ "$a" = --reflink=always ] || args+=("$a"); done\nexec /bin/cp "${args[@]}"\n' >"$CPS/cp"
  check "probe_reflink: cp --reflink=always works (XFS) -> reflink" "$(rp "$CPS")" "reflink"
  check "probe_reflink: leaves no probe files" "$(find "$TMP/rprobe" -mindepth 1 | grep -c .)" "0"
  wcm() { E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; m=$(workspace_copy_mode); echo "$m $(workspace_cp_flag "$m")"' _ "$RIG/lib.sh"; }
  rm -f "$TROOT/state/workspace_copy"
  check "workspace copy: no state (aws-prelim) -> reflink, as before" "$(wcm)" "reflink --reflink=always"
  echo sparse >"$TROOT/state/workspace_copy"
  check "workspace copy: state sparse -> cp --sparse=always" "$(wcm)" "sparse --sparse=always"
  rm -f "$TROOT/state/workspace_copy"
  check "setup.sh requires reflink from each template dir into workspaces, every run (fresh-metal)" "$(grep -c 'for d in "$E15_ROOT/template" "$E15_ROOT/template-mem512"; do e15_require_reflink "$E15_WORKSPACES" "$d"; done' "$RIG/setup.sh")/$(grep -c 'workspace_copy" ]' "$RIG/setup.sh")" "1/0"
  check "rung.sh copies with the recorded mode's flag" "$(grep -c 'cp "\$cpf" "\$tpl" "\$d/workspace.img"' "$RIG/rung.sh")/$(grep -c 'workspace_cp_flag "\$WS_COPY"' "$RIG/rung.sh")" "1/2"
  check "rung.sh keeps the K floor unchanged" "$(grep -c 'print(max(16, (int(math.ceil(w/s))+3)\*int(sys.argv\[3\])))' "$RIG/rung.sh")" "1"
  de() { E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; shift; workspace_disk_estimate "$@"' _ "$RIG/lib.sh" "$@"; }
  check "disk estimate: 128 x 16 images x 256 MiB worst case" "$(de 128 16 256 15000 104857600)" \
    "N=128: 2048 images (K=16) x 256 MiB = 512.0 GiB worst case; 29.3 GiB estimated, 32.2 GiB with the 10% margin; 100.0 GiB free"
  check "disk estimate: creation cost above free space fails" "$(de 128 16 1024 600000 104857600 >/dev/null; echo $?)" "1"
  # rung.sh in sparse mode: prints the estimate and refuses a rung that cannot fit (before any unit)
  printf '#!/usr/bin/env bash\n[ "$1" = is-active ] && exit 0\nexit 0\n' >"$STUB/systemctl"
  printf '#!/usr/bin/env bash\necho "Filesystem 1024-blocks Used Available Capacity Mounted"\necho "/dev/x 100 1 10 1%% /"\n' >"$STUB/df"
  chmod +x "$STUB/df"
  mkdir -p "$TROOT/corpora/default" "$TROOT/runs" "$TROOT/workspaces" "$TROOT/jail" "$TROOT/state"
  printf '{"table": {"mean_span_min": 30}}\n' >"$TROOT/corpora/default/corpus-report.json"
  head -c 4096 /dev/zero >"$TROOT/template/workspace.img"
  echo sparse >"$TROOT/state/workspace_copy"
  : >"$CALLS"
  E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" PATH="$SPATH" E15_MANIFEST="$TMP/m.md" bash "$RIG/rung.sh" sbx 1 default >"$TMP/r.out" 2>&1
  check "rung.sh sparse: refuses when the copies do not fit" "$?/$(grep -c 'not enough disk for 16 sparse workspaces' "$TMP/r.out")" "1/1"
  check "rung.sh sparse: the refusal started no worker" "$(grep -c 'systemd-run' "$CALLS")" "0"
  rm -f "$TROOT/state/workspace_copy" "$STUB/df"
  printf '#!/usr/bin/env bash\necho "systemctl $*" >>"%s"\n' "$CALLS" >"$STUB/systemctl"
fi

# parallel disk measurement: 4 concurrent direct readers of separate files, summed (stubbed dd)
if [ -f "$RIG/lib.sh" ]; then
  PDS="$TMP/pddstub"
  mkdir -p "$PDS"
  : >"$TMP/pdd.calls"
  # Each reader of FILE.<i> takes 0.3 s and reports (i+1) x 100 MB/s; a write creates its file.
  cat >"$PDS/dd" <<SH
#!/usr/bin/env bash
echo "\$(date +%s.%N) dd \$*" >>"$TMP/pdd.calls"
for a; do case "\$a" in of=/dev/null) ;; of=*) : >"\${a#of=}" ;; if=/dev/zero) ;; if=*) f=\${a#if=} ;; esac; done
case "\$*" in *iflag=direct*)
  sleep 0.5
  echo "\$(date +%s.%N) end \$f" >>"$TMP/pdd.calls"
  i=\${f##*.}
  echo "2147483648 bytes (2.1 GB, 2.0 GiB) copied, \$(python3 -c "print(2147.483648/((\$i+1)*100))") s, x MB/s" >&2 ;;
esac
SH
  chmod +x "$PDS/dd"
  got=$(PATH="$PDS:$PATH" E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; measure_disk_read_parallel "$2" 4 2048' _ "$RIG/lib.sh" "$TMP/pprobe")
  check "parallel disk read: the readers' MB/s summed (100+200+300+400)" "$got" "1000.0"
  check "parallel disk read: 4 writes of 512 x 4M direct, 4 direct reads of separate files" \
    "$(grep -c 'bs=4M count=512 oflag=direct' "$TMP/pdd.calls")/$(grep 'iflag=direct' "$TMP/pdd.calls" | grep -o 'if=[^ ]*' | sort -u | grep -c .)" "4/4"
  # concurrent: every reader started before the first one ended
  check "parallel disk read: the readers ran concurrently" "$(python3 -c '
import sys
rows = [l.split() for l in open(sys.argv[1])]
starts = [float(r[0]) for r in rows if "iflag=direct" in r]
ends = [float(r[0]) for r in rows if r[1] == "end"]
print("yes" if len(starts) == 4 and max(starts) < min(ends) else "no")' "$TMP/pdd.calls")" "yes"
  check "parallel disk read: every probe file is removed" "$(find "$TMP" -maxdepth 1 -name 'pprobe*' | grep -c .)" "0"
  printf '#!/usr/bin/env bash\ncase "$*" in *iflag=direct*) exit 1 ;; *of=*) for a; do case "$a" in of=*) : >"${a#of=}" ;; esac; done ;; esac\n' >"$PDS/dd"
  PATH="$PDS:$PATH" E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; measure_disk_read_parallel "$2" 4 2048' _ "$RIG/lib.sh" "$TMP/pprobe" >/dev/null 2>&1
  check "parallel disk read: a failed reader fails, files still removed" "$?/$(find "$TMP" -maxdepth 1 -name 'pprobe*' | grep -c .)" "1/0"
  check "setup.sh fresh-metal: max = parallel, single kept for reference" \
    "$(grep -c 'par=$(measure_disk_read_parallel "$E15_WORKSPACES/.disk-read-probe-p" 4 2048)' "$RIG/setup.sh")/$(grep -c 'printf .%s\\n. "$par" >"$E15_STATE/disk_read_max_mbs"' "$RIG/setup.sh")/$(grep -c 'printf .%s\\n. "$one" >"$E15_STATE/disk_read_single_mbs"' "$RIG/setup.sh")" "1/1/1"
  check "setup.sh: the parallel measurement is fresh-metal only" "$(grep -B3 'par=$(measure_disk_read_parallel' "$RIG/setup.sh" | grep -c '^if \[ "\$METAL" = 1 \] && \[ ! -s "\$E15_STATE/disk_read_max_mbs" \]; then$')" "1"
  check "rung.sh records disk_read_single_mbs too" "$(grep -c '"disk_read_single_mbs": ' "$RIG/rung.sh")" "1"
fi

# teardown on fresh-metal: no host-worker/bench verify; lists LEFTOVERs; undoes in reverse
if [ -f "$RIG/teardown.sh" ]; then
  printf '#!/usr/bin/env bash\nexit 1\n' >"$STUB/systemctl"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$STUB/sudo"
  mkdir -p "$TROOT/state" && echo fresh-metal >"$TROOT/state/host_profile"
  : >"$OUT"
  printf -- '## Bootstrap 1\n- t LEFTOVER: apt packages podman (kept)\n- t added u to group kvm | PURGE: echo kvm >>"$OUT"\n## Setup 1\n- t PRESTATE: fresh-metal: no host services to pause\n- t created slice | UNDO: echo slice >>"$OUT"\n- t relay | UNDO: echo relay >>"$OUT"\n' >"$TMP/m7.md"
  E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" PATH="$SPATH" E15_MANIFEST="$TMP/m7.md" bash "$RIG/teardown.sh" >"$TMP/t7.out" 2>&1
  check "fresh-metal teardown: verifies without a host worker or bench containers (exit 0)" "$?" "0"
  check "fresh-metal teardown: undoes setup in reverse, keeps bootstrap's PURGE for --purge" "$(tr '\n' ' ' <"$OUT")" "relay slice "
  check "fresh-metal teardown: lists the LEFTOVER packages" "$(grep -c '^LEFTOVER: apt packages podman' "$TMP/t7.out")" "1"
  check "fresh-metal teardown: the verify note names fresh-metal" "$(grep -c 'verified (fresh-metal)' "$TMP/m7.md")" "1"
  rm -f "$TROOT/state/host_profile"
  printf '#!/usr/bin/env bash\necho "systemctl $*" >>"%s"\n' "$CALLS" >"$STUB/systemctl"
  printf '#!/usr/bin/env bash\necho "sudo $*" >>"%s"\n' "$CALLS" >"$STUB/sudo"
fi

# --- H1/H2: fresh-metal storage preflight and required reflink (stubbed stat/findmnt/xfs_info/cp) --
if [ -f "$RIG/lib.sh" ]; then
  SS="$TMP/sstub"
  mkdir -p "$SS"
  # stat -c %d DIR: the device from $SDEV ("DIR DEV" lines; longest matching prefix), default 100
  cat >"$SS/stat" <<'SH'
#!/usr/bin/env bash
d=${!#}
awk -v d="$d" 'index(d, $1) == 1 && length($1) > l {l = length($1); v = $2} END {print (v == "" ? 100 : v)}' "$SDEV"
SH
  printf '#!/usr/bin/env bash\ncase "$*" in *FSTYPE*) echo "$SFS" ;; *TARGET*) echo /srv/e15 ;; *SOURCE*) echo /dev/nvme1n1 ;; esac\n' >"$SS/findmnt"
  printf '#!/usr/bin/env bash\necho "meta-data=$1 reflink=$SREFLINK"\n' >"$SS/xfs_info"
  printf '#!/usr/bin/env bash\n[ "$1" = -n ] && shift\nexec "$@"\n' >"$SS/sudo"
  chmod +x "$SS"/*
  SR="$TMP/e15-rig-test.store"
  mkdir -p "$SR"/{snapshots,workspaces,jail,template,template-mem512,state}
  sc() { # storage check over the five dirs setup.sh checks; prints pass|refused, message in $TMP/sc.out
    (PATH="$SS:$PATH" E15_HOST_PROFILE=fresh-metal E15_ROOT="$SR" E15_TEST_ROOT="$SR" E15_MANIFEST="$TMP/m.md" \
      bash -c 'source "$1"; e15_storage_check "$E15_SNAPDIR" "$E15_WORKSPACES" "$E15_JAIL" "$E15_ROOT/template" "$E15_ROOT/template-mem512"' _ "$RIG/lib.sh" \
      >"$TMP/sc.out" 2>&1) && echo pass || echo refused
  }
  export SDEV="$TMP/sdev" SFS=xfs SREFLINK=1
  printf '%s 100\n' "$SR" >"$SDEV"
  check "storage: one device, XFS reflink=1 -> passes" "$(sc)/$(grep -c 'on one device, XFS reflink=1 at /srv/e15 (/dev/nvme1n1)' "$TMP/sc.out")" "pass/1"
  # the review's split layout: only workspaces/ on the second volume
  printf '%s 100\n%s/workspaces 200\n' "$SR" "$SR" >"$SDEV"
  check "storage: workspaces/ alone on another device -> refused, naming each dir's device" \
    "$(sc)/$(grep -c "are not on one filesystem device" "$TMP/sc.out")/$(grep -c "$SR/workspaces=200" "$TMP/sc.out")/$(grep -c "$SR/snapshots=100" "$TMP/sc.out")" "refused/1/1/1"
  printf '%s 100\n%s/template-mem512 300\n' "$SR" "$SR" >"$SDEV"
  check "storage: a template on another device -> refused" "$(sc)" "refused"
  printf '%s 100\n' "$SR" >"$SDEV"
  check "storage: one device but ext4 -> refused" "$(SFS=ext4 sc)/$(grep -c 'is on ext4 (/srv/e15), not XFS' "$TMP/sc.out")" "refused/1"
  # L4: xfs_info's output is captured before it is matched (no grep -q on a pipe under pipefail)
  XS="$TMP/xstub"; mkdir -p "$XS"
  printf '#!/usr/bin/env bash\n[ "$1" = -n ] && shift\nexec "$@"\n' >"$XS/sudo"
  # a long xfs_info whose reflink=1 is on line 3 of 2000: a grep -q in a pipe could stop early
  printf '#!/usr/bin/env bash\necho "meta-data=$1 isize=512"\necho "  = crc=1"\necho "  = reflink=1 bigtime=1"\nfor i in $(seq 2000); do echo "pad line $i padding padding padding padding"; done\nexit "${XFS_RC:-0}"\n' >"$XS/xfs_info"
  chmod +x "$XS"/*
  xr() { (PATH="$XS:$PATH" E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'set -o pipefail; source "$1"; e15_xfs_reflink /x' _ "$RIG/lib.sh") && echo yes || echo no; }
  check "e15_xfs_reflink: reflink=1 early in a long xfs_info output, under pipefail" "$(xr)" "yes"
  check "e15_xfs_reflink: xfs_info failing is not reflink" "$(XFS_RC=1 xr)" "no"
  check "e15_xfs_reflink: no grep -q on a pipe" "$(grep -v '^ *#' "$RIG/lib.sh" | grep -c 'xfs_info.*| *grep -q')" "0"
  check "storage: XFS without reflink=1 -> refused" "$(SREFLINK=0 sc)/$(grep -c 'has no reflink=1 (mkfs.xfs -m reflink=1)' "$TMP/sc.out")" "refused/1"
  # e15_require_reflink: probes from the template dir into workspaces/, every call; no fallback
  CPR="$TMP/cprstub"
  mkdir -p "$CPR"
  printf '#!/usr/bin/env bash\necho "cp $*" >>"%s"\n[ "${CP_REFLINK:-1}" = 1 ] || { echo "cp: failed to clone: Invalid cross-device link" >&2; exit 1; }\nargs=(); for a; do [ "$a" = --reflink=always ] || args+=("$a"); done\nexec /bin/cp "${args[@]}"\n' "$TMP/cpr.log" >"$CPR/cp"
  chmod +x "$CPR/cp"
  rr() { (PATH="$CPR:$PATH" E15_HOST_PROFILE=fresh-metal E15_ROOT="$SR" E15_TEST_ROOT="$SR" E15_MANIFEST="$TMP/m.md" \
    bash -c 'source "$1"; e15_require_reflink "$E15_WORKSPACES" "$E15_ROOT/template"' _ "$RIG/lib.sh" >"$TMP/rr.out" 2>&1) && echo pass || echo refused; }
  : >"$TMP/cpr.log"
  check "reflink required: works -> pass, state reflink" "$(rr)/$(cat "$SR/state/workspace_copy")" "pass/reflink"
  check "reflink required: the probe copies template dir -> workspaces dir (not state/)" \
    "$(grep -c "cp --reflink=always $SR/template/.reflink-probe.src $SR/workspaces/.reflink-probe.dst" "$TMP/cpr.log")" "1"
  check "reflink required: probe files removed" "$(find "$SR/template" "$SR/workspaces" -name '.reflink-probe*' | grep -c .)" "0"
  : >"$TMP/cpr.log"
  check "reflink required: re-probed on every call (a recorded reflink is not trusted)" "$(rr)/$(grep -c . "$TMP/cpr.log")" "pass/1"
  check "reflink required: fails -> refused, no sparse fallback, state removed" \
    "$(CP_REFLINK=0 rr)/$(grep -c 'reflink is required (no sparse fallback)' "$TMP/rr.out")/$([ -e "$SR/state/workspace_copy" ] && echo kept || echo removed)" "refused/1/removed"
  check "setup.sh: storage preflight before any build (fresh-metal)" \
    "$(awk '/storage=\$\(e15_storage_check "\$E15_SNAPDIR" "\$E15_WORKSPACES" "\$E15_JAIL" "\$E15_ROOT\/template" "\$E15_ROOT\/template-mem512"\)/{a=NR} /^# --- 5\. moca/{b=NR} END{print (a && a<b) ? "before" : "missing"}' "$RIG/setup.sh")" "before"
  check "setup.sh: no sparse fallback left on fresh-metal" "$(grep -c 'probe_reflink "\$E15_STATE"' "$RIG/setup.sh")/$(grep -c 'workspace_copy=sparse' "$RIG/setup.sh")" "0/0"
  # M1: measured in workspaces/, re-measured when the workspaces device changes
  check "setup.sh: disk read measured in workspaces/ (fresh-metal)" "$(grep -c 'measure_disk_read "\$E15_WORKSPACES/.disk-read-probe-1" 2048' "$RIG/setup.sh")/$(grep -c 'ws_src=$(findmnt -no SOURCE -T "\$E15_WORKSPACES"' "$RIG/setup.sh")/$(grep -c '>"\$E15_STATE/disk_read_source"' "$RIG/setup.sh")" "1/1/1"
  check "setup.sh: aws-prelim's measurement is unchanged" "$(grep -c 'mbs=$(measure_disk_read "\$E15_STATE/.disk-read-probe" 2048)' "$RIG/setup.sh")" "1"
  check "setup.sh: free space from the workspaces filesystem" "$(grep -c 'free_kb=$(df -Pk "\$E15_WORKSPACES"' "$RIG/setup.sh")/$(grep -c 'df -Pk "\$E15_ROOT"' "$RIG/setup.sh")" "1/0"
  rm -rf "$SR"
fi

# --- H2: reflink disk estimate (per-session delta, 10% margin) and rung.sh's refusal -------------
if [ -f "$RIG/lib.sh" ]; then
  de() { E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; shift; workspace_disk_estimate "$@"' _ "$RIG/lib.sh" "$@"; }
  # 100 copies x 1 GiB = 100 GiB; +10% = 110 GiB
  check "disk estimate: fits only with the margin -> 0" "$(de 10 10 1024 1048576 115343360 >/dev/null; echo $?)" "0"
  check "disk estimate: fits without the margin, not with it -> refused" "$(de 10 10 1024 1048576 110100480 >/dev/null; echo $?)" "1"
  wd() { E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; shift; workspace_delta_kb "$@"' _ "$RIG/lib.sh" "$@"; }
  head -c 3145728 /dev/urandom >"$TMP/tpl3m.img"
  check "workspace delta: the template's allocated size minus data.bin" "$(wd "$TMP/tpl3m.img" 1)" "$(($(du -k "$TMP/tpl3m.img" | cut -f1) - 1024))"
  check "workspace delta: floor 1 MiB; E15_WS_DELTA_MB overrides" "$(wd "$TMP/tpl3m.img" 512)/$(E15_WS_DELTA_MB=40 wd "$TMP/tpl3m.img" 0)" "1024/40960"
  # rung.sh on fresh-metal: refuses without a reflink state, and when the N*K deltas + 10% do not fit
  printf '#!/usr/bin/env bash\n[ "$1" = is-active ] && exit 0\nexit 0\n' >"$STUB/systemctl"
  printf '#!/usr/bin/env bash\necho "Filesystem 1024-blocks Used Available Capacity Mounted"\necho "/dev/x 100 1 ${DF_AVAIL:-10} 1%% /"\n' >"$STUB/df"
  chmod +x "$STUB/df"
  mkdir -p "$TROOT/corpora/default" "$TROOT/runs" "$TROOT/workspaces" "$TROOT/jail" "$TROOT/state" "$TROOT/template"
  printf '{"table": {"mean_span_min": 30}}\n' >"$TROOT/corpora/default/corpus-report.json"
  head -c 4096 /dev/zero >"$TROOT/template/workspace.img"
  echo fresh-metal >"$TROOT/state/host_profile"
  rm -f "$TROOT/state/workspace_copy"
  mrung() { E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" PATH="$SPATH" E15_MANIFEST="$TMP/m.md" env "$@" bash "$RIG/rung.sh" sbx 1 default >"$TMP/r.out" 2>&1; }
  : >"$CALLS"
  mrung
  check "rung.sh fresh-metal: no reflink state -> refused (no sparse default)" "$?/$(grep -c 'state/workspace_copy is not reflink (run setup.sh; reflink is required)' "$TMP/r.out")" "1/1"
  echo sparse >"$TROOT/state/workspace_copy"
  mrung
  check "rung.sh fresh-metal: a sparse state -> refused" "$?/$(grep -c 'is not reflink' "$TMP/r.out")" "1/1"
  echo reflink >"$TROOT/state/workspace_copy"
  # 16 copies x 1 MiB delta (floor) = 16384 kB; +10% = 18022 kB
  mrung DF_AVAIL=17000
  check "rung.sh fresh-metal: N*K deltas + 10% above free space -> refused before any unit" \
    "$?/$(grep -c 'not enough disk for 16 reflinked workspaces (1 MiB delta each, +10%)' "$TMP/r.out")/$(grep -c 'systemd-run' "$CALLS")" "1/1/0"
  rm -f "$TROOT/state/host_profile" "$TROOT/state/workspace_copy" "$STUB/df"
  printf '#!/usr/bin/env bash\necho "systemctl $*" >>"%s"\n' "$CALLS" >"$STUB/systemctl"
  check "rung.sh: the sampler measures the workspaces device on fresh-metal only" \
    "$(grep -c 'if \[ "\$E15_HOST_PROFILE" = fresh-metal \]; then export E15_DISK_PATH=\${E15_DISK_PATH:-\$E15_WORKSPACES}; fi' "$RIG/rung.sh")" "1"
  check "aws-prelim: the sparse branch in rung.sh is unchanged" "$(grep -c 'die "not enough disk for \$((N \* K)) sparse workspaces: \$est"' "$RIG/rung.sh")" "1"
fi

# --- L3: E15_TEST_PINS and E15_TEST_FSTAB only under a */e15-rig-test.* root ---------------------
printf 'E15_GO_VERSION=evil\n' >"$TMP/evil-pins.sh"
check "test pins: honoured under a test root" "$(E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" E15_TEST_PINS="$TMP/evil-pins.sh" bash -c 'source "$1"; echo $E15_GO_VERSION' _ "$RIG/lib.sh")" "evil"
check "test pins: ignored on /srv/e15 even when E15_TEST_ROOT names it" "$(E15_ROOT=/srv/e15 E15_TEST_ROOT=/srv/e15 E15_TEST_PINS="$TMP/evil-pins.sh" E15_TEST_FSTAB="$TMP/f" bash -c 'source "$1"; echo $E15_GO_VERSION $E15_FSTAB' _ "$RIG/lib.sh")" "1.26.0 /etc/fstab"
check "aws-prelim: the root PURGE is still rm -rf of the root" "$(E15_ROOT=/srv/e15 bash -c 'source "$1"; e15_root_purge_cmd' _ "$RIG/lib.sh")" "sudo -n rm -rf /srv/e15"
check "SPEC §9.3 lists memory_high; §13 accepts the operator's XFS reflink=1 mount" \
  "$(grep -c 'MemoryHigh reclaim throttled it' "$RIG/../SPEC.md")/$(grep -c 'is accepted as it is: bootstrap without `E15_DATA_DEV` leaves it' "$RIG/../SPEC.md")" "1/1"
check "aws-prelim: no missing workspace_copy state still means reflink" "$(E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; rm -f "$E15_STATE/workspace_copy"; workspace_copy_mode' _ "$RIG/lib.sh")" "reflink"

# --- rung.sh relay hygiene: restart E15's relay before the worker, attach check before the driver --
if [ -f "$RIG/rung.sh" ]; then
  RH="$TMP/rhstub"
  RR="$TMP/e15-rig-test.relay"
  rm -rf "$RH" "$RR"
  mkdir -p "$RH" "$RR"/{corpora/default,src/e15/commands,bin,template,secrets,logs,state,workspaces,jail,runs}
  ORD="$TMP/rh.order"
  printf '{"session":"s","calls":[]}\n' >"$RR/corpora/default/corpus.jsonl"
  printf '{"table": {"mean_span_min": 30}}\n' >"$RR/corpora/default/corpus-report.json"
  echo '{}' >"$RR/src/e15/commands/library.json"
  printf '#!/bin/sh\necho driver >>"%s"\nexit 0\n' "$ORD" >"$RR/bin/e15-driver"
  printf '#!/bin/sh\n' >"$RR/bin/microvm-worker"
  chmod +x "$RR/bin/e15-driver" "$RR/bin/microvm-worker"
  head -c 4096 /dev/zero >"$RR/template/workspace.img"
  echo tok >"$RR/secrets/exec.token"
  # systemctl: the relay is active while $RR/relay-up exists; nothing else is.
  cat >"$RH/systemctl" <<SH
#!/usr/bin/env bash
case "\$1 \$*" in
is-active*e15-relay.service*) [ -e "$RR/relay-up" ] ;;
is-active* | is-failed*) exit 1 ;;
*) exit 0 ;;
esac
SH
  # sudo: systemd-run / systemctl are simulated and logged in order; file commands run.
  cat >"$RH/sudo" <<SH
#!/usr/bin/env bash
[ "\$1" = -n ] && shift
case "\$1" in
systemctl)
  case "\$*" in *"stop e15-relay.service"*) rm -f "$RR/relay-up"; echo relay-stop >>"$ORD" ;; esac
  case "\$*" in *" sh-"*) echo "SHARED \$*" >>"$ORD" ;; esac
  exit 0 ;;
systemd-run)
  case "\$*" in
  *--unit=e15-relay.service*) touch "$RR/relay-up"; echo relay-start >>"$ORD" ;;
  *--unit=e15-worker.service*)
    echo worker-start >>"$ORD"
    for a; do case "\$a" in StandardOutput=file:*) echo "microvm-worker: attached, serving execs" >"\${a#StandardOutput=file:}" ;; esac; done ;;
  esac
  exit 0 ;;
esac
exec "\$@"
SH
  printf '#!/usr/bin/env bash\n[ -e "%s/relay-up" ] && printf "LISTEN 0 1 127.0.0.1:9643 0.0.0.0:*\\nLISTEN 0 1 127.0.0.1:9644 0.0.0.0:*\\n"\nexit 0\n' "$RR" >"$RH/ss"
  # grpcurl: the probe Exec. GRPC_MODE=refuse (default): the worker's checkKey refusal of an invalid
  # key (in-stream ExecError); eof: a refused duplicate Hello; ran: the worker ran it (exit 0).
  cat >"$RH/grpcurl" <<SH
#!/usr/bin/env bash
echo "\$*" | grep -o '"workspace_key": *"[^"]*"' | sed 's/^/probe /' >>"$ORD"
case "\${GRPC_MODE:-refuse}" in
eof) echo "ERROR: Code: Unavailable desc = EOF" >&2; exit 1 ;;
ran) echo '{"end": {"exitCode": 0}}' ;;
*) k=\$(echo "\$*" | grep -o '"workspace_key": *"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')
   echo "{\"error\": {\"message\": \"invalid-workspace-key: workspace_key \\\\\"\$k\\\\\" must match [A-Za-z0-9][A-Za-z0-9._-]{0,127}\"}}"
   echo "ERROR: Code: Internal" >&2; exit 1 ;;
esac
SH
  # cp: --reflink=always is GNU's; the copy itself is real
  printf '#!/usr/bin/env bash\nargs=(); for a; do case "$a" in --reflink=*|--sparse=*) ;; *) args+=("$a") ;; esac; done\nexec /bin/cp "${args[@]}"\n' >"$RH/cp"
  chmod +x "$RH"/*
  rh() { touch "$RR/relay-up"; : >"$ORD"
    env E15_ROOT="$RR" E15_TEST_ROOT="$RR" E15_MANIFEST="$TMP/rh.md" E15_WARMUP_S=1 E15_WINDOW_S=1 \
      E15_MEMINFO="$TMP/nomeminfo" PATH="$RH:$STUB:$PATH" "$@" bash "$RIG/rung.sh" sbx 1 default >"$TMP/rh.out" 2>&1; }
  rh
  check "rung.sh: relay restarted after the old units stop, before the worker; probe, then driver" \
    "$(grep -v '^probe ' "$ORD" | tr '\n' ' ' | sed 's/ $//')|$(grep -c '^probe "workspace_key": *"_e15-attach-probe"' "$ORD")" "relay-stop relay-start worker-start driver|1"
  check "rung.sh: the attach probe ran between the worker start and the driver" \
    "$(awk '/^worker-start/{w=NR} /attach-probe/{p=NR} /^driver/{d=NR} END{print (w<p && p<d) ? "ordered" : "no"}' "$ORD")" "ordered"
  check "rung.sh: the relay restart touches E15's relay only (no sh-* unit)" "$(grep -c SHARED "$ORD")" "0"
  check "rung.sh: the attach check passed is logged" "$(grep -c 'relay attach check passed' "$TMP/rh.out")" "1"
  check "rung.sh: the probe key is one the worker's checkKey refuses (no run, no VM, no standby)" \
    "$(E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'eval "$(grep "^E15_PROBE_KEY=" "$1")"; [[ "$E15_PROBE_KEY" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] && echo valid || echo refused' _ "$RIG/rung.sh")/$(find "$RR/workspaces" -name '*attach-probe*' | grep -c .)" "refused/0"
  check "rung.sh: the probe passes on the worker's own refusal (proof it reached the worker)" "$(grep -c '^ExecError: invalid-workspace-key: ' "$RR"/runs/default/sbx/N1/attach-probe.log)" "1"
  rh GRPC_MODE=eof E15_ATTACH_TIMEOUT_S=3
  check "rung.sh: a failed attach check is a rig error (exit 1) and the driver never starts" \
    "$?/$(grep -c 'relay attach check failed: no Exec through e15-relay.service reached the worker within 3 s (rig error, not a measured result)' "$TMP/rh.out")/$(grep -c '^driver' "$ORD")" "1/1/0"
  check "rung.sh: a failed attach check writes no record" "$(find "$RR/runs" -name record.json -o -name params.json | grep -c .)" "0"
  rh GRPC_MODE=ran
  check "rung.sh: a worker that RUNS the probe (it would cost a VM) is refused" "$?/$(grep -c 'the worker ran the probe on workspace_key _e15-attach-probe instead of refusing it' "$TMP/rh.out")/$(grep -c '^driver' "$ORD")" "1/1/0"
  # M2: grpcurl resolved before the relay is touched
  mv "$RH/grpcurl" "$RH/grpcurl.off"
  NOG="$TMP/nogrpc"; mkdir -p "$NOG"
  for b in bash env sh python3 awk sed grep cat date mkdir rm cp mv chmod find head tail tr cut dirname basename sort mktemp sleep kill pkill du df ls touch seq wc od comm stat readlink xargs sha256sum shasum uname id hostname tee printf true false test; do
    w=$(command -v "$b" 2>/dev/null) && [ -n "$w" ] && [ "${w#/}" != "$w" ] && ln -sf "$w" "$NOG/$b"
  done
  touch "$RR/relay-up"; : >"$ORD"
  env -i HOME="$HOME" E15_ROOT="$RR" E15_TEST_ROOT="$RR" E15_MANIFEST="$TMP/rh.md" E15_WARMUP_S=1 E15_WINDOW_S=1 \
    E15_MEMINFO="$TMP/nomeminfo" PATH="$RH:$NOG" "$NOG/bash" "$RIG/rung.sh" sbx 1 default >"$TMP/rh.out" 2>&1
  check "rung.sh: no grpcurl -> refused before the relay is restarted, naming grpcurl" \
    "$?/$(grep -c 'no grpcurl on PATH .*the relay was not touched' "$TMP/rh.out")/$(grep -c '^relay-' "$ORD")" "1/1/0"
  mv "$RH/grpcurl.off" "$RH/grpcurl"
  rm -rf "$RR"
fi

# aws-prelim is unchanged where it matters: guards, PRESTATE, rootfs source, disk measurement
check "aws-prelim setup keeps the shared-host pause" "$(grep -c 'sctl stop "\$E15_HOST_WORKER"' "$RIG/setup.sh")/$(grep -c 'sudo -n docker stop "\$c"' "$RIG/setup.sh")" "1/1"
check "aws-prelim setup keeps the base snapshot loop mount" "$(grep -c 'sudo -n mount -o loop,ro "\$E15_BASE_SNAPSHOT/rootfs" "\$mnt"' "$RIG/setup.sh")" "1"
check "setup.sh: fresh-metal rootfs from build-rootfs.sh over the pinned image, digest checked" \
  "$(grep -c 'deploy/microvm/build-rootfs.sh" --out "\$tree" --image "\$E15_SANDBOX_IMAGE"' "$RIG/setup.sh")/$(grep -c '"\$E15_SANDBOX_IMAGE_DIGEST" | "\$E15_SANDBOX_IMAGE_AMD64_DIGEST") ;;' "$RIG/setup.sh")" "1/1"
check "setup.sh: fresh-metal kernel fetched by pinned sha256" "$(grep -c 'e15_fetch "\$E15_KERNEL_URL" "\$E15_KERNEL_SHA256" "\$KERNEL"' "$RIG/setup.sh")" "1"
check "setup.sh: one build-snapshot call, --guest-ram-mb 1024, kernel per profile" "$(grep -c -- '--kernel "\$KERNEL" --rootfs "\$tree"' "$RIG/setup.sh")/$(grep -c -- '--vmm firecracker --guest-ram-mb 1024' "$RIG/setup.sh")" "1/1"

# --- metal bring-up: the resident patch's stock suite in a private pid namespace ---------------
# moca's TestSweepOrphansFindsEveryLeftoverVMCgroup kills fake pids 4242-4244; on the 96-vCPU metal
# host those are kworkers (EPERM). fresh-metal runs apply.sh under unshare --pid as the login user.
check "setup.sh: fresh-metal apply.sh runs in a fresh pid namespace, as the login user" \
  "$(grep -c '\[ "\$METAL" = 1 \] && pidns=(sudo -n unshare --pid --fork --mount-proc' "$RIG/setup.sh")/$(grep -c 'setpriv "--reuid=\$(id -u)" "--regid=\$(id -g)" --init-groups' "$RIG/setup.sh")/$(grep -c '("\${pidns\[@\]}" env "\${GOENV_USER\[@\]}" MOCA_SRC=' "$RIG/setup.sh")" "1/1/1"
pidns_snip=$(sed -n '/^  pidns=()$/,/--init-groups env/p' "$RIG/setup.sh")
check "setup.sh: aws-prelim apply.sh runs as before (no pid namespace)" \
  "$(METAL=0 bash -c "$pidns_snip"$'\n''echo ${#pidns[@]}')/$(METAL=1 bash -c "$pidns_snip"$'\n''echo ${pidns[0]} ${pidns[2]} ${pidns[3]}')" "0/sudo unshare --pid"
check "setup.sh: fresh-metal template artifact hashed as root, empty hash refused" \
  "$(grep -c 'tsha=\$(sudo -n sha256sum "\$E15_P_TEMPLATE"' "$RIG/setup.sh")/$(grep -c '\[ -n "\$tsha" \] || die' "$RIG/setup.sh")/$(grep -c 'e15_artifact "\$E15_P_TEMPLATE_STAMP" "\$(sha256_of' "$RIG/setup.sh")" "1/1/0"

# --- E16: ladder.sh E15_LADDER_TAG / E15_K_MULT base, and experiments/e16-low-duty/rig/chain.sh stage dispatch ------
# chain.sh drives the real ladder.sh one rung at a time against the stub rung.sh above.
CHAIN="$RIG/../../e16/rig/chain.sh"
if [ -f "$CHAIN" ] && [ -f "$RIG/ladder.sh" ]; then
  printf '256=%s\n256-k2=%s\n256-s2=%s\n256-s2-k2=%s\n' '{"holds":true,"holds_abs":true,"unseeded_sessions":3}' "$ok" \
    '{"holds":true,"holds_abs":true,"unseeded_sessions":3}' "$ok" >"$TMP/recs"
  ladder_rungs fresh-metal "256"
  check "E16 ladder: E15_K_MULT unset -> k2 at x2 (E15 unchanged)" "$(grep -c '^256-k2 k=2 ' "$TMP/lcalls")" "1"
  rm -rf "$TROOT/runs"
  : >"$TMP/lcalls"
  E15_K_MULT=2 E15_LADDER_TAG=s2 E15_LADDER_RUNGS=256 E15_HOST_PROFILE=fresh-metal E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" \
    E15_RUNG="$STUBRUNG" RECS="$TMP/recs" LADDER_CALLS="$TMP/lcalls" PATH="$SPATH" E15_MANIFEST="$TMP/m.md" \
    bash "$RIG/ladder.sh" default sbx >"$TMP/l.out" 2>&1
  check "E16 ladder: E15_LADDER_TAG=s2 tags every rung dir, k2 doubles the caller's K (2 -> 4)" \
    "$?/$(cut -d' ' -f1,2 "$TMP/lcalls" | tr '\n' ' ')" "0/256-s2 k=2 256-s2-k2 k=4 "
  E15_LADDER_TAG=S-2 E15_LADDER_RUNGS=256 E15_HOST_PROFILE=fresh-metal E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" \
    E15_RUNG="$STUBRUNG" RECS="$TMP/recs" LADDER_CALLS="$TMP/lcalls" PATH="$SPATH" E15_MANIFEST="$TMP/m.md" \
    bash "$RIG/ladder.sh" default sbx >"$TMP/l.out" 2>&1
  check "E16 ladder: a bad E15_LADDER_TAG exits 2" "$?" "2"
  E15_LADDER_TAG=-s2 E15_LADDER_RUNGS=256 E15_HOST_PROFILE=fresh-metal E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" \
    E15_RUNG="$STUBRUNG" RECS="$TMP/recs" LADDER_CALLS="$TMP/lcalls" PATH="$SPATH" E15_MANIFEST="$TMP/m.md" \
    bash "$RIG/ladder.sh" default sbx >"$TMP/l.out" 2>&1
  check "E16 ladder: E15_LADDER_TAG starting with '-' exits 2 (stag-s2 style tags are fine)" "$?" "2"

  CLOG="$TMP/chainlogs"
  chain() { # chain STAGE [ARM] -> stdout in $TMP/c.out
    : >"$TMP/lcalls"
    E16_SRC="$RIG/../.." E16_RUNS="$TROOT/runs" E16_LOGDIR="$CLOG" E16_RUNG="$STUBRUNG" E16_DF_PATH="$TMP" \
      E16_NO_SENTINEL=1 E16_NO_PERF=1 E16_NO_ANALYSIS=1 E16_BASELINE="$TMP/stub-baseline.sh" \
      E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" RECS="$TMP/recs" LADDER_CALLS="$TMP/lcalls" PATH="$SPATH" \
      E15_MANIFEST="$TMP/m.md" bash "$CHAIN" "$@" >"$TMP/c.out" 2>&1
  }
  clj() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d.get(sys.argv[2], "absent"), separators=(",", ":")))' "$TROOT/runs/lowduty/$1/ladder.json" "$2"; }
  rl() { grep -E '^E16 [a-z-]+ [a-z-]+ N=' "$TMP/c.out" | grep -v -e SKIP -e bisect -e DISK | sed 's/^E16 [a-z-]* [a-z-]* //' | tr '\n' ';'; }
  printf '#!/usr/bin/env bash\necho "baseline $*" >>"$LADDER_CALLS"\nmkdir -p "$E15_ROOT/runs/$1/$2/N1"\necho "{\\"excess_p95_ms\\": 100.0, \\"overhead_ms\\": 5.0}" >"$E15_ROOT/runs/$1/$2/N1/baseline.json"\n' >"$TMP/stub-baseline.sh"

  rm -rf "$TROOT/runs" "$CLOG"
  chain bogus
  check "chain.sh: an unknown stage exits 2" "$?" "2"
  chain ladder-sbx nope
  check "chain.sh: an unknown arm exits 2" "$?" "2"
  chain baselines
  check "chain.sh baselines: both arms, in order" "$?/$(tr '\n' ';' <"$TMP/lcalls")" "0/baseline lowduty sbx;baseline lowduty resident-inf;"
  chain baselines
  check "chain.sh baselines: idempotent (skips existing baseline.json)" "$(wc -l <"$TMP/lcalls" | tr -d ' ')/$(grep -c 'SKIP' "$TMP/c.out")" "0/2"

  # sbx: 256, 384 hold, 512 fails -> extension not run; bisect 448 (holds)
  printf '256=%s\n384=%s\n512=%s\n448=%s\n' "$ok" "$ok" "$both_bad" "$ok" >"$TMP/recs"
  chain ladder-sbx
  check "chain.sh ladder-sbx: exit 0" "$?" "0"
  check "chain.sh ladder-sbx: rungs 256 384 512, then bisect 448" "$(cut -d' ' -f1 "$TMP/lcalls" | tr '\n' ' ')" "256 384 512 448 "
  check "chain.sh ladder-sbx: one line per rung, in the format" "$(rl)" \
    "N=256 holds=true holds_abs=true p95x=null reason=none;N=384 holds=true holds_abs=true p95x=null reason=none;N=512 holds=false holds_abs=false p95x=null reason=unknown;N=448 holds=true holds_abs=true p95x=null reason=none;"
  check "chain.sh ladder-sbx: assembled n_max 448, stopped_at 512" "$(clj sbx n_max)/$(clj sbx stopped_at)" "448/512"
  check "chain.sh ladder-sbx: gaps below n_max listed as assumed held" "$(clj sbx rungs_not_run_assumed_held)" "[1,8,16,24,32,40,48,56,64,80,96,128,160,192,320]"
  check "chain.sh ladder-sbx: each invocation's ladder.json kept aside" "$(find "$TROOT/runs/lowduty/sbx/e16" -name 'ladder-N*.json' | wc -l | tr -d ' ')" "4"
  chain ladder-sbx
  check "chain.sh ladder-sbx: idempotent (re-run runs nothing)" "$(wc -l <"$TMP/lcalls" | tr -d ' ')/$(grep -c SKIP "$TMP/c.out")/$(clj sbx n_max)" "0/4/448"

  # resident: 256 fails -> step down 192 (fails), 160 holds -> bisect 176? not on the ladder: none between 160 and 192
  rm -rf "$TROOT/runs/lowduty/resident-inf"
  printf '256=%s\n192=%s\n160=%s\n' "$both_bad" "$both_bad" "$ok" >"$TMP/recs"
  chain ladder-resident
  check "chain.sh ladder-resident: 256 fails -> step down 192, 160 (descending)" "$?/$(cut -d' ' -f1 "$TMP/lcalls" | tr '\n' ' ')" "0/256 192 160 "
  check "chain.sh ladder-resident: n_max 160, stopped_at 192" "$(clj resident-inf n_max)/$(clj resident-inf stopped_at)" "160/192"

  # seeds: sbx deciding rungs 448 (s2 holds) and 512 (s2 holds -> disagree -> s3 fails)
  printf '448-s2=%s\n512-s2=%s\n512-s3=%s\n' "$ok" "$ok" "$both_bad" >"$TMP/recs"
  chain seeds sbx
  check "chain.sh seeds: s2 on both deciding rungs, s3 where they disagree" "$?/$(cut -d' ' -f1 "$TMP/lcalls" | tr '\n' ' ')" "0/448-s2 512-s2 512-s3 "
  check "chain.sh seeds: majority keeps 512 failed, n_max 448" "$(clj sbx n_max)/$(clj sbx stopped_at)/$(clj sbx seeds_undecided)" "448/512/[]"
  check "chain.sh seeds: the seed run had E15_SEED... dirs tagged s2" "$([ -f "$TROOT/runs/lowduty/sbx/N448-s2/record.json" ] && echo yes)" "yes"

  # a rung.sh failure inside the ladder is a rig error: exit 1, no row written
  rm -rf "$TROOT/runs/lowduty/sbx"
  printf '256=%s\n' "$ok" >"$TMP/recs"
  chain ladder-sbx
  check "chain.sh: a rig error stops the stage (exit 1, RIG_ERROR line, no row for 384)" \
    "$?/$(grep -c 'N=384 RIG_ERROR' "$TMP/c.out")/$([ -f "$TROOT/runs/lowduty/sbx/e16/N384.json" ] && echo yes || echo no)" "1/1/no"

  # cal / long-rung / control: one rung each with their tags, warm-ups, windows and K
  printf '256-cal=%s\n256-long=%s\n768-a2=%s\n' "$ok" "$ok" "$ok" >"$TMP/recs"
  chain cal
  check "chain.sh cal: N=256 tag cal per arm, K x2, warm-up 1200" "$(cut -d' ' -f1-3 "$TMP/lcalls" | tr '\n' ';')" "256-cal k=2 w=1200;256-cal k=2 w=1200;"
  chain long-rung
  check "chain.sh long-rung: resident-inf N=256 tag long, warm-up 600, K x3" "$(cut -d' ' -f1-3 "$TMP/lcalls" | tr '\n' ';')/$([ -f "$TROOT/runs/lowduty/resident-inf/N256-long/record.json" ] && echo yes)" "256-long k=3 w=600;/yes"
  chain long-rung
  check "chain.sh long-rung: idempotent" "$(wc -l <"$TMP/lcalls" | tr -d ' ')" "0"
  chain control
  check "chain.sh control: N=768 tag a2" "$(cut -d' ' -f1 "$TMP/lcalls")" "768-a2"
  E16_SRC="$RIG/../.." E16_RUNS="$TROOT/runs" E16_LOGDIR="$CLOG" E16_RUNG="$STUBRUNG" E16_DF_PATH="$TMP" E16_NO_SENTINEL=1 \
    E16_NO_PERF=1 E16_NO_ANALYSIS=1 E16_WS_DELTA0_MB=999999 E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" RECS="$TMP/recs" \
    LADDER_CALLS="$TMP/lcalls" PATH="$SPATH" E15_MANIFEST="$TMP/m.md" bash "$CHAIN" ladder-sbx >"$TMP/c.out" 2>&1
  check "chain.sh: the disk check stops a rung that does not fit" "$?/$(grep -c 'DISK need' "$TMP/c.out")" "1/1"
  # rungs above 1024: memory headroom check (idle host required; projection logged)
  rm -rf "$TROOT/runs/lowduty/resident-inf"
  mkdir -p "$TROOT/runs/lowduty/resident-inf/e16"
  for n in 256 384 512 640 768 896 1024; do
    printf '{"n":%s,"seed":1,"holds":true,"holds_abs":true,"dir":"x"}\n' "$n" >"$TROOT/runs/lowduty/resident-inf/e16/N$n.json"
  done
  printf 'MemAvailable:   104857600 kB\n' >"$TMP/meminfo"
  printf '1280=%s\n' "$ok" >"$TMP/recs"
  E16_MEMINFO="$TMP/meminfo" chain ladder-resident
  check "chain.sh: N=1280 refused on a host that is not idle (100 GiB available)" "$?/$(grep -c 'N=1280 MEMORY host not idle' "$TMP/c.out")/$(wc -l <"$TMP/lcalls" | tr -d ' ')" "1/1/0"
  printf 'MemAvailable:   377487360 kB\n' >"$TMP/meminfo"
  E16_MEMINFO="$TMP/meminfo" chain ladder-resident
  # post-seal SBX extension: only when resident's n_max >= 1024
  python3 -c 'import json,sys; json.dump({"n_max": 896}, open(sys.argv[1], "w"))' "$TROOT/runs/lowduty/resident-inf/ladder.json.t"
  check "chain.sh: N=1280 runs on an idle host after the memory check, then extends to 1536" "$(grep -c 'N=1280 memory check: MemAvailable 360 GiB' "$TMP/c.out")/$(cut -d' ' -f1 "$TMP/lcalls" | tr '\n' ' ')" "1/1280 1536 "
  mv "$TROOT/runs/lowduty/resident-inf/ladder.json" "$TROOT/runs/lowduty/resident-inf/ladder.json.keep"
  mv "$TROOT/runs/lowduty/resident-inf/ladder.json.t" "$TROOT/runs/lowduty/resident-inf/ladder.json"
  chain ladder-sbx-ext
  check "chain.sh ladder-sbx-ext: skipped when resident n_max < 1024" "$?/$(grep -c 'ladder-sbx-ext SKIP: resident-inf n_max=896' "$TMP/c.out")/$(wc -l <"$TMP/lcalls" | tr -d ' ')" "0/1/0"
  python3 -c 'import json,sys; json.dump({"n_max": 1024}, open(sys.argv[1], "w"))' "$TROOT/runs/lowduty/resident-inf/ladder.json"
  rm -rf "$TROOT/runs/lowduty/sbx"
  mkdir -p "$TROOT/runs/lowduty/sbx/e16"
  printf '{"n":1024,"seed":1,"holds":true,"holds_abs":true,"dir":"x"}\n' >"$TROOT/runs/lowduty/sbx/e16/N1024.json"
  printf '{"n_max": 1024}\n' >"$TROOT/runs/lowduty/sbx/ladder.json"
  printf '1280=%s\n1536=%s\n' "$ok" "$both_bad" >"$TMP/recs"
  E16_MEMINFO="$TMP/meminfo" chain ladder-sbx-ext
  check "chain.sh ladder-sbx-ext: runs 1280, 1536 when resident n_max >= 1024" "$?/$(cut -d' ' -f1 "$TMP/lcalls" | tr '\n' ' ')" "0/1280 1536 "
  check "chain.sh ladder-sbx-ext: sealed ladder kept, extension labelled, rows marked" \
    "$([ -f "$TROOT/runs/lowduty/sbx/ladder.sealed.json" ] && echo kept)/$(clj sbx n_max)/$(clj sbx stopped_at)/$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["post_seal_extension"]["sealed"])' "$TROOT/runs/lowduty/sbx/ladder.json")/$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("post_seal_extension"))' "$TROOT/runs/lowduty/sbx/e16/N1280.json")" "kept/1280/1536/False/True"
  # sealed resident extension from an assembled n_max of 1024 (seeds lifted it)
  rm -rf "$TROOT/runs/lowduty/resident-inf"
  mkdir -p "$TROOT/runs/lowduty/resident-inf/e16"
  for n in 896 1024; do printf '{"n":%s,"seed":1,"holds":true,"holds_abs":true,"dir":"x"}\n' "$n" >"$TROOT/runs/lowduty/resident-inf/e16/N$n.json"; done
  python3 -c 'import json,sys; json.dump({"n_max": 1024}, open(sys.argv[1], "w"))' "$TROOT/runs/lowduty/resident-inf/ladder.json"
  printf '1280=%s\n1536=%s\n' "$ok" "$both_bad" >"$TMP/recs"
  E16_MEMINFO="$TMP/meminfo" chain ladder-resident-ext
  check "chain.sh ladder-resident-ext: 1280, 1536 from n_max 1024; assembled n_max 1280, stopped 1536" \
    "$?/$(cut -d' ' -f1 "$TMP/lcalls" | tr '\n' ' ')/$(clj resident-inf n_max)/$(clj resident-inf stopped_at)" "0/1280 1536 /1280/1536"
  python3 -c 'import json,sys; json.dump({"n_max": 896}, open(sys.argv[1], "w"))' "$TROOT/runs/lowduty/resident-inf/ladder.json"
  chain ladder-resident-ext
  check "chain.sh ladder-resident-ext: skipped unless the sealed n_max is 1024" "$?/$(wc -l <"$TMP/lcalls" | tr -d ' ')/$(grep -c 'ladder-resident-ext SKIP' "$TMP/c.out")" "0/0/1"
  # stag (supplementary): validity per rung (stub validator), seeds 1+2 at 896 and 1024, s3 on
  # disagreement, one re-run of an invalid rung, then resident 1280/1536 and SBX 1280/1536 (postseal)
  VSTUB="$TMP/stub-valid.py"
  cat >"$VSTUB" <<'PY'
import json, os, sys
d = [a for a in sys.argv[1:] if not a.startswith("--")][0]
bad = os.path.basename(d) in os.environ.get("INVALID_DIRS", "").split()
json.dump({"valid": not bad, "reasons": ["egress_wedged=1"] if bad else []}, open(os.path.join(d, "stag_valid.json"), "w"))
print("invalid egress_wedged=1" if bad else "valid")
PY
  stag() { E16_VALID_PY="$VSTUB" E16_MEMINFO="$TMP/meminfo" chain stag; }
  printf '{"n_max": 896, "sealed": "marker"}\n' >"$TROOT/runs/lowduty/resident-inf/ladder.json"
  rm -rf "$TROOT/runs/lowduty/resident-inf/e16-supp" "$TROOT/runs/lowduty/sbx/e16-supp"
  printf '896-stag=%s\n896-stag-s2=%s\n1024-stag=%s\n1024-stag-r=%s\n1024-stag-s2=%s\n1024-stag-s3=%s\n1280-stag=%s\n1280-postseal=%s\n1536-postseal=%s\n' \
    "$ok" "$ok" "$ok" "$ok" "$both_bad" "$ok" "$both_bad" "$ok" "$both_bad" >"$TMP/recs"
  INVALID_DIRS="N1024-stag" stag
  check "chain.sh stag: 896 s1 s2; 1024 s1 invalid -> re-run once (-r); s2 disagrees -> s3; then 1280; SBX 1280, 1536" \
    "$?/$(cut -d' ' -f1 "$TMP/lcalls" | tr '\n' ' ')" "0/896-stag 896-stag-s2 1024-stag 1024-stag-r 1024-stag-s2 1024-stag-s3 1280-stag 1280-postseal 1536-postseal "
  check "chain.sh stag: seeds and the deferral reach the rungs" "$(grep -c '^1024-stag-s3 ' "$TMP/lcalls")/$(grep -c 'PAIR resident-inf 896=true 1024=true' "$TMP/c.out")" "1/1"
  check "chain.sh stag: sealed ladder.json kept; rows in e16-supp only; invalid row not counted" \
    "$(clj resident-inf sealed)/$([ -f "$TROOT/runs/lowduty/resident-inf/e16/N1024-stag.json" ] && echo leaked || echo clean)/$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["verdicts"]["1024"]["seeds"], d["verdicts"]["1024"]["holds"])' "$TROOT/runs/lowduty/resident-inf/ladder-supp.json")" '"marker"/clean/[1, 2, 3] True'
  rm -rf "$TROOT/runs/lowduty/resident-inf/e16-supp" "$TROOT/runs/lowduty/sbx/e16-supp"
  printf '896-stag=%s\n896-stag-r=%s\n' "$ok" "$ok" >"$TMP/recs"
  INVALID_DIRS="N896-stag N896-stag-r" stag
  check "chain.sh stag: invalid twice stops the stage (exit 1, nothing further)" \
    "$?/$(cut -d' ' -f1 "$TMP/lcalls" | tr '\n' ' ')/$(grep -c 'INVALID again' "$TMP/c.out")" "1/896-stag 896-stag-r /1"
  rm -rf "$TROOT/runs/lowduty/resident-inf/e16-supp" "$TROOT/runs/lowduty/sbx/e16-supp"
  printf '896-stag=%s\n896-stag-s2=%s\n1024-stag=%s\n1024-stag-s2=%s\n' "$ok" "$ok" "$both_bad" "$both_bad" >"$TMP/recs"
  stag
  check "chain.sh stag: 1024 failing on both seeds stops (no 1280, no SBX)" \
    "$?/$(cut -d' ' -f1 "$TMP/lcalls" | tr '\n' ' ')/$(grep -c 'fails with the deferral too' "$TMP/c.out")" "0/896-stag 896-stag-s2 1024-stag 1024-stag-s2 /1"
fi

# E16 supplementary: E15_END_SESSION_DEFER (fresh-metal only, resident arms only, default off)
endflag_snip=$(sed -n '/^end_flag=()$/,/^fi$/p' "$RIG/rung.sh")
for spec in "fresh-metal resident-inf 1:--end-session-exec --end-session-defer --end-session-rate 50" \
  "fresh-metal resident-inf 0:--end-session-exec" "aws-prelim resident-inf 1:--end-session-exec" "fresh-metal sbx 1:"; do
  read -r p_ a_ d_ <<<"${spec%%:*}"
  got=$(E15_HOST_PROFILE=$p_ ARM=$a_ E15_END_SESSION_DEFER=$d_ bash -c "$endflag_snip"$'\n''echo "${end_flag[*]}"')
  check "rung.sh end-session defer: profile=$p_ arm=$a_ E15_END_SESSION_DEFER=$d_" "$got" "${spec#*:}"
done
check "setup.sh: fresh-metal keeps e15-driver, builds a changed driver source as e15-driver-defer" \
  "$(grep -c 'go build -o "\$E15_BIN/e15-driver-defer"' "$RIG/setup.sh")/$(grep -c '\[ -x "\$E15_BIN/e15-driver" \] && ! stamp_ok go-driver' "$RIG/setup.sh")" "1/1"
check "rung.sh: E15_END_SESSION_DEFER runs e15-driver-defer, the baseline is matched on the stock driver" \
  "$(grep -c 'DRIVER=\$E15_BIN/e15-driver-defer' "$RIG/rung.sh")/$(grep -c 'drv_sha=\$(sha_of "\$BASE_DRIVER")' "$RIG/rung.sh")" "1/1"
check "rung.sh: params.json records end_session_defer only when on" "$(grep -c 'if "\$END_DEFER" == "1" else {}' "$RIG/rung.sh")" "1"

# --- E17 Task 3: points pycache*, arms lease-30/lease-120 (fresh-metal only) -----------------
# The pre-existing points and arms are compared byte for byte against golden dumps written from
# the tree before E17 (tests/golden/, dump.sh); the new ones are checked for their exact values.
GOLD="$RIG/tests/golden"
gdump() { # PROFILE BODY: lib.sh, points.sh and golden/dump.sh sourced under the test root
  E15_HOST_PROFILE="$1" E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; source "$2"; source "$3"; eval "$4"' \
    _ "$RIG/lib.sh" "$RIG/points.sh" "$GOLD/dump.sh" "$2" 2>&1
}
gsame() { # GOLDEN: "same" when $TMP/gold.out equals it, else the first diff lines and "differs"
  if cmp -s "$TMP/gold.out" "$1"; then echo same; else
    diff "$1" "$TMP/gold.out" | head -5
    echo differs
  fi
}
rm -rf "$TROOT/state"
for prof in aws-prelim fresh-metal; do
  for p in default lowduty mem512; do
    gdump "$prof" "e15_golden_point $p" >"$TMP/gold.out"
    check "E17 golden: e15_point $p on $prof is byte-identical to before" "$(gsame "$GOLD/point-$p.txt")" "same"
  done
  gdump "$prof" "e15_golden_arms '$TMP/gold.env'" >"$TMP/gold.out"
  check "E17 golden: warm-up, binary and worker env of sbx resident-inf resident-300 control on $prof unchanged" \
    "$(gsame "$GOLD/arms.$prof.txt")" "same"
done
check "E17: E15_ARMS on aws-prelim unchanged (no lease arms)" "$(gdump aws-prelim 'echo ${E15_ARMS[*]}')" "sbx resident-inf resident-300 control"
check "E17: E15_ARMS on fresh-metal: the E15 arms in order, then lease-30 lease-120" "$(gdump fresh-metal 'echo ${E15_ARMS[*]}')" \
  "sbx resident-inf resident-300 control lease-30 lease-120"
check "E17: aws-prelim refuses the lease arms" "$(gdump aws-prelim 'e15_is_arm lease-30 || echo no30; e15_is_arm lease-120 || echo no120' | tr '\n' ' ')" "no30 no120 "

# the pycache points: fresh-metal only, the brief's exact values
fpt() { # PROFILE POINT
  E15_HOST_PROFILE="$1" E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; source "$2"; e15_point "$3" || { echo refused; exit 0; }
    echo "$E15_P_ARMS|$E15_P_CORPUS|${E15_P_LIBRARY#"$E15_ROOT"/}|${E15_P_TEMPLATE#"$E15_ROOT"/}|$E15_P_TEMPLATE_STAMP|$E15_P_IMAGE_MB|$E15_P_DATASET_MIB|$E15_P_DATASET_SEED|$E15_P_SCAN_CLASSES|$E15_P_SCAN_CMD|$E15_P_FALLBACK|${E15_P_PROBE_CAP_MS-unset}"' \
    _ "$RIG/lib.sh" "$RIG/points.sh" "$2" 2>&1
}
parms="sbx resident-300 lease-30 lease-120"
check "E17 points: pycache" "$(fpt fresh-metal pycache)" "$parms|pycache|src/e17/workload/library.json|template-pycache-d256/workspace.img|template-pycache-d256|1536|256|1|||0|120000"
check "E17 points: pycache-low (its own corpus, the D=256 template)" "$(fpt fresh-metal pycache-low)" "$parms|pycache-low|src/e17/workload/library.json|template-pycache-d256/workspace.img|template-pycache-d256|1536|256|1|||0|120000"
check "E17 points: pycache-d64 (pycache corpus, D=64 template)" "$(fpt fresh-metal pycache-d64)" "$parms|pycache|src/e17/workload/library.json|template-pycache-d64/workspace.img|template-pycache-d64|1536|64|1|||0|120000"
check "E17 points: pycache-d768 (pycache corpus, D=768 template)" "$(fpt fresh-metal pycache-d768)" "$parms|pycache|src/e17/workload/library.json|template-pycache-d768/workspace.img|template-pycache-d768|1536|768|1|||0|120000"
check "E17 points: the library is /srv/e15/src/e17/workload/library.json on the rig root" \
  "$(E15_HOST_PROFILE=fresh-metal E15_ROOT=/srv/e15 bash -c 'source "$1"; source "$2"; e15_point pycache; echo "$E15_P_LIBRARY $E15_P_TEMPLATE"' _ "$RIG/lib.sh" "$RIG/points.sh" 2>&1)" \
  "/srv/e15/src/e17/workload/library.json /srv/e15/template-pycache-d256/workspace.img"
for p in pycache pycache-low pycache-d64 pycache-d768; do
  check "E17 points: $p refused on aws-prelim" "$(fpt aws-prelim "$p")" "refused"
done
check "E17 points: e15_point_arms pycache (fresh-metal)" "$(gdump fresh-metal 'e15_point_arms pycache')" "$parms"
fsig() { E15_HOST_PROFILE=fresh-metal E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; source "$2"; e15_point_sig "$3"' _ "$RIG/lib.sh" "$RIG/points.sh" "$1"; }
check "E17 point_sig: the four pycache points and default, lowduty, mem512 all apart" \
  "$(for p in pycache pycache-low pycache-d64 pycache-d768 default lowduty mem512; do fsig "$p"; echo; done | sort -u | grep -cE '^[0-9a-f]{64}$')" "7"
check "E17 points: setup.sh's template list unchanged (pycache templates are bringup.sh's)" "$(gdump fresh-metal 'e15_templates' | tr '\n' ' ')" "default mem512 "

# the lease arms: the resident binary, standby depth 0, E15_RESIDENT=1 with their idle, warm-up 1200
lenv() { E15_HOST_PROFILE=fresh-metal E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; worker_env "$3" "$2"; grep -E "^(E15_RESIDENT|E15_RESIDENT_IDLE_S|SH_STANDBY_DEPTH)=" "$2" | tr "\n" " "' _ "$RIG/lib.sh" "$TMP/wenv" "$1" 2>&1; }
check "E17 worker_env lease-30" "$(lenv lease-30)" "SH_STANDBY_DEPTH=0 E15_RESIDENT=1 E15_RESIDENT_IDLE_S=30 "
check "E17 worker_env lease-120" "$(lenv lease-120)" "SH_STANDBY_DEPTH=0 E15_RESIDENT=1 E15_RESIDENT_IDLE_S=120 "
check "E17 worker_env: lease-30 equals resident-300 but for the idle line" \
  "$(diff <(E15_HOST_PROFILE=fresh-metal E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; worker_env resident-300 "$2"; cat "$2"' _ "$RIG/lib.sh" "$TMP/wa") \
    <(E15_HOST_PROFILE=fresh-metal E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; worker_env lease-30 "$2"; cat "$2"' _ "$RIG/lib.sh" "$TMP/wb") | grep -c '^[<>]')" "2"
check "E17 worker_bin: lease-30, lease-120 run the resident binary" \
  "$(gdump fresh-metal 'worker_bin lease-30; worker_bin lease-120' | sed "s#^$TROOT/##" | tr '\n' ' ')" "bin/microvm-worker-resident bin/microvm-worker-resident "
check "E17 warm-up: lease-30, lease-120 1200 s on fresh-metal" "$(gdump fresh-metal 'e15_default_warmup lease-30; e15_default_warmup lease-120' | tr '\n' ' ')" "1200 1200 "

# rung.sh: end-session Exec for the lease arms, the record's binary, patch sha and end_session_exec
for spec in "fresh-metal lease-30 0:--end-session-exec" "fresh-metal lease-120 0:--end-session-exec" \
  "fresh-metal lease-30 1:--end-session-exec --end-session-defer --end-session-rate 50"; do
  read -r p_ a_ d_ <<<"${spec%%:*}"
  got=$(E15_HOST_PROFILE=$p_ ARM=$a_ E15_END_SESSION_DEFER=$d_ bash -c "$endflag_snip"$'\n''echo "${end_flag[*]}"')
  check "E17 rung.sh end flag: arm=$a_ E15_END_SESSION_DEFER=$d_" "$got" "${spec#*:}"
done
check "E17 rung.sh: the record maps lease-30, lease-120 to the resident binary" \
  "$(grep -c '"lease-30": "\$E15_BIN/microvm-worker-resident", "lease-120": "\$E15_BIN/microvm-worker-resident"' "$RIG/rung.sh")" "1"
check "E17 rung.sh: end_session_exec true for the lease arms" \
  "$(grep -c '"end_session_exec": arm in ("resident-inf", "resident-300", "lease-30", "lease-120"),' "$RIG/rung.sh")" "1"
check "E17 rung.sh: resident_patch_sha256 recorded for the lease arms" \
  "$(grep -c 'if arm.startswith(("resident", "lease-")) else None' "$RIG/rung.sh")" "1"
check "E17 rung.sh: usage names the lease arms and pycache points" \
  "$(grep -c '^#   ARM    sbx | resident-inf | resident-300 | control | lease-30 | lease-120' "$RIG/rung.sh")/$(grep -c 'pycache | pycache-low | pycache-d64 | pycache-d768' "$RIG/rung.sh")" "1/1"
: >"$CALLS"
E15_HOST_PROFILE=fresh-metal E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" PATH="$SPATH" E15_MANIFEST="$TMP/m.md" bash "$RIG/rung.sh" lease-30 8 default >"$TMP/r.out" 2>&1
check "E17 rung.sh: default does not run lease-30 (exit 2)" "$?/$(grep -c 'does not run ARM lease-30' "$TMP/r.out")" "2/1"
E15_HOST_PROFILE=fresh-metal E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" PATH="$SPATH" E15_MANIFEST="$TMP/m.md" bash "$RIG/rung.sh" resident-inf 8 pycache >"$TMP/r.out" 2>&1
check "E17 rung.sh: pycache does not run resident-inf (exit 2)" "$?/$(grep -c 'does not run ARM resident-inf' "$TMP/r.out")" "2/1"
E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" PATH="$SPATH" E15_MANIFEST="$TMP/m.md" bash "$RIG/rung.sh" lease-30 8 pycache >"$TMP/r.out" 2>&1
check "E17 rung.sh: aws-prelim refuses lease-30 (unknown ARM, exit 2)" "$?/$(grep -c "unknown ARM 'lease-30'" "$TMP/r.out")" "2/1"
check "E17 rung.sh: none of these touched systemctl, sudo or podman" "$(wc -l <"$CALLS" | tr -d ' ')" "0"

# setup.sh: the template loop and the lowduty block are byte-identical to before (sha256 of the
# sed ranges at 6364d0f); the pycache corpora block is fresh-metal only, checked and recorded
check "E17 setup.sh: template loop (step 8) byte-identical" \
  "$(sed -n '/^# --- 8. workspace templates/,/^done < <(e15_templates)$/p' "$RIG/setup.sh" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')" \
  "cef55bb0313966edadff8bd0d8f8c54ad9d9be8b56738e4a60326f4547982563"
check "E17 setup.sh: lowduty block (step 8a) byte-identical" \
  "$(sed -n '/^# --- 8a. the lowduty corpus/,/^fi$/p' "$RIG/setup.sh" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')" \
  "cd7034e7629fd3a102a72d458ec6b08bc870a7b0d41610a4e691f840b31347d0"
pcsnip=$(sed -n '/^# --- 8c. the pycache corpora/,/^# end pycache corpora$/p' "$RIG/setup.sh")
check "E17 setup.sh: the pycache corpora block exists" "$([ -n "$pcsnip" ] && echo present || echo missing)" "present"
pcrun() { # METAL: run the block under the test root; prints rc, then state/artifacts
  rm -rf "$TROOT/state/artifacts"
  E15_HOST_PROFILE=fresh-metal E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" E15_MANIFEST="$TMP/pcm.md" METAL=$1 bash -c 'source "$1"; set -e; eval "$2"' \
    _ "$RIG/lib.sh" "$pcsnip" >"$TMP/pc.out" 2>&1
  echo "rc=$?"
  sed "s#$TROOT/##g" "$TROOT/state/artifacts" 2>/dev/null | cut -d' ' -f1,3
}
mkpc() { # POINT [WRONG]: stage a corpus and a report whose corpus_sha256 matches (or not)
  mkdir -p "$TROOT/corpora/$1"
  printf '{"session": "%s"}\n' "$1" >"$TROOT/corpora/$1/corpus.jsonl"
  python3 -c 'import hashlib,json,sys; d=open(sys.argv[1],"rb").read(); json.dump({"corpus_sha256": sys.argv[2] or hashlib.sha256(d).hexdigest()}, open(sys.argv[3],"w"))' \
    "$TROOT/corpora/$1/corpus.jsonl" "${2:-}" "$TROOT/corpora/$1/corpus-report.json"
}
rm -rf "$TROOT/corpora/pycache" "$TROOT/corpora/pycache-low"
check "E17 setup.sh pycache corpora: none staged -> notes only, no artifact" "$(pcrun 1 | tr '\n' ' ')/$(grep -c 'note: no .*pycache.*/corpus.jsonl staged' "$TMP/pc.out")" "rc=0 /2"
mkpc pycache
mkpc pycache-low
check "E17 setup.sh pycache corpora: both staged -> both recorded" "$(pcrun 1 | tr '\n' ' ')" \
  "rc=0 corpus-pycache corpora/pycache/corpus.jsonl corpus-pycache-low corpora/pycache-low/corpus.jsonl "
check "E17 setup.sh pycache corpora: aws-prelim (METAL=0) does nothing" "$(pcrun 0 | tr '\n' ' ')/$(wc -c <"$TMP/pc.out" | tr -d ' ')" "rc=0 /0"
mkpc pycache-low 0000000000000000000000000000000000000000000000000000000000000000
check "E17 setup.sh pycache corpora: a sha256 mismatch dies" "$(pcrun 1 | head -1)/$(grep -c 'is not its report.s corpus_sha256' "$TMP/pc.out")" "rc=1/1"
rm -f "$TROOT/corpora/pycache-low/corpus-report.json"
check "E17 setup.sh pycache corpora: corpus without a report dies" "$(pcrun 1 | head -1)/$(grep -c 'has corpus.jsonl but no corpus-report.json' "$TMP/pc.out")" "rc=1/1"
rm -rf "$TROOT/corpora/pycache" "$TROOT/corpora/pycache-low" "$TROOT/state/artifacts"

# experiments/e17-lease/rig/sync.sh: the laptop sync (never run by the tests: it reaches the rig)
SYNC17="$RIG/../../../experiments/e17-lease/rig/sync.sh"
if [ -f "$SYNC17" ]; then
  bash -n "$SYNC17" 2>"$TMP/n.out"
  check "bash -n e17/rig/sync.sh" "$([ -s "$TMP/n.out" ] && echo FAIL || echo clean)" "clean"
  if [ -n "$SC" ]; then
    "$SC" -x "$SYNC17" >"$TMP/sc.out" 2>&1
    check "shellcheck e17/rig/sync.sh" "$([ -s "$TMP/sc.out" ] && echo FAIL || echo clean)" "clean"
    [ -s "$TMP/sc.out" ] && sed 's/^/    /' "$TMP/sc.out" | head -20
  fi
  check "e17 sync.sh: rsyncs e15/, e16/, e17/ with e16's excludes" \
    "$(grep -c '^X=(--exclude results/ --exclude predictions.json --exclude predictions-metal.json --exclude __pycache__ --exclude .pytest_cache)$' "$SYNC17")/$(grep -cE 'rsync -a --delete "\$\{X\[@\]\}" -e "\$S" experiments/(e15-session-density|e16-low-duty|e17-lease)/ "\$H:/srv/e15/src/(e15|e16|e17)/"' "$SYNC17")" "1/3"
  check "e17 sync.sh: corpora to /srv/e15/corpora/<point>/, wheels to /srv/e15/wheels-pycache/ (not E15's wheels)" \
    "$(grep -c '"\$H:/srv/e15/corpora/\$p/"' "$SYNC17")/$(grep -c '"\$H:/srv/e15/wheels-pycache/"' "$SYNC17")/$(grep -c '/srv/e15/wheels/' "$SYNC17")" "1/1/0"
  check "e17 sync.sh: defaults E17_CORPORA, E17_WHEELS" \
    "$(grep -c 'E17_CORPORA:-/tmp/kagenti/e17-corpora' "$SYNC17")/$(grep -c 'E17_WHEELS:-/tmp/kagenti/e17-wheels-probe' "$SYNC17")" "1/1"
else
  check "e17/rig/sync.sh exists" "missing" "present"
fi


# --- E17 Task 5: experiments/e17-lease/rig bringup.sh, gen_corpora.sh, smoke.sh -----------------------------------
# bringup.sh runs against a staged test root with every host tool a stub: sudo runs the command,
# mount/umount/mountpoint keep a mount table in a file, debugfs reads the fake image (the stub
# builder writes its BUILD lines as the image), stat/findmnt/xfs_info report one XFS reflink=1
# device, cp drops --reflink. The builder is a stub that logs each call and refuses an existing
# OUT_IMG, as the real one does.
E17D="$RIG/../../../experiments/e17-lease"
for s in rig/bringup.sh rig/smoke.sh rig/gen_corpora.sh rig/reprobe.sh; do
  if [ ! -f "$E17D/$s" ]; then
    check "e17/$s exists" "missing" "present"
    continue
  fi
  bash -n "$E17D/$s" 2>"$TMP/n.out"
  check "bash -n e17/$s" "$([ -s "$TMP/n.out" ] && echo FAIL || echo clean)" "clean"
  if [ -n "$SC" ]; then
    "$SC" -x "$E17D/$s" >"$TMP/sc.out" 2>&1
    check "shellcheck e17/$s" "$([ -s "$TMP/sc.out" ] && echo FAIL || echo clean)" "clean"
    [ -s "$TMP/sc.out" ] && sed 's/^/    /' "$TMP/sc.out" | head -20
  fi
done
if [ -f "$E17D/rig/bringup.sh" ]; then
  BU="$TMP/bustub"
  rm -rf "$BU"
  mkdir -p "$BU"
  printf '#!/usr/bin/env bash\n[ "$1" = -n ] && shift\n[ $# -eq 0 ] && exit 0\nexec "$@"\n' >"$BU/sudo"
  # mount -o OPTS SRC MNT: one "MNT SRC OPTS" line in $BU_MOUNTS; umount [-d] MNT drops it
  printf '#!/usr/bin/env bash\necho "mount $*" >>"$BU_LOG"\necho "$4 $3 $2" >>"$BU_MOUNTS"\n' >"$BU/mount"
  # umount [-d] MNT drops MNT's line, unless BU_UMOUNT_STUCK=1 (the mount survives, umount exits 32)
  printf '#!/usr/bin/env bash\necho "umount $*" >>"$BU_LOG"\n[ "${BU_UMOUNT_STUCK:-0}" = 1 ] && exit 32\nm=${!#}\ngrep -v "^$m " "$BU_MOUNTS" >"$BU_MOUNTS.n" || true\nmv "$BU_MOUNTS.n" "$BU_MOUNTS"\n' >"$BU/umount"
  # systemctl is-active e15-worker.service: active when BU_WORKER_UP=1 (a rung is running)
  printf '#!/usr/bin/env bash\ncase "$1 ${!#}" in "is-active e15-worker.service") [ "${BU_WORKER_UP:-0}" = 1 ] ;; *) exit 1 ;; esac\n' >"$BU/systemctl"
  printf '#!/usr/bin/env bash\ngrep -q "^${!#} " "$BU_MOUNTS"\n' >"$BU/mountpoint"
  printf '#!/usr/bin/env bash\ncat "$3"\n' >"$BU/debugfs"
  printf '#!/usr/bin/env bash\necho 100\n' >"$BU/stat"
  printf '#!/usr/bin/env bash\ncase "$*" in *FSTYPE*) echo xfs ;; *TARGET*) echo /srv/e15 ;; *SOURCE*) echo /dev/nvme1n1 ;; esac\n' >"$BU/findmnt"
  printf '#!/usr/bin/env bash\necho "meta-data=$1 reflink=1"\n' >"$BU/xfs_info"
  printf '#!/usr/bin/env bash\nargs=(); for a; do [ "$a" = --reflink=always ] || args+=("$a"); done\nexec /bin/cp "${args[@]}"\n' >"$BU/cp"
  chmod +x "$BU"/*
  # The stub builder (bash 3.2-safe: it runs under e15_path's /bin/bash on a laptop).
  cat >"$TMP/stub-builder.sh" <<'SH'
#!/usr/bin/env bash
# stub build_pycache_workspace.sh
while [ $# -gt 1 ]; do
  case "$1" in
  --image-mb) M=$2; shift 2 ;;
  --dataset-mib) D=$2; shift 2 ;;
  --dataset-seed) S=$2; shift 2 ;;
  --wheels) WH=$2; shift 2 ;;
  --rootfs-tree) R=$2; shift 2 ;;
  *) break ;;
  esac
done
OUT=$1
echo "build D=$D S=$S M=$M wheels=$WH rootfs=$R out=$OUT mounted=$(grep -c "^$R " "$BU_MOUNTS")" >>"$BU_BUILDS"
[ "${BU_FAIL:-0}" = 1 ] && { echo "stub builder: failing on purpose" >&2; exit 1; }
[ ! -e "$OUT" ] || { echo "stub builder: $OUT exists" >&2; exit 1; }
printf 'template: pycache\ndataset_mib: %s\ndataset_seed: %s\ndataset_shards: 1\ndataset_rows: 9\ndataset_sha256: %s\nwheels: 2 verified\nvenv: python 3.9.25, stub %s\n' \
  "$D" "$S" "$(printf 'data-%s-%s' "$D" "$S" | sha256sum | cut -d' ' -f1)" "${BU_GEN:-1}" >"$OUT"
echo "built $OUT (stub)"
SH
  BR17="$TMP/e15-rig-test.e17"
  bu_stage() { # a fresh test root: staged e15/rig and e17/{rig,workload}, wheels, corpora, rootfs
    rm -rf "$BR17"
    mkdir -p "$BR17/src/e15" "$BR17/src/e17/workload" "$BR17/state" "$BR17/workspaces" "$BR17/logs" \
      "$BR17/snapshots/e15" "$BR17/wheels-pycache"
    cp -R "$RIG" "$BR17/src/e15/rig"
    cp -R "$E17D/rig" "$BR17/src/e17/rig"
    cp -R "$E17D/workload/project" "$BR17/src/e17/workload/project"
    cp "$TMP/stub-builder.sh" "$BR17/src/e17/workload/build_pycache_workspace.sh"
    printf 'wheel-a\n' >"$BR17/wheels-pycache/a-1.0-py3-none-any.whl"
    printf 'wheel-b\n' >"$BR17/wheels-pycache/b-2.0-py3-none-any.whl"
    { echo "# E17 pycache venv wheels (test)"
      (cd "$BR17/wheels-pycache" && sha256sum a-1.0-py3-none-any.whl b-2.0-py3-none-any.whl); } >"$BR17/src/e17/workload/wheels.lock"
    printf 'fake ext4 rootfs\n' >"$BR17/snapshots/e15/rootfs"
    printf 'snapshot-agent sha256:%s %s\nsnapshot-rootfs sha256:%s %s\n' "$(printf x | sha256sum | cut -d' ' -f1)" \
      "$BR17/snapshots/e15/agent" "$(sha256sum "$BR17/snapshots/e15/rootfs" | cut -d' ' -f1)" "$BR17/snapshots/e15/rootfs" >"$BR17/state/artifacts"
    for p in pycache pycache-low; do
      mkdir -p "$BR17/corpora/$p"
      printf '{"session": "%s"}\n' "$p" >"$BR17/corpora/$p/corpus.jsonl"
      python3 -c 'import hashlib,json,sys; json.dump({"corpus_sha256": hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest()}, open(sys.argv[2],"w"))' \
        "$BR17/corpora/$p/corpus.jsonl" "$BR17/corpora/$p/corpus-report.json"
    done
    : >"$TMP/bu.mounts"
    : >"$TMP/bu.builds"
    : >"$TMP/bu.log"
    rm -f "$TMP/bu-m.md"
  }
  bu() { # run the staged bringup.sh; prints its exit code
    env E15_HOST_PROFILE=fresh-metal E15_ROOT="$BR17" E15_TEST_ROOT="$BR17" E15_MANIFEST="$TMP/bu-m.md" \
      BU_MOUNTS="$TMP/bu.mounts" BU_BUILDS="$TMP/bu.builds" BU_LOG="$TMP/bu.log" PATH="$BU:$PATH" "$@" \
      bash "$BR17/src/e17/rig/bringup.sh" >"$TMP/bu.out" 2>&1
    echo $?
  }
  nb() { grep -c '^build ' "$TMP/bu.builds"; }
  tsha() { sha256sum "$BR17/template-pycache-d$1/workspace.img" | cut -d' ' -f1; }

  bu_stage
  check "E17 bringup: first run exits 0, builds d64 d256 d768 once each" \
    "$(bu)/$(sed 's/ S=.*//' "$TMP/bu.builds" | tr '\n' ' ')" "0/build D=64 build D=256 build D=768 "
  grep -q 'bringup.sh:' "$TMP/bu.out" && sed 's/^/    /' "$TMP/bu.out" | tail -5
  check "E17 bringup: the builder's arguments (1536 MiB, seed 1, the staged wheels, exact OUT paths)" \
    "$(grep -c "S=1 M=1536 wheels=$BR17/wheels-pycache rootfs=$BR17/rootfs-ro.mnt.[A-Za-z0-9]* out=$BR17/template-pycache-d\(64\|256\|768\)/workspace.img mounted=1\$" "$TMP/bu.builds")" "3"
  check "E17 bringup: the rootfs is state/artifacts' snapshot-rootfs, loop-mounted read-only, once" \
    "$(grep -c "^mount -o loop,ro $BR17/snapshots/e15/rootfs $BR17/rootfs-ro.mnt" "$TMP/bu.log")/$(grep -c '^mount ' "$TMP/bu.log")" "1/1"
  check "E17 bringup: unmounted (umount -d) and the mount point removed" \
    "$(grep -c '^umount -d ' "$TMP/bu.log")/$(grep -c . "$TMP/bu.mounts")/$(find "$BR17" -maxdepth 1 -name 'rootfs-ro.mnt.*' | grep -c .)" "1/0/0"
  check "E17 bringup: state/template-pycache-d<D> is each image's sha256 (rung.sh's template_sha256)" \
    "$(for d in 64 256 768; do [ "$(cat "$BR17/state/template-pycache-d$d")" = "$(tsha "$d")" ] && printf y || printf n; done)" "yyy"
  check "E17 bringup: BUILD beside each image (smoke.sh's dataset_sha256), artifacts recorded" \
    "$(for d in 64 256 768; do cmp -s "$BR17/template-pycache-d$d/BUILD" "$BR17/template-pycache-d$d/workspace.img" && printf y || printf n; done)/$(awk '{print $1}' "$BR17/state/artifacts" | grep -c '^template-pycache-d\(64\|256\|768\)$')/$(awk '{print $1}' "$BR17/state/artifacts" | grep -c '^corpus-pycache\(-low\)\?$')" "yyy/3/2"
  check "E17 bringup: one manifest note per template with its leaf undo line" \
    "$(for d in 64 256 768; do grep -c "E17 built $BR17/template-pycache-d$d/workspace.img (sha256 $(tsha "$d");.* -- undo: sudo -n rm -rf $BR17/template-pycache-d$d; rm -f $BR17/state/template-pycache-d$d $BR17/state/template-pycache-d$d.inputs\$" "$TMP/bu-m.md"; done | tr '\n' ' ')" "1 1 1 "
  # the stamp skip
  cp "$TMP/bu-m.md" "$TMP/bu-m.1"
  check "E17 bringup: a second run builds nothing and mounts nothing (inputs stamps match)" \
    "$(bu)/$(nb)/$(grep -c '^mount ' "$TMP/bu.log")/$(grep -c 'inputs unchanged.*(skipped)' "$TMP/bu.out")" "0/3/1/3"
  check "E17 bringup: the second run's manifest has no new build note" \
    "$(grep -c '^- .* E17 built ' "$TMP/bu-m.md")" "3"
  touch "$BR17/template-pycache-d256/keep"
  printf 'tampered\n' >>"$BR17/template-pycache-d256/workspace.img"
  check "E17 bringup: an image whose sha256 is not its stamp's is rebuilt, alone" \
    "$(bu)/$(tail -1 "$TMP/bu.builds" | sed 's/ S=.*//')/$(nb)" "0/build D=256/4"
  check "E17 bringup: the rebuild removed only the old workspace.img (a sibling file is kept)" \
    "$([ -f "$BR17/template-pycache-d256/keep" ] && echo kept)/$([ "$(cat "$BR17/state/template-pycache-d256")" = "$(tsha 256)" ] && echo restamped)" "kept/restamped"
  printf '# changed\n' >>"$BR17/src/e17/workload/build_pycache_workspace.sh"
  check "E17 bringup: a changed builder rebuilds all three" "$(bu)/$(nb)" "0/7"
  printf '# changed\n' >>"$BR17/src/e17/workload/project/analyze.py"
  check "E17 bringup: a changed project source rebuilds all three" "$(bu)/$(nb)" "0/10"
  printf '# a comment line\n' >>"$BR17/src/e17/workload/wheels.lock"
  check "E17 bringup: a changed wheels.lock rebuilds all three" "$(bu)/$(nb)" "0/13"
  mkdir -p "$BR17/src/e17/workload/project/__pycache__"
  printf 'x\n' >"$BR17/src/e17/workload/project/__pycache__/a.pyc"
  check "E17 bringup: bytecode caches in the project do not count as sources" "$(bu)/$(nb)" "0/13"
  rm -f "$BR17/state/template-pycache-d768.inputs"
  check "E17 bringup: a missing inputs stamp rebuilds that template" "$(bu)/$(tail -1 "$TMP/bu.builds" | sed 's/ S=.*//')/$(nb)" "0/build D=768/14"
  # always unmounted: a failing build leaves no mount, no mount point, no stamp, no image
  rm -f "$BR17/state/template-pycache-d64.inputs"
  check "E17 bringup: a failing build exits 1, unmounted by the trap, no stamp for it" \
    "$(bu BU_FAIL=1)/$(grep -c . "$TMP/bu.mounts")/$(find "$BR17" -maxdepth 1 -name 'rootfs-ro.mnt.*' | grep -c .)/$([ -e "$BR17/state/template-pycache-d64" ] && echo stamp || echo nostamp)/$([ -e "$BR17/template-pycache-d64/workspace.img" ] && echo img || echo noimg)" \
    "1/0/0/nostamp/noimg"
  # a running rung is never preempted: no template removed or rebuilt while e15-worker.service runs
  check "E17 bringup: (rebuild the failed d64 first)" "$(bu)/$(nb)" "0/16"
  check "E17 bringup: all stamps match, a rung running -> exit 0 (nothing removed or rebuilt)" "$(bu BU_WORKER_UP=1)/$(nb)" "0/16"
  printf 'tampered\n' >>"$BR17/template-pycache-d256/workspace.img"
  cp "$BR17/template-pycache-d256/workspace.img" "$TMP/bu-tampered.img"
  : >"$TMP/bu.log"
  check "E17 bringup: a template to rebuild while a rung runs -> refused, the old image untouched, nothing mounted" \
    "$(bu BU_WORKER_UP=1)/$(grep -c "a rung's worker (e15-worker.service) is running; refusing to preempt it" "$TMP/bu.out")/$(nb)/$(cmp -s "$TMP/bu-tampered.img" "$BR17/template-pycache-d256/workspace.img" && echo untouched)/$(grep -c '^mount ' "$TMP/bu.log")" \
    "1/1/16/untouched/0"
  # a failed unmount is loud: the trap warns, the explicit unmount after the builds is fatal
  : >"$TMP/bu.log"
  check "E17 bringup: an unmount that fails after the builds is fatal, with a WARNING naming the mount" \
    "$(bu BU_UMOUNT_STUCK=1)/$(grep -c "^bringup.sh: WARNING: $BR17/rootfs-ro.mnt.[A-Za-z0-9]* still mounted\$" "$TMP/bu.out")/$(grep -c "is still mounted after umount .*unmount it by hand" "$TMP/bu.out")/$(grep -c "^$BR17/rootfs-ro.mnt" "$TMP/bu.mounts")/$(find "$BR17" -maxdepth 1 -name 'rootfs-ro.mnt.*' | grep -c .)" \
    "1/2/1/1/1"
  : >"$TMP/bu.mounts"
  find "$BR17" -maxdepth 1 -name 'rootfs-ro.mnt.*' -exec rmdir {} +
  rm -f "$BR17/state/template-pycache-d64.inputs"
  check "E17 bringup: a failing build whose unmount also fails -> the trap's WARNING on stderr" \
    "$(bu BU_FAIL=1 BU_UMOUNT_STUCK=1)/$(grep -c "^bringup.sh: WARNING: $BR17/rootfs-ro.mnt.[A-Za-z0-9]* still mounted\$" "$TMP/bu.out")/$(grep -c 'build_pycache_workspace.sh (D=64) failed' "$TMP/bu.out")" "1/1/1"
  : >"$TMP/bu.mounts"
  find "$BR17" -maxdepth 1 -name 'rootfs-ro.mnt.*' -exec rmdir {} +
  # the wheel check (before any mount or build)
  bu_stage
  rm -f "$BR17/wheels-pycache/b-2.0-py3-none-any.whl"
  check "E17 bringup: a wheel missing from wheels-pycache is refused, nothing mounted or built" \
    "$(bu)/$(grep -c 'b-2.0-py3-none-any.whl: missing from' "$TMP/bu.out")/$(grep -c . "$TMP/bu.log")/$(nb)" "1/1/0/0"
  printf 'wheel-b tampered\n' >"$BR17/wheels-pycache/b-2.0-py3-none-any.whl"
  check "E17 bringup: a wheel whose sha256 is not the lock's is refused, nothing built" \
    "$(bu)/$(grep -c 'b-2.0-py3-none-any.whl: sha256 [0-9a-f]*, wheels.lock pins' "$TMP/bu.out")/$(nb)" "1/1/0"
  printf 'wheel-b\n' >"$BR17/wheels-pycache/b-2.0-py3-none-any.whl"
  printf 'unlocked\n' >"$BR17/wheels-pycache/extra-0.1-py3-none-any.whl"
  check "E17 bringup: an extra unlocked wheel does not fail the check (the lock decides)" "$(bu)/$(nb)" "0/3"
  # the rootfs from E15's state
  bu_stage
  printf 'other bytes\n' >"$BR17/snapshots/e15/rootfs"
  check "E17 bringup: a rootfs whose sha256 is not the recorded snapshot-rootfs is refused before any mount" \
    "$(bu)/$(grep -c 'is not the recorded snapshot-rootfs' "$TMP/bu.out")/$(grep -c '^mount ' "$TMP/bu.log")" "1/1/0"
  bu_stage
  grep -v '^snapshot-rootfs ' "$BR17/state/artifacts" >"$TMP/art" && mv "$TMP/art" "$BR17/state/artifacts"
  check "E17 bringup: no snapshot-rootfs artifact -> refused (run setup.sh first)" \
    "$(bu)/$(grep -c 'no snapshot-rootfs line' "$TMP/bu.out")" "1/1"
  bu_stage
  printf 'snapshot-rootfs sha256:%s /tmp/elsewhere/rootfs\n' "$(sha256sum "$BR17/snapshots/e15/rootfs" | cut -d' ' -f1)" >"$BR17/state/artifacts"
  check "E17 bringup: a recorded rootfs outside the E15 root is refused" "$(bu)/$(grep -c 'refuse_outside_root: /tmp/elsewhere/rootfs' "$TMP/bu.out")" "3/1"
  bu_stage
  rm -f "$BR17/state/artifacts"
  check "E17 bringup: no state/artifacts -> refused by name (not a silent exit), nothing recorded or built" \
    "$(bu)/$(grep -c "bringup.sh: no $BR17/state/artifacts (run e15/rig/setup.sh first" "$TMP/bu.out")/$([ -e "$BR17/state/artifacts" ] && echo created || echo absent)/$(nb)" "1/1/absent/0"
  # refusals before anything: profile, staged copy, corpora
  bu_stage
  check "E17 bringup: aws-prelim refused" "$(bu E15_HOST_PROFILE=aws-prelim)/$(grep -c 'E17 runs on fresh-metal only' "$TMP/bu.out")" "1/1"
  (env E15_HOST_PROFILE=fresh-metal E15_ROOT="$BR17" E15_TEST_ROOT="$BR17" E15_MANIFEST="$TMP/bu-m.md" PATH="$BU:$PATH" \
    bash "$E17D/rig/bringup.sh" >"$TMP/bu.out" 2>&1)
  check "E17 bringup: only the staged copy runs" "$?/$(grep -c 'run the staged copy' "$TMP/bu.out")" "1/1"
  printf 'x\n' >>"$BR17/corpora/pycache-low/corpus.jsonl"
  check "E17 bringup: a corpus whose sha256 is not its report's is refused" "$(bu)/$(grep -c 'is not its report.s corpus_sha256' "$TMP/bu.out")/$(nb)" "1/1/0"

  # the path guard: e17_check_target, and a points.sh that would hand bringup.sh a parent path
  ctg() { # PATH D -> pass|refused (message in $TMP/ctg.out)
    (E15_HOST_PROFILE=fresh-metal E15_ROOT="$BR17" E15_TEST_ROOT="$BR17" E15_MANIFEST="$TMP/bu-m.md" bash -c \
      'source "$1"; eval "$(sed -n "/^e17_check_target() {/,/^}/p" "$2")"; e17_check_target "$3" "$4"' \
      _ "$RIG/lib.sh" "$E17D/rig/bringup.sh" "$1" "$2" >"$TMP/ctg.out" 2>&1) && echo pass || echo refused
  }
  bu_stage
  mkdir -p "$BR17/template-pycache-d256" "$BR17/template-pycache-d64" "$BR17/elsewhere"
  check "E17 path guard: the exact template path passes" "$(ctg "$BR17/template-pycache-d256/workspace.img" 256)" "pass"
  check "E17 path guard: the template's directory is refused" "$(ctg "$BR17/template-pycache-d256" 256)" "refused"
  check "E17 path guard: the E15 root is refused" "$(ctg "$BR17" 256)" "refused"
  check "E17 path guard: the snapshot directory is refused" "$(ctg "$BR17/snapshots/e15" 256)" "refused"
  check "E17 path guard: another D's image is refused" "$(ctg "$BR17/template-pycache-d64/workspace.img" 256)" "refused"
  check "E17 path guard: a D that is not a template is refused" "$(ctg "$BR17/template-pycache-d512/workspace.img" 512)" "refused"
  check "E17 path guard: a .. spelling is refused" "$(ctg "$BR17/template-pycache-d256/../template-pycache-d256/workspace.img" 256)" "refused"
  check "E17 path guard: a // spelling is refused" "$(ctg "$BR17//template-pycache-d256/workspace.img" 256)" "refused"
  check "E17 path guard: E15's own template is refused" "$(ctg "$BR17/template/workspace.img" 256)" "refused"
  check "E17 path guard: the /srv/e15 path under a test root is refused" "$(ctg /srv/e15/template-pycache-d256/workspace.img 256)" "refused"
  mkdir -p "$BR17/template-pycache-d256/workspace.img"
  check "E17 path guard: an image path that is a directory is refused" "$(ctg "$BR17/template-pycache-d256/workspace.img" 256)" "refused"
  rmdir "$BR17/template-pycache-d256/workspace.img"
  rmdir "$BR17/template-pycache-d64"
  ln -s "$BR17/elsewhere" "$BR17/template-pycache-d64"
  check "E17 path guard: a template directory that is a symlink is refused" "$(ctg "$BR17/template-pycache-d64/workspace.img" 64)" "refused"
  ln -s "$BR17/elsewhere/x.img" "$BR17/template-pycache-d256/workspace.img"
  check "E17 path guard: an image that is a symlink is refused" "$(ctg "$BR17/template-pycache-d256/workspace.img" 256)" "refused"
  rm -f "$BR17/template-pycache-d256/workspace.img" "$BR17/template-pycache-d64"
  # the whole script: a points.sh whose pycache template is the directory, not the image
  bu_stage
  sed -i.orig 's#^    E15_P_TEMPLATE=\$E15_ROOT/\$E15_P_TEMPLATE_STAMP/workspace.img$#    E15_P_TEMPLATE=$E15_ROOT/$E15_P_TEMPLATE_STAMP#' "$BR17/src/e15/rig/points.sh"
  check "E17 path guard test: the staged points.sh was changed" "$(cmp -s "$BR17/src/e15/rig/points.sh" "$RIG/points.sh" && echo same || echo changed)" "changed"
  mkdir -p "$BR17/template-pycache-d64"
  touch "$BR17/template-pycache-d64/sentinel"
  check "E17 bringup: a parent-path target from points.sh is refused (exit 3), nothing removed or built" \
    "$(bu)/$(grep -c "is not exactly $BR17/template-pycache-d64/workspace.img" "$TMP/bu.out")/$([ -f "$BR17/template-pycache-d64/sentinel" ] && echo kept)/$(nb)/$(grep -c '^mount ' "$TMP/bu.log")" "3/1/kept/0/0"
  check "E17 bringup: its only rm is rm -f of the checked image (rm -rf only in the manifest's undo text)" \
    "$(grep -v '^ *#' "$E17D/rig/bringup.sh" | grep 'rm -rf' | grep -vc 'm_note "E17 .* -- undo: \(sudo -n \)\?rm -rf \$')/$(grep -c '^    sudo -n rm -f -- "\$T"$' "$E17D/rig/bringup.sh")/$(grep -B1 '^    sudo -n rm -f -- "\$T"$' "$E17D/rig/bringup.sh" | grep -c '^    e17_check_target "\$T" "\$D"$')" "0/1/1"
  rm -rf "$BR17"
fi

# gen_corpora.sh: both corpora, the brief's arguments, and --durations-from
if [ -f "$E17D/rig/gen_corpora.sh" ]; then
  GC="$TMP/gc"
  rm -rf "$GC"
  gc() { E17_CORPORA="$GC" E17_GAPS="$E17D/extract/testdata/gaps-20.jsonl" bash "$E17D/rig/gen_corpora.sh" "$@" >"$TMP/gc.out" 2>&1; echo $?; }
  gcr() { python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"r": r}))' "$GC/$1/corpus-report.json" "$2"; }
  gcd() { # POINT -> "class=dur_ms/work_ms" for every distinct pair in the corpus
    python3 -c 'import json,sys
s=set()
for l in open(sys.argv[1]):
    for c in json.loads(l)["calls"]: s.add("%s=%d/%d" % (c["class"], c["dur_ms"], c["work_ms"]))
print(" ".join(sorted(s)))' "$GC/$1/corpus.jsonl"
  }
  check "E17 gen_corpora: placeholders without --durations-from, and it says so" \
    "$(gc)/$(gcd pycache)/$(grep -c 'placeholder durations' "$TMP/gc.out")" "0/py_analyze=15000/15000 py_grep=2200/2200 py_import=2000/2000 py_short=300/300 py_test=60000/60000/1"
  check "E17 gen_corpora: pycache at duty 0.095, pycache-low at 0.015; 400 sessions, seed 1, min-turns 4" \
    "$(gcr pycache '(r["duty_target"], r["sessions"], r["seed"], r["min_turns"])')/$(gcr pycache-low '(r["duty_target"], r["sessions"], r["seed"], r["min_turns"])')" \
    "(0.095, 400, 1, 4)/(0.015, 400, 1, 4)"
  check "E17 gen_corpora: same as pycache_corpus.py run directly (byte-identical)" \
    "$(python3 "$E17D/extract/pycache_corpus.py" --gaps-from "$E17D/extract/testdata/gaps-20.jsonl" --duty 0.015 --sessions 400 --seed 1 --min-turns 4 --out "$TMP/gc-direct" >/dev/null 2>&1; cmp -s "$TMP/gc-direct/corpus.jsonl" "$GC/pycache-low/corpus.jsonl" && echo same)" "same"
  cp "$GC/pycache/corpus.jsonl" "$TMP/gc-placeholder.jsonl"
  printf '{"py_analyze": 18250.6, "py_test": 57100, "py_import": 1980.6, "py_grep": 2150, "py_short": 412}\n' >"$TMP/cal.json"
  check "E17 gen_corpora --durations-from: every call carries the measured durations, both corpora" \
    "$(gc --durations-from "$TMP/cal.json")/$(gcd pycache)/$(gcd pycache-low)" \
    "0/py_analyze=18251/18251 py_grep=2150/2150 py_import=1981/1981 py_short=412/412 py_test=57100/57100/py_analyze=18251/18251 py_grep=2150/2150 py_import=1981/1981 py_short=412/412 py_test=57100/57100"
  check "E17 gen_corpora --durations-from: the reports record them and the file, and no placeholder note" \
    "$(gcr pycache 'r["durations_ms"]')/$(gcr pycache-low 'r["durations_from"]["file"]')/$(grep -c 'placeholder durations' "$TMP/gc.out")" \
    "{'py_analyze': 18251, 'py_test': 57100, 'py_import': 1981, 'py_grep': 2150, 'py_short': 412}/cal.json/0"
  check "E17 gen_corpora --durations-from: the duty is still met with the measured durations" \
    "$(gcr pycache 'r["duty_achieved"]["mean"] <= 0.095 * 1.2')/$(gcr pycache-low 'r["duty_achieved"]["mean"] <= 0.015 * 1.2')" "True/True"
  check "E17 gen_corpora --durations-from: the corpus changed, the report's corpus_sha256 is its file's" \
    "$(cmp -s "$TMP/gc-placeholder.jsonl" "$GC/pycache/corpus.jsonl" && echo same || echo changed)/$([ "$(gcr pycache 'r["corpus_sha256"]')" = "$(sha256sum "$GC/pycache/corpus.jsonl" | cut -d' ' -f1)" ] && echo match)" "changed/match"
  cp "$GC/pycache/corpus.jsonl" "$TMP/gc-cal.jsonl"
  printf '{"py_analyze": 18250, "py_test": 57100, "py_import": 1980, "py_short": 412}\n' >"$TMP/cal-bad.json"
  check "E17 gen_corpora --durations-from: a file missing a class fails, the corpora stay as they were" \
    "$(gc --durations-from "$TMP/cal-bad.json")/$(grep -c 'pycache_corpus.py: --durations-from' "$TMP/gc.out")/$(cmp -s "$TMP/gc-cal.jsonl" "$GC/pycache/corpus.jsonl" && echo kept)/$(find "$GC" -maxdepth 1 -name '.pycache*' | grep -c .)" "1/1/kept/0"
  check "E17 gen_corpora: a missing CAL.json, or another argument, is a usage error" \
    "$(gc --durations-from "$TMP/nope.json")/$(gc --bogus)" "2/2"
  check "E17 gen_corpora: the brief's gap source and corpora root are the defaults" \
    "$(grep -c 'E17_GAPS:-/tmp/kagenti/e16-corpus-default/corpus.jsonl' "$E17D/rig/gen_corpora.sh")/$(grep -c 'E17_CORPORA:-/tmp/kagenti/e17-corpora' "$E17D/rig/gen_corpora.sh")" "1/1"
  rm -rf "$GC" "$TMP/gc-direct"
fi

# smoke.sh: the rung line per arm, and its refusals (it is never run here: it starts workers)
if [ -f "$E17D/rig/smoke.sh" ]; then
  check "E17 smoke: one rung.sh ARM 1 pycache per arm, 60 s warm-up, 120 s window, tag smoke" \
    "$(grep -c '^ARMS=(sbx resident-300 lease-30 lease-120)$' "$E17D/rig/smoke.sh")/$(grep -c 'E15_WARMUP_S=60 E15_WINDOW_S=120 E15_TAG=smoke E15_START_ZERO=\$START_ZERO bash "\$RUNG" "\$arm" 1 "\$POINT"' "$E17D/rig/smoke.sh")/$(grep -c '^POINT=pycache$' "$E17D/rig/smoke.sh")" "1/1/1"
  check "E17 smoke: the sha256 is checked against the D=256 template's BUILD, warmcold.py on each rung" \
    "$(grep -c '^BUILD=\${E15_P_TEMPLATE%/\*}/BUILD$' "$E17D/rig/smoke.sh")/$(grep -c 'python3 "\$E17_SRC/analysis/warmcold.py" "\$d"' "$E17D/rig/smoke.sh")" "1/1"
  (E15_HOST_PROFILE=aws-prelim E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" E15_MANIFEST="$TMP/m.md" PATH="$SPATH" bash "$E17D/rig/smoke.sh" >"$TMP/sm.out" 2>&1)
  check "E17 smoke: aws-prelim refused" "$?/$(grep -c 'E17 runs on fresh-metal only' "$TMP/sm.out")" "1/1"
  (E15_HOST_PROFILE=fresh-metal E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" E15_MANIFEST="$TMP/m.md" PATH="$SPATH" bash "$E17D/rig/smoke.sh" >"$TMP/sm.out" 2>&1)
  check "E17 smoke: only the staged copy runs" "$?/$(grep -c 'run the staged copy' "$TMP/sm.out")" "1/1"
  # smoke.sh end to end against stubs: a rung.sh stub (E15_RUNG) writing canned rung files, and
  # sudo/systemctl/systemd-run/ss/grpcurl/cp stubs for its relay Exec of analyze
  SM="$TMP/e15-rig-test.smoke"
  SS5="$TMP/smstub"
  rm -rf "$SM" "$SS5"
  mkdir -p "$SM/src/e15" "$SM/src/e17/workload" "$SM/state" "$SM/logs" "$SM/bin" "$SM/workspaces" "$SM/secrets" \
    "$SM/template-pycache-d256" "$SS5"
  cp -R "$RIG" "$SM/src/e15/rig"
  cp -R "$E17D/rig" "$SM/src/e17/rig"
  cp -R "$E17D/analysis" "$SM/src/e17/analysis"
  cp "$E17D/workload/library.json" "$SM/src/e17/workload/library.json"
  printf 'tok\n' >"$SM/secrets/exec.token"
  printf '#!/bin/sh\n' >"$SM/bin/microvm-worker"
  chmod +x "$SM/bin/microvm-worker"
  printf 'image\n' >"$SM/template-pycache-d256/workspace.img"
  SMSHA=$(printf 'smoke-dataset' | sha256sum | cut -d' ' -f1)
  printf 'template: pycache\ndataset_mib: 256\ndataset_seed: 1\ndataset_sha256: %s\nvenv: python 3.9\n' "$SMSHA" >"$SM/template-pycache-d256/BUILD"
  printf '#!/usr/bin/env bash\n[ "$1" = -n ] && shift\n[ $# -eq 0 ] && exit 0\nexec "$@"\n' >"$SS5/sudo"
  printf '#!/usr/bin/env bash\ncase "$1 ${!#}" in "is-active e15-relay.service") [ -e "$SM_FLAG" ] ;; "stop e15-relay.service") rm -f "$SM_FLAG" ;; "is-active e15-worker.service") [ -e "$SM_WFLAG" ] ;; is-active*|is-failed*) exit 1 ;; esac\n' >"$SS5/systemctl"
  printf '#!/usr/bin/env bash\nfor a; do case "$a" in --unit=e15-relay.service) touch "$SM_FLAG" ;; StandardOutput=file:*) echo "microvm-worker: attached, serving execs" >"${a#StandardOutput=file:}" ;; esac; done\n' >"$SS5/systemd-run"
  printf '#!/usr/bin/env bash\n[ -e "$SM_FLAG" ] && printf "LISTEN 0 511 127.0.0.1:9643 0.0.0.0:*\\nLISTEN 0 511 127.0.0.1:9644 0.0.0.0:*\\n"\nexit 0\n' >"$SS5/ss"
  printf '#!/usr/bin/env bash\nargs=(); for a; do [ "$a" = --reflink=always ] || args+=("$a"); done\nexec /bin/cp "${args[@]}"\n' >"$SS5/cp"
  # grpcurl: the probe key gets the worker's refusal; any other key "runs" analyze
  cat >"$SS5/grpcurl" <<'SH'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do [ "$1" = -d ] && req=$2; shift; done
echo "grpcurl $req" >>"$SM_GLOG"
case "$req" in
*_e15-attach-probe*) echo '{"error": {"message": "invalid-workspace-key: _e15-attach-probe"}}' ;;
*) python3 -c 'import base64,json,sys; print(json.dumps({"chunk": {"data": base64.b64encode(sys.argv[1].encode()).decode()}})); print(json.dumps({"end": {"exitCode": int(sys.argv[2])}}))' \
     "rows=9 sha256=${SM_PRINT_SHA} clusters=1.000"$'\n' "${SM_ANALYZE_RC:-0}" ;;
esac
SH
  # the rung stub: record.json, a calls.jsonl with the classes in SM_CLASSES (exit SM_EXIT), worker.log
  cat >"$TMP/smoke-rung.sh" <<'SH'
#!/usr/bin/env bash
echo "rung $* w=$E15_WARMUP_S win=$E15_WINDOW_S tag=$E15_TAG zero=${E15_START_ZERO:-unset}" >>"$SM_RLOG"
# SM_WORKER_AFTER=1: someone else's rung worker comes up after this smoke's last rung
[ "${SM_WORKER_AFTER:-0}" = 1 ] && [ "$1" = lease-120 ] && touch "$SM_WFLAG"
d=$E15_ROOT/runs/$3/$1/N$2-$E15_TAG
mkdir -p "$d"
echo '{"holds": true}' >"$d/record.json"
: >"$d/calls.jsonl"
i=0
set -- ${SM_CLASSES:-py_analyze py_test py_analyze}
for c; do
  st='"status": "ok", "cause": "ok", "exit": '"${SM_EXIT:-0}"
  # SM_CUT_LAST=1: the last call was cut at the run's end (the driver: status err, no exit)
  [ "${SM_CUT_LAST:-0}" = 1 ] && [ "$i" = $(($# - 1)) ] && st='"status": "err", "cause": "cut_at_end", "exit": null'
  printf '{"session": "e15-k-0-0", "call": %d, "class": "%s", %s, "execs": 1, "in_window": true, "ts": "2026-11-10T00:00:0%dZ", "observed_ms": 10}\n' "$i" "$c" "$st" "$i" >>"$d/calls.jsonl"
  i=$((i + 1))
done
: >"$d/worker.log"
SH
  chmod +x "$SS5"/* "$TMP/smoke-rung.sh"
  smoke() { # VAR=... -> exit code; output in $TMP/sm.out
    rm -rf "$SM/runs" "$SM/workspaces/e17-smoke-analyze" "$TMP/sm.flag" "$TMP/sm.wflag"
    : >"$TMP/sm.rlog"
    : >"$TMP/sm.glog"
    env E15_HOST_PROFILE=fresh-metal E15_ROOT="$SM" E15_TEST_ROOT="$SM" E15_MANIFEST="$TMP/sm-m.md" E15_RUNG="$TMP/smoke-rung.sh" \
      SM_FLAG="$TMP/sm.flag" SM_WFLAG="$TMP/sm.wflag" SM_RLOG="$TMP/sm.rlog" SM_GLOG="$TMP/sm.glog" SM_PRINT_SHA="$SMSHA" PATH="$SS5:$PATH" "$@" \
      bash "$SM/src/e17/rig/smoke.sh" >"$TMP/sm.out" 2>&1
    echo $?
  }
  check "E17 smoke (stubbed): passes; one rung per arm with the brief's settings, starting at zero" \
    "$(smoke)/$(cut -d' ' -f2- "$TMP/sm.rlog" | tr '\n' ';')" \
    "0/sbx 1 pycache w=60 win=120 tag=smoke zero=1;resident-300 1 pycache w=60 win=120 tag=smoke zero=1;lease-30 1 pycache w=60 win=120 tag=smoke zero=1;lease-120 1 pycache w=60 win=120 tag=smoke zero=1;"
  grep -q 'FAILED\|smoke.sh:' "$TMP/sm.out" && sed 's/^/    /' "$TMP/sm.out" | tail -5
  check "E17 smoke (stubbed): warmcold counts printed per rung, the pass line names the BUILD sha256" \
    "$(grep -c '^smoke pycache/[a-z0-9-]*/N1-smoke: warm [0-9]* cold [0-9]* unknown [0-9]* (holds=True)$' "$TMP/sm.out")/$(grep -c "analyze sha256 = BUILD dataset_sha256 ($SMSHA)" "$TMP/sm.out")" "4/1"
  check "E17 smoke (stubbed): analyze ran on its own key with the library's command; the copy removed after" \
    "$(grep -c '"workspace_key": "e17-smoke-analyze"' "$TMP/sm.glog")/$(grep -c 'cd project && ../venv/bin/python analyze.py' "$TMP/sm.glog")/$([ -e "$SM/workspaces/e17-smoke-analyze" ] && echo left || echo removed)" "1/1/removed"
  check "E17 smoke (stubbed): a printed sha256 that is not BUILD's fails" \
    "$(smoke SM_PRINT_SHA="$(printf other | sha256sum | cut -d' ' -f1)")/$(grep -c "analyze printed sha256=[0-9a-f]*, .*BUILD has dataset_sha256 $SMSHA" "$TMP/sm.out")" "1/1"
  check "E17 smoke (stubbed): analyze exiting non-zero through the relay fails" \
    "$(smoke SM_ANALYZE_RC=1)/$(grep -c 'analyze through the relay exited 1' "$TMP/sm.out")" "1/1"
  check "E17 smoke (stubbed): an sbx py_analyze call with exit 1 fails" \
    "$(smoke SM_EXIT=1)/$(grep -c 'sbx py_analyze: .*status ok cause ok exit 1' "$TMP/sm.out")" "1/1"
  check "E17 smoke (stubbed): no py_analyze call in the sbx rung fails, naming E15_START_ZERO" \
    "$(smoke SM_CLASSES='py_test py_short')/$(grep -c 'no completed py_analyze call among the rung.s 2 calls (0 cut at the end; E15_START_ZERO=1)' "$TMP/sm.out")" "1/1"
  check "E17 smoke (stubbed): E15_START_ZERO=0 from the environment is passed through" \
    "$(smoke E15_START_ZERO=0)/$(grep -c ' zero=0$' "$TMP/sm.rlog")" "0/4"
  check "E17 smoke (stubbed): a py_analyze call cut at the run's end (cut_at_end) is not a failure" \
    "$(smoke SM_CUT_LAST=1)/$(grep -c 'sbx py_analyze: 2 py_analyze call(s), 0 not ok/exit 0, 1 cut at the end' "$TMP/sm.out")" "0/1"
  check "E17 smoke (stubbed): a cut py_analyze call is not a completed one (the only one, cut -> fails)" \
    "$(smoke SM_CLASSES='py_test py_analyze' SM_CUT_LAST=1)/$(grep -c 'no completed py_analyze call among the rung.s 2 calls (1 cut at the end' "$TMP/sm.out")" "1/1"
  touch "$TMP/sm.wflag.pre"
  check "E17 smoke (stubbed): a rung's worker already running -> refused before any rung" \
    "$(smoke SM_WFLAG="$TMP/sm.wflag.pre")/$(grep -c "a rung's worker (e15-worker.service) is running; refusing to preempt it" "$TMP/sm.out")/$(grep -c . "$TMP/sm.rlog")" "1/1/0"
  rm -f "$TMP/sm.wflag.pre"
  check "E17 smoke (stubbed): a rung's worker up before the analyze check -> refused, no relay restart or Exec" \
    "$(smoke SM_WORKER_AFTER=1)/$(grep -c "a rung's worker (e15-worker.service) is running; refusing to preempt it" "$TMP/sm.out")/$(grep -c . "$TMP/sm.rlog")/$(grep -c . "$TMP/sm.glog")/$([ -e "$SM/workspaces/e17-smoke-analyze" ] && echo copied || echo none)" "1/1/4/0/none"
  rm -rf "$SM"
fi

# --- E17 Task 5b: the pycache probe cap (points.sh, classprobe.sh) and experiments/e17-lease/rig/reprobe.sh -------
# E15's probe caps planned durations at 30 s; pycache's py_test runs ~62 s whatever it is planned
# at, so its class median came out +31 s. The pycache points set E15_P_PROBE_CAP_MS=120000, which
# classprobe.sh passes to make_probe.py; no other point sets it, and it enters only the pycache
# points' signature (the goldens above stay byte-identical).
pcap() { # BODY under fresh-metal, lib.sh and points.sh sourced
  E15_HOST_PROFILE=fresh-metal E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; source "$2"; eval "$3"' \
    _ "$RIG/lib.sh" "$RIG/points.sh" "$1" 2>&1
}
E15PTS="default short lowduty long no-infra no-chains smoke mem512"
check "E17 5b points: the four pycache points set E15_P_PROBE_CAP_MS=120000" \
  "$(pcap 'for p in pycache pycache-low pycache-d64 pycache-d768; do e15_point $p; printf "%s " "$E15_P_PROBE_CAP_MS"; done')" \
  "120000 120000 120000 120000 "
check "E17 5b points: no E15 point sets it" \
  "$(pcap "for p in $E15PTS; do e15_point \$p; printf '%s ' \"\${E15_P_PROBE_CAP_MS-unset}\"; done")" \
  "unset unset unset unset unset unset unset unset "
check "E17 5b points: it does not leak from pycache into the next point in the same shell" \
  "$(pcap "for p in $E15PTS; do e15_point pycache; e15_point \$p; printf '%s ' \"\${E15_P_PROBE_CAP_MS-unset}\"; done")" \
  "unset unset unset unset unset unset unset unset "
for p in default lowduty mem512; do
  check "E17 5b point_sig: $p after pycache in one shell is its golden signature" \
    "$(pcap "e15_point_sig pycache >/dev/null; e15_point_sig $p")" "$(sed -n 's/^point_sig=//p' "$GOLD/point-$p.txt")"
done
check "E17 5b points: the pycache settings end with the probe cap" \
  "$(pcap 'for p in pycache pycache-low pycache-d64 pycache-d768; do e15_point $p; case "$E15_P_SETTINGS" in *" scan_cmd= probe_cap_ms=120000") printf y ;; *) printf n ;; esac; done')" "yyyy"
sha_s() { printf '%s' "$1" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'; }
pc_set=$(pcap 'e15_point pycache; echo "$E15_P_SETTINGS"')
check "E17 5b point_sig: the probe cap is part of pycache's identity (not the settings without it)" \
  "$([ "$(pcap 'e15_point_sig pycache')" = "$(sha_s "$pc_set")" ] && echo sig-of-settings)/$([ "$(pcap 'e15_point_sig pycache')" != "$(sha_s "${pc_set% probe_cap_ms=120000}")" ] && echo apart)" \
  "sig-of-settings/apart"
sed 's/E15_P_PROBE_CAP_MS=120000/E15_P_PROBE_CAP_MS=90000/' "$RIG/points.sh" >"$TMP/points-cap90k.sh"
check "E17 5b point_sig: another probe cap is another pycache signature" \
  "$([ "$(E15_HOST_PROFILE=fresh-metal E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; source "$2"; e15_point_sig pycache' _ "$RIG/lib.sh" "$TMP/points-cap90k.sh" 2>&1)" != "$(pcap 'e15_point_sig pycache')" ] && echo apart)" "apart"

# classprobe.sh: make_probe.py gets --cap-ms 30000 at an E15 point, the point's cap at pycache
# (a make_probe.py stub logs its argv, then runs the real one)
CP5="$TMP/e15-rig-test.cp5b"
rm -rf "$CP5"
mkdir -p "$CP5/src/e15/analysis" "$CP5/src/e15/commands" "$CP5/src/e17/workload" "$CP5/corpora/default" "$CP5/corpora/pycache"
cat >"$CP5/src/e15/analysis/make_probe.py" <<'PY'
import os, runpy, sys
with open(os.environ["MP_LOG"], "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
sys.argv[0] = os.environ["MP_REAL"]
runpy.run_path(sys.argv[0], run_name="__main__")
PY
printf '%s\n' '{"session":"s","user":"u","provider":"claude","calls":[{"i":0,"class":"read","work_ms":5,"dur_ms":50,"chain":false}]}' >"$CP5/corpora/default/corpus.jsonl"
printf '%s\n' '{"version":1,"classes":{"read":[{"id":"r","cmd":"x","exit":0,"nominal_ms":30,"run_ms":3}]},"standin":{}}' >"$CP5/src/e15/commands/library.json"
cp "$RIG/../../../experiments/e17-lease/workload/library.json" "$CP5/src/e17/workload/library.json"
printf '%s\n' '{"session":"s","user":"u","provider":"claude","calls":[{"i":0,"class":"py_analyze","work_ms":15000,"dur_ms":15000,"chain":false},{"i":1,"class":"py_test","work_ms":60000,"dur_ms":60000,"chain":false},{"i":2,"class":"py_short","work_ms":300,"dur_ms":300,"chain":false}]}' \
  >"$CP5/corpora/pycache/corpus.jsonl"
cprobe() { # PROFILE POINT -> exit code; make_probe argv in $TMP/mp.log
  : >"$TMP/mp.log"
  : >"$TMP/pcalls"
  env E15_HOST_PROFILE="$1" E15_ROOT="$CP5" E15_TEST_ROOT="$CP5" E15_RUNG="$PRUNG" P_SHORT=none P_CALLS="$TMP/pcalls" MP_LOG="$TMP/mp.log" \
    MP_REAL="$RIG/../analysis/make_probe.py" PATH="$SPATH" E15_MANIFEST="$TMP/m.md" bash "$RIG/classprobe.sh" "$2" sbx >"$TMP/cp5.out" 2>&1
  echo $?
}
check "E17 5b classprobe: an E15 point passes --cap-ms 30000 (aws-prelim and fresh-metal)" \
  "$(cprobe aws-prelim default)/$(grep -c ' --cap-ms 30000$' "$TMP/mp.log")/$(cprobe fresh-metal default)/$(grep -c ' --cap-ms 30000$' "$TMP/mp.log")" "0/1/0/1"
check "E17 5b classprobe: pycache passes --cap-ms 120000, after the per-class and seed options" \
  "$(cprobe fresh-metal pycache)/$(sed "s#$CP5#<R>#g" "$TMP/mp.log")" \
  "0/<R>/corpora/pycache/corpus.jsonl <R>/src/e17/workload/library.json <R>/runs/pycache/sbx/probe-corpora --per-class 20 --seed 1 --cap-ms 120000"
check "E17 5b classprobe: the pycache py_test probe plans 60000 ms, not 30000" \
  "$(python3 -c 'import json,sys; print(sorted({c["dur_ms"] for c in json.loads(open(sys.argv[1]).readline())["calls"]}))' "$CP5/runs/pycache/sbx/probe-corpora/py_test/corpus.jsonl")" "[60000]"
rm -rf "$CP5"

# reprobe.sh ARM: the staged copy against a staged root; classprobe.sh (E15_CLASSPROBE) and
# analysis/baseline.py are stubs that log their argv and environment; the seeded runs and the old
# probe are fixtures. Seeds: s1 ok, s2 empty_window (skipped), s3 ok, s4 ok -> 3 evaluable, 36
# calls, so baseline.sh stopped at s4; s5 is a stale extra dir that must not be counted.
RP="$TMP/e15-rig-test.reprobe"
RPS="$TMP/rpstub"
RE17="$RIG/../../../experiments/e17-lease"
if [ -f "$RE17/rig/reprobe.sh" ]; then
  rm -rf "$RP" "$RPS"
  mkdir -p "$RP/src/e15" "$RP/src/e17/workload" "$RP/corpora/pycache" "$RP/bin" "$RP/state" "$RPS"
  cp -R "$RIG" "$RP/src/e15/rig"
  cp -R "$RIG/../analysis" "$RP/src/e15/analysis"
  cp -R "$RE17/rig" "$RP/src/e17/rig"
  cp "$RE17/workload/library.json" "$RP/src/e17/workload/library.json"
  printf 'pycache corpus\n' >"$RP/corpora/pycache/corpus.jsonl"
  printf '#!/bin/sh\n' >"$RP/bin/e15-driver"
  chmod +x "$RP/bin/e15-driver"
  printf '#!/usr/bin/env bash\ncase "$1 ${!#}" in "is-active e15-worker.service") [ -e "$RP_WFLAG" ] ;; *) exit 1 ;; esac\n' >"$RPS/systemctl"
  chmod +x "$RPS/systemctl"
  cat >"$RP/src/e15/analysis/baseline.py" <<'PY'
import json, os, sys
argv = sys.argv[1:]
with open(os.environ["RP_BLOG"], "a") as f:
    f.write("argv %s\n" % " ".join(argv))
    for k in ("E15_BASELINE_CORPUS", "E15_BASELINE_ARM", "E15_BASELINE_SEEDS", "E15_BASELINE_SKIPPED"):
        f.write("%s=%s\n" % (k, os.environ.get(k)))
if os.environ.get("RP_BFAIL") == "1":
    sys.exit("baseline.py: stub failure")
rec = json.load(open(os.path.join(argv[1], "record.json")))
b = {k: rec[k] for k in ("library_sha256", "driver_bin_sha256", "corpus_sha256", "point_sig")}
b.update({"class_medians": {"py_test": 1900, "py_analyze": 400}, "global_median_ms": 500, "excess_p95_ms": 300,
          "n1_median_pace": 0.01, "probe_failed": {}, "baseline_p95_ms": 700})
json.dump(b, open(argv[0], "w"), indent=2, sort_keys=True)
print(700)
PY
  cat >"$RPS/classprobe.sh" <<'SH'
#!/usr/bin/env bash
echo "classprobe $*" >>"$RP_CLOG"
[ "${RP_CPFAIL:-0}" = 1 ] && exit 1
mkdir -p "$E15_ROOT/runs/$1/$2/probe-corpora"
for c in py_analyze py_short py_test; do
  d=$E15_ROOT/runs/$1/$2/N1-probe-$c
  mkdir -p "$d"
  echo new >"$d/marker"
  echo '{"in_window": true, "status": "ok"}' >"$d/calls.jsonl"
  python3 -c 'import json,sys; e=json.loads(sys.argv[2]); e.update(json.loads(sys.argv[3] or "{}")); json.dump(e, open(sys.argv[1], "w"))' \
    "$d/record.json" "$RP_ENV" "${RP_PENV:-}"
  # RP_CPPARTIAL=1: a rig error after the first probe (its dir and probe-corpora are left)
  [ "${RP_CPPARTIAL:-0}" = 1 ] && exit 1
  echo "$d"
done
SH
  chmod +x "$RPS/classprobe.sh"
  # the rung environment every seeded record and (by default) every new probe record carries; an
  # sbx-like record: no resident_patch_sha256 key at all
  RP_ENV='{"template_sha256": "t1", "worker_bin_sha256": "w1", "snapshot_hash": "h1", "snapshot_guest_ram_mb": 1024}'
  rp_cur=$(E15_HOST_PROFILE=fresh-metal E15_ROOT="$RP" E15_TEST_ROOT="$RP" bash -c 'source "$1"; source "$2"; e15_point pycache; echo "$E15_P_SETTINGS"' _ "$RIG/lib.sh" "$RIG/points.sh")
  rp_old=${rp_cur% probe_cap_ms=120000}
  rp_oldsig=$(sha_s "$rp_old")
  rp_cursig=$(sha_s "$rp_cur")
  rp_stage() { # ARM [SETTINGS]: seeded runs, old probe dirs and the old baseline.json
    local a=$1 st=${2:-$rp_old} R=$RP/runs/pycache/$1
    rm -rf "$RP/runs"
    mkdir -p "$R/N1" "$R/probe-corpora"
    echo old >"$R/probe-corpora/marker"
    for c in py_analyze py_short py_test; do
      mkdir -p "$R/N1-probe-$c"
      echo old >"$R/N1-probe-$c/marker"
    done
    python3 - "$R" "$st" "$(sha_s "$st")" "$(sha_f "$RP/src/e17/workload/library.json")" "$(sha_f "$RP/bin/e15-driver")" \
      "$(sha_f "$RP/corpora/pycache/corpus.jsonl")" "${RP_S3:-ok}" "$RP_ENV" <<'PY'
import json, os, sys
R, st, sig, lib, drv, corpus, s3, env = sys.argv[1:9]
ok = {"holds": True, "reason": None}
kinds = {1: ok, 2: {"holds": False, "reason": "empty_window"}, 3: ok if s3 == "ok" else {"holds": False, "reason": "p95"},
         4: ok, 5: ok}
for s, v in kinds.items():
    d = os.path.join(R, "N1-s%d" % s)
    os.makedirs(d)
    rec = dict(v, library_sha256=lib, driver_bin_sha256=drv, corpus_sha256=corpus, point_sig=sig, point_settings=st)
    rec.update(json.loads(env))
    json.dump(rec, open(os.path.join(d, "record.json"), "w"))
    n = 0 if s == 2 else 12
    with open(os.path.join(d, "calls.jsonl"), "w") as f:
        for i in range(n):
            f.write(json.dumps({"in_window": True, "status": "ok", "observed_ms": 1100, "planned_dur_ms": 1000, "class": "py_short"}) + "\n")
d = lambda s: os.path.join(R, "N1-s%d" % s)
b = {"point_sig": sig, "library_sha256": lib, "driver_bin_sha256": drv, "corpus_sha256": corpus,
     "class_medians": {"py_test": 31412, "py_analyze": 420}, "global_median_ms": 600, "excess_p95_ms": 310,
     "n1_median_pace": 0.01, "evaluable": [{"seed": s, "dir": d(s)} for s in (1, 3, 4)],
     "skipped": [{"seed": 2, "tag": "s2", "reason": "empty_window"}]}
json.dump(b, open(os.path.join(R, "N1", "baseline.json"), "w"), indent=2, sort_keys=True)
PY
    cp "$R/N1/baseline.json" "$TMP/rp-old-baseline.json"
  }
  rp() { # ARM [VAR=...] -> exit code; output in $TMP/rp.out
    local a=$1
    shift
    : >"$TMP/rp.clog"
    : >"$TMP/rp.blog"
    env E15_HOST_PROFILE=fresh-metal E15_ROOT="$RP" E15_TEST_ROOT="$RP" E15_MANIFEST="$TMP/rp-m.md" E15_CLASSPROBE="$RPS/classprobe.sh" \
      RP_ENV="$RP_ENV" RP_CLOG="$TMP/rp.clog" RP_BLOG="$TMP/rp.blog" RP_WFLAG="$TMP/rp.wflag" PATH="$RPS:$PATH" "$@" \
      bash "$RP/src/e17/rig/reprobe.sh" "$a" >"$TMP/rp.out" 2>&1
    echo $?
  }
  rp_unmoved() { # ARM: "unmoved" when the old probe and baseline are where they were and nothing ran
    local R=$RP/runs/pycache/$1
    if [ "$(cat "$R/N1-probe-py_test/marker" "$R/probe-corpora/marker" 2>/dev/null | tr '\n' ' ')" = "old old " ] &&
      cmp -s "$R/N1/baseline.json" "$TMP/rp-old-baseline.json" && [ -z "$(find "$R" -name '_cap30k-*' -o -name 'baseline.cap30k.json')" ] &&
      [ ! -s "$TMP/rp.clog" ] && [ ! -s "$TMP/rp.blog" ]; then echo unmoved; else echo moved; fi
  }
  RPR=$RP/runs/pycache/sbx
  rp_stage sbx
  check "E17 5b reprobe: sbx passes" "$(rp sbx)" "0"
  grep -q 'reprobe.sh:' "$TMP/rp.out" && sed 's/^/    /' "$TMP/rp.out" | tail -5
  check "E17 5b reprobe: the old probe dirs and probe-corpora are renamed aside, contents kept" \
    "$(for c in py_analyze py_short py_test; do cat "$RPR/_cap30k-N1-probe-$c/marker"; done | tr '\n' ' ')/$(cat "$RPR/_cap30k-probe-corpora/marker")" "old old old /old"
  check "E17 5b reprobe: the old baseline.json is kept as baseline.cap30k.json" \
    "$(cmp -s "$RPR/N1/baseline.cap30k.json" "$TMP/rp-old-baseline.json" && echo kept)" "kept"
  check "E17 5b reprobe: classprobe.sh pycache ARM ran once; its probe dirs are new" \
    "$(tr '\n' ';' <"$TMP/rp.clog")/$(cat "$RPR/N1-probe-py_test/marker")" "classprobe pycache sbx;/new"
  check "E17 5b reprobe: baseline.py gets exactly the evaluable seeded dirs, then --probe the new probes" \
    "$(sed -n 's/^argv //p' "$TMP/rp.blog" | sed "s#$RPR#<A>#g")" \
    "<A>/N1/baseline.json <A>/N1-s1 <A>/N1-s3 <A>/N1-s4 --probe <A>/N1-probe-py_analyze <A>/N1-probe-py_short <A>/N1-probe-py_test"
  check "E17 5b reprobe: baseline.py's environment is baseline.sh's (corpus, arm, seeds, skipped)" \
    "$(grep '^E15_BASELINE_' "$TMP/rp.blog" | sed "s#$RP#<R>#g" | tr '\n' ';')" \
    "E15_BASELINE_CORPUS=<R>/corpora/pycache/corpus.jsonl;E15_BASELINE_ARM=sbx;E15_BASELINE_SEEDS=1 3 4;E15_BASELINE_SKIPPED=2:s2:empty_window;"
  rpj() { python3 -c 'import json,sys; print(eval(sys.argv[2], {"b": json.load(open(sys.argv[1]))}))' "$RPR/N1/baseline.json" "$1"; }
  check "E17 5b reprobe: the new baseline carries the pycache point's current signature, the seeded one recorded" \
    "$(rpj 'b["point_sig"]')/$(rpj 'b["reprobe"]["seeded_point_sig"]')/$(rpj 'b["reprobe"]["probe_cap_ms"]')/$(rpj 'b["class_medians"]["py_test"]')" \
    "$rp_cursig/$rp_oldsig/120000/1900"
  rp_lookup() { # ARM BASELINE: rung.sh's baseline resolution at pycache N=8 on fresh-metal
    E15_HOST_PROFILE=fresh-metal E15_ROOT="$RP" E15_TEST_ROOT="$RP" PATH="$SPATH" E15_MANIFEST="$TMP/rp-m.md" bash -c '
      set -e; source "$1"; source "${1%/lib.sh}/points.sh"; E15_PROG=t
      N=8 POINT=pycache ARM=$3; e15_point "$POINT"
      eval "$(sed -n "/^WINDOW=\${E15_WINDOW_S:-900}/,/^# end baseline resolution/p" "$2")"
      echo ok' _ "$RIG/lib.sh" "$RIG/rung.sh" "$1" 2>"$TMP/rpl.err"
  }
  check "E17 5b reprobe: rung.sh accepts the new baseline at pycache N=8" "$(rp_lookup sbx)" "ok"
  cp "$RPR/N1/baseline.cap30k.json" "$RPR/N1/baseline.json"
  check "E17 5b reprobe: rung.sh refuses the cap30k baseline (old point_sig)" \
    "$(rp_lookup sbx)/$(grep -c 'stale N=1 baseline .*point_sig' "$TMP/rpl.err")" "/1"
  check "E17 5b reprobe: a second reprobe is refused (the aside targets exist), nothing run" \
    "$(rp sbx)/$(grep -c 'already exists' "$TMP/rp.out")/$(grep -c . "$TMP/rp.clog")" "1/1/0"

  rp_stage lease-30
  check "E17 5b reprobe: lease-30 passes; its arm in the paths and the environment" \
    "$(rp lease-30)/$(tr -d '\n' <"$TMP/rp.clog")/$(grep -c '^E15_BASELINE_ARM=lease-30$' "$TMP/rp.blog")" "0/classprobe pycache lease-30/1"
  rp_stage sbx "$rp_cur"
  check "E17 5b reprobe: seeded runs already at the current signature pass too" "$(rp sbx)/$(rpj 'b["point_sig"]')" "0/$rp_cursig"

  # refusals: each leaves the old probe and baseline where they were and runs nothing
  rp_stage sbx
  touch "$TMP/rp.wflag"
  check "E17 5b reprobe: a rung's worker running -> refused" \
    "$(rp sbx)/$(grep -c "a rung's worker (e15-worker.service) is running; refusing to preempt it" "$TMP/rp.out")/$(rp_unmoved sbx)" "1/1/unmoved"
  rm -f "$TMP/rp.wflag"
  check "E17 5b reprobe: aws-prelim refused" "$(rp sbx E15_HOST_PROFILE=aws-prelim)/$(grep -c 'E17 runs on fresh-metal only' "$TMP/rp.out")/$(rp_unmoved sbx)" "1/1/unmoved"
  check "E17 5b reprobe: an arm pycache does not run, or none, is a usage error" "$(rp resident-inf)/$(rp control)/$(rp '')/$(rp_unmoved sbx)" "2/2/2/unmoved"
  check "E17 5b reprobe: only the staged copy runs" \
    "$(env E15_HOST_PROFILE=fresh-metal E15_ROOT="$RP" E15_TEST_ROOT="$RP" E15_MANIFEST="$TMP/rp-m.md" PATH="$RPS:$PATH" bash "$RE17/rig/reprobe.sh" sbx >"$TMP/rp.out" 2>&1; echo $?)/$(grep -c 'run the staged copy' "$TMP/rp.out")" "1/1"
  RP_S3=fail rp_stage sbx
  check "E17 5b reprobe: a seeded run that does not hold -> refused (baseline.sh would have died)" \
    "$(rp sbx)/$(grep -c 'N1-s3 does not hold' "$TMP/rp.out")/$(rp_unmoved sbx)" "1/1/unmoved"
  rp_stage sbx
  python3 -c 'import json,sys; b=json.load(open(sys.argv[1])); b["evaluable"]=b["evaluable"][:2]; json.dump(b, open(sys.argv[1],"w"))' "$RPR/N1/baseline.json"
  cp "$RPR/N1/baseline.json" "$TMP/rp-old-baseline.json"
  check "E17 5b reprobe: re-derived seeds that are not the old baseline's -> refused" \
    "$(rp sbx)/$(grep -c 'evaluable seeds 1 3 4 .*the old baseline.json has 1 3' "$TMP/rp.out")/$(rp_unmoved sbx)" "1/1/unmoved"
  rp_stage sbx
  rm "$RPR/N1-s4/record.json"
  check "E17 5b reprobe: a seeded run baseline.sh counted is missing -> refused" \
    "$(rp sbx)/$(grep -c "no $RPR/N1-s4/record.json" "$TMP/rp.out")/$(rp_unmoved sbx)" "1/1/unmoved"
  rp_stage sbx "${rp_old/dataset_mib=256/dataset_mib=64}"
  check "E17 5b reprobe: seeded runs of other point settings -> refused" \
    "$(rp sbx)/$(grep -c 'N1-s1 was recorded with point settings' "$TMP/rp.out")/$(rp_unmoved sbx)" "1/1/unmoved"
  rp_stage sbx
  printf 'changed\n' >>"$RP/src/e17/workload/library.json"
  check "E17 5b reprobe: seeded runs of another library -> refused (rung.sh would refuse the baseline)" \
    "$(rp sbx)/$(grep -c 'library_sha256' "$TMP/rp.out")/$(rp_unmoved sbx)" "1/1/unmoved"
  cp "$RE17/workload/library.json" "$RP/src/e17/workload/library.json"
  rp_stage sbx
  rm "$RPR/N1/baseline.json" "$TMP/rp-old-baseline.json"
  check "E17 5b reprobe: no old baseline.json -> refused (run baseline.sh)" "$(rp sbx)/$(grep -c 'no .*/N1/baseline.json' "$TMP/rp.out")/$(grep -c . "$TMP/rp.clog")" "1/1/0"
  # the path guard: a symlinked probe dir, or an existing aside target, refuses before any move
  rp_stage sbx
  mkdir -p "$TMP/rp-elsewhere"
  ln -s "$TMP/rp-elsewhere" "$RPR/N1-probe-build"
  check "E17 5b reprobe path guard: a probe dir that is a symlink -> refused, nothing moved" \
    "$(rp sbx)/$(grep -c "refusing $RPR/N1-probe-build: a symlink" "$TMP/rp.out")/$(rp_unmoved sbx)" "1/1/unmoved"
  rm "$RPR/N1-probe-build"
  mkdir "$RPR/_cap30k-N1-probe-py_short"
  check "E17 5b reprobe path guard: an existing aside target -> refused, nothing moved" \
    "$(rp sbx)/$(grep -c "_cap30k-N1-probe-py_short already exists" "$TMP/rp.out")/$(rmdir "$RPR/_cap30k-N1-probe-py_short"; rp_unmoved sbx)" "1/1/unmoved"
  rp_stage sbx
  rm -rf "$RPR"
  mkdir -p "$TMP/rp-arm-elsewhere"
  ln -s "$TMP/rp-arm-elsewhere" "$RPR"
  check "E17 5b reprobe path guard: an arm directory that is a symlink -> refused" \
    "$(rp sbx)/$(grep -c "refusing $RPR: a symlink" "$TMP/rp.out")/$(grep -c . "$TMP/rp.clog")" "1/1/0"
  rm -f "$RPR"
  # failures after the moves: the old probe stays aside, no baseline.json is left
  rp_stage sbx
  check "E17 5b reprobe: a classprobe.sh failure dies, no baseline.json, the old one kept aside" \
    "$(rp sbx RP_CPFAIL=1)/$(grep -c 'classprobe.sh pycache sbx failed' "$TMP/rp.out")/$([ -e "$RPR/N1/baseline.json" ] && echo left || echo none)/$(cmp -s "$RPR/N1/baseline.cap30k.json" "$TMP/rp-old-baseline.json" && echo kept)" \
    "1/1/none/kept"
  rp_stage sbx
  check "E17 5b reprobe: a baseline.py failure dies, no baseline.json" \
    "$(rp sbx RP_BFAIL=1)/$(grep -c 'baseline.py failed' "$TMP/rp.out")/$([ -e "$RPR/N1/baseline.json" ] && echo left || echo none)" "1/1/none"
  # fix round 1: the environment check (new probes vs the counted seeded runs)
  rp_stage sbx
  check "E17 5b reprobe env: a template re-stamp since the seeded runs -> dies naming the field, both values and dirs; no baseline" \
    "$(rp sbx RP_PENV='{"template_sha256": "t2"}')/$(grep -c "template_sha256 differs: the new probe $RPR/N1-probe-py_analyze has \"t2\", the seeded run $RPR/N1-s1 has \"t1\"" "$TMP/rp.out")/$(grep -c . "$TMP/rp.blog")/$([ -e "$RPR/N1/baseline.json" ] && echo left || echo none)" \
    "1/1/0/none"
  rp_stage sbx
  check "E17 5b reprobe env: another snapshot guest RAM -> dies" \
    "$(rp sbx RP_PENV='{"snapshot_guest_ram_mb": 256}')/$(grep -c 'snapshot_guest_ram_mb differs: .* has 256, the seeded run .* has 1024' "$TMP/rp.out")" "1/1"
  rp_stage sbx
  check "E17 5b reprobe env: a worker rebuild -> dies" \
    "$(rp sbx RP_PENV='{"worker_bin_sha256": "w2"}')/$(grep -c 'worker_bin_sha256 differs' "$TMP/rp.out")" "1/1"
  rp_stage sbx
  check "E17 5b reprobe env: a field on one side only (even null) is a mismatch" \
    "$(rp sbx RP_PENV='{"resident_patch_sha256": null}')/$(grep -c 'resident_patch_sha256 differs: .* has null, the seeded run .* has (absent)' "$TMP/rp.out")" "1/1"
  rp_stage sbx
  check "E17 5b reprobe env: a field absent from both sides is equal (the sbx happy path has no resident_patch_sha256)" \
    "$(rp sbx)/$(grep -c 'differs' "$TMP/rp.out")" "0/0"
  # fix round 1: a run that failed after the moves names itself and prints the restore commands
  rp_stage sbx
  check "E17 5b reprobe recovery: step 3 fails after one probe (a partial N1-probe-py_analyze and probe-corpora left)" \
    "$(rp sbx RP_CPPARTIAL=1)/$([ -d "$RPR/N1-probe-py_analyze" ] && [ -d "$RPR/probe-corpora" ] && echo partial)" "1/partial"
  check "E17 5b reprobe recovery: the re-run is refused as a failed previous reprobe, nothing run" \
    "$(rp sbx)/$(grep -c 'a previous reprobe failed after the moves' "$TMP/rp.out")/$(grep -c 'no .*/N1/baseline.json (run baseline.sh' "$TMP/rp.out")/$(grep -c . "$TMP/rp.clog")" "1/1/0/0"
  check "E17 5b reprobe recovery: the partial new probe goes to _failed-<ts>-* first, then each _cap30k-* back, then the baseline" \
    "$(grep '^  mv -- ' "$TMP/rp.out" | sed "s#$RPR#<A>#g; s#_failed-[0-9TZ]*-#_failed-<ts>-#" | tr '\n' ';')" \
    "  mv -- <A>/N1-probe-py_analyze <A>/_failed-<ts>-N1-probe-py_analyze;  mv -- <A>/probe-corpora <A>/_failed-<ts>-probe-corpora;  mv -- <A>/_cap30k-N1-probe-py_analyze <A>/N1-probe-py_analyze;  mv -- <A>/_cap30k-N1-probe-py_short <A>/N1-probe-py_short;  mv -- <A>/_cap30k-N1-probe-py_test <A>/N1-probe-py_test;  mv -- <A>/_cap30k-probe-corpora <A>/probe-corpora;  mv -- <A>/N1/baseline.cap30k.json <A>/N1/baseline.json;"
  grep '^  mv -- ' "$TMP/rp.out" >"$TMP/rp-restore.sh"
  bash "$TMP/rp-restore.sh"
  check "E17 5b reprobe recovery: the printed commands restore the arm exactly; the re-run then passes" \
    "$(rp_unmoved sbx)/$(rp sbx)/$(cat "$RPR/N1-probe-py_test/marker")/$(cmp -s "$RPR/N1/baseline.cap30k.json" "$TMP/rp-old-baseline.json" && echo kept)" "unmoved/0/new/kept"
  check "E17 5b reprobe: its only removal is rm -f of the half-written baseline.json; no rm -rf" \
    "$(grep -v '^ *#' "$RE17/rig/reprobe.sh" | grep -c 'rm -rf')/$(grep -v '^ *#' "$RE17/rig/reprobe.sh" | grep -cE '(^|[^a-z])rm ')" "0/1"
  rm -rf "$RP" "$RPS" "$TMP/rp-elsewhere" "$TMP/rp-arm-elsewhere"
fi
echo
if [ "$fails" -eq 0 ]; then
  echo "rig.test.sh: all checks passed"
else
  echo "rig.test.sh: $fails check(s) FAILED"
fi
[ "$fails" -eq 0 ]
