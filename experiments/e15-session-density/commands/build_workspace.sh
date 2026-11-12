#!/usr/bin/env bash
# experiments/e15-session-density/commands/build_workspace.sh
#
# Builds E15's seeded workspace template (SPEC §5.6): an ext4 image whose root is the guest's
# /workspace, holding
#   project/   the repository in project.lock, at its locked commit, with its .git
#   scripts/   the generated script set (scripts/gen_scripts.py)
#   data.bin   only with --dataset-mib W: W MiB of incompressible bytes, deterministic from
#              --dataset-seed S (SHAKE-256 of "e15-data.bin/<S>/<block>" per MiB block), the
#              memory-pressure point's per-session working set (SPEC §10.3, mem512)
# The rig copies the template once per session key; the worker reuses any workspace.img that is
# already ext4, so no worker change is needed.
#
# Usage:
#   sudo experiments/e15-session-density/commands/build_workspace.sh [OPTS] OUT_IMG   sparse ext4 image (Linux, root)
#   experiments/e15-session-density/commands/build_workspace.sh [OPTS] --dir OUTDIR   stage the tree only (any OS, no root)
#
# Options (before OUT_IMG / --dir):
#   --image-mb M        image size in MiB (default 256); must match the rung's SH_WORKSPACE_IMAGE_MB
#   --dataset-mib W     write /workspace/data.bin, W MiB (W + 128 <= M: room for the project and
#                       ext4's own metadata)
#   --dataset-seed S    data.bin's seed (default 1)
#
# Environment:
#   E15_PROJECT_SRC   clone from here instead of project.lock's url (a local clone or bundle;
#                     the commit must still be in it)
#   E15_WS_UID/GID    owner of the tree inside the image (default 0:0, the guest agent's uid --
#                     git refuses a repository owned by another uid as "dubious ownership")
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LOCK="$HERE/project.lock"
IMG_MIB=256
WS_UID="${E15_WS_UID:-0}"
WS_GID="${E15_WS_GID:-0}"

DATA_MIB=0
DATA_SEED=1

usage() {
  echo "usage: $0 [--image-mb M] [--dataset-mib W] [--dataset-seed S] OUT_IMG | --dir OUTDIR" >&2
  exit 1
}

# write_dataset ROOT: ROOT/data.bin, DATA_MIB MiB, one SHAKE-256 stream per 1 MiB block.
write_dataset() {
  [ "$DATA_MIB" -gt 0 ] || return 0
  python3 - "$1/data.bin" "$DATA_MIB" "$DATA_SEED" <<'PY'
import hashlib, os, sys
out, mib, seed = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(out + ".tmp", "wb") as f:
    for i in range(mib):
        f.write(hashlib.shake_256(b"e15-data.bin/%d/%d" % (seed, i)).digest(1 << 20))
os.chmod(out + ".tmp", 0o444)
os.rename(out + ".tmp", out)
PY
}

lock_field() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$LOCK" "$1"
}

