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

# sample.sh under E17C=1 (PLAN-E17C Task 3, ruling R-d): each VM's footprint as the moca worker charges it
# (readLeaseFootprint, moca #974): vm_fp = memory.current - max(file - file_mapped - shmem - file_dirty -
# file_writeback, 0), clamped at 0; vm_dirty = file_dirty. A VM whose memory.stat is missing or lacks a field is
# left out (never 0). With E17C unset the line is byte-identical to the pre-E17c sampler's (golden below).
if [ -f "$RIG/sample.sh" ]; then
  FV="$TMP/fcg17/e15-vms.slice"
  mkvm() { # NAME PROCS CURRENT [STAT-LINES]: a fake VM cgroup; no STAT-LINES -> no memory.stat
    mkdir -p "$FV/$1"
    printf '%s' "$2" >"$FV/$1/cgroup.procs"
    printf '%s\n' "$3" >"$FV/$1/memory.current"
    [ $# -ge 4 ] && printf '%b' "$4" >"$FV/$1/memory.stat"
    return 0
  }
  # vm-a: reclaimable 600000-100000-50000-20000-10000 = 420000 -> 1000000-420000; the *_thp decoys are not the fields
  mkvm vm-a 11 1000000 'anon 300000\nfile 600000\nfile_mapped 100000\nfile_dirty 20000\nfile_writeback 10000\nshmem 50000\nfile_thp 999\nshmem_thp 7\n'
  # vm-b: reclaimable < 0 -> 0, the footprint is memory.current
  mkvm vm-b 12 500000 'file 100\nfile_mapped 200\nshmem 0\nfile_dirty 0\nfile_writeback 0\n'
  # vm-c: no file_writeback -> out of vm_fp; its file_dirty is still a reading
  mkvm vm-c 13 700000 'file 1000\nfile_mapped 0\nshmem 0\nfile_dirty 300\n'
  # vm-d: reclaimable above memory.current -> clamped at 0
  mkvm vm-d 14 1000 'file 5000\nfile_mapped 0\nshmem 0\nfile_dirty 0\nfile_writeback 0\n'
  # vm-e: no memory.stat -> in vm_mem only
  mkvm vm-e 15 2000
  # vm-f: an idle pool cgroup (no process) and the worker's service cgroup: in nothing
  mkvm vm-f '' 9 'file 1\nfile_mapped 0\nshmem 0\nfile_dirty 0\nfile_writeback 0\n'
  mkvm microvm-worker.service 16 9 'file 1\nfile_mapped 0\nshmem 0\nfile_dirty 0\nfile_writeback 0\n'
  s17() { # [VAR=VALUE...]: one sampler run over the fake tree -> its first line, t and ts normalised
    rm -f "$OUTS"
    env E15_PROC="$FP" E15_DISK_DEV=nosuch E15_DISK_PATH="$TMP/nodisk" E15_SLICE_DIR="$TMP/fcg17" \
      E15_STATS_URL=http://127.0.0.1:1/x "$@" bash "$RIG/sample.sh" "$OUTS" "$(date +%s)" 1.2 >/dev/null 2>&1
    head -1 "$OUTS" | sed -E 's/^\{"t":[0-9.-]+,"ts":[0-9.]+,/{"t":T,"ts":TS,/'
  }
  base='{"t":T,"ts":TS,"mem_available_kb":100,"page_cache_kb":5,"slice_mem_bytes":null,"slice_cpu_usec":null,"e15_mem_bytes":null,"e15_cpu_usec":null,"psi_cpu_some_avg10":null,"psi_mem_some_avg10":null,"psi_mem_full_avg10":null,"slice_psi_mem_some_avg10":null,"disk_used_pct":null,"disk_used_kb":null,"procs":3,"vm_mem":{"vm-a":1000000,"vm-b":500000,"vm-c":700000,"vm-d":1000,"vm-e":2000}'
  check "sample.sh E17C=1: vm_fp and vm_dirty beside vm_mem, the line otherwise unchanged" \
    "$(s17 E17C=1)" "$base"',"vm_fp":{"vm-a":580000,"vm-b":500000,"vm-d":0},"vm_dirty":{"vm-a":20000,"vm-b":0,"vm-c":300,"vm-d":0}}'
  check "sample.sh E17C unset: the line is byte-identical to the pre-E17c sampler's" "$(s17)" "$base}"
  check "sample.sh E17C=0 (anything but 1): unchanged" "$(s17 E17C=0)" "$base}"
  check "sample.sh E17C=1: a VM missing memory.stat or a field is left out of vm_fp, never 0" \
    "$(s17 E17C=1 >/dev/null; head -1 "$OUTS" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(",".join(sorted(set(d["vm_mem"]) - set(d["vm_fp"]))), ",".join(sorted(set(d["vm_mem"]) - set(d["vm_dirty"]))))')" "vm-c,vm-e vm-e"
  # The switch reaches the sampler as rung.sh starts it: an E17C=1 environment, lib.sh sourced (its profile
  # exports E17B=1 too), then a plain `bash sample.sh` child -- rung.sh's own launch line, pinned below.
  rm -f "$OUTS"
  E17C=1 E15_PROC="$FP" E15_DISK_DEV=nosuch E15_DISK_PATH="$TMP/nodisk" E15_SLICE_DIR="$TMP/fcg17" E15_STATS_URL=http://127.0.0.1:1/x \
    bash -c 'source "$1"; bash "$2" "$3" "$(date +%s)" 1.2' _ "$RIG/lib.sh" "$RIG/sample.sh" "$OUTS" >/dev/null 2>&1
  check "sample.sh: E17C=1 reaches the sampler through lib.sh as rung.sh starts it" "$(head -1 "$OUTS" | grep -c '"vm_fp":{"vm-a":580000,')" "1"
  check "rung.sh: the sampler is a plain bash child (inherits E17C; no env -i, no unset)" \
    "$(grep -c '^bash "\$HERE/sample.sh" "\$DIR/samples.jsonl" "\$launch_ts" "\$((WARMUP + WINDOW + 120))" &$' "$RIG/rung.sh")/$(grep -cE 'unset[^#]*E17C|export -n[^#]*E17C' "$RIG/rung.sh" "$RIG/lib.sh" | awk -F: '{s+=$NF} END{print s}')" "1/0"
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
  "sudo -n env CONTAINERS_STORAGE_CONF=$TROOT/containers/storage.conf CONTAINERS_CONF=$TROOT/containers/containers.conf podman 2 "
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
  check "e17 sync.sh: E17_RIG_HOST and E17_RIG_KEY override the AWS default" \
    "$(grep -c '^H=\${E17_RIG_HOST:-ubuntu@\${RIG_IP' "$SYNC17")/$(grep -c '^K=\${E17_RIG_KEY:-\$HOME/.ssh/id_ed25519}$' "$SYNC17")" "1/1"
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
  # E17b (ruling E17B-R21): under E17B=1 bringup.sh also builds the D=192 template of point squeeze-256
  bu_stage
  printf 'E17B_MOCA_PIN=%s\n' 1111111111111111111111111111111111111111 >"$TMP/bu-e17b-pins.sh"
  check "E17b bringup: under E17B=1 it also builds d192 (squeeze-256), with the same recipe (1536 MiB, seed 1, the staged wheels)" \
    "$(bu E17B=1 E15_TEST_PINS="$TMP/bu-e17b-pins.sh")/$(sed 's/ S=.*//' "$TMP/bu.builds" | tr '\n' ' ')/$(grep -c "^build D=192 S=1 M=1536 wheels=$BR17/wheels-pycache rootfs=$BR17/rootfs-ro.mnt.[A-Za-z0-9]* out=$BR17/template-pycache-d192/workspace.img mounted=1\$" "$TMP/bu.builds")" \
    "0/build D=64 build D=256 build D=768 build D=192 /1"
  check "E17b bringup: d192 gets its stamp, BUILD and manifest note like the others" \
    "$([ -s "$BR17/state/template-pycache-d192" ] && [ "$(cat "$BR17/state/template-pycache-d192")" = "$(tsha 192)" ] && echo stamp)/$(cmp -s "$BR17/template-pycache-d192/BUILD" "$BR17/template-pycache-d192/workspace.img" && echo build)/$(grep -c "E17 built $BR17/template-pycache-d192/workspace.img" "$TMP/bu-m.md")" "stamp/build/1"
  bu_stage
  bu >/dev/null
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
  check "E17 path guard: D=192 (E17b squeeze-256) only under E17B=1" \
    "$(ctg "$BR17/template-pycache-d192/workspace.img" 192)/$(E17B=1 ctg "$BR17/template-pycache-d192/workspace.img" 192)" "refused/pass"
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
  # gc: the E17b corpora (E17B=1); gcu: E17B unset (the sealed E17a command); gc0: E17_TMPFS_SHARE=0 explicitly
  gc() { E17B=1 E17_CORPORA="$GC" E17_GAPS="$E17D/extract/testdata/gaps-20.jsonl" bash "$E17D/rig/gen_corpora.sh" "$@" >"$TMP/gc.out" 2>&1; echo $?; }
  gcu() { env -u E17B E17_CORPORA="$GC" E17_GAPS="$E17D/extract/testdata/gaps-20.jsonl" bash "$E17D/rig/gen_corpora.sh" "$@" >"$TMP/gc.out" 2>&1; echo $?; }
  E17C_FIXPIN_GC=2222222222222222222222222222222222222222
  gc0() { env -u E17B E17_TMPFS_SHARE=0 E17_CORPORA="$GC" E17_GAPS="$E17D/extract/testdata/gaps-20.jsonl" bash "$E17D/rig/gen_corpora.sh" >"$TMP/gc.out" 2>&1; echo $?; }
  gcr() { python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"r": r}))' "$GC/$1/corpus-report.json" "$2"; }
  # gcc: E17C=1 alone (PLAN-E17C Task 4: E17C=1 implies E17B=1, so the E17b corpora)
  gcc() { env -u E17B E17C=1 E17_CORPORA="$GC" E17_GAPS="$E17D/extract/testdata/gaps-20.jsonl" bash "$E17D/rig/gen_corpora.sh" >"$TMP/gc.out" 2>&1; echo $?; }
  check "E17c gen_corpora: E17C=1 alone (E17B unset) is E17B=1: E17_TMPFS_SHARE defaults to 0.5" \
    "$(gcc)/$(gcr pycache '(r["tmpfs_share"], r["tmpfs_sessions"])')/$(gcr pycache-low '(r["tmpfs_share"], r["tmpfs_sessions"])')" "0/(0.5, 200)/(0.5, 200)"
  gcd() { # POINT -> "class=dur_ms/work_ms" for every distinct pair in the corpus
    python3 -c 'import json,sys
s=set()
for l in open(sys.argv[1]):
    for c in json.loads(l)["calls"]: s.add("%s=%d/%d" % (c["class"], c["dur_ms"], c["work_ms"]))
print(" ".join(sorted(s)))' "$GC/$1/corpus.jsonl"
  }
  # E17c Task 10 (SPEC §13.5, R45): --gate-256 GATE.json (a passing gate-256.json) also writes pycache-256, the 256 MiB
  # points' corpus: pycache's arguments with py_analyze at the gate's measured ms, so it has its own corpus hash
  # final review M5: the gate must match library-256.json's committed scale and E17C_MOCA_PIN (E17C_PINS_FILE and
  # E17_LIBRARY_256 point the script at a fixture pin and a library at scale 8 here)
  printf 'E17C_MOCA_PIN=%s\n' "$E17C_FIXPIN_GC" >"$TMP/gc-pins.sh"
  gclib() { python3 -c 'import json,sys; sys.path.insert(0, sys.argv[3]); import gate256; l=json.load(open(sys.argv[1])); l["classes"]["py_analyze"][0]["cmd"]=gate256.analyze_cmd(int(sys.argv[2])); json.dump(l, open(sys.argv[4], "w"))' \
    "$E17D/workload/library-256.json" "$1" "$E17D/analysis" "$TMP/gc-lib256.json"; }
  gclib 8
  gcg() { env -u E17B E17C=1 E17C_PINS_FILE="$TMP/gc-pins.sh" E17_LIBRARY_256="$TMP/gc-lib256.json" E17_CORPORA="$GC" E17_GAPS="$E17D/extract/testdata/gaps-20.jsonl" bash "$E17D/rig/gen_corpora.sh" "$@" >"$TMP/gc.out" 2>&1; echo $?; }
  printf '{"stage": "gate-256", "pass": true, "chosen_scale": 8, "py_analyze_ms": 4321.5, "moca_commit": "%s"}\n' "$E17C_FIXPIN_GC" >"$TMP/g256.json"
  rm -rf "$GC"
  check "E17c gen_corpora: E17C=1 without --gate-256 writes no pycache-256, and says why" \
    "$(gcg)/$([ -e "$GC/pycache-256" ] && echo there || echo none)/$(grep -c 'no pycache-256 corpus.*--gate-256' "$TMP/gc.out")" "0/none/1"
  cp "$GC/pycache/corpus.jsonl" "$TMP/gc-p.jsonl"
  cp "$GC/pycache-low/corpus.jsonl" "$TMP/gc-pl.jsonl"
  check "E17c gen_corpora --gate-256: also pycache-256, pycache's arguments (duty 0.095, 400 sessions, seed 1, tmpfs share 0.5)" \
    "$(gcg --gate-256 "$TMP/g256.json")/$(gcr pycache-256 '(r["duty_target"], r["sessions"], r["seed"], r["min_turns"], r["tmpfs_share"])')" "0/(0.095, 400, 1, 4, 0.5)"
  check "E17c gen_corpora --gate-256: py_analyze at the gate's ms (rounded), the other classes as pycache's; the report names the input" \
    "$(gcd pycache-256)/$(gcr pycache-256 'r["durations_from"]["file"]')" \
    "py_analyze=4322/4322 py_grep=2200/2200 py_import=2000/2000 py_shmem=100/100 py_short=300/300 py_test=60000/60000/durations-256.json"
  check "E17c gen_corpora --gate-256: its own corpus hash; pycache and pycache-low byte-identical to the run without it" \
    "$([ "$(gcr pycache-256 'r["corpus_sha256"]')" != "$(gcr pycache 'r["corpus_sha256"]')" ] && echo own)/$([ "$(gcr pycache-256 'r["corpus_sha256"]')" = "$(sha256sum "$GC/pycache-256/corpus.jsonl" | cut -d' ' -f1)" ] && echo match)/$(cmp -s "$TMP/gc-p.jsonl" "$GC/pycache/corpus.jsonl" && cmp -s "$TMP/gc-pl.jsonl" "$GC/pycache-low/corpus.jsonl" && echo same)" \
    "own/match/same"
  printf '{"py_analyze": 18250.6, "py_test": 57100, "py_import": 1980.6, "py_grep": 2150, "py_short": 412}\n' >"$TMP/cal256.json"
  check "E17c gen_corpora --gate-256 with --durations-from: the measured durations, py_analyze replaced by the gate's" \
    "$(gcg --durations-from "$TMP/cal256.json" --gate-256 "$TMP/g256.json")/$(gcd pycache-256)/$(gcd pycache | cut -d' ' -f1)" \
    "0/py_analyze=4322/4322 py_grep=2150/2150 py_import=1981/1981 py_shmem=100/100 py_short=412/412 py_test=57100/57100/py_analyze=18251/18251"
  cp "$GC/pycache-256/corpus.jsonl" "$TMP/gc-256.jsonl"
  printf '{"stage": "gate-256", "pass": false, "chosen_scale": null, "py_analyze_ms": null, "reason": "scale 1: OOM"}\n' >"$TMP/g256-fail.json"
  check "E17c gen_corpora --gate-256: a gate that did not pass is refused (exit 1, naming it), pycache-256 left as it was" \
    "$(gcg --gate-256 "$TMP/g256-fail.json")/$(grep -c 'g256-fail.json did not pass' "$TMP/gc.out")/$(cmp -s "$TMP/gc-256.jsonl" "$GC/pycache-256/corpus.jsonl" && echo kept)" "1/1/kept"
  check "E17c gen_corpora --gate-256: the corpus report records the gate file's sha256, chosen scale and moca_commit" \
    "$(gcg --gate-256 "$TMP/g256.json")/$(gcr pycache-256 'sorted(r["gate_256"].items())')" \
    "0/[('chosen_scale', 8), ('file', 'g256.json'), ('moca_commit', '$E17C_FIXPIN_GC'), ('sha256', '$(sha256sum "$TMP/g256.json" | cut -d' ' -f1)')]"
  cp "$GC/pycache-256/corpus.jsonl" "$TMP/gc-256.jsonl"
  gclib 16
  check "E17c gen_corpora --gate-256: refused (exit 1, nothing written) when library-256.json's scale is not the gate's chosen one" \
    "$(gcg --gate-256 "$TMP/g256.json")/$(grep -c 'gc-lib256.json carries scale 16, but .*g256.json chose 8' "$TMP/gc.out")/$(cmp -s "$TMP/gc-256.jsonl" "$GC/pycache-256/corpus.jsonl" && echo kept)" "1/1/kept"
  gclib 0
  check "E17c gen_corpora --gate-256: refused while library-256.json carries the placeholder 0" \
    "$(gcg --gate-256 "$TMP/g256.json")/$(grep -c 'carries scale 0, but' "$TMP/gc.out")" "1/1"
  gclib 8
  printf '{"stage": "gate-256", "pass": true, "chosen_scale": 8, "py_analyze_ms": 4321.5, "moca_commit": "%s"}\n' 3333333333333333333333333333333333333333 >"$TMP/g256-other.json"
  check "E17c gen_corpora --gate-256: refused when the gate's moca_commit is not E17C_MOCA_PIN" \
    "$(gcg --gate-256 "$TMP/g256-other.json")/$(grep -c 'moca_commit "3333333333333333333333333333333333333333", not E17C_MOCA_PIN '"$E17C_FIXPIN_GC" "$TMP/gc.out")/$(cmp -s "$TMP/gc-256.jsonl" "$GC/pycache-256/corpus.jsonl" && echo kept)" "1/1/kept"
  check "E17c gen_corpora --gate-256: refused with E17C unset (E17B=1 or neither), and without a file" \
    "$(gc --gate-256 "$TMP/g256.json")/$(gcu --gate-256 "$TMP/g256.json")/$(gcg --gate-256 "$TMP/nope.json")" "2/2/2"
  check "E17 gen_corpora: placeholders without --durations-from, and it says so" \
    "$(gc)/$(gcd pycache)/$(grep -c 'placeholder durations' "$TMP/gc.out")" "0/py_analyze=15000/15000 py_grep=2200/2200 py_import=2000/2000 py_shmem=100/100 py_short=300/300 py_test=60000/60000/1"
  check "E17b gen_corpora: under E17B=1 E17_TMPFS_SHARE defaults to 0.5 (200 of 400 sessions flagged tmpfs, both corpora)" \
    "$(gcr pycache '(r["tmpfs_share"], r["tmpfs_sessions"])')/$(gcr pycache-low '(r["tmpfs_share"], r["tmpfs_sessions"])')/$(grep -c '(200 tmpfs, share 0.5)' "$TMP/gc.out")" \
    "(0.5, 200)/(0.5, 200)/2"
  check "E17 gen_corpora: pycache at duty 0.095, pycache-low at 0.015; 400 sessions, seed 1, min-turns 4" \
    "$(gcr pycache '(r["duty_target"], r["sessions"], r["seed"], r["min_turns"])')/$(gcr pycache-low '(r["duty_target"], r["sessions"], r["seed"], r["min_turns"])')" \
    "(0.095, 400, 1, 4)/(0.015, 400, 1, 4)"
  check "E17 gen_corpora: same as pycache_corpus.py run directly (byte-identical)" \
    "$(python3 "$E17D/extract/pycache_corpus.py" --gaps-from "$E17D/extract/testdata/gaps-20.jsonl" --duty 0.015 --sessions 400 --seed 1 --min-turns 4 --tmpfs-share 0.5 --out "$TMP/gc-direct" >/dev/null 2>&1; cmp -s "$TMP/gc-direct/corpus.jsonl" "$GC/pycache-low/corpus.jsonl" && echo same)" "same"
  cp "$GC/pycache/corpus.jsonl" "$TMP/gc-placeholder.jsonl"
  printf '{"py_analyze": 18250.6, "py_test": 57100, "py_import": 1980.6, "py_grep": 2150, "py_short": 412}\n' >"$TMP/cal.json"
  check "E17 gen_corpora --durations-from: every call carries the measured durations, both corpora" \
    "$(gc --durations-from "$TMP/cal.json")/$(gcd pycache)/$(gcd pycache-low)" \
    "0/py_analyze=18251/18251 py_grep=2150/2150 py_import=1981/1981 py_shmem=100/100 py_short=412/412 py_test=57100/57100/py_analyze=18251/18251 py_grep=2150/2150 py_import=1981/1981 py_shmem=100/100 py_short=412/412 py_test=57100/57100"
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
  check "E17b gen_corpora: E17_TMPFS_SHARE=0 writes the E17a corpora (no py_shmem, no tmpfs; pycache_corpus.py --tmpfs-share 0 byte for byte)" \
    "$(gc0)/$(gcd pycache-low)/$(gcr pycache '(r["tmpfs_share"], r["tmpfs_sessions"])')/$(grep -c '"tmpfs"' "$GC/pycache/corpus.jsonl")/$(python3 "$E17D/extract/pycache_corpus.py" --gaps-from "$E17D/extract/testdata/gaps-20.jsonl" --duty 0.015 --sessions 400 --seed 1 --min-turns 4 --tmpfs-share 0 --out "$TMP/gc-direct0" >/dev/null 2>&1; cmp -s "$TMP/gc-direct0/corpus.jsonl" "$GC/pycache-low/corpus.jsonl" && echo same)" \
    "0/py_analyze=15000/15000 py_grep=2200/2200 py_import=2000/2000 py_short=300/300 py_test=60000/60000/(0.0, 0)/0/same"
  check "E17 gen_corpora (M3): with E17B unset the default is the E17a corpora (tmpfs share 0, the same bytes as E17_TMPFS_SHARE=0)" \
    "$(gc0)/$(cp "$GC/pycache/corpus.jsonl" "$TMP/gc-share0.jsonl"; gcu)/$(gcr pycache '(r["tmpfs_share"], r["tmpfs_sessions"])')/$(grep -c '"tmpfs"' "$GC/pycache/corpus.jsonl")/$(cmp -s "$TMP/gc-share0.jsonl" "$GC/pycache/corpus.jsonl" && echo same)" \
    "0/0/(0.0, 0)/0/same"
  check "E17 gen_corpora: a missing CAL.json, or another argument, is a usage error" \
    "$(gc --durations-from "$TMP/nope.json")/$(gc --bogus)" "2/2"
  check "E17 gen_corpora: the brief's gap source and corpora root are the defaults" \
    "$(grep -c 'E17_GAPS:-/tmp/kagenti/e16-corpus-default/corpus.jsonl' "$E17D/rig/gen_corpora.sh")/$(grep -c 'E17_CORPORA:-/tmp/kagenti/e17-corpora' "$E17D/rig/gen_corpora.sh")" "1/1"
  rm -rf "$GC" "$TMP/gc-direct" "$TMP/gc-direct0"
