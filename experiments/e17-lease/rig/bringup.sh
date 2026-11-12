#!/usr/bin/env bash
# shellcheck disable=SC2024  # logs are the login user's files on purpose; sudo runs the command only
# experiments/e17-lease/rig/bringup.sh -- E17's rig bring-up on the E15 metal host (PLAN Task 5 step 1). Idempotent.
#
# Run by the controller only, as the rig's login user (passwordless sudo), from the staged copy,
# after experiments/e17-lease/rig/sync.sh and with E15's setup.sh done (its snapshot built and recorded):
#   E15_HOST_PROFILE=fresh-metal bash /srv/e15/src/e17/rig/bringup.sh
#
# Inputs (sync.sh stages them):
#   /srv/e15/src/e17/workload/            build_pycache_workspace.sh, wheels.lock, project/
#   /srv/e15/wheels-pycache/*.whl         the venv's wheels (wheels.lock)
#   /srv/e15/corpora/pycache{,-low}/      corpus.jsonl + corpus-report.json
#   /srv/e15/state/artifacts              setup.sh's "snapshot-rootfs <sha256> <path>" line: the guest
#                                         rootfs the venv is built with (read from there, not assumed)
#
# What it does, in order, each step logged to the manifest (default ~/e17-manifest.md; E15_MANIFEST
# overrides) as a note with its undo line (a note: teardown.sh replays nothing from it):
#   1. guards: fresh-metal only, login user, the staged copy, every path under /srv/e15
#   2. the guest rootfs: the snapshot-rootfs artifact's path and sha256, the file checked against it
#      (first: a missing state/artifacts is refused by name before anything is recorded there)
#   3. the pycache corpora: each corpus.jsonl's sha256 against its report's corpus_sha256 (as setup.sh
#      step 8c), recorded in state/artifacts
#   4. the wheels: every wheel in wheels.lock is in /srv/e15/wheels-pycache with the locked sha256
#   5. the templates (points.sh pycache-d64, pycache, pycache-d768): for D = 64, 256, 768, refused
#      while a rung's worker (e15-worker.service) runs, before any template is removed or rebuilt,
#      /srv/e15/template-pycache-d<D>/workspace.img by build_pycache_workspace.sh --image-mb 1536
#      --dataset-mib D --dataset-seed 1 --wheels /srv/e15/wheels-pycache --rootfs-tree <the rootfs,
#      loop-mounted read-only once, as setup.sh step 7's aws-prelim branch, unmounted by a trap;
#      its sha256 is checked again after the unmount>.
#      A template is skipped when its inputs stamp (state/template-pycache-d<D>.inputs: the sha256
#      over the builder, wheels.lock, the project sources, image size, D, seed and the rootfs sha256)
#      matches, the image is there and its sha256 is the recorded one. Otherwise only the exact old
#      workspace.img is removed (rm -f, after the path guard) and the template is rebuilt.
#      Per template: state/template-pycache-d<D> = the image's sha256 (rung.sh's template_sha256),
#      state/artifacts, and BUILD (the image's /BUILD, read with debugfs) beside the image, which
#      smoke.sh checks analyze's printed sha256 against.
#
# Rig safety: no rm -rf is run; it appears only in the manifest's undo text, always of a leaf (one
# template directory, one corpus directory, the wheels directory). The only removal run is `rm -f` of
# a template image whose path is exactly $E15_ROOT/template-pycache-d<D>/workspace.img for D in 64
# 256 768 (e17_check_target, checked again just before), and of the BUILD file and stamps beside it.
# The rootfs mount point is a fresh mktemp directory, removed with rmdir (empty only).
set -euo pipefail
E15_PROG=bringup.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E15_MANIFEST=${E15_MANIFEST:-$HOME/e17-manifest.md}
# The staged copy on the rig has e15/ beside e17/ ($HERE/../../e15/rig); a checkout of this
# repo has it at $HERE/../../../experiments/e15-session-density/rig. Use whichever exists.
E15_RIG=$HERE/../../e15/rig
[ -f "$E15_RIG/lib.sh" ] || E15_RIG=$HERE/../../../experiments/e15-session-density/rig
# shellcheck source=SCRIPTDIR/../../experiments/e15-session-density/rig/lib.sh
. "$E15_RIG/lib.sh"
# shellcheck source=SCRIPTDIR/../../experiments/e15-session-density/rig/points.sh
. "$E15_RIG/points.sh"

E17_DS=(64 256 768)

# e17_point_of D: the points.sh point whose template has dataset D.
e17_point_of() {
  case "$1" in
  64) echo pycache-d64 ;;
  256) echo pycache ;;
  768) echo pycache-d768 ;;
  *) return 1 ;;
  esac
}