# stage ROOT: clone the locked project into ROOT/project and generate ROOT/scripts.
stage() {
  local root="$1" url commit src head
  url="$(lock_field url)"
  commit="$(lock_field commit)"
  src="${E15_PROJECT_SRC:-$url}"
  # Fetch exactly the locked commit (no branches, no tags) and detach at it, so the image holds
  # history up to the lock and nothing past it: no ref can reach a later commit.
  git init -q "$root/project"
  git -C "$root/project" fetch -q --no-tags "$src" "$commit"
  git -C "$root/project" checkout -q --detach "$commit"
  git -C "$root/project" for-each-ref --format='%(refname)' refs/heads refs/tags |
    while read -r ref; do git -C "$root/project" update-ref -d "$ref"; done
  # Drop FETCH_HEAD and any object fetched beyond the lock's history.
  rm -f "$root/project/.git/FETCH_HEAD"
  git -C "$root/project" reflog expire --expire=now --all
  git -C "$root/project" gc -q --prune=now
  head="$(git -C "$root/project" rev-parse HEAD)"
  if [ "$head" != "$commit" ]; then
    echo "build_workspace.sh: HEAD $head is not the locked commit $commit" >&2
    exit 1
  fi
  if [ -n "$(git -C "$root/project" for-each-ref)" ]; then
    echo "build_workspace.sh: staged project still has refs besides HEAD" >&2
    exit 1
  fi
  # The library's scratch directory: write/file_ops invocations work under project/.e15/ and
  # must leave `git status` clean.
  mkdir -p "$root/project/.git/info"
  printf '.e15/\n' >>"$root/project/.git/info/exclude"
  # The image is copied per session; keep the index valid across copies, and give
  # `git commit-tree` an identity without a global config (the guest has no HOME config).
  git -C "$root/project" config core.checkStat minimal
  git -C "$root/project" config core.trustctime false
  git -C "$root/project" config user.name e15
  git -C "$root/project" config user.email e15@example.invalid
  python3 "$HERE/scripts/gen_scripts.py" "$root/scripts"
  git -C "$root/project" update-index -q --refresh
  if [ -n "$(git -C "$root/project" status --porcelain)" ]; then
    echo "build_workspace.sh: staged project is not clean" >&2
    exit 1
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
  --image-mb | --dataset-mib | --dataset-seed)
    [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]] || {
      echo "build_workspace.sh: $1 needs a non-negative integer" >&2
      usage
    }
    case "$1" in
    --image-mb) IMG_MIB=$((10#$2)) ;;
    --dataset-mib)
      DATA_MIB=$((10#$2))
      [ "$DATA_MIB" -gt 0 ] || {
        echo "build_workspace.sh: --dataset-mib must be >= 1" >&2
        exit 1
      }
      ;;
    --dataset-seed) DATA_SEED=$((10#$2)) ;;
    esac
    shift 2
    ;;
  *) break ;;
  esac
done
if [ "$IMG_MIB" -lt 64 ]; then
  echo "build_workspace.sh: --image-mb $IMG_MIB is too small (>= 64)" >&2
  exit 1
fi
if [ "$DATA_MIB" -gt 0 ] && [ $((DATA_MIB + 128)) -gt "$IMG_MIB" ]; then
  echo "build_workspace.sh: --dataset-mib $DATA_MIB does not fit a $IMG_MIB MiB image (need W + 128 <= M)" >&2
  exit 1
fi

[ $# -ge 1 ] || usage
case "$1" in
--dir)
  [ $# -eq 2 ] || usage
  OUT="$2"
  if [ -e "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ]; then
    echo "build_workspace.sh: $OUT exists and is not empty" >&2
    exit 1
  fi
  mkdir -p "$OUT"
  stage "$OUT"
  write_dataset "$OUT"
  ds=""
  [ "$DATA_MIB" = 0 ] || ds=", data.bin $DATA_MIB MiB seed $DATA_SEED"
  echo "staged $OUT ($(lock_field commit)$ds)"
  exit 0
  ;;
-h | --help) usage ;;
-*) usage ;;
esac

[ $# -eq 1 ] || usage
OUT_IMG="$1"
if [ "$(id -u)" != 0 ]; then
  echo "build_workspace.sh: image mode must run as root (loop mount, file ownership)" >&2
  exit 1
fi
if [ -e "$OUT_IMG" ]; then
  echo "build_workspace.sh: $OUT_IMG exists; remove it or choose another path" >&2
  exit 1
fi

# Build under a temp name next to the target and rename at the end, so a half-built image is
# never at OUT_IMG (the worker would take any ext4 file there as a finished template).
TMP_IMG="$(mktemp "$OUT_IMG.build-XXXXXX")"
MNT="$(mktemp -d)"
cleanup() {
  if mountpoint -q "$MNT"; then umount "$MNT" || true; fi
  rmdir "$MNT" 2>/dev/null || true
  rm -f "$TMP_IMG"
}
trap cleanup EXIT

truncate -s "${IMG_MIB}M" "$TMP_IMG"
# A data.bin image (mem512) is 1 GiB: initialise its inode tables and journal now, so no guest's
# ext4lazyinit writes them later -- each such write would un-share blocks of a reflinked per-session
# copy. The default image is built as before.
mkfs_opts=()
[ "$DATA_MIB" = 0 ] || mkfs_opts=(-E "lazy_itable_init=0,lazy_journal_init=0")
mkfs.ext4 -F -q "${mkfs_opts[@]}" "$TMP_IMG"
mount -o loop "$TMP_IMG" "$MNT"
stage "$MNT"
write_dataset "$MNT"
chown -R "$WS_UID:$WS_GID" "$MNT/project" "$MNT/scripts"
[ ! -e "$MNT/data.bin" ] || chown "$WS_UID:$WS_GID" "$MNT/data.bin"
# The ownership change touched every inode; refresh the index so the first `git status` in a
# session is not an index rewrite.
git -c safe.directory="$MNT/project" -C "$MNT/project" update-index -q --refresh
sync
umount "$MNT"
mv "$TMP_IMG" "$OUT_IMG"
echo "built $OUT_IMG ($(lock_field commit), ${IMG_MIB} MiB sparse, data.bin ${DATA_MIB} MiB seed ${DATA_SEED}, $(du -k "$OUT_IMG" | cut -f1) KiB used)"
