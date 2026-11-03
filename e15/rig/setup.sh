#!/usr/bin/env bash
# shellcheck disable=SC2024  # logs are the login user's files on purpose; sudo runs the command only
# e15/rig/setup.sh -- bring the E15 stack up on the shared rig (SPEC §4, §6.6, §7). Idempotent.
#
# Run as the rig's login user (ec2-user, passwordless sudo) from the copied tree:
#   bash /srv/e15/src/e15/rig/setup.sh
#
# Inputs, staged before the first run (rsync from the laptop):
#   /srv/e15/src/e15/              this repo's e15/ directory
#   /srv/e15/corpora/<point>/      corpus.jsonl + corpus-report.json per point
#                                  (default short long no-infra no-chains smoke)
#   /srv/e15/wheels/*.whl          pytest and its py3.9 dependencies (pip download on the laptop)
#   /srv/e15/project-src/          optional: a clone holding project.lock's commit (E15_PROJECT_SRC)
#
# What it does, in order, each step logged to ~/e15-manifest.md with its undo:
#   1. guards: ports 9643/9644/9645/9646/6400 free, nothing under /opt/serverless-harness
#   2. stops microvm-worker.service and docker containers bench-cp, bench-redis (UNDO: start)
#   3. /srv/e15 tree; tokens in /srv/e15/secrets (0600)
#   4. e15.slice (MemoryMax = host RAM - 3 GiB, MemoryHigh = MemoryMax - 1 GiB) and e15-vms.slice,
#      as unit files (UNDO: remove)
#   5. moca v0.9.0 clone at /srv/e15/moca (+ pi-fork submodule, npm ci + build), pnpm install
#      --frozen-lockfile
#   6. builds: stock microvm-worker, null-responder, e15-driver; resident build (resident/apply.sh)
#   7. rootfs = /srv/snapshots/default's rootfs tree + pytest wheels; build-snapshot.sh
#      --guest-ram-mb 1024 --image e15 --out /srv/e15/snapshots/e15; pytest checked in a VM
#   8. workspace templates (commands/build_workspace.sh, points.sh): /srv/e15/template/workspace.img
#      (256 MiB) and /srv/e15/template-mem512/workspace.img (1024 MiB, 512 MiB data.bin, seed 1)
#   8b. disk_read_max_mbs in /srv/e15/state: dd iflag=direct read of a 2 GiB file, once
#   9. Redis (podman, 127.0.0.1:6400, --save '') and the relay (127.0.0.1:9643 attach, :9644 exec)
#
# Built artifacts (step 5-8) are stamped in /srv/e15/state and skipped when unchanged; they are
# PURGE lines in the manifest (teardown.sh --purge), so a plain teardown keeps them for the next
# setup. Services and host state are UNDO lines (teardown.sh).
#
# Host profile (lib.sh, E15_HOST_PROFILE; SPEC §13). The above is aws-prelim, the default. With
# E15_HOST_PROFILE=fresh-metal (a fresh dedicated Ubuntu host, after bootstrap.sh):
#   1-2. no shared-host guards and nothing to pause; every path must be under /srv/e15
#   5-6. pnpm, Node and Go are bootstrap.sh's (/srv/e15/bin, /srv/e15/node, /srv/e15/go-toolchain)
#   7.   guest kernel = the pinned Firecracker CI kernel (pins.sh, sha256-checked); rootfs =
#        moca v0.9.0's deploy/microvm/build-rootfs.sh over the pinned sandbox image (by digest),
#        then the same pytest wheels and gitconfig; each artifact's sha256 in state/artifacts
#   7b.  workspace copies: a reflink probe under /srv/e15; on a filesystem without reflink (ext4)
#        sparse copies, state/workspace_copy=sparse
#   8b.  disk read max: 4 parallel direct-I/O readers of separate 2 GiB files, summed
#        (state/disk_read_max_mbs) and the single stream (state/disk_read_single_mbs)
#   9.   Redis by digest, in podman storage under /srv/e15/containers
set -euo pipefail
E15_PROG=setup.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
# shellcheck source=points.sh
. "$HERE/points.sh"