# e17_check_target PATH D: exit 3 unless PATH is exactly $E15_ROOT/template-pycache-d<D>/workspace.img
# for D in 64 256 768, spelled that way (no //, ., .., trailing /), with neither the image nor its
# directory a symlink, the image not a directory, and the whole path under $E15_ROOT physically.
e17_check_target() {
  local p=$1 d=$2 want
  case "$d" in 64 | 256 | 768) ;; *)
    printf 'e17_check_target: D=%s is not a pycache template (64 256 768)\n' "$d" >&2
    exit 3
    ;;
  esac
  want=$E15_ROOT/template-pycache-d$d/workspace.img
  if [ "$p" != "$want" ] || [ "$(_lexical_path "$p")" != "$want" ]; then
    printf 'e17_check_target: %s is not exactly %s (rig rule: only that leaf is removed or built)\n' "$p" "$want" >&2
    exit 3
  fi
  if [ -L "$p" ] || [ -L "${p%/*}" ] || [ -d "$p" ]; then
    printf 'e17_check_target: %s or its directory is a symlink, or it is a directory\n' "$p" >&2
    exit 3
  fi
  refuse_outside_root "$p" "${p%/*}"
}

[ "$E15_HOST_PROFILE" = fresh-metal ] || die "E15_HOST_PROFILE=$E15_HOST_PROFILE: E17 runs on fresh-metal only"
[ "$(id -u)" != 0 ] || die "run as the login user, not root (sudo -n is used per step)"
sudo -n true 2>/dev/null || die "needs passwordless sudo"
E17_SRC=$E15_ROOT/src/e17
case "$HERE" in "$E17_SRC"/rig) ;; *) die "run the staged copy: $E17_SRC/rig/bringup.sh (not $HERE)" ;; esac
WL=$E17_SRC/workload
BUILDER=$WL/build_pycache_workspace.sh
LOCK=$WL/wheels.lock
WHEELS=$E15_ROOT/wheels-pycache
for f in "$BUILDER" "$LOCK"; do [ -f "$f" ] || die "no $f (run e17/rig/sync.sh)"; done
[ -d "$WL/project" ] || die "no $WL/project (run e17/rig/sync.sh)"
[ -d "$WHEELS" ] || die "no $WHEELS (run e17/rig/sync.sh)"
refuse_shared_paths "$E15_ROOT" "$E15_MANIFEST" "$E15_STATE" "$E15_LOGS" "$WHEELS" "$E15_CORPORA"
mkdir -p "$E15_STATE" "$E15_LOGS"
m_init
m_section "E17 bringup"
log "bringup: manifest $E15_MANIFEST"

# --- 2. the guest rootfs (E15's snapshot, from state/artifacts) ----------------------------------
# Read before step 3 records anything there (e15_artifact creates the file): a host setup.sh never
# set up has no artifacts file, and that is refused by name before any change.
[ -f "$E15_STATE/artifacts" ] || die "no $E15_STATE/artifacts (run e15/rig/setup.sh first: it records the snapshot rootfs there)"
art=$(awk '$1 == "snapshot-rootfs" {print $2, $3}' "$E15_STATE/artifacts" | tail -1)
[ -n "$art" ] || die "no snapshot-rootfs line in $E15_STATE/artifacts (run e15/rig/setup.sh first)"
read -r rootfs_want ROOTFS <<<"$art"
rootfs_want=${rootfs_want#sha256:}
[ -n "$ROOTFS" ] || die "the snapshot-rootfs artifact names no path"
refuse_outside_root "$ROOTFS"
sudo -n test -f "$ROOTFS" || die "no snapshot rootfs $ROOTFS (state/artifacts)"
rootfs_sha=$(sudo -n sha256sum "$ROOTFS" | cut -d' ' -f1)
[ "$rootfs_sha" = "$rootfs_want" ] ||
  die "$ROOTFS sha256 $rootfs_sha is not the recorded snapshot-rootfs $rootfs_want (re-run setup.sh)"
log "guest rootfs $ROOTFS (sha256 $rootfs_sha)"

# --- 3. the pycache corpora (staged by sync.sh) -------------------------------------------------
for pc in pycache pycache-low; do
  pd=$E15_CORPORA/$pc
  for f in corpus.jsonl corpus-report.json; do
    [ -f "$pd/$f" ] || die "no $pd/$f (e17/rig/gen_corpora.sh, then sync.sh)"
  done
  pcsha=$(sha256_of "$pd/corpus.jsonl")
  pcwant=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("corpus_sha256") or "")' "$pd/corpus-report.json")
  [ "$pcsha" = "$pcwant" ] || die "$pd/corpus.jsonl sha256 $pcsha is not its report's corpus_sha256 ${pcwant:-(none)}"
  e15_artifact "corpus-$pc" "$pcsha" "$pd/corpus.jsonl"
  log "$pc corpus sha256 $pcsha"
  m_has "E17 $pc corpus $pd/corpus.jsonl sha256 $pcsha" ||
    m_note "E17 $pc corpus $pd/corpus.jsonl sha256 $pcsha (staged by sync.sh) -- undo: rm -rf $pd"
