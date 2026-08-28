# OpenCode + Auth0 + ORDS MCP

How to connect [OpenCode](https://opencode.ai) to this lab’s ORDS MCP server with Auth0 OAuth.

**Prerequisites:** [AUTH0_SETUP.md](./AUTH0_SETUP.md) complete; `docker compose up -d` healthy.

---

## One-time project config

```bash
cd /path/to/ords
cp opencode.json.example opencode.json   # if needed
```

`opencode.json` (lab default):

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "ords-mcp": {
      "type": "remote",
      "url": "http://127.0.0.1:8080/mcp",
      "enabled": true,
      "timeout": 120000,
      "oauth": {
        "clientId": "{env:AUTH0_CLIENT_ID}",
        "scope": "urn:oracle:dbtools:ords:mcpserver:all offline_access"
      }
    }
  }
}
```

| Field | Why |
|-------|-----|
| `url` | Public MCP URL; must match Auth0 API Identifier and ORDS audience (`resource=`). Behind a proxy: [REVERSE_PROXY.md](./REVERSE_PROXY.md) |
| `clientId` | Native app Client ID from `.env` |
| **No** `clientSecret` | Native + PKCE (`token_endpoint_auth_method=none`) |
| `scope` | MCP permission + refresh; avoid extra scopes unless needed |
| `timeout` | SQL tools can be slow on first call |

OpenCode loads `{env:AUTH0_CLIENT_ID}` from the environment — always:

```bash
set -a && source .env && set +a
```

---

## Login (happy path)

```bash
cd /path/to/ords

# Callback port must be free (only one auth at a time)
ss -ltnp | grep 19876 || echo "callback port free"

set -a && source .env && set +a
echo "Client ID: $AUTH0_CLIENT_ID"

opencode mcp logout ords-mcp 2>/dev/null
opencode mcp auth ords-mcp
```

1. Browser opens Auth0 (or use the printed authorize URL).  
2. Sign in (Google or DB user that has the right **Roles**).  
3. Approve access.  
4. Browser page: **Authorization successful / OpenCode is now connected**.  
5. Leave the **CLI** running until it finishes.  
6. Verify:

```bash
opencode mcp list
```

**Success:**

```text
✓ ords-mcp connected (OAuth)
     http://127.0.0.1:8080/mcp
```

Then:

```bash
opencode
```

### Prompts to try

| User roles | Prompt | Expect |
|------------|--------|--------|
| `POOL.FIN` only | “Using ords-mcp, list databases I can access.” | `mcp-fin` only |
| `POOL.FIN` | “On mcp-fin run: select * from invoices” | rows |
| `POOL.FIN` | “On mcp-hr run: select 1 from dual” | denied / not listed |
| `POOL.HR` only | list databases | `mcp-hr` only |

---

## What “Authorization successful” vs CLI `needs_auth` means

| Message | Meaning |
|---------|---------|
| Browser: Authorization successful | Auth0 issued an auth **code**; OpenCode exchanged it for tokens |
| CLI: `Unexpected status: needs_auth` then Done | Often OpenCode still cannot **use** MCP (e.g. ORDS **403**) |
| `opencode mcp list` → **connected (OAuth)** | Tokens OK **and** MCP accepts them |

Tokens are stored in:

```text
~/.local/share/opencode/mcp-auth.json
```

### Inspect the access token

```bash
python3 - <<'PY'
import json
from pathlib import Path
from jose import jwt  # pip install python-jose if needed

path = Path.home() / ".local/share/opencode" / "mcp-auth.json"
data = json.loads(path.read_text())
at = data["ords-mcp"]["tokens"]["accessToken"]
c = jwt.get_unverified_claims(at)
print("sub        ", c.get("sub"))
print("aud        ", c.get("aud"))
print("roles2     ", c.get("roles2"))
print("permissions", c.get("permissions"))
print("scope      ", c.get("scope"))
PY
```

### Good token (working lab)

```text
aud         http://127.0.0.1:8080/mcp
roles2      ['POOL.FIN']
permissions ['urn:oracle:dbtools:ords:mcpserver:all']
scope       urn:oracle:dbtools:ords:mcpserver:all
```

### Bad tokens → symptoms

| Token | Symptom |
|-------|---------|
| No / wrong `aud` | 401; Auth0 Service not found during login if API missing |
| Missing `roles2` or claim named `roles` | ORDS: Missing Role Claim → 401 |
| `roles2` set but `permissions` empty | ORDS: **403**; CLI **needs_auth** after browser success |
| Stale token after Auth0 change | Same as before — **logout + auth** again |

---

## Switch user or refresh roles

```bash
opencode mcp logout ords-mcp
opencode mcp auth ords-mcp
```

Assigning a role in Auth0 does **not** update an existing JWT.

---

## OpenCode authorize URL (reference)

OpenCode builds a URL like:

```text
https://<AUTH0_DOMAIN>/authorize
  ?response_type=code
  &client_id=<NATIVE_CLIENT_ID>
  &code_challenge=…
  &code_challenge_method=S256
  &redirect_uri=http://127.0.0.1:19876/mcp/oauth/callback
  &scope=urn:oracle:dbtools:ords:mcpserver:all offline_access
  &resource=http://127.0.0.1:8080/mcp
```

| Parameter | Must match |
|-----------|------------|
| `client_id` | Native app |
| `redirect_uri` | Allowed Callback URLs |
| `resource` | API Identifier **exactly** |
| `scope` | API permission (+ offline_access if used) |

---

## Troubleshooting (OpenCode-specific)

| Error / symptom | Fix |
|-----------------|-----|
| Callback URL mismatch | Add `http://127.0.0.1:19876/mcp/oauth/callback` on Native app |
| Grant type `authorization_code` not allowed | App type **Native**; Advanced → Grant Types → Authorization Code |
| Changing M2M → Native disables Client Credentials | Expected; use separate M2M app for `test_auth0.py` if needed |
| **Service not found: http://127.0.0.1:8080/mcp** | Create API with that Identifier (not only `https://ords.lab/mcp`) |
| Empty **Authentication failed** | Kill leftover process on port **19876**; one auth at a time |
| Browser success + CLI `needs_auth` | Check token `permissions` + `roles2`; role must include MCP permission; re-auth |
| `opencode mcp list` still needs_auth | Token 403/401 from ORDS — fix claims, not OpenCode UI |
| No APIs tab on Native application | Normal — configure **APIs** and **Roles → Permissions** instead |

Safe way to free callback port:

```bash
ss -ltnp | grep 19876
# kill the PID shown for opencode if needed
kill <pid>
```

Do **not** use `pkill -f 'opencode mcp'` inside scripts that contain that same string (can kill the shell wrapper).

---

## Manual bearer fallback (dev only)

If OAuth is blocked, paste a valid access token (e.g. from a working session):

```json
"oauth": false,
"headers": {
  "Authorization": "Bearer {env:ORDS_MCP_TOKEN}"
}
```

```bash
export ORDS_MCP_TOKEN='…'
opencode
```

Prefer real OAuth for the lab.

---

## Related docs

- [AUTH0_SETUP.md](./AUTH0_SETUP.md) — Auth0 configuration  
- [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) — full error map  
- [ARCHITECTURE.md](./ARCHITECTURE.md) — security model  
- [OpenCode MCP docs](https://opencode.ai/docs/mcp-servers/)
