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
#   4. e15.slice (MemoryMax = host RAM - 2 GiB) and e15-vms.slice, as unit files (UNDO: remove)
#   5. moca v0.9.0 clone at /srv/e15/moca (+ pi-fork submodule, npm ci + build), pnpm install
#      --frozen-lockfile
#   6. builds: stock microvm-worker, null-responder, e15-driver; resident build (resident/apply.sh)
#   7. rootfs = /srv/snapshots/default's rootfs tree + pytest wheels; build-snapshot.sh
#      --guest-ram-mb 1024 --image e15 --out /srv/e15/snapshots/e15; pytest checked in a VM
#   8. workspace template /srv/e15/template/workspace.img (commands/build_workspace.sh)
#   9. Redis (podman, 127.0.0.1:6400, --save '') and the relay (127.0.0.1:9643 attach, :9644 exec)
#
# Built artifacts (step 5-8) are stamped in /srv/e15/state and skipped when unchanged; they are
# PURGE lines in the manifest (teardown.sh --purge), so a plain teardown keeps them for the next
# setup. Services and host state are UNDO lines (teardown.sh).
set -euo pipefail
E15_PROG=setup.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

[ "$(id -u)" != 0 ] || die "run as the login user, not root (sudo -n is used per step)"
sudo -n true 2>/dev/null || die "needs passwordless sudo"
[ -d "$E15_SRC" ] || die "no $E15_SRC: rsync e15/ there first"
case "$HERE" in "$E15_SRC"/rig) ;; *) die "run the staged copy: $E15_SRC/rig/setup.sh (not $HERE)" ;; esac

refuse_shared_paths "$E15_ROOT" "$E15_MANIFEST" "$E15_SNAPDIR" "$E15_WORKSPACES" "$E15_JAIL"
m_init

# A setup whose services are already up is a no-op for them (second setup is idempotent).
already_up=0
if unit_active "$E15_UNIT_RELAY" && sudo -n podman container exists "$E15_REDIS_CTR" 2>/dev/null; then
  already_up=1
fi
if [ "$already_up" = 0 ]; then
  for unit in "$E15_UNIT_RELAY" "$E15_UNIT_WORKER" "$E15_UNIT_NULL"; do
    unit_active "$unit" && die "$unit is running without the full stack; run teardown.sh first"
  done
  # A partial setup may have left E15's own Redis up; its port is then ours, not a conflict.
  ports=("${E15_PORTS[@]}")
  if sudo -n podman container exists "$E15_REDIS_CTR" 2>/dev/null; then
    ports=("$E15_PORT_ATTACH" "$E15_PORT_EXEC" "$E15_PORT_NULL" "$E15_PORT_STATS")
  fi
  refuse_ports "${ports[@]}"
fi
m_section Setup
log "setup: manifest $E15_MANIFEST (already_up=$already_up)"

# --- 2. pause the host's own worker and the bench containers ---------------------------------
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

# --- 3. tree and secrets ---------------------------------------------------------------------
for d in "$E15_BIN" "$E15_SECRETS" "$E15_STATE" "$E15_LOGS" "$E15_RUNS" "$E15_WORKSPACES" \
  "$E15_JAIL" "$E15_ROOT/go" "$E15_ROOT/template"; do
  if [ ! -d "$d" ]; then
    sudo -n mkdir -p "$d"
    sudo -n chown "$(id -un):$(id -gn)" "$d"
  fi
done
m_has "PURGE: sudo -n rm -rf $E15_ROOT" ||
  m_purge "created $E15_ROOT (all E15 files)" "sudo -n rm -rf $E15_ROOT"
