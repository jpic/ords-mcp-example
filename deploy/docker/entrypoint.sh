#!/usr/bin/env bash
# Production entrypoint: init | serve | check | ords passthrough
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

mkdir -p "${ORDS_CONFIG}"

cmd="${1:-serve}"
shift || true

case "${cmd}" in
  init|configure)
    exec /opt/oracle/scripts/init-config.sh
    ;;
  check)
    if [[ ! -f "${ORDS_CONFIG}/.ords-mcp-initialized" ]]; then
      echo "ERROR: config not initialized (${ORDS_CONFIG}/.ords-mcp-initialized missing)" >&2
      exit 1
    fi
    "${ORDS_BIN}" --config "${ORDS_CONFIG}" --version >/dev/null
    echo "OK: config present"
    exit 0
    ;;
  serve)
    # Auto-init only when explicitly requested (lab/dev convenience)
    if [[ ! -f "${ORDS_CONFIG}/.ords-mcp-initialized" ]]; then
      if [[ "${ORDS_AUTO_INIT:-false}" == "true" ]]; then
        echo "[entrypoint] ORDS_AUTO_INIT=true — running init-config"
        /opt/oracle/scripts/init-config.sh
      else
        echo "ERROR: ORDS config not initialized." >&2
        echo "Run with command 'init' (initContainer) or set ORDS_AUTO_INIT=true (dev only)." >&2
        exit 1
      fi
    elif [[ "${ORDS_RECONFIGURE:-false}" == "true" ]]; then
      echo "[entrypoint] ORDS_RECONFIGURE=true — re-running init-config"
      /opt/oracle/scripts/init-config.sh
    fi
    echo "[entrypoint] starting ords serve (config=${ORDS_CONFIG})"
    exec "${ORDS_BIN}" --config "${ORDS_CONFIG}" serve
    ;;
  version|--version)
    exec "${ORDS_BIN}" --version
    ;;
  bash|sh)
    exec /bin/bash "$@"
    ;;
  *)
    exec "${ORDS_BIN}" --config "${ORDS_CONFIG}" "${cmd}" "$@"
    ;;
esac
