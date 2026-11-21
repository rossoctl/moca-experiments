#!/usr/bin/env bash
# experiments/e15-session-density/rig/lib.sh -- shared definitions and guards for the E15 rig scripts (SPEC §4, §6.6, §7).
#
# shellcheck disable=SC2034  # the tables below are used by the scripts that source this file
# Sourced, never run. Sourcing has no side effects: it defines paths, tables and functions only.
#
# Rig rules enforced here (SPEC §4):
#   refuse_shared_paths PATH...  exit 3 if any PATH is, or is under, /opt/serverless-harness
#   refuse_ports PORT...         exit 3 if anything already listens on a PORT (ss -ltnH)
#   refuse_units ARGS...         exit 3 if any systemctl argument names an sh-* unit
#   sctl ARGS...                 the ONLY way these scripts call systemctl: refuse_units, then
#                                `sudo -n systemctl ARGS`
#
# Manifest (~/e15-manifest.md, override E15_MANIFEST): every host change is one line
#   - <utc> <what> | UNDO: <command>     replayed in reverse by teardown.sh
#   - <utc> <what> | PURGE: <command>    replayed in reverse by teardown.sh --purge only
#   - <utc> <what>                       a note
# Sections: "## Setup <utc>", "## Bootstrap <utc>", "## Teardown <utc>", "## Purge <utc>".
#
# Host profile (E15_HOST_PROFILE, SPEC §13):
#   aws-prelim   (default) the preliminary, shared AWS rig: Amazon Linux 2023, a P6 install, its
#                Firecracker in /usr/local/bin and its golden snapshot. The shared-host guards above.
#   fresh-metal  a dedicated, fresh Ubuntu host. bootstrap.sh installs the toolchain under /srv/e15
#                (pins.sh); setup.sh builds the guest rootfs from moca v0.9.0's sandbox image. No
#                shared-host guards (nothing shared runs there); instead refuse_shared_paths refuses
#                any path outside /srv/e15 (the manifest excepted) and sctl any non-E15 unit.

E15_ROOT=${E15_ROOT:-/srv/e15}
# Rig rule: E15's files live under /srv/e15. A root elsewhere is refused at source time.
case "$E15_ROOT" in
/srv/e15 | /srv/e15/*) ;;
# rig.test.sh only: a scratch root it made itself, named so nothing real can match by accident.
*/e15-rig-test.*) [ "${E15_TEST_ROOT:-}" = "$E15_ROOT" ] || {
  printf 'lib.sh: E15_ROOT=%s is a test root but E15_TEST_ROOT does not name it\n' "$E15_ROOT" >&2
  exit 3
} ;;
*)
  printf 'lib.sh: E15_ROOT=%s is not under /srv/e15 (rig rule)\n' "$E15_ROOT" >&2
  exit 3
  ;;
esac
E15_MANIFEST=${E15_MANIFEST:-$HOME/e15-manifest.md}
# The profile setup.sh recorded ($E15_ROOT/state/host_profile) is the default, so rung.sh and
# teardown.sh need no E15_HOST_PROFILE; without one, aws-prelim. A different explicit profile is
# refused: the two lay out binaries and the guest differently.
_e15_rec_profile=$(cat "$E15_ROOT/state/host_profile" 2>/dev/null || true)
E15_HOST_PROFILE=${E15_HOST_PROFILE:-${_e15_rec_profile:-aws-prelim}}
case "$E15_HOST_PROFILE" in
aws-prelim | fresh-metal) ;;
*)
  printf 'lib.sh: E15_HOST_PROFILE=%s is not a profile (aws-prelim, fresh-metal)\n' "$E15_HOST_PROFILE" >&2
  exit 3
  ;;
esac
if [ -n "$_e15_rec_profile" ] && [ "$_e15_rec_profile" != "$E15_HOST_PROFILE" ]; then
  printf 'lib.sh: E15_HOST_PROFILE=%s, but this host was set up as %s (%s/state/host_profile)\n' \
    "$E15_HOST_PROFILE" "$_e15_rec_profile" "$E15_ROOT" >&2
  exit 3
fi
# shellcheck source=pins.sh
. "$(dirname "${BASH_SOURCE[0]}")/pins.sh"
# rig.test.sh only: fixture pins (its own tarballs' checksums) and a scratch fstab, honoured only
# under its named scratch root (*/e15-rig-test.*, never /srv/e15 even if E15_TEST_ROOT names it).
E15_FSTAB=/etc/fstab
case "$E15_ROOT" in
*/e15-rig-test.*)
  if [ -n "${E15_TEST_PINS:-}" ] && [ "${E15_TEST_ROOT:-}" = "$E15_ROOT" ]; then
    # shellcheck disable=SC1090
    . "$E15_TEST_PINS"
  fi
  [ "${E15_TEST_ROOT:-}" = "$E15_ROOT" ] && E15_FSTAB=${E15_TEST_FSTAB:-/etc/fstab}
  ;;
esac
E15_SHARED=/opt/serverless-harness

# moca v0.9.0 (SPEC §6.6).
E15_MOCA_PIN=c13d55649777e69ec7649d6fa8c08f4acb1f4e2e
E15_MOCA_URL=${E15_MOCA_URL:-https://github.com/rossoctl/moca.git}

# E17b profile (experiments/e17-lease/PLAN-E17B.md): with E17B=1 every arm runs from E17B_MOCA_PIN
# (experiments/e17-lease/rig/e17b-pins.sh) in its own checkout, $E15_ROOT/moca-e17b (set below), so
# setup.sh's clone, build stamps, snapshot key, relay, microvm-worker and guest agent all follow it.
# With E17B unset (or anything but 1) nothing here runs and the sealed E15/E16/E17a procedures resolve
# as before. rig.test.sh only: a fixture pin file (E15_TEST_PINS) is applied last, as for pins.sh.
# E17c profile (experiments/e17-lease/PLAN-E17C.md): E17C=1 is E17B=1 (ship-* arms, the lease worker, E17a arms
# refused, resident build skipped; E17C=1 alone is E17C=1 E17B=1, exported to child scripts) except that the pin is
# E17C_MOCA_PIN (experiments/e17-lease/rig/e17c-pins.sh) and the checkout $E15_ROOT/moca-e17c (set below).
# With E17C unset (or anything but 1) nothing here runs and E17b and the sealed procedures resolve as before.
[ "${E17C:-}" != 1 ] || export E17B=1
if [ "${E17B:-}" = 1 ]; then
  _e17b_here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  # The repo layout (experiments/e17-lease) and the rig's staged one (/srv/e15/src/e17, sync.sh).
  for _e17b_f in "$_e17b_here/../../e17-lease/rig/e17b-pins.sh" "$_e17b_here/../../e17/rig/e17b-pins.sh"; do
    [ -f "$_e17b_f" ] && break
  done
  [ -f "$_e17b_f" ] || {
    printf 'lib.sh: E17B=1 but no e17b-pins.sh at %s or %s\n' "$_e17b_here/../../e17-lease/rig/e17b-pins.sh" "$_e17b_here/../../e17/rig/e17b-pins.sh" >&2
    exit 3
  }
  # shellcheck disable=SC1090
  . "$_e17b_f"
  if [ "${E17C:-}" = 1 ]; then
    for _e17c_f in "$_e17b_here/../../e17-lease/rig/e17c-pins.sh" "$_e17b_here/../../e17/rig/e17c-pins.sh"; do
      [ -f "$_e17c_f" ] && break
    done
    [ -f "$_e17c_f" ] || {
      printf 'lib.sh: E17C=1 but no e17c-pins.sh at %s or %s\n' "$_e17b_here/../../e17-lease/rig/e17c-pins.sh" "$_e17b_here/../../e17/rig/e17c-pins.sh" >&2
      exit 3
    }
    # shellcheck disable=SC1090
    . "$_e17c_f"
  fi
  case "$E15_ROOT" in
  */e15-rig-test.*)
    # shellcheck disable=SC1090
    [ -n "${E15_TEST_PINS:-}" ] && [ "${E15_TEST_ROOT:-}" = "$E15_ROOT" ] && . "$E15_TEST_PINS"
    ;;
  esac
  # shellcheck disable=SC2153 # assigned by the pin file sourced above
  E15_MOCA_PIN=$E17B_MOCA_PIN
  # shellcheck disable=SC2153 # assigned by the pin file sourced above
  [ "${E17C:-}" != 1 ] || E15_MOCA_PIN=$E17C_MOCA_PIN
fi
# e17b_require_pin: refuse an E17B_MOCA_PIN that is not a full 40-hex sha or is the all-zero placeholder.
# setup.sh and rung.sh call it when E17B=1; teardown.sh does not (it must always be able to undo).
e17b_require_pin() {
  case "${E17B_MOCA_PIN:-}" in
  0000000000000000000000000000000000000000)
    die "E17B_MOCA_PIN is still the placeholder (all zeros) in e17b-pins.sh; replace it with the upstream/main sha before any rig run"
    ;;
  esac
  printf '%s' "${E17B_MOCA_PIN:-}" | grep -qE '^[0-9a-f]{40}$' ||
    die "E17B_MOCA_PIN '${E17B_MOCA_PIN:-}' is not a full 40-hex sha (e17b-pins.sh)"
}
# e17c_require_pin: the same for E17C_MOCA_PIN (e17c-pins.sh). setup.sh and rung.sh call it when E17C=1, before
# the E17b checks; teardown.sh does not.
e17c_require_pin() {
  case "${E17C_MOCA_PIN:-}" in
  0000000000000000000000000000000000000000)
    die "E17C_MOCA_PIN is still the placeholder (all zeros) in e17c-pins.sh; replace it with the upstream/main sha (moca #974 merged) before any rig run"
    ;;
  esac
  printf '%s' "${E17C_MOCA_PIN:-}" | grep -qE '^[0-9a-f]{40}$' ||
    die "E17C_MOCA_PIN '${E17C_MOCA_PIN:-}' is not a full 40-hex sha (e17c-pins.sh)"
}

