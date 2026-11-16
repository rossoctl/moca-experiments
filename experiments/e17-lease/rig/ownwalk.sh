#!/usr/bin/env bash
# experiments/e17-lease/rig/ownwalk.sh [--plan] FILES -- the ownership-walk probe at one workspace size (spec §7.4,
# PLAN-E17B Task 11 and Task 14 Step 4) on the metal host. FILES: 10000, 100000 or 500000.
#
# Run by chain-e17b.sh (stage ownwalk: once per size, after the seal), from the staged copy, with E17B=1 on
# fresh-metal. One worker cycle, as rung.sh's for a ship-300 rung:
#   1. stop any rung units left over; wipe $E15_WORKSPACES and $E15_JAIL (after refuse_shared_paths, as rung.sh)
#   2. the size's workspace template, built once into its own leaf $E15_ROOT/template-ownwalk/F<FILES>-<MB>.img:
#      a blank ext4 image of IMAGE_MB MiB (at least 1024, and at least 2 blocks per inode) with INODES inodes
#      (FILES + FILES/1000 directories + 8192 slack) and no lazy init, so no guest's ext4lazyinit runs during
#      the walk. The 256 MiB default template holds about 65k inodes, too few for 100k or 500k files.
#   3. five workspaces RUN-0..RUN-4 (the driver's ownwalkKey), each a reflink copy of the template
#   4. a fresh token key (e15-driver-e17b mint-key) the restarted relay trusts; ship-300's worker
#      (lib.sh worker_env, image size IMAGE_MB); its banner must say lease=on
#   5. e15-driver-e17b ownwalk --files FILES --repeats 5 at ship-300's idle timeout (300 s), build_tree.sh as the
#      per-exec write: per repeat the per-exec build as root, set_mode lease (epoch 1), A, reset, B
#   6. stop the worker (its VMs go with it), remove the token key; ownwalk-params.json beside the driver's
#      ownwalk.json in $E15_RUNS/ownwalk/ship-300/F<FILES>/ (a previous one is moved aside, as rung.sh does)
# No params.json is written there: the chain's per-rung analysis gate reads params.json, and this is not a rung.
# No attach probe: the relay is restarted for this run, so no stale worker session can hold sandbox e15, and
# start_worker waits for the worker's attach line.
#
# --plan prints the sizing, the keys, the paths and the driver command, and changes nothing.
# Exit: the driver's (0 every repeat valid, 1 otherwise; ownwalk.json is written either way), 1 on a rig error,
# 2 on bad usage.
set -euo pipefail
E15_PROG=ownwalk.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() {
  echo "usage: ownwalk.sh [--plan] FILES   (FILES: 10000 | 100000 | 500000; E17B=1, fresh-metal, the staged copy)" >&2
  exit 2
}
PLAN=0
if [ "${1:-}" = --plan ]; then
  PLAN=1
  shift
fi
[ $# -eq 1 ] || usage
FILES=$1
case "$FILES" in 10000 | 100000 | 500000) ;; *) usage ;; esac
# Before lib.sh: with E17B unset lib.sh resolves the sealed pin, and this probe is the E17b arm's.
[ "${E17B:-}" = 1 ] || {
  echo "ownwalk.sh: E17B=1 is required (the probe runs the shipped lease at the E17b pin); chain-e17b.sh sets it" >&2
  exit 1
}
E15_RIG=$HERE/../../e15/rig
[ -f "$E15_RIG/lib.sh" ] || {
  printf '%s: no %s/lib.sh: run the staged copy (/srv/e15/src/e17/rig/ownwalk.sh)\n' "$E15_PROG" "$E15_RIG" >&2
  exit 1
}
# shellcheck source=SCRIPTDIR/../../e15-session-density/rig/lib.sh
. "$E15_RIG/lib.sh"
E17_SRC=$E15_ROOT/src/e17
case "$HERE" in "$E17_SRC"/rig) ;; *) die "run the staged copy: $E17_SRC/rig/ownwalk.sh (not $HERE)" ;; esac

