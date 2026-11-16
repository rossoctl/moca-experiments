#!/usr/bin/env bash
# shellcheck disable=SC2024  # the logs are the login user's on purpose (as setup.sh); only the commands need root
# experiments/e17-lease/rig/snapshot-e17b.sh -- build one E17b guest snapshot into a NEW leaf.
#
#   E17B=1 snapshot-e17b.sh --ram-mb {1024|256} --leaf e17b-<sha8>-<ram>
#
# Run ON THE RIG by the controller, as the login user (sudo -n per step, as setup.sh), from the staged
# copy ($E15_ROOT/src/e17/rig). setup.sh under E17B=1 never builds a snapshot (rulings E17B-R3, R32: it skips
# that step with a log line); this is the builder it names. It reuses setup.sh step 7's recipe for fresh-metal: the pinned guest kernel,
# moca's build-rootfs.sh over the pinned sandbox image + E15's pytest wheels, the guest git identity,
# then moca's build-snapshot.sh from $E15_MOCA (the E17b checkout, at E17B_MOCA_PIN) with that
# checkout's own guest agent (--agent $E15_MOCA/remote-worker). Like E15 it bakes no egress CA.
#
# Rig safety (2026-11-09 incident): the leaf is a NEW directory under /srv/e15/snapshots and nothing
# else is ever deleted. The name must be e17b-<first 8 hex of the pin>-<1024|256> with the RAM equal to
# --ram-mb; never e15, never an existing leaf, never a path with / or .., and the snapshots dir must be
# the real directory (no symlink escape). Every rm -rf goes through safe_rm_rf, which re-checks.
#
# After the build the manifest must list lease-v1 and balloon-fpr-v1. If either is missing the leaf is
# REMOVED (not left marked failed): a half-trusted snapshot sitting under the snapshots dir, with a valid
# name, is one stray --snapshot argument from being measured as an E17b arm. The leaf is ours (the guard
# proved it did not exist before this run), the manifest is copied into the build log first, and the
# build log is kept, so nothing needed for diagnosis is lost.
set -euo pipefail
E15_PROG=snapshot-e17b.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The profile is the whole point: with E17B unset lib.sh would resolve the sealed E15 pin and checkout.
if [ "${E17B:-}" != 1 ]; then
  printf '%s: E17B=1 is required (E17b snapshots are built at E17B_MOCA_PIN only)\n' "$E15_PROG" >&2
  exit 1
fi
# The repo layout and the rig's staged one (sync.sh puts e15-session-density at src/e15 and e17-lease at src/e17).
for _lib in "$HERE/../../e15-session-density/rig/lib.sh" "$HERE/../../e15/rig/lib.sh"; do
  [ -f "$_lib" ] && break
done
[ -f "$_lib" ] || {
  printf '%s: no lib.sh next to the E15 rig scripts\n' "$E15_PROG" >&2
  exit 1
}
# shellcheck source=../../e15-session-density/rig/lib.sh
. "$_lib"

LEAF_RE='^e17b-[0-9a-f]{8}-(1024|256)$'
LEAF=""
RAM=""

# snaproot_ok: the snapshots dir is the real /srv/e15/snapshots (rig tests: their own scratch one), not a symlink.
snaproot_ok() {
  local phys
  case "$E15_SNAPDIR" in
  /srv/e15/snapshots) ;;
  */e15-rig-test.*/snapshots) [ "${E15_TEST_ROOT:-}" = "${E15_SNAPDIR%/snapshots}" ] || return 1 ;;
  *) return 1 ;;
  esac
  [ -d "$E15_SNAPDIR" ] || return 1
  phys=$(cd -P "$E15_SNAPDIR" 2>/dev/null && pwd -P) || return 1
  [ "$phys" = "$E15_SNAPDIR" ]
}

