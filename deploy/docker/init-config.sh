#!/usr/bin/env bash
# Fail-closed ORDS MCP configuration (JWT profile + pools).
# No default database passwords. No lab hostnames required.
set -euo pipefail

ORDS_BIN="${ORDS_BIN:-ords}"
ORDS_CONFIG="${ORDS_CONFIG:-/etc/ords/config}"
ORDS_POOLS_DIR="${ORDS_POOLS_DIR:-/etc/ords/pools.d}"
export ORDS_CONFIG

# ORDS 26.x config CLI often exits 1 even when the setting is applied successfully.
ords_cfg() {
  set +e
  "${ORDS_BIN}" --config "${ORDS_CONFIG}" config "$@"
  local ec=$?
  set -e
  if [[ $ec -eq 0 ]]; then
    return 0
  fi
  # Args may be: set ...  OR  --db-pool NAME set ...  OR  --db-pool NAME secret ...
  local a
  for a in "$@"; do
    case "$a" in
      set|secret|delete) return 0 ;;
    esac
  done
  return "$ec"
}

require() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "ERROR: required environment variable ${name} is not set" >&2
    exit 1
  fi
}

require ORDS_JWT_ISSUER
require ORDS_JWT_AUDIENCE
require ORDS_JWT_JWKS_URL

ORDS_JWT_AUTH_SERVER_URL="${ORDS_JWT_AUTH_SERVER_URL:-${ORDS_JWT_ISSUER}}"
ORDS_JWT_ROLE_CLAIM="${ORDS_JWT_ROLE_CLAIM:-/roles2}"
ORDS_MCP_SCOPE="${ORDS_MCP_SCOPE:-urn:oracle:dbtools:ords:mcpserver:all}"
ORDS_HTTP_PORT="${ORDS_HTTP_PORT:-8080}"
ORDS_HTTP_HOST="${ORDS_HTTP_HOST:-0.0.0.0}"

ISSUER="${ORDS_JWT_ISSUER}"
case "${ISSUER}" in
  */) ;;
  *) ISSUER="${ISSUER}/" ;;
esac

mkdir -p "${ORDS_CONFIG}"
if ! touch "${ORDS_CONFIG}/.write-test" 2>/dev/null; then
  echo "ERROR: ${ORDS_CONFIG} is not writable by $(id -u):$(id -g)." >&2
  echo "Mount an empty volume or set fsGroup=54321 (oracle)." >&2
  exit 1
fi
rm -f "${ORDS_CONFIG}/.write-test"

echo "[init-config] JWT issuer=${ISSUER}"
echo "[init-config] JWT audience=${ORDS_JWT_AUDIENCE}"
echo "[init-config] JWT jwks=${ORDS_JWT_JWKS_URL}"
echo "[init-config] role claim=${ORDS_JWT_ROLE_CLAIM}"

ords_cfg set --global feature.mcp true
ords_cfg set --global standalone.http.port "${ORDS_HTTP_PORT}"
ords_cfg set --global standalone.http.host "${ORDS_HTTP_HOST}" || true

if [[ "${ORDS_ENABLE_HTTPS:-false}" == "true" ]]; then
  require ORDS_HTTPS_PORT
  ords_cfg set --global standalone.https.port "${ORDS_HTTPS_PORT}"
else
  ords_cfg delete --global standalone.https.port 2>/dev/null || true
fi

ords_cfg set --global mcp.security.jwt.profile.issuer "${ISSUER}"
ords_cfg set --global mcp.security.jwt.profile.audience "${ORDS_JWT_AUDIENCE}"
ords_cfg set --global mcp.security.jwt.profile.jwk.url "${ORDS_JWT_JWKS_URL}"
ords_cfg set --global mcp.security.jwt.profile.authorization.server.url "${ORDS_JWT_AUTH_SERVER_URL}"
ords_cfg set --global mcp.security.jwt.profile.role.claim.name "${ORDS_JWT_ROLE_CLAIM}"