# Ports (SPEC §4): relay attach, relay exec, null-responder (control arm), worker /stats, Redis.
E15_PORT_ATTACH=9643
E15_PORT_EXEC=9644
E15_PORT_NULL=9645
E15_PORT_STATS=9646
E15_PORT_REDIS=6400
E15_PORTS=("$E15_PORT_ATTACH" "$E15_PORT_EXEC" "$E15_PORT_NULL" "$E15_PORT_STATS" "$E15_PORT_REDIS")

# Units E15 creates. The worker's slice nests inside e15.slice (systemd expands the dash).
# Unit files go to the admin unit directory, the same path on AL2023 and Ubuntu.
E15_UNIT_DIR=/etc/systemd/system
E15_SLICE=e15.slice
E15_VM_SLICE=e15-vms.slice
E15_PARENT_CGROUP=e15.slice/e15-vms.slice
E15_UNIT_RELAY=e15-relay.service
E15_UNIT_WORKER=e15-worker.service
E15_UNIT_NULL=e15-null.service
E15_REDIS_CTR=e15-redis
E15_REDIS_IMAGE=docker.io/library/redis:7-alpine

# The host's own services E15 pauses for a run (SPEC §4), restored by teardown.
E15_HOST_WORKER=microvm-worker.service
E15_BENCH_CTRS=(bench-cp bench-redis)

# Firecracker binaries: aws-prelim, already on the host (read only); fresh-metal, bootstrap.sh's
# pinned release under /srv/e15/bin. The guest's base: aws-prelim copies the host's golden
# snapshot's rootfs and kernel; fresh-metal builds the rootfs from moca's sandbox image and fetches
# the pinned CI kernel (pins.sh), so it has no E15_BASE_SNAPSHOT.
if [ "$E15_HOST_PROFILE" = fresh-metal ]; then
  E15_JAILER=$E15_ROOT/bin/jailer
  E15_FIRECRACKER=$E15_ROOT/bin/firecracker
  E15_BASE_SNAPSHOT=""
  E15_REDIS_IMAGE=$E15_METAL_REDIS_IMAGE
else
  E15_JAILER=/usr/local/bin/jailer
  E15_FIRECRACKER=/usr/local/bin/firecracker
  E15_BASE_SNAPSHOT=/srv/snapshots/default
fi

E15_ARMS=(sbx resident-inf resident-300 control)
# E17 (experiments/e17-lease/SPEC.md, fresh-metal only): the lease arms, the resident worker with a 30 s or 120 s idle
# lease (worker_env); otherwise as resident-300. aws-prelim: the sealed arm list above.
[ "$E15_HOST_PROFILE" != fresh-metal ] || E15_ARMS+=(lease-30 lease-120)
# E17b (E17B=1, fresh-metal only): ship-30/120/300 are the shipped lease at idle timeout 30/120/300 s (the stock worker at
# E17B_MOCA_PIN, depth 0; worker_env). With E17B unset the arm list above stands.
if [ "$E15_HOST_PROFILE" = fresh-metal ] && [ "${E17B:-}" = 1 ]; then E15_ARMS+=(ship-30 ship-120 ship-300); fi
# E17c (E17C=1, fresh-metal only): ship-300-nd is ship-300 with the idle page-cache drop off (SH_LEASE_CACHE_DROP_S=0;
# worker_env). With E17C unset the arm list above stands.
if [ "$E15_HOST_PROFILE" = fresh-metal ] && [ "${E17C:-}" = 1 ]; then E15_ARMS+=(ship-300-nd); fi
E15_LADDER=(1 8 16 24 32 40 48 56 64 80 96 128)
# fresh-metal (SPEC §13, user decision 2026-11-04): the ladder extends past 128 until one arm fails,
# resident arms warm up 1200 s (their VMs are still growing at 600 s), and footprint drift is judged
# on the summed VM memory (record.py drift_basis). aws-prelim: the sealed preliminary procedure.
E15_DRIFT_BASIS=median
if [ "$E15_HOST_PROFILE" = fresh-metal ]; then
  E15_LADDER+=(160 192 256 320 384 448 512 576 640 704 768 896 1024)
  # E16 (sealed with its predictions, 2026-11-08): E15_LADDER_EXTRA appends rungs above 1024 (e16
  # chain.sh sets "1280 1536"); unset, the E15 metal ladder is unchanged.
  # shellcheck disable=SC2206  # word-split a space-separated rung list
  [ -z "${E15_LADDER_EXTRA:-}" ] || E15_LADDER+=($E15_LADDER_EXTRA)
  E15_DRIFT_BASIS=sum
fi
# e15_default_warmup ARM: the rung warm-up (s) when E15_WARMUP_S is unset.
e15_default_warmup() {
  case "$E15_HOST_PROFILE:$1" in
  fresh-metal:sbx | fresh-metal:resident-inf | fresh-metal:resident-300) echo 1200 ;;
  fresh-metal:lease-30 | fresh-metal:lease-120) echo 1200 ;; # E17: as resident-300
  fresh-metal:ship-30 | fresh-metal:ship-120 | fresh-metal:ship-300) echo 1200 ;; # E17b: as the lease arms
  fresh-metal:ship-300-nd) echo 1200 ;;                                              # E17c: as ship-300
  *) echo 600 ;;
  esac
}
E15_FLOOR_MB=1536
# SH_MAX_RUNS: the worker's backstop on unparked runs (moca vmpool admitLocked). A resident-inf
# session holds one unparked run for its whole life, so 512 would refuse a metal resident rung above
# N=512 before any host resource binds; the metal ladder goes past that (SPEC §13). aws-prelim
# keeps 512, the preliminary run's value.
# SH_MAX_COMMITTED_MB: the worker's admission budget (moca charges every VM its full guest RAM);
# 1 TiB on both profiles.
# E16 (experiments/e16-low-duty/SPEC.md §5): E15_MAX_COMMITTED_MB and E15_MAX_RUNS from the environment override both,
# on fresh-metal only (a positive integer without leading zeros, else lib.sh exits 3). aws-prelim ignores them: its sealed
# values stand. Unset on fresh-metal: the E15 metal values above.
_e15_env_committed=${E15_MAX_COMMITTED_MB:-}
_e15_env_runs=${E15_MAX_RUNS:-}
E15_MAX_COMMITTED_MB=1048576
if [ "$E15_HOST_PROFILE" = fresh-metal ]; then E15_MAX_RUNS=2048; else E15_MAX_RUNS=512; fi
if [ "$E15_HOST_PROFILE" = fresh-metal ]; then
  for _e15_v in "E15_MAX_COMMITTED_MB=$_e15_env_committed" "E15_MAX_RUNS=$_e15_env_runs"; do
    case "${_e15_v#*=}" in
    "") ;;
    0* | *[!0-9]*)
      printf 'lib.sh: %s is not a positive integer\n' "$_e15_v" >&2
      exit 3
      ;;
    esac
  done
  [ -z "$_e15_env_committed" ] || E15_MAX_COMMITTED_MB=$_e15_env_committed
  [ -z "$_e15_env_runs" ] || E15_MAX_RUNS=$_e15_env_runs
fi
unset _e15_env_committed _e15_env_runs _e15_v

# Points (SPEC §10.3): points.sh (sourced after this file).

# e15_e17a_arm_refused ARM: under E17B=1 (the E17b profile) the E17a arms resident-* and lease-* are refused, naming
# why, on stderr (PR #34): E17B=1 only adds ship-* to E15_ARMS / points.sh, but those arms' worker is
# microvm-worker-resident, the old-pin build, which would run against the E17b relay and guest agent and be recorded at
# E17B_MOCA_PIN. Returns 1 (not refused) otherwise; with E17B unset nothing changes.
e15_e17a_arm_refused() {
  [ "${E17B:-}" = 1 ] || return 1
  case "$1" in resident-* | lease-*) ;; *) return 1 ;; esac
  printf '%s: %s is an E17a arm: its worker is microvm-worker-resident, the old-pin build; under E17B=1 it would run against the E17b relay and guest agent and be recorded at E17B_MOCA_PIN. Run it with E17B unset\n' "${E15_PROG:-e15}" "$1" >&2
}

e15_is_arm() {
  local a
  ! e15_e17a_arm_refused "$1" || return 1
  for a in "${E15_ARMS[@]}"; do [ "$a" = "$1" ] && return 0; done
  return 1
}

e15_on_ladder() {
  local n
  for n in "${E15_LADDER[@]}"; do [ "$n" = "$1" ] && return 0; done
  return 1
}

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() {
  printf '%s: %s\n' "${E15_PROG:-e15}" "$*" >&2
  exit 1
}
utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- guards ----------------------------------------------------------------------------------

# _lexical_path PATH: absolute, with . and .. resolved lexically (portable: no realpath -m).
_lexical_path() {
  local p=$1 parts=() seg
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  local IFS=/
  for seg in $p; do
    case "$seg" in
    '' | .) ;;
    ..) [ ${#parts[@]} -gt 0 ] && unset 'parts[${#parts[@]}-1]' ;;
    *) parts+=("$seg") ;;
    esac
  done
  printf '/%s\n' "${parts[*]}"
}

