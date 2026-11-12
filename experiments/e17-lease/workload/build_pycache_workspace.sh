#!/usr/bin/env bash
# experiments/e17-lease/workload/build_pycache_workspace.sh
#
# Builds E17's pycache workspace template (SPEC §4.2, PLAN Task 2): an ext4 image whose root is the
# guest's /workspace, holding
#   data/      D MiB of numeric CSV shards, data/shard-NNN.csv, 32 MiB each (the last one holds the
#              remainder), deterministic from --dataset-seed S: every shard's rows come from one
#              SHAKE-256 stream of "e17-pycache/<S>/<shard>", E15's data.bin approach
#              (experiments/e15-session-density/commands/build_workspace.sh) with CSV rows in place of raw blocks. CSV, not
#              Parquet: pyarrow is not in the wheel set, and read_csv still has to parse every byte.
#   venv/      a Python 3.9 venv with the wheels in wheels.lock installed with no index (image mode
#              only): built by the guest's own python3.9 in a chroot of --rootfs-tree, because the
#              guest's Python is the one that must run it
#   project/   the analysis project (this directory's project/, without bytecode or caches)
#   BUILD      what was built: the dataset's size, rows and sha256 (over the shard bytes in
#              order, what analyze.py prints), the wheel check and the venv's versions
# The rig copies the template once per session key, as it does E15's.
#
# Usage:
#   sudo experiments/e17-lease/workload/build_pycache_workspace.sh [OPTS] --wheels DIR --rootfs-tree PATH OUT_IMG
#                                                    sparse ext4 image (Linux, root; the rig)
#   experiments/e17-lease/workload/build_pycache_workspace.sh [OPTS] --dir OUTDIR
#                                                    stage data/ and project/ only (any OS, no
#                                                    root); BUILD records "venv: skipped (no rootfs)"
#
# Options (before OUT_IMG / --dir):
#   --image-mb M         image size in MiB (default 1536, E15_P_IMAGE_MB); D + 512 <= M (the venv
#                        is about 350 MiB unpacked, plus ext4's own metadata)
#   --dataset-mib D      dataset size in MiB (default 256)
#   --dataset-seed S     the dataset's seed (default 1)
#   --wheels DIR         the wheels named in wheels.lock; every one is sha256-checked against the
#                        lock before anything is built (also in --dir mode, which then only checks)
#   --rootfs-tree PATH   the guest's root filesystem tree, e.g. the E15 snapshot's rootfs mounted
#                        read-only; it must hold /usr/bin/python3.9, /workspace, /mnt, /tmp, /dev
#                        and /proc, and its python3.9 must import venv and ensurepip (checked
#                        in a chroot before any image work). Nothing is written to it: the
#                        chroot's /workspace, /mnt (the wheels, read-only), /tmp (a tmpfs), /dev
#                        and /proc are mounts over it.
#
# Environment:
#   E17_WS_UID/GID    owner of the tree inside the image (default 0:0, the guest agent's uid, as
#                     in E15's template)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LOCK="$HERE/wheels.lock"
IMG_MIB=1536
DATA_MIB=256
DATA_SEED=1
WHEELS=""
ROOTFS=""
WS_UID="${E17_WS_UID:-0}"
WS_GID="${E17_WS_GID:-0}"

die() {
  echo "build_pycache_workspace.sh: $*" >&2
  exit 1
}

usage() {
  echo "usage: $0 [--image-mb M] [--dataset-mib D] [--dataset-seed S] [--wheels DIR] [--rootfs-tree PATH] OUT_IMG | --dir OUTDIR" >&2
  exit 1
}

