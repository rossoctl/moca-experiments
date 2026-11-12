#!/usr/bin/env bash
# E18 wrapper. Brings the moca compose trial up in a throwaway project, runs the driver or the baseline, tears down.
#
#   ./run.sh stub [--runs 10]     crash runs against the canned-response model stub
#   ./run.sh real                 real-model baseline (needs ANTHROPIC_API_KEY, no stub)
#
# Environment:
#   E18_COMPOSE_DIR   moca's deploy/compose (default ~/gh/moca/deploy/compose)
#   SH_PORT           host port for the supervisor (default 18080)
#   SH_WORKERS        worker pool size (default: the container's CPU count)
#   E18_KEY_FILE      file holding the real ANTHROPIC_API_KEY (real mode)
set -euo pipefail

MODE="${1:-}"
[[ "$MODE" == stub || "$MODE" == real ]] || { echo "usage: $0 stub|real [driver/baseline args]" >&2; exit 2; }
shift

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="${E18_COMPOSE_DIR:-$HOME/gh/moca/deploy/compose}"
SH_PORT="${SH_PORT:-18080}"
PROJ="$(mktemp -d)"
export E18_DIR="$HERE"
export E18_STUB_PORT="${E18_STUB_PORT:-18099}"

export E18_PROJECT_DIR="$PROJ"
teardown() {
  # shellcheck disable=SC2086
  docker compose -p e18 --project-directory "$PROJ" --env-file "$PROJ/.env" $E18_FILE_ARGS down -v >/dev/null 2>&1 || true
  rm -rf "$PROJ"
}
E18_FILE_ARGS=""
trap teardown EXIT

{
  echo "SH_RELAY_TOKEN=$(head -c 32 /dev/urandom | base64 | tr -d '/+=')"
  echo "MOCA_RELAY_EXEC_TOKEN=$(head -c 32 /dev/urandom | base64 | tr -d '/+=')"
  echo "SH_TURNS_PER_WORKER=4"
  echo "SH_PORT=$SH_PORT"
  [[ -n "${SH_WORKERS:-}" ]] && echo "SH_WORKERS=$SH_WORKERS"
  if [[ "$MODE" == real ]]; then
    # E18_KEY_FILE keeps the key out of the environment and the command line.
    if [[ -n "${E18_KEY_FILE:-}" ]]; then ANTHROPIC_API_KEY="$(tr -d '[:space:]' <"$E18_KEY_FILE")"; fi
    : "${ANTHROPIC_API_KEY:?real mode needs ANTHROPIC_API_KEY or E18_KEY_FILE}"
    echo "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY"
    [[ -n "${ANTHROPIC_BASE_URL:-}" ]] && echo "ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL"
  fi
} >"$PROJ/.env"
chmod 600 "$PROJ/.env"

FILES="$COMPOSE_DIR/docker-compose.yml"
[[ "$MODE" == stub ]] && FILES="$FILES $HERE/compose.override.yml"
export E18_COMPOSE_FILES="$FILES"
ARGS=()
for f in $FILES; do ARGS+=(-f "$f"); E18_FILE_ARGS="$E18_FILE_ARGS -f $f"; done

docker compose -p e18 --project-directory "$PROJ" --env-file "$PROJ/.env" "${ARGS[@]}" up -d
# The admin listener is unpublished; poll it from inside the supervisor container.
READY=0
for _ in $(seq 1 90); do
  docker compose -p e18 --project-directory "$PROJ" --env-file "$PROJ/.env" "${ARGS[@]}" exec -T supervisor \
    node -e "fetch('http://127.0.0.1:8081/readyz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" >/dev/null 2>&1 && { READY=1; break; }
  sleep 1
done
[[ "$READY" == 1 ]] || { echo "supervisor never became ready" >&2; exit 1; }

cd "$HERE"
if [[ "$MODE" == stub ]]; then
  node driver.mjs --url "http://127.0.0.1:$SH_PORT" "$@"
else
  node baseline.mjs --url "http://127.0.0.1:$SH_PORT" "$@"
fi
