#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted $ here are stub bodies
# experiments/e17-lease/rig/tests/probes.test.sh
#
# Rig-free tests for the spec §7.4 probes (PLAN-E17B Task 11): probe-overhead.sh (the level-1 overhead: baseline.sh for
# arm ship-300 at the default point, then overhead_compare.py) and ownwalk.sh (the ownership walk: its plan, the
# workspace sizing and the driver command; the host steps are the rig's). Both run from a staged copy under a scratch
# root (/srv/e15/src layout); baseline.sh is a stub that logs its call and writes a baseline.json; systemctl and sudo
# are stubs.
#
# Run: bash experiments/e17-lease/rig/tests/probes.test.sh      (SHELLCHECK=/path/to/shellcheck if not on PATH)
set -uo pipefail

RIG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
E17="$RIG/.."
E15RIG="$RIG/../../e15-session-density/rig"
fails=0
check() {
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1 (want '$3', got '$2')"
    fails=$((fails + 1))
  fi
}

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

# --- syntax and lint -------------------------------------------------------------------------
SC="${SHELLCHECK:-$(command -v shellcheck || true)}"
for s in probe-overhead.sh ownwalk.sh tests/probes.test.sh ../workload/build_tree.sh; do
  if [ ! -f "$RIG/$s" ]; then
    check "$s exists" "missing" "present"
    continue
  fi
  bash -n "$RIG/$s" 2>"$TMP/n.out"
  check "bash -n $s" "$([ -s "$TMP/n.out" ] && echo FAIL || echo clean)" "clean"
  if [ -n "$SC" ]; then
    "$SC" -x "$RIG/$s" >"$TMP/sc.out" 2>&1
    check "shellcheck $s" "$([ -s "$TMP/sc.out" ] && echo FAIL || echo clean)" "clean"
    [ -s "$TMP/sc.out" ] && sed 's/^/    /' "$TMP/sc.out" | head -20
  else
    check "shellcheck available" "missing" "present"
  fi
done

# --- fixture: a staged copy under a scratch root -------------------------------------------------------------------
T="$TMP/e15-rig-test.probes"
PIN=1111111111111111111111111111111111111111
mkdir -p "$T/src/e15" "$T/src/e17" "$T/state" "$T/runs" "$TMP/stub"
cp -R "$E15RIG" "$T/src/e15/rig"
cp -R "$RIG" "$T/src/e17/rig"
cp -R "$E17/analysis" "$T/src/e17/analysis"
cp -R "$E17/workload" "$T/src/e17/workload"
printf 'E17B_MOCA_PIN=%s\n' "$PIN" >"$TMP/pins.sh"
printf '%s\n' "$PIN" >"$T/state/go-stock-e17b"
echo fresh-metal >"$T/state/host_profile"
CLOG="$TMP/calls.log"
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/stub/systemctl"
printf '#!/usr/bin/env bash\n[ "$1" = -n ] && shift\nexec "$@"\n' >"$TMP/stub/sudo"
chmod +x "$TMP/stub/systemctl" "$TMP/stub/sudo"
# baseline.sh stub: logs "baseline ARGS e17b=<E17B>" and writes the arm's N1/baseline.json (class medians STUB_MEDIANS)
cat >"$TMP/stub-baseline.sh" <<SH
#!/usr/bin/env bash
echo "baseline \$* e17b=\${E17B:-unset}" >>"$CLOG"
# as baseline.sh:45 does: the arm's N1/baseline.json is removed before the first rung
rm -f "\$E15_ROOT/runs/\$1/\$2/N1/baseline.json"
[ -z "\${STUB_FAIL:-}" ] || exit 1
mkdir -p "\$E15_ROOT/runs/\$1/\$2/N1"
printf '{"class_medians": %s, "corpus_sha256": "c", "library_sha256": "l", "overhead_ms": 3.0, "global_median_ms": 2.0, "probe": "%s"}\n' \
  "\${STUB_MEDIANS:-{\"build\": 40.0, \"read\": 12.0\}}" "\$2" >"\$E15_ROOT/runs/\$1/\$2/N1/baseline.json"
SH
chmod +x "$TMP/stub-baseline.sh"
REF="$TMP/ref.json"
printf '{"class_medians": {"build": -34.0, "read": -13.0}, "corpus_sha256": "c", "library_sha256": "l", "overhead_ms": -26.0, "global_median_ms": -34.0}\n' >"$REF"

