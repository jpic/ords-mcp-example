#!/usr/bin/env bash
# Lab-only: materialize pools.d from compose env (still no silent empty passwords).
set -euo pipefail

POOLS_DIR="${ORDS_POOLS_DIR:-/etc/ords/pools.d}"
mkdir -p "${POOLS_DIR}"

write_pool() {
  local file="$1" name="$2" host="$3" port="$4" service="$5" user="$6" role="$7" pass="$8" desc="$9"
  if [[ -z "${pass}" ]]; then
    echo "ERROR: lab pool ${name} password env is empty" >&2
    exit 1
  fi
  local secrets="/tmp/ords-lab-secrets"
  mkdir -p "${secrets}"
  local pf="${secrets}/${name}.password"
  printf '%s' "${pass}" >"${pf}"
  chmod 0600 "${pf}"
  cat >"${POOLS_DIR}/${file}" <<EOF
NAME=${name}
DESCRIPTION=${desc}
HOST=${host}
PORT=${port}
SERVICE=${service}
USERNAME=${user}
ROLE=${role}
PASSWORD_FILE=${pf}
SCOPE=urn:oracle:dbtools:ords:mcpserver:all
EOF
}

DB_HOST="${DB_HOST:-oracle}"
DB_PORT="${DB_PORT:-1521}"
DB_SERVICE="${DB_SERVICE:-FREEPDB1}"

write_pool "mcp-hr.env" \
  "${MCP_HR_POOL_NAME:-mcp-hr}" \
  "${DB_HOST}" "${DB_PORT}" "${DB_SERVICE}" \
  "${MCP_HR_DB_USER:-HR_MCP_RO}" \
  "${MCP_HR_ROLE:-POOL.HR}" \
  "${MCP_HR_DB_PASSWORD:?Set MCP_HR_DB_PASSWORD}" \
  "Lab HR database (read-only MCP user)"

write_pool "mcp-fin.env" \
  "${MCP_FIN_POOL_NAME:-mcp-fin}" \
  "${DB_HOST}" "${DB_PORT}" "${DB_SERVICE}" \
  "${MCP_FIN_DB_USER:-FIN_MCP_RO}" \
  "${MCP_FIN_ROLE:-POOL.FIN}" \
  "${MCP_FIN_DB_PASSWORD:?Set MCP_FIN_DB_PASSWORD}" \
  "Lab FIN database (read-only MCP user)"

echo "[lab-bootstrap] wrote pools to ${POOLS_DIR}"
