#!/usr/bin/env bash
# Configure ORDS for MCP + Auth0 JWT and two role-gated pools (mcp-hr, mcp-fin).
set -euo pipefail

ORDS_BIN="${ORDS_BIN:-ords}"
ORDS_CONFIG="${ORDS_CONFIG:-/etc/ords/config}"
export ORDS_CONFIG

ords_cfg() {
  "${ORDS_BIN}" --config "${ORDS_CONFIG}" config "$@"
}

echo "[configure-mcp] Enabling MCP and HTTP standalone settings..."
ords_cfg set --global feature.mcp true
ords_cfg set --global standalone.http.port "${ORDS_HTTP_PORT:-8080}"
ords_cfg set --global standalone.http.host 0.0.0.0 || true
if [[ "${ORDS_ENABLE_HTTPS:-false}" == "true" ]]; then
  ords_cfg set --global standalone.https.port "${ORDS_HTTPS_PORT:-8443}" || true
else
  ords_cfg delete --global standalone.https.port 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Auth0 JWT profile
# ---------------------------------------------------------------------------
: "${AUTH0_DOMAIN:?Set AUTH0_DOMAIN in .env (e.g. dev-xxxx.eu.auth0.com) — see docs/AUTH0_SETUP.md}"

AUDIENCE="${JWT_AUDIENCE:-${AUTH0_AUDIENCE:-https://ords.lab/mcp}}"
ISSUER="${JWT_ISSUER:-${AUTH0_ISSUER:-https://${AUTH0_DOMAIN}/}}"
JWKS_URL="${JWT_JWKS_URL:-${AUTH0_JWKS_URL:-https://${AUTH0_DOMAIN}/.well-known/jwks.json}}"
AUTH_SERVER_URL="${JWT_AUTH_SERVER_URL:-${AUTH0_AUTHORIZE_URL:-https://${AUTH0_DOMAIN}}}"
# Auth0 reserves "roles"; Jeff Smith / ORDS lab use claim "roles2"
MCP_ROLE_CLAIM="${MCP_ROLE_CLAIM:-/roles2}"

case "${ISSUER}" in
  */) ;;
  *) ISSUER="${ISSUER}/" ;;
esac

echo "[configure-mcp] Auth0 issuer=${ISSUER} audience=${AUDIENCE}"
echo "[configure-mcp] JWKS=${JWKS_URL}"
ords_cfg set --global mcp.security.jwt.profile.issuer "${ISSUER}"
ords_cfg set --global mcp.security.jwt.profile.audience "${AUDIENCE}"
ords_cfg set --global mcp.security.jwt.profile.jwk.url "${JWKS_URL}"
ords_cfg set --global mcp.security.jwt.profile.authorization.server.url "${AUTH_SERVER_URL}"
ords_cfg set --global mcp.security.jwt.profile.role.claim.name "${MCP_ROLE_CLAIM}"

# ---------------------------------------------------------------------------
# MCP pools
# ---------------------------------------------------------------------------
DB_HOST="${DB_HOST:-oracle}"
DB_PORT="${DB_PORT:-1521}"
DB_SERVICE="${DB_SERVICE:-FREEPDB1}"

HR_POOL="${MCP_HR_POOL_NAME:-mcp-hr}"
FIN_POOL="${MCP_FIN_POOL_NAME:-mcp-fin}"
HR_ROLE="${MCP_HR_ROLE:-POOL.HR}"
FIN_ROLE="${MCP_FIN_ROLE:-POOL.FIN}"
HR_USER="${MCP_HR_DB_USER:-HR_MCP_RO}"
FIN_USER="${MCP_FIN_DB_USER:-FIN_MCP_RO}"
HR_PASS="${MCP_HR_DB_PASSWORD:-HrMcp_ChangeMe1}"
FIN_PASS="${MCP_FIN_DB_PASSWORD:-FinMcp_ChangeMe1}"

configure_pool() {
  local pool="$1" user="$2" pass="$3" role="$4" description="$5"
  echo "[configure-mcp] Pool ${pool} user=${user} role=${role}"
  ords_cfg --db-pool "${pool}" set db.connectionType basic
  ords_cfg --db-pool "${pool}" set db.hostname "${DB_HOST}"
  ords_cfg --db-pool "${pool}" set db.port "${DB_PORT}"
  ords_cfg --db-pool "${pool}" set db.servicename "${DB_SERVICE}"
  ords_cfg --db-pool "${pool}" set db.username "${user}"
  ords_cfg --db-pool "${pool}" set db.description "${description}"
  ords_cfg --db-pool "${pool}" set mcp.role "${role}"
  ords_cfg --db-pool "${pool}" set mcp.scope "urn:oracle:dbtools:ords:mcpserver:all"
  printf '%s\n' "${pass}" | ords_cfg --db-pool "${pool}" secret --password-stdin db.password
}

configure_pool "${HR_POOL}" "${HR_USER}" "${HR_PASS}" "${HR_ROLE}" \
  "Lab HR database (read-only MCP user)"
configure_pool "${FIN_POOL}" "${FIN_USER}" "${FIN_PASS}" "${FIN_ROLE}" \
  "Lab FIN database (read-only MCP user)"

echo "[configure-mcp] Done."
ords_cfg list 2>/dev/null | grep -iE 'mcp|jwt|standalone|db\.(host|port|service|user|desc)|feature' || true