_under() { [ "$1" = "$2" ] || case "$1" in "$2"/*) return 0 ;; *) return 1 ;; esac }

refuse_shared_paths() {
  local p lp phys
  if [ "$E15_HOST_PROFILE" = fresh-metal ]; then
    refuse_outside_root "$@"
    return
  fi
  for p in "$@"; do
    lp=$(_lexical_path "$p")
    phys=$lp
    if [ -e "$lp" ]; then
      phys=$(cd -P "$(dirname "$lp")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename "$lp")") || phys=$lp
    fi
    if _under "$lp" "$E15_SHARED" || _under "$phys" "$E15_SHARED"; then
      printf 'refuse_shared_paths: %s is under %s (rig rule: E15 never writes there)\n' "$p" "$E15_SHARED" >&2
      exit 3
    fi
  done
}

refuse_ports() {
  local listening port
  listening=$(ss -ltnH 2>/dev/null | awk '{print $4}')
  for port in "$@"; do
    if printf '%s\n' "$listening" | grep -Eq ":${port}\$"; then
      printf 'refuse_ports: something already listens on port %s\n' "$port" >&2
      exit 3
    fi
  done
}

# refuse_outside_root PATH... (fresh-metal): exit 3 unless each PATH is under $E15_ROOT or is the
# manifest itself. Package installs (bootstrap.sh) are the only host changes outside it.
refuse_outside_root() {
  local p lp phys root_phys
  root_phys=$(cd -P "$E15_ROOT" 2>/dev/null && pwd -P) || root_phys=$E15_ROOT
  for p in "$@"; do
    lp=$(_lexical_path "$p")
    [ "$lp" = "$(_lexical_path "$E15_MANIFEST")" ] && continue
    # A symlink under the root that points out of it is outside too (the last component included).
    phys=$lp
    if [ -d "$lp" ]; then
      phys=$(cd -P "$lp" 2>/dev/null && pwd -P) || phys=$lp
    elif [ -e "$lp" ]; then
      phys=$(cd -P "$(dirname "$lp")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename "$lp")") || phys=$lp
      [ -L "$phys" ] && phys=$(_lexical_path "$(cd -P "$(dirname "$phys")" && readlink "$phys" | sed "s#^[^/]#$(pwd -P)/&#")")
    fi
    if ! _under "$lp" "$E15_ROOT" || ! { _under "$phys" "$E15_ROOT" || _under "$phys" "$root_phys"; }; then
      printf 'refuse_outside_root: %s is outside %s (fresh-metal rule: E15 writes only there)\n' "$p" "$E15_ROOT" >&2
      exit 3
    fi
  done
}

refuse_units() {
  local a
  if [ "$E15_HOST_PROFILE" = fresh-metal ]; then
    # Every argument is an option, a systemctl verb, or one of E15's own units. set-property is for e15.slice's
    # MemoryMax/MemoryHigh only (the E17b squeeze rung, e15_slice_squeeze): any other unit or property is refused.
    case " $* " in *" set-property "*)
      for a in "$@"; do
        case "$a" in -* | set-property | e15.slice | MemoryMax=* | MemoryHigh=*) ;; *)
          printf 'refuse_units: set-property %s: only e15.slice MemoryMax/MemoryHigh (fresh-metal rule)\n' "$a" >&2
          exit 3
          ;;
        esac
      done
      ;;
    esac
    for a in "$@"; do
      case "$a" in
      -* | start | stop | restart | reset-failed | daemon-reload | is-active | is-failed | status | show | e15.slice | e15-*) ;;
      set-property | MemoryMax=* | MemoryHigh=*) ;; # the set-property rule above
      *)
        printf 'refuse_units: %s is not an E15 unit (fresh-metal rule: E15 touches only its own)\n' "$a" >&2
        exit 3
        ;;
      esac
    done
    return 0
  fi
  for a in "$@"; do
    case "$a" in
    sh-* | */sh-*)
      printf 'refuse_units: %s is a shared sh-* unit (rig rule: E15 never touches it)\n' "$a" >&2
      exit 3
      ;;
    esac
  done
}

sctl() {
  refuse_units "$@"
  sudo -n systemctl "$@"
}

# --- manifest --------------------------------------------------------------------------------

m_init() {
  if [ ! -f "$E15_MANIFEST" ]; then
    printf '# E15 rig manifest (%s)\n\nEvery change E15 makes on this host, in order, with its undo.\n' \
      "$(hostname 2>/dev/null || echo host)" >"$E15_MANIFEST"
  fi
}
m_section() { printf '\n## %s %s\n' "$1" "$(utc)" >>"$E15_MANIFEST"; }
m_note() { printf -- '- %s %s\n' "$(utc)" "$*" >>"$E15_MANIFEST"; }
# m_change WHAT UNDO
m_change() { printf -- '- %s %s | UNDO: %s\n' "$(utc)" "$1" "$2" >>"$E15_MANIFEST"; }
# m_purge WHAT PURGE
m_purge() { printf -- '- %s %s | PURGE: %s\n' "$(utc)" "$1" "$2" >>"$E15_MANIFEST"; }
# m_has TEXT: the manifest already records TEXT (used to keep PURGE lines unique).
m_has() { [ -f "$E15_MANIFEST" ] && grep -qF -- "$1" "$E15_MANIFEST"; }
# m_cycle_has TEXT: a line after the manifest's last "## Teardown" header holds TEXT.
m_cycle_has() {
  [ -f "$E15_MANIFEST" ] || return 1
  local last
  last=$(grep -n '^## Teardown' "$E15_MANIFEST" | tail -1 | cut -d: -f1)
  tail -n +"$((${last:-0} + 1))" "$E15_MANIFEST" | grep -qF -- "$1"
}
# m_prestate STATE: record the host's pre-setup state (teardown.sh verifies against the last
# PRESTATE line) -- once per cycle. A setup run while E15 is already up would otherwise record
# E15's own stops (microvm-worker inactive, bench containers stopped) as the state to restore.
m_prestate() {
  if m_cycle_has " PRESTATE: "; then
    m_note "PRESTATE kept: this cycle's first setup recorded it (now: $1)"
  else
    m_note "PRESTATE: $1"
  fi
}

# --- small helpers ---------------------------------------------------------------------------

# Go on the rig: the modules need go 1.26, the host has 1.25.1. Everything under $E15_ROOT/go.
# One VAR=value per line: mapfile -t GOENV < <(e15_goenv user); env "${GOENV[@]}" go ...
e15_goenv() {
  local who=${1:-user}
  printf '%s\n' GOTOOLCHAIN=go1.26.0 GOWORK=off "GOPATH=$E15_ROOT/go/$who" \
    "GOMODCACHE=$E15_ROOT/go/$who/mod" "GOCACHE=$E15_ROOT/go/$who/cache"
  # fresh-metal: the host has no go/node; bootstrap.sh's are first on PATH, caches under /srv/e15.
  [ "$E15_HOST_PROFILE" != fresh-metal ] || e15_userenv "$who"
}

# e15_userenv [WHO] (fresh-metal): VAR=value lines that keep every tool's PATH, cache and config
# under /srv/e15 (npm, corepack, pnpm's XDG dirs, go telemetry). Empty on aws-prelim.
e15_userenv() {
  local who=${1:-user} x=$E15_ROOT/xdg/${1:-user}
  [ "$E15_HOST_PROFILE" = fresh-metal ] || return 0
  printf '%s\n' "PATH=$(e15_path)" "npm_config_cache=$E15_ROOT/npm-cache/$who" \
    "COREPACK_HOME=$E15_COREPACK_HOME" COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
    "XDG_CACHE_HOME=$x/cache" "XDG_CONFIG_HOME=$x/config" "XDG_DATA_HOME=$x/data" "XDG_STATE_HOME=$x/state"
}

# --- host profile ----------------------------------------------------------------------------

# Toolchain directories bootstrap.sh fills (fresh-metal only).
E15_GO_ROOT=$E15_ROOT/go-toolchain
E15_NODE_ROOT=$E15_ROOT/node
E15_COREPACK_HOME=$E15_ROOT/corepack

# e15_path: the PATH the rig's commands run with. aws-prelim: the system's (unchanged).
# fresh-metal: /srv/e15/bin, then the pinned Go and Node, then the system's sbin/bin.
e15_path() {
  if [ "$E15_HOST_PROFILE" = fresh-metal ]; then
    printf '%s\n' "$E15_ROOT/bin:$E15_GO_ROOT/bin:$E15_NODE_ROOT/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  else
    printf '%s\n' "/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin"
  fi
}

# e15_node: the node binary the relay unit runs.
e15_node() {
  if [ "$E15_HOST_PROFILE" = fresh-metal ]; then echo "$E15_NODE_ROOT/bin/node"; else echo /usr/bin/node; fi
}

# e15_os_id: ID from /etc/os-release (E15_OS_RELEASE overrides the file, for tests).
# shellcheck disable=SC1090,SC1091  # /etc/os-release, or a test fixture
e15_os_id() { (. "${E15_OS_RELEASE:-/etc/os-release}" 2>/dev/null && echo "${ID:-unknown}") || echo unknown; }

