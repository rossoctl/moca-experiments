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
SCRIPTS=(lib.sh points.sh setup.sh teardown.sh rung.sh ladder.sh sample.sh baseline.sh classprobe.sh tests/rig.test.sh)
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
  check "ladder.json would read n1_overhead_ms from N1/baseline.json (rule text mentions B + 250)" "$(grep -c 'B + 250 ms' "$RIG/ladder.sh")/$(grep -c 'n1_overhead_ms' "$RIG/ladder.sh")" "2/1"
  rm -f "$TROOT/runs/default/sbx/N1/baseline.json"
  check "ladder: the rig error is recorded" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["rungs"][0]["rig_errors"])' "$TROOT/runs/default/sbx/ladder.json")" "['unseeded_sessions=2']"
  printf '1=%s\n1-k2=%s\n' '{"unseeded_sessions":2}' '{"unseeded_sessions":1}' >"$TMP/recs"
  ladder
  check "ladder: still unseeded with K doubled dies" "$?" "1"

  printf '1=%s\n1-repeat=%s\n8=%s\n' '{"holds":false,"holds_abs":false,"repeat_required":true,"unseeded_sessions":0}' "$ok" "$both_bad" >"$TMP/recs"
  E15_WARMUP_S=30 ladder
  check "ladder: repeat_required re-runs with warm-up doubled and the repeat counts" "$(lj n_max)/$(grep -c '^1-repeat k=1 w=60' "$TMP/lcalls")" "1/1"
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
  check "rung.sh K floor: max(16, formula)" "$(grep -c 'print(max(16, (int(math.ceil' "$RIG/rung.sh")" "1"
  kf=$(sed -n '/^K=\$(python3/p' "$RIG/rung.sh" | sed 's/^K=\$(//; s/)$//')
  # shellcheck disable=SC2001
  check "rung.sh K: short run gets 16" "$(eval "$(echo "$kf" | sed 's/"\$((WARMUP + WINDOW))" "\$span_min" "\$K_MULT"/"1500" "30" "1"/')")" "16"
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
  GOOD='class_medians={} global_median_ms=1 excess_p95_ms=2'
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
  check "rung.sh starts the worker with the point's image size" "$(grep -c 'start_worker "\$ARM" "\$DIR" "\$E15_P_IMAGE_MB"' "$RIG/rung.sh")" "1"
  check "rung.sh copies the point's template, not E15_TEMPLATE" "$(grep -c 'E15_TEMPLATE' "$RIG/rung.sh")/$(grep -c '"\$TEMPLATE" "\$RUN_ID"' "$RIG/rung.sh")" "0/1"
fi

# rung.sh at mem512: the default point's baseline is never accepted (same library and corpus hashes;
# the point signature keeps them apart)
if [ -f "$RIG/rung.sh" ] && [ -f "$RIG/points.sh" ]; then
  printf '#!/usr/bin/env bash\n[ "$1" = is-active ] && exit 0\nexit 0\n' >"$STUB/systemctl"
  rm -rf "$TROOT/runs"
  GOOD='class_medians={} global_median_ms=1 excess_p95_ms=2'
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
  check "sample.sh: disk_await_ms = 50 ms / 10 I/Os" "$(sed -n 2p "$OUTS" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["disk_await_ms"])')" "5.0"
  rm -f "$OUTS"
  E15_PROC="$FP" E15_DISK_DEV=nosuch E15_SLICE_DIR="$TMP/nocg" E15_STATS_URL=http://127.0.0.1:1/x \
    bash "$RIG/sample.sh" "$OUTS" "$(date +%s)" 2.5 >/dev/null 2>&1
  check "sample.sh: an unknown device gives samples, no disk_read_mbs" "$([ "$(grep -c . "$OUTS")" -ge 2 ] && echo n)/$(grep -c disk_read_mbs "$OUTS")" "n/0"
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

echo
if [ "$fails" -eq 0 ]; then
  echo "rig.test.sh: all checks passed"
else
  echo "rig.test.sh: $fails check(s) FAILED"
fi
[ "$fails" -eq 0 ]
