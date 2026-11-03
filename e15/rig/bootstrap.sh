#!/usr/bin/env bash
# shellcheck disable=SC2024  # logs are the login user's files on purpose; sudo runs the command only
# e15/rig/bootstrap.sh -- install the toolchain a FRESH dedicated host needs before setup.sh
# (fresh-metal profile only; SPEC §13). Idempotent: a second run changes nothing and writes nothing
# to the manifest.
#
# Run as the login user (passwordless sudo) from the staged tree, before setup.sh:
#   E15_HOST_PROFILE=fresh-metal bash /srv/e15/src/e15/rig/bootstrap.sh
#
# Every download is pinned by version and checksum in pins.sh; an empty pin refuses the run.
# What it does, each change logged to ~/e15-manifest.md:
#   1. apt packages the rig needs and the host lacks (podman for E15's Redis and the rootfs
#      export; unzip, git, curl, e2fsprogs, xfsprogs, python3, iproute2 when missing), after
#      cloud-init is done and with a 10-minute dpkg lock timeout. The exact packages apt added
#      (dpkg before/after, recorded even when the install fails) and any unit they enabled are
#      kept by teardown and listed as LEFTOVER with their undo (apt-get purge of that list)
#   2. /srv/e15 tree; podman storage under /srv/e15/containers (storage.conf)
#   3. Go into /srv/e15/go-toolchain, Node into /srv/e15/node, pnpm via corepack (COREPACK_HOME
#      /srv/e15/corepack, shim in /srv/e15/bin), Firecracker + jailer and grpcurl into /srv/e15/bin;
#      each tarball's sha256 in /srv/e15/state/artifacts. A re-run checks each tool's version
#      (and grpcurl's binary sha256), it does not re-hash the tarballs
#   4. the login user in group kvm (PURGE: removed again by teardown.sh --purge)
# Files under /srv/e15 go with its PURGE line (teardown.sh --purge).
#
# Test hooks (rig.test.sh): E15_FETCH (downloader), E15_OS_RELEASE, E15_KVM_DEV; under a test root
# only, E15_TEST_PINS (lib.sh).
set -euo pipefail
E15_PROG=bootstrap.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

[ "$E15_HOST_PROFILE" = fresh-metal ] || die "fresh-metal only (E15_HOST_PROFILE=$E15_HOST_PROFILE); aws-prelim needs no bootstrap"
e15_require_pins
[ "$(id -u)" != 0 ] || die "run as the login user, not root (sudo -n is used per step)"
sudo -n true 2>/dev/null || die "needs passwordless sudo"
[ -d "$E15_SRC" ] || die "no $E15_SRC: rsync e15/ there first"
case "$HERE" in "$E15_SRC"/rig) ;; *) die "run the staged copy: $E15_SRC/rig/bootstrap.sh (not $HERE)" ;; esac
[ "$(e15_pkg_mgr)" = apt ] || die "fresh-metal expects Ubuntu/Debian (apt); this host is $(e15_os_id)"
[ -e "${E15_KVM_DEV:-/dev/kvm}" ] || die "no ${E15_KVM_DEV:-/dev/kvm}: the host cannot run microVMs"
[ "$(uname -m)" = x86_64 ] || [ "${E15_TEST_ROOT:-}" = "$E15_ROOT" ] || die "the pins are x86_64; this host is $(uname -m)"

DL=$E15_ROOT/downloads
refuse_shared_paths "$E15_ROOT" "$E15_MANIFEST" "$DL" "$E15_GO_ROOT" "$E15_NODE_ROOT" "$E15_COREPACK_HOME" "$E15_BIN"
m_init
# The section header is written with the first change only: a second run leaves the manifest as is.
changed=0
b_section() {
  [ "$changed" = 1 ] && return 0
  m_section Bootstrap
  changed=1
}
b_change() {
  b_section
  m_change "$@"
}
b_purge() {
  b_section
  m_has "PURGE: $2" || m_purge "$1" "$2"
}
b_note() {
  b_section
  m_note "$@"
}