# e15_pkg_mgr: the host's package manager (Ubuntu/Debian apt; AL2023/Fedora dnf).
e15_pkg_mgr() {
  case "$(e15_os_id)" in
  ubuntu | debian) echo apt ;;
  amzn | fedora | rhel | centos | rocky | almalinux) echo dnf ;;
  *) echo unknown ;;
  esac
}
e15_pkg_installed() {
  case "$(e15_pkg_mgr)" in
  apt) dpkg-query -W -f '${Status}' "$1" 2>/dev/null | grep -q 'install ok installed' ;;
  dnf) rpm -q "$1" >/dev/null 2>&1 ;;
  *) return 1 ;;
  esac
}
# e15_pkg_remove_cmd PKG...: the command that removes exactly PKG... (apt: purge, conffiles too;
# no autoremove, which could take auto-installed packages that predate E15).
e15_pkg_remove_cmd() {
  case "$(e15_pkg_mgr)" in
  apt) echo "sudo -n env DEBIAN_FRONTEND=noninteractive apt-get purge -y $*" ;;
  dnf) echo "sudo -n dnf remove -y $*" ;;
  *) echo "false # no package manager for $*" ;;
  esac
}
# e15_dpkg_list: every installed package (dpkg "ii"), arch-qualified where dpkg does, sorted.
e15_dpkg_list() {
  { dpkg-query -W -f '${db:Status-Abbrev} ${binary:Package}\n' 2>/dev/null || true; } | awk '$1 ~ /^ii/ {print $2}' | sort
}
# e15_enabled_units: every enabled unit file (read only, no sudo), sorted.
e15_enabled_units() {
  { systemctl list-unit-files --state=enabled --no-legend --no-pager 2>/dev/null || true; } | awk 'NF {print $1}' | sort
}

# e15_require_pins: die naming every empty pins.sh constant (fresh-metal never guesses a checksum).
e15_require_pins() {
  local n empty=()
  for n in "${E15_PINS[@]}"; do [ -n "${!n:-}" ] || empty+=("$n"); done
  [ ${#empty[@]} -eq 0 ] || die "empty pin(s) in pins.sh, the operator must fill them: ${empty[*]}"
}

# e15_fetch URL SHA256 OUT: download URL to OUT and check its sha256; a mismatch removes OUT and
# fails. An OUT already present with the right sha256 is kept (no download). E15_FETCH overrides
# the downloader (tests): it is called as "$E15_FETCH URL OUT".
e15_fetch() {
  local url=$1 want=$2 out=$3 got
  [ -n "$want" ] || die "e15_fetch: no checksum for $url"
  if [ -f "$out" ] && [ "$(sha256_of "$out")" = "$want" ]; then return 0; fi
  rm -f "$out.part"
  if [ -n "${E15_FETCH:-}" ]; then
    "$E15_FETCH" "$url" "$out.part" || die "download failed: $url"
  else
    curl -fsSL --retry 3 -o "$out.part" "$url" || die "download failed: $url"
  fi
  got=$(sha256_of "$out.part")
  if [ "$got" != "$want" ]; then
    rm -f "$out.part"
    die "checksum mismatch for $url: got $got, want $want"
  fi
  mv -f "$out.part" "$out"
}

# probe_reflink DIR [SRCDIR]: "reflink" if `cp --reflink=always` of a file in SRCDIR (default DIR)
# into DIR works, else "sparse".
probe_reflink() {
  local d=$1 s=${2:-$1} r=sparse
  printf 'e15 reflink probe\n' >"$s/.reflink-probe.src"
  cp --reflink=always "$s/.reflink-probe.src" "$d/.reflink-probe.dst" 2>/dev/null && r=reflink
  rm -f "$s/.reflink-probe.src" "$d/.reflink-probe.dst"
  echo "$r"
}

# e15_require_reflink WSDIR SRCDIR (fresh-metal, SPEC §13): reflink is required. Probes on every
# call (never cached) a `cp --reflink=always` from SRCDIR (the template's directory) into WSDIR
# (the workspaces directory) -- the copy rung.sh makes. Records state/workspace_copy=reflink, or
# removes it and dies: no sparse fallback.
e15_require_reflink() {
  if [ "$(probe_reflink "$1" "$2")" != reflink ]; then
    rm -f "$E15_STATE/workspace_copy"
    die "fresh-metal: cp --reflink=always from $2 into $1 fails; reflink is required (no sparse fallback): mount an XFS reflink=1 volume at $E15_ROOT (bootstrap.sh E15_DATA_DEV=/dev/...)"
  fi
  mkdir -p "$E15_STATE"
  printf 'reflink\n' >"$E15_STATE/workspace_copy"
}

# e15_xfs_reflink MOUNTPOINT: the XFS filesystem mounted there has reflink=1 (xfs_info).
# The output is captured first: `xfs_info | grep -q` under pipefail can fail on SIGPIPE.
e15_xfs_reflink() {
  local out
  out=$(sudo -n xfs_info "$1" 2>/dev/null) || return 1
  case "$out" in *reflink=1*) return 0 ;; *) return 1 ;; esac
}

# e15_storage_check DIR... (fresh-metal): every DIR on one filesystem device (stat -c %d), and that
# filesystem XFS with reflink=1. moca's worker hardlinks the snapshot files and the workspace image
# into the jail, so SH_SNAPSHOT_DIR, SH_WORKSPACE_ROOT and SH_CHROOT_BASE must share a device
# (remote-worker vmpool devicecheck.go; it refuses to start otherwise), and a reflink cannot cross
# filesystems, so the templates must be there too. Prints one line; dies naming each DIR's device.
e15_storage_check() {
  local d dev first="" same=1 devs=() fst mnt
  for d in "$@"; do
    dev=$(stat -c %d "$d" 2>/dev/null) || die "storage: cannot stat $d"
    devs+=("$d=$dev")
    [ -n "$first" ] || first=$dev
    [ "$dev" = "$first" ] || same=0
  done
  [ "$same" = 1 ] || die "storage: ${devs[*]} are not on one filesystem device (moca's worker hardlinks snapshot and workspace files into the jail; reflink cannot cross filesystems): mount the XFS volume at $E15_ROOT, the whole E15 root (bootstrap.sh E15_DATA_DEV=/dev/...)"
  fst=$(findmnt -no FSTYPE -T "$1" 2>/dev/null || true)
  mnt=$(findmnt -no TARGET -T "$1" 2>/dev/null || true)
  [ "$fst" = xfs ] || die "storage: $1 is on ${fst:-an unknown filesystem} ($mnt), not XFS: mount an XFS reflink=1 volume at $E15_ROOT (bootstrap.sh E15_DATA_DEV=/dev/...)"
  e15_xfs_reflink "$mnt" || die "storage: the XFS filesystem at $mnt has no reflink=1 (mkfs.xfs -m reflink=1)"
  echo "storage: ${devs[*]} on one device, XFS reflink=1 at $mnt ($(findmnt -no SOURCE -T "$1" 2>/dev/null || echo source unknown))"
}

# e15_root_purge_cmd: the PURGE command that removes E15's files. aws-prelim: rm -rf of the root,
# as before. fresh-metal: when the root is a mount point (the E15 data volume), its contents only
# -- the mount and its fstab line are bootstrap.sh's own PURGE lines, replayed after this one.
# e15_root_purge_mount_aware_cmd: that command, whatever the profile (teardown.sh replays it in
# place of an older `sudo -n rm -rf <root>` line when the root is a mount point).
e15_root_purge_mount_aware_cmd() {
  printf '%s\n' "sudo -n bash -c 'if mountpoint -q \"\$1\"; then find \"\$1\" -mindepth 1 -maxdepth 1 -exec rm -rf {} +; else rm -rf \"\$1\"; fi' _ $E15_ROOT"
}
e15_root_purge_cmd() {
  if [ "$E15_HOST_PROFILE" = fresh-metal ]; then
    e15_root_purge_mount_aware_cmd
  else
    printf '%s\n' "sudo -n rm -rf $E15_ROOT"
  fi
}

# workspace_copy_mode: the state setup.sh recorded (reflink | sparse); reflink when none (the
# preliminary rig, whose setup predates the probe, is XFS).
workspace_copy_mode() {
  local m
  m=$(cat "$E15_STATE/workspace_copy" 2>/dev/null) || m=reflink
  case "$m" in reflink | sparse) echo "$m" ;; *) echo reflink ;; esac
}

# workspace_cp_flag MODE: the cp flag that makes one workspace copy.
workspace_cp_flag() {
  case "$1" in sparse) echo --sparse=always ;; *) echo --reflink=always ;; esac
}

# workspace_disk_estimate N K IMAGE_MB COPY_KB FREE_KB: one line for the operator, exit 1 when the
# N*K copies' estimated cost plus a 10% margin exceeds FREE_KB. COPY_KB is what one copy is
# estimated to cost: sparse, the template's allocated size (paid at creation); reflink, the
# per-session delta (workspace_delta_kb). The worst case is every guest writing its whole image.
workspace_disk_estimate() {
  local n=$1 k=$2 mb=$3 ckb=$4 fkb=$5 imgs
  imgs=$((n * k))
  awk -v i="$imgs" -v mb="$mb" -v c="$ckb" -v f="$fkb" -v n="$n" -v k="$k" 'BEGIN {
    est = i * c / 1048576; worst = i * mb / 1024; free = f / 1048576
    printf "N=%d: %d images (K=%d) x %d MiB = %.1f GiB worst case; %.1f GiB estimated, %.1f GiB with the 10%% margin; %.1f GiB free\n", n, i, k, mb, worst, est, est * 1.1, free
    exit (i * c * 11 > f * 10) ? 1 : 0 }'
}

# workspace_delta_kb TEMPLATE DATASET_MIB: the estimated disk cost of one reflinked workspace copy
# (fresh-metal). A reflinked copy costs nothing at creation; a guest un-shares the blocks it
# writes. The estimate assumes a session rewrites everything its image holds (project tree, ext4
# journal and metadata: the template's allocated size) except data.bin, which the mem512 scan only
# reads. E15_WS_DELTA_MB overrides it. Floor 1 MiB.
workspace_delta_kb() {
  local kb
  if [ -n "${E15_WS_DELTA_MB:-}" ]; then
    echo $((E15_WS_DELTA_MB * 1024))
    return
  fi
  kb=$(($(du -k "$1" | cut -f1) - ${2:-0} * 1024))
  [ "$kb" -ge 1024 ] || kb=1024
  echo "$kb"
}