[ "$(id -u)" != 0 ] || die "run as the login user, not root (sudo -n is used per step)"
sudo -n true 2>/dev/null || die "needs passwordless sudo"
[ -d "$E15_SRC" ] || die "no $E15_SRC: rsync e15/ there first"
case "$HERE" in "$E15_SRC"/rig) ;; *) die "run the staged copy: $E15_SRC/rig/setup.sh (not $HERE)" ;; esac
METAL=0
if [ "$E15_HOST_PROFILE" = fresh-metal ]; then
  METAL=1
  e15_require_pins
  for t in "$E15_GO_ROOT/bin/go" "$E15_NODE_ROOT/bin/node" "$E15_BIN/pnpm" "$E15_FIRECRACKER" "$E15_JAILER" "$E15_BIN/grpcurl"; do
    [ -x "$t" ] || die "fresh-metal: no $t; run bootstrap.sh first"
  done
  command -v podman >/dev/null || die "fresh-metal: no podman; run bootstrap.sh first"
  id -nG | tr ' ' '\n' | grep -qx kvm || log "note: $(id -un) is not yet in group kvm in this shell (bootstrap added it; the units run as root)"
  # Every tool the rig calls is bootstrap.sh's first.
  PATH=$(e15_path)
  export PATH
  mapfile -t UENV < <(e15_userenv user)
  export "${UENV[@]}"
fi

refuse_shared_paths "$E15_ROOT" "$E15_MANIFEST" "$E15_SNAPDIR" "$E15_WORKSPACES" "$E15_JAIL"
m_init

# A setup whose services are already up is a no-op for them (second setup is idempotent).
already_up=0
if unit_active "$E15_UNIT_RELAY" && e15_podman container exists "$E15_REDIS_CTR" 2>/dev/null; then
  already_up=1
fi
if [ "$already_up" = 0 ]; then
  for unit in "$E15_UNIT_RELAY" "$E15_UNIT_WORKER" "$E15_UNIT_NULL"; do
    unit_active "$unit" && die "$unit is running without the full stack; run teardown.sh first"
  done
  # A partial setup may have left E15's own Redis up; its port is then ours, not a conflict.
  ports=("${E15_PORTS[@]}")
  if e15_podman container exists "$E15_REDIS_CTR" 2>/dev/null; then
    ports=("$E15_PORT_ATTACH" "$E15_PORT_EXEC" "$E15_PORT_NULL" "$E15_PORT_STATS")
  fi
  refuse_ports "${ports[@]}"
fi
m_section Setup
log "setup: manifest $E15_MANIFEST (already_up=$already_up)"

# --- 2. pause the host's own worker and the bench containers ---------------------------------
# The pre-setup state teardown.sh verifies against: one PRESTATE line per cycle (m_prestate). A
# second setup in the same cycle sees E15's own stops, so only the first one is written.
# fresh-metal: nothing of the shared rig exists there; nothing to pause.
if [ "$METAL" = 1 ]; then
  m_prestate "fresh-metal: no host services to pause"
else
if unit_active "$E15_HOST_WORKER"; then hw=active; else hw=inactive; fi
bench=()
for c in "${E15_BENCH_CTRS[@]}"; do
  bench+=("$c=$(sudo -n docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || echo absent)")
done
m_prestate "$E15_HOST_WORKER=$hw ${bench[*]}"
if unit_active "$E15_HOST_WORKER"; then
  sctl stop "$E15_HOST_WORKER"
  m_change "stopped $E15_HOST_WORKER (SPEC §4: paused for the run)" "sudo -n systemctl start $E15_HOST_WORKER"
  log "stopped $E15_HOST_WORKER"
else
  m_note "$E15_HOST_WORKER already inactive (nothing to undo)"
fi
for c in "${E15_BENCH_CTRS[@]}"; do
  if [ "$(sudo -n docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || echo absent)" = true ]; then
    sudo -n docker stop "$c" >/dev/null
    m_change "docker stop $c (kept, not removed)" "sudo -n docker start $c"
    log "stopped container $c"
  else
    m_note "container $c not running (nothing to undo)"
  fi
done
fi

# --- 3. tree and secrets ---------------------------------------------------------------------
for d in "$E15_BIN" "$E15_SECRETS" "$E15_STATE" "$E15_LOGS" "$E15_RUNS" "$E15_WORKSPACES" \
  "$E15_JAIL" "$E15_ROOT/go" "$E15_ROOT/template" "$E15_ROOT/template-mem512"; do
  if [ ! -d "$d" ]; then
    sudo -n mkdir -p "$d"
    sudo -n chown "$(id -un):$(id -gn)" "$d"
  fi