fi

# smoke.sh: the rung line per arm, and its refusals (it is never run here: it starts workers)
if [ -f "$E17D/rig/smoke.sh" ]; then
  check "E17 smoke: one rung.sh ARM 1 pycache per arm, 60 s warm-up, 120 s window, tag smoke" \
    "$(grep -c '^ARMS=(sbx resident-300 lease-30 lease-120)$' "$E17D/rig/smoke.sh")/$(grep -c 'E15_WARMUP_S=60 E15_WINDOW_S=120 E15_TAG=smoke E15_START_ZERO=\$START_ZERO bash "\$RUNG" "\$arm" 1 "\$POINT"' "$E17D/rig/smoke.sh")/$(grep -c '^POINT=pycache$' "$E17D/rig/smoke.sh")" "1/1/1"
  check "E17 smoke: the sha256 is checked against the D=256 template's BUILD, warmcold.py (warmcold_lease.py on ship-*) on each rung" \
    "$(grep -c '^BUILD=\${E15_P_TEMPLATE%/\*}/BUILD$' "$E17D/rig/smoke.sh")/$(grep -c 'python3 "\$E17_SRC/analysis/\$wc" "\$d"' "$E17D/rig/smoke.sh")" "1/1"
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
  # E17b (Task 4 review C4-1): the resident and E17a lease arms need the resident build, which E17B=1 skips
  printf 'E17B_MOCA_PIN=%s\n' 1111111111111111111111111111111111111111 >"$TMP/sm-e17b-pins.sh"
  printf '#!/bin/sh\n' >"$SM/bin/microvm-worker-e17b"
  chmod +x "$SM/bin/microvm-worker-e17b"
  mkdir -p "$SM/snapshots/e17b-11111111-1024" && echo '{}' >"$SM/snapshots/e17b-11111111-1024/manifest.json"
  check "E17 smoke (stubbed): under E17B=1 the arms are sbx and the ship arms only, in that order" \
    "$(smoke E17B=1 E15_TEST_PINS="$TMP/sm-e17b-pins.sh")/$(cut -d' ' -f2 "$TMP/sm.rlog" | tr '\n' ' ')" "0/sbx ship-30 ship-120 ship-300 "
  check "E17b smoke (stubbed, M2): ship rungs are read by warmcold_lease.py (first_lease in the counts), sbx by warmcold.py" \
    "$(smoke E17B=1 E15_TEST_PINS="$TMP/sm-e17b-pins.sh")/$(grep -c '^smoke pycache/ship-[0-9]*/N1-smoke: warm [0-9]* cold [0-9]* unknown [0-9]* failed_no_vm [0-9]* first_lease [0-9]* disagreements [0-9]* (holds=True)$' "$TMP/sm.out")/$(grep -c '^smoke pycache/sbx/N1-smoke: warm [0-9]* cold [0-9]* unknown [0-9]* (holds=True)$' "$TMP/sm.out")/$([ -f "$SM/runs/pycache/ship-300/N1-smoke/warmcold-report.json" ] && grep -c '"first_lease"' "$SM/runs/pycache/ship-300/N1-smoke/warmcold-report.json")" \
    "0/3/1/1"
  check "E17 smoke (stubbed): E17B=0 keeps the E17 arms" "$(smoke E17B=0)/$(cut -d' ' -f2 "$TMP/sm.rlog" | tr '\n' ' ')" "0/sbx resident-300 lease-30 lease-120 "
  rm -f "$SM/bin/microvm-worker-e17b"
  check "E17 smoke (stubbed): warmcold counts printed per rung, the pass line names the BUILD sha256" \
    "$(grep -c '^smoke pycache/[a-z0-9-]*/N1-smoke: warm [0-9]* cold [0-9]* unknown [0-9]* (holds=True)$' "$TMP/sm.out")/$(grep -c "analyze sha256 = BUILD dataset_sha256 ($SMSHA)" "$TMP/sm.out")" "4/1"
  # E17c (PLAN-E17C Task 4, carried from Task 2): E17C=1 smokes E17c's arms, sbx ship-300 ship-300-nd
  printf '#!/bin/sh\n' >"$SM/bin/microvm-worker-e17b"
  chmod +x "$SM/bin/microvm-worker-e17b"
  printf 'E17B_MOCA_PIN=%s\nE17C_MOCA_PIN=%s\n' 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 >"$TMP/sm-e17c-pins.sh"
  mkdir -p "$SM/snapshots/e17c-22222222-1024" && echo '{}' >"$SM/snapshots/e17c-22222222-1024/manifest.json"
  check "E17c smoke (stubbed): under E17C=1 (E17B unset) the arms are sbx ship-300 ship-300-nd, in that order" \
    "$(smoke E17C=1 E15_TEST_PINS="$TMP/sm-e17c-pins.sh")/$(cut -d' ' -f2 "$TMP/sm.rlog" | tr '\n' ' ')" "0/sbx ship-300 ship-300-nd "
  check "E17c smoke (stubbed): E17B=1 alone keeps E17b's arms" \
    "$(smoke E17B=1 E15_TEST_PINS="$TMP/sm-e17b-pins.sh")/$(cut -d' ' -f2 "$TMP/sm.rlog" | tr '\n' ' ')" "0/sbx ship-30 ship-120 ship-300 "
  rm -f "$SM/bin/microvm-worker-e17b"
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
  check "E17c reprobe: the usage text lists ship-300-nd under E17C=1" \
    "$(grep -c 'usage: reprobe.sh ARM .*with E17C=1: sbx ship-300 ship-300-nd' "$RE17/rig/reprobe.sh")" "1"
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
# --- E17b profile (E17B=1: its own moca pin and checkout; the sealed procedures are untouched) ---
RE17B="$(cd "$RIG/../../e17-lease/rig" && pwd)"
e17b_pin_file="$RE17B/e17b-pins.sh"
t17() { # t17 E17B-value|unset EXPR [VAR=val ...]: evaluate EXPR after sourcing lib.sh at a scratch root
  local ev=$1 expr=$2
  shift 2
  if [ "$ev" = unset ]; then
    env -u E17B "$@" E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; eval "$2"' _ "$RIG/lib.sh" "$expr" 2>&1
  else
    env E17B="$ev" "$@" E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; eval "$2"' _ "$RIG/lib.sh" "$expr" 2>&1
  fi
}
rm -rf "$TROOT/state"
E17B_FIXPIN=1111111111111111111111111111111111111111
printf 'E17B_MOCA_PIN=%s\n' "$E17B_FIXPIN" >"$TMP/e17b-test-pins.sh"
test_e17b_pin_is_a_full_sha() {
  local want_pin
  want_pin=$(grep -E '^E17B_MOCA_PIN=' "$e17b_pin_file" | cut -d= -f2)
  check "e17b: pins file exists and sets E17B_MOCA_PIN to a full 40-hex sha" "$(printf '%s' "$want_pin" | grep -cE '^[0-9a-f]{40}$')" "1"
  check "e17b: the pins file says the placeholder must be replaced before any rig run" "$(grep -ci 'replace.*before any rig run' "$e17b_pin_file")" "1"
  check "e17b: pins file is not sourced (and E17B_MOCA_PIN not defined) with E17B unset" "$(t17 unset 'echo "${E17B_MOCA_PIN:-none}"')" "none"
  check "e17b: a real sha is accepted by e17b_require_pin" "$(t17 1 'e17b_require_pin && echo ok' E15_TEST_PINS="$TMP/e17b-test-pins.sh")" "ok"
  # The placeholder is a fixture: the repo's e17b-pins.sh holds the real pin once bring-up sets it.
  printf 'E17B_MOCA_PIN=0000000000000000000000000000000000000000\n' >"$TMP/e17b-placeholder.sh"
  check "e17b: the placeholder sha is refused, naming the pin file" "$(t17 1 '(e17b_require_pin)' E15_TEST_PINS="$TMP/e17b-placeholder.sh" 2>&1 | grep -c 'E17B_MOCA_PIN.*placeholder')/$(t17 1 '(e17b_require_pin) >/dev/null 2>&1; echo $?' E15_TEST_PINS="$TMP/e17b-placeholder.sh")" "1/1"
  check "e17b: a short or non-hex pin is refused" \
    "$(printf 'E17B_MOCA_PIN=abc123\n' >"$TMP/e17b-bad1.sh"; t17 1 '(e17b_require_pin) >/dev/null 2>&1; echo $?' E15_TEST_PINS="$TMP/e17b-bad1.sh")/$(printf 'E17B_MOCA_PIN=ZZZ%s\n' "${E17B_FIXPIN:3}" >"$TMP/e17b-bad2.sh"; t17 1 '(e17b_require_pin) >/dev/null 2>&1; echo $?' E15_TEST_PINS="$TMP/e17b-bad2.sh")" "1/1"
  check "e17b: setup.sh and rung.sh call e17b_require_pin when E17B=1, before any host change" \
    "$(grep -c '^\[ "\${E17B:-}" != 1 \] || e17b_require_pin$' "$RIG/setup.sh")/$(grep -c '^\[ "\${E17B:-}" != 1 \] || { e17b_require_pin && e17b_require_build; }$' "$RIG/rung.sh")" "1/1"
  check "e17b: a rung with E17B=1 and the placeholder pin refuses to start (exit 1, names the pin)" \
    "$(env E17B=1 E15_TEST_PINS="$TMP/e17b-placeholder.sh" E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash "$RIG/rung.sh" sbx 1 default >"$TMP/e17b-rung.out" 2>&1; echo $?)/$(grep -c 'E17B_MOCA_PIN.*placeholder' "$TMP/e17b-rung.out")" "1/1"
}
test_e17b_profile_off_is_unchanged() {
  check "e17b off: E15_MOCA_PIN is the old pin" "$(t17 unset 'echo $E15_MOCA_PIN')" "c13d55649777e69ec7649d6fa8c08f4acb1f4e2e"
  check "e17b off: E15_MOCA is \$E15_ROOT/moca" "$(t17 unset 'echo $E15_MOCA')" "$TROOT/moca"
  check "e17b off: E17B=0 or empty also leaves the sealed values" "$(t17 0 'echo $E15_MOCA_PIN $E15_MOCA')/$(t17 '' 'echo $E15_MOCA_PIN $E15_MOCA')" "c13d55649777e69ec7649d6fa8c08f4acb1f4e2e $TROOT/moca/c13d55649777e69ec7649d6fa8c08f4acb1f4e2e $TROOT/moca"
  check "e17b off: no E17B variable is defined" "$(t17 unset 'compgen -v E17B | wc -l | tr -d " "')" "0"
  if git -C "$RIG" rev-parse --verify -q e17b/plan:experiments/e15-session-density/rig/lib.sh >/dev/null; then
    mkdir -p "$TMP/oldrig"
    git -C "$RIG" show e17b/plan:experiments/e15-session-density/rig/lib.sh >"$TMP/oldrig/lib.sh"
    cp "$RIG/pins.sh" "$TMP/oldrig/pins.sh"
    dump() { env -u E17B E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; for v in $(compgen -v E15_ | sort); do declare -p "$v"; done' _ "$1" 2>&1 | sha256sum; }
    check "e17b off: every E15_* variable lib.sh defines equals the e17b/plan lib.sh's" "$([ "$(dump "$RIG/lib.sh")" = "$(dump "$TMP/oldrig/lib.sh")" ] && echo same || echo differ)" "same"
  else
    check "e17b off: e17b/plan ref available for the full-variable comparison" "missing" "present"
  fi
  check "e17b: pins.sh is not touched by the profile (no E17B in it)" "$(grep -c 'E17B' "$RIG/pins.sh")" "0"
}
test_e17b_profile_on() {
  check "e17b on: E15_MOCA_PIN follows E17B_MOCA_PIN" "$(t17 1 'echo $E15_MOCA_PIN' E15_TEST_PINS="$TMP/e17b-test-pins.sh")" "$E17B_FIXPIN"
  check "e17b on: E15_MOCA is \$E15_ROOT/moca-e17b" "$(t17 1 'echo $E15_MOCA' E15_TEST_PINS="$TMP/e17b-test-pins.sh")" "$TROOT/moca-e17b"
  check "e17b on: every other pins.sh pin is unchanged" \
    "$([ "$(t17 unset 'for n in "${E15_PINS[@]}"; do echo "$n=${!n}"; done' | sha256sum)" = "$(t17 1 'for n in "${E15_PINS[@]}"; do echo "$n=${!n}"; done' E15_TEST_PINS="$TMP/e17b-test-pins.sh" | sha256sum)" ] && echo same || echo differ)" "same"
  check "e17b on: the snapshot key in setup.sh is built from E15_MOCA_PIN on both profiles (so it follows the pin)" "$(grep -c 'snap_key="\$E15_MOCA_PIN-\$wheels_key-' "$RIG/setup.sh")" "2"
  check "e17b on: setup.sh's clone, node and stock-go stamps use E15_MOCA and E15_MOCA_PIN (node stamp is node-e17b under E17B=1)" \
    "$(grep -c 'stamp_ok "\$NODE_STAMP" "\$E15_MOCA_PIN"' "$RIG/setup.sh")/$(grep -c 'stamp_ok "\$(stock_stamp)" "\$E15_MOCA_PIN"' "$RIG/setup.sh")" "1/1"
  check "e17b on: setup.sh keeps the sealed node stamp apart (NODE_STAMP=node-e17b under E17B=1, node otherwise)" \
    "$(grep -c '^NODE_STAMP=node$' "$RIG/setup.sh")/$(grep -c 'NODE_STAMP=node-e17b' "$RIG/setup.sh")" "1/1"
  check "e17b on: setup.sh skips the resident build (apply.sh) when E17B=1, runs it otherwise" \
    "$(grep -B1 'k=\$(src_key resident)' "$RIG/setup.sh" | grep -c 'E17B')/$(awk '/^if \[ "\$\{E17B:-\}" != 1 \]; then$/{g=1} g&&/^k=\$\(src_key resident\)$/{k=1} k&&/resident\/apply\.sh/{a=1} a&&/^fi$/{print "guarded"; exit}' "$RIG/setup.sh")" "1/guarded"
}
test_e17b_pin_is_a_full_sha
test_e17b_profile_off_is_unchanged
test_e17b_profile_on
# --- E17c profile (E17C=1: E17B=1 with its own moca pin and checkout; with E17C unset nothing changes) ---
e17c_pin_file="$RE17B/e17c-pins.sh"
t17c() { # t17c E17C-value|unset E17B-value|unset EXPR [VAR=val ...]: evaluate EXPR after sourcing lib.sh at a scratch root
  local cv=$1 bv=$2 expr=$3 ea=()
  shift 3
  if [ "$cv" = unset ]; then ea+=(-u E17C); else ea+=(E17C="$cv"); fi
  if [ "$bv" = unset ]; then ea=(-u E17B "${ea[@]}"); else ea+=(E17B="$bv"); fi
  env "${ea[@]}" "$@" E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; eval "$2"' _ "$RIG/lib.sh" "$expr" 2>&1
}
E17C_FIXPIN=2222222222222222222222222222222222222222
printf 'E17C_MOCA_PIN=%s\n' "$E17C_FIXPIN" >"$TMP/e17c-test-pins.sh"
test_e17c_pin_is_a_full_sha() {
  local want_pin
  want_pin=$(grep -E '^E17C_MOCA_PIN=' "$e17c_pin_file" | cut -d= -f2)
  check "e17c: pins file exists and sets E17C_MOCA_PIN to 40 hex digits (the placeholder until moca #974 merges)" "$(printf '%s' "$want_pin" | grep -cE '^[0-9a-f]{40}$')" "1"
  check "e17c: the pins file says the placeholder must be replaced before any rig run" "$(grep -ci 'replace.*before any rig run' "$e17c_pin_file")" "1"
  check "e17c: pins file is not sourced (E17C_MOCA_PIN undefined) with E17C unset, with or without E17B=1" \
    "$(t17c unset unset 'echo "${E17C_MOCA_PIN:-none}"')/$(t17c unset 1 'echo "${E17C_MOCA_PIN:-none}"')" "none/none"
  check "e17c: a real sha is accepted by e17c_require_pin" "$(t17c 1 unset 'e17c_require_pin && echo ok' E15_TEST_PINS="$TMP/e17c-test-pins.sh")" "ok"
  printf 'E17C_MOCA_PIN=0000000000000000000000000000000000000000\n' >"$TMP/e17c-placeholder.sh"
  check "e17c: the placeholder sha is refused, naming e17c-pins.sh" \
    "$(t17c 1 unset '(e17c_require_pin)' E15_TEST_PINS="$TMP/e17c-placeholder.sh" 2>&1 | grep -c 'E17C_MOCA_PIN.*placeholder.*e17c-pins.sh')/$(t17c 1 unset '(e17c_require_pin) >/dev/null 2>&1; echo $?' E15_TEST_PINS="$TMP/e17c-placeholder.sh")" "1/1"
  printf 'E17C_MOCA_PIN=abc123\n' >"$TMP/e17c-bad1.sh"
  printf 'E17C_MOCA_PIN=ZZZ%s\n' "${E17C_FIXPIN:3}" >"$TMP/e17c-bad2.sh"
  check "e17c: a short or non-hex pin is refused, naming e17c-pins.sh" \
    "$(t17c 1 unset '(e17c_require_pin) >/dev/null 2>&1; echo $?' E15_TEST_PINS="$TMP/e17c-bad1.sh")/$(t17c 1 unset '(e17c_require_pin) >/dev/null 2>&1; echo $?' E15_TEST_PINS="$TMP/e17c-bad2.sh")/$(t17c 1 unset '(e17c_require_pin)' E15_TEST_PINS="$TMP/e17c-bad1.sh" | grep -c 'not a full 40-hex sha (e17c-pins.sh)')" "1/1/1"
  check "e17c: setup.sh and rung.sh call e17c_require_pin when E17C=1, before the E17b checks" \
    "$(grep -A2 '^\[ "\${E17C:-}" != 1 \] || e17c_require_pin$' "$RIG/setup.sh" | grep -c '^\[ "\${E17B:-}" != 1 \] || e17b_require_pin$')/$(grep -A2 '^\[ "\${E17C:-}" != 1 \] || e17c_require_pin$' "$RIG/rung.sh" | grep -c '^\[ "\${E17B:-}" != 1 \] || { e17b_require_pin && e17b_require_build; }$')" "1/1"
  check "e17c: a rung with E17C=1 and the placeholder pin refuses to start (exit 1, names the pin file)" \
    "$(env -u E17B E17C=1 E15_TEST_PINS="$TMP/e17c-placeholder.sh" E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash "$RIG/rung.sh" sbx 1 default >"$TMP/e17c-rung.out" 2>&1; echo $?)/$(grep -c 'E17C_MOCA_PIN.*placeholder.*e17c-pins.sh' "$TMP/e17c-rung.out")" "1/1"
  check "e17c: the pin-file-not-found error names both candidate paths" \
    "$(grep -c "but no e17c-pins.sh at.*e17-lease/rig/e17c-pins.sh.*e17/rig/e17c-pins.sh" "$RIG/lib.sh")" "1"
}
test_e17c_profile_off_is_unchanged() {
  check "e17c off: with E17C unset no E17C variable is defined (E17B unset / E17B=1)" \
    "$(t17c unset unset 'compgen -v E17C | wc -l | tr -d " "')/$(t17c unset 1 'compgen -v E17C | wc -l | tr -d " "')" "0/0"
  check "e17c off: E17B=1 alone keeps E17b's pin and checkout" \
    "$(t17c unset 1 'echo $E15_MOCA_PIN $E15_MOCA' E15_TEST_PINS="$TMP/e17b-test-pins.sh")" "$E17B_FIXPIN $TROOT/moca-e17b"
  check "e17c off: E17C=0 or empty is E17C unset" \
    "$(t17c 0 1 'echo $E15_MOCA_PIN $E15_MOCA')/$(t17c '' unset 'echo $E15_MOCA_PIN $E15_MOCA')" "$(t17c unset 1 'echo $E15_MOCA_PIN $E15_MOCA')/$(t17c unset unset 'echo $E15_MOCA_PIN $E15_MOCA')"
  # The goldens were written from the pre-E17c lib.sh (tests/golden/dump.sh says how), so no git ref is needed.
  local b g ea
  for b in unset 1; do
    if [ "$b" = unset ]; then g="$GOLD/profile-e17b-off.txt"; else g="$GOLD/profile-e17b-on.txt"; fi
    t17c unset "$b" '. "'"$GOLD/dump.sh"'"; e15_golden_profile' >"$TMP/gold.out"
    check "e17c off: with E17C unset and E17B $b every E15_/E17B/E17C variable lib.sh defines (flags, values) equals the pre-E17c golden" \
      "$(gsame "$g")" "same"
    check "e17c off: with E17C unset and E17B $b sourcing lib.sh exports no new variable" \
      "$(if [ "$b" = unset ]; then ea=(-u E17B); else ea=(E17B="$b"); fi
        env -u E17C "${ea[@]}" E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'b=$(env | cut -d= -f1 | sort); source "$1"; comm -13 <(echo "$b") <(env | cut -d= -f1 | sort) | tr "\n" " "' _ "$RIG/lib.sh" 2>&1)" ""
  done
  check "e17c: pins.sh and e17b-pins.sh are not touched by the profile (no E17C in them)" "$(grep -c 'E17C' "$RIG/pins.sh" "$RE17B/e17b-pins.sh" | cut -d: -f2 | tr '\n' ' ')" "0 0 "
}
test_e17c_profile_on() {
  local p="E15_TEST_PINS=$TMP/e17c-test-pins.sh"
  check "e17c on: E15_MOCA_PIN follows E17C_MOCA_PIN" "$(t17c 1 unset 'echo $E15_MOCA_PIN' "$p")" "$E17C_FIXPIN"
  check "e17c on: E15_MOCA is \$E15_ROOT/moca-e17c" "$(t17c 1 unset 'echo $E15_MOCA' "$p")" "$TROOT/moca-e17c"
  check "e17c on: E17C=1 implies E17B=1, exported to child processes" "$(t17c 1 unset 'echo $E17B; bash -c "echo \$E17B"' "$p" | tr '\n' ' ')" "1 1 "
  check "e17c on: E17C=1 alone resolves exactly as E17C=1 E17B=1" \
    "$([ "$(t17c 1 unset 'for v in $(compgen -v E15_; compgen -v E17B; compgen -v E17C); do declare -p "$v"; done' "$p" | sha256sum)" = "$(t17c 1 1 'for v in $(compgen -v E15_; compgen -v E17B; compgen -v E17C); do declare -p "$v"; done' "$p" | sha256sum)" ] && echo same || echo differ)" "same"
  check "e17c on: the E17b semantics hold (ship-* arms on fresh-metal, a ship arm is a lease arm, E17a arms refused)" \
    "$(t17c 1 unset 'case " ${E15_ARMS[*]} " in *" ship-300 "*) echo arms ;; *) echo noarms ;; esac; e17b_lease_arm ship-300 && echo lease; e15_e17a_arm_refused lease-300 2>/dev/null && echo refused' "$p" E15_HOST_PROFILE=fresh-metal | tr '\n' ' ')" "arms lease refused "
  check "e17c on: every other pins.sh pin is unchanged" \
    "$([ "$(t17c unset unset 'for n in "${E15_PINS[@]}"; do echo "$n=${!n}"; done' | sha256sum)" = "$(t17c 1 unset 'for n in "${E15_PINS[@]}"; do echo "$n=${!n}"; done' "$p" | sha256sum)" ] && echo same || echo differ)" "same"
  check "e17c on: the snapshot leaf is e17c-<E17C pin8>-<ram> (ruling R-i) and the stock build stamp key carries the E17C pin" \
    "$(t17c 1 unset 'worker_snapimg' "$p")/$(t17c 1 unset 'worker_snapimg' "$p" E17B_GUEST_RAM_MB=256)/$(t17c 1 unset 'stamp_set() { :; }; mkdir -p "$E15_STATE"; echo "$E15_MOCA_PIN" >"$E15_STATE/go-stock-e17b"; e17b_require_build && echo built' "$p")" "e17c-${E17C_FIXPIN:0:8}-1024/e17c-${E17C_FIXPIN:0:8}-256/built"
  check "e17c off: E17B=1 alone keeps the e17b-<pin8>-<ram> leaf" "$(t17c unset 1 'worker_snapimg' E15_TEST_PINS="$TMP/e17b-test-pins.sh")" "e17b-${E17B_FIXPIN:0:8}-1024"
  rm -rf "${TROOT:?}/state"
}
test_e17c_pin_is_a_full_sha
test_e17c_profile_off_is_unchanged
test_e17c_profile_on