# --- containers (Redis; fresh-metal also the rootfs image) -------------------------------------
# fresh-metal keeps root podman's storage under /srv/e15 (CONTAINERS_STORAGE_CONF), so no image or
# layer lands in /var/lib/containers. aws-prelim: root podman as before.
E15_PODMAN_CONF=$E15_ROOT/containers/storage.conf
e15_podman_str() {
  if [ "$E15_HOST_PROFILE" = fresh-metal ]; then
    echo "sudo -n env CONTAINERS_STORAGE_CONF=$E15_PODMAN_CONF podman"
  else
    echo "sudo -n podman"
  fi
}
e15_podman() {
  if [ "$E15_HOST_PROFILE" = fresh-metal ]; then
    # No storage.conf (before bootstrap, after --purge): podman must not fall back to
    # /var/lib/containers, so there is no E15 container to see.
    [ -f "$E15_PODMAN_CONF" ] || return 1
    sudo -n env CONTAINERS_STORAGE_CONF="$E15_PODMAN_CONF" podman "$@"
  else
    sudo -n podman "$@"
  fi
}
e15_podman_conf_body() {
  printf '[storage]\ndriver = "overlay"\ngraphroot = "%s"\nrunroot = "%s"\n' \
    "$E15_ROOT/containers/storage" "$E15_ROOT/containers/run"
}

# e15_artifact NAME SHA256 SOURCE (fresh-metal): one line per artifact in $E15_STATE/artifacts,
# replaced when NAME is recorded again.
e15_artifact() {
  mkdir -p "$E15_STATE"
  local f=$E15_STATE/artifacts
  touch "$f"
  { grep -v "^$1 " "$f" || true; } >"$f.new"
  printf '%s %s %s\n' "$1" "$2" "$3" >>"$f.new"
  mv -f "$f.new" "$f"
}

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

# dd_mbs: from dd's summary on stdin ("<bytes> bytes (...) copied, <secs> s, ..."), MB/s
# (10^6 bytes per second) computed from bytes and seconds (dd's own rate is rounded and unit-varied).
dd_mbs() {
  awk '/ bytes .* copied, / {b=$1; for (i=1;i<=NF;i++) if ($i=="s," || $i=="seconds,") s=$(i-1); sub(",","",s)}
    END {if (b>0 && s>0) printf "%.1f\n", b/1e6/s; else exit 1}'
}

# measure_disk_read FILE [MIB]: the volume's sequential read throughput (SPEC §10.3, mem512's
# disk_io binding): write MIB (default 2048) MiB to FILE with direct I/O, read it back with direct
# I/O (no page cache), remove it, print MB/s. FILE must be on the volume holding the workspaces.
measure_disk_read() {
  local f=$1 mib=${2:-2048} out
  dd if=/dev/zero of="$f" bs=4M count=$((mib / 4)) oflag=direct conv=fsync status=none || {
    rm -f "$f"
    return 1
  }
  out=$(dd if="$f" of=/dev/null bs=4M iflag=direct 2>&1)
  rm -f "$f"
  printf '%s\n' "$out" | dd_mbs
}

# measure_disk_read_parallel PREFIX [STREAMS] [MIB] (fresh-metal): STREAMS (default 4) separate
# MIB (default 2048) MiB files PREFIX.<i>, written with direct I/O, then read back by STREAMS
# concurrent `dd iflag=direct bs=4M` readers; prints the SUM of the readers' MB/s. One stream does
# not saturate an EBS volume (its per-I/O latency caps it), the rungs' many guests do. Every file is
# removed, whatever fails.
measure_disk_read_parallel() {
  local pre=$1 n=${2:-4} mib=${3:-2048} i rc=0 pids=()
  for ((i = 0; i < n; i++)); do
    dd if=/dev/zero of="$pre.$i" bs=4M count=$((mib / 4)) oflag=direct conv=fsync status=none || rc=1
  done
  if [ "$rc" = 0 ]; then
    for ((i = 0; i < n; i++)); do
      dd if="$pre.$i" of=/dev/null bs=4M iflag=direct 2>"$pre.$i.out" &
      pids+=($!)
    done
    for i in "${pids[@]}"; do wait "$i" || rc=1; done
  fi
  local sum=0 v
  if [ "$rc" = 0 ]; then
    for ((i = 0; i < n; i++)); do
      v=$(dd_mbs <"$pre.$i.out") || {
        rc=1
        break
      }
      sum=$(awk -v a="$sum" -v b="$v" 'BEGIN {printf "%.1f", a + b}')
    done
  fi
  for ((i = 0; i < n; i++)); do rm -f "$pre.$i" "$pre.$i.out"; done
  [ "$rc" = 0 ] || return 1
  echo "$sum"
}

# unit_active UNIT: systemctl is-active, quiet (reading state needs no sudo).
unit_active() {
  refuse_units "$1"
  systemctl is-active --quiet "$1"
}

# --- E15 paths -------------------------------------------------------------------------------

E15_SRC=$E15_ROOT/src/e15
E15_BIN=$E15_ROOT/bin
E15_SECRETS=$E15_ROOT/secrets
E15_STATE=$E15_ROOT/state
E15_LOGS=$E15_ROOT/logs
E15_MOCA=$E15_ROOT/moca
[ "${E17B:-}" != 1 ] || E15_MOCA=$E15_ROOT/moca-e17b # E17b profile (above): its own checkout
[ "${E17C:-}" != 1 ] || E15_MOCA=$E15_ROOT/moca-e17c # E17c profile (above): its own checkout
E15_SNAPDIR=$E15_ROOT/snapshots
E15_SNAPIMG=e15
E15_TEMPLATE=$E15_ROOT/template/workspace.img
E15_WORKSPACES=$E15_ROOT/workspaces
E15_JAIL=$E15_ROOT/jail
E15_RUNS=$E15_ROOT/runs
E15_CORPORA=$E15_ROOT/corpora
E15_CG=/sys/fs/cgroup/e15.slice
E15_VMCG=$E15_CG/e15-vms.slice

# stamp_ok NAME KEY / stamp_set NAME KEY: a build step is skipped when its stamp holds KEY.
stamp_ok() { [ -f "$E15_STATE/$1" ] && [ "$(cat "$E15_STATE/$1")" = "$2" ]; }
stamp_get() { cat "$E15_STATE/$1" 2>/dev/null; }
# refuse_driver_rebuild STAMP BIN KEY (setup.sh with E17B unset; ruling E17B-R37): die rather than overwrite an EXISTING
# sealed driver binary whose stamp records another driver source key, unless E15_ACK_DRIVER_REBUILD=1. A fresh rig (no
# binary, or no stamp) builds as before.
refuse_driver_rebuild() {
  local stamp=$1 bin=$2 key=$3 old
  [ -e "$bin" ] || return 0
  old=$(stamp_get "$stamp") || old=""
  if [ -z "$old" ] || [ "$old" = "$key" ]; then return 0; fi
  if [ "${E15_ACK_DRIVER_REBUILD:-0}" = 1 ]; then
    log "E15_ACK_DRIVER_REBUILD=1: rebuilding $bin (stamp $stamp $old -> $key)"
    return 0
  fi
  die "refusing to rebuild the existing $bin: its stamp $stamp is $old, the driver source is now $key. The sealed rungs that ran it record its sha256. This checkout's driver changes are opt-in flags and the default path is golden-tested unchanged (driver TestDefaultPathUnchanged), but a rebuild still replaces the binary: keep it (E17B=1 builds its own -e17b drivers), or set E15_ACK_DRIVER_REBUILD=1 to rebuild it knowingly"
}
stamp_set() {
  mkdir -p "$E15_STATE"
  printf '%s\n' "$2" >"$E15_STATE/$1"
}

# wait_for SECONDS CMD...: poll CMD every 0.5 s until it succeeds or SECONDS pass.
wait_for() {
  local deadline=$((SECONDS + $1))
  shift
  until "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.5
  done
}

port_listening() { ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "^127\.0\.0\.1:$1\$"; }

# --- memory guards (Task 8 mem512 OOM incident, user decision a+b) ---------------------------

# E15_MEMINFO: the meminfo file the guards read (tests point it at a fake one).
E15_MEMINFO=${E15_MEMINFO:-/proc/meminfo}
# e15_slice_limits MEMTOTAL_KB: "MEMORYMAX MEMORYHIGH" in bytes for e15.slice. MemoryMax = MemTotal
# - 3 GiB, so the slice's own OOM acts before the host's (2 GiB left the global OOM killer to run
# first); MemoryHigh = MemoryMax - 1 GiB, so the slice is throttled and reclaimed before that.
e15_slice_limits() {
  local mib=$(($1 / 1024))
  local max=$(((mib - 3072) * 1024 * 1024))
  printf '%s %s\n' "$max" "$((max - 1024 * 1024 * 1024))"
}

# e15_squeeze_limits MB (E17b squeeze rungs): "MEMORYMAX MEMORYHIGH" in bytes for e15.slice lowered to MB MiB,
# MemoryHigh = MemoryMax - 1 GiB as in e15_slice_limits.
e15_squeeze_limits() {
  local max=$(($1 * 1024 * 1024))
  printf '%s %s\n' "$max" "$((max - 1024 * 1024 * 1024))"
}