probe() { # [VAR=val ...] -- ARGS: the staged probe-overhead.sh; rc echoed, output in $TMP/p.out
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    envs+=("$1")
    shift
  done
  [ "${1:-}" != -- ] || shift
  : >"$CLOG"
  env E17B=1 E15_ROOT="$T" E15_TEST_ROOT="$T" E15_TEST_PINS="$TMP/pins.sh" E15_MANIFEST="$TMP/m.md" PATH="$TMP/stub:$PATH" \
    E17B_TEST_HARNESS=1 E17B_BASELINE="$TMP/stub-baseline.sh" ${envs[@]+"${envs[@]}"} bash "$T/src/e17/rig/probe-overhead.sh" "$@" >"$TMP/p.out" 2>&1
  echo $?
}
N1="$T/runs/default/ship-300/N1"

test_probe_overhead_uses_ship_arm() {
  rm -rf "$T/runs" && mkdir -p "$T/runs"
  check "probe-overhead: baseline.sh for arm ship-300 at the default point (the default probe classes), under E17B=1" \
    "$(probe)/$(cat "$CLOG")" "0/baseline default ship-300 e17b=1"
  check "probe-overhead: the probe's baseline is kept as N1/baseline.probe-overhead.json" \
    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["probe"])' "$N1/baseline.probe-overhead.json")" "ship-300"
  check "probe-overhead: no reference staged -> no overhead.json, the log names the laptop command" \
    "$([ -e "$N1/overhead.json" ] && echo written || echo none)/$(grep -c 'overhead_compare.py <that copy>' "$TMP/p.out")" "none/1"
  check "probe-overhead: extra arguments are a usage error, nothing run" "$(probe -- default)/$(grep -c . "$CLOG")" "2/0"
  check "probe-overhead (PR #34 fix round 2): E17B_BASELINE outside the test harness is refused, named, nothing run" \
    "$(probe E17B_TEST_HARNESS= --)/$(grep -c 'REFUSED: .*E17B_BASELINE' "$TMP/p.out")/$(grep -c . "$CLOG")" "1/1/0"
  check "probe-overhead: refused without E17B=1, nothing run" \
    "$(env -u E17B E15_ROOT="$T" E15_TEST_ROOT="$T" E15_TEST_PINS="$TMP/pins.sh" PATH="$TMP/stub:$PATH" E17B_BASELINE="$TMP/stub-baseline.sh" \
      bash "$T/src/e17/rig/probe-overhead.sh" >"$TMP/p.out" 2>&1; echo $?)/$(grep -c 'E17B=1 is required' "$TMP/p.out")/$(grep -c . "$CLOG")" "1/1/0"
}
test_probe_overhead_keeps_the_calibration() {
  rm -rf "$T/runs" && mkdir -p "$N1"
  printf '{"class_medians": {"build": 1.0}, "probe": "calibration"}\n' >"$N1/baseline.json"
  check "probe-overhead: the calibration baseline the ladder read is back at N1/baseline.json, nothing else left behind" \
    "$(probe)/$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["probe"])' "$N1/baseline.json")/$(find "$N1" -name 'baseline.before-*' | wc -l | tr -d ' ')" \
    "0/calibration/0"
  check "probe-overhead: with a staged reference the per-class difference goes to N1/overhead.json" \
    "$(probe E17B_OVERHEAD_REF="$REF")/$(python3 -c 'import json,sys; j=json.load(open(sys.argv[1])); print(j["classes"]["build"]["added_ms"], j["classes"]["read"]["added_ms"], j["comparable"])' "$N1/overhead.json")" \
    "0/74.0 25.0 True"
  check "probe-overhead: a missing staged reference is a rig error" "$(probe E17B_OVERHEAD_REF="$TMP/nowhere.json")" "1"
  printf '{"class_medians": {"build": 1.0}, "probe": "calibration"}\n' >"$N1/baseline.json"
  check "probe-overhead: a failed baseline.sh (which removed N1/baseline.json) fails the probe and puts the calibration baseline back" \
    "$(probe STUB_FAIL=1)/$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["probe"])' "$N1/baseline.json" 2>&1)/$(find "$N1" -name 'baseline.before-*' | wc -l | tr -d ' ')" \
    "1/calibration/0"
  rm -f "$N1/baseline.json"
  check "probe-overhead: a failed probe with no calibration baseline leaves none" \
    "$(probe STUB_FAIL=1)/$([ -e "$N1/baseline.json" ] && echo present || echo absent)" "1/absent"
}
test_probe_overhead_rerun_keeps_the_earlier_probe() {
  rm -rf "$T/runs" && mkdir -p "$N1"
  printf '{"class_medians": {"build": 1.0}, "probe": "calibration"}\n' >"$N1/baseline.json"
  probe >/dev/null
  probe STUB_MEDIANS='{"build": 99.0}' >/dev/null
  check "probe-overhead: a re-run moves the earlier baseline.probe-overhead.json aside with a timestamp, never over it" \
    "$(find "$N1" -name 'baseline.probe-overhead.prev-*.json' | wc -l | tr -d ' ')/$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["class_medians"]["build"])' "$N1/baseline.probe-overhead.json")/$(python3 -c 'import json,sys,glob; print(json.load(open(glob.glob(sys.argv[1] + "/baseline.probe-overhead.prev-*.json")[0]))["class_medians"]["build"])' "$N1")" \
    "1/99.0/40.0"
}

