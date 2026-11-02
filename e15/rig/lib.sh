#!/usr/bin/env bash
# e15/rig/lib.sh -- shared definitions and guards for the E15 rig scripts (SPEC §4, §6.6, §7).
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
# Sections: "## Setup <utc>", "## Teardown <utc>", "## Purge <utc>".

E15_ROOT=${E15_ROOT:-/srv/e15}
E15_MANIFEST=${E15_MANIFEST:-$HOME/e15-manifest.md}
E15_SHARED=/opt/serverless-harness

# moca v0.9.0 (SPEC §6.6).
E15_MOCA_PIN=c13d55649777e69ec7649d6fa8c08f4acb1f4e2e
E15_MOCA_URL=${E15_MOCA_URL:-https://github.com/rossoctl/moca.git}

# Ports (SPEC §4): relay attach, relay exec, null-responder (control arm), worker /stats, Redis.
E15_PORT_ATTACH=9643
E15_PORT_EXEC=9644
E15_PORT_NULL=9645
E15_PORT_STATS=9646
E15_PORT_REDIS=6400
E15_PORTS=("$E15_PORT_ATTACH" "$E15_PORT_EXEC" "$E15_PORT_NULL" "$E15_PORT_STATS" "$E15_PORT_REDIS")

# Units E15 creates. The worker's slice nests inside e15.slice (systemd expands the dash).
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

# Firecracker binaries already on the host (read only).
E15_JAILER=/usr/local/bin/jailer
E15_FIRECRACKER=/usr/local/bin/firecracker
E15_BASE_SNAPSHOT=/srv/snapshots/default

E15_ARMS=(sbx resident-inf resident-300 control)
E15_LADDER=(1 8 16 24 32 40 48 56 64 80 96 128)
E15_FLOOR_MB=1536

# Points (SPEC §10.3): corpus directory under $E15_ROOT/corpora and the arms each point runs.
# "smoke" is the bring-up point: a dense subset of the default corpus, every arm.
e15_point_arms() {
  case "$1" in
  default) echo "sbx resident-inf resident-300 control" ;;
  short) echo "sbx resident-inf" ;;
  long | no-infra | no-chains) echo "sbx resident-inf resident-300" ;;
  smoke) echo "sbx resident-inf resident-300 control" ;;
  *) return 1 ;;
  esac
}

e15_is_arm() {
  local a
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

refuse_units() {
  local a
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

# --- small helpers ---------------------------------------------------------------------------

# Go on the rig: the modules need go 1.26, the host has 1.25.1. Everything under $E15_ROOT/go.
# One VAR=value per line: mapfile -t GOENV < <(e15_goenv user); env "${GOENV[@]}" go ...
e15_goenv() {
  local who=${1:-user}
  printf '%s\n' GOTOOLCHAIN=go1.26.0 GOWORK=off "GOPATH=$E15_ROOT/go/$who" \
    "GOMODCACHE=$E15_ROOT/go/$who/mod" "GOCACHE=$E15_ROOT/go/$who/cache"
}

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

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

# --- E15's own units -------------------------------------------------------------------------

# kill_vm_cgroups: kill every process left in a VM cgroup under e15-vms.slice (never the worker's
# own service cgroup) and remove the empty pool directories the worker created. E15's own tree only.
kill_vm_cgroups() {
  [ -d "$E15_VMCG" ] || return 0
  sudo -n bash -c '
    for d in "$1"/*/; do
      d=${d%/}; n=${d##*/}
      case "$n" in *.service|*.scope|*.slice) continue ;; esac
      [ -f "$d/cgroup.kill" ] && [ -s "$d/cgroup.procs" ] && echo 1 >"$d/cgroup.kill"
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

# worker_env ARM OUT: write the worker's non-secret environment for ARM (SPEC §7.1-§7.2).
worker_env() {
  local arm=$1 out=$2 depth
  case "$arm" in
  sbx) depth=2 ;;
  resident-inf | resident-300) depth=0 ;;
  *) die "worker_env: no worker for arm $arm" ;;
  esac
  {
    echo "RELAY_ADDR=127.0.0.1:$E15_PORT_ATTACH"
    echo "RELAY_TLS=false"
    echo "SANDBOX_ID=e15"
    echo "SH_VMM=firecracker"
    echo "SH_JAILER_BIN=$E15_JAILER"
    echo "SH_FIRECRACKER_BIN=$E15_FIRECRACKER"
    echo "SH_SNAPSHOT_DIR=$E15_SNAPDIR"
    echo "SH_SNAPSHOT_IMAGE=$E15_SNAPIMG"
    echo "SH_WORKSPACE_ROOT=$E15_WORKSPACES"
    echo "SH_CHROOT_BASE=$E15_JAIL"
    echo "SH_PARENT_CGROUP=$E15_PARENT_CGROUP"
    echo "SH_GUEST_RAM_MB=1024"
    echo "SH_STANDBY_DEPTH=$depth"
    echo "WORKER_MAX_CONCURRENT=256"
    echo "SH_MAX_RUNS=512"
    echo "SH_MAX_COMMITTED_MB=1048576"
    echo "SH_HOST_MEM_FLOOR_MB=$E15_FLOOR_MB"
    echo "SH_WORKSPACE_IMAGE_MB=256"
    echo "SH_WORKSPACE_IDLE=24h"
    echo "SH_DIAG_STATS_ADDR=127.0.0.1:$E15_PORT_STATS"
    echo "SH_DIAG_PHASES=1"
    echo "TZ=UTC"
    case "$arm" in
    resident-inf) printf 'E15_RESIDENT=1\nE15_RESIDENT_IDLE_S=0\n' ;;
    resident-300) printf 'E15_RESIDENT=1\nE15_RESIDENT_IDLE_S=300\n' ;;
    esac
  } >"$out"
}