# e15_slice_squeeze MB WHY (rung.sh, E15_SQUEEZE_MEMMAX_MB): lower e15.slice to MB MiB for one rung with
# `systemctl set-property --runtime` (a /run drop-in: gone at reboot). The values to restore are read first with
# `systemctl show`, never recomputed, into E15_SQUEEZE_ORIG_MAX/E15_SQUEEZE_ORIG_HIGH; a squeeze only lowers
# MemoryMax. One manifest line (m_change) whose UNDO restores them is written before the change, and
# E15_SQUEEZE_ACTIVE=1 is set before it too (a failed set-property may have applied one property), so
# e15_slice_unsqueeze restores on every path. Dies on a refusal or a failure.
e15_slice_squeeze() {
  local mb=$1 why=$2 cur max high
  cur=$(sctl show "$E15_SLICE" --property=MemoryMax,MemoryHigh) || die "systemctl show $E15_SLICE failed: the values to restore are unknown, nothing changed"
  E15_SQUEEZE_ORIG_MAX=$(printf '%s\n' "$cur" | sed -n 's/^MemoryMax=//p')
  E15_SQUEEZE_ORIG_HIGH=$(printf '%s\n' "$cur" | sed -n 's/^MemoryHigh=//p')
  [[ "$E15_SQUEEZE_ORIG_MAX" =~ ^[0-9]+$ ]] ||
    die "$E15_SLICE MemoryMax is '$E15_SQUEEZE_ORIG_MAX', not a byte count (setup.sh sets one): refusing to squeeze it"
  [[ "$E15_SQUEEZE_ORIG_HIGH" =~ ^([0-9]+|infinity)$ ]] ||
    die "$E15_SLICE MemoryHigh is '$E15_SQUEEZE_ORIG_HIGH', not a byte count or infinity: refusing to squeeze it"
  read -r max high < <(e15_squeeze_limits "$mb")
  [ "$max" -le "$E15_SQUEEZE_ORIG_MAX" ] ||
    die "E15_SQUEEZE_MEMMAX_MB=$mb ($max bytes) is above $E15_SLICE's MemoryMax $E15_SQUEEZE_ORIG_MAX: a squeeze only lowers it"
  E15_SQUEEZE_MAX=$max
  E15_SQUEEZE_HIGH=$high
  m_init
  m_change "$E15_SLICE MemoryMax=$max MemoryHigh=$high (runtime, $why; was MemoryMax=$E15_SQUEEZE_ORIG_MAX MemoryHigh=$E15_SQUEEZE_ORIG_HIGH)" \
    "sudo -n systemctl set-property --runtime $E15_SLICE MemoryMax=$E15_SQUEEZE_ORIG_MAX MemoryHigh=$E15_SQUEEZE_ORIG_HIGH; sudo -n rm -f -- $(e15_slice_dropins | paste -sd' ' -); sudo -n systemctl daemon-reload"
  E15_SQUEEZE_ACTIVE=1
  sctl set-property --runtime "$E15_SLICE" "MemoryMax=$max" "MemoryHigh=$high" ||
    die "systemctl set-property --runtime $E15_SLICE MemoryMax=$max MemoryHigh=$high failed"
  log "$E15_SLICE squeezed: MemoryMax=$max MemoryHigh=$high (was $E15_SQUEEZE_ORIG_MAX / $E15_SQUEEZE_ORIG_HIGH)"
}

# e15_slice_dropins: the two runtime drop-ins `set-property --runtime` writes for e15.slice (systemd's system.control
# directory). The restore removes exactly these two files; nothing else under /run is ever deleted. (A function, not a
# variable: lib.sh defines no new E15_* variable for the sealed procedures.)
e15_slice_dropins() { printf '%s\n' /run/systemd/system.control/e15.slice.d/50-MemoryMax.conf /run/systemd/system.control/e15.slice.d/50-MemoryHigh.conf; }

# e15_slice_unsqueeze: restore what e15_slice_squeeze read (a no-op when nothing was squeezed), then remove the two
# runtime drop-ins and daemon-reload, so the slice is back to its unit file only. Never dies, so a trap can call it:
# returns 1 when the restore failed (logged with the command; the manifest's UNDO line has it too).
e15_slice_unsqueeze() {
  [ "${E15_SQUEEZE_ACTIVE:-0}" = 1 ] || return 0
  local dmax dhigh
  { read -r dmax && read -r dhigh; } < <(e15_slice_dropins)
  if sctl set-property --runtime "$E15_SLICE" "MemoryMax=$E15_SQUEEZE_ORIG_MAX" "MemoryHigh=$E15_SQUEEZE_ORIG_HIGH"; then
    E15_SQUEEZE_ACTIVE=0
    m_note "$E15_SLICE restored: MemoryMax=$E15_SQUEEZE_ORIG_MAX MemoryHigh=$E15_SQUEEZE_ORIG_HIGH"
    log "$E15_SLICE restored: MemoryMax=$E15_SQUEEZE_ORIG_MAX MemoryHigh=$E15_SQUEEZE_ORIG_HIGH"
    case "$dmax $dhigh" in
    "/run/systemd/system.control/e15.slice.d/50-MemoryMax.conf /run/systemd/system.control/e15.slice.d/50-MemoryHigh.conf") ;;
    *)
      log "WARNING: refusing to remove drop-ins other than e15.slice's 50-MemoryMax.conf/50-MemoryHigh.conf"
      return 1
      ;;
    esac
    if sudo -n rm -f -- "$dmax" "$dhigh" && sctl daemon-reload; then
      E15_SQUEEZE_RESTORED=1
      m_note "$E15_SLICE runtime drop-ins removed ($dmax, $dhigh), daemon-reload"
      return 0
    fi
    log "WARNING: $E15_SLICE values restored, but removing its runtime drop-ins or daemon-reload failed; run: sudo -n rm -f -- $dmax $dhigh; sudo -n systemctl daemon-reload"
    return 1
  fi
  log "WARNING: could not restore $E15_SLICE; run: sudo -n systemctl set-property --runtime $E15_SLICE MemoryMax=$E15_SQUEEZE_ORIG_MAX MemoryHigh=$E15_SQUEEZE_ORIG_HIGH (the manifest's UNDO line)"
  return 1
}

# memavail_kb: MemAvailable in kB from $E15_MEMINFO (empty if unreadable).
memavail_kb() { awk '$1=="MemAvailable:"{print $2; exit}' "$E15_MEMINFO" 2>/dev/null; }

# memavail_watchdog MARKER [FLOOR_MIB] [N] [INTERVAL_S]: sample MemAvailable every INTERVAL_S (1);
# when it is below FLOOR_MIB (E15_MEMAVAIL_FLOOR_MIB, default 1024) for N (3) consecutive samples,
# write MARKER ("memory_floor <utc> <memavail_kb>"), kill every E15 VM (kill_vm_cgroups) and return
# 0. Runs until killed otherwise. rung.sh runs it beside the driver and aborts the rung on MARKER.
memavail_watchdog() {
  local marker=$1 floor_mib=${2:-${E15_MEMAVAIL_FLOOR_MIB:-1024}} need=${3:-3} iv=${4:-1}
  local below=0 kb
  while :; do
    kb=$(memavail_kb)
    if [ -n "$kb" ] && [ "$kb" -lt $((floor_mib * 1024)) ]; then
      below=$((below + 1))
    else
      below=0
    fi
    if [ "$below" -ge "$need" ]; then
      printf 'memory_floor %s %s\n' "$(utc)" "$kb" >"$marker"
      kill_vm_cgroups
      return 0
    fi
    sleep "$iv"
  done
}

# --- E15's own units -------------------------------------------------------------------------

# kill_vm_cgroups: kill every process left in a VM cgroup under e15-vms.slice (never the worker's
# own service cgroup) and remove the empty pool directories the worker created. E15's own tree only.
kill_vm_cgroups() {
  [ -d "$E15_VMCG" ] || return 0
  sudo -n bash -c '
    for d in "$1"/*/; do
      d=${d%/}; n=${d##*/}
      case "$n" in *.service|*.scope|*.slice) continue ;; esac
      # cgroupfs files report size 0, so test the content: [ -s cgroup.procs ] is always false
      [ -f "$d/cgroup.kill" ] && [ -n "$(cat "$d/cgroup.procs" 2>/dev/null)" ] && echo 1 >"$d/cgroup.kill"
    done
    sleep 0.5
    for d in "$1"/*/; do
      d=${d%/}; n=${d##*/}
      case "$n" in *.service|*.scope|*.slice) continue ;; esac
      rmdir "$d" 2>/dev/null || true
    done' _ "$E15_VMCG"
}

# stop_e15_unit UNIT: stop one of E15's transient units if it is loaded; forget a failed one.
stop_e15_unit() {
  case "$1" in e15-*) ;; *) die "stop_e15_unit: $1 is not an E15 unit" ;; esac
  if systemctl is-active --quiet "$1" || systemctl is-failed --quiet "$1"; then
    sctl stop "$1" >/dev/null 2>&1 || true
  fi
  sctl reset-failed "$1" >/dev/null 2>&1 || true
}

# stop_rung_units: the per-rung units and any VM they left behind.
stop_rung_units() {
  stop_e15_unit "$E15_UNIT_WORKER"
  stop_e15_unit "$E15_UNIT_NULL"
  kill_vm_cgroups
}