done
m_has "PURGE: sudo -n rm -rf $E15_ROOT" ||
  m_purge "created $E15_ROOT (all E15 files)" "sudo -n rm -rf $E15_ROOT"
chmod 0700 "$E15_SECRETS"
# fresh-metal: the profile is recorded (bootstrap.sh did already); lib.sh then defaults to it and
# refuses another (rung, teardown). aws-prelim records nothing: it is the default.
if [ "$METAL" = 1 ] && [ "$(cat "$E15_STATE/host_profile" 2>/dev/null || true)" != fresh-metal ]; then
  echo fresh-metal >"$E15_STATE/host_profile"
fi
gen_token() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
if [ ! -s "$E15_SECRETS/exec.token" ]; then
  (umask 077 && gen_token >"$E15_SECRETS/exec.token" && gen_token >"$E15_SECRETS/sandbox.token")
  m_note "generated relay tokens in $E15_SECRETS (0600; removed with $E15_ROOT)"
fi
(
  umask 077
  printf 'SH_RELAY_TOKEN=%s\nMOCA_RELAY_EXEC_TOKEN=%s\nSH_RELAY_PORT=%s\nMOCA_RELAY_EXEC_ADDR=127.0.0.1:%s\nREDIS_URL=redis://127.0.0.1:%s\nSH_SANDBOX_MAX_INFLIGHT=1024\nNODE_ENV=production\n' \
    "$(cat "$E15_SECRETS/sandbox.token")" "$(cat "$E15_SECRETS/exec.token")" \
    "$E15_PORT_ATTACH" "$E15_PORT_EXEC" "$E15_PORT_REDIS" >"$E15_SECRETS/relay.env"
  printf 'SANDBOX_TOKEN=%s\n' "$(cat "$E15_SECRETS/sandbox.token")" >"$E15_SECRETS/worker.env"
)

