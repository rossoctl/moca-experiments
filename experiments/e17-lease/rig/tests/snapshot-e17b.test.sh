#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted $ here are bash -c bodies and stub bodies
# experiments/e17-lease/rig/tests/snapshot-e17b.test.sh
#
# Rig-free tests for snapshot-e17b.sh: the leaf-path guard, argument handling, the rm -rf helper and the
# feature assertion. No KVM, no root, no real build: sudo is a pass-through stub, and the host-bound steps
# (kernel fetch, rootfs tree, build-snapshot.sh) are replaced by shell functions after sourcing the script.
#
# Run: bash experiments/e17-lease/rig/tests/snapshot-e17b.test.sh      (SHELLCHECK=/path/to/shellcheck if not on PATH)
set -uo pipefail

RIG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
E15RIG="$RIG/../../e15-session-density/rig"
SCRIPT="$RIG/snapshot-e17b.sh"
fails=0
check() {
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1 (want '$3', got '$2')"
    fails=$((fails + 1))
  fi
}

TMP="$(cd "$(mktemp -d)" && pwd -P)" # physical: the guard compares realpaths (macOS /var is a symlink)
trap 'rm -rf "$TMP"' EXIT

# --- syntax and lint -------------------------------------------------------------------------
SC="${SHELLCHECK:-$(command -v shellcheck || true)}"
for s in snapshot-e17b.sh tests/snapshot-e17b.test.sh; do
  bash -n "$RIG/$s" 2>"$TMP/n.out"
  check "bash -n $s" "$([ -s "$TMP/n.out" ] && echo FAIL || echo clean)" "clean"
  if [ -n "$SC" ]; then
    "$SC" -x -P "$E15RIG" "$RIG/$s" >"$TMP/sc.out" 2>&1
    check "shellcheck $s" "$([ -s "$TMP/sc.out" ] && echo FAIL || echo clean)" "clean"
    [ -s "$TMP/sc.out" ] && sed 's/^/    /' "$TMP/sc.out" | head -20
  else
    check "shellcheck available" "missing" "present"
  fi
done

# --- fixture: a scratch root, a moca checkout at a known commit, a pass-through sudo -----------
TROOT="$TMP/e15-rig-test.root"
SNAP="$TROOT/snapshots"
MOCA="$TROOT/moca-e17b"
mkdir -p "$SNAP" "$TROOT/logs" "$MOCA"
git -C "$MOCA" init -q
# plumbing, not `git commit`: no hooks run (a global commit hook is noisy)
git -C "$MOCA" update-ref HEAD "$(GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t git -C "$MOCA" commit-tree -m fixture "$(git -C "$MOCA" hash-object -t tree -w /dev/null)")"
PIN=$(git -C "$MOCA" rev-parse HEAD)
P8=${PIN:0:8}
printf 'E17B_MOCA_PIN=%s\n' "$PIN" >"$TMP/pins.sh"
printf 'E17B_MOCA_PIN=%s\n' "1111111111111111111111111111111111111111" >"$TMP/pins-other.sh"
STUB="$TMP/stub"
mkdir -p "$STUB"
printf '#!/usr/bin/env bash\n[ "${1:-}" = -n ] && shift\nexec "$@"\n' >"$STUB/sudo"
chmod +x "$STUB/sudo"
# A sentinel that no case may touch.
mkdir -p "$SNAP/e15"
echo keep >"$SNAP/e15/manifest.json"
mkdir -p "$TMP/outside"