worker_bin() {
  case "$1" in
  sbx) echo "$E15_BIN/microvm-worker" ;;
  resident-inf | resident-300) echo "$E15_BIN/microvm-worker-resident" ;;
  *) die "worker_bin: no worker for arm $1" ;;
  esac
}

# start_worker ARM DIR: the arm's worker as transient e15-worker.service in e15-vms.slice, its
# stdout+stderr to DIR/worker.log, its settings in DIR/worker.env. Waits until it has attached.
start_worker() {
  local arm=$1 dir=$2 bin
  bin=$(worker_bin "$arm")
  [ -x "$bin" ] || die "no worker binary $bin (run setup.sh)"
  unit_active "$E15_UNIT_WORKER" && die "$E15_UNIT_WORKER is already running"
  refuse_ports "$E15_PORT_STATS"
  worker_env "$arm" "$dir/worker.env"
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
    "$E15_BIN/null-responder" --listen "127.0.0.1:$E15_PORT_NULL" >/dev/null ||
    die "systemd-run $E15_UNIT_NULL failed"
  wait_for 30 port_listening "$E15_PORT_NULL" || die "null-responder did not listen on $E15_PORT_NULL"
}

# The relay binds its attach port on 0.0.0.0 (startRelay); this preload rewrites that one bind to
# loopback before the server starts (rig rule: E15 binds 127.0.0.1 only). The unit also carries
# IPAddressAllow=localhost as a second fence. Resolved from the relay package's own node_modules,
# so it patches the same @grpc/grpc-js instance main.ts imports.
E15_RELAY_PRELOAD="data:text/javascript,import{createRequire}from'node:module';const g=createRequire(process.cwd()+'/package.json')('@grpc/grpc-js');const b=g.Server.prototype.bindAsync;g.Server.prototype.bindAsync=function(a,...r){return b.call(this,String(a).replace('0.0.0.0:','127.0.0.1:'),...r)};"

start_relay() {
  refuse_ports "$E15_PORT_ATTACH" "$E15_PORT_EXEC"
  mkdir -p "$E15_LOGS"
  sudo -n systemd-run --quiet --unit="$E15_UNIT_RELAY" --slice="$E15_SLICE" \
    -p User="$(id -un)" -p WorkingDirectory="$E15_MOCA/packages/sandbox-relay" \
    -p EnvironmentFile="$E15_SECRETS/relay.env" \
    -p IPAddressDeny=any -p IPAddressAllow=localhost \
    -p MemoryAccounting=yes -p CPUAccounting=yes \
    -p StandardOutput="append:$E15_LOGS/relay.log" \
    /usr/bin/node --import tsx --import "$E15_RELAY_PRELOAD" src/main.ts >/dev/null ||
    die "systemd-run $E15_UNIT_RELAY failed"
  wait_for 60 port_listening "$E15_PORT_ATTACH" || die "relay attach port $E15_PORT_ATTACH not on 127.0.0.1; see $E15_LOGS/relay.log"
  wait_for 30 port_listening "$E15_PORT_EXEC" || die "relay exec port $E15_PORT_EXEC not on 127.0.0.1"
  if ss -ltnH | awk '{print $4}' | grep -Eq "^(0\.0\.0\.0|\*|\[::\]):($E15_PORT_ATTACH|$E15_PORT_EXEC)\$"; then
    die "relay listens on a wildcard address; refusing (rig rule)"
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