# --- E17d profile (E17D=1: E17C=1 with its own moca pin, checkout and snapshot leaf; with E17D unset nothing changes) ---
e17d_pin_file="$RE17B/e17d-pins.sh"
t17d() { # t17d E17D-value|unset E17C-value|unset EXPR [VAR=val ...]: evaluate EXPR after sourcing lib.sh at a scratch root
  local dv=$1 cv=$2 expr=$3 un=(-u E17B) ea=()
  shift 3
  if [ "$dv" = unset ]; then un+=(-u E17D); else ea+=(E17D="$dv"); fi
  if [ "$cv" = unset ]; then un+=(-u E17C); else ea+=(E17C="$cv"); fi
  env "${un[@]}" ${ea[@]+"${ea[@]}"} "$@" E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'source "$1"; source "$2"; source "$3"; eval "$4"' \
    _ "$RIG/lib.sh" "$RIG/points.sh" "$GOLD/dump.sh" "$expr" 2>&1
}
E17D_FIXPIN=3333333333333333333333333333333333333333
printf 'E17D_MOCA_PIN=%s\n' "$E17D_FIXPIN" >"$TMP/e17d-test-pins.sh"
printf 'MemTotal: 400000000 kB\n' >"$TMP/e17d-meminfo"
test_e17d_pin_is_a_full_sha() {
  local want_pin
  want_pin=$(grep -E '^E17D_MOCA_PIN=' "$e17d_pin_file" | cut -d= -f2)
  check "e17d: pins file sets E17D_MOCA_PIN to 40 hex digits, not the placeholder" \
    "$(printf '%s' "$want_pin" | grep -cE '^[0-9a-f]{40}$')/$(printf '%s' "$want_pin" | grep -c '^0*$')" "1/0"
  check "e17d: the pin is moca main's #1026 merge (a9a11a228b6f, with #1027)" "${want_pin:0:12}" "a9a11a228b6f"
  check "e17d: pins file is not sourced (E17D_MOCA_PIN undefined) with E17D unset, with or without E17C=1" \
    "$(t17d unset unset 'echo "${E17D_MOCA_PIN:-none}"')/$(t17d unset 1 'echo "${E17D_MOCA_PIN:-none}"')" "none/none"
  check "e17d: the committed pin is accepted by e17d_require_pin" "$(t17d 1 unset 'e17d_require_pin && echo ok')" "ok"
  printf 'E17D_MOCA_PIN=0000000000000000000000000000000000000000\n' >"$TMP/e17d-placeholder.sh"
  check "e17d: the placeholder sha is refused, naming e17d-pins.sh" \
    "$(t17d 1 unset '(e17d_require_pin)' E15_TEST_PINS="$TMP/e17d-placeholder.sh" 2>&1 | grep -c 'E17D_MOCA_PIN.*placeholder.*e17d-pins.sh')/$(t17d 1 unset '(e17d_require_pin) >/dev/null 2>&1; echo $?' E15_TEST_PINS="$TMP/e17d-placeholder.sh")" "1/1"
  printf 'E17D_MOCA_PIN=abc123\n' >"$TMP/e17d-bad1.sh"
  printf 'E17D_MOCA_PIN=ZZZ%s\n' "${E17D_FIXPIN:3}" >"$TMP/e17d-bad2.sh"
  check "e17d: a short or non-hex pin is refused, naming e17d-pins.sh" \
    "$(t17d 1 unset '(e17d_require_pin) >/dev/null 2>&1; echo $?' E15_TEST_PINS="$TMP/e17d-bad1.sh")/$(t17d 1 unset '(e17d_require_pin) >/dev/null 2>&1; echo $?' E15_TEST_PINS="$TMP/e17d-bad2.sh")/$(t17d 1 unset '(e17d_require_pin)' E15_TEST_PINS="$TMP/e17d-bad1.sh" | grep -c 'not a full 40-hex sha (e17d-pins.sh)')" "1/1/1"
  check "e17d: setup.sh and rung.sh call e17d_require_pin when E17D=1, before the E17c check" \
    "$(grep -A2 '^\[ "\${E17D:-}" != 1 \] || e17d_require_pin$' "$RIG/setup.sh" | grep -c '^\[ "\${E17C:-}" != 1 \] || e17c_require_pin$')/$(grep -A2 '^\[ "\${E17D:-}" != 1 \] || e17d_require_pin$' "$RIG/rung.sh" | grep -c '^\[ "\${E17C:-}" != 1 \] || e17c_require_pin$')" "1/1"
  check "e17d: a rung with E17D=1 and the placeholder pin refuses to start (exit 1, names the pin file)" \
    "$(env -u E17B -u E17C E17D=1 E15_TEST_PINS="$TMP/e17d-placeholder.sh" E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash "$RIG/rung.sh" sbx 1 default >"$TMP/e17d-rung.out" 2>&1; echo $?)/$(grep -c 'E17D_MOCA_PIN.*placeholder.*e17d-pins.sh' "$TMP/e17d-rung.out")" "1/1"
  check "e17d: the pin-file-not-found error names both candidate paths" \
    "$(grep -c "but no e17d-pins.sh at.*e17-lease/rig/e17d-pins.sh.*e17/rig/e17d-pins.sh" "$RIG/lib.sh")" "1"
  check "e17d: pins.sh, e17b-pins.sh and e17c-pins.sh are not touched by the profile (no E17D in them)" \
    "$(grep -c 'E17D' "$RIG/pins.sh" "$RE17B/e17b-pins.sh" "$RE17B/e17c-pins.sh" | cut -d: -f2 | tr '\n' ' ')" "0 0 0 "
}
test_e17d_profile_off_is_unchanged() {
  check "e17d off: with E17D unset no E17D variable is defined (E17C unset / E17C=1)" \
    "$(t17d unset unset 'compgen -v E17D | wc -l | tr -d " "')/$(t17d unset 1 'compgen -v E17D | wc -l | tr -d " "')" "0/0"
  check "e17d off: E17D=0 or empty is E17D unset" \
    "$(t17d 0 1 'echo $E15_MOCA_PIN $E15_MOCA')/$(t17d '' 1 'echo $E15_MOCA_PIN $E15_MOCA')" "$(t17d unset 1 'echo $E15_MOCA_PIN $E15_MOCA')/$(t17d unset 1 'echo $E15_MOCA_PIN $E15_MOCA')"
  # The goldens were written from the pre-E17d lib.sh and points.sh (tests/golden/dump.sh says how), so no git ref.
  t17d unset 1 'e15_golden_profile' E15_HOST_PROFILE=fresh-metal >"$TMP/gold.out"
  check "e17d off: with E17D unset and E17C=1 every E15_/E17B/E17C/E17D variable lib.sh defines equals the pre-E17d golden" \
    "$(gsame "$GOLD/profile-e17c-on.txt")" "same"
  rm -f "$TROOT/env"
  t17d unset 1 'e15_golden_e17c "$E15_ROOT/env" "'"$TMP/e17d-meminfo"'"' E15_HOST_PROFILE=fresh-metal >"$TMP/gold.out"
  check "e17d off: with E17D unset and E17C=1 every E17c point and arm (E15_P_*, point_sig, warm-up, worker, env) equals the pre-E17d golden" \
    "$(gsame "$GOLD/e17c-on.txt")" "same"
  check "e17d off: with E17D unset and E17C=1 sourcing lib.sh exports no new variable" \
    "$(env -u E17D -u E17B E17C=1 E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash -c 'b=$(env | cut -d= -f1 | sort); source "$1"; comm -13 <(echo "$b") <(env | cut -d= -f1 | sort) | tr "\n" " "' _ "$RIG/lib.sh" 2>&1)" "E17B "
}
test_e17d_profile_on() {
  local p="E15_TEST_PINS=$TMP/e17d-test-pins.sh"
  check "e17d on: E15_MOCA_PIN follows E17D_MOCA_PIN (the committed pin, and a fixture pin)" \
    "$(t17d 1 unset 'echo $E15_MOCA_PIN')/$(t17d 1 unset 'echo $E15_MOCA_PIN' "$p")" "$(grep -E '^E17D_MOCA_PIN=' "$e17d_pin_file" | cut -d= -f2)/$E17D_FIXPIN"
  check "e17d on: E15_MOCA is \$E15_ROOT/moca-e17d" "$(t17d 1 unset 'echo $E15_MOCA' "$p")" "$TROOT/moca-e17d"
  check "e17d on: E17D=1 implies E17C=1 and E17B=1, exported to child processes" \
    "$(t17d 1 unset 'echo $E17C $E17B; bash -c "echo \$E17C \$E17B"' "$p" | tr '\n' ' ')" "1 1 1 1 "
  check "e17d on: E17D=1 alone resolves exactly as E17D=1 E17C=1" \
    "$([ "$(t17d 1 unset 'for v in $(compgen -v E15_; compgen -v E17B; compgen -v E17C; compgen -v E17D); do declare -p "$v"; done' "$p" | sha256sum)" = "$(t17d 1 1 'for v in $(compgen -v E15_; compgen -v E17B; compgen -v E17C; compgen -v E17D); do declare -p "$v"; done' "$p" | sha256sum)" ] && echo same || echo differ)" "same"
  check "e17d on: the E17c semantics hold (ship-300-nd on fresh-metal, a ship arm is a lease arm, E17a arms refused)" \
    "$(t17d 1 unset 'case " ${E15_ARMS[*]} " in *" ship-300-nd "*) echo arms ;; *) echo noarms ;; esac; e17b_lease_arm ship-300 && echo lease; e15_e17a_arm_refused lease-300 2>/dev/null && echo refused' "$p" E15_HOST_PROFILE=fresh-metal | tr '\n' ' ')" "arms lease refused "
  check "e17d on: every pins.sh pin is unchanged" \
    "$([ "$(t17d unset unset 'for n in "${E15_PINS[@]}"; do echo "$n=${!n}"; done' | sha256sum)" = "$(t17d 1 unset 'for n in "${E15_PINS[@]}"; do echo "$n=${!n}"; done' "$p" | sha256sum)" ] && echo same || echo differ)" "same"
  check "e17d on: the snapshot leaf is e17d-<E17D pin8>-<ram> and the stock build stamp key carries the E17D pin" \
    "$(t17d 1 unset 'worker_snapimg' "$p")/$(t17d 1 unset 'worker_snapimg' "$p" E17B_GUEST_RAM_MB=256)/$(t17d 1 unset 'stamp_set() { :; }; mkdir -p "$E15_STATE"; echo "$E15_MOCA_PIN" >"$E15_STATE/go-stock-e17b"; e17b_require_build && echo built' "$p")" "e17d-${E17D_FIXPIN:0:8}-1024/e17d-${E17D_FIXPIN:0:8}-256/built"
  check "e17d on: the missing-snapshot message names the E17D=1 build" \
    "$(t17d 1 unset '(e17b_require_snapshot)' "$p" | grep -c 'E17D=1 experiments/e17-lease/rig/snapshot-e17b.sh --ram-mb 1024 --leaf e17d-')" "1"
  check "e17d off: E17C=1 alone keeps the e17c-<pin8>-<ram> leaf" "$(t17d unset 1 'worker_snapimg' E15_TEST_PINS="$TMP/e17c-test-pins.sh")" "e17c-${E17C_FIXPIN:0:8}-1024"
  rm -rf "${TROOT:?}/state"
}
test_e17d_pin_is_a_full_sha
test_e17d_profile_off_is_unchanged
test_e17d_profile_on

test_e17b_setup_never_deletes_the_sealed_snapshot() {
  local snip="$TMP/e17b-snapstep.sh"
  # The snapshot step's opening (ruling E17B-R32): under E17B=1 it is SKIPPED with a log line, never a build; the
  # build branch (elif) is cut at its first line, replaced by a marker, so the snippet runs with sudo/rm stubbed.
  awk '/^if \[ "\$\{E17B:-\}" = 1 \]; then # step 7 under the E17b profile/{p=1} p&&/^  tree=\$E15_ROOT\/rootfs-build\/tree$/{print "  echo would-build"; exit} p{print}' "$RIG/setup.sh" >"$snip"
  printf 'fi\n' >>"$snip"
  check "e17b snapshot: the E17B=1 branch comes first in the snapshot step, the build only in its elif" \
    "$(head -1 "$snip" | grep -c '^if \[ "\${E17B:-}" = 1 \]; then # step 7')/$(grep -c '^elif ! stamp_ok snapshot "\$snap_key"' "$snip")/$(grep -c 'would-build' "$snip")" "1/1/1"
  local rmlog="$TMP/e17b-snap-calls.log"
  : >"$rmlog"
  run_step() {
    env "$@" E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" RMLOG="$rmlog" bash -c '
      source "$1"
      sudo() { echo "sudo $*" >>"$RMLOG"; }
      rm() { echo "rm $*" >>"$RMLOG"; }
      stamp_ok() { return 1; }
      snap_key=k
      source "$2"; echo reached-end' _ "$RIG/lib.sh" "$snip" 2>&1
  }
  local out rc
  out=$(run_step E17B=1 E15_TEST_PINS="$TMP/e17b-test-pins.sh"); rc=$?
  check "e17b snapshot: under E17B=1 the step is skipped with a log line naming snapshot-e17b.sh (exit 0, no build, the rest of setup runs)" \
    "$rc/$(printf '%s' "$out" | grep -c 'step 7 (snapshot) skipped.*snapshot-e17b.sh --ram-mb 1024 and --ram-mb 256.*never over e15')/$(printf '%s' "$out" | grep -c would-build)/$(printf '%s' "$out" | grep -c reached-end)" "0/1/0/1"
  check "e17b snapshot: no rm and no sudo call was made" "$(grep -c . "$rmlog")" "0"
  check "e17b snapshot: with E17B unset the step builds as before (falls to the build branch)" "$(run_step E17B= | grep -c would-build)" "1"
  check "e17b snapshot: no die is left in the E17B=1 branch (R32 replaces R3's die)" \
    "$(grep -c 'E17b snapshots are built by experiments/e17-lease/rig/snapshot-e17b.sh into a new leaf, never over' "$RIG/setup.sh")/$(awk '/# step 7 under the E17b profile/{p=1} p&&/^elif /{exit} p&&/die /{d++} END{print d+0}' "$RIG/setup.sh")" "0/0"
  check "e17b snapshot: setup.sh's first snapshot rm -rf comes after the E17B=1 branch, in the build branch" \
    "$(awk '/# step 7 under the E17b profile/{g=NR} /^elif ! stamp_ok snapshot "\$snap_key"/{a=NR} /rm -rf "\$\{E15_SNAPDIR:\?\}/{r=NR} END{print (a&&g&&r&&g<a&&a<r)?"after":"bad"}' "$RIG/setup.sh")" "after"
  check "e17b snapshot: the rootfs-build rm -rf is in the build branch too" \
    "$(awk '/^elif ! stamp_ok snapshot "\$snap_key"/{a=NR} /sudo -n rm -rf "\$E15_ROOT\/rootfs-build"/{r=NR; exit} END{print (a&&r&&a<r)?"after":"bad"}' "$RIG/setup.sh")" "after"
}
# R32: setup.sh step 10 (the end-to-end check) under E17B=1 runs on the selected E17b leaf with its own stamp, after a
# relay restart from the E17b checkout; with no leaf it is skipped, telling the operator what to run. E17B unset: as before.
test_e17b_setup_e2e_step() {
  local snip="$TMP/e17b-e2estep.sh" calls="$TMP/e17b-e2e-calls.log"
  awk '/^# --- 10. end-to-end check/{p=1} p&&/^log "setup: done/{exit} p{print}' "$RIG/setup.sh" >"$snip"
  run_e2e() {
    : >"$calls"
    env "$@" E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" CALLS="$calls" bash -c '
      source "$1"
      sudo() { :; }
      stamp_ok() { return 1; }
      stamp_set() { echo "stamp_set $1" >>"$CALLS"; }
      sha256_of() { echo 0123456789abcdef0123; }
      start_worker() { echo "start_worker $1" >>"$CALLS"; }
      start_relay() { echo "start_relay ${1:-}" >>"$CALLS"; }
      stop_e15_unit() { echo "stop $1" >>"$CALLS"; }
      stop_rung_units() { :; }
      gexec() { echo ok; }
      m_note() { :; }
      workspace_cp_flag() { echo --reflink=always; }
      workspace_copy_mode() { echo reflink; }
      E15_STATE=$(mktemp -d); echo tkey >"$E15_STATE/template"
      source "$2"; echo "reached-end e2e_pending=${e2e_pending:-0}"' _ "$RIG/lib.sh" "$snip" 2>&1
  }
  local out
  rm -rf "$TROOT/snapshots/e17b-11111111-1024"
  out=$(run_e2e E17B=1 E15_TEST_PINS="$TMP/e17b-test-pins.sh")
  check "e17b e2e: no E17b leaf -> skipped, naming the leaf and snapshot-e17b.sh, nothing started" \
    "$(printf '%s' "$out" | grep -c "no E17b snapshot $TROOT/snapshots/e17b-11111111-1024: the end-to-end check is skipped.*snapshot-e17b.sh --ram-mb 1024.*re-run E17B=1 setup.sh")/$(grep -c . "$calls")/$(printf '%s' "$out" | grep -c 'reached-end e2e_pending=1')" "1/0/1"
  mkdir -p "$TROOT/snapshots/e17b-11111111-1024"
  echo '{}' >"$TROOT/snapshots/e17b-11111111-1024/manifest.json"
  out=$(run_e2e E17B=1 E15_TEST_PINS="$TMP/e17b-test-pins.sh")
  check "e17b e2e: with the leaf -> the relay restarts from the E17b checkout, then the worker; its own stamp e2e-e17b" \
    "$(tr '\n' ';' <"$calls")/$(printf '%s' "$out" | grep -c 'reached-end e2e_pending=0')" "stop e15-relay.service;start_relay ;start_worker sbx;stamp_set e2e-e17b;/1"
  rm -rf "$TROOT/snapshots/e17b-11111111-1024"
  out=$(run_e2e E17B=)
  check "e17b e2e: E17B unset -> the sealed check (no relay restart, stamp e2e)" "$(tr '\n' ';' <"$calls")" "start_worker sbx;stamp_set e2e;"
}
test_e17b_builds_to_separate_binaries() {
  check "e17b build: stock worker, null-responder and stamp names follow the profile" \
    "$(t17 1 'echo $(stock_worker_bin) $(null_bin) $(stock_stamp)' E15_TEST_PINS="$TMP/e17b-test-pins.sh")" \
    "$TROOT/bin/microvm-worker-e17b $TROOT/bin/null-responder-e17b go-stock-e17b"
  check "e17b build: unchanged with E17B unset" "$(t17 unset 'echo $(stock_worker_bin) $(null_bin) $(stock_stamp)')" "$TROOT/bin/microvm-worker $TROOT/bin/null-responder go-stock"
  check "e17b build: start_null uses null_bin" "$(grep -c '"\$(null_bin)" --listen' "$RIG/lib.sh")/$(grep -c '"\$E15_BIN/null-responder" --listen' "$RIG/lib.sh")" "1/0"
  check "e17b build: rung.sh refuses E17B=1 when the build stamp is not for E15_MOCA_PIN (exit 1, names go-stock-e17b)" \
    "$(env E17B=1 E15_TEST_PINS="$TMP/e17b-test-pins.sh" E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash "$RIG/rung.sh" sbx 1 default >"$TMP/e17b-rung2.out" 2>&1; echo $?)/$(grep -c 'go-stock-e17b' "$TMP/e17b-rung2.out")" "1/1"
  check "e17b build: rung.sh passes the stamp check when it matches (the stamp refusal is gone)" \
    "$(mkdir -p "$TROOT/state"; printf '%s\n' "$E17B_FIXPIN" >"$TROOT/state/go-stock-e17b"; env E17B=1 E15_TEST_PINS="$TMP/e17b-test-pins.sh" E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash "$RIG/rung.sh" sbx 1 default >"$TMP/e17b-rung3.out" 2>&1; grep -c 'go-stock-e17b' "$TMP/e17b-rung3.out"; rm -rf "$TROOT/state")" "0"
}
test_worker_bin_follows_profile() {
  check "worker_bin: E17B=1 -> sbx and ship-* use the -e17b worker" \
    "$(t17 1 'for a in sbx ship-30 ship-120 ship-300; do worker_bin $a; done' E15_TEST_PINS="$TMP/e17b-test-pins.sh" | sort -u | tr '\n' ' ')" "$TROOT/bin/microvm-worker-e17b "
  check "worker_bin: E17B unset -> sbx unchanged, resident/lease arms unchanged" \
    "$(t17 unset 'for a in sbx resident-inf resident-300 lease-30 lease-120; do worker_bin $a; done' | tr '\n' ' ')" \
    "$TROOT/bin/microvm-worker $TROOT/bin/microvm-worker-resident $TROOT/bin/microvm-worker-resident $TROOT/bin/microvm-worker-resident $TROOT/bin/microvm-worker-resident "
  check "worker_bin: a ship-* arm is refused when E17B is unset" "$(t17 unset '(worker_bin ship-30) >/dev/null 2>&1; echo $?')" "1"
}
test_sealed_binaries_untouched_when_e17b_set() {
  local blk="$TMP/e17b-stock-build.sh" rec="$TMP/e17b-build-calls.log"
  awk '/^if ! stamp_ok "\$\(stock_stamp\)"/{p=1} p{print} p&&/^fi$/{exit}' "$RIG/setup.sh" >"$blk"
  check "e17b build: setup.sh has a stock-build block keyed by stock_stamp" "$(grep -c 'go build' "$blk")" "2"
  : >"$rec"
  mkdir -p "$TROOT/moca-e17b/remote-worker" "$TROOT/logs" "$TROOT/bin"
  env E17B=1 E15_TEST_PINS="$TMP/e17b-test-pins.sh" E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" REC="$rec" bash -c '
    source "$1"
    GOENV_USER=()
    env() { shift 0; echo "build $*" >>"$REC"; }
    stamp_ok() { return 1; }
    stamp_set() { echo "stamp $*" >>"$REC"; }
    sha256_of() { echo x; }
    m_note() { :; }
    log() { :; }
    source "$2"' _ "$RIG/lib.sh" "$blk" >"$TMP/e17b-build.out" 2>&1
  check "e17b build: under E17B=1 the go builds write only the -e17b binaries" \
    "$(grep -c 'go build -o '"$TROOT"'/bin/microvm-worker-e17b ' "$rec")/$(grep -c 'go build -o '"$TROOT"'/bin/null-responder-e17b ' "$rec")/$(grep -cE 'go build -o '"$TROOT"'/bin/(microvm-worker|null-responder) ' "$rec")" "1/1/0"
  check "e17b build: under E17B=1 the stamp written is go-stock-e17b, never go-stock" "$(grep -c "^stamp go-stock-e17b $E17B_FIXPIN\$" "$rec")/$(grep -c '^stamp go-stock ' "$rec")" "1/0"
  rm -rf "${TROOT:?}/moca-e17b" "${TROOT:?}/logs" "${TROOT:?}/bin"
}
check "e17b: the pin-file-not-found error names both candidate paths" \
  "$(grep -c "but no e17b-pins.sh at.*e17-lease/rig/e17b-pins.sh.*e17/rig/e17b-pins.sh" "$RIG/lib.sh")" "1"