# ---------------------------------------------------------------------------
# Pools: /etc/ords/pools.d/*.env  (one file per pool)
# Required keys in each file:
#   NAME HOST PORT SERVICE USERNAME ROLE
# Password: PASSWORD or PASSWORD_FILE (path); no defaults.
# Optional: DESCRIPTION SCOPE
# ---------------------------------------------------------------------------
shopt -s nullglob
pool_files=("${ORDS_POOLS_DIR}"/*.env)
if [[ ${#pool_files[@]} -eq 0 ]]; then
  echo "ERROR: no pool definitions in ${ORDS_POOLS_DIR}/*.env" >&2
  echo "See deploy/pools/README.md" >&2
  exit 1
fi

load_pool_file() {
  local file="$1"
  # shellcheck disable=SC1090
  set -a
  # Clear pool vars before source
  unset NAME HOST PORT SERVICE USERNAME ROLE DESCRIPTION SCOPE PASSWORD PASSWORD_FILE || true
  # Only allow simple KEY=VALUE lines
  # shellcheck disable=SC1090
  source <(grep -E '^[A-Z_][A-Z0-9_]*=' "${file}" || true)
  set +a

  local missing=()
  [[ -n "${NAME:-}" ]] || missing+=(NAME)
  [[ -n "${HOST:-}" ]] || missing+=(HOST)
  [[ -n "${PORT:-}" ]] || missing+=(PORT)
  [[ -n "${SERVICE:-}" ]] || missing+=(SERVICE)
  [[ -n "${USERNAME:-}" ]] || missing+=(USERNAME)
  [[ -n "${ROLE:-}" ]] || missing+=(ROLE)

  local pass=""
  if [[ -n "${PASSWORD_FILE:-}" ]]; then
    if [[ ! -f "${PASSWORD_FILE}" ]]; then
      echo "ERROR: pool ${NAME:-?} PASSWORD_FILE not found: ${PASSWORD_FILE}" >&2
      exit 1
    fi
    pass="$(tr -d '\r\n' <"${PASSWORD_FILE}")"
  elif [[ -n "${PASSWORD:-}" ]]; then
    pass="${PASSWORD}"
  else
    missing+=(PASSWORD_or_PASSWORD_FILE)
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: pool file ${file} missing: ${missing[*]}" >&2
    exit 1
  fi
  if [[ -z "${pass}" ]]; then
    echo "ERROR: pool ${NAME} password is empty" >&2
    exit 1
  fi

  local scope="${SCOPE:-${ORDS_MCP_SCOPE}}"
  local desc="${DESCRIPTION:-MCP pool ${NAME}}"

  echo "[init-config] pool name=${NAME} host=${HOST}:${PORT}/${SERVICE} user=${USERNAME} role=${ROLE}"

  ords_cfg --db-pool "${NAME}" set db.connectionType basic
  ords_cfg --db-pool "${NAME}" set db.hostname "${HOST}"
  ords_cfg --db-pool "${NAME}" set db.port "${PORT}"
  ords_cfg --db-pool "${NAME}" set db.servicename "${SERVICE}"
  ords_cfg --db-pool "${NAME}" set db.username "${USERNAME}"
  ords_cfg --db-pool "${NAME}" set db.description "${desc}"
  ords_cfg --db-pool "${NAME}" set mcp.role "${ROLE}"
  ords_cfg --db-pool "${NAME}" set mcp.scope "${scope}"
  printf '%s\n' "${pass}" | ords_cfg --db-pool "${NAME}" secret --password-stdin db.password
}

for f in "${pool_files[@]}"; do
  echo "[init-config] loading ${f}"
  load_pool_file "${f}"
done

# Marker so serve can detect initialized config
{
  date -u +%Y-%m-%dT%H:%M:%SZ
  echo "pools=${#pool_files[@]}"
} >"${ORDS_CONFIG}/.ords-mcp-initialized" || {
  echo "ERROR: failed to write ${ORDS_CONFIG}/.ords-mcp-initialized" >&2
  exit 1
}
echo "[init-config] done (${#pool_files[@]} pool(s))"