# --- 4. slices -------------------------------------------------------------------------------
mem_kb=$(awk '/^MemTotal:/{print $2}' "$E15_MEMINFO")
read -r slice_max slice_high < <(e15_slice_limits "$mem_kb")
want_slice=$(printf '[Unit]\nDescription=E15 experiment (moca-experiments)\n\n[Slice]\nMemoryAccounting=yes\nCPUAccounting=yes\nIOAccounting=yes\nTasksAccounting=yes\nMemoryMax=%s\nMemoryHigh=%s\nMemorySwapMax=0\n' "$slice_max" "$slice_high")
want_vms=$(printf '[Unit]\nDescription=E15 worker and its microVMs\n\n[Slice]\nMemoryAccounting=yes\nCPUAccounting=yes\nTasksAccounting=yes\nMemorySwapMax=0\n')
for pair in "$E15_SLICE:$want_slice" "$E15_VM_SLICE:$want_vms"; do
  unit=${pair%%:*}
  body=${pair#*:}
  f=$E15_UNIT_DIR/$unit
  if [ ! -f "$f" ]; then
    printf '%s\n' "$body" | sudo -n tee "$f" >/dev/null
    m_change "created $f" "sudo -n systemctl stop $unit; sudo -n rm -f $f; sudo -n systemctl daemon-reload"
  elif [ "$(sudo -n cat "$f")" != "$body" ]; then
    printf '%s\n' "$body" | sudo -n tee "$f" >/dev/null
    m_note "rewrote $f (E15's own unit)"
  fi
done
sctl daemon-reload
sctl start "$E15_SLICE" "$E15_VM_SLICE"
m_note "e15.slice MemoryMax=$slice_max MemoryHigh=$slice_high bytes (host RAM $((mem_kb / 1024)) MiB - 3 GiB; MemoryMax - 1 GiB); undone with the slice unit's UNDO line"
# Pool cgroups need the cpu/memory/pids controllers enabled below e15-vms.slice.
sudo -n sh -c "echo '+memory +pids +cpu' > $E15_VMCG/cgroup.subtree_control" 2>/dev/null || true

# --- 5. moca v0.9.0 --------------------------------------------------------------------------
if [ ! -d "$E15_MOCA/.git" ]; then
  git clone --quiet --no-checkout "$E15_MOCA_URL" "$E15_MOCA"
  git -C "$E15_MOCA" -c advice.detachedHead=false checkout --quiet --detach "$E15_MOCA_PIN"
  m_note "cloned moca $E15_MOCA_PIN into $E15_MOCA"
fi
[ "$(git -C "$E15_MOCA" rev-parse HEAD)" = "$E15_MOCA_PIN" ] || die "$E15_MOCA is not at $E15_MOCA_PIN"
mapfile -t GOENV_USER < <(e15_goenv user)
if ! stamp_ok node "$E15_MOCA_PIN"; then
  log "moca: pi-fork submodule + npm ci + build, pnpm install --frozen-lockfile (logs in $E15_LOGS)"
  git -C "$E15_MOCA" submodule update --init --quiet pi-fork
  (cd "$E15_MOCA/pi-fork" && npm ci --no-audit --no-fund >"$E15_LOGS/pi-npm.log" 2>&1 &&
    for p in ai agent tui coding-agent; do npm run build -w "packages/$p" || exit 1; done >"$E15_LOGS/pi-build.log" 2>&1) ||
    die "pi-fork build failed; see $E15_LOGS/pi-*.log"
  (cd "$E15_MOCA" && pnpm install --frozen-lockfile --store-dir "$E15_ROOT/pnpm-store" >"$E15_LOGS/pnpm.log" 2>&1) ||
    die "pnpm install failed; see $E15_LOGS/pnpm.log"
  stamp_set node "$E15_MOCA_PIN"
  m_note "moca node deps installed (pnpm store $E15_ROOT/pnpm-store)"
fi

# --- 6. Go builds ----------------------------------------------------------------------------
src_key() { (cd "$E15_SRC" && find "$@" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16); }
if ! stamp_ok go-stock "$E15_MOCA_PIN"; then
  log "building stock microvm-worker and null-responder at $E15_MOCA_PIN"
  (cd "$E15_MOCA/remote-worker" && env "${GOENV_USER[@]}" go build -o "$E15_BIN/microvm-worker" ./cmd/microvm-worker &&
    env "${GOENV_USER[@]}" go build -o "$E15_BIN/null-responder" ./cmd/null-responder) >"$E15_LOGS/go-stock.log" 2>&1 ||
    die "stock build failed; see $E15_LOGS/go-stock.log"
  stamp_set go-stock "$E15_MOCA_PIN"
  m_note "built $E15_BIN/microvm-worker (sha256 $(sha256_of "$E15_BIN/microvm-worker"))"
fi
k=$(src_key driver)
if ! stamp_ok go-driver "$k"; then
  (cd "$E15_SRC/driver" && env "${GOENV_USER[@]}" go build -o "$E15_BIN/e15-driver" .) >"$E15_LOGS/go-driver.log" 2>&1 ||
    die "driver build failed; see $E15_LOGS/go-driver.log"
  stamp_set go-driver "$k"
  m_note "built $E15_BIN/e15-driver (src $k)"
fi
k=$(src_key resident)
if ! stamp_ok go-resident "$k"; then
  log "resident build: resident/apply.sh (patch tests run here; log $E15_LOGS/apply.log)"
  (env "${GOENV_USER[@]}" MOCA_SRC="$E15_MOCA" bash "$E15_SRC/resident/apply.sh" "$E15_ROOT/resident-work" "$E15_BIN") \
    >"$E15_LOGS/apply.log" 2>&1 || die "resident/apply.sh failed; see $E15_LOGS/apply.log"
  stamp_set go-resident "$k"
  m_note "built $E15_BIN/microvm-worker-resident (patch sha256 $(sha256_of "$E15_SRC/resident/resident.patch"))"
fi

# --- 7. rootfs + snapshot --------------------------------------------------------------------
compgen -G "$E15_ROOT/wheels/pytest-*.whl" >/dev/null || die "no pytest wheel in $E15_ROOT/wheels (pip download on the laptop)"
wheels_key=$( (cd "$E15_ROOT/wheels" && sha256sum ./*.whl) | sha256sum | cut -c1-16)
if [ "$METAL" = 1 ]; then
  # The guest kernel (pins.sh): fetched once, sha256-checked on every setup.
  KERNEL=$E15_ROOT/kernel/$E15_KERNEL_NAME
  mkdir -p "$(dirname "$KERNEL")"
  e15_fetch "$E15_KERNEL_URL" "$E15_KERNEL_SHA256" "$KERNEL"
  e15_artifact kernel "$E15_KERNEL_SHA256" "$E15_KERNEL_URL"
  snap_key="$E15_MOCA_PIN-$wheels_key-$(printf '%s' "$E15_SANDBOX_IMAGE_DIGEST" | cut -c8-23)-$(printf '%s' "$E15_KERNEL_SHA256" | cut -c1-16)"
else
  KERNEL=$E15_BASE_SNAPSHOT/kernel
  snap_key="$E15_MOCA_PIN-$wheels_key-$(sha256_of "$E15_BASE_SNAPSHOT/rootfs" | cut -c1-16)"
fi
if ! stamp_ok snapshot "$snap_key" || [ ! -f "$E15_SNAPDIR/$E15_SNAPIMG/manifest.json" ]; then
  tree=$E15_ROOT/rootfs-build/tree
  if [ "$METAL" = 1 ]; then
  log "rootfs: moca v0.9.0 build-rootfs.sh over $E15_SANDBOX_IMAGE + pytest wheels (log $E15_LOGS/build-rootfs.log)"
  sudo -n rm -rf "$E15_ROOT/rootfs-build"
  sudo -n mkdir -p "$E15_ROOT/rootfs-build"
  e15_podman pull "$E15_SANDBOX_IMAGE" >"$E15_LOGS/podman-pull-sandbox.log" 2>&1 ||
    die "podman pull $E15_SANDBOX_IMAGE failed; see $E15_LOGS/podman-pull-sandbox.log"
  sudo -n env CONTAINERS_STORAGE_CONF="$E15_PODMAN_CONF" PATH="$(e15_path)" \
    bash "$E15_MOCA/deploy/microvm/build-rootfs.sh" --out "$tree" --image "$E15_SANDBOX_IMAGE" \
    >"$E15_LOGS/build-rootfs.log" 2>&1 || die "build-rootfs.sh failed; see $E15_LOGS/build-rootfs.log"
  src_digest=$(sudo -n sed -n 's/^digest=//p' "$tree/etc/moca-rootfs-source")
  case "$src_digest" in
  "$E15_SANDBOX_IMAGE_DIGEST" | "$E15_SANDBOX_IMAGE_AMD64_DIGEST") ;;
  *) die "build-rootfs.sh exported digest '$src_digest', not the pinned $E15_SANDBOX_IMAGE_DIGEST" ;;
  esac
  e15_artifact sandbox-image "$src_digest" "$E15_SANDBOX_IMAGE"
  else
  log "rootfs: $E15_BASE_SNAPSHOT/rootfs (read-only loop mount) + pytest wheels"
  mnt=$(mktemp -d "$E15_ROOT/rootfs-build.mnt.XXXXXX")
  # A failure between mount and umount must not leave the loop device attached.
  trap 'mountpoint -q "$mnt" && sudo -n umount -d "$mnt"; rmdir "$mnt" 2>/dev/null || true' EXIT
  sudo -n rm -rf "$E15_ROOT/rootfs-build"
  sudo -n mkdir -p "$tree"
  sudo -n mount -o loop,ro "$E15_BASE_SNAPSHOT/rootfs" "$mnt"
  sudo -n cp -a "$mnt/." "$tree/"
  sudo -n umount -d "$mnt"
  rmdir "$mnt"
  trap - EXIT
  fi
  # The base image's init and agent are replaced by build-snapshot.sh's own.
  sp=$(sudo -n sh -c "ls -d $tree/usr/lib/python3.*/site-packages" | head -1)
  [ -n "$sp" ] || die "no python3 site-packages in the base rootfs"
  for w in "$E15_ROOT"/wheels/*.whl; do sudo -n unzip -q -o "$w" -d "$sp"; done
  sudo -n chroot "$tree" /usr/bin/python3 -m compileall -q "${sp#"$tree"}" >/dev/null 2>&1 || true
  sudo -n chroot "$tree" /usr/bin/python3 -m pytest --version >"$E15_LOGS/rootfs-pytest.log" 2>&1 ||
    die "pytest does not import in the staged rootfs (chroot); see $E15_LOGS/rootfs-pytest.log"
  # The guest's git identity (build-snapshot.sh's check_git_identity, #415): the base image
  # predates it; the same system gitconfig remote-worker/Dockerfile bakes.
  if ! sudo -n test -s "$tree/etc/gitconfig"; then
    printf '[user]\n\tname = MOCA sandbox\n\temail = sandbox@moca.invalid\n' | sudo -n tee "$tree/etc/gitconfig" >/dev/null
  fi
  sudo -n mkdir -p "$E15_SNAPDIR"
  sudo -n rm -rf "${E15_SNAPDIR:?}/$E15_SNAPIMG"
  log "build-snapshot.sh --guest-ram-mb 1024 --image $E15_SNAPIMG --out $E15_SNAPDIR/$E15_SNAPIMG (log $E15_LOGS/build-snapshot.log)"
  mapfile -t GOENV_ROOT < <(e15_goenv root)
  sudo -n env PATH="$(e15_path)" "${GOENV_ROOT[@]}" TMPDIR="$E15_ROOT" \
    bash "$E15_MOCA/deploy/microvm/build-snapshot.sh" \
    --kernel "$KERNEL" --rootfs "$tree" --agent "$E15_MOCA/remote-worker" \
    --image "$E15_SNAPIMG" --vmm firecracker --guest-ram-mb 1024 --out "$E15_SNAPDIR/$E15_SNAPIMG" \
    >"$E15_LOGS/build-snapshot.log" 2>&1 || die "build-snapshot.sh failed; see $E15_LOGS/build-snapshot.log"
  sudo -n rm -rf "$E15_ROOT/rootfs-build"
  stamp_set snapshot "$snap_key"
  if [ "$METAL" = 1 ]; then
    for f in rootfs agent; do
      e15_artifact "snapshot-$f" "$(sudo -n python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2] + "_sha256"])' "$E15_SNAPDIR/$E15_SNAPIMG/manifest.json" "$f")" "$E15_SNAPDIR/$E15_SNAPIMG/$f"
    done
  fi
  m_note "built snapshot $E15_SNAPDIR/$E15_SNAPIMG ($(sudo -n python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m["hash"], "guest", m["guest_ram_mb"], "MiB", ",".join(m["capabilities"]))' "$E15_SNAPDIR/$E15_SNAPIMG/manifest.json"))"
fi

# --- 8. workspace templates (points.sh): default, and mem512's (1024 MiB, 512 MiB data.bin) ------
tpath() { if [ "$METAL" = 1 ]; then e15_path; else echo "/usr/bin:/usr/sbin:/bin:/sbin"; fi; }
k=$(src_key commands)
while read -r tpoint; do
  e15_point "$tpoint" || die "points.sh: unknown template point $tpoint"
  tkey="$k-$E15_P_IMAGE_MB-$E15_P_DATASET_MIB-$E15_P_DATASET_SEED"
  [ "$tpoint" = default ] && tkey=$k # the default template's stamp as before (e2e check key)
  if ! stamp_ok "$E15_P_TEMPLATE_STAMP" "$tkey" || [ ! -f "$E15_P_TEMPLATE" ]; then
    sudo -n rm -f "$E15_P_TEMPLATE"
    psrc=()
    [ -d "$E15_ROOT/project-src" ] && psrc=(E15_PROJECT_SRC="$E15_ROOT/project-src")
    wsopts=(--image-mb "$E15_P_IMAGE_MB")
    [ "$E15_P_DATASET_MIB" = 0 ] || wsopts+=(--dataset-mib "$E15_P_DATASET_MIB" --dataset-seed "$E15_P_DATASET_SEED")
    wlog=$E15_LOGS/build_workspace-$tpoint.log
    [ "$tpoint" = default ] && wlog=$E15_LOGS/build_workspace.log
    sudo -n env "${psrc[@]}" PATH="$(tpath)" bash "$E15_SRC/commands/build_workspace.sh" \
      "${wsopts[@]}" "$E15_P_TEMPLATE" >"$wlog" 2>&1 || die "build_workspace.sh ($tpoint) failed; see $wlog"
    stamp_set "$E15_P_TEMPLATE_STAMP" "$tkey"
    m_note "built $E15_P_TEMPLATE ($(tail -1 "$wlog"))"
  fi
  [ "$METAL" = 1 ] && e15_artifact "$E15_P_TEMPLATE_STAMP" "$(sha256_of "$E15_P_TEMPLATE")" "$E15_P_TEMPLATE"
done < <(e15_templates)

# --- 7b. workspace copies: reflink where the filesystem has it, else sparse (fresh-metal) -----
# aws-prelim is XFS with reflink (rung.sh's default). fresh-metal probes once and records it.
if [ "$METAL" = 1 ] && [ ! -s "$E15_STATE/workspace_copy" ]; then
  mode=$(probe_reflink "$E15_STATE")
  printf '%s\n' "$mode" >"$E15_STATE/workspace_copy"
  m_note "workspace_copy=$mode (cp --reflink=always probe under $E15_STATE; $(stat -f -c %T "$E15_ROOT" 2>/dev/null || echo fs unknown))"
fi
if [ "$METAL" = 1 ] && [ "$(workspace_copy_mode)" = sparse ]; then
  # Sparse copies share no blocks: the operator checks each rung's cost against the free space
  # (rung.sh prints it again and refuses a rung whose copies alone do not fit). K = 16 is the floor.
  free_kb=$(df -Pk "$E15_ROOT" | awk 'NR==2 {print $4}')
  while read -r tpoint; do
    e15_point "$tpoint"
    tkb=$(du -k "$E15_P_TEMPLATE" | cut -f1)
    for n in "${E15_LADDER[@]}"; do
      log "sparse workspaces, point $tpoint: $(workspace_disk_estimate "$n" 16 "$E15_P_IMAGE_MB" "$tkb" "$free_kb" || true)"
    done
    m_note "sparse workspaces, point $tpoint at N=${E15_LADDER[-1]}: $(workspace_disk_estimate "${E15_LADDER[-1]}" 16 "$E15_P_IMAGE_MB" "$tkb" "$free_kb" || echo "(does not fit)")"
  done < <(e15_templates)
fi

# --- 8b. the volume's sequential read throughput (record.py's disk_io binding), once -----------
if [ "$METAL" = 1 ] && [ ! -s "$E15_STATE/disk_read_max_mbs" ]; then
  log "measuring direct-I/O read throughput of the /srv/e15 volume: 1 stream, then 4 parallel (2 GiB files)"
  one=$(measure_disk_read "$E15_STATE/.disk-read-probe-1" 2048) || die "disk read measurement (single) failed"
  par=$(measure_disk_read_parallel "$E15_STATE/.disk-read-probe-p" 4 2048) || die "disk read measurement (parallel) failed"
  printf '%s\n' "$one" >"$E15_STATE/disk_read_single_mbs"
  printf '%s\n' "$par" >"$E15_STATE/disk_read_max_mbs"
  m_note "disk_read_max_mbs=$par (4 parallel dd iflag=direct bs=4M readers of separate 2 GiB files, summed); disk_read_single_mbs=$one (one stream); files removed"
fi
if [ ! -s "$E15_STATE/disk_read_max_mbs" ]; then
  log "measuring sequential direct-I/O read throughput of the /srv/e15 volume (2 GiB file)"
  mbs=$(measure_disk_read "$E15_STATE/.disk-read-probe" 2048) || die "disk read measurement failed"
  printf '%s\n' "$mbs" >"$E15_STATE/disk_read_max_mbs"
  m_note "disk_read_max_mbs=$mbs (dd iflag=direct bs=4M, 2 GiB under $E15_STATE; file removed)"
fi

# Listed leftovers: things outside /srv/e15 E15's builds touch that no UNDO removes.
if [ "$METAL" = 1 ]; then
  # npm, corepack and podman storage are all under /srv/e15 (lib.sh e15_userenv, storage.conf);
  # bootstrap.sh listed its apt packages.
  left_list=("systemd journal lines of E15's transient units (rotated by journald)")
else
  left_list=("npm cache ~/.npm (pi-fork npm ci; shared with other users of npm on this host)"
    "podman image $E15_REDIS_IMAGE (pre-existing on this host; E15 pulls nothing new)")
fi
for left in "${left_list[@]}"; do
  m_has "LEFTOVER: $left" || m_note "LEFTOVER: $left"
done

# --- 9. Redis and the relay ------------------------------------------------------------------
if ! e15_podman container exists "$E15_REDIS_CTR" 2>/dev/null; then
  # Host network, bound to loopback: no port-forward NAT rules, and the relay's systemd IP fence
  # (IPAddressAllow=localhost) admits it, which a DNAT to the podman bridge would not.
  e15_podman run -d --name "$E15_REDIS_CTR" --network host \
    "$E15_REDIS_IMAGE" redis-server --bind 127.0.0.1 --port "$E15_PORT_REDIS" --save '' --appendonly no >/dev/null
  m_change "podman run $E15_REDIS_CTR (host network, 127.0.0.1:$E15_PORT_REDIS, --save '')" \
    "$(e15_podman_str) rm -f $E15_REDIS_CTR"
  wait_for 30 port_listening "$E15_PORT_REDIS" || die "Redis did not listen on 127.0.0.1:$E15_PORT_REDIS"
fi
if ! unit_active "$E15_UNIT_RELAY"; then
  # UNDO recorded BEFORE the start: a check that fails after systemd-run leaves a recorded unit.
  m_change "starting $E15_UNIT_RELAY (127.0.0.1:$E15_PORT_ATTACH attach, 127.0.0.1:$E15_PORT_EXEC exec)" \
    "sudo -n systemctl stop $E15_UNIT_RELAY 2>/dev/null; sudo -n systemctl reset-failed $E15_UNIT_RELAY 2>/dev/null; true"
  start_relay
  sleep 3
  if grep -q 'redis client error' "$E15_LOGS/relay.log"; then
    stop_e15_unit "$E15_UNIT_RELAY"
    die "the relay cannot reach Redis on 127.0.0.1:$E15_PORT_REDIS (relay stopped); see $E15_LOGS/relay.log"
  fi
fi

# The rung units are E15's own; a teardown stops whatever a rung left behind.
if [ "$already_up" = 0 ]; then
  m_change "rung units ($E15_UNIT_WORKER, $E15_UNIT_NULL) and their VM cgroups may exist from here on" \
    "bash -c '. $E15_SRC/rig/lib.sh; stop_rung_units'"
fi

# --- 10. end-to-end check: a stock worker, one Exec per tool the library leans on ------------
check_key="$(sha256_of "$E15_SNAPDIR/$E15_SNAPIMG/manifest.json" | cut -c1-16)-$(cat "$E15_STATE/template")"
if ! stamp_ok e2e "$check_key"; then
  d=$E15_ROOT/logs/e2e
  rm -rf "$d"
  mkdir -p "$d"
  sudo -n rm -rf "$E15_WORKSPACES/e15-e2e"
  sudo -n mkdir -m 0700 "$E15_WORKSPACES/e15-e2e"
  sudo -n cp "$(workspace_cp_flag "$(workspace_copy_mode)")" "$E15_TEMPLATE" "$E15_WORKSPACES/e15-e2e/workspace.img"
  start_worker sbx "$d"
  e2e_ok=1
  for c in 'python3 -m pytest --version' 'cd project && git status --porcelain && git rev-parse HEAD' \
    'ls scripts | head -3' 'cd project && python3 -m pytest -q -p no:cacheprovider tests/test_more.py -x -k chunked'; do
    if out=$(gexec e15-e2e "$c" 2>&1); then
      printf '$ %s\n%s\n' "$c" "$out" >>"$d/e2e.log"
    else
      printf '$ %s\nFAILED (exit %s)\n%s\n' "$c" "$?" "$out" >>"$d/e2e.log"
      e2e_ok=0
    fi
  done
  stop_rung_units
  sudo -n rm -rf "$E15_WORKSPACES/e15-e2e"
  [ "$e2e_ok" = 1 ] || die "end-to-end check failed; see $d/e2e.log"
  stamp_set e2e "$check_key"
  m_note "end-to-end check passed in a booted VM: $(head -2 "$d/e2e.log" | tail -1)"
fi

log "setup: done. relay $(ss -ltnH | awk '{print $4}' | grep -E ":($E15_PORT_ATTACH|$E15_PORT_EXEC)\$" | tr '\n' ' ')"
m_note "setup complete"
