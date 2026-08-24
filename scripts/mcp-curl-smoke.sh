#!/usr/bin/env bash
# Smoke-test ORDS MCP with a bearer access token (from Auth0 login / debugger).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -f "${ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT}/.env"
  set +a
fi

ORDS_URL="${ORDS_MCP_URL:-http://127.0.0.1:8080/mcp}"
TOKEN="${1:-${MCP_ACCESS_TOKEN:-}}"

if [[ -z "${TOKEN}" ]]; then
  echo "Usage: $0 <access_token>" >&2
  echo "Or: MCP_ACCESS_TOKEN=... $0" >&2
  echo "Get a token via OpenCode mcp auth, or Auth0 test login / your app." >&2
  exit 1
fi

post_mcp() {
  local body="$1"
  curl -sS "${ORDS_URL}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d "${body}"
}

echo "=== GET ${ORDS_URL} (no token → expect 401) ==="
curl -sS -o /dev/null -w "http_code=%{http_code}\n" "${ORDS_URL}" || true

echo "=== MCP initialize ==="
post_mcp '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"lab-smoke","version":"0.1"}}}'
echo

echo "=== tools/list ==="
post_mcp '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
echo

echo "=== tools/call database_list ==="
post_mcp '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"database_list","arguments":{}}}'
echo