test_e17b_setup_never_deletes_the_sealed_snapshot
test_e17b_setup_e2e_step
test_e17b_builds_to_separate_binaries
test_worker_bin_follows_profile
test_sealed_binaries_untouched_when_e17b_set

# --- E17b Task 4: ship-* arms, relay token keyset, lease worker env, the -e17b driver binaries ----
t17m() { # PROFILE E17B-value|unset EXPR [VAR=val ...]: lib.sh + points.sh sourced; E15_MEMINFO is $TMP/meminfo-e17b
  local prof=$1 ev=$2 expr=$3
  shift 3
  if [ "$ev" = unset ]; then
    env -u E17B E15_HOST_PROFILE="$prof" E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" E15_TEST_PINS="$TMP/e17b-test-pins.sh" E15_MEMINFO="$TMP/meminfo-e17b" "$@" \
      bash -c 'source "$1"; source "$2"; eval "$3"' _ "$RIG/lib.sh" "$RIG/points.sh" "$expr" 2>&1
  else
    env E17B="$ev" E15_HOST_PROFILE="$prof" E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" E15_TEST_PINS="$TMP/e17b-test-pins.sh" E15_MEMINFO="$TMP/meminfo-e17b" "$@" \
      bash -c 'source "$1"; source "$2"; eval "$3"' _ "$RIG/lib.sh" "$RIG/points.sh" "$expr" 2>&1
  fi
}
printf 'MemTotal:       402653184 kB\nMemAvailable:   400000000 kB\n' >"$TMP/meminfo-e17b" # 393216 MiB
test_ship_arms_known_on_fresh_metal_only() {
  local isarm='for a in ship-30 ship-120 ship-300; do e15_is_arm $a && printf "yes " || printf "no "; done'
  check "ship arms: known on fresh-metal under E17B=1" "$(t17m fresh-metal 1 "$isarm")" "yes yes yes "
  check "ship arms: refused on aws-prelim even under E17B=1" "$(t17m aws-prelim 1 "$isarm")" "no no no "
  check "ship arms: refused on fresh-metal with E17B unset (the sealed procedures are unchanged)" "$(t17m fresh-metal unset "$isarm")" "no no no "
  check "ship arms: E15_ARMS on fresh-metal under E17B=1 appends them after the lease arms" \
    "$(t17m fresh-metal 1 'echo ${E15_ARMS[*]}')" "sbx resident-inf resident-300 control lease-30 lease-120 ship-30 ship-120 ship-300"
  check "ship arms: E15_ARMS with E17B unset is the E17 list" "$(t17m fresh-metal unset 'echo ${E15_ARMS[*]}')" "sbx resident-inf resident-300 control lease-30 lease-120"
  check "ship arms: the default, smoke and pycache* points run them under E17B=1" \
    "$(t17m fresh-metal 1 'for p in default smoke pycache pycache-low pycache-d64 pycache-d768; do e15_point $p; case " $E15_P_ARMS " in *" ship-30 ship-120 ship-300 "*) printf "%s " $p ;; esac; done')" \
    "default smoke pycache pycache-low pycache-d64 pycache-d768 "
  check "ship arms: no point lists them with E17B unset" \
    "$(t17m fresh-metal unset 'for p in default smoke pycache pycache-low pycache-d64 pycache-d768 lowduty mem512 short long; do e15_point $p; case " $E15_P_ARMS " in *" ship-"*) printf "%s " $p ;; esac; done')" ""
  check "ship arms: the lowduty and mem512 points do not run them" \
    "$(t17m fresh-metal 1 'for p in lowduty mem512 short long no-infra no-chains; do e15_point $p; case " $E15_P_ARMS " in *" ship-"*) printf "%s " $p ;; esac; done')" ""
  check "ship arms: the default warm-up is 1200 s (as the lease arms)" "$(t17m fresh-metal 1 'e15_default_warmup ship-30; e15_default_warmup ship-300' | tr '\n' ' ')" "1200 1200 "
}
test_ship_worker_env_has_admission() {
  local f="$TMP/ship-wenv"
  # 393216 MiB host RAM - 8192 = 385024
  check "ship worker_env: SH_MAX_COMMITTED_MB = host RAM MiB - 8192" "$(t17m fresh-metal 1 'worker_env ship-120 "'"$f"'"; grep "^SH_MAX_COMMITTED_MB=" "'"$f"'"')" "SH_MAX_COMMITTED_MB=385024"
  check "ship worker_env: WORKER_MAX_CONCURRENT is above the ladder's top N (also with E15_LADDER_EXTRA)" \
    "$(t17m fresh-metal 1 'worker_env ship-30 "'"$f"'"; top=0; for n in "${E15_LADDER[@]}"; do [ "$n" -gt "$top" ] && top=$n; done; v=$(sed -n "s/^WORKER_MAX_CONCURRENT=//p" "'"$f"'"); [ "$v" -gt "$top" ] && echo above' E15_LADDER_EXTRA="1280 1536")" "above"
  check "ship worker_env: standby depth 2 (the worker default, E17B-R44), no resident knobs, no lease knobs (the defaults stand)" \
    "$(t17m fresh-metal 1 'worker_env ship-300 "'"$f"'"; sed -n "s/^SH_STANDBY_DEPTH=//p" "'"$f"'"; grep -cE "^(E15_RESIDENT|SH_LEASE_)" "'"$f"'"' | tr '\n' ' ')" "2 0 "
  check "ship worker_env: the three ship arms differ in nothing (the idle timeout is the token's)" \
    "$(t17m fresh-metal 1 'for a in ship-30 ship-120 ship-300; do worker_env $a "'"$f"'"; sha256sum <"'"$f"'"; done' | sort -u | wc -l | tr -d ' ')" "1"
  check "ship worker_env: it keeps the physical guard and the other sbx lines" \
    "$(t17m fresh-metal 1 'worker_env ship-120 "'"$f"'"; grep -E "^(SH_HOST_MEM_FLOOR_MB|SH_GUEST_RAM_MB|SH_VMM|SH_MAX_RUNS)=" "'"$f"'"' | tr '\n' ' ')" "SH_VMM=firecracker SH_GUEST_RAM_MB=1024 SH_MAX_RUNS=2048 SH_HOST_MEM_FLOOR_MB=1536 "
  check "ship worker_env: no readable MemTotal -> refused, not a guessed budget" \
    "$(t17m fresh-metal 1 '(worker_env ship-30 "'"$f"'") >/dev/null 2>&1; echo $?' E15_MEMINFO="$TMP/no-such-meminfo")" "1"
  check "ship worker_env: refused outside E17B=1" "$(t17m fresh-metal unset '(worker_env ship-30 "'"$f"'") >/dev/null 2>&1; echo $?')" "1"
}
test_sbx_arm_unchanged() {
  local a="$TMP/sbx-wenv-a" b="$TMP/sbx-wenv-b"
  t17m fresh-metal unset 'worker_env sbx "'"$a"'"' >/dev/null
  t17m fresh-metal 1 'worker_env sbx "'"$b"'"' >/dev/null
  check "sbx worker_env under E17B=1 differs from E17B unset only in the snapshot leaf (E17B-R17)" \
    "$(diff "$a" "$b" | grep '^[<>]' | tr '\n' ' ')" "< SH_SNAPSHOT_IMAGE=e15 > SH_SNAPSHOT_IMAGE=e17b-11111111-1024 "
  check "sbx worker_env keeps depth 2, 256 slots and the 1 TiB budget" "$(grep -E '^(SH_STANDBY_DEPTH|WORKER_MAX_CONCURRENT|SH_MAX_COMMITTED_MB)=' "$b" | tr '\n' ' ')" "SH_STANDBY_DEPTH=2 WORKER_MAX_CONCURRENT=256 SH_MAX_COMMITTED_MB=1048576 "
  check "resident-300 and lease-30 worker_env are unchanged by the profile but for the snapshot leaf (E17B-R17)" \
    "$(for ev in unset 1; do t17m fresh-metal $ev 'for x in resident-300 lease-30; do worker_env $x "'"$a"'"; grep -v "^SH_SNAPSHOT_IMAGE=" "'"$a"'" | sha256sum; done'; done | sort | uniq -c | awk '{print $1}' | tr '\n' ' ')" "2 2 "
}
test_e17b_driver_builds_to_separate_binaries() {
  local blk="$TMP/e17b-driver-build.sh" rec="$TMP/e17b-driver-calls.log"
  awk '/^k=\$\(src_key driver\)$/{p=1} /^# E17b \(E17B=1\): the shipped worker runs/{exit} p{print}' "$RIG/setup.sh" >"$blk"
  check "e17b driver build: the extracted setup.sh block holds the driver builds (sealed 2 + e17b 2)" "$(grep -c 'go build' "$blk")" "4"
  mkdir -p "$TROOT/bin" "$TROOT/logs" "$TMP/driver"
  run_blk() { # E17B-value METAL: run the block with go builds simulated (each writes its -o file)
    : >"$rec"
    env ${1:+E17B=$1} E15_TEST_PINS="$TMP/e17b-test-pins.sh" E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" REC="$rec" METAL="$2" TMP_SRC="$TMP" bash -c '
      source "$1"
      GOENV_USER=()
      E15_SRC=$TMP_SRC
      src_key() { echo srckey; }
      env() { while [ $# -gt 0 ]; do [ "$1" = -o ] && { echo built >"$2"; echo "build $2" >>"$REC"; }; shift; done; }
      stamp_ok() { [ -e "$E15_BIN/.stamp-$1" ] && [ "$(cat "$E15_BIN/.stamp-$1")" = "$2" ]; }
      stamp_set() { echo "stamp $1 $2" >>"$REC"; printf "%s" "$2" >"$E15_BIN/.stamp-$1"; }
      sha256_of() { echo x; }
      m_note() { :; }
      source "$2"' _ "$RIG/lib.sh" "$blk" >"$TMP/e17b-dbuild.out" 2>&1
  }
  rm -f "$TROOT"/bin/.stamp-* "$TROOT"/bin/e15-driver*
  printf 'sealed-driver' >"$TROOT/bin/e15-driver"
  chmod +x "$TROOT/bin/e15-driver"
  printf 'sealed-defer' >"$TROOT/bin/e15-driver-defer"
  run_blk 1 1
  check "e17b driver build: under E17B=1 the builds write only the -e17b driver and defer variant" \
    "$(sort "$rec" | grep '^build' | sed "s#$TROOT/##" | tr '\n' ' ')" "build bin/e15-driver-defer-e17b build bin/e15-driver-e17b "
  check "e17b driver build: the stamp written is go-driver-e17b, never go-driver or go-driver-defer" \
    "$(grep -c '^stamp go-driver-e17b srckey$' "$rec")/$(grep -cE '^stamp go-driver(-defer)? ' "$rec")" "1/0"
  check "e17b driver build: the sealed e15-driver and e15-driver-defer are byte-for-byte untouched" \
    "$(cat "$TROOT/bin/e15-driver")/$(cat "$TROOT/bin/e15-driver-defer")" "sealed-driver/sealed-defer"
  run_blk 1 1
  check "e17b driver build: a second run with the stamp set builds nothing" "$(grep -c . "$rec")" "0"
  rm -f "$TROOT"/bin/.stamp-* "$TROOT"/bin/e15-driver*
  printf 'sealed-driver' >"$TROOT/bin/e15-driver"
  chmod +x "$TROOT/bin/e15-driver"
  run_blk "" 1
  check "e17b driver build: with E17B unset a changed driver on metal still builds e15-driver-defer only (as before)" \
    "$(grep '^build' "$rec" | sed "s#$TROOT/##" | tr '\n' ' ')/$(cat "$TROOT/bin/e15-driver")" "build bin/e15-driver-defer /sealed-driver"
  rm -f "$TROOT"/bin/.stamp-* "$TROOT"/bin/e15-driver*
  run_blk "" 0
  check "e17b driver build: with E17B unset and no driver the old path builds e15-driver and stamps go-driver" \
    "$(grep '^build' "$rec" | sed "s#$TROOT/##" | tr '\n' ' ')/$(grep -c '^stamp go-driver srckey$' "$rec")" "build bin/e15-driver /1"
  rm -rf "${TROOT:?}/bin" "${TROOT:?}/logs"
  check "e17b driver build: lib.sh names the binaries" \
    "$(t17m fresh-metal 1 'echo $E15_BIN' | sed "s#$TROOT/##")" "bin"
}
test_sealed_driver_untouched_when_e17b_set() {
  check "e17b driver: the sealed build lines in setup.sh are still present, once each" \
    "$(grep -c 'go build -o "\$E15_BIN/e15-driver-defer" \.' "$RIG/setup.sh")/$(grep -c 'go build -o "\$E15_BIN/e15-driver" \.' "$RIG/setup.sh")" "1/1"
  check "e17b driver: no E17B build writes a sealed driver name (every e17b go build names -e17b)" \
    "$(grep -cE 'go build -o "\$E15_BIN/e15-driver[a-z-]*e17b" \.' "$RIG/setup.sh")" "2"
  check "e17b driver: rung.sh under E17B=1 selects the -e17b driver and its defer variant" \
    "$(grep -c 'DRIVER=\${DRIVER}-e17b' "$RIG/rung.sh")/$(grep -c 'BASE_DRIVER=\${BASE_DRIVER}-e17b' "$RIG/rung.sh")" "1/1"
}
# the shipped-arm rung, end to end against stubs (no host: systemd-run, sudo, grpcurl, the driver and the worker are scripts)
test_ship_rung_harness() {
  RS="$TMP/e15-rig-test.ship"
  RSS="$TMP/shipstub"
  rm -rf "$RS" "$RSS"
  mkdir -p "$RSS" "$RS"/{corpora/default,src/e15/commands,bin,template,secrets,logs,state,workspaces,jail,runs}
  SORD="$RS/order.log"
  SARGS="$RS/driver-args.log"
  SSYS="$RS/sysd.log"
  printf '{"session":"s","calls":[]}\n' >"$RS/corpora/default/corpus.jsonl"
  printf '{"table": {"mean_span_min": 30}}\n' >"$RS/corpora/default/corpus-report.json"
  echo '{}' >"$RS/src/e15/commands/library.json"
  head -c 4096 /dev/zero >"$RS/template/workspace.img"
  echo tok >"$RS/secrets/exec.token"
  echo fresh-metal >"$RS/state/host_profile"
  echo reflink >"$RS/state/workspace_copy"
  printf '%s\n' "$E17B_FIXPIN" >"$RS/state/go-stock-e17b"
  cp "$TMP/meminfo-e17b" "$RS/meminfo"
  # record.py stub: the rung completes (exit 0) once params.json is written
  mkdir -p "$RS/src/e15/analysis"
  printf 'import sys\nopen(sys.argv[1] + "/record.json", "w").write("{\\"holds\\": true}")\nprint("true")\n' >"$RS/src/e15/analysis/record.py"
  # the squeeze point (Task 9): pycache-d768's corpus, the E17 library and the D=768 template
  mkdir -p "$RS/corpora/pycache" "$RS/src/e17/workload" "$RS/template-pycache-d768"
  printf '{"session":"s","calls":[]}\n' >"$RS/corpora/pycache/corpus.jsonl"
  printf '{"table": {"mean_span_min": 30}}\n' >"$RS/corpora/pycache/corpus-report.json"
  echo '{}' >"$RS/src/e17/workload/library.json"
  head -c 4096 /dev/zero >"$RS/template-pycache-d768/workspace.img"
  mkdir -p "$RS/template-pycache-d192"
  head -c 4096 /dev/zero >"$RS/template-pycache-d192/workspace.img"
  # the E17b snapshot leaves (snapshot-e17b.sh; E17B-R17): e17b-<pin8>-<RAM>
  for r in 1024 256; do
    mkdir -p "$RS/snapshots/e17b-${E17B_FIXPIN:0:8}-$r"
    printf '{"hash": "h%s", "guest_ram_mb": %s, "features": ["lease-v1", "balloon-fpr-v1"]}\n' "$r" "$r" >"$RS/snapshots/e17b-${E17B_FIXPIN:0:8}-$r/manifest.json"
  done
  # e15.slice as setup.sh leaves it for this host's RAM (lib.sh e15_slice_limits): what `systemctl show` reports
  read -r SLICE_MAX0 SLICE_HIGH0 < <(t17m fresh-metal 1 'e15_slice_limits 402653184')
  printf 'MemoryMax=%s\nMemoryHigh=%s\n' "$SLICE_MAX0" "$SLICE_HIGH0" >"$RS/slice.state"
  # the -e17b driver stub: mint-key writes a fake key pair; a run records its args and writes a calls.jsonl
  cat >"$RS/bin/e15-driver-e17b" <<SH
#!/bin/sh
echo "\$*" >>"$SARGS"
if [ "\$1" = mint-key ]; then
  mkdir -p "\$3"; echo "FAKE-PEM" >"\$3/token.key"; echo "kid0123456789abcd:QUJD" >"\$3/token.pub"; exit 0
fi
echo driver >>"$SORD"
# what the driver saw of its key directory (the rung removes it after the run): token.pub and the dir's mode
for a; do case "\$a" in */token.key) d=\${a%/token.key}; echo "pub \$(cat "\$d/token.pub") mode \$(stat -c %a "\$d" 2>/dev/null || stat -f %Lp "\$d")" >>"$RS/driver-saw.log" ;; esac; done
# STUB_DRIVER_TERM=1: the rung is killed (SIGTERM) while the driver runs
if [ -n "\${STUB_DRIVER_TERM:-}" ]; then kill -TERM "\$PPID"; sleep 2; exit 0; fi
out=; while [ \$# -gt 0 ]; do [ "\$1" = --out ] && out=\$2; shift; done
[ -z "\${STUB_CALLS:-}" ] || printf '%s\n' "\$STUB_CALLS" >"\$out/calls.jsonl"
exit \${STUB_DRIVER_EXIT:-0}
SH
  printf '#!/bin/sh\necho SEALED-DRIVER-RAN >>"%s"\n' "$SORD" >"$RS/bin/e15-driver"
  printf '#!/bin/sh\n' >"$RS/bin/microvm-worker-e17b"
  printf '#!/bin/sh\n' >"$RS/bin/microvm-worker"
  chmod +x "$RS/bin"/*
  cat >"$RSS/systemctl" <<SH
#!/usr/bin/env bash
case "\$1 \$*" in
is-active*e15-relay.service*) [ -e "$RS/relay-up" ] ;;
is-active*e15-worker.service*) [ -e "$RS/worker-up" ] ;;
is-active* | is-failed*) exit 1 ;;
*) exit 0 ;;
esac
SH
  cat >"$RSS/sudo" <<SH
#!/usr/bin/env bash
[ "\$1" = -n ] && shift
case "\$1" in
systemctl)
  case "\$*" in
  *"stop e15-relay.service"*) rm -f "$RS/relay-up" ;;
  *"stop e15-worker.service"*) rm -f "$RS/worker-up"; echo worker-stop >>"$SORD" ;;
  *"show e15.slice --property=MemoryMax,MemoryHigh"*) echo show-slice >>"$SORD"; cat "$RS/slice.state" ;;
  *daemon-reload*) echo daemon-reload >>"$SORD" ;;
  *"set-property --runtime e15.slice "*)
    echo "set-property \${*:5}" >>"$SORD"
    [ -z "\${STUB_SETPROP_FAIL:-}" ] || exit 1
    printf '%s\n' "\${@:5}" >"$RS/slice.state" ;;
  esac
  exit 0 ;;
rm) echo "sudo-\$*" >>"$SORD"; exit 0 ;;
systemd-run)
  echo "\$*" >>"$SSYS"
  case "\$*" in
  *--unit=e15-relay.service*) touch "$RS/relay-up"; echo relay-start >>"$SORD" ;;
  *--unit=e15-worker.service*)
    touch "$RS/worker-up"; echo worker-start >>"$SORD"
    # the banner in moca's format (remote-worker/cmd/microvm-worker/main.go: the log.Printf with leaseBanner); STUB_BANNER on|off|none
    b='2026/11/15 10:00:00 microvm-worker: relay=127.0.0.1:9643 sandbox_id=e15 tls=false vmm=firecracker D=0 guest=1024MiB budget=385024MiB slots=1792 standby_headroom=off mem_floor=1536MiB workspace_idle=24h0m0s lease=on lease_idle=5m0s/1h0m0s lease_max=8h0m0s/8h0m0s lease_grace=30s lease_start=192MiB lease_headroom=1.25 lease_pagecache=256MiB lease_reclaim_free=2048MiB labels=map[]'
    case "\${STUB_BANNER:-on}" in
    off) b='2026/11/15 10:00:00 microvm-worker: relay=127.0.0.1:9643 sandbox_id=e15 tls=false vmm=firecracker D=0 guest=1024MiB budget=385024MiB slots=1792 standby_headroom=off mem_floor=1536MiB workspace_idle=24h0m0s lease=off labels=map[]' ;;
    none) b='' ;;
    # a worker with moca #974 (E17c): the lease_cache_drop field after lease_reclaim_free, 30s (the default) or off (0)
    drop30) b='2026/11/15 10:00:00 microvm-worker: relay=127.0.0.1:9643 sandbox_id=e15 tls=false vmm=firecracker D=0 guest=1024MiB budget=385024MiB slots=1792 standby_headroom=off mem_floor=1536MiB workspace_idle=24h0m0s lease=on lease_idle=5m0s/1h0m0s lease_max=8h0m0s/8h0m0s lease_grace=30s lease_start=192MiB lease_headroom=1.25 lease_pagecache=256MiB lease_reclaim_free=2048MiB lease_cache_drop=30s labels=map[]' ;;
    dropoff) b='2026/11/15 10:00:00 microvm-worker: relay=127.0.0.1:9643 sandbox_id=e15 tls=false vmm=firecracker D=0 guest=1024MiB budget=385024MiB slots=1792 standby_headroom=off mem_floor=1536MiB workspace_idle=24h0m0s lease=on lease_idle=5m0s/1h0m0s lease_max=8h0m0s/8h0m0s lease_grace=30s lease_start=192MiB lease_headroom=1.25 lease_pagecache=256MiB lease_reclaim_free=2048MiB lease_cache_drop=off labels=map[]' ;;
    # a pin whose drop default is not 30s (final review M3: 5a's +45 s reading assumes the 30 s drop)
    drop45) b='2026/11/15 10:00:00 microvm-worker: relay=127.0.0.1:9643 sandbox_id=e15 tls=false vmm=firecracker D=0 guest=1024MiB budget=385024MiB slots=1792 standby_headroom=off mem_floor=1536MiB workspace_idle=24h0m0s lease=on lease_idle=5m0s/1h0m0s lease_max=8h0m0s/8h0m0s lease_grace=30s lease_start=192MiB lease_headroom=1.25 lease_pagecache=256MiB lease_reclaim_free=2048MiB lease_cache_drop=45s labels=map[]' ;;
    esac
    for a; do case "\$a" in StandardOutput=file:*)
      { [ -z "\$b" ] || printf '%s\n' "\$b"; printf '2026/11/15 10:00:01 microvm-worker: attached, serving execs\n'; } >"\${a#StandardOutput=file:}" ;; esac; done ;;
  esac
  exit 0 ;;
esac
exec "\$@"
SH
  printf '#!/usr/bin/env bash\n[ -e "%s/relay-up" ] && printf "LISTEN 0 1 127.0.0.1:9643 0.0.0.0:*\\nLISTEN 0 1 127.0.0.1:9644 0.0.0.0:*\\n"\nexit 0\n' "$RS" >"$RSS/ss"
  cat >"$RSS/grpcurl" <<SH
#!/usr/bin/env bash
k=\$(echo "\$*" | grep -o '"workspace_key": *"[^"]*"' | sed 's/.*"\([^"]*\)"\$/\1/')
echo "{\"error\": {\"message\": \"invalid-workspace-key: workspace_key \\\\\"\$k\\\\\" must match [A-Za-z0-9][A-Za-z0-9._-]{0,127}\"}}"
echo "ERROR: Code: Internal" >&2; exit 1
SH
  printf '#!/usr/bin/env bash\nargs=(); for a; do case "$a" in --reflink=*|--sparse=*) ;; *) args+=("$a") ;; esac; done\nexec /bin/cp "${args[@]}"\n' >"$RSS/cp"
  # sed: rung.sh's `sed -E -i EXPR FILE` is GNU's; BSD sed needs a suffix argument
  printf '#!/usr/bin/env bash\nargs=(); inplace=0; for a; do if [ "$a" = -i ]; then inplace=1; else args+=("$a"); fi; done\nif [ $inplace = 1 ]; then f=${args[${#args[@]}-1]}; unset "args[${#args[@]}-1]"; /usr/bin/sed "${args[@]}" "$f" >"$f.sedtmp" && mv "$f.sedtmp" "$f"; else exec /usr/bin/sed "${args[@]}"; fi\n' >"$RSS/sed"
  chmod +x "$RSS"/*
}
srung() { # ARM [VAR=val ...]: a 1-session rung of ARM on the default point; E17B=1 unless E17B= is passed
  local arm=$1
  shift
  : >"$SORD"
  : >"$SARGS"
  : >"$SSYS"
  rm -f "$RS/worker-up" "$RS/secrets/relay-lease.env" "$RS/driver-saw.log"
  touch "$RS/relay-up"
  rm -rf "$RS/runs"
  mkdir -p "$RS/runs"
  printf 'MemoryMax=%s\nMemoryHigh=%s\n' "$SLICE_MAX0" "$SLICE_HIGH0" >"$RS/slice.state"
  env E17B=1 E15_TEST_PINS="$TMP/e17b-test-pins.sh" E15_HOST_PROFILE=fresh-metal E15_ROOT="$RS" E15_TEST_ROOT="$RS" E15_MANIFEST="$TMP/ship.md" \
    E15_WARMUP_S=1 E15_WINDOW_S=1 E15_MEMINFO="$RS/meminfo" PATH="$RSS:$STUB:$PATH" "$@" bash "$RIG/rung.sh" "$arm" "${SRUNG_N:-1}" "${SRUNG_POINT:-default}" >"$TMP/ship-rung.out" 2>&1
}
qrung() { SRUNG_POINT=squeeze srung "$@"; } # ARM [VAR=val ...]: the same rung at the squeeze point
sparams() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$RS/runs/default/$1/N1/params.json" "$2" 2>&1; }
test_ship_rung_passes_lease_flags() {
  srung ship-120
  local args
  args=$(grep -v '^mint-key' "$SARGS")
  check "ship rung: the driver gets --lease-mode, --token-key, --idle-timeout-s 120, --token-wrk e15, --token-iss e17b-driver" \
    "$(printf '%s' "$args" | grep -c -- '--lease-mode --token-key '"$RS"'/secrets/token-[^ /]*/token.key --idle-timeout-s 120 --token-wrk e15 --token-iss e17b-driver')" "1"
  check "ship rung: the idle timeout follows the arm (30 / 300)" \
    "$(for a in ship-30 ship-300; do srung $a; grep -o -- '--idle-timeout-s [0-9]*' "$SARGS"; done | tr '\n' ' ')" "--idle-timeout-s 30 --idle-timeout-s 300 "
  srung ship-30
  check "ship rung: the -e17b driver ran, the sealed e15-driver never" "$(grep -c '^driver$' "$SORD")/$(grep -c SEALED-DRIVER-RAN "$SORD")" "1/0"
  check "ship rung: no end-session Exec (the lease ends by idle timeout or the worker stop)" "$(grep -c -- '--end-session' "$SARGS")" "0"
  check "ship rung: the end-of-run order is driver, then worker stop" \
    "$(grep -E '^(driver|worker-stop)$' "$SORD" | tr '\n' ' ')" "driver worker-stop "
  check "ship rung: the key was minted by the -e17b driver before the relay started" \
    "$(head -1 "$SARGS" | cut -d' ' -f1)/$(awk '/^relay-start/{r=NR} END{print (r > 0) ? "relay" : "none"}' "$SORD")" "mint-key/relay"
  check "ship rung: the wbin map in params knows the ship arms under E17B=1 only (worker_bin_sha256 set from the -e17b worker)" \
    "$(grep -c 'ship_wbin="\\"ship-30\\": \\"\$(worker_bin ship-30)\\", \\"ship-120\\": \\"\$(worker_bin ship-120)\\", \\"ship-300\\": \\"\$(worker_bin ship-300)\\","' "$RIG/rung.sh")" "1"
  check "ship rung: params.json records arm, idle_timeout_s, moca_commit, the worker banner" \
    "$(sparams ship-30 arm)/$(sparams ship-30 idle_timeout_s)/$(sparams ship-30 moca_commit)/$(sparams ship-30 lease_banner | grep -c 'microvm-worker: relay=.*lease_start=192MiB')" "ship-30/30/$E17B_FIXPIN/1"
  check "ship rung: params.json worker_env carries the admission settings" \
    "$(sparams ship-30 worker_env | grep -c "'SH_MAX_COMMITTED_MB': '385024'")" "1"
  check "ship rung: params.json keeps driver_bin_sha256 of the -e17b driver (not the sealed one)" \
    "$(sparams ship-30 driver_bin_sha256)" "$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$RS/bin/e15-driver-e17b")"
  check "ship rung: the driver records py_shmem's stdout (--record-stdout py_shmem, E17B-R22)" \
    "$(grep -c -- '--record-stdout py_shmem' "$SARGS")" "1"
  srung sbx
  check "sbx rung under E17B=1: the -e17b driver runs and gets no lease flag" "$(grep -c '^driver$' "$SORD")/$(grep -c -- '--lease-mode\|--token' "$SARGS")" "1/0"
  check "sbx rung under E17B=1: it records py_shmem's stdout too" "$(grep -c -- '--record-stdout py_shmem' "$SARGS")" "1"
  check "--record-stdout is passed only under E17B=1 (the sealed driver never gets it)" \
    "$(grep -c 'stdout_flag=(--record-stdout py_shmem)' "$RIG/rung.sh")/$(grep -B2 'stdout_flag=(--record-stdout py_shmem)' "$RIG/rung.sh" | grep -c 'E17B:-}" = 1')/$(grep -c '"\${stdout_flag\[@\]}"' "$RIG/rung.sh")" "1/1/1"
  check "sbx rung under E17B=1: no mint-key, no lease params" "$(grep -c '^mint-key' "$SARGS")/$(sparams sbx idle_timeout_s | grep -c KeyError)" "0/1"
}
test_relay_env_has_token_keyset_and_issuer() {
  srung ship-300
  local relay_line
  relay_line=$(grep -- '--unit=e15-relay.service' "$SSYS")
  check "relay env: a lease arm adds one more EnvironmentFile to the relay unit" "$(printf '%s' "$relay_line" | grep -o 'EnvironmentFile=[^ ]*' | tr '\n' ' ' | sed "s#$RS/##g")" "EnvironmentFile=secrets/relay.env EnvironmentFile=secrets/relay-lease.env "
  check "relay env: the file holds the token.pub content and the fixed issuer, nothing else" \
    "$(cat "$RS/secrets/relay-lease.env")" "SH_SANDBOX_TOKEN_PUBLIC_KEYS=kid0123456789abcd:QUJD
SH_SANDBOX_TOKEN_ISSUER=e17b-driver"
  check "relay env: the file is mode 0600" "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$RS/secrets/relay-lease.env")" "0o600"
  check "relay env: the keyset is the one minted for this rung (the driver's --token-key dir, as the driver saw it)" \
    "$(sed -n 's/^pub \([^ ]*\) mode .*/\1/p' "$RS/driver-saw.log")" "kid0123456789abcd:QUJD"
  check "relay env: the key directory is mode 0700 (as the driver saw it)" "$(sed -n 's/.* mode //p' "$RS/driver-saw.log")" "700"
  srung ship-30
  local d1 d2
  d1=$(grep -o -- '--token-key [^ ]*' "$SARGS")
  sleep 1
  srung ship-30
  d2=$(grep -o -- '--token-key [^ ]*' "$SARGS")
  check "relay env: a new key directory per rung (a key per run)" "$([ "$d1" != "$d2" ] && echo differ || echo same)" "differ"
  srung sbx
  check "relay env: sbx under E17B=1 is unchanged (one EnvironmentFile, no keyset file)" \
    "$(grep -- '--unit=e15-relay.service' "$SSYS" | grep -o 'EnvironmentFile=[^ ]*' | wc -l | tr -d ' ')/$([ -e "$RS/secrets/relay-lease.env" ] && echo exists || echo none)" "1/none"
  check "relay env: start_relay without an argument is the sealed command line (E17B-free callers unchanged)" \
    "$(grep -c 'start_relay()' "$RIG/lib.sh")/$(grep -c 'EnvironmentFile="\$E15_SECRETS/relay.env"' "$RIG/lib.sh")" "1/1"
  : >"$SSYS"
  srung sbx E17B=
  check "relay env: a sealed rung (E17B unset) is unchanged too" "$(grep -- '--unit=e15-relay.service' "$SSYS" | grep -c 'relay-lease.env')" "0"
}
test_rung_marks_ship_rung_failed() {
  srung ship-30 STUB_DRIVER_EXIT=0 STUB_CALLS='{"session":"a","cause":"set_mode_failed"}'
  check "ship rung failure: a set_mode_failed row fails the rung even when the driver exits 0 (logged)" \
    "$(grep -c 'ship-30 rung failed: 1 call(s) with cause set_mode_failed' "$TMP/ship-rung.out")" "1"
  check "ship rung failure: params.json carries rung_failed and a non-zero driver_exit" "$(sparams ship-30 rung_failed)/$(sparams ship-30 driver_exit)" "set_mode_failed=1/1"
  srung ship-30 STUB_DRIVER_EXIT=1
  check "ship rung failure: a non-zero driver exit fails the rung (logged, recorded)" \
    "$(grep -c 'ship-30 rung failed: driver exit 1' "$TMP/ship-rung.out")/$(sparams ship-30 rung_failed)/$(sparams ship-30 driver_exit)" "1/driver_exit=1/1"
  srung ship-30 STUB_DRIVER_EXIT=0 STUB_CALLS='{"session":"a","cause":"ok"}'
  check "ship rung failure: a clean driver and no set_mode_failed row is not a failure" \
    "$(grep -c 'rung failed' "$TMP/ship-rung.out")/$(sparams ship-30 rung_failed)/$(sparams ship-30 driver_exit)" "0/None/0"
  check "ship rung failure: a memory-watchdog abort (the host's verdict) is not a failed rung" \
    "$(grep -c 'if \[ "\$driver_exit" != 0 \] && \[ "\$memory_abort" = null \]; then' "$RIG/rung.sh")" "1"
  srung sbx STUB_DRIVER_EXIT=0 STUB_CALLS='{"session":"a","cause":"set_mode_failed"}'
  check "ship rung failure: the rule is for ship-* only (sbx is not judged by it)" "$(grep -c 'rung failed' "$TMP/ship-rung.out")/$(sparams sbx driver_exit)" "0/0"
}
test_ship_rung_harness
test_ship_arms_known_on_fresh_metal_only
test_ship_worker_env_has_admission
test_sbx_arm_unchanged
test_e17b_driver_builds_to_separate_binaries
test_sealed_driver_untouched_when_e17b_set
test_ship_rung_passes_lease_flags
test_relay_env_has_token_keyset_and_issuer
test_rung_marks_ship_rung_failed
check "ship arms: smoke.sh and reprobe.sh and record.py name them" \
  "$(grep -c 'ship-30 ship-120 ship-300' "$RIG/../../e17-lease/rig/smoke.sh")/$(grep -c 'ship-30 ship-120 ship-300' "$RIG/../../e17-lease/rig/reprobe.sh")/$(grep -c '"ship-30", "ship-120", "ship-300"' "$RIG/../analysis/record.py")" "1/1/1"