chmod 0700 "$E15_SECRETS"
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
mem_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
slice_max=$(((mem_kb / 1024 - 2048) * 1024 * 1024))
want_slice=$(printf '[Unit]\nDescription=E15 experiment (moca-experiments)\n\n[Slice]\nMemoryAccounting=yes\nCPUAccounting=yes\nIOAccounting=yes\nTasksAccounting=yes\nMemoryMax=%s\nMemorySwapMax=0\n' "$slice_max")
want_vms=$(printf '[Unit]\nDescription=E15 worker and its microVMs\n\n[Slice]\nMemoryAccounting=yes\nCPUAccounting=yes\nTasksAccounting=yes\nMemorySwapMax=0\n')
for pair in "$E15_SLICE:$want_slice" "$E15_VM_SLICE:$want_vms"; do
  unit=${pair%%:*}
  body=${pair#*:}
  f=/etc/systemd/system/$unit
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
m_note "e15.slice MemoryMax=$slice_max bytes (host RAM $((mem_kb / 1024)) MiB - 2 GiB)"
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
snap_key="$E15_MOCA_PIN-$wheels_key-$(sha256_of "$E15_BASE_SNAPSHOT/rootfs" | cut -c1-16)"
if ! stamp_ok snapshot "$snap_key" || [ ! -f "$E15_SNAPDIR/$E15_SNAPIMG/manifest.json" ]; then
  log "rootfs: $E15_BASE_SNAPSHOT/rootfs (read-only loop mount) + pytest wheels"
  tree=$E15_ROOT/rootfs-build/tree
  mnt=$(mktemp -d "$E15_ROOT/rootfs-build.mnt.XXXXXX")
  sudo -n rm -rf "$E15_ROOT/rootfs-build"
  sudo -n mkdir -p "$tree"
  sudo -n mount -o loop,ro "$E15_BASE_SNAPSHOT/rootfs" "$mnt"
  sudo -n cp -a "$mnt/." "$tree/"
  sudo -n umount "$mnt"
  rmdir "$mnt"
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
  sudo -n env PATH="/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin" "${GOENV_ROOT[@]}" TMPDIR="$E15_ROOT" \
    bash "$E15_MOCA/deploy/microvm/build-snapshot.sh" \
    --kernel "$E15_BASE_SNAPSHOT/kernel" --rootfs "$tree" --agent "$E15_MOCA/remote-worker" \
    --image "$E15_SNAPIMG" --vmm firecracker --guest-ram-mb 1024 --out "$E15_SNAPDIR/$E15_SNAPIMG" \
    >"$E15_LOGS/build-snapshot.log" 2>&1 || die "build-snapshot.sh failed; see $E15_LOGS/build-snapshot.log"
  sudo -n rm -rf "$E15_ROOT/rootfs-build"
  stamp_set snapshot "$snap_key"
  m_note "built snapshot $E15_SNAPDIR/$E15_SNAPIMG ($(sudo -n python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m["hash"], "guest", m["guest_ram_mb"], "MiB", ",".join(m["capabilities"]))' "$E15_SNAPDIR/$E15_SNAPIMG/manifest.json"))"
fi

# --- 8. workspace template -------------------------------------------------------------------
k=$(src_key commands)
if ! stamp_ok template "$k" || [ ! -f "$E15_TEMPLATE" ]; then
  sudo -n rm -f "$E15_TEMPLATE"
  psrc=()
  [ -d "$E15_ROOT/project-src" ] && psrc=(E15_PROJECT_SRC="$E15_ROOT/project-src")
  sudo -n env "${psrc[@]}" PATH="/usr/bin:/usr/sbin:/bin:/sbin" bash "$E15_SRC/commands/build_workspace.sh" "$E15_TEMPLATE" \
    >"$E15_LOGS/build_workspace.log" 2>&1 || die "build_workspace.sh failed; see $E15_LOGS/build_workspace.log"
  stamp_set template "$k"
  m_note "built $E15_TEMPLATE ($(tail -1 "$E15_LOGS/build_workspace.log"))"
fi

# --- 9. Redis and the relay ------------------------------------------------------------------
if ! sudo -n podman container exists "$E15_REDIS_CTR" 2>/dev/null; then
  # Host network, bound to loopback: no port-forward NAT rules, and the relay's systemd IP fence
  # (IPAddressAllow=localhost) admits it, which a DNAT to the podman bridge would not.
  sudo -n podman run -d --name "$E15_REDIS_CTR" --network host \
    "$E15_REDIS_IMAGE" redis-server --bind 127.0.0.1 --port "$E15_PORT_REDIS" --save '' --appendonly no >/dev/null
  m_change "podman run $E15_REDIS_CTR (host network, 127.0.0.1:$E15_PORT_REDIS, --save '')" \
    "sudo -n podman rm -f $E15_REDIS_CTR"
  wait_for 30 port_listening "$E15_PORT_REDIS" || die "Redis did not listen on 127.0.0.1:$E15_PORT_REDIS"
fi
if ! unit_active "$E15_UNIT_RELAY"; then
  start_relay
  sleep 3
  if grep -q 'redis client error' "$E15_LOGS/relay.log"; then
    die "the relay cannot reach Redis on 127.0.0.1:$E15_PORT_REDIS; see $E15_LOGS/relay.log"
  fi
  m_change "started $E15_UNIT_RELAY (127.0.0.1:$E15_PORT_ATTACH attach, 127.0.0.1:$E15_PORT_EXEC exec)" \
    "sudo -n systemctl stop $E15_UNIT_RELAY; sudo -n systemctl reset-failed $E15_UNIT_RELAY 2>/dev/null || true"
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
  sudo -n cp --reflink=always "$E15_TEMPLATE" "$E15_WORKSPACES/e15-e2e/workspace.img"
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
