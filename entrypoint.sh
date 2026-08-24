#!/usr/bin/env bash
set -euo pipefail

ORDS_HOME="${ORDS_HOME:-/opt/oracle/ords}"
ORDS_CONFIG="${ORDS_CONFIG:-/etc/ords/config}"
export ORDS_CONFIG

if [[ -x "${ORDS_HOME}/bin/ords" ]]; then
  ORDS_BIN="${ORDS_HOME}/bin/ords"
else
  echo "ERROR: ords binary not found under ${ORDS_HOME}" >&2
  exit 1
fi
export ORDS_BIN

DB_HOST="${DB_HOST:-oracle}"
DB_PORT="${DB_PORT:-1521}"
WAIT_FOR_DB="${WAIT_FOR_DB:-true}"
DB_WAIT_TIMEOUT="${DB_WAIT_TIMEOUT:-300}"
ORDS_MODE="${ORDS_MODE:-mcp}"

mkdir -p "${ORDS_CONFIG}"

wait_for_port() {
  local host="$1" port="$2" timeout="$3" label="${4:-service}"
  local start now
  start=$(date +%s)
  echo "Waiting for ${label} at ${host}:${port} (timeout ${timeout}s)..."
  while true; do
    if nc -z "${host}" "${port}" 2>/dev/null; then
      echo "${label} port is open."
      return 0
    fi
    now=$(date +%s)
    if (( now - start >= timeout )); then
      echo "ERROR: timed out waiting for ${label} ${host}:${port}" >&2
      return 1
    fi
    sleep 2
  done
}

cmd="${1:-serve}"
shift || true

case "${cmd}" in
  serve)
    if [[ "${WAIT_FOR_DB}" == "true" ]]; then
      wait_for_port "${DB_HOST}" "${DB_PORT}" "${DB_WAIT_TIMEOUT}" "database"
      sleep "${DB_SETTLE_SECONDS:-25}"
    fi
    if [[ "${ORDS_MODE}" == "mcp" || "${ORDS_MODE}" == "both" ]]; then
      if [[ -z "${AUTH0_DOMAIN:-}" ]]; then
        echo "ERROR: AUTH0_DOMAIN is required. Copy .env.example → .env and follow docs/AUTH0_SETUP.md" >&2
        exit 1
      fi
      /opt/oracle/scripts/configure-mcp.sh
    fi
    echo "Starting ORDS (mode=${ORDS_MODE}) config=${ORDS_CONFIG}"
    exec "${ORDS_BIN}" --config "${ORDS_CONFIG}" serve
    ;;
  configure-mcp)
    /opt/oracle/scripts/configure-mcp.sh
    ;;
  bash|sh)
    exec /bin/bash "$@"
    ;;
  *)
    exec "${ORDS_BIN}" --config "${ORDS_CONFIG}" "${cmd}" "$@"
    ;;
esac