# --- E17b Task 9: the squeeze point, the MemoryMax knob, the squeeze stop rule; Task 4 carry-overs C4-1..C4-3 ---
qparam() { python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get(sys.argv[2]), sort_keys=True))' "$RS/runs/squeeze/$1/N1/params.json" "$2" 2>&1; }
test_squeeze_point_defined() {
  local f='e15_point squeeze && echo "$E15_P_ARMS|$E15_P_CORPUS|$E15_P_DATASET_MIB|$E15_P_IMAGE_MB|$E15_P_TEMPLATE_STAMP|${E15_P_LIBRARY#"$E15_ROOT"/}|$E15_P_FALLBACK|$E15_P_PROBE_CAP_MS"'
  check "squeeze: pycache-d768's workload (corpus pycache, D 768, 1536 MiB image, its template, the E17 library) with arms ship-300 and sbx" \
    "$(t17m fresh-metal 1 "$f")" "ship-300 sbx|pycache|768|1536|template-pycache-d768|src/e17/workload/library.json|0|120000"
  check "squeeze: its settings are pycache-d768's but for the point name, so its signature (and baselines) are its own" \
    "$(t17m fresh-metal 1 'e15_point squeeze; a=${E15_P_SETTINGS/point=squeeze /point=pycache-d768 }; e15_point pycache-d768; [ "$a" = "$E15_P_SETTINGS" ] && echo same; [ "$(e15_point_sig squeeze)" != "$(e15_point_sig pycache-d768)" ] && echo own-sig' | tr '\n' ' ')" "same own-sig "
  check "squeeze: unknown with E17B unset, and on aws-prelim" \
    "$(t17m fresh-metal unset 'e15_point squeeze; echo $?')/$(t17m aws-prelim 1 'e15_point squeeze; echo $?')" "1/1"
  check "squeeze: no other point's arms or settings change (pycache-d768 still runs the E17 arms and the ship arms)" \
    "$(t17m fresh-metal 1 'e15_point pycache-d768; echo $E15_P_ARMS')" "sbx resident-300 lease-30 lease-120 ship-30 ship-120 ship-300"
  qrung ship-30 # (resident-300 is no longer an arm under E17B=1 at all: PR #34)
  check "squeeze: rung.sh refuses an arm the point does not run (exit 2)" "$?/$(grep -c 'POINT squeeze does not run ARM ship-30' "$TMP/ship-rung.out")" "2/1"
  qrung ship-300
  check "squeeze: a ship-300 rung at the point runs (exit 0) with the D=768 template" "$?/$(qparam ship-300 point)/$(qparam ship-300 dataset_mib)" '0/"squeeze"/768'
}
test_memmax_set_and_restored_on_error() {
  local want_set="set-property MemoryMax=17179869184 MemoryHigh=16106127360" want_restore="set-property MemoryMax=$SLICE_MAX0 MemoryHigh=$SLICE_HIGH0"
  local orig="MemoryMax=$SLICE_MAX0 MemoryHigh=$SLICE_HIGH0 "
  : >"$TMP/ship.md"
  qrung ship-300 E15_SQUEEZE_MEMMAX_MB=16384
  check "memmax: a squeeze rung with the knob completes (exit 0)" "$?" "0"
  check "memmax: the originals are read first, the limit set (MemoryHigh = MemoryMax - 1 GiB) before the worker starts, the originals restored after it stops, then the runtime drop-ins removed and systemd reloaded" \
    "$(grep -E '^(show-slice|set-property|worker-start|driver|worker-stop|sudo-rm|daemon-reload)' "$SORD" | tr '\n' ';')" \
    "show-slice;$want_set;worker-start;driver;worker-stop;$want_restore;sudo-rm -f -- /run/systemd/system.control/e15.slice.d/50-MemoryMax.conf /run/systemd/system.control/e15.slice.d/50-MemoryHigh.conf;daemon-reload;"
  check "memmax: the slice is back at its original values" "$(tr '\n' ' ' <"$RS/slice.state")" "$orig"
  check "memmax: one manifest line for the change, its UNDO the restore to the originals" \
    "$(grep -c "e15.slice MemoryMax=17179869184 MemoryHigh=16106127360 .*| UNDO: sudo -n systemctl set-property --runtime e15.slice MemoryMax=$SLICE_MAX0 MemoryHigh=$SLICE_HIGH0; sudo -n rm -f -- /run/systemd/system.control/e15.slice.d/50-MemoryMax.conf /run/systemd/system.control/e15.slice.d/50-MemoryHigh.conf; sudo -n systemctl daemon-reload\$" "$TMP/ship.md")/$(grep -c 'UNDO' "$TMP/ship.md")" "1/1"
  check "memmax: params.json records the knob, the squeezed and the original values, and the restore" \
    "$(qparam ship-300 squeeze_memmax_mb)/$(qparam ship-300 squeeze_slice)" \
    "16384/{\"MemoryHigh\": 16106127360, \"MemoryMax\": 17179869184, \"original_MemoryHigh\": \"$SLICE_HIGH0\", \"original_MemoryMax\": \"$SLICE_MAX0\", \"restored\": true}"
  qrung ship-300 E15_SQUEEZE_MEMMAX_MB=16384 STUB_BANNER=off
  check "memmax on error: the rung dies before the driver (lease=off) and the trap still restores the slice" \
    "$?/$(grep -c '^driver$' "$SORD")/$(grep -E '^set-property' "$SORD" | tr '\n' ';')/$(tr '\n' ' ' <"$RS/slice.state")" "1/0/$want_set;$want_restore;/$orig"
  qrung ship-300 E15_SQUEEZE_MEMMAX_MB=16384 STUB_DRIVER_TERM=1
  check "memmax on a signal: the rung killed (SIGTERM) while the driver runs restores the slice" \
    "$?/$(grep -E '^set-property' "$SORD" | tr '\n' ';')/$(tr '\n' ' ' <"$RS/slice.state")" "143/$want_set;$want_restore;/$orig"
  qrung ship-300 E15_SQUEEZE_MEMMAX_MB=16384 STUB_SETPROP_FAIL=1
  check "memmax: a failing set-property dies before the worker starts, and the restore is still attempted" \
    "$?/$(grep -c '^worker-start' "$SORD")/$(grep -c '^set-property' "$SORD")/$(grep -c 'could not restore e15.slice' "$TMP/ship-rung.out")" "1/0/2/1"
  qrung ship-300 E15_SQUEEZE_MEMMAX_MB=999999999
  check "memmax: a value above the slice's own MemoryMax is refused (a squeeze only lowers it), nothing set" \
    "$?/$(grep -c '^set-property' "$SORD")/$(grep -c 'a squeeze only lowers it' "$TMP/ship-rung.out")" "1/0/1"
  check "memmax: bad values (incl. 8192: no committed budget left, E17B-R20) are usage errors before any host change (exit 2, no systemd call)" \
    "$(for v in abc 1024 0 -5 08192 8192; do qrung ship-300 E15_SQUEEZE_MEMMAX_MB=$v; printf '%s:%s ' "$?" "$(grep -c . "$SSYS")"; done)" "2:0 2:0 2:0 2:0 2:0 2:0 "
  srung ship-300 E15_SQUEEZE_MEMMAX_MB=16384
  check "memmax: refused at any point but squeeze (exit 2, no systemd call, slice untouched)" "$?/$(grep -c . "$SSYS")/$(grep -cE '^(show-slice|set-property)' "$SORD")" "2/0/0"
  qrung ship-300
  check "memmax: unset at squeeze -> the slice is neither read nor set; params has no squeeze fields" \
    "$(grep -cE '^(show-slice|set-property)' "$SORD")/$(qparam ship-300 squeeze_memmax_mb)" "0/null"
  srung sbx E17B=
  check "memmax: a sealed rung (E17B unset) never reads or sets the slice" "$(grep -cE '^(show-slice|set-property)' "$SORD")" "0"
  check "refuse_units (fresh-metal): set-property on e15.slice with MemoryMax/MemoryHigh passes; another unit or property is refused" \
    "$(for c in 'set-property --runtime e15.slice MemoryMax=1 MemoryHigh=1' 'set-property --runtime system.slice MemoryMax=1' 'set-property --runtime sh-relay.service MemoryMax=1' 'set-property --runtime e15.slice CPUQuota=10%'; do t17m fresh-metal 1 "(refuse_units $c) >/dev/null 2>&1 && echo pass || echo refused"; done | tr '\n' ' ')" "pass refused refused refused "
  check "lib.sh e15_squeeze_limits: MemoryMax = MB MiB, MemoryHigh = MemoryMax - 1 GiB (the slice rule)" "$(t17m fresh-metal 1 'e15_squeeze_limits 8192')" "8589934592 7516192768"
  srung sbx E17B= E15_SQUEEZE_ACTIVE=1 E15_SQUEEZE_ORIG_MAX=1 E15_SQUEEZE_ORIG_HIGH=1
  check "memmax: an exported E15_SQUEEZE_ACTIVE=1 does not leak into a sealed rung (no set-property, no drop-in removal)" \
    "$(grep -cE '^(set-property|sudo-rm|daemon-reload)' "$SORD")" "0"
  qrung ship-300 E15_SQUEEZE_ACTIVE=1 E15_SQUEEZE_ORIG_MAX=1 E15_SQUEEZE_ORIG_HIGH=1
  check "memmax: nor into a squeeze rung without the knob" "$(grep -cE '^(set-property|sudo-rm|daemon-reload)' "$SORD")" "0"
}
test_rung_removes_token_keys() {
  local n
  srung ship-30
  n=$(find "$RS/secrets" -maxdepth 1 -name 'token-*' | wc -l | tr -d ' ')
  check "token keys: the driver had its key dir, and the rung removed it at its end" "$(grep -c '^pub ' "$RS/driver-saw.log")/$n" "1/0"
  srung ship-30 STUB_BANNER=off
  check "token keys: removed when the rung dies after the mint (before the driver)" "$(find "$RS/secrets" -maxdepth 1 -name 'token-*' | wc -l | tr -d ' ')" "0"
  srung ship-30 STUB_DRIVER_TERM=1
  check "token keys: removed when the rung is killed while the driver runs" "$(find "$RS/secrets" -maxdepth 1 -name 'token-*' | wc -l | tr -d ' ')" "0"
  check "token keys: the rung's other secrets stay" "$(cat "$RS/secrets/exec.token")" "tok"
  srung ship-30 E15_TAG='x..y'
  check "token keys: a RUN_ID that is not a plain token-<run> leaf (here a ..) is refused before the mint" "$?/$(grep -c '^mint-key' "$SARGS")/$(grep -c 'not a token-<run> leaf' "$TMP/ship-rung.out")" "1/0/1"
  check "token keys: no manifest line (the rung creates and removes the dir under \$E15_ROOT; the reason is in rung.sh)" \
    "$(grep -c 'token-' "$TMP/ship.md")/$(grep -c 'needs no manifest line' "$RIG/rung.sh")" "0/1"
  local S="$TROOT/secrets"
  rm -rf "$S" "$TMP/tk-outside"
  mkdir -p "$S/token-ok" "$S/token-extra" "$TMP/tk-outside"
  echo k >"$S/token-ok/token.key"; echo p >"$S/token-ok/token.pub"
  echo k >"$S/token-extra/token.key"; echo x >"$S/token-extra/other"
  echo keep >"$TMP/tk-outside/token.key"
  ln -s "$TMP/tk-outside" "$S/token-link"
  echo s >"$S/exec.token"
  local rm_t='(e17b_token_dir_remove "$1") >/dev/null 2>&1 && echo removed || echo refused'
  check "token dir removal: a token-<run> leaf with its key pair is removed" "$(t17m fresh-metal 1 "set -- '$S/token-ok'; $rm_t")/$([ -e "$S/token-ok" ] && echo left || echo gone)" "removed/gone"
  check "token dir removal: refuses the secrets dir itself, a dot-dot path, a nested path, a non-token leaf" \
    "$(for d in "$S" "$S/../secrets" "$S/token-a/b" "$S/exec.token" "$S/token-" "$S/token-.."; do t17m fresh-metal 1 "set -- '$d'; $rm_t"; done | tr '\n' ' ')" "refused refused refused refused refused refused "
  check "token dir removal: refuses a symlinked leaf; its target is untouched" \
    "$(t17m fresh-metal 1 "set -- '$S/token-link'; $rm_t")/$(cat "$TMP/tk-outside/token.key")" "refused/keep"
  check "token dir removal: an unexpected file stays (never rm -rf): the key goes, the dir is kept" \
    "$(t17m fresh-metal 1 "set -- '$S/token-extra'; $rm_t")/$(find "$S/token-extra" -mindepth 1 -exec basename {} \; | tr '\n' ' ')" "refused/other "
  check "token dir removal: other secrets are untouched" "$(cat "$S/exec.token")" "s"
  check "token dir removal: no rm -rf in it" "$(sed -n '/^e17b_token_dir_remove()/,/^}/p' "$RIG/lib.sh" | grep -c 'rm -rf')/$(sed -n '/^e17b_token_dir_remove()/,/^}/p' "$RIG/lib.sh" | grep -c 'rm -f --')" "0/1"
  rm -rf "$S" "$TMP/tk-outside"
}
test_ship_rung_checks_lease_banner() {
  srung ship-300 STUB_BANNER=off
  check "lease banner: lease=off -> the rung dies before the driver starts, naming lease-v1" \
    "$?/$(grep -c '^driver$' "$SORD")/$(grep -c "banner says lease=off: the snapshot $RS/snapshots/e17b-11111111-1024 does not advertise lease-v1" "$TMP/ship-rung.out")" "1/0/1"
  srung ship-300 STUB_BANNER=none
  check "lease banner: no banner -> the rung dies before the driver starts" "$?/$(grep -c '^driver$' "$SORD")/$(grep -c 'no startup banner' "$TMP/ship-rung.out")" "1/0/1"
  srung ship-300
  check "lease banner: lease=on -> logged, the driver runs" "$?/$(grep -c '^driver$' "$SORD")/$(grep -c 'worker banner: lease=on' "$TMP/ship-rung.out")" "0/1/1"
  check "lease banner: the check comes before the relay attach probe (no probe Exec on a lease=off worker)" \
    "$(awk '/worker banner: lease=on/{b=NR} /relay attach check passed/{p=NR} END{print (b && p && b < p) ? "before" : "after"}' "$TMP/ship-rung.out")" "before"
  srung sbx STUB_BANNER=off
  check "lease banner: under E17B=1 sbx needs the lease-v1 snapshot too (every E17b arm runs on it)" "$?/$(grep -c '^driver$' "$SORD")" "1/0"
  srung sbx STUB_BANNER=none E17B=
  check "lease banner: a sealed rung (E17B unset) is not checked" "$(grep -c 'SEALED-DRIVER-RAN' "$SORD")" "1"
}
# the squeeze ladder rule: the stop rule's reading of samples.jsonl (worker /stats leaseEnds), then ladder.sh
SQRULE="$RIG/../../e17-lease/analysis/squeeze_rule.py"
mkq() { # DIR WARMUP WINDOW EXPR: params.json + samples.jsonl at 1 Hz; EXPR(t) is the cumulative memory_reclaim
  # count, None for a sample without worker stats, -1 for worker stats without leaseEnds (sbx)
  mkdir -p "$1"
  python3 - "$@" <<'PY'
import json, sys
d, w, win, expr = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
f = eval("lambda t: " + expr)
json.dump({"warmup_s": w, "window_s": win, "arm": "ship-300", "n": 8, "memory_abort": None, "oom_kills": 0},
          open(d + "/params.json", "w"))
with open(d + "/samples.jsonl", "w") as o:
    for t in range(0, w + win + 30):
        v = f(t)
        r = {"t": t, "ts": 1e9 + t}
        if v is not None:
            r["worker"] = {"leaseVMs": 3} if v < 0 else {"leaseEnds": {"idle": 3, "memory_reclaim": v}}
        o.write(json.dumps(r) + "\n")
PY
}
sqr() { # DIR -> "met/min_per_minute/why-word" from squeeze-rule.json (and the script's exit code)
  python3 "$SQRULE" "$1" >"$TMP/sqr.out" 2>&1
  local rc=$?
  python3 -c 'import json,sys; r=json.load(open(sys.argv[1] + "/squeeze-rule.json")); print("%s/%s/%s/%s" % (sys.argv[2], json.dumps(r["met"]), r.get("min_per_minute"), (r.get("why") or "-").split(" ")[0]))' "$1" "$rc" 2>&1
}
test_squeeze_stop_rule() {
  local q="$TMP/sq-rule"
  rm -rf "$q"
  mkq "$q/a" 60 300 't // 30'
  check "stop rule: a reclaim every 30 s through the window -> met (2 per minute in each of 5 minutes)" "$(sqr "$q/a")" "0/true/2/-"
  check "stop rule: squeeze-rule.json lists the 5 whole minutes of the window [60, 360)" \
    "$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r["window"], [(b["start"], b["end"], b["memory_reclaim"]) for b in r["bins"]])' "$q/a/squeeze-rule.json")" \
    "[60, 360] [(60, 120, 2), (120, 180, 2), (180, 240, 2), (240, 300, 2), (300, 360, 2)]"
  mkq "$q/b" 60 300 't // 30 if t < 180 else (6 if t < 240 else 6 + (t - 240) // 30)'
  check "stop rule: one minute without a reclaim -> not met, naming the minute" "$(sqr "$q/b")/$(grep -c 'minute \[180, 240) had 0' "$q/b/squeeze-rule.json")" "0/false/0/minute/1"
  mkq "$q/c" 60 300 '0 if t < 70 else 10'
  check "stop rule: 10 reclaims bunched in the first minute (2 per minute on average) -> not met (every minute counts)" "$(sqr "$q/c")" "0/false/0/minute"
  mkq "$q/d" 60 300 'min(t, 59) // 10'
  check "stop rule: reclaims in the warm-up only -> not met" "$(sqr "$q/d")" "0/false/0/minute"
  mkq "$q/e" 60 300 '-1'
  check "stop rule: worker stats without leaseEnds (sbx) -> not met, 0 reclaims" "$(sqr "$q/e")" "0/false/0/minute"
  mkq "$q/f" 60 300 'None if 230 <= t <= 241 else t // 30'
  check "stop rule: samples missing around a boundary but rows inside each minute -> judged (first row at or after the start, last at or before the end)" \
    "$(sqr "$q/f")/$(python3 -c 'import json,sys; print([b["memory_reclaim"] for b in json.load(open(sys.argv[1]))["bins"]])' "$q/f/squeeze-rule.json")" "0/true/1/-/[2, 2, 1, 2, 2]"
  mkq "$q/f2" 60 300 'None if 175 <= t <= 245 else t // 30'
  check "stop rule: a minute with no worker stats inside it -> undecidable (null), never guessed" "$(sqr "$q/f2")/$(grep -c 'no worker stats inside minute \[180, 240)' "$q/f2/squeeze-rule.json")" "0/null/None/no/1"
  mkq "$q/f3" 60 300 '(t - 5) // 30 if t % 60 >= 5 else None'
  check "stop rule: the bound is conservative (no tolerance): reclaims before a minute's first row are not counted in it" \
    "$(sqr "$q/f3")/$(python3 -c 'import json,sys; print([b["memory_reclaim"] for b in json.load(open(sys.argv[1]))["bins"]])' "$q/f3/squeeze-rule.json")" "0/true/1/-/[1, 1, 1, 1, 1]"
  mkq "$q/g" 60 300 't // 30 if t < 200 else 0'
  check "stop rule: a counter that goes down (the worker restarted) -> undecidable (null)" "$(sqr "$q/g")" "0/null/None/memory_reclaim"
  mkq "$q/h" 60 30 't'
  check "stop rule: a window shorter than a minute -> undecidable (null)" "$(sqr "$q/h")" "0/null/None/window"
  mkq "$q/i" 60 330 't // 30'
  check "stop rule: a trailing part of the window under a minute is not judged (5 bins of a 330 s window)" \
    "$(sqr "$q/i")/$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["bins"]))' "$q/i/squeeze-rule.json")" "0/true/2/-/5"
  check "stop rule: no samples.jsonl -> exit 1, no verdict" "$(rm -f "$q/a/samples.jsonl" "$q/a/squeeze-rule.json"; python3 "$SQRULE" "$q/a" >/dev/null 2>&1; echo $?)/$([ -e "$q/a/squeeze-rule.json" ] && echo written || echo none)" "1/none"
  rm -rf "$q"
  # ladder.sh at the squeeze point against a stub rung.sh: the stub writes record.json (holds breaks from N=16),
  # params.json and samples.jsonl whose reclaim rate is 2/min from N=SQ_MET_N (default 64) and 0 below
  local SQ="$TMP/e15-rig-test.sq" SR="$TMP/sq-rung.sh"
  rm -rf "$SQ"
  mkdir -p "$SQ/src/e17/analysis" "$SQ/runs"
  cp "$SQRULE" "$SQ/src/e17/analysis/squeeze_rule.py"
  cat >"$SR" <<'SH'
#!/usr/bin/env bash
arm=$1 n=$2 point=$3
echo "rung $arm $n $point memmax=${E15_SQUEEZE_MEMMAX_MB:-unset}" >>"$SQ_LOG"
d=$E15_ROOT/runs/$point/$arm/N$n${E15_TAG:+-$E15_TAG}
mkdir -p "$d"
h=true
[ "$n" -lt 16 ] || h=false
printf '{"holds": %s, "holds_abs": %s, "aborted": false, "unseeded_sessions": 0, "repeat_required": false, "median_class_pace": 1.0}\n' "$h" "$h" >"$d/record.json"
python3 - "$d" "$n" <<'PY'
import json, os, sys
d, n = sys.argv[1], int(sys.argv[2])
per = 2 if n >= int(os.environ.get("SQ_MET_N", "64")) else 0
gap = str(n) == os.environ.get("SQ_GAP_N")
abort = {"reason": "memory_floor"} if str(n) == os.environ.get("SQ_ABORT_N") else None
json.dump({"warmup_s": 60, "window_s": 300, "arm": "ship-300", "n": n, "memory_abort": abort, "oom_kills": 0}, open(d + "/params.json", "w"))
with open(d + "/samples.jsonl", "w") as o:
    for t in range(0, 400):
        r = {"t": t, "ts": 1e9 + t}
        if not (gap and 175 <= t <= 245):
            r["worker"] = {"leaseEnds": {"memory_reclaim": t * per // 60}}
        o.write(json.dumps(r) + "\n")
PY
SH
  chmod +x "$SR"
  sql() { # ARM [POINT] [VAR=val ...]: ladder.sh at the squeeze point (or POINT) with the stub; rc, output in $TMP/sq.out
    local arm=$1 pt=squeeze
    shift
    case "${1:-}" in *=*) ;; ?*) pt=$1; shift ;; esac
    : >"$TMP/sq.log"
    rm -rf "$SQ/runs"
    env E17B=1 E15_TEST_PINS="$TMP/e17b-test-pins.sh" E15_HOST_PROFILE=fresh-metal E15_ROOT="$SQ" E15_TEST_ROOT="$SQ" E15_MANIFEST="$TMP/sq.md" \
      E15_RUNG="$SR" SQ_LOG="$TMP/sq.log" PATH="$STUB:$PATH" "$@" bash "$RIG/ladder.sh" "$pt" "$arm" >"$TMP/sq.out" 2>&1
  }
  sqj() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(eval(sys.argv[2], {"d": d})))' "$SQ/runs/${2:-squeeze}/${3:-ship-300}/ladder.json" "$1" 2>&1; }
  sql ship-300 E15_SQUEEZE_MEMMAX_MB=16384
  check "squeeze ladder: climbs past the latency break (N=16) and stops at the first N whose window meets the rule (64)" \
    "$?/$(cut -d' ' -f3 "$TMP/sq.log" | tr '\n' ' ')" "0/1 8 16 24 32 40 48 56 64 "
  check "squeeze ladder: every rung ran with the knob" "$(grep -c 'memmax=16384$' "$TMP/sq.log")" "9"
  check "squeeze ladder: ladder.json records the stop N, why, the knob, and each rung's rule verdict; n_max is still the latency one" \
    "$(sqj 'd["squeeze"]["stop_n"]')/$(sqj 'd["squeeze"]["stopped_by"]')/$(sqj 'd["squeeze"]["memmax_mb"]')/$(sqj '[r["met"] for r in d["squeeze"]["rungs"]]')/$(sqj 'd["n_max"]')" \
    '64/"reclaim_rate"/16384/[false, false, false, false, false, false, false, false, true]/8'
  check "squeeze ladder: each rung dir has its squeeze-rule.json" "$(find "$SQ/runs/squeeze/ship-300" -name squeeze-rule.json | wc -l | tr -d ' ')" "9"
  sql ship-300 E15_SQUEEZE_MEMMAX_MB=16384 SQ_ABORT_N=32
  check "squeeze ladder: a memory-guard event (the watchdog's memory_abort) stops the climb there (criterion 3 already failed)" \
    "$?/$(sqj 'd["squeeze"]["stop_n"]')/$(sqj 'd["squeeze"]["stopped_by"]')/$(tail -1 "$TMP/sq.log" | cut -d' ' -f3)" '0/32/"guard"/32'
  sql ship-300 E15_SQUEEZE_MEMMAX_MB=16384 SQ_GAP_N=24
  check "squeeze ladder: an undecidable rung (stats missing at a boundary) is a rig error: the ladder dies there" \
    "$?/$(tail -1 "$TMP/sq.log" | cut -d' ' -f3)/$(grep -c 'squeeze stop rule undecidable at N=24' "$TMP/sq.out")" "1/24/1"
  sql ship-300 E15_SQUEEZE_MEMMAX_MB=16384 E15_LADDER_RUNGS="1 8 16"
  check "squeeze ladder: never met within the rungs climbed -> stop_n null, stopped_by top_of_ladder" \
    "$?/$(sqj 'd["squeeze"]["stop_n"]')/$(sqj 'd["squeeze"]["stopped_by"]')" '0/null/"top_of_ladder"'
  sql ship-300 E15_SQUEEZE_MEMMAX_MB=8192
  check "squeeze ladder: refused with a value that leaves no committed budget (8192, E17B-R20)" "$?/$(grep -c . "$TMP/sq.log")" "2/0"
  sql ship-300
  check "squeeze ladder: refused without E15_SQUEEZE_MEMMAX_MB (exit 2, no rung)" "$?/$(grep -c . "$TMP/sq.log")/$(grep -c 'E15_SQUEEZE_MEMMAX_MB' "$TMP/sq.out")" "2/0/1"
  sql sbx E15_SQUEEZE_MEMMAX_MB=16384
  check "squeeze ladder: refused for sbx (exit 2, no rung): sbx runs one rung at the N the ship-300 climb stopped at" "$?/$(grep -c . "$TMP/sq.log")" "2/0"
  sql ship-300 squeeze-256 E15_SQUEEZE_MEMMAX_MB=16384
  check "squeeze ladder: squeeze-256 climbs by the same stop rule (stops at 64, squeeze record in its ladder.json)" \
    "$?/$(tail -1 "$TMP/sq.log" | cut -d' ' -f3)/$(sqj 'd["squeeze"]["stop_n"]' squeeze-256)/$(sqj 'd["squeeze"]["stopped_by"]' squeeze-256)" '0/64/64/"reclaim_rate"'
  sql ship-300 pycache-d768
  check "squeeze ladder: any other point keeps the E15 stop rule (both verdicts broken at 16), no squeeze record" \
    "$?/$(cut -d' ' -f3 "$TMP/sq.log" | tr '\n' ' ')/$(sqj '"squeeze" in d' pycache-d768)" "0/1 8 16 /false"
  sql ship-300 pycache-d768 E15_SQUEEZE_MEMMAX_MB=16384
  check "squeeze ladder: the knob is refused at another point (exit 2, no rung)" "$?/$(grep -c . "$TMP/sq.log")" "2/0"
  rm -rf "$SQ" "$SR"
}
# --- E17b Task 9 fix round 1: the E17b snapshot leaf (E17B-R17) and the squeezed committed budget (E17B-R20) ---
test_e17b_snapshot_leaf_selected() {
  local f="$TMP/leaf-wenv" ev='grep -E "^(SH_SNAPSHOT_IMAGE|SH_GUEST_RAM_MB)=" "'"$TMP/leaf-wenv"'" | tr "\n" " "'
  check "leaf: under E17B=1 every arm's worker env names e17b-<pin8>-1024 at 1024 MiB, never the sealed e15 leaf" \
    "$(for a in sbx ship-30 ship-300; do t17m fresh-metal 1 "worker_env $a '$f'; $ev"; echo; done | sort -u | tr -d '\n')" "SH_SNAPSHOT_IMAGE=e17b-11111111-1024 SH_GUEST_RAM_MB=1024 "
  check "leaf: E17B_GUEST_RAM_MB=256 selects e17b-<pin8>-256 and a 256 MiB guest" \
    "$(t17m fresh-metal 1 "worker_env ship-300 '$f'; $ev" E17B_GUEST_RAM_MB=256)" "SH_SNAPSHOT_IMAGE=e17b-11111111-256 SH_GUEST_RAM_MB=256 "
  check "leaf: E17B unset -> the sealed e15 leaf and 1024 MiB, whatever E17B_GUEST_RAM_MB says" \
    "$(t17m fresh-metal unset "worker_env sbx '$f'; $ev" E17B_GUEST_RAM_MB=256)" "SH_SNAPSHOT_IMAGE=e15 SH_GUEST_RAM_MB=1024 "
  check "leaf: a guest RAM snapshot-e17b.sh does not build (512) is refused" "$(t17m fresh-metal 1 "(worker_env sbx '$f') >/dev/null 2>&1; echo \$?" E17B_GUEST_RAM_MB=512)" "1"
  srung ship-300
  check "leaf: params.json records the leaf, the guest RAM and the leaf's manifest hash" \
    "$(sparams ship-300 snapshot_image)/$(sparams ship-300 guest_ram_mb)/$(sparams ship-300 snapshot_hash)" "e17b-11111111-1024/1024/h1024"
  srung ship-300 E17B_GUEST_RAM_MB=256
  check "leaf: a 256 MiB rung records the 256 leaf" "$(sparams ship-300 snapshot_image)/$(sparams ship-300 guest_ram_mb)/$(sparams ship-300 snapshot_hash)" "e17b-11111111-256/256/h256"
  mv "$RS/snapshots/e17b-11111111-1024" "$RS/snapshots/hold-1024"
  srung sbx
  check "leaf: a missing leaf dies before the worker starts (and before the relay restart), naming the leaf and snapshot-e17b.sh" \
    "$?/$(grep -c '^worker-start' "$SORD")/$(grep -c '^relay-start' "$SORD")/$(grep -c "no E17b snapshot $RS/snapshots/e17b-11111111-1024 .*snapshot-e17b.sh" "$TMP/ship-rung.out")" "1/0/0/1"
  check "leaf: start_worker refuses a missing leaf too (smoke.sh's analyze check calls it directly)" \
    "$(sed -n '/^start_worker()/,/^}/p' "$RIG/lib.sh" | grep -c 'e17b_require_snapshot')" "1"
  mv "$RS/snapshots/hold-1024" "$RS/snapshots/e17b-11111111-1024"
  srung sbx E17B=
  check "leaf: a sealed rung records the e15 leaf's hash as before, and no snapshot_image key" "$(sparams sbx snapshot_image | grep -c KeyError)" "1"
}
test_squeeze_budget_follows_memmax() {
  qrung ship-300 E15_SQUEEZE_MEMMAX_MB=16384
  check "budget: at squeeze with the knob, ship-300's SH_MAX_COMMITTED_MB = MemoryMax - 8192 (the squeezed host); params records it" \
    "$(grep '^SH_MAX_COMMITTED_MB=' "$RS/runs/squeeze/ship-300/N1/worker.env")/$(qparam ship-300 committed_mb)/$(qparam ship-300 squeeze_memmax_mb)" "SH_MAX_COMMITTED_MB=8192/8192/16384"
  qrung sbx E15_SQUEEZE_MEMMAX_MB=16384
  check "budget: sbx at squeeze gets the same squeezed budget (the guard comparison is fair)" \
    "$(grep '^SH_MAX_COMMITTED_MB=' "$RS/runs/squeeze/sbx/N1/worker.env")/$(qparam sbx committed_mb)" "SH_MAX_COMMITTED_MB=8192/8192"
  qrung ship-300
  check "budget: at squeeze without the knob the arm's own budget stands (host RAM - 8192), no committed_mb key" \
    "$(grep '^SH_MAX_COMMITTED_MB=' "$RS/runs/squeeze/ship-300/N1/worker.env")/$(qparam ship-300 committed_mb)" "SH_MAX_COMMITTED_MB=385024/null"
  srung sbx
  check "budget: unchanged at other points (sbx keeps E16's never-binding budget)" "$(grep '^SH_MAX_COMMITTED_MB=' "$RS/runs/default/sbx/N1/worker.env")" "SH_MAX_COMMITTED_MB=1048576"
  check "budget: worker_env refuses a squeeze that leaves no budget" "$(t17m fresh-metal 1 "(worker_env ship-300 '$TMP/b-wenv') >/dev/null 2>&1; echo \$?" E15_SQUEEZE_MEMMAX_MB=8192)" "1"
  check "budget: the comment says the host-MemAvailable reclaim trigger is not exercised by the squeeze" "$(grep -c 'host-MemAvailable reclaim trigger is not exercised' "$RIG/lib.sh")" "1"
}
test_e17b_snapshot_leaf_selected
test_squeeze_budget_follows_memmax
test_squeeze_256_point() {
  local f='e15_point squeeze-256 && echo "$E15_P_ARMS|$E15_P_CORPUS|$E15_P_DATASET_MIB|$E15_P_IMAGE_MB|$E15_P_TEMPLATE_STAMP|${E15_P_LIBRARY#"$E15_ROOT"/}|$E15_P_FALLBACK|$E15_P_PROBE_CAP_MS"'
  check "squeeze-256: squeeze with D scaled to 192 (768 x 256/1024; its own template), the same corpus, library and arms" \
    "$(t17m fresh-metal 1 "$f")" "ship-300 sbx|pycache|192|1536|template-pycache-d192|src/e17/workload/library.json|0|120000"
  check "squeeze-256: unknown with E17B unset, and on aws-prelim" \
    "$(t17m fresh-metal unset 'e15_point squeeze-256; echo $?')/$(t17m aws-prelim 1 'e15_point squeeze-256; echo $?')" "1/1"
  check "squeeze-256: its own point signature" "$(t17m fresh-metal 1 '[ "$(e15_point_sig squeeze-256)" != "$(e15_point_sig squeeze)" ] && echo own')" "own"
  check "squeeze-256: e15_is_squeeze names both squeeze points and nothing else" \
    "$(t17m fresh-metal 1 'for p in squeeze squeeze-256 pycache-d768 default; do e15_is_squeeze $p && printf "%s " $p; done')" "squeeze squeeze-256 "
  SRUNG_POINT=squeeze-256 srung ship-300 E17B_GUEST_RAM_MB=256 E15_SQUEEZE_MEMMAX_MB=16384
  check "squeeze-256: a 256 MiB rung with the knob runs (exit 0): D=192, the 256 leaf, the slice squeezed and restored" \
    "$?/$(python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); print(p["dataset_mib"], p["guest_ram_mb"], p["snapshot_image"], p["squeeze_memmax_mb"], p["committed_mb"])' "$RS/runs/squeeze-256/ship-300/N1/params.json")/$(grep -c '^set-property' "$SORD")" \
    "0/192 256 e17b-11111111-256 16384 8192/2"
  SRUNG_POINT=squeeze-256 srung ship-300
  check "squeeze-256: refused (exit 2, nothing started) without E17B_GUEST_RAM_MB=256" \
    "$?/$(grep -c . "$SSYS")/$(grep -c 'POINT squeeze-256 runs at E17B_GUEST_RAM_MB=256' "$TMP/ship-rung.out")" "2/0/1"
  qrung ship-300 E17B_GUEST_RAM_MB=256
  check "squeeze: refused (exit 2) at 256 MiB (its D=768 is for 1024 MiB guests; squeeze-256 is the 256 MiB point)" \
    "$?/$(grep -c . "$SSYS")/$(grep -c 'POINT squeeze runs at E17B_GUEST_RAM_MB=1024' "$TMP/ship-rung.out")" "2/0/1"
}
test_squeeze_256_point
test_squeeze_point_defined
test_memmax_set_and_restored_on_error
test_rung_removes_token_keys
test_ship_rung_checks_lease_banner
test_squeeze_stop_rule

