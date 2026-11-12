#!/usr/bin/env bash
# Download the raw experiment archives from the data-v1 release, verify their sha256, and
# unpack them into the experiment directories. See data/MANIFEST.md.
#
# The archives were built before the 2026-11 experiments/e02-e05-harness/ reorganization, so their members
# still carry the old paths (experiments/e15-session-density/results/..., experiments/e16-low-duty/results/...); dest_of/member_of map them.
#   data/fetch-data.sh [name ...]     names: e15-metal e16-resident-inf e16-sbx (default: all)
set -euo pipefail

REPO="${MOCA_EXPERIMENTS_REPO:-rossoctl/moca-experiments}"
TAG="${DATA_TAG:-data-v1}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

sha_of() {
  case "$1" in
    e15-metal) echo 99cfe2d0692600d264ea52d8c5e24c7bfdd4147b01dc02207bd50bb7f7b7dacb ;;
    e16-resident-inf) echo 01719466c3716608e9db65a2dff068dc7c9f6965ebbd336ab825283eae7eb311 ;;
    e16-sbx) echo 3fc449e171882cf1eabd43c0006226387b4c91ad3938c812f410c5dc2a35df81 ;;
    *) return 1 ;;
  esac
}

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

# dest_of <name>: where the archive's tree goes; member_of <name>: its path inside the archive.
dest_of() {
  case "$1" in
    e15-metal) echo experiments/e15-session-density/results/metal ;;
    e16-resident-inf) echo experiments/e16-low-duty/results/resident-inf ;;
    e16-sbx) echo experiments/e16-low-duty/results/sbx ;;
  esac
}
member_of() {
  case "$1" in
    e15-metal) echo e15/results/metal ;;
    e16-resident-inf) echo e16/results/resident-inf ;;
    e16-sbx) echo e16/results/sbx ;;
  esac
}

names=("$@")
[ ${#names[@]} -gt 0 ] || names=(e15-metal e16-resident-inf e16-sbx)

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for n in "${names[@]}"; do
  want="$(sha_of "$n")" || { echo "unknown archive: $n" >&2; exit 2; }
  f="moca-experiments-$n-raw.tar.gz"
  echo "fetching $f"
  curl -fL --retry 3 -o "$tmp/$f" "https://github.com/$REPO/releases/download/$TAG/$f"
  got="$(sha256 "$tmp/$f")"
  if [ "$got" != "$want" ]; then
    echo "checksum mismatch for $f: expected $want, got $got" >&2
    exit 1
  fi
  mkdir -p "$tmp/x"
  tar -xzf "$tmp/$f" -C "$tmp/x"
  dest="$(dest_of "$n")"; member="$(member_of "$n")"
  mkdir -p "$ROOT/$dest"
  cp -R "$tmp/x/$member/." "$ROOT/$dest/"
  echo "extracted $n to $dest"
done