# worker_env ARM OUT [IMAGE_MB]: write the worker's non-secret environment for ARM (SPEC §7.1-§7.2).
# IMAGE_MB is the point's workspace image size (points.sh E15_P_IMAGE_MB; default 256).
worker_env() {
  local arm=$1 out=$2 image_mb=${3:-256} depth committed=$E15_MAX_COMMITTED_MB slots=256 snap ram
  snap=$(worker_snapimg) || exit 1
  ram=$(worker_guest_ram_mb) || exit 1
  case "$arm" in
  sbx) depth=2 ;;
  resident-inf | resident-300) depth=0 ;;
  lease-30 | lease-120) depth=0 ;; # E17 (fresh-metal only; E15_ARMS)
  ship-30 | ship-120 | ship-300 | ship-300-nd)
    # E17b (E17B=1): the shipped lease. Admission is bounded by host RAM less 8 GiB (spec §6) and the slots sit above the
    # ladder's top N; the lease knobs (SH_LEASE_*) are left unset, so the worker's defaults stand and its banner prints them.
    # E17c's ship-300-nd (E17C=1) is ship-300 plus SH_LEASE_CACHE_DROP_S=0 (the idle page-cache drop off; below).
    [ "${E17B:-}" = 1 ] || die "worker_env: arm $arm exists only under E17B=1"
    [ "$arm" != ship-300-nd ] || [ "${E17C:-}" = 1 ] || die "worker_env: arm $arm exists only under E17C=1"
    # Standby depth 2, the worker's default (ruling E17B-R44): the stock microvm-worker refuses SH_STANDBY_DEPTH=0
    # ("must be a positive integer"; vmpool treats <= 0 as the default) and a shipped lease is promoted from a standby,
    # so depth 0 (the E15 resident patch's setting, E17a) is not a configuration the shipped worker has.
    depth=2
    local mem_kb top=0 n
    mem_kb=$(awk '/^MemTotal:/{print $2}' "$E15_MEMINFO" 2>/dev/null)
    [[ "$mem_kb" =~ ^[1-9][0-9]*$ ]] || die "worker_env: no MemTotal in $E15_MEMINFO: the lease admission budget (host RAM - 8192 MiB) cannot be derived"
    committed=$((mem_kb / 1024 - 8192))
    [ "$committed" -gt 0 ] || die "worker_env: host RAM $((mem_kb / 1024)) MiB leaves no admission budget above 8192 MiB"
    for n in "${E15_LADDER[@]}"; do [ "$n" -le "$top" ] || top=$n; done
    slots=$((top + 256))
    ;;
  *) die "worker_env: no worker for arm $arm" ;;
  esac
  # E17b squeeze (E17B-R20; rung.sh allows E15_SQUEEZE_MEMMAX_MB at POINT squeeze only): the worker never reads
  # e15.slice's MemoryMax. Its memory_reclaim fires on the committed budget (admission) or on host MemAvailable below
  # its reclaim floor, so the no-overcommit rule is applied to the squeezed host: every arm at the point (ship-300 and
  # sbx alike) gets SH_MAX_COMMITTED_MB = MemoryMax - 8192. The host-MemAvailable reclaim trigger is not exercised by
  # the squeeze (the host itself stays large).
  if [ "${E17B:-}" = 1 ] && [ -n "${E15_SQUEEZE_MEMMAX_MB:-}" ]; then
    committed=$((E15_SQUEEZE_MEMMAX_MB - 8192))
    [ "$committed" -gt 0 ] || die "worker_env: E15_SQUEEZE_MEMMAX_MB=$E15_SQUEEZE_MEMMAX_MB leaves no committed budget (MemoryMax - 8192 MiB)"
  fi
  {
    echo "RELAY_ADDR=127.0.0.1:$E15_PORT_ATTACH"
    echo "RELAY_TLS=false"
    echo "SANDBOX_ID=e15"
    echo "SH_VMM=firecracker"
    echo "SH_JAILER_BIN=$E15_JAILER"
    echo "SH_FIRECRACKER_BIN=$E15_FIRECRACKER"
    echo "SH_SNAPSHOT_DIR=$E15_SNAPDIR"
    echo "SH_SNAPSHOT_IMAGE=$snap"
    echo "SH_WORKSPACE_ROOT=$E15_WORKSPACES"
    echo "SH_CHROOT_BASE=$E15_JAIL"
    echo "SH_PARENT_CGROUP=$E15_PARENT_CGROUP"
    echo "SH_GUEST_RAM_MB=$ram"
    echo "SH_STANDBY_DEPTH=$depth"
    echo "WORKER_MAX_CONCURRENT=$slots"
    echo "SH_MAX_RUNS=$E15_MAX_RUNS"
    echo "SH_MAX_COMMITTED_MB=$committed"
    echo "SH_HOST_MEM_FLOOR_MB=$E15_FLOOR_MB"
    echo "SH_WORKSPACE_IMAGE_MB=$image_mb"
    echo "SH_WORKSPACE_IDLE=24h"
    echo "SH_DIAG_STATS_ADDR=127.0.0.1:$E15_PORT_STATS"
    echo "SH_DIAG_PHASES=1"
    echo "TZ=UTC"
    case "$arm" in
    resident-inf) printf 'E15_RESIDENT=1\nE15_RESIDENT_IDLE_S=0\n' ;;
    resident-300) printf 'E15_RESIDENT=1\nE15_RESIDENT_IDLE_S=300\n' ;;
    lease-30) printf 'E15_RESIDENT=1\nE15_RESIDENT_IDLE_S=30\n' ;;
    lease-120) printf 'E15_RESIDENT=1\nE15_RESIDENT_IDLE_S=120\n' ;;
    ship-300-nd) echo "SH_LEASE_CACHE_DROP_S=0" ;; # E17c: the idle page-cache drop off (moca #974; unset = 30 s)
    esac
  } >"$out"
}