# --- PR #34 review: sealed rungs never resolve ship-* workers; E17a arms refused under E17B=1; driver rebuild guard ---
test_pr34_sealed_rung_has_no_worker_bin_errors() {
  srung sbx E17B=
  check "sealed rung (E17B unset): stderr has no worker_bin: line (the ship-* wbin keys exist only under E17B=1)" \
    "$(grep -c 'worker_bin:' "$TMP/ship-rung.out")/$(sparams sbx arm)" "0/sbx"
  check "sealed rung (E17B unset): worker_bin_sha256 is still the stock worker's" \
    "$(sparams sbx worker_bin_sha256)" "$(sha_f "$RS/bin/microvm-worker")"
  srung ship-30
  check "E17B=1 ship rung: worker_bin_sha256 is the -e17b worker's (the ship-* keys are there)" \
    "$(grep -c 'worker_bin:' "$TMP/ship-rung.out")/$(sparams ship-30 worker_bin_sha256)" "0/$(sha_f "$RS/bin/microvm-worker-e17b")"
}
test_pr34_e17a_arms_refused_under_e17b() {
  local isarm='for a in resident-inf resident-300 lease-30 lease-120; do e15_is_arm $a 2>/dev/null && printf "yes " || printf "no "; done'
  check "E17B=1: e15_is_arm refuses the E17a arms resident-* and lease-*" "$(t17m fresh-metal 1 "$isarm")" "no no no no "
  check "E17B unset: the E17a arms are arms as before" "$(t17m fresh-metal unset "$isarm")" "yes yes yes yes "
  check "E17B=1: the refusal says why (an E17a arm, the old-pin resident worker, run it with E17B unset)" \
    "$(t17m fresh-metal 1 'e15_is_arm lease-30' | grep -c 'lease-30 is an E17a arm.*old-pin.*E17B unset')" "1"
  check "E17B=1: worker_bin refuses resident-* and lease-* (exit 1, the same reason)" \
    "$(t17m fresh-metal 1 'for a in resident-inf resident-300 lease-30 lease-120; do (worker_bin $a) 2>&1 | grep -c "is an E17a arm"; (worker_bin $a) >/dev/null 2>&1; echo $?; done' | tr '\n' ' ')" "1 1 1 1 1 1 1 1 "
  check "E17B=1: rung.sh resident-300 is refused before anything runs (exit 2, the reason named)" \
    "$(mkdir -p "$TROOT/state"; printf '%s\n' "$E17B_FIXPIN" >"$TROOT/state/go-stock-e17b"; env E17B=1 E15_HOST_PROFILE=fresh-metal E15_TEST_PINS="$TMP/e17b-test-pins.sh" E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash "$RIG/rung.sh" resident-300 1 pycache >"$TMP/pr34-rung.out" 2>&1; echo $?; rm -rf "$TROOT/state")/$(grep -c 'is an E17a arm' "$TMP/pr34-rung.out")" "2/1"
  check "E17B=1: reprobe.sh lease-30 is refused (usage, the reason named)" \
    "$(env E17B=1 E15_HOST_PROFILE=fresh-metal E15_TEST_PINS="$TMP/e17b-test-pins.sh" E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" bash "$RIG/../../e17-lease/rig/reprobe.sh" lease-30 >"$TMP/pr34-rp.out" 2>&1; echo $?)/$(grep -c 'is an E17a arm' "$TMP/pr34-rp.out")/$(grep -c 'with E17B=1: sbx ship-30 ship-120 ship-300 only' "$TMP/pr34-rp.out")" "2/1/1"
  check "smoke.sh: the comment no longer says E15_ARMS lists sbx and ship-* only under E17B=1" \
    "$(grep -c 'list those only under E17B=1' "$RIG/../../e17-lease/rig/smoke.sh")" "0"
}
test_pr34_sealed_driver_rebuild_guard() {
  local blk="$TMP/pr34-driver-build.sh" rec="$TMP/pr34-driver-calls.log"
  awk '/^k=\$\(src_key driver\)$/{p=1} /^# E17b \(E17B=1\): the shipped worker runs/{exit} p{print}' "$RIG/setup.sh" >"$blk"
  mkdir -p "$TROOT/bin" "$TROOT/logs" "$TMP/driver"
  dblk() { # METAL [VAR=val ...]: the block with E17B unset; go builds simulated; stamps in $E15_BIN/.stamp-*; rc echoed
    local metal=$1
    shift
    : >"$rec"
    env -u E17B "$@" E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" REC="$rec" METAL="$metal" TMP_SRC="$TMP" bash -c '
      source "$1"
      GOENV_USER=()
      E15_SRC=$TMP_SRC
      src_key() { echo newkey; }
      env() { while [ $# -gt 0 ]; do [ "$1" = -o ] && { echo built >"$2"; echo "build $2" >>"$REC"; }; shift; done; }
      stamp_ok() { [ -e "$E15_BIN/.stamp-$1" ] && [ "$(cat "$E15_BIN/.stamp-$1")" = "$2" ]; }
      stamp_get() { cat "$E15_BIN/.stamp-$1" 2>/dev/null; }
      stamp_set() { echo "stamp $1 $2" >>"$REC"; printf "%s" "$2" >"$E15_BIN/.stamp-$1"; }
      sha256_of() { echo x; }
      m_note() { :; }
      source "$2"' _ "$RIG/lib.sh" "$blk" >"$TMP/pr34-dbuild.out" 2>&1
    echo $?
  }
  seal_bins() { # the E16 rig: both sealed drivers built from older sources
    rm -f "$TROOT"/bin/.stamp-* "$TROOT"/bin/e15-driver*
    printf 'sealed-driver' >"$TROOT/bin/e15-driver"
    chmod +x "$TROOT/bin/e15-driver"
    printf 'e15key' >"$TROOT/bin/.stamp-go-driver"
    printf 'sealed-defer' >"$TROOT/bin/e15-driver-defer"
    printf 'e16key' >"$TROOT/bin/.stamp-go-driver-defer"
  }
  seal_bins
  check "driver guard: sealed setup on metal refuses to rebuild an existing e15-driver-defer of another source key (nothing built)" \
    "$(dblk 1)/$(grep -c . "$rec")/$(cat "$TROOT/bin/e15-driver-defer")" "1/0/sealed-defer"
  check "driver guard: the refusal names the old and new keys, E15_ACK_DRIVER_REBUILD and the golden-tested default path" \
    "$(grep -c 'e15-driver-defer.*e16key.*newkey.*E15_ACK_DRIVER_REBUILD=1' "$TMP/pr34-dbuild.out")/$(grep -c 'golden-tested' "$TMP/pr34-dbuild.out")" "1/1"
  check "driver guard: E15_ACK_DRIVER_REBUILD=1 rebuilds it (stamped with the new key)" \
    "$(dblk 1 E15_ACK_DRIVER_REBUILD=1)/$(grep '^build' "$rec" | sed "s#$TROOT/##")/$(cat "$TROOT/bin/.stamp-go-driver-defer")" "0/build bin/e15-driver-defer/newkey"
  seal_bins
  check "driver guard: off metal, an existing e15-driver of another key is refused too; ACK rebuilds it" \
    "$(dblk 0)/$(grep -c 'e15-driver: its stamp go-driver is e15key' "$TMP/pr34-dbuild.out")/$(cat "$TROOT/bin/e15-driver")/$(dblk 0 E15_ACK_DRIVER_REBUILD=1)/$(cat "$TROOT/bin/e15-driver")" "1/1/sealed-driver/0/built"
  seal_bins
  check "driver guard: E16_REBUILD_DRIVER=1 alone does not rebuild the sealed e15-driver (the ACK is needed)" \
    "$(dblk 1 E16_REBUILD_DRIVER=1)/$(cat "$TROOT/bin/e15-driver")" "1/sealed-driver"
  rm -f "$TROOT"/bin/.stamp-* "$TROOT"/bin/e15-driver*
  check "driver guard: a fresh rig (no binary, no stamp) builds e15-driver as before" \
    "$(dblk 1)/$(grep '^build' "$rec" | sed "s#$TROOT/##")" "0/build bin/e15-driver"
  rm -f "$TROOT"/bin/.stamp-go-driver-defer "$TROOT"/bin/e15-driver-defer
  chmod +x "$TROOT/bin/e15-driver"
  printf 'e15key' >"$TROOT/bin/.stamp-go-driver"
  check "driver guard: E16's first defer build (no e15-driver-defer yet) is unchanged" \
    "$(dblk 1)/$(grep '^build' "$rec" | sed "s#$TROOT/##")" "0/build bin/e15-driver-defer"
  rm -rf "${TROOT:?}/bin" "${TROOT:?}/logs"
  check "driver guard: the rig README bring-up step names E15_ACK_DRIVER_REBUILD" \
    "$(grep -c 'E15_ACK_DRIVER_REBUILD' "$RIG/../../e17-lease/rig/README.md")" "1"
}
test_pr34_sealed_rung_has_no_worker_bin_errors
test_pr34_e17a_arms_refused_under_e17b
test_pr34_sealed_driver_rebuild_guard

# --- E17c Task 2: ship-300-nd, the shipped lease without the idle page-cache drop (E17C=1 only) ---------------------
printf 'E17B_MOCA_PIN=%s\nE17C_MOCA_PIN=%s\n' "$E17B_FIXPIN" "$E17C_FIXPIN" >"$TMP/e17c-rung-pins.sh"
t17n() { t17m "$1" 1 "$2" E17C=1 E15_TEST_PINS="$TMP/e17c-rung-pins.sh" "${@:3}"; } # PROFILE EXPR [VAR=val ...]: E17C=1
test_ship_nd_arm_known_under_e17c_only() {
  local isarm='e15_is_arm ship-300-nd && echo yes || echo no'
  check "ship-300-nd: known on fresh-metal under E17C=1; not under E17B=1 alone, E17B unset, or on aws-prelim" \
    "$(t17n fresh-metal "$isarm")/$(t17m fresh-metal 1 "$isarm")/$(t17m fresh-metal unset "$isarm")/$(t17n aws-prelim "$isarm")" "yes/no/no/no"
  check "ship-300-nd: E15_ARMS under E17C=1 appends it after the E17b ship arms" \
    "$(t17n fresh-metal 'echo ${E15_ARMS[*]}')" "sbx resident-inf resident-300 control lease-30 lease-120 ship-30 ship-120 ship-300 ship-300-nd"
  check "ship-300-nd: the points the ship arms run (default, smoke, pycache*) list it under E17C=1; squeeze does not" \
    "$(t17n fresh-metal 'for p in default smoke pycache pycache-low pycache-d64 pycache-d768 squeeze squeeze-256 lowduty mem512; do e15_point $p; case " $E15_P_ARMS " in *" ship-300-nd "*) printf "%s " $p ;; esac; done')" \
    "default smoke pycache pycache-low pycache-d64 pycache-d768 "
  check "ship-300-nd: no point lists it under E17B=1 alone" \
    "$(t17m fresh-metal 1 'for p in default smoke pycache pycache-low pycache-d64 pycache-d768 squeeze; do e15_point $p; case " $E15_P_ARMS " in *" ship-300-nd "*) printf "%s " $p ;; esac; done')" ""
  check "ship-300-nd: the point signature is the same with or without it (the arm list is not in the settings)" \
    "$([ "$(t17n fresh-metal 'e15_point_sig pycache')" = "$(t17m fresh-metal 1 'e15_point_sig pycache')" ] && echo same || echo differ)" "same"
  check "ship-300-nd: the default warm-up is 1200 s (as ship-300)" "$(t17n fresh-metal 'e15_default_warmup ship-300-nd')" "1200"
}
test_ship_nd_worker_env() {
  local a="$TMP/nd-wenv-300" b="$TMP/nd-wenv-nd" c="$TMP/nd-wenv-300b"
  t17n fresh-metal 'worker_env ship-300 "'"$a"'"; worker_env ship-300-nd "'"$b"'"' >/dev/null
  t17m fresh-metal 1 'worker_env ship-300 "'"$c"'"' >/dev/null
  check "ship-300-nd worker_env: ship-300's plus SH_LEASE_CACHE_DROP_S=0, nothing else" \
    "$(diff "$a" "$b" | grep '^[<>]' | tr '\n' ' ')" "> SH_LEASE_CACHE_DROP_S=0 "
  check "ship-300 worker_env has no SH_LEASE_CACHE_DROP_S line (the worker's 30 s default stands), under E17C=1 and E17B=1" \
    "$(grep -c '^SH_LEASE_CACHE_DROP_S' "$a")/$(grep -c '^SH_LEASE_CACHE_DROP_S' "$c")" "0/0"
  check "ship-300-nd worker_env: refused under E17B=1 alone (E17C unset)" \
    "$(t17m fresh-metal 1 '(worker_env ship-300-nd "'"$b.x"'") >/dev/null 2>&1; echo $?')" "1"
}
test_ship_nd_is_a_lease_arm() {
  check "ship-300-nd: a lease arm under E17C=1 (e17b_lease_arm), not under E17B=1 alone or E17B unset" \
    "$(t17n fresh-metal 'e17b_lease_arm ship-300-nd && echo y || echo n')/$(t17m fresh-metal 1 'e17b_lease_arm ship-300-nd && echo y || echo n')/$(t17m fresh-metal unset 'e17b_lease_arm ship-300-nd && echo y || echo n')" "y/n/n"
  check "ship-300-nd: its token idle timeout is 300 s (ship-300's is still 300)" \
    "$(t17n fresh-metal 'e17b_idle_timeout_s ship-300-nd; e17b_idle_timeout_s ship-300' | tr '\n' ' ')" "300 300 "
  check "ship-300-nd: its worker is the stock -e17b build under E17C=1; refused under E17B=1 alone" \
    "$(t17n fresh-metal 'worker_bin ship-300-nd')/$(t17m fresh-metal 1 '(worker_bin ship-300-nd) >/dev/null 2>&1; echo $?')" "$TROOT/bin/microvm-worker-e17b/1"
  check "ship-300-nd: not an E17a arm (never refused as one)" "$(t17n fresh-metal 'e15_e17a_arm_refused ship-300-nd && echo refused || echo ok')" "ok"
}
crung() { # ARM [VAR=val ...]: srung under E17C=1 (the E17c pin's stamp and snapshot leaf in the harness root)
  local arm=$1 rc
  shift
  printf '%s\n' "$E17C_FIXPIN" >"$RS/state/go-stock-e17b"
  mkdir -p "$RS/snapshots/e17c-${E17C_FIXPIN:0:8}-1024"
  printf '{"hash": "hc", "guest_ram_mb": 1024, "features": ["lease-v1", "balloon-fpr-v1"]}\n' >"$RS/snapshots/e17c-${E17C_FIXPIN:0:8}-1024/manifest.json"
  srung "$arm" E17C=1 E15_TEST_PINS="$TMP/e17c-rung-pins.sh" "$@"
  rc=$?
  printf '%s\n' "$E17B_FIXPIN" >"$RS/state/go-stock-e17b"
  return $rc
}
test_ship_nd_rung_checks_cache_drop_banner() {
  crung ship-300-nd STUB_BANNER=dropoff
  check "cache-drop banner: ship-300-nd on lease_cache_drop=off runs (exit 0), the driver at --idle-timeout-s 300 in lease mode" \
    "$?/$(grep -c '^driver$' "$SORD")/$(grep -c -- '--lease-mode --token-key [^ ]* --idle-timeout-s 300 ' "$SARGS")" "0/1/1"
  check "cache-drop banner: ship-300-nd params.json records lease_cache_drop off, idle_timeout_s 300, its worker env and worker sha" \
    "$(sparams ship-300-nd lease_cache_drop)/$(sparams ship-300-nd idle_timeout_s)/$(sparams ship-300-nd worker_env | grep -c "'SH_LEASE_CACHE_DROP_S': '0'")/$(sparams ship-300-nd worker_bin_sha256 | grep -cE '^[0-9a-f]{64}$')" "off/300/1/1"
  check "cache-drop banner: the value is logged" "$(grep -c 'worker banner: lease_cache_drop=off' "$TMP/ship-rung.out")" "1"
  crung ship-300 STUB_BANNER=drop30
  check "cache-drop banner: ship-300 on lease_cache_drop=30s runs; params.json records it as printed" \
    "$?/$(grep -c '^driver$' "$SORD")/$(sparams ship-300 lease_cache_drop)" "0/1/30s"
  crung ship-300-nd STUB_BANNER=drop30
  check "cache-drop banner: ship-300-nd on lease_cache_drop=30s -> refused before the driver, naming the mismatch" \
    "$?/$(grep -c '^driver$' "$SORD")/$(grep -c 'lease_cache_drop=30s.*ship-300-nd needs off' "$TMP/ship-rung.out")" "1/0/1"
  crung ship-300 STUB_BANNER=dropoff
  check "cache-drop banner: ship-300 on lease_cache_drop=off -> refused before the driver, naming the mismatch" \
    "$?/$(grep -c '^driver$' "$SORD")/$(grep -c 'lease_cache_drop=off.*ship-300 needs the drop on' "$TMP/ship-rung.out")" "1/0/1"
  crung ship-300 STUB_BANNER=drop45
  check "cache-drop banner: ship-300 on lease_cache_drop=45s -> refused before the driver: E17c's ship-300 needs exactly 30s (M3)" \
    "$?/$(grep -c '^driver$' "$SORD")/$(grep -c 'lease_cache_drop=45s.*ship-300 needs exactly 30s' "$TMP/ship-rung.out")" "1/0/1"
  crung ship-300-nd STUB_BANNER=drop45
  check "cache-drop banner: ship-300-nd on lease_cache_drop=45s -> refused (it needs off), as before" \
    "$?/$(grep -c '^driver$' "$SORD")/$(grep -c 'lease_cache_drop=45s.*ship-300-nd needs off' "$TMP/ship-rung.out")" "1/0/1"
  local a
  for a in ship-300 ship-300-nd; do
    crung $a STUB_BANNER=on
    check "cache-drop banner: $a on a banner without lease_cache_drop (a worker before moca #974) -> refused before the driver" \
      "$?/$(grep -c '^driver$' "$SORD")/$(grep -c 'no lease_cache_drop= field' "$TMP/ship-rung.out")" "1/0/1"
  done
  crung ship-300-nd STUB_BANNER=dropoff
  check "cache-drop banner: the check comes before the relay attach probe" \
    "$(awk '/worker banner: lease_cache_drop=/{b=NR} /relay attach check passed/{p=NR} END{print (b && p && b < p) ? "before" : "after"}' "$TMP/ship-rung.out")" "before"
  crung sbx STUB_BANNER=drop30
  check "cache-drop banner: sbx under E17C=1 is not checked and its params.json has no lease_cache_drop" \
    "$?/$(grep -c '^driver$' "$SORD")/$(sparams sbx lease_cache_drop | grep -c KeyError)" "0/1/1"
  srung ship-300 STUB_BANNER=drop30
  check "cache-drop banner: with E17C unset a ship-300 rung is not checked and its params.json has no lease_cache_drop" \
    "$?/$(grep -c '^driver$' "$SORD")/$(sparams ship-300 lease_cache_drop | grep -c KeyError)" "0/1/1"
  srung ship-300 STUB_BANNER=on
  check "cache-drop banner: with E17C unset a banner without the field still runs (E17b unchanged)" "$?/$(grep -c '^driver$' "$SORD")" "0/1"
  check "cache-drop banner: params.json gets lease_cache_drop only from the E17C=1 ship branch (sbx and E17C unset unchanged)" \
    "$(grep -c 'lease_cache_drop' "$RIG/rung.sh" | awk '{print ($1 > 0) ? "present" : "absent"}')/$(grep -c 'if "\$lease_cache_drop_rec" == "1" else {}' "$RIG/rung.sh")" "present/1"
}
test_ship_nd_arm_known_under_e17c_only
test_ship_nd_worker_env
test_ship_nd_is_a_lease_arm
test_ship_nd_rung_checks_cache_drop_banner

# --- E17c Task 10 (SPEC §13.5, R45): the 256 MiB points' library and corpus; gate-256's rungs ----------------------
c256rung() { # ARM [VAR=val ...]: crung at pycache-d64 (the e17c 256 MiB leaf and the 256 inputs in the harness root)
  mkdir -p "$RS/snapshots/e17c-${E17C_FIXPIN:0:8}-256" "$RS/corpora/pycache-256" "$RS/template-pycache-d64"
  printf '{"hash": "hc256", "guest_ram_mb": 256, "features": ["lease-v1", "balloon-fpr-v1"]}\n' >"$RS/snapshots/e17c-${E17C_FIXPIN:0:8}-256/manifest.json"
  printf '{"session":"s","calls":[]}\n' >"$RS/corpora/pycache-256/corpus.jsonl"
  printf '{"table": {"mean_span_min": 30}}\n' >"$RS/corpora/pycache-256/corpus-report.json"
  cp "$RIG/../../e17-lease/workload/library-256.json" "$RS/src/e17/workload/library-256.json"
  head -c 4096 /dev/zero >"$RS/template-pycache-d64/workspace.img"
  SRUNG_POINT=pycache-d64 crung "$@"
}
d64params() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$RS/runs/pycache-d64/$1/N1/params.json" "$2" 2>&1; }
test_e17c_256_library() {
  local f='e15_point P && echo "$E15_P_CORPUS|${E15_P_LIBRARY#"$E15_ROOT"/}"' p out=""
  check "E17c 256: under E17C=1 pycache-d64 and squeeze-256 replay library-256.json and their own corpus, pycache-256" \
    "$(t17n fresh-metal "${f/P/pycache-d64}")/$(t17n fresh-metal "${f/P/squeeze-256}")" \
    "pycache-256|src/e17/workload/library-256.json/pycache-256|src/e17/workload/library-256.json"
  for p in pycache pycache-low pycache-d768 squeeze; do out+="$p=$(t17n fresh-metal "${f/P/$p}") "; done
  check "E17c 256: the 1024 MiB points keep the E17 library and their corpora under E17C=1" "$out" \
    "pycache=pycache|src/e17/workload/library.json pycache-low=pycache-low|src/e17/workload/library.json pycache-d768=pycache|src/e17/workload/library.json squeeze=pycache|src/e17/workload/library.json "
  check "E17c 256: with E17C unset pycache-d64 and squeeze-256 resolve as before (E17B=1; pycache-d64 with E17B unset too)" \
    "$(t17m fresh-metal 1 "${f/P/pycache-d64}")/$(t17m fresh-metal 1 "${f/P/squeeze-256}")/$(t17m fresh-metal unset "${f/P/pycache-d64}")" \
    "pycache|src/e17/workload/library.json/pycache|src/e17/workload/library.json/pycache|src/e17/workload/library.json"
  check "E17c 256: pycache-d64's point signature under E17C=1 is not E17b's (its library and corpus are in the settings)" \
    "$([ "$(t17n fresh-metal 'e15_point_sig pycache-d64')" != "$(t17m fresh-metal 1 'e15_point_sig pycache-d64')" ] && echo own)" "own"
  c256rung sbx E17B_GUEST_RAM_MB=256
  check "E17c 256: a pycache-d64 rung at 256 MiB runs with library-256.json (the driver's --library)" \
    "$?/$(grep -c -- "--library $RS/src/e17/workload/library-256.json " "$SARGS")/$(grep -c -- '--record-stdout py_shmem$' "$SARGS")" "0/1/1"
  check "E17c 256: params.json records which library the rung ran: its path, name and sha256" \
    "$(d64params sbx library)/$(d64params sbx library_name)/$([ "$(d64params sbx library_sha256)" = "$(sha_f "$RS/src/e17/workload/library-256.json")" ] && echo sha)/$([ "$(d64params sbx library_sha256)" != "$(sha_f "$RS/src/e17/workload/library.json")" ] && echo not-1024)" \
    "$RS/src/e17/workload/library-256.json/library-256.json/sha/not-1024"
  c256rung sbx
  check "E17c 256: under E17C=1 pycache-d64 is refused at 1024 MiB (exit 2, nothing started): its library is the 256 MiB one" \
    "$?/$(grep -c . "$SSYS")/$(grep -c 'POINT pycache-d64 runs at E17B_GUEST_RAM_MB=256 under E17C=1' "$TMP/ship-rung.out")" "2/0/1"
  SRUNG_POINT=pycache-d64 srung sbx
  check "E17c 256: with E17C unset pycache-d64 runs at 1024 MiB on library.json as before, and params has no library_name" \
    "$?/$(grep -c -- "--library $RS/src/e17/workload/library.json " "$SARGS")/$(d64params sbx library_name | grep -c KeyError)" "0/1/1"
  # gate-256's rungs: E17C_GATE_LIBRARY (the chain's only), with a probe corpus, at pycache-d64
  mkdir -p "$RS/probe"
  printf '{"session":"probe-py_analyze","calls":[]}\n' >"$RS/probe/corpus.jsonl"
  printf '{"table": {"mean_span_min": 6}}\n' >"$RS/probe/corpus-report.json"
  echo '{"classes": {}}' >"$RS/gate-lib.json"
  c256rung ship-300 E17B_GUEST_RAM_MB=256 STUB_BANNER=drop30 E17C_GATE_LIBRARY="$RS/gate-lib.json" E15_CORPUS_OVERRIDE="$RS/probe/corpus.jsonl"
  check "E17c gate rung: E17C_GATE_LIBRARY replaces the library and records py_analyze's stdout (the peak RSS line)" \
    "$?/$(grep -c -- "--corpus $RS/probe/corpus.jsonl --library $RS/gate-lib.json " "$SARGS")/$(grep -c -- '--record-stdout py_shmem,py_analyze$' "$SARGS")/$(d64params ship-300 library_name)" "0/1/1/gate-lib.json"
  local why
  for why in "point:SRUNG_POINT=pycache" "override:E15_CORPUS_OVERRIDE=" "e17c:E17C="; do
    case "$why" in
    point*) SRUNG_POINT=pycache crung sbx E17C_GATE_LIBRARY="$RS/gate-lib.json" E15_CORPUS_OVERRIDE="$RS/probe/corpus.jsonl" ;;
    override*) c256rung sbx E17B_GUEST_RAM_MB=256 E17C_GATE_LIBRARY="$RS/gate-lib.json" ;;
    e17c*) SRUNG_POINT=pycache-d64 srung sbx E17B_GUEST_RAM_MB=256 E17C_GATE_LIBRARY="$RS/gate-lib.json" E15_CORPUS_OVERRIDE="$RS/probe/corpus.jsonl" ;;
    esac
    printf '%s=%s:%s:%s ' "${why%%:*}" "$?" "$(grep -c . "$SSYS")" "$(grep -c 'E17C_GATE_LIBRARY is gate-256' "$TMP/ship-rung.out")"
  done >"$TMP/gl.out"
  check "E17c gate rung: E17C_GATE_LIBRARY is refused (exit 2, nothing started) at another point, without a probe corpus, or with E17C unset" \
    "$(cat "$TMP/gl.out")" "point=2:0:1 override=2:0:1 e17c=2:0:1 "
}
test_e17c_256_library
check "ship-300-nd: record.py judges its footprint drift as the other lease arms (RESIDENT)" \
  "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import record; print("ship-300-nd" in record.RESIDENT)' "$RIG/../analysis" 2>&1)" "True"