# write_dataset ROOT: ROOT/data/shard-NNN.csv, DATA_MIB MiB in all. A shard is a header line and
# fixed-width rows "gg,dd.ddd,dd.ddd,dd.ddd,dd.ddd,dd.ddd,dd.ddd": a group id 00..99 and six
# values 00.000..65.535, from 14 bytes of the shard's SHAKE-256 stream per row (one little-endian
# uint16 per field). Each shard is as many whole rows as fit its size. Prints "SHARDS ROWS SHA256",
# the sha256 over every shard's bytes in order.
write_dataset() {
  python3 - "$1/data" "$DATA_MIB" "$DATA_SEED" <<'PY'
import array, hashlib, os, sys
out, mib, seed = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
SHARD_MIB = 32
HEADER = b"g,x0,x1,x2,x3,x4,x5\n"
FIELDS = 7
ROW = 2 + 7 * (FIELDS - 1) + 1
GROUP = [b"%02d" % (v % 100) for v in range(1 << 16)]
VALUE = [b",%02d.%03d" % divmod(v, 1000) for v in range(1 << 16)]
os.makedirs(out)
digest, rows_all, sizes = hashlib.sha256(), 0, []
left = mib
while left > 0:
    sizes.append(min(SHARD_MIB, left))
    left -= sizes[-1]
for n, size in enumerate(sizes):
    rows = ((size << 20) - len(HEADER)) // ROW
    words = array.array("H", hashlib.shake_256(b"e17-pycache/%d/%d" % (seed, n)).digest(rows * FIELDS * 2))
    if sys.byteorder == "big":
        words.byteswap()
    lines = [HEADER]
    for r in range(0, rows * FIELDS, FIELDS):
        g, a, b, c, d, e, f = words[r:r + FIELDS]
        lines.append(b"".join((GROUP[g], VALUE[a], VALUE[b], VALUE[c], VALUE[d], VALUE[e], VALUE[f], b"\n")))
    blob = b"".join(lines)
    path = os.path.join(out, "shard-%03d.csv" % n)
    with open(path + ".tmp", "wb") as fh:
        fh.write(blob)
    os.chmod(path + ".tmp", 0o444)
    os.rename(path + ".tmp", path)
    digest.update(blob)
    rows_all += rows
print(len(sizes), rows_all, digest.hexdigest())
PY
}

# check_wheels: every wheel in wheels.lock is in WHEELS with the locked sha256. Prints the count.
check_wheels() {
  python3 - "$LOCK" "$WHEELS" <<'PY'
import hashlib, os, sys
lock, wheels = sys.argv[1], sys.argv[2]
bad, n = [], 0
for line in open(lock):
    if not line.strip() or line.startswith("#"):
        continue
    want, name = line.split()
    n += 1
    path = os.path.join(wheels, name)
    if not os.path.isfile(path):
        bad.append(f"{name}: missing from {wheels}")
        continue
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    if h.hexdigest() != want:
        bad.append(f"{name}: sha256 {h.hexdigest()}, wheels.lock pins {want}")
if bad:
    sys.exit("build_pycache_workspace.sh: wheel check failed:\n  " + "\n  ".join(bad))
print(n)
PY
}

# requirements: wheels.lock as a pip requirements file in hash-checking mode (name==version from
# each wheel's filename), so pip checks every hash a second time and installs nothing else.
requirements() {
  python3 - "$LOCK" <<'PY'
import sys
for line in open(sys.argv[1]):
    if line.strip() and not line.startswith("#"):
        sha, name = line.split()
        dist, version = name.split("-")[:2]
        print(f"{dist}=={version} --hash=sha256:{sha}")
PY
}

# stage ROOT: ROOT/project, ROOT/data and ROOT/BUILD's dataset and wheel lines.
stage() {
  local root="$1" ds
  mkdir -p "$root/project"
  tar -C "$HERE/project" --exclude=__pycache__ --exclude=.pytest_cache --exclude='*.pyc' -cf - . |
    tar -C "$root/project" --no-same-owner -xf -
  read -r -a ds < <(write_dataset "$root")
  {
    echo "template: pycache"
    echo "dataset_mib: $DATA_MIB"
    echo "dataset_seed: $DATA_SEED"
    echo "dataset_shards: ${ds[0]}"
    echo "dataset_rows: ${ds[1]}"
    echo "dataset_sha256: ${ds[2]}"
    if [ -n "$WHEELS" ]; then
      echo "wheels: $WHEEL_COUNT verified (wheels.lock sha256 $(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$LOCK"))"
    else
      echo "wheels: not checked (no --wheels)"
    fi
  } >"$root/BUILD"
}