# E17b (E17B=1, ruling E17B-R3): the stock worker and null-responder are built to their own binaries
# and stamp, so the sealed E15/E16/E17a binaries are never overwritten. Unchanged with E17B unset.
stock_worker_bin() { if [ "${E17B:-}" = 1 ]; then echo "$E15_BIN/microvm-worker-e17b"; else echo "$E15_BIN/microvm-worker"; fi; }
null_bin() { if [ "${E17B:-}" = 1 ]; then echo "$E15_BIN/null-responder-e17b"; else echo "$E15_BIN/null-responder"; fi; }
stock_stamp() { if [ "${E17B:-}" = 1 ]; then echo go-stock-e17b; else echo go-stock; fi; }
# e17b_require_build: under E17B=1 the stock binaries must have been built at E15_MOCA_PIN (rung.sh).
e17b_require_build() {
  stamp_ok go-stock-e17b "$E15_MOCA_PIN" ||
    die "E17B=1 but the go-stock-e17b build stamp in $E15_STATE is not for $E15_MOCA_PIN; run setup.sh with E17B=1"
}
# e17b_lease_arm ARM: true for an E17b shipped-lease arm (ship-*) under E17B=1, and for E17c's ship-300-nd under E17C=1.
e17b_lease_arm() {
  [ "${E17B:-}" = 1 ] && case "$1" in
  ship-30 | ship-120 | ship-300) true ;;
  ship-300-nd) [ "${E17C:-}" = 1 ] ;;
  *) false ;;
  esac
}
# e17b_idle_timeout_s ARM: the lease idle timeout of a ship arm (the token's idle_timeout_s claim); ship-300-nd's is 300.
e17b_idle_timeout_s() {
  e17b_lease_arm "$1" || die "e17b_idle_timeout_s: $1 is not a ship arm (E17B=1)"
  local s=${1#ship-}
  echo "${s%-nd}"
}
# E17b snapshot leaf (ruling E17B-R17): under E17B=1 every arm's worker runs on snapshot-e17b.sh's leaf
# e17b-<first 8 of E15_MOCA_PIN>-<E17B_GUEST_RAM_MB> (1024 by default; 256 for the 256 MiB stages) with that guest RAM,
# never on the sealed e15 leaf; under E17C=1 the leaf is e17c-<first 8 of E15_MOCA_PIN (= E17C_MOCA_PIN)>-<ram>.
# With E17B unset: $E15_SNAPIMG and 1024 MiB, as before.
e17b_guest_ram_mb() {
  case "${E17B_GUEST_RAM_MB:-1024}" in
  1024 | 256) echo "${E17B_GUEST_RAM_MB:-1024}" ;;
  *) die "E17B_GUEST_RAM_MB=${E17B_GUEST_RAM_MB} is not 1024 or 256 (the guest RAMs snapshot-e17b.sh builds)" ;;
  esac
}
worker_snapimg() {
  if [ "${E17B:-}" = 1 ]; then
    local ram
    ram=$(e17b_guest_ram_mb) || exit 1
    # E17c (E17C=1, ruling R-i): its own leaves e17c-<E17C pin8>-<ram> (snapshot-e17b.sh under E17C=1)
    if [ "${E17C:-}" = 1 ]; then echo "e17c-${E15_MOCA_PIN:0:8}-$ram"; else echo "e17b-${E15_MOCA_PIN:0:8}-$ram"; fi
  else
    echo "$E15_SNAPIMG"
  fi
}
worker_guest_ram_mb() { if [ "${E17B:-}" = 1 ]; then e17b_guest_ram_mb; else echo 1024; fi; }
# e17b_require_snapshot: under E17B=1, the selected leaf must hold a manifest.json (rung.sh before any host change,
# start_worker before the worker starts); a no-op with E17B unset.
e17b_require_snapshot() {
  [ "${E17B:-}" = 1 ] || return 0
  local leaf ram
  leaf=$(worker_snapimg) || exit 1
  ram=$(e17b_guest_ram_mb) || exit 1
  [ -f "$E15_SNAPDIR/$leaf/manifest.json" ] ||
    die "no E17b snapshot $E15_SNAPDIR/$leaf (manifest.json): build it with $([ "${E17C:-}" = 1 ] && echo E17C=1 || echo E17B=1) experiments/e17-lease/rig/snapshot-e17b.sh --ram-mb $ram --leaf $leaf"
}
# e17b_token_iss: the token issuer the relay's SH_SANDBOX_TOKEN_ISSUER and the driver's --token-iss share.
e17b_token_iss() { echo e17b-driver; }
# e17b_token_dir_ok DIR: DIR is one token-<run> leaf directly under $E15_SECRETS ([A-Za-z0-9._-], no ..), lexically.
e17b_token_dir_ok() {
  local leaf=${1#"$E15_SECRETS"/}
  [ "$leaf" != "$1" ] || return 1
  case "$leaf" in token-?*) ;; *) return 1 ;; esac
  case "$leaf" in */* | *..*) return 1 ;; esac
  [[ "$leaf" =~ ^token-[A-Za-z0-9._-]+$ ]]
}
# e17b_token_dir_remove DIR: remove a rung's key directory (mint-key's token.key and token.pub, then the empty dir).
# Only a checked token-<run> leaf of $E15_SECRETS that is a real directory (not a symlink), inside $E15_ROOT; never
# rm -rf: an unexpected file keeps the dir (logged). Returns 1 on a refusal or a leftover.
e17b_token_dir_remove() {
  local d=$1
  e17b_token_dir_ok "$d" || {
    log "refusing to remove $d: not a token-<run> leaf of $E15_SECRETS"
    return 1
  }
  [ -e "$d" ] || [ -L "$d" ] || return 0
  if [ -L "$d" ] || [ ! -d "$d" ]; then
    log "refusing to remove $d: not a directory (or a symlink)"
    return 1
  fi
  refuse_outside_root "$d"
  rm -f -- "$d/token.key" "$d/token.pub"
  rmdir -- "$d" 2>/dev/null || {
    log "WARNING: $d holds more than token.key/token.pub; the keys are removed, the directory is left"
    return 1
  }
}

worker_bin() {
  ! e15_e17a_arm_refused "$1" || exit 1
  case "$1" in
  sbx | ship-30 | ship-120 | ship-300)
    # ship-* exist only in the E17b profile
    if [ "${E17B:-}" = 1 ]; then
      stock_worker_bin
    elif [ "$1" = sbx ]; then
      echo "$E15_BIN/microvm-worker"
    else
      die "worker_bin: no worker for arm $1"
    fi
    ;;
  ship-300-nd)
    # E17c only (E17C=1): the same stock worker as ship-300
    [ "${E17C:-}" = 1 ] || die "worker_bin: no worker for arm $1"
    stock_worker_bin
    ;;
  resident-inf | resident-300) echo "$E15_BIN/microvm-worker-resident" ;;
  lease-30 | lease-120) echo "$E15_BIN/microvm-worker-resident" ;; # E17
  *) die "worker_bin: no worker for arm $1" ;;
  esac
}

# start_worker ARM DIR [IMAGE_MB]: the arm's worker as transient e15-worker.service in e15-vms.slice, its
# stdout+stderr to DIR/worker.log, its settings in DIR/worker.env. Waits until it has attached.
start_worker() {
  local arm=$1 dir=$2 image_mb=${3:-256} bin
  bin=$(worker_bin "$arm")
  [ -x "$bin" ] || die "no worker binary $bin (run setup.sh)"
  e17b_require_snapshot
  unit_active "$E15_UNIT_WORKER" && die "$E15_UNIT_WORKER is already running"
  refuse_ports "$E15_PORT_STATS"
  worker_env "$arm" "$dir/worker.env" "$image_mb"
  : >"$dir/worker.log"
  sctl start "$E15_VM_SLICE"
  sudo -n systemd-run --quiet --unit="$E15_UNIT_WORKER" --slice="$E15_VM_SLICE" \
    -p Type=simple -p KillMode=control-group -p KillSignal=SIGTERM -p TimeoutStopSec=180 \
    -p LimitMEMLOCK=infinity -p LimitNOFILE=1048576 \
    -p MemoryAccounting=yes -p CPUAccounting=yes -p TasksAccounting=yes \
    -p AssertPathExists=/dev/kvm \
    -p EnvironmentFile="$E15_SECRETS/worker.env" -p EnvironmentFile="$dir/worker.env" \
    -p StandardOutput="file:$dir/worker.log" \
    "$bin" >/dev/null || die "systemd-run $E15_UNIT_WORKER failed"
  if ! wait_for 180 grep -q 'microvm-worker: attached, serving execs' "$dir/worker.log"; then
    tail -20 "$dir/worker.log" >&2
    die "worker ($arm) did not attach within 180 s; see $dir/worker.log"
  fi
}

start_null() {
  local dir=$1
  unit_active "$E15_UNIT_NULL" && die "$E15_UNIT_NULL is already running"
  refuse_ports "$E15_PORT_NULL"
  sudo -n systemd-run --quiet --unit="$E15_UNIT_NULL" --slice="$E15_SLICE" \
    -p User="$(id -un)" -p StandardOutput="file:$dir/null.log" \
    "$(null_bin)" --listen "127.0.0.1:$E15_PORT_NULL" >/dev/null ||
    die "systemd-run $E15_UNIT_NULL failed"
  wait_for 30 port_listening "$E15_PORT_NULL" || die "null-responder did not listen on $E15_PORT_NULL"
}

# The relay binds its attach port on 0.0.0.0 (startRelay); this preload rewrites that one bind to
# loopback before the server starts (rig rule: E15 binds 127.0.0.1 only). The unit also carries
# IPAddressAllow=localhost as a second fence. Resolved from the relay package's own node_modules,
# so it patches the same @grpc/grpc-js instance main.ts imports.
E15_RELAY_PRELOAD="data:text/javascript,import{createRequire}from'node:module';const g=createRequire(process.cwd()+'/package.json')('@grpc/grpc-js');const b=g.Server.prototype.bindAsync;g.Server.prototype.bindAsync=function(a,...r){return b.call(this,String(a).replace('0.0.0.0:','127.0.0.1:'),...r)};"

# start_relay [EXTRA_ENV_FILE]: E15's relay. E17b lease arms pass the per-rung file holding the token keyset and issuer;
# with no argument the command line is the sealed one.
start_relay() {
  local extra=()
  [ -z "${1:-}" ] || extra=(-p EnvironmentFile="$1")
  refuse_ports "$E15_PORT_ATTACH" "$E15_PORT_EXEC"
  mkdir -p "$E15_LOGS"
  # systemd creates the file as root; rotate it so this start's lines are the only ones checked.
  [ -f "$E15_LOGS/relay.log" ] && sudo -n mv -f "$E15_LOGS/relay.log" "$E15_LOGS/relay.log.1"
  # fresh-metal: node is bootstrap.sh's, not the system's; aws-prelim's unit is as before.
  local envp=()
  [ "$E15_HOST_PROFILE" != fresh-metal ] || envp=(-p Environment="PATH=$(e15_path)")
  sudo -n systemd-run --quiet --unit="$E15_UNIT_RELAY" --slice="$E15_SLICE" \
    -p User="$(id -un)" -p WorkingDirectory="$E15_MOCA/packages/sandbox-relay" \
    -p EnvironmentFile="$E15_SECRETS/relay.env" "${extra[@]}" \
    -p IPAddressDeny=any -p IPAddressAllow=localhost \
    -p MemoryAccounting=yes -p CPUAccounting=yes \
    -p StandardOutput="append:$E15_LOGS/relay.log" "${envp[@]}" \
    "$(e15_node)" --import tsx --import "$E15_RELAY_PRELOAD" src/main.ts >/dev/null ||
    die "systemd-run $E15_UNIT_RELAY failed"
  if ! wait_for 60 port_listening "$E15_PORT_ATTACH" || ! wait_for 30 port_listening "$E15_PORT_EXEC"; then
    stop_e15_unit "$E15_UNIT_RELAY"
    die "relay ports $E15_PORT_ATTACH/$E15_PORT_EXEC not on 127.0.0.1 (relay stopped); see $E15_LOGS/relay.log"
  fi
  if ss -ltnH | awk '{print $4}' | grep -Eq "^(0\.0\.0\.0|\*|\[::\]):($E15_PORT_ATTACH|$E15_PORT_EXEC)\$"; then
    stop_e15_unit "$E15_UNIT_RELAY"
    die "relay listens on a wildcard address; relay stopped (rig rule)"
  fi
}

# gexec KEY CMD: one Exec through the relay with grpcurl; prints the command's output, exits with
# its exit code (99 on a transport error). The token reaches grpcurl through its environment.
gexec() {
  local key=$1 cmd=$2 out
  # shellcheck disable=SC2016  # grpcurl -expand-headers expands ${E15_TOK} from its environment
  out=$(E15_TOK=$(cat "$E15_SECRETS/exec.token") grpcurl -plaintext -expand-headers \
    -H 'authorization: Bearer ${E15_TOK}' \
    -import-path "$E15_MOCA/proto" -proto sandbox/v1/sandbox.proto \
    -d "$(python3 -c 'import json,sys; print(json.dumps({"sandbox_id":"e15","exec":{"req_id":int(sys.argv[3]),"command":sys.argv[2],"timeout_s":120,"streaming":True,"workspace_key":sys.argv[1]}}))' "$key" "$cmd" "$RANDOM$RANDOM")" \
    "127.0.0.1:$E15_PORT_EXEC" sandbox.v1.SandboxExec/Exec 2>&1)
  printf '%s' "$out" | python3 -c '
import base64, json, sys
txt = sys.stdin.read()
dec = json.JSONDecoder(); i = 0; code = 99; buf = b""
while True:
    j = txt.find("{", i)
    if j < 0: break
    try:
        o, i = dec.raw_decode(txt, j)
    except ValueError:
        i = j + 1; continue
    if "chunk" in o: buf += base64.b64decode(o["chunk"].get("data", ""))
    if "end" in o: code = int(o["end"].get("exitCode", 0))
    if "error" in o: sys.stderr.write("ExecError: %s\n" % o["error"].get("message")); code = 98
if code == 99: sys.stderr.write(txt[:2000] + "\n")
sys.stdout.write(buf.decode("utf-8", "replace")); sys.exit(code)'
}
