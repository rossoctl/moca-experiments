#!/usr/bin/env bash
# E17 follow-up (lease spec v0.2 §16 item 5): build ONE test snapshot with a free-page-reporting balloon.
# Scratch only: a shared clone of the pinned moca checkout (pinned repo untouched), a rootfs tree copied
# from the e15 snapshot's rootfs, output to the NEW leaf /srv/e15/snapshots/e17-fpr (refused if present).
# Undo: sudo rm -rf /srv/e15/snapshots/e17-fpr /srv/e15/e17/fpr
set -euo pipefail
export E15_HOST_PROFILE=fresh-metal
# shellcheck source=/dev/null
source /srv/e15/src/e15/rig/lib.sh
OUT=/srv/e15/snapshots/e17-fpr
W=/srv/e15/e17/fpr
[ ! -e "$OUT" ] || { echo "refusing: $OUT exists"; exit 1; }
[ ! -e "$W" ] || { echo "refusing: $W exists"; exit 1; }
mkdir -p "$W"
PIN=$(git -C /srv/e15/moca rev-parse HEAD)
git clone --quiet --shared --no-checkout /srv/e15/moca "$W/moca"
git -C "$W/moca" -c advice.detachedHead=false checkout --quiet --detach "$PIN"
F="$W/moca/deploy/microvm/build-snapshot.sh"
n=$(grep -n 'api_put "$api_sock" /machine-config' "$F" | head -1 | cut -d: -f1)
[ -n "$n" ] || { echo "no machine-config PUT in $F"; exit 1; }
# Insert after the 2-line machine-config PUT (Firecracker arm, pre-boot): the balloon, reporting only.
sed -i "$((n + 1))a\\  api_put \"\$api_sock\" /balloon '{\"amount_mib\":0,\"deflate_on_oom\":false,\"free_page_reporting\":true}'" "$F"
sed -n "$n,$((n + 3))p" "$F"
git -C "$W/moca" diff --stat
# Rootfs tree: the e15 snapshot's rootfs (already has pytest and the gitconfig), copied writable.
mnt=$(mktemp -d "$W/mnt.XXXXXX")
sudo -n mount -o loop,ro /srv/e15/snapshots/e15/rootfs "$mnt"
sudo -n mkdir -p "$W/rootfs-tree"
sudo -n cp -a "$mnt/." "$W/rootfs-tree/"
sudo -n umount -d "$mnt"; rmdir "$mnt"
mapfile -t GOENV_ROOT < <(e15_goenv root)
sudo -n env PATH="$(e15_path)" "${GOENV_ROOT[@]}" TMPDIR="$W" \
  bash "$F" --kernel /srv/e15/kernel/vmlinux-6.18.44 --rootfs "$W/rootfs-tree" --agent /srv/e15/moca/remote-worker \
  --image e17-fpr --vmm firecracker --guest-ram-mb 1024 --out "$OUT" >"$W/build-snapshot.log" 2>&1 ||
  { echo "build-snapshot.sh failed; tail:"; tail -30 "$W/build-snapshot.log"; exit 1; }
sudo -n rm -rf "$W/rootfs-tree"
sudo -n python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print("built", sys.argv[1], m["hash"][:16], "guest", m["guest_ram_mb"], "MiB")' "$OUT/manifest.json"
