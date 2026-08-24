#!/usr/bin/env bash
# Used only by root Dockerfile lab image path via compose command override if needed.
set -euo pipefail
if [[ "${1:-serve}" == "serve" ]] && [[ "${ORDS_LAB_BOOTSTRAP:-true}" == "true" ]]; then
  /opt/oracle/scripts/lab-bootstrap-pools.sh
  export ORDS_AUTO_INIT="${ORDS_AUTO_INIT:-true}"
fi
exec /opt/oracle/scripts/entrypoint.sh "$@"