done

# --- 4. the wheels ------------------------------------------------------------------------------
# Every wheel wheels.lock names, with its locked sha256 (build_pycache_workspace.sh checks again).
nwh=0
bad=()
while read -r want name; do
  case "$want" in '' | '#'*) continue ;; esac
  nwh=$((nwh + 1))
  if [ ! -f "$WHEELS/$name" ]; then
    bad+=("$name: missing from $WHEELS")
  elif [ "$(sha256_of "$WHEELS/$name")" != "$want" ]; then
    bad+=("$name: sha256 $(sha256_of "$WHEELS/$name"), wheels.lock pins $want")
  fi
done <"$LOCK"
[ "$nwh" -gt 0 ] || die "$LOCK names no wheel"
[ ${#bad[@]} -eq 0 ] || die "wheel check failed: $(printf '%s; ' "${bad[@]}")"
lock_sha=$(sha256_of "$LOCK")
log "wheels: $nwh in $WHEELS match wheels.lock ($lock_sha)"
m_has "E17 wheels $WHEELS: $nwh match wheels.lock $lock_sha" ||
  m_note "E17 wheels $WHEELS: $nwh match wheels.lock $lock_sha (staged by sync.sh) -- undo: rm -rf $WHEELS"

# --- 5. the templates ---------------------------------------------------------------------------
# Never preempt a rung: none may run while a template is removed or rebuilt.
refuse_running_rung() { if unit_active "$E15_UNIT_WORKER"; then die "a rung's worker ($E15_UNIT_WORKER) is running; refusing to preempt it (no template removed or rebuilt)"; fi; }
proj_sha=$(cd "$WL/project" && find . -type f ! -path '*/__pycache__/*' ! -path '*/.pytest_cache/*' ! -name '*.pyc' -print0 |
  LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
builder_sha=$(sha256_of "$BUILDER")

# The rootfs is mounted read-only once, when the first template needs a build; always unmounted on
# exit (the builder's own chroot mounts under it first, should a killed build have left any).
# A mount that survives its umount is loud: a WARNING per path on stderr, return 1, and the mount
# point is kept (never rmdir'd or forgotten). The trap warns; the explicit call after the loop dies.
mnt=""
unmount_rootfs() {
  [ -n "$mnt" ] || return 0
  local m left=0
  for m in proc dev tmp mnt workspace; do
    if mountpoint -q "$mnt/$m"; then sudo -n umount "$mnt/$m" || true; fi
  done
  if mountpoint -q "$mnt"; then sudo -n umount -d "$mnt" || true; fi
  for m in "$mnt/proc" "$mnt/dev" "$mnt/tmp" "$mnt/mnt" "$mnt/workspace" "$mnt"; do
    if mountpoint -q "$m"; then
      printf '%s: WARNING: %s still mounted\n' "$E15_PROG" "$m" >&2
      left=1
    fi
  done
  [ "$left" = 0 ] || return 1
  rmdir "$mnt" 2>/dev/null || true
  mnt=""
}
trap 'unmount_rootfs || true' EXIT
mounted=0
mount_rootfs() {
  [ -z "$mnt" ] || return 0
  mnt=$(mktemp -d "$E15_ROOT/rootfs-ro.mnt.XXXXXX")
  sudo -n mount -o loop,ro "$ROOTFS" "$mnt"
  mounted=1
  log "mounted $ROOTFS read-only at $mnt"
}

# read_build IMG OUT D SEED: the image's /BUILD into OUT; dies unless it is a pycache build of
# dataset D, seed SEED, with a venv. Prints its dataset_sha256.
read_build() {
  local img=$1 out=$2 d=$3 s=$4 dsha
  sudo -n debugfs -R 'cat /BUILD' "$img" 2>/dev/null >"$out.new" || true
  if ! grep -qx "dataset_mib: $d" "$out.new" || ! grep -qx "dataset_seed: $s" "$out.new" ||
    ! grep -q '^venv: ' "$out.new" || grep -q '^venv: skipped' "$out.new"; then
    die "$img: its /BUILD is not a pycache build of D=$d seed=$s with a venv (see $out.new)"
  fi
  dsha=$(sed -n 's/^dataset_sha256: //p' "$out.new")
  [[ "$dsha" =~ ^[0-9a-f]{64}$ ]] || die "$img: its /BUILD has no dataset_sha256"
  mv -f "$out.new" "$out"
  echo "$dsha"
}

summary=()
for D in "${E17_DS[@]}"; do
  pt=$(e17_point_of "$D")
  e15_point "$pt" || die "points.sh: no point $pt"
  [ "$E15_P_DATASET_MIB" = "$D" ] || die "points.sh: point $pt has dataset $E15_P_DATASET_MIB MiB, not $D"
  T=$E15_P_TEMPLATE
  STAMP=$E15_P_TEMPLATE_STAMP
  [ "$STAMP" = "template-pycache-d$D" ] || die "points.sh: point $pt's stamp is $STAMP, not template-pycache-d$D"
  e17_check_target "$T" "$D"
  tdir=${T%/*}
  if [ ! -d "$tdir" ]; then
    sudo -n mkdir -p "$tdir"
    sudo -n chown "$(id -un):$(id -gn)" "$tdir"
  fi
  # rung.sh reflinks the template into workspaces/: same device, XFS reflink=1, probed (setup.sh 3).
  storage=$(e15_storage_check "$E15_WORKSPACES" "$tdir")
  e15_require_reflink "$E15_WORKSPACES" "$tdir"
  m_has "$storage" || m_note "$storage"
  key=$(printf 'builder %s\nwheels.lock %s\nproject %s\nimage_mb %s\ndataset_mib %s\ndataset_seed %s\nrootfs %s\n' \
    "$builder_sha" "$lock_sha" "$proj_sha" "$E15_P_IMAGE_MB" "$D" "$E15_P_DATASET_SEED" "$rootfs_sha" | sha256sum | cut -d' ' -f1)
  state=kept
  if stamp_ok "$STAMP.inputs" "$key" && sudo -n test -f "$T" && [ -s "$E15_STATE/$STAMP" ] &&
    [ "$(sudo -n sha256sum "$T" | cut -d' ' -f1)" = "$(cat "$E15_STATE/$STAMP")" ]; then
    tsha=$(cat "$E15_STATE/$STAMP")
    dsha=$(read_build "$T" "$tdir/BUILD" "$D" "$E15_P_DATASET_SEED")
    log "template-pycache-d$D: inputs unchanged, $T sha256 $tsha (skipped)"
  else
    state=built
    refuse_running_rung
    mount_rootfs
    rm -f "$E15_STATE/$STAMP" "$E15_STATE/$STAMP.inputs" "$tdir/BUILD"
    e17_check_target "$T" "$D"
    sudo -n rm -f -- "$T"
    wlog=$E15_LOGS/build_pycache_workspace-d$D.log
    log "building $T (D=$D, seed $E15_P_DATASET_SEED, $E15_P_IMAGE_MB MiB; log $wlog)"
    sudo -n env PATH="$(e15_path)" bash "$BUILDER" --image-mb "$E15_P_IMAGE_MB" --dataset-mib "$D" \
      --dataset-seed "$E15_P_DATASET_SEED" --wheels "$WHEELS" --rootfs-tree "$mnt" "$T" >"$wlog" 2>&1 ||
      die "build_pycache_workspace.sh (D=$D) failed; see $wlog"
    tsha=$(sudo -n sha256sum "$T" | cut -d' ' -f1)
    [[ "$tsha" =~ ^[0-9a-f]{64}$ ]] || die "cannot hash $T"
    dsha=$(read_build "$T" "$tdir/BUILD" "$D" "$E15_P_DATASET_SEED")
    stamp_set "$STAMP" "$tsha"
    stamp_set "$STAMP.inputs" "$key"
    m_note "E17 built $T (sha256 $tsha; dataset_sha256 $dsha; inputs $key: builder $builder_sha, wheels.lock $lock_sha, project $proj_sha, image_mb $E15_P_IMAGE_MB, D $D, seed $E15_P_DATASET_SEED, rootfs $rootfs_sha; $(tail -1 "$wlog")) -- undo: sudo -n rm -rf $tdir; rm -f $E15_STATE/$STAMP $E15_STATE/$STAMP.inputs"
  fi
  e15_artifact "$STAMP" "$tsha" "$T"
  summary+=("d$D $state sha256=$tsha dataset_sha256=$dsha")
done
unmount_rootfs || die "$mnt is still mounted after umount (see the WARNING above); unmount it by hand (sudo -n umount -d $mnt) before anything else"
# The snapshot's rootfs must be byte-identical after the mount (the worker refuses a drifted one).
if [ "$mounted" = 1 ] && [ "$(sudo -n sha256sum "$ROOTFS" | cut -d' ' -f1)" != "$rootfs_sha" ]; then
  die "$ROOTFS changed while mounted read-only (sha256 no longer $rootfs_sha): the E15 snapshot is broken, rebuild it with setup.sh"
fi
for s in "${summary[@]}"; do log "template-pycache-$s"; done
m_note "E17 bringup complete: ${summary[*]}"