# leaf_name_ok NAME RAM: the name grammar, the pin prefix and the RAM. Prints the reason on stderr, returns 1.
leaf_name_ok() {
  local name=$1 ram=$2 pin8=${E15_MOCA_PIN:0:8}
  [ -n "$name" ] || { echo "empty leaf name" >&2; return 1; }
  case "$name" in
  */* | *..*) echo "leaf '$name' has / or .." >&2; return 1 ;;
  e15) echo "leaf 'e15' is the sealed snapshot" >&2; return 1 ;;
  esac
  [[ $name =~ $LEAF_RE ]] || { echo "leaf '$name' is not e17b-<8 hex>-{1024|256}" >&2; return 1; }
  [[ $pin8 =~ ^[0-9a-f]{8}$ ]] || { echo "E15_MOCA_PIN '$E15_MOCA_PIN' has no 8-hex prefix" >&2; return 1; }
  [[ $name == "e17b-$pin8-"* ]] || { echo "leaf '$name' is not for pin $pin8" >&2; return 1; }
  case "$ram" in 1024 | 256) ;; *) echo "--ram-mb '$ram' is not 1024 or 256" >&2; return 1 ;; esac
  [ "${name##*-}" = "$ram" ] || { echo "leaf '$name' names RAM ${name##*-}, --ram-mb is $ram" >&2; return 1; }
}

# leaf_path_ok NAME: the leaf's path is directly under the real snapshots dir and is not a symlink.
leaf_path_ok() {
  local path=$E15_SNAPDIR/$1 parent
  snaproot_ok || { echo "snapshots dir '$E15_SNAPDIR' is not the real /srv/e15/snapshots" >&2; return 1; }
  parent=$(cd -P "$(dirname "$path")" 2>/dev/null && pwd -P) || return 1
  [ "$parent" = "$E15_SNAPDIR" ] || { echo "'$path' resolves outside $E15_SNAPDIR" >&2; return 1; }
  [ ! -L "$path" ] || { echo "'$path' is a symlink" >&2; return 1; }
}

# leaf_new_ok NAME RAM: everything above, and the leaf does not exist yet.
leaf_new_ok() {
  leaf_name_ok "$1" "$2" && leaf_path_ok "$1" || return 1
  if [ -e "$E15_SNAPDIR/$1" ] || [ -L "$E15_SNAPDIR/$1" ]; then
    echo "leaf '$E15_SNAPDIR/$1' already exists" >&2
    return 1
  fi
}

# stage_dir: this run's scratch (rootfs tree), keyed by the leaf so runs never share one.
stage_dir() { echo "$E15_ROOT/rootfs-build-e17b/$LEAF"; }

# safe_rm_rf PATH: the ONLY rm -rf in this script. PATH must be exactly this run's leaf or this run's stage
# dir, rebuilt from the validated LEAF/RAM and re-checked here (name grammar, no symlink, real parent).
safe_rm_rf() {
  local p=${1:-} sroot=$E15_ROOT/rootfs-build-e17b phys
  [ -n "$p" ] || die "safe_rm_rf: empty path"
  leaf_name_ok "$LEAF" "$RAM" 2>/dev/null || die "safe_rm_rf: refusing, leaf '$LEAF' / ram '$RAM' fail the guard"
  if [ "$p" = "$E15_SNAPDIR/$LEAF" ]; then
    leaf_path_ok "$LEAF" >/dev/null 2>&1 || die "safe_rm_rf: refusing $p (leaf path check)"
  elif [ "$p" = "$(stage_dir)" ]; then
    [ ! -L "$sroot" ] && [ ! -L "$p" ] || die "safe_rm_rf: refusing $p (symlink)"
    [ -d "$sroot" ] || return 0 # nothing to remove
    phys=$(cd -P "$sroot" 2>/dev/null && pwd -P) || die "safe_rm_rf: cannot resolve $sroot"
    [ "$phys" = "$sroot" ] || die "safe_rm_rf: refusing $p ($sroot is not the real directory)"
  else
    die "safe_rm_rf: refusing '$p': neither this run's leaf nor its stage dir"
  fi
  sudo -n rm -rf -- "${p:?}"
}

# --- build steps (functions so rig-free tests can replace the host-bound ones) -----------------------------
prepare_kernel() {
  KERNEL=$E15_ROOT/kernel/$E15_KERNEL_NAME
  mkdir -p "$(dirname "$KERNEL")"
  e15_fetch "$E15_KERNEL_URL" "$E15_KERNEL_SHA256" "$KERNEL"
}

# E17B_ROOTFS_REQUIRE: the tools build-rootfs.sh checks the image for (its --require; ruling E17B-R43). moca's own
# default list (deploy/microvm/build-rootfs.sh REQUIRED_TOOLS) includes gh, which E15's pinned benchmark image never
# shipped, so the default refuses it ("gh there refuses every benchmark image"). The E17b guest must keep E15/E17a's
# userland (Python 3.9, the cp39 wheels), and the pycache workload never calls gh: so the list is moca's minus gh. The
# snapshot's manifest still records the capabilities the guest really has.
E17B_ROOTFS_REQUIRE="bash git rg python3 base64 file ls cat"

# prepare_tree TREE: setup.sh step 7's fresh-metal rootfs, the same recipe (build-rootfs.sh at the E17b pin with
# --require E17B_ROOTFS_REQUIRE).
prepare_tree() {
  local tree=$1 src_digest sp w
  log "rootfs: $E15_MOCA/deploy/microvm/build-rootfs.sh over $E15_SANDBOX_IMAGE + pytest wheels (log $E15_LOGS/build-rootfs-$LEAF.log)"
  e15_podman pull "$E15_SANDBOX_IMAGE" >"$E15_LOGS/podman-pull-sandbox-$LEAF.log" 2>&1 ||
    die "podman pull $E15_SANDBOX_IMAGE failed; see $E15_LOGS/podman-pull-sandbox-$LEAF.log"
  sudo -n env CONTAINERS_STORAGE_CONF="$E15_PODMAN_CONF" PATH="$(e15_path)" \
    bash "$E15_MOCA/deploy/microvm/build-rootfs.sh" --out "$tree" --image "$E15_SANDBOX_IMAGE" \
    --require "$E17B_ROOTFS_REQUIRE" \
    >"$E15_LOGS/build-rootfs-$LEAF.log" 2>&1 || die "build-rootfs.sh failed; see $E15_LOGS/build-rootfs-$LEAF.log"
  src_digest=$(sudo -n sed -n 's/^digest=//p' "$tree/etc/moca-rootfs-source")
  case "$src_digest" in
  "$E15_SANDBOX_IMAGE_DIGEST" | "$E15_SANDBOX_IMAGE_AMD64_DIGEST") ;;
  *) die "build-rootfs.sh exported digest '$src_digest', not the pinned $E15_SANDBOX_IMAGE_DIGEST" ;;
  esac
  sp=$(sudo -n sh -c "ls -d $tree/usr/lib/python3.*/site-packages" | head -1)
  [ -n "$sp" ] || die "no python3 site-packages in the base rootfs"
  for w in "$E15_ROOT"/wheels/*.whl; do sudo -n unzip -q -o "$w" -d "$sp"; done
  sudo -n chroot "$tree" /usr/bin/python3 -m compileall -q "${sp#"$tree"}" >/dev/null 2>&1 || true
  sudo -n chroot "$tree" /usr/bin/python3 -m pytest --version >"$E15_LOGS/rootfs-pytest-$LEAF.log" 2>&1 ||
    die "pytest does not import in the staged rootfs (chroot); see $E15_LOGS/rootfs-pytest-$LEAF.log"
  if ! sudo -n test -s "$tree/etc/gitconfig"; then
    printf '[user]\n\tname = MOCA sandbox\n\temail = sandbox@moca.invalid\n' | sudo -n tee "$tree/etc/gitconfig" >/dev/null
  fi
}

# run_build_snapshot TREE OUT: moca's build-snapshot.sh, the same arguments as setup.sh (RAM and image name aside).
run_build_snapshot() {
  local tree=$1 out=$2
  local -a GOENV_ROOT
  mapfile -t GOENV_ROOT < <(e15_goenv root)
  log "build-snapshot.sh --guest-ram-mb $RAM --image $LEAF --out $out (log $E15_LOGS/build-snapshot-$LEAF.log)"
  sudo -n env PATH="$(e15_path)" "${GOENV_ROOT[@]}" TMPDIR="$E15_ROOT" \
    bash "$E15_MOCA/deploy/microvm/build-snapshot.sh" \
    --kernel "$KERNEL" --rootfs "$tree" --agent "$E15_MOCA/remote-worker" \
    --image "$LEAF" --vmm firecracker --guest-ram-mb "$RAM" --out "$out" \
    >"$E15_LOGS/build-snapshot-$LEAF.log" 2>&1 || die "build-snapshot.sh failed; see $E15_LOGS/build-snapshot-$LEAF.log"
}

# manifest_features MANIFEST: the features list, one per line.
manifest_features() {
  sudo -n python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1])).get("features", [])))' "$1"
}

# assert_features MANIFEST: lease-v1 and balloon-fpr-v1 must both be listed.
assert_features() {
  local feats f missing=()
  feats=$(manifest_features "$1") || return 1
  for f in lease-v1 balloon-fpr-v1; do
    printf '%s\n' "$feats" | grep -qx "$f" || missing+=("$f")
  done
  [ ${#missing[@]} -eq 0 ] || { echo "manifest lacks: ${missing[*]}" >&2; return 1; }
}

CLEAN_LEAF=0
CLEAN_STAGE=0
cleanup() {
  local rc=$?
  trap - EXIT
  set +e
  # Only a leaf this run proved new, re-proved just before it started building, and has not
  # yet validated is ever removed on failure (a leaf another run published meanwhile is not ours).
  if [ "$rc" != 0 ] && [ "$CLEAN_LEAF" = 1 ]; then
    log "failed (rc $rc): removing the unpublished leaf $E15_SNAPDIR/$LEAF"
    (safe_rm_rf "$E15_SNAPDIR/$LEAF")
  fi
  if [ "$CLEAN_STAGE" = 1 ]; then (safe_rm_rf "$(stage_dir)"); fi
  exit "$rc"
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
    --ram-mb | --leaf)
      [ $# -ge 2 ] || die "$1 needs a value (usage: --ram-mb {1024|256} --leaf e17b-<sha8>-<ram>)"
      if [ "$1" = --ram-mb ]; then RAM=$2; else LEAF=$2; fi
      shift 2
      ;;
    *) die "unknown argument '$1' (usage: --ram-mb {1024|256} --leaf e17b-<sha8>-<ram>)" ;;
    esac
  done
  [ "$E15_HOST_PROFILE" = fresh-metal ] || die "E17b snapshots are built on the fresh-metal rig only"
  e17b_require_pin
  leaf_name_ok "$LEAF" "$RAM" || die "bad --leaf/--ram-mb"
  [ "$(id -u)" != 0 ] || die "run as the login user, not root (sudo -n is used per step)"
  sudo -n true 2>/dev/null || die "needs passwordless sudo"
  [ -d "$E15_MOCA/.git" ] || [ -f "$E15_MOCA/.git" ] || die "no moca checkout at $E15_MOCA; run setup.sh with E17B=1 first"
  [ "$(git -C "$E15_MOCA" rev-parse HEAD)" = "$E15_MOCA_PIN" ] || die "$E15_MOCA is not at E17B_MOCA_PIN $E15_MOCA_PIN"
  PATH=$(e15_path)
  export PATH
  refuse_shared_paths "$E15_ROOT" "$E15_MANIFEST" "$E15_SNAPDIR"
  mkdir -p "$E15_LOGS"
  [ -d "$E15_SNAPDIR" ] || sudo -n mkdir -p "$E15_SNAPDIR"
  leaf_new_ok "$LEAF" "$RAM" || die "refusing leaf '$LEAF'"
  m_init
  m_section Snapshot
  trap cleanup EXIT
  CLEAN_STAGE=1 # from here the stage dir is ours (the leaf is claimed only right before the build)
  local stage tree out=$E15_SNAPDIR/$LEAF
  stage=$(stage_dir)
  tree=$stage/tree
  safe_rm_rf "$stage"
  sudo -n mkdir -p "$stage"
  prepare_kernel
  prepare_tree "$tree"
  # The leaf only appears at build-snapshot's final publish, minutes from now: prove it is still new
  # right before the build, so a failure removes only a leaf this run published.
  leaf_new_ok "$LEAF" "$RAM" || die "leaf '$LEAF' appeared meanwhile; not touching it"
  CLEAN_LEAF=1
  run_build_snapshot "$tree" "$out"
  sudo -n test -f "$out/manifest.json" || die "build-snapshot.sh left no $out/manifest.json"
  sudo -n cat "$out/manifest.json" >"$E15_LOGS/manifest-$LEAF.json"
  assert_features "$out/manifest.json" || die "manifest $out/manifest.json is not lease-capable (copy: $E15_LOGS/manifest-$LEAF.json); leaf removed"
  CLEAN_LEAF=0 # valid from here on: a later bookkeeping failure must not delete a good snapshot
  m_purge "built snapshot $out ($(sudo -n python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m["hash"], "guest", m["guest_ram_mb"], "MiB", ",".join(m["features"]))' "$out/manifest.json"))" "sudo -n rm -rf $out"
  log "built $out"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
