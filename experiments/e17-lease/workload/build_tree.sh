#!/bin/sh
# experiments/e17-lease/workload/build_tree.sh DIR N -- the ownership-walk probe's workspace tree (PLAN-E17B Task 11,
# spec §7.4): N empty files in DIR/d0, DIR/d1, ..., 1000 per directory (the last one holds the rest), named f0..f999.
#
# The driver's `e15-driver ownwalk --files N` sends this script's text as its per-exec Exec (as root, before any
# set_mode): sh -c SCRIPT build_tree.sh DIR N. Deterministic: the same N gives the same names and sizes (every
# file is empty: the walk's cost is per inode, and empty files keep the workspace image small). POSIX sh with
# mkdir as the only external command, so it runs on the guest's shell whatever else its rootfs has.
# DIR must not exist. Prints "build_tree: files=N dirs=D dir=DIR" on success; exits non-zero on bad arguments or
# any failed write.
set -eu

[ $# -eq 2 ] || {
  echo "usage: build_tree.sh DIR N" >&2
  exit 2
}
dir=$1
n=$2
case "$n" in
'' | *[!0-9]* | 0*)
  echo "build_tree.sh: N must be a positive integer, got '$n'" >&2
  exit 2
  ;;
esac
if [ -e "$dir" ] || [ -L "$dir" ]; then
  echo "build_tree.sh: $dir exists: the tree is built in a fresh workspace only" >&2
  exit 1
fi
mkdir -p "$dir"

per=1000
made=0
d=0
while [ "$made" -lt "$n" ]; do
  mkdir "$dir/d$d"
  j=0
  while [ "$j" -lt "$per" ] && [ "$made" -lt "$n" ]; do
    : >"$dir/d$d/f$j"
    j=$((j + 1))
    made=$((made + 1))
  done
  d=$((d + 1))
done
echo "build_tree: files=$made dirs=$d dir=$dir"