ARM=ship-300
REPEATS=5
INODES=$((FILES + FILES / 1000 + 8192))
IMAGE_MB=$(((INODES * 2 * 4096 + (1 << 20) - 1) >> 20)) # 2 blocks of 4 KiB per inode, in MiB
IMAGE_MB=$((((IMAGE_MB + 1023) / 1024) * 1024))         # whole GiB, at least 1
RUN_ID=ownwalk-F$FILES-$(date -u +%s)
KEYS=()
for ((i = 0; i < REPEATS; i++)); do KEYS+=("$RUN_ID-$i"); done
DIR=$E15_RUNS/ownwalk/$ARM/F$FILES
TEMPLATE_DIR=$E15_ROOT/template-ownwalk
TEMPLATE=$TEMPLATE_DIR/F$FILES-$IMAGE_MB.img
DRIVER=$E15_BIN/e15-driver-e17b
SCRIPT=$E17_SRC/workload/build_tree.sh
TOKEN_DIR=$E15_SECRETS/token-$RUN_ID
DRIVER_ARGS=(ownwalk --files "$FILES" --repeats "$REPEATS" --target "127.0.0.1:$E15_PORT_EXEC" --sandbox-id e15
  --token-key "$TOKEN_DIR/token.key" --token-iss "$(e17b_token_iss)" --idle-timeout-s "${ARM#ship-}" --run-id "$RUN_ID"
  --out "$DIR" --build-script "$SCRIPT")

if [ "$PLAN" = 1 ]; then
  echo "files: $FILES"
  echo "inodes: $INODES"
  echo "image_mb: $IMAGE_MB"
  echo "run_id: $RUN_ID"
  echo "keys: ${KEYS[*]}"
  echo "dir: $DIR"
  echo "template: $TEMPLATE"
  echo "driver: $DRIVER ${DRIVER_ARGS[*]}"
  exit 0
fi

[ "$E15_HOST_PROFILE" = fresh-metal ] || die "the E17b probes run on fresh-metal only (this host: $E15_HOST_PROFILE)"
e17b_require_pin
e17b_require_build
e17b_lease_arm "$ARM" || die "$ARM is not a lease arm under E17B=1"
if unit_active "$E15_UNIT_WORKER"; then die "a rung's worker ($E15_UNIT_WORKER) is running; refusing to preempt it"; fi
e17b_require_snapshot
[ -x "$DRIVER" ] || die "no $DRIVER (run setup.sh with E17B=1)"
[ -f "$SCRIPT" ] || die "no $SCRIPT (sync.sh stages experiments/e17-lease/workload)"
e17b_token_dir_ok "$TOKEN_DIR" || die "the key directory $TOKEN_DIR is not a token-<run> leaf of $E15_SECRETS; nothing minted"
refuse_outside_root "$DIR" "$TEMPLATE_DIR"

cleanup() {
  stop_rung_units || true
  e17b_token_dir_remove "$TOKEN_DIR" || true
}
trap cleanup EXIT

if [ -e "$DIR" ]; then mv "$DIR" "$DIR.prev-$(date -u +%Y%m%dT%H%M%SZ)"; fi
mkdir -p "$DIR"
log "ownwalk files=$FILES: $REPEATS repeats on fresh keys, ${IMAGE_MB} MiB workspaces with $INODES inodes -> $DIR"

# --- 1-3. fresh worker state, the template, the workspaces -----------------------------------------------------
stop_rung_units
refuse_shared_paths "$E15_WORKSPACES" "$E15_JAIL"
sudo -n find "$E15_WORKSPACES" "$E15_JAIL" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
if ! sudo -n test -f "$TEMPLATE"; then
  sudo -n mkdir -p "$TEMPLATE_DIR"
  tmp_img=$TEMPLATE.build-$$
  sudo -n rm -f "$tmp_img"
  sudo -n truncate -s "${IMAGE_MB}M" "$tmp_img"
  sudo -n mkfs.ext4 -F -q -N "$INODES" -E lazy_itable_init=0,lazy_journal_init=0 "$tmp_img" || {
    sudo -n rm -f "$tmp_img"
    die "mkfs.ext4 of the ownwalk template $tmp_img failed"
  }
  sudo -n chmod 0600 "$tmp_img"
  sudo -n mv -f "$tmp_img" "$TEMPLATE"
  m_note "built the ownwalk template $TEMPLATE (blank ext4, ${IMAGE_MB} MiB sparse, $INODES inodes; removed with $E15_ROOT by teardown.sh --purge)"