own() { # ARGS: the staged ownwalk.sh; rc echoed, output in $TMP/o.out
  env E17B=1 E15_ROOT="$T" E15_TEST_ROOT="$T" E15_TEST_PINS="$TMP/pins.sh" E15_MANIFEST="$TMP/m.md" PATH="$TMP/stub:$PATH" \
    bash "$T/src/e17/rig/ownwalk.sh" "$@" >"$TMP/o.out" 2>&1
  echo $?
}
plan_field() { awk -v k="$1" '$1 == k":" {sub(/^[^:]*: /, ""); print; exit}' "$TMP/o.out"; }

test_ownwalk_plan() {
  local f
  for f in 10000 100000 500000; do
    printf '%s:%s:%s:%s ' "$f" "$(own --plan "$f")" "$(plan_field inodes)" "$(plan_field image_mb)"
  done >"$TMP/plan.out"
  check "ownwalk: --plan at each size (inodes = files + dirs + 8192 slack; image >= 1024 MiB and >= 2 blocks per inode)" \
    "$(cat "$TMP/plan.out")" "10000:0:18202:1024 100000:0:108292:1024 500000:0:508692:4096 "
  own --plan 100000 >/dev/null
  local run
  run=$(plan_field run_id)
  check "ownwalk: the workspace keys are RUN-0..RUN-4, the driver's ownwalkKey names (one fresh key per repeat)" \
    "$(plan_field keys)" "$run-0 $run-1 $run-2 $run-3 $run-4"
  check "ownwalk: the run id names the size" "$(if [ "${run#ownwalk-F100000-}" != "$run" ]; then echo ok; else echo "$run"; fi)" "ok"
  check "ownwalk: the driver runs the ownwalk subcommand at arm ship-300's idle timeout, 5 repeats, build_tree.sh as the per-exec write" \
    "$(plan_field driver | grep -c -- "e15-driver-e17b ownwalk --files 100000 --repeats 5 --target 127.0.0.1:9644 --sandbox-id e15 --token-key $T/secrets/token-$run/token.key --token-iss e17b-driver --idle-timeout-s 300 --run-id $run --out $T/runs/ownwalk/ship-300/F100000 --build-script $T/src/e17/workload/build_tree.sh")" "1"
  check "ownwalk: the template is a new leaf under template-ownwalk, never the shared template" \
    "$(plan_field template)" "$T/template-ownwalk/F100000-1024.img"
  check "ownwalk: --plan touches nothing" "$([ -e "$T/secrets" ] || [ -e "$T/runs/ownwalk" ] || [ -e "$T/template-ownwalk" ] && echo touched || echo clean)" "clean"
  check "ownwalk: a size other than the three, or no size, is a usage error" "$(own --plan 12345)/$(own)/$(own 10000 100000)" "2/2/2"
  check "ownwalk: refused without E17B=1" \
    "$(env -u E17B E15_ROOT="$T" E15_TEST_ROOT="$T" E15_TEST_PINS="$TMP/pins.sh" PATH="$TMP/stub:$PATH" bash "$T/src/e17/rig/ownwalk.sh" --plan 10000 >"$TMP/o.out" 2>&1; echo $?)/$(grep -c 'E17B=1 is required' "$TMP/o.out")" "1/1"
}
test_ownwalk_host_steps() {
  local s="$RIG/ownwalk.sh"
  check "ownwalk: the workspaces and jail are wiped only after refuse_shared_paths, as rung.sh does" \
    "$(awk '/refuse_shared_paths "\$E15_WORKSPACES" "\$E15_JAIL"/ {g=NR} /-mindepth 1 -maxdepth 1 -exec rm -rf/ {w=NR} END {print (g && w > g) ? "guarded" : "unguarded"}' "$s")" "guarded"
  check "ownwalk: the template is formatted with the inode count and no lazy init, under a temp name, then moved into place" \
    "$(grep -c 'mkfs.ext4 -F -q -N "\$INODES" -E lazy_itable_init=0,lazy_journal_init=0' "$s")/$(grep -c 'mv -f "\$tmp_img" "\$TEMPLATE"' "$s")" "1/1"
  check "ownwalk: the worker is ship-300's at the template's image size, and the banner must say lease=on" \
    "$(grep -c 'start_worker "\$ARM" "\$DIR" "\$IMAGE_MB"' "$s")/$(grep -c '" lease=on "' "$s")" "1/1"
  check "ownwalk: the per-rung token key is minted by the -e17b driver and removed on every exit (EXIT trap)" \
    "$(grep -c 'mint-key --out "\$TOKEN_DIR"' "$s")/$(grep -c 'e17b_token_dir_remove "\$TOKEN_DIR"' "$s")/$(grep -c '^trap cleanup EXIT' "$s")" "1/1/1"
  check "ownwalk: shell values reach Python as argv/env only (every heredoc quoted, no \$ inside its source)" \
    "$(grep -c "<<PY" "$s")/$(awk "/<<'PY'/ {inpy=1; next} /^PY\$/ {inpy=0} inpy && /\\\$[A-Za-z{(]/ {n++} END {print n+0}" "$s")" "0/0"
  check "ownwalk: the header notes the relay's 30 min Exec deadline and the Task 12 smoke's 10k build time" \
    "$(grep -c "^#.*relay's own default Exec deadline" "$s")/$(grep -c "^#.*Task 12 smoke runs ownwalk.sh 10000" "$s")" "1/1"
  touch "$TMP/worker-up"
  printf '#!/usr/bin/env bash\ncase "$*" in *e15-worker.service*) [ -e "%s/worker-up" ] ;; *) exit 1 ;; esac\n' "$TMP" >"$TMP/stub/systemctl"
  check "ownwalk: a rung's worker running -> refused before any host change" \
    "$(own 10000)/$(grep -c 'refusing to preempt it' "$TMP/o.out")/$([ -e "$T/runs/ownwalk" ] && echo touched || echo clean)" "1/1/clean"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/stub/systemctl"
  rm -f "$TMP/worker-up"
}
test_ownwalk_500k_projection() {
  rm -rf "$T/runs/ownwalk"
  check "ownwalk: 500k with no smaller run: no projection, it runs" "$(own --plan 500000)/$(plan_field projected_build_s)/$(plan_field skip)" "0/none/no"
  mkdir -p "$T/runs/ownwalk/ship-300/F100000"
  printf '{"files": 100000, "runs": [{"build": {"ms": 250000}}, {"build": {"ms": 290000}}]}\n' >"$T/runs/ownwalk/ship-300/F100000/ownwalk.json"
  check "ownwalk: 500k projects its build from the largest smaller run's slowest build (290 s x 5 = 1450 s <= 25 min): runs" \
    "$(own --plan 500000)/$(plan_field projected_build_s)/$(plan_field skip)" "0/1450/no"
  printf '{"files": 100000, "runs": [{"build": {"ms": 310000}}]}\n' >"$T/runs/ownwalk/ship-300/F100000/ownwalk.json"
  check "ownwalk: a projection over 25 min (the relay's 30 min Exec deadline) skips 500k with a reason, exit 0, nothing touched" \
    "$(own 500000)/$(grep -c 'SKIP 500000: projected build 1550 s' "$TMP/o.out")/$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["reason"][:20])' "$T/runs/ownwalk/ship-300/F500000/skipped.json")/$([ -e "$T/secrets" ] || [ -e "$T/template-ownwalk" ] && echo touched || echo clean)" \
    "0/1/projected build 1550/clean"
  check "ownwalk: 10k and 100k are never projected" "$(own --plan 100000)/$(plan_field skip)" "0/no"
  rm -rf "$T/runs/ownwalk"
}
test_probe_overhead_uses_ship_arm
test_probe_overhead_keeps_the_calibration
test_probe_overhead_rerun_keeps_the_earlier_probe
test_ownwalk_plan
test_ownwalk_500k_projection
test_ownwalk_host_steps

echo
if [ "$fails" -eq 0 ]; then echo "probes.test.sh: all checks passed"; else echo "probes.test.sh: $fails FAILED"; fi
exit "$([ "$fails" -eq 0 ] && echo 0 || echo 1)"
