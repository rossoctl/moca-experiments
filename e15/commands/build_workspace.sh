#!/usr/bin/env bash
# e15/commands/build_workspace.sh
#
# Builds E15's seeded workspace template (SPEC §5.6): an ext4 image whose root is the guest's
# /workspace, holding
#   project/   the repository in project.lock, at its locked commit, with its .git
#   scripts/   the generated script set (scripts/gen_scripts.py)
# The rig copies the template once per session key; the worker reuses any workspace.img that is
# already ext4, so no worker change is needed.
#
# Usage:
#   sudo e15/commands/build_workspace.sh OUT_IMG       256 MiB sparse ext4 image (Linux, root)
#   e15/commands/build_workspace.sh --dir OUTDIR       stage the tree only (any OS, no root)
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

usage() {
  echo "usage: $0 OUT_IMG | --dir OUTDIR" >&2
  exit 1
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
  echo "staged $OUT ($(lock_field commit))"
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
mkfs.ext4 -F -q "$TMP_IMG"
mount -o loop "$TMP_IMG" "$MNT"
stage "$MNT"
chown -R "$WS_UID:$WS_GID" "$MNT/project" "$MNT/scripts"
# The ownership change touched every inode; refresh the index so the first `git status` in a
# session is not an index rewrite.
git -c safe.directory="$MNT/project" -C "$MNT/project" update-index -q --refresh
sync
umount "$MNT"
mv "$TMP_IMG" "$OUT_IMG"
echo "built $OUT_IMG ($(lock_field commit), ${IMG_MIB} MiB sparse, $(du -k "$OUT_IMG" | cut -f1) KiB used)"