# --- 1. apt packages -------------------------------------------------------------------------
E15_APT_PKGS=(podman unzip git curl e2fsprogs xfsprogs python3 iproute2)
APT_OPTS=(-o DPkg::Lock::Timeout=600)
missing=()
for p in "${E15_APT_PKGS[@]}"; do e15_pkg_installed "$p" || missing+=("$p"); done
# apt_record: what apt actually added (dpkg before/after) and the units that became enabled,
# written once, also when the install fails part way (EXIT trap): the next run sees those packages
# as present and would not name them.
apt_recorded=0
apt_record() {
  [ "$apt_recorded" = 0 ] || return 0
  apt_recorded=1
  local added units undo
  added=$(comm -13 <(printf '%s\n' "$pkgs_before") <(e15_dpkg_list) | tr '\n' ' ')
  added=${added% }
  units=$(comm -13 <(printf '%s\n' "$units_before") <(e15_enabled_units) | tr '\n' ' ')
  units=${units% }
  if [ -z "$added" ]; then
    b_note "apt: no package was added (asked for ${missing[*]})"
    return 0
  fi
  undo=$(e15_pkg_remove_cmd "$added")
  [ -z "$units" ] || undo="sudo -n systemctl disable --now $units; $undo"
  b_note "LEFTOVER: apt packages added by E15 (asked for ${missing[*]}): $added; units they enabled: ${units:-none}; kept; undo: $undo"
}
if [ ${#missing[@]} -gt 0 ]; then
  if command -v cloud-init >/dev/null 2>&1; then
    log "apt: waiting for cloud-init to finish (it holds the dpkg lock on a fresh boot)"
    cloud-init status --wait >/dev/null 2>&1 || log "note: cloud-init status --wait exited non-zero; continuing"
  fi
  log "apt: installing ${missing[*]}"
  # needrestart (Ubuntu) would otherwise restart the host's services after the install.
  sudo -n env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get "${APT_OPTS[@]}" update -q >/dev/null ||
    die "apt-get update failed"
  b_note "LEFTOVER: apt package lists refreshed (apt-get update)"
  # Recommends included: podman needs its network backend and runtime. Every package apt adds is
  # listed, not only the named ones.
  pkgs_before=$(e15_dpkg_list)
  units_before=$(e15_enabled_units)
  b_note "apt: installing ${missing[*]} (the packages added are recorded next, even if this fails)"
  trap apt_record EXIT
  sudo -n env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get "${APT_OPTS[@]}" install -y -q \
    "${missing[@]}" >/dev/null || die "apt-get install ${missing[*]} failed"
  apt_record
  trap - EXIT
  for p in "${missing[@]}"; do e15_pkg_installed "$p" || die "apt reported success but $p is not installed"; done
fi

# --- 2. tree, podman storage -----------------------------------------------------------------
# The root may already exist, made by the operator (sudo) to stage src/: it must be the login user's.
if [ ! -d "$E15_ROOT" ] || [ ! -w "$E15_ROOT" ]; then
  sudo -n mkdir -p "$E15_ROOT"
  sudo -n chown "$(id -un):$(id -gn)" "$E15_ROOT"
fi
m_has "PURGE: sudo -n rm -rf $E15_ROOT" || b_purge "created $E15_ROOT (all E15 files)" "sudo -n rm -rf $E15_ROOT"
for d in "$DL" "$E15_STATE" "$E15_BIN" "$E15_LOGS" "$(dirname "$E15_PODMAN_CONF")"; do mkdir -p "$d"; done
if [ "$(cat "$E15_STATE/host_profile" 2>/dev/null || true)" != fresh-metal ]; then
  echo fresh-metal >"$E15_STATE/host_profile"
  b_note "host profile fresh-metal recorded in $E15_STATE/host_profile"
fi
if [ "$(cat "$E15_PODMAN_CONF" 2>/dev/null || true)" != "$(e15_podman_conf_body)" ]; then
  e15_podman_conf_body >"$E15_PODMAN_CONF"
  b_note "podman storage for E15 under $E15_ROOT/containers ($E15_PODMAN_CONF; nothing in /var/lib/containers)"
fi
# Replayed (in reverse) before the PURGE of /srv/e15: no overlay mount is left under it.
m_has "PURGE: $(e15_podman_str) system reset -f" ||
  b_purge "E15's podman storage" "$(e15_podman_str) system reset -f >/dev/null 2>&1 || true"

# --- 3. pinned toolchain ---------------------------------------------------------------------
# install_tarball NAME URL SHA256 CHECK -- BODY...: skip when state/bootstrap-NAME holds SHA256 and
# CHECK (a command) succeeds; else fetch, verify, run BODY with $tb the tarball, CHECK, stamp.
install_tarball() {
  local name=$1 url=$2 sha=$3 check=$4 tb
  shift 5
  if stamp_ok "bootstrap-$name" "$sha" && bash -c "$check" >/dev/null 2>&1; then return 0; fi
  tb=$DL/$(basename "$url")
  log "bootstrap: $name from $url"
  e15_fetch "$url" "$sha" "$tb"
  "$@" "$tb" || die "installing $name failed"
  bash -c "$check" >/dev/null 2>&1 || die "$name installed but its check failed: $check"
  stamp_set "bootstrap-$name" "$sha"
  e15_artifact "$name" "$sha" "$url"
  b_note "installed $name ($url, sha256 $sha)"
}

# The helpers run under `|| die` (errexit off), so every step checks its own exit.
untar_into() { # DIR TARBALL: replace DIR with TARBALL's single top directory
  local dir=$1 tb=$2
  rm -rf "$dir.new" || return 1
  mkdir -p "$dir.new" || return 1
  tar -xf "$tb" -C "$dir.new" --strip-components=1 --no-same-owner || return 1
  rm -rf "$dir" || return 1
  mv "$dir.new" "$dir"
}
inst_go() { untar_into "$E15_GO_ROOT" "$1"; }
inst_node() { untar_into "$E15_NODE_ROOT" "$1"; }
inst_fc() {
  local t r=1
  t=$(mktemp -d "$DL/fc.XXXXXX") || return 1
  tar -xzf "$1" -C "$t" --no-same-owner &&
    install -m 0755 "$t/release-$E15_FC_VERSION-x86_64/firecracker-$E15_FC_VERSION-x86_64" "$E15_BIN/firecracker" &&
    install -m 0755 "$t/release-$E15_FC_VERSION-x86_64/jailer-$E15_FC_VERSION-x86_64" "$E15_BIN/jailer" && r=0
  rm -rf "$t"
  return "$r"
}
# grpcurl's own sha256 (the installed binary) is kept beside it: a re-run's check compares it, so a
# failed upgrade that left another binary in place is not taken for the pinned one.
GRPCURL_BIN_SHA=$E15_STATE/grpcurl.bin.sha256
inst_grpcurl() {
  local t r=1
  t=$(mktemp -d "$DL/grpcurl.XXXXXX") || return 1
  tar -xzf "$1" -C "$t" --no-same-owner &&
    install -m 0755 "$t/grpcurl" "$E15_BIN/grpcurl" &&
    sha256_of "$E15_BIN/grpcurl" >"$GRPCURL_BIN_SHA" && r=0
  rm -rf "$t"
  return "$r"
}

install_tarball go "$E15_GO_URL" "$E15_GO_SHA256" \
  "'$E15_GO_ROOT/bin/go' version | grep -qF 'go$E15_GO_VERSION '" -- inst_go
install_tarball node "$E15_NODE_URL" "$E15_NODE_SHA256" \
  "[ \"\$('$E15_NODE_ROOT/bin/node' --version)\" = v$E15_NODE_VERSION ]" -- inst_node
install_tarball firecracker "$E15_FC_URL" "$E15_FC_SHA256" \
  "'$E15_BIN/firecracker' --version | head -1 | grep -qF 'Firecracker $E15_FC_VERSION' && [ -x '$E15_BIN/jailer' ]" -- inst_fc
install_tarball grpcurl "$E15_GRPCURL_URL" "$E15_GRPCURL_SHA256" \
  "'$E15_BIN/grpcurl' -version 2>&1 | grep -qE '^grpcurl v?$E15_GRPCURL_VERSION\$' && [ \"\$(sha256sum '$E15_BIN/grpcurl' | cut -d' ' -f1)\" = \"\$(cat '$GRPCURL_BIN_SHA')\" ]" -- inst_grpcurl

# pnpm through corepack, pinned by version and the registry's sha512.
mapfile -t UENV < <(e15_userenv user)
pnpm_spec="pnpm@$E15_PNPM_VERSION+sha512.$E15_PNPM_SHA512"
if ! stamp_ok bootstrap-pnpm "$pnpm_spec" || [ "$(env "${UENV[@]}" "$E15_BIN/pnpm" --version 2>/dev/null)" != "$E15_PNPM_VERSION" ]; then
  log "bootstrap: $pnpm_spec via corepack (COREPACK_HOME $E15_COREPACK_HOME)"
  mkdir -p "$E15_COREPACK_HOME"
  env "${UENV[@]}" "$E15_NODE_ROOT/bin/corepack" enable --install-directory "$E15_BIN" pnpm ||
    die "corepack enable pnpm failed"
  env "${UENV[@]}" "$E15_NODE_ROOT/bin/corepack" install -g "$pnpm_spec" || die "corepack install $pnpm_spec failed"
  got=$(env "${UENV[@]}" "$E15_BIN/pnpm" --version 2>/dev/null || true)
  [ "$got" = "$E15_PNPM_VERSION" ] || die "pnpm --version is '$got', want $E15_PNPM_VERSION"
  stamp_set bootstrap-pnpm "$pnpm_spec"
  e15_artifact pnpm "sha512:$E15_PNPM_SHA512" "corepack $pnpm_spec"
  b_note "installed pnpm $E15_PNPM_VERSION via corepack (sha512 $E15_PNPM_SHA512; shim $E15_BIN/pnpm)"
fi

# --- 4. kvm group ----------------------------------------------------------------------------
me=$(id -un)
kvm_members=$(getent group kvm | cut -d: -f4) || die "no group kvm on this host"
case ",$kvm_members," in
*",$me,"*) ;;
*)
  sudo -n usermod -aG kvm "$me" || die "usermod -aG kvm $me failed"
  # The PURGE succeeds whether or not $me is still a member (so a repeated purge is not a failure).
  b_purge "added $me to group kvm (takes effect at the next login)" \
    "sudo -n gpasswd -d $me kvm >/dev/null 2>&1 || ! getent group kvm | cut -d: -f4 | tr , '\\n' | grep -qx $me"
  ;;
esac

if [ "$changed" = 1 ]; then
  m_note "bootstrap complete"
  log "bootstrap: done (changes in $E15_MANIFEST)"
else
  log "bootstrap: nothing to change"
fi