snapls() { (cd "$SNAP" && echo ./* | sed 's#\./##g'); }
# run_in BODY [ENV...]: BODY in a fresh bash with the E17b profile on the scratch root, script sourced.
run_in() {
  local body=$1
  shift
  env E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" E15_TEST_PINS="${PINS_FILE:-$TMP/pins.sh}" E15_HOST_PROFILE=fresh-metal E17B=1 \
    E15_MANIFEST="$TMP/m.md" PATH="$STUB:$PATH" "$@" bash -c 'source "$1"; '"$body" _ "$SCRIPT"
}
# gate LEAF RAM: does leaf_new_ok accept it?
gate() { run_in 'leaf_new_ok "$T_LEAF" "$T_RAM"' T_LEAF="$1" T_RAM="$2" >"$TMP/g.out" 2>&1 && echo accepted || echo refused; }

# --- 1. the leaf-path guard ------------------------------------------------------------------
for bad in "e15" "" "../x" "a/b" "e17b-$P8-1024/.." "e17b-$P8-512" "e17b-$P8-" "e17b-deadbeef-1024" "E17B-ABCDEF12-1024" \
  "e17b-${P8}0-1024" "e17b-${P8:0:7}-1024" "x-e17b-$P8-1024" "e17b-$P8-1024x" "$SNAP/e17b-$P8-1024" ".."; do
  check "rootfs --require is moca's tool list minus gh (E17B-R43: E15's benchmark image never shipped gh)" \
  "$(sed -n 's/^E17B_ROOTFS_REQUIRE="\(.*\)"$/\1/p' "$SCRIPT")/$(grep -c -- '--require "\$E17B_ROOTFS_REQUIRE"' "$SCRIPT")" \
  "bash git rg python3 base64 file ls cat/1"
check "guard refuses leaf '$bad'" "$(gate "$bad" 1024)" "refused"
done
check "guard refuses the right name with the wrong --ram-mb (1024 vs 256)" "$(gate "e17b-$P8-1024" 256)" "refused"
check "guard refuses the right name with the wrong --ram-mb (256 vs 1024)" "$(gate "e17b-$P8-256" 1024)" "refused"
check "guard refuses --ram-mb 512 even for a name that says 512" "$(gate "e17b-$P8-512" 512)" "refused"
check "guard accepts e17b-<pin8>-1024" "$(gate "e17b-$P8-1024" 1024)" "accepted"
check "guard accepts e17b-<pin8>-256" "$(gate "e17b-$P8-256" 256)" "accepted"
mkdir -p "$SNAP/e17b-$P8-1024"
check "guard refuses an existing leaf" "$(gate "e17b-$P8-1024" 1024)" "refused"
rmdir "$SNAP/e17b-$P8-1024"
ln -s "$TMP/outside" "$SNAP/e17b-$P8-256"
check "guard refuses a dangling/outside symlink leaf" "$(gate "e17b-$P8-256" 256)" "refused"
rm "$SNAP/e17b-$P8-256"
mv "$SNAP" "$TMP/snap-real"
ln -s "$TMP/snap-real" "$SNAP"
check "guard refuses a symlinked snapshots dir (escape)" "$(gate "e17b-$P8-1024" 1024)" "refused"
rm "$SNAP"
mv "$TMP/snap-real" "$SNAP"
check "guard accepts again once the snapshots dir is real" "$(gate "e17b-$P8-1024" 1024)" "accepted"
check "guard refuses a snapshots dir outside /srv/e15/snapshots" "$(run_in 'E15_SNAPDIR=$T_D; leaf_new_ok "$T_LEAF" 1024' T_D="$TMP/outside" T_LEAF="e17b-$P8-1024" >/dev/null 2>&1 && echo accepted || echo refused)" "refused"

# --- 2. E17B unset, bad arguments --------------------------------------------------------------
out=$(env -u E17B E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" PATH="$STUB:$PATH" bash "$SCRIPT" --ram-mb 1024 --leaf "e17b-$P8-1024" 2>&1)
rc=$?
check "E17B unset: dies at once, nonzero, names E17B=1" "$([ "$rc" != 0 ] && echo nonzero)/$(printf '%s' "$out" | grep -c 'E17B=1 is required')" "nonzero/1"
check "E17B unset: nothing created" "$(snapls)" "e15"
out=$(env E17B=0 E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" PATH="$STUB:$PATH" bash "$SCRIPT" --ram-mb 1024 --leaf "e17b-$P8-1024" 2>&1)
check "E17B=0 is not E17B=1" "$?/$(printf '%s' "$out" | grep -c 'E17B=1 is required')" "1/1"

main_rc() { run_in "$1" >"$TMP/main.out" 2>&1 && echo 0 || echo $?; }
main_rc_to() { # like main_rc, but a hang is a failure: 8 s watchdog
  (
    run_in "$1" >"$TMP/main.out" 2>&1 &
    p=$!
    (sleep 8; kill -9 "$p" 2>/dev/null) &
    w=$!
    wait "$p"
    r=$?
    kill "$w" 2>/dev/null
    echo "$r"
  )
}
check "--ram-mb with no value: fails fast, no hang" "$(main_rc_to 'main --ram-mb')" "1"
check "--leaf with no value: fails fast, no hang" "$(main_rc_to "main --ram-mb 1024 --leaf")" "1"
check "unknown argument refused" "$(main_rc 'main --bogus 1')" "1"
check "missing --leaf refused" "$(main_rc 'main --ram-mb 1024')" "1"
check "leaf RAM vs --ram-mb mismatch refused by main" "$(main_rc "main --ram-mb 256 --leaf e17b-$P8-1024")" "1"
check "leaf for another pin refused by main" "$(main_rc 'main --ram-mb 1024 --leaf e17b-deadbeef-1024')" "1"
check "leaf e15 refused by main, sentinel intact" "$(main_rc 'main --ram-mb 1024 --leaf e15')/$(cat "$SNAP/e15/manifest.json")" "1/keep"
check "checkout not at the pin refused" "$(PINS_FILE=$TMP/pins-other.sh main_rc 'main --ram-mb 1024 --leaf e17b-11111111-1024')" "1"
check "refused runs created no leaf" "$(snapls)" "e15"

# --- 3. the rm -rf helper --------------------------------------------------------------------
mkdir -p "$SNAP/e17b-$P8-1024/sub" "$TMP/victim"
echo x >"$TMP/victim/f"
rmcase() { run_in 'LEAF=$T_LEAF; RAM=$T_RAM; safe_rm_rf "$T_PATH"' T_LEAF="$1" T_RAM="$2" T_PATH="$3" >"$TMP/rm.out" 2>&1 && echo removed || echo refused; }
check "safe_rm_rf refuses an outside path" "$(rmcase "e17b-$P8-1024" 1024 "$TMP/victim")/$(ls "$TMP/victim")" "refused/f"
check "safe_rm_rf refuses the snapshots dir" "$(rmcase "e17b-$P8-1024" 1024 "$SNAP")/$(snapls)" "refused/e15 e17b-$P8-1024"
check "safe_rm_rf refuses e15 even if LEAF=e15" "$(rmcase e15 1024 "$SNAP/e15")/$(cat "$SNAP/e15/manifest.json")" "refused/keep"
check "safe_rm_rf refuses a path with .." "$(rmcase "e17b-$P8-1024" 1024 "$SNAP/e17b-$P8-1024/../e15")/$(cat "$SNAP/e15/manifest.json")" "refused/keep"
check "safe_rm_rf refuses another e17b leaf" "$(rmcase "e17b-$P8-1024" 1024 "$SNAP/e17b-$P8-256")" "refused"
check "safe_rm_rf refuses an empty path" "$(rmcase "e17b-$P8-1024" 1024 "")" "refused"
check "safe_rm_rf refuses an invalid LEAF/RAM pair" "$(rmcase "e17b-$P8-1024" 256 "$SNAP/e17b-$P8-1024")/$([ -d "$SNAP/e17b-$P8-1024" ] && echo there)" "refused/there"
check "safe_rm_rf refuses a leaf under a symlinked snapshots dir" "$(
  mv "$SNAP" "$TMP/snap-real"
  ln -s "$TMP/snap-real" "$SNAP"
  rmcase "e17b-$P8-1024" 1024 "$SNAP/e17b-$P8-1024"
  rm "$SNAP"
  mv "$TMP/snap-real" "$SNAP"
)/$([ -d "$SNAP/e17b-$P8-1024" ] && echo there)" "refused/there"
check "safe_rm_rf removes this run's leaf" "$(rmcase "e17b-$P8-1024" 1024 "$SNAP/e17b-$P8-1024")/$([ -e "$SNAP/e17b-$P8-1024" ] && echo there || echo gone)" "removed/gone"
check "safe_rm_rf left e15 and the victim alone" "$(cat "$SNAP/e15/manifest.json")/$(ls "$TMP/victim")" "keep/f"
check "the script has exactly one rm -rf (inside safe_rm_rf)" "$(grep -c 'rm -rf' "$SCRIPT")/$(grep -c 'sudo -n rm -rf -- "${p:?}"' "$SCRIPT")" "$(grep -c 'rm -rf' "$SCRIPT")/1"
check "the only executable rm -rf line is the helper's" "$(grep -v '^ *#' "$SCRIPT" | grep 'rm -rf' | grep -vc 'm_purge')" "1"

# --- 4. the build flow, host steps replaced ------------------------------------------------------
# FEATS is the features list the fake build-snapshot "produces"; FAIL=1 makes it die after creating a partial leaf.
FLOW='
prepare_kernel() { KERNEL=$E15_ROOT/kernel/k; }
prepare_tree() { mkdir -p "$1"; echo tree >"$1/marker"; }
run_build_snapshot() {
  mkdir -p "$2"
  [ "${FAIL:-}" != 1 ] || die "fake build-snapshot failure"
  printf "{\"hash\": \"h1\", \"guest_ram_mb\": %s, \"features\": [%s]}\n" "$RAM" "$FEATS" >"$2/manifest.json"
}
e15_path() { echo "$PATH"; }
'
flow() { run_in "$FLOW main --ram-mb $1 --leaf $2" FEATS="$3" FAIL="${4:-}" >"$TMP/flow.out" 2>&1 && echo 0 || echo $?; }
STAGE="$TROOT/rootfs-build-e17b"
L=e17b-$P8-1024
check "build with lease-v1 + balloon-fpr-v1 publishes" "$(flow 1024 "$L" '"lease-v1", "lease-processes-v1", "balloon-fpr-v1"')/$([ -f "$SNAP/$L/manifest.json" ] && echo published)" "0/published"
check "a successful build removes its stage dir" "$([ -e "$STAGE/$L" ] && echo left || echo clean)" "clean"
check "a successful build records a PURGE line for the leaf" "$(grep -c "PURGE: sudo -n rm -rf $SNAP/$L" "$TMP/m.md")" "1"
check "a successful build keeps the manifest copy in the logs" "$([ -s "$TROOT/logs/manifest-$L.json" ] && echo yes)" "yes"
check "an existing leaf is refused and left intact" "$(flow 1024 "$L" '"lease-v1", "balloon-fpr-v1"')/$([ -f "$SNAP/$L/manifest.json" ] && echo intact)" "1/intact"
check "the 256 leaf builds with guest_ram_mb 256" "$(flow 256 "e17b-$P8-256" '"balloon-fpr-v1", "lease-v1"')/$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["guest_ram_mb"])' "$SNAP/e17b-$P8-256/manifest.json")" "0/256"
rm -rf "${SNAP:?}/$L" "${SNAP:?}/e17b-$P8-256"
check "missing balloon-fpr-v1: fails, leaf removed" "$(flow 1024 "$L" '"lease-v1"')/$([ -e "$SNAP/$L" ] && echo left || echo removed)" "1/removed"
check "missing balloon-fpr-v1: names the missing feature" "$(grep -c 'manifest lacks: balloon-fpr-v1' "$TMP/flow.out")" "1"
check "missing balloon-fpr-v1: the evidence stays in the logs" "$([ -s "$TROOT/logs/manifest-$L.json" ] && echo kept)/$([ -e "$STAGE/$L" ] && echo left || echo clean)" "kept/clean"
check "missing lease-v1: fails, leaf removed" "$(flow 1024 "$L" '"balloon-fpr-v1"')/$([ -e "$SNAP/$L" ] && echo left || echo removed)" "1/removed"
check "no features at all: fails, leaf removed" "$(flow 1024 "$L" '')/$([ -e "$SNAP/$L" ] && echo left || echo removed)" "1/removed"
check "a failing build-snapshot leaves no partial leaf" "$(flow 1024 "$L" '' 1)/$([ -e "$SNAP/$L" ] && echo left || echo removed)/$([ -e "$STAGE/$L" ] && echo left || echo clean)" "1/removed/clean"
check "after all of it e15 is untouched and no other leaf exists" "$(snapls)/$(cat "$SNAP/e15/manifest.json")" "e15/keep"

# --- 5. the E17c profile (PLAN-E17C Task 4): E17C=1 implies E17B=1; leaves e17c-<E17C pin8>-{1024|256} only ----
# The E17c checkout (moca-e17c) is at the fixture commit; E17C_MOCA_PIN is that commit, E17B_MOCA_PIN another.
cp -R "$MOCA" "$TROOT/moca-e17c"
printf 'E17B_MOCA_PIN=%s\nE17C_MOCA_PIN=%s\n' 1111111111111111111111111111111111111111 "$PIN" >"$TMP/pins-c.sh"
printf 'E17B_MOCA_PIN=%s\nE17C_MOCA_PIN=%s\n' "$PIN" 2222222222222222222222222222222222222222 >"$TMP/pins-c-other.sh"
# run_c BODY [ENV...]: run_in, but E17C=1 with E17B unset (lib.sh implies E17B=1)
run_c() {
  local body=$1
  shift
  env -u E17B E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" E15_TEST_PINS="${PINS_FILE:-$TMP/pins-c.sh}" E15_HOST_PROFILE=fresh-metal E17C=1 \
    E15_MANIFEST="$TMP/m.md" PATH="$STUB:$PATH" "$@" bash -c 'source "$1"; '"$body" _ "$SCRIPT"
}
gate_c() { run_c 'leaf_new_ok "$T_LEAF" "$T_RAM"' T_LEAF="$1" T_RAM="$2" >"$TMP/g.out" 2>&1 && echo accepted || echo refused; }
check "E17C=1 alone (E17B unset) is not refused as 'E17B=1 is required'" \
  "$(run_c 'echo sourced' 2>&1 | grep -c 'is required')/$(run_c 'echo "$E17B"' 2>/dev/null)" "0/1"
check "E17C=1: the guard accepts e17c-<E17C pin8>-1024 and -256" "$(gate_c "e17c-$P8-1024" 1024)/$(gate_c "e17c-$P8-256" 256)" "accepted/accepted"
check "E17C=1: the guard refuses e17b-<pin8>-* leaves (E17b's), naming the e17c grammar" \
  "$(gate_c "e17b-$P8-1024" 1024)/$(grep -c 'is not e17c-<8 hex>-{1024|256}' "$TMP/g.out")/$(gate_c "e17b-$P8-256" 256)" "refused/1/refused"
check "E17C=1: the guard refuses an e17c leaf for the E17B pin, the wrong RAM, or a bad name" \
  "$(gate_c "e17c-11111111-1024" 1024)/$(gate_c "e17c-$P8-1024" 256)/$(gate_c "e17c-$P8-512" 512)/$(gate_c "e15" 1024)/$(gate_c "x-e17c-$P8-1024" 1024)" \
  "refused/refused/refused/refused/refused"
check "E17B=1 alone: the guard refuses e17c-* leaves (E17c's)" "$(gate "e17c-$P8-1024" 1024)/$(grep -c 'is not e17b-<8 hex>-{1024|256}' "$TMP/g.out")" "refused/1"
out=$(env -u E17B E17C=0 E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" PATH="$STUB:$PATH" bash "$SCRIPT" --ram-mb 1024 --leaf "e17c-$P8-1024" 2>&1)
check "E17C=0 with E17B unset is still refused (E17B=1 is required)" "$?/$(printf '%s' "$out" | grep -c 'E17B=1 is required')" "1/1"
flow_c() { run_c "$FLOW main --ram-mb $1 --leaf $2" FEATS="$3" >"$TMP/flow.out" 2>&1 && echo 0 || echo $?; }
LC=e17c-$P8-1024
check "E17C=1: a build publishes e17c-<E17C pin8>-1024 from the moca-e17c checkout" \
  "$(flow_c 1024 "$LC" '"lease-v1", "balloon-fpr-v1"')/$([ -f "$SNAP/$LC/manifest.json" ] && echo published)" "0/published"
check "E17C=1: main refuses an e17b leaf, nothing created" "$(run_c "$FLOW main --ram-mb 1024 --leaf e17b-$P8-1024" FEATS='"lease-v1", "balloon-fpr-v1"' >/dev/null 2>&1 && echo 0 || echo 1)/$([ -e "$SNAP/e17b-$P8-1024" ] && echo created || echo none)" "1/none"
check "E17C=1: a moca-e17c checkout not at E17C_MOCA_PIN is refused" \
  "$(PINS_FILE=$TMP/pins-c-other.sh run_c "$FLOW main --ram-mb 256 --leaf e17c-22222222-256" FEATS='"lease-v1", "balloon-fpr-v1"' >"$TMP/flow.out" 2>&1 && echo 0 || echo 1)/$(grep -c 'is not at E17C_MOCA_PIN' "$TMP/flow.out")" "1/1"
printf 'E17B_MOCA_PIN=%s\nE17C_MOCA_PIN=%s\n' "$PIN" 0000000000000000000000000000000000000000 >"$TMP/pins-c-zero.sh"
check "E17C=1: the placeholder E17C pin is refused (e17c_require_pin)" \
  "$(PINS_FILE=$TMP/pins-c-zero.sh run_c "$FLOW main --ram-mb 1024 --leaf e17c-00000000-1024" FEATS='"lease-v1", "balloon-fpr-v1"' >"$TMP/flow.out" 2>&1 && echo 0 || echo 1)/$(grep -c 'E17C_MOCA_PIN is still the placeholder' "$TMP/flow.out")" "1/1"
rm -rf "${SNAP:?}/$LC"
check "after the E17c cases e15 is untouched and no other leaf exists" "$(snapls)/$(cat "$SNAP/e15/manifest.json")" "e15/keep"

# --- 6. the E17d profile (PLAN-E17D Task 2): E17D=1 implies E17C=1; leaves e17d-<E17D pin8>-*, lease-processes-v1 --
cp -R "$MOCA" "$TROOT/moca-e17d"
printf 'E17B_MOCA_PIN=%s\nE17C_MOCA_PIN=%s\nE17D_MOCA_PIN=%s\n' 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 "$PIN" >"$TMP/pins-d.sh"
run_d() {
  local body=$1
  shift
  env -u E17B -u E17C E15_ROOT="$TROOT" E15_TEST_ROOT="$TROOT" E15_TEST_PINS="${PINS_FILE:-$TMP/pins-d.sh}" E15_HOST_PROFILE=fresh-metal E17D=1 \
    E15_MANIFEST="$TMP/m.md" PATH="$STUB:$PATH" "$@" bash -c 'source "$1"; '"$body" _ "$SCRIPT"
}
gate_d() { run_d 'leaf_new_ok "$T_LEAF" "$T_RAM"' T_LEAF="$1" T_RAM="$2" >"$TMP/g.out" 2>&1 && echo accepted || echo refused; }
check "E17D=1 alone (E17B, E17C unset) is not refused as 'E17B=1 is required'; it implies both" \
  "$(run_d 'echo sourced' 2>&1 | grep -c 'is required')/$(run_d 'echo "$E17B$E17C"' 2>/dev/null)" "0/11"
check "E17D=1: the guard accepts e17d-<E17D pin8>-1024 and -256" "$(gate_d "e17d-$P8-1024" 1024)/$(gate_d "e17d-$P8-256" 256)" "accepted/accepted"
check "E17D=1: the guard refuses e17c-* and e17b-* leaves, naming the e17d grammar" \
  "$(gate_d "e17c-$P8-1024" 1024)/$(grep -c 'is not e17d-<8 hex>-{1024|256}' "$TMP/g.out")/$(gate_d "e17b-$P8-1024" 1024)" "refused/1/refused"
check "E17C=1 alone: the guard refuses e17d-* leaves (E17d's)" "$(gate_c "e17d-$P8-1024" 1024)/$(grep -c 'is not e17c-<8 hex>-{1024|256}' "$TMP/g.out")" "refused/1"
flow_d() { run_d "$FLOW main --ram-mb $1 --leaf $2" FEATS="$3" >"$TMP/flow.out" 2>&1 && echo 0 || echo $?; }
LD=e17d-$P8-1024
check "E17D=1: a build publishes e17d-<E17D pin8>-1024 from the moca-e17d checkout when the manifest lists lease-processes-v1" \
  "$(flow_d 1024 "$LD" '"lease-v1", "balloon-fpr-v1", "lease-processes-v1"')/$([ -f "$SNAP/$LD/manifest.json" ] && echo published)" "0/published"
rm -rf "${SNAP:?}/$LD"
check "E17D=1: a manifest without lease-processes-v1 fails and the leaf is removed, naming the feature" \
  "$(flow_d 1024 "$LD" '"lease-v1", "balloon-fpr-v1"')/$([ -e "$SNAP/$LD" ] && echo left || echo removed)/$(grep -c 'manifest lacks: lease-processes-v1' "$TMP/flow.out")" "1/removed/1"
check "E17C=1: lease-processes-v1 is not required (E17c's leaves are unchanged)" \
  "$(flow_c 1024 "e17c-$P8-1024" '"lease-v1", "balloon-fpr-v1"')" "0"
rm -rf "${SNAP:?}/e17c-$P8-1024"
printf 'E17B_MOCA_PIN=%s\nE17C_MOCA_PIN=%s\nE17D_MOCA_PIN=%s\n' "$PIN" "$PIN" 0000000000000000000000000000000000000000 >"$TMP/pins-d-zero.sh"
check "E17D=1: the placeholder E17D pin is refused (e17d_require_pin)" \
  "$(PINS_FILE=$TMP/pins-d-zero.sh run_d "$FLOW main --ram-mb 1024 --leaf e17d-00000000-1024" FEATS='"lease-v1", "balloon-fpr-v1", "lease-processes-v1"' >"$TMP/flow.out" 2>&1 && echo 0 || echo 1)/$(grep -c 'E17D_MOCA_PIN is still the placeholder' "$TMP/flow.out")" "1/1"
check "after the E17d cases e15 is untouched and no other leaf exists" "$(snapls)/$(cat "$SNAP/e15/manifest.json")" "e15/keep"

echo
if [ "$fails" -eq 0 ]; then echo "snapshot-e17b.test.sh: all checks passed"; else echo "snapshot-e17b.test.sh: $fails FAILED"; fi
exit "$([ "$fails" -eq 0 ] && echo 0 || echo 1)"