# --- E17d Task 2 (spec §14.2): the ship-300-l2 arm, points pycache-l2 and squeeze-l2, the per-rung lease mode --------
printf 'E17B_MOCA_PIN=%s\nE17C_MOCA_PIN=%s\nE17D_MOCA_PIN=%s\n' "$E17B_FIXPIN" "$E17C_FIXPIN" "$E17D_FIXPIN" >"$TMP/e17d-rung-pins.sh"
t17o() { t17m "$1" 1 "$2" E17D=1 E15_TEST_PINS="$TMP/e17d-rung-pins.sh" "${@:3}"; } # PROFILE EXPR [VAR=val ...]: E17D=1
test_l2_arm_known_under_e17d_only() {
  local isarm='e15_is_arm ship-300-l2 && echo yes || echo no'
  check "ship-300-l2: known on fresh-metal under E17D=1; not under E17C=1 alone, E17B=1 alone, E17B unset, or on aws-prelim" \
    "$(t17o fresh-metal "$isarm")/$(t17n fresh-metal "$isarm")/$(t17m fresh-metal 1 "$isarm")/$(t17m fresh-metal unset "$isarm")/$(t17o aws-prelim "$isarm")" "yes/no/no/no/no"
  check "ship-300-l2: E15_ARMS under E17D=1 appends it after E17c's arms" \
    "$(t17o fresh-metal 'echo ${E15_ARMS[*]}')" "sbx resident-inf resident-300 control lease-30 lease-120 ship-30 ship-120 ship-300 ship-300-nd ship-300-l2"
  check "ship-300-l2: points pycache-l2 (sbx ship-300 ship-300-l2) and squeeze-l2 (ship-300 ship-300-l2) under E17D=1" \
    "$(t17o fresh-metal 'e15_point_arms pycache-l2')/$(t17o fresh-metal 'e15_point_arms squeeze-l2')" "sbx ship-300 ship-300-l2/ship-300 ship-300-l2"
  check "ship-300-l2: no other point lists it under E17D=1" \
    "$(t17o fresh-metal 'for p in default smoke pycache pycache-low pycache-d64 pycache-d768 squeeze squeeze-256 lowduty mem512; do e15_point $p; case " $E15_P_ARMS " in *" ship-300-l2 "*) printf "%s " $p ;; esac; done')" ""
  check "pycache-l2 and squeeze-l2: unknown with E17D unset (E17C=1, E17B=1, unset) and on aws-prelim" \
    "$(for e in t17n 't17m fresh-metal 1' 't17m fresh-metal unset'; do case $e in t17n) t17n fresh-metal 'e15_point pycache-l2 && echo y || echo n; e15_point squeeze-l2 && echo y || echo n' ;; *) $e 'e15_point pycache-l2 && echo y || echo n; e15_point squeeze-l2 && echo y || echo n' ;; esac; done | tr '\n' ' ')$(t17o aws-prelim 'e15_point pycache-l2 && echo y || echo n')" "n n n n n n n"
  local f='e15_point P && echo "$E15_P_CORPUS|${E15_P_LIBRARY#"$E15_ROOT"/}|${E15_P_TEMPLATE#"$E15_ROOT"/}|$E15_P_IMAGE_MB|$E15_P_DATASET_MIB|$E15_P_FALLBACK|$E15_P_PROBE_CAP_MS"'
  check "pycache-l2: corpus pycache-l2, the E17 library, pycache's D=256 template, 1536 MiB, no fallback, the 120 s probe cap" \
    "$(t17o fresh-metal "${f/P/pycache-l2}")" "pycache-l2|src/e17/workload/library.json|template-pycache-d256/workspace.img|1536|256|0|120000"
  check "squeeze-l2: pycache-l2's workload; a squeeze point (e15_is_squeeze)" \
    "$(t17o fresh-metal "${f/P/squeeze-l2}")/$(t17o fresh-metal 'e15_is_squeeze squeeze-l2 && echo squeeze')" "pycache-l2|src/e17/workload/library.json|template-pycache-d256/workspace.img|1536|256|0|120000/squeeze"
  check "pycache-l2, squeeze-l2 and pycache have three point signatures" \
    "$(t17o fresh-metal 'for p in pycache pycache-l2 squeeze-l2; do e15_point_sig $p; done' | sort -u | wc -l | tr -d ' ')" "3"
  check "ship-300-l2: the default warm-up is 1200 s (as ship-300)" "$(t17o fresh-metal 'e15_default_warmup ship-300-l2')" "1200"
}
test_l2_worker_env_and_flags() {
  local a="$TMP/l2-wenv-300" b="$TMP/l2-wenv-l2"
  t17o fresh-metal 'worker_env ship-300 "'"$a"'"; worker_env ship-300-l2 "'"$b"'"' >/dev/null
  check "ship-300-l2 worker_env: exactly ship-300's (SH_LEASE_CACHE_DROP_S and SH_LEASE_MAX_PROCESSES at the defaults)" \
    "$(diff "$a" "$b" >/dev/null && echo same)/$(grep -c '^SH_LEASE_CACHE_DROP_S\|^SH_LEASE_MAX_PROCESSES' "$b")" "same/0"
  check "ship-300-l2 worker_env: refused with E17D unset (E17C=1)" \
    "$(t17n fresh-metal '(worker_env ship-300-l2 "'"$b.x"'") >/dev/null 2>&1; echo $?')" "1"
  check "ship-300-l2: a lease arm under E17D=1 only; its token idle timeout is 300 s; the stock -e17b worker" \
    "$(t17o fresh-metal 'e17b_lease_arm ship-300-l2 && echo y || echo n')/$(t17n fresh-metal 'e17b_lease_arm ship-300-l2 && echo y || echo n')/$(t17o fresh-metal 'e17b_idle_timeout_s ship-300-l2')/$(t17o fresh-metal 'worker_bin ship-300-l2')/$(t17n fresh-metal '(worker_bin ship-300-l2) >/dev/null 2>&1; echo $?')" \
    "y/n/300/$TROOT/bin/microvm-worker-e17b/1"
  check "e17d driver flags: ship-300-l2 mints lease+processes with the restart rule; the level-1 arms lease; sbx none" \
    "$(t17o fresh-metal 'for a in ship-300-l2 ship-300 ship-300-nd sbx; do printf "%s=[%s] " $a "$(e17d_lease_flags $a)"; done')" \
    "ship-300-l2=[--lease-mode=lease+processes --l2-restart] ship-300=[--lease-mode=lease] ship-300-nd=[--lease-mode=lease] sbx=[] "
  check "e17d library: ship-300-l2 replays library-l2.json, every other arm the point's library" \
    "$(t17o fresh-metal 'e17d_arm_library ship-300-l2 /x/library.json; e17d_arm_library ship-300 /x/library.json; e17d_arm_library sbx /x/library.json' | sed "s#$TROOT#<ROOT>#" | tr '\n' ' ')" \
    "<ROOT>/src/e17/workload/library-l2.json /x/library.json /x/library.json "
  check "e17d lease mode: the mode each arm runs (params.json's lease_mode)" \
    "$(t17o fresh-metal 'for a in ship-300-l2 ship-300 sbx; do e17d_lease_mode $a; done' | tr '\n' ' ')" "lease+processes lease per-exec "
}
drung() { # ARM [VAR=val ...]: srung under E17D=1 at point pycache-l2 (the E17d pin's stamp, leaf and inputs in the harness root)
  local arm=$1 rc feats=${DRUNG_FEATS:-'"lease-v1", "balloon-fpr-v1", "lease-processes-v1"'}
  shift
  printf '%s\n' "$E17D_FIXPIN" >"$RS/state/go-stock-e17b"
  mkdir -p "$RS/snapshots/e17d-${E17D_FIXPIN:0:8}-1024" "$RS/corpora/pycache-l2" "$RS/template-pycache-d256" "$RS/src/e17/workload"
  printf '{"hash": "hd", "guest_ram_mb": 1024, "features": [%s]}\n' "$feats" >"$RS/snapshots/e17d-${E17D_FIXPIN:0:8}-1024/manifest.json"
  printf '{"session":"s","calls":[]}\n' >"$RS/corpora/pycache-l2/corpus.jsonl"
  printf '{"table": {"mean_span_min": 30}}\n' >"$RS/corpora/pycache-l2/corpus-report.json"
  cp "$RIG/../../e17-lease/workload/library.json" "$RIG/../../e17-lease/workload/library-l2.json" "$RS/src/e17/workload/"
  head -c 4096 /dev/zero >"$RS/template-pycache-d256/workspace.img"
  SRUNG_POINT=${SRUNG_POINT:-pycache-l2} srung "$arm" E17D=1 E15_TEST_PINS="$TMP/e17d-rung-pins.sh" "$@"
  rc=$?
  printf '%s\n' "$E17B_FIXPIN" >"$RS/state/go-stock-e17b"
  return $rc
}
l2params() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$RS/runs/pycache-l2/$1/N1/params.json" "$2" 2>&1; }
test_l2_rung() {
  drung ship-300-l2 STUB_BANNER=drop30
  check "ship-300-l2 rung: runs (exit 0) with library-l2.json and --lease-mode=lease+processes ... --l2-restart" \
    "$?/$(grep -c -- "--library $RS/src/e17/workload/library-l2.json " "$SARGS")/$(grep -c -- '--lease-mode=lease+processes --l2-restart --token-key [^ ]* --idle-timeout-s 300 ' "$SARGS")" "0/1/1"
  check "ship-300-l2 rung: params.json records the mode, the restart rule, the idle timeout, the library, lease-processes-v1 and the leaf" \
    "$(l2params ship-300-l2 lease_mode)/$(l2params ship-300-l2 l2_restart)/$(l2params ship-300-l2 idle_timeout_s)/$(l2params ship-300-l2 library_name)/$(l2params ship-300-l2 snapshot_lease_processes)/$(l2params ship-300-l2 snapshot_image)/$(l2params ship-300-l2 moca_commit)/$(l2params ship-300-l2 snapshot_hash)" \
    "lease+processes/True/300/library-l2.json/True/e17d-${E17D_FIXPIN:0:8}-1024/$E17D_FIXPIN/hd"
  drung ship-300 STUB_BANNER=drop30
  check "ship-300 under E17D=1: library.json and --lease-mode=lease, no restart rule; params lease_mode lease" \
    "$?/$(grep -c -- "--library $RS/src/e17/workload/library.json " "$SARGS")/$(grep -c -- '--lease-mode=lease --token-key ' "$SARGS")/$(grep -c -- '--l2-restart' "$SARGS")/$(l2params ship-300 lease_mode)/$(l2params ship-300 l2_restart)" "0/1/1/0/lease/False"
  drung sbx STUB_BANNER=drop30
  check "sbx under E17D=1: no lease flag; params lease_mode per-exec, the same leaf" \
    "$?/$(grep -c -- '--lease-mode\|--l2-restart' "$SARGS")/$(l2params sbx lease_mode)/$(l2params sbx snapshot_image)" "0/0/per-exec/e17d-${E17D_FIXPIN:0:8}-1024"
  drung ship-300-l2 STUB_BANNER=dropoff
  check "ship-300-l2 rung: a banner with lease_cache_drop=off is refused before the driver (it needs the default 30s)" \
    "$?/$(grep -c '^driver$' "$SORD")/$(grep -c 'ship-300-l2 needs the drop on' "$TMP/ship-rung.out")" "1/0/1"
  drung ship-300-l2 STUB_BANNER=drop45
  check "ship-300-l2 rung: lease_cache_drop=45s is refused too (exactly 30s, as ship-300)" \
    "$?/$(grep -c '^driver$' "$SORD")/$(grep -c 'ship-300-l2 needs exactly 30s' "$TMP/ship-rung.out")" "1/0/1"
  local a
  for a in ship-300-l2 sbx; do
    DRUNG_FEATS='"lease-v1", "balloon-fpr-v1"' drung "$a" STUB_BANNER=drop30
    check "e17d snapshot: $a on a leaf without lease-processes-v1 is refused before any worker starts, naming the feature" \
      "$?/$(grep -c '^worker-start\|^driver$' "$SORD")/$(grep -c 'does not advertise lease-processes-v1' "$TMP/ship-rung.out")" "1/0/1"
  done
  SRUNG_POINT=pycache drung ship-300-l2 STUB_BANNER=drop30
  check "ship-300-l2 at a point that does not list it (pycache) is refused (exit 2)" "$?" "2"
  srung ship-300 STUB_BANNER=on
  check "with E17D unset a ship-300 rung still passes the bare --lease-mode (E17b and E17c unchanged)" \
    "$?/$(grep -c -- '--lease-mode --token-key ' "$SARGS")/$(sparams ship-300 lease_mode | grep -c KeyError)" "0/1/1"
}
test_l2_arm_known_under_e17d_only
test_l2_worker_env_and_flags
test_l2_rung
check "ship-300-l2: record.py judges its footprint drift as the other lease arms (RESIDENT)" \
  "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import record; print("ship-300-l2" in record.RESIDENT)' "$RIG/../analysis" 2>&1)" "True"
rm -rf "$RS" "$RSS"
echo
if [ "$fails" -eq 0 ]; then
  echo "rig.test.sh: all checks passed"
else
  echo "rig.test.sh: $fails check(s) FAILED"
fi
[ "$fails" -eq 0 ]