fi
WS_COPY=$(workspace_copy_mode)
[ "$WS_COPY" = reflink ] || die "fresh-metal: state/workspace_copy is not reflink (run setup.sh; reflink is required)"
sudo -n bash -c '
  set -e
  ws=$1 tpl=$2 cpf=$3
  shift 3
  for k in "$@"; do
    mkdir -m 0700 "$ws/$k"
    cp "$cpf" "$tpl" "$ws/$k/workspace.img"
    chmod 0600 "$ws/$k/workspace.img"
  done' _ "$E15_WORKSPACES" "$TEMPLATE" "$(workspace_cp_flag "$WS_COPY")" "${KEYS[@]}"

# --- 4. the relay with this run's token key, ship-300's worker -------------------------------------------------
[ -f "$E15_LOGS/relay.log" ] && sudo -n cp "$E15_LOGS/relay.log" "$DIR/relay.before-restart.log"
stop_e15_unit "$E15_UNIT_RELAY"
(umask 077 && "$DRIVER" mint-key --out "$TOKEN_DIR") >"$DIR/mint-key.log" 2>&1 ||
  die "e15-driver mint-key --out $TOKEN_DIR failed; see $DIR/mint-key.log"
[ -s "$TOKEN_DIR/token.key" ] && [ -s "$TOKEN_DIR/token.pub" ] || die "mint-key left no token.key/token.pub in $TOKEN_DIR"
relay_extra=$E15_SECRETS/relay-lease.env
(umask 077 && printf 'SH_SANDBOX_TOKEN_PUBLIC_KEYS=%s\nSH_SANDBOX_TOKEN_ISSUER=%s\n' "$(cat "$TOKEN_DIR/token.pub")" "$(e17b_token_iss)" >"$relay_extra")
start_relay "$relay_extra"
sleep 3
if grep -qs 'redis client error' "$E15_LOGS/relay.log"; then
  die "the restarted relay cannot reach Redis on 127.0.0.1:$E15_PORT_REDIS; see $E15_LOGS/relay.log"
fi
start_worker "$ARM" "$DIR" "$IMAGE_MB"
banner=$(grep -m1 'microvm-worker: relay=' "$DIR/worker.log" || true)
case " $banner " in
*" lease=on "*) log "worker banner: lease=on" ;;
*) die "the worker's banner does not say lease=on ($banner): the probe needs the snapshot-e17b.sh leaf; the driver was not started" ;;
esac

# --- 5. the probe ----------------------------------------------------------------------------------------------
driver_exit=0
"$DRIVER" "${DRIVER_ARGS[@]}" >"$DIR/driver.log" 2>&1 || driver_exit=$?
log "ownwalk driver exit $driver_exit ($DIR/ownwalk.json)"

# --- 6. stop the backend, the record ---------------------------------------------------------------------------
cleanup
trap - EXIT
[ ! -f "$DIR/worker.log" ] || sudo -n chown "$(id -un):$(id -gn)" "$DIR/worker.log"
python3 - "$DIR" <<PY
import hashlib, json, os, sys
d = sys.argv[1]
def sha(p):
    try:
        with open(p, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except OSError:
        return None
env = {}
try:
    for line in open(os.path.join(d, "worker.env")):
        if "=" in line:
            k, v = line.rstrip("\n").split("=", 1)
            env[k] = v
except OSError:
    pass
snap = None
try:
    snap = json.load(open("$E15_SNAPDIR/$(worker_snapimg)/manifest.json"))
except (OSError, ValueError):
    pass
p = {
    "probe": "ownwalk", "arm": "$ARM", "files": $FILES, "repeats": $REPEATS, "run_id": "$RUN_ID",
    "keys": "${KEYS[*]}".split(), "inodes": $INODES, "image_mb": $IMAGE_MB, "template": "$TEMPLATE",
    "idle_timeout_s": int("${ARM#ship-}"), "driver_exit": $driver_exit,
    "moca_commit": "$E15_MOCA_PIN", "driver_bin_sha256": sha("$DRIVER"), "build_tree_sha256": sha("$SCRIPT"),
    "worker_bin_sha256": sha("$(worker_bin "$ARM")"), "worker_env": env,
    "snapshot_image": "$(worker_snapimg)", "snapshot_hash": snap and snap.get("hash"),
    "guest_ram_mb": int("$(worker_guest_ram_mb)"), "host_profile": "$E15_HOST_PROFILE",
    "lease_banner": """$banner""",
}
json.dump(p, open(os.path.join(d, "ownwalk-params.json"), "w"), indent=2, sort_keys=True)
PY
exit "$driver_exit"