while [ $# -gt 0 ]; do
  case "$1" in
  --image-mb | --dataset-mib | --dataset-seed)
    if [ $# -lt 2 ] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
      echo "build_pycache_workspace.sh: $1 needs a non-negative integer" >&2
      usage
    fi
    case "$1" in
    --image-mb) IMG_MIB=$((10#$2)) ;;
    --dataset-mib) DATA_MIB=$((10#$2)) ;;
    --dataset-seed) DATA_SEED=$((10#$2)) ;;
    esac
    shift 2
    ;;
  --wheels | --rootfs-tree)
    if [ $# -lt 2 ] || [ ! -d "$2" ]; then die "$1 needs an existing directory"; fi
    case "$1" in
    --wheels) WHEELS="$(cd "$2" && pwd)" ;;
    --rootfs-tree) ROOTFS="$(cd "$2" && pwd)" ;;
    esac
    shift 2
    ;;
  *) break ;;
  esac
done
[ "$DATA_MIB" -gt 0 ] || die "--dataset-mib must be >= 1"

[ $# -ge 1 ] || usage
WHEEL_COUNT=0
case "$1" in
--dir)
  [ $# -eq 2 ] || usage
  OUT="$2"
  if [ -e "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ]; then
    die "$OUT exists and is not empty"
  fi
  [ -z "$WHEELS" ] || WHEEL_COUNT="$(check_wheels)"
  mkdir -p "$OUT"
  stage "$OUT"
  echo "venv: skipped (no rootfs)" >>"$OUT/BUILD"
  echo "staged $OUT (dataset $DATA_MIB MiB seed $DATA_SEED, $(sed -n 's/^dataset_shards: //p' "$OUT/BUILD") shards)"
  exit 0
  ;;
-h | --help) usage ;;
-*) usage ;;
esac

[ $# -eq 1 ] || usage
OUT_IMG="$1"
[ "$(id -u)" = 0 ] || die "image mode must run as root (loop mount, chroot, file ownership)"
[ -n "$WHEELS" ] || die "image mode needs --wheels DIR (the venv's wheels)"
[ -n "$ROOTFS" ] || die "image mode needs --rootfs-tree PATH (the guest rootfs that builds the venv)"
[ $((DATA_MIB + 512)) -le "$IMG_MIB" ] ||
  die "--dataset-mib $DATA_MIB does not fit a $IMG_MIB MiB image with the venv (need D + 512 <= M)"
[ ! -e "$OUT_IMG" ] || die "$OUT_IMG exists; remove it or choose another path"
for p in usr/bin/python3.9 workspace mnt tmp dev proc; do
  [ -e "$ROOTFS/$p" ] || die "--rootfs-tree $ROOTFS has no /$p"
done
# The guest's python3.9 must be able to make a venv with pip in it; check before any image work.
# A clean environment as in_guest below, and -B: no bytecode written into the rootfs tree.
chroot "$ROOTFS" /usr/bin/env -i PATH=/usr/bin:/bin HOME=/tmp TMPDIR=/tmp /usr/bin/python3.9 -B -c 'import venv, ensurepip' ||
  die "--rootfs-tree $ROOTFS: /usr/bin/python3.9 cannot import venv and ensurepip (chroot); it cannot build the venv"
WHEEL_COUNT="$(check_wheels)"

# The chroot's mounts, innermost last; cleanup unmounts them in reverse, then the image. Checked
# before the trap is set, so a refusal here never unmounts another build's mounts.
CHROOT_MOUNTS=("$ROOTFS/workspace" "$ROOTFS/mnt" "$ROOTFS/tmp" "$ROOTFS/dev" "$ROOTFS/proc")
for m in "${CHROOT_MOUNTS[@]}"; do
  ! mountpoint -q "$m" || die "$m is already a mount point (another build running?)"
done

# Build under a temp name next to the target and rename at the end, so a half-built image is
# never at OUT_IMG (the worker would take any ext4 file there as a finished template).
TMP_IMG="$(mktemp "$OUT_IMG.build-XXXXXX")"
MNT="$(mktemp -d)"
cleanup() {
  local i
  for ((i = ${#CHROOT_MOUNTS[@]} - 1; i >= 0; i--)); do
    if mountpoint -q "${CHROOT_MOUNTS[$i]}"; then umount "${CHROOT_MOUNTS[$i]}" || true; fi
  done
  if mountpoint -q "$MNT"; then umount "$MNT" || true; fi
  rmdir "$MNT" 2>/dev/null || true
  rm -f "$TMP_IMG"
}
trap cleanup EXIT

truncate -s "${IMG_MIB}M" "$TMP_IMG"
# Initialise the inode tables and journal now, so no guest's ext4lazyinit writes them later -- each
# such write would un-share blocks of a reflinked per-session copy (as E15's data.bin image).
mkfs.ext4 -F -q -E "lazy_itable_init=0,lazy_journal_init=0" "$TMP_IMG"
mount -o loop "$TMP_IMG" "$MNT"
stage "$MNT"
requirements >"$MNT/.requirements.txt"

# The venv is built where the guest will see it, /workspace/venv, so its paths (pyvenv.cfg, the
# scripts' shebangs) are the guest's. --system-site-packages: the guest rootfs carries pytest in
# its system site-packages (E15's setup.sh step 7) and the library runs `venv/bin/python -m
# pytest`; --ignore-installed puts every locked wheel in the venv even if the rootfs has one.
mount --bind "$MNT" "$ROOTFS/workspace"
mount --bind -o ro "$WHEELS" "$ROOTFS/mnt"
mount -o remount,bind,ro "$ROOTFS/mnt"
mount -t tmpfs -o size=512m tmpfs "$ROOTFS/tmp"
mount --bind /dev "$ROOTFS/dev"
mount -t proc proc "$ROOTFS/proc"
in_guest() { chroot "$ROOTFS" /usr/bin/env -i PATH=/usr/bin:/bin HOME=/tmp TMPDIR=/tmp "$@"; }
in_guest /usr/bin/python3.9 -m venv --system-site-packages /workspace/venv
in_guest /workspace/venv/bin/python -m pip install -q --no-index --no-cache-dir --disable-pip-version-check \
  --ignore-installed --require-hashes --find-links /mnt -r /workspace/.requirements.txt
venv_line="$(in_guest /workspace/venv/bin/python -c '
import platform, numpy, pandas, scipy, sklearn, pytest
print("python %s, numpy %s, pandas %s, scipy %s, scikit-learn %s, pytest %s" % (platform.python_version(),
      numpy.__version__, pandas.__version__, scipy.__version__, sklearn.__version__, pytest.__version__))')"
rm -f "$MNT/.requirements.txt"
for ((i = ${#CHROOT_MOUNTS[@]} - 1; i >= 0; i--)); do umount "${CHROOT_MOUNTS[$i]}"; done
echo "venv: $venv_line" >>"$MNT/BUILD"

chown -R "$WS_UID:$WS_GID" "$MNT/project" "$MNT/data" "$MNT/venv" "$MNT/BUILD"
sync
umount "$MNT"
mv "$TMP_IMG" "$OUT_IMG"
echo "built $OUT_IMG (${IMG_MIB} MiB sparse, dataset $DATA_MIB MiB seed $DATA_SEED, $venv_line, $(du -k "$OUT_IMG" | cut -f1) KiB used)"
