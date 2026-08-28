# Architecture

## Goal

Different users/groups reach **only the Oracle databases (pools) their Auth0 roles allow**, via **ORDS MCP** and an MCP client such as **OpenCode**.

## Runtime diagram

```text
                    Auth0 tenant
         ┌──────────────────────────────────┐
         │ Native app (PKCE / auth code)    │
         │ API Identifier =                 │
         │   http://127.0.0.1:8080/mcp      │
         │ Roles POOL.HR / POOL.FIN         │
         │  + permission on each role:      │
         │  urn:oracle:dbtools:ords:        │
         │    mcpserver:all                 │
         │ Trigger post-login → roles2      │
         └───────────────┬──────────────────┘
                         │ access token (JWT RS256)
                         ▼
 OpenCode ──HTTP──► ORDS standalone :8080/mcp
 (MCP client)              │
                           │ validate iss/aud/JWKS
                           │ require MCP scope/permission
                           │ filter pools by roles2 ↔ mcp.role
              ┌────────────┴────────────┐
              ▼                         ▼
        pool mcp-hr                pool mcp-fin
        mcp.role=POOL.HR           mcp.role=POOL.FIN
        mcp.scope=…mcpserver:all   mcp.scope=…mcpserver:all
        user HR_MCP_RO             user FIN_MCP_RO
              │                         │
              └────────────┬────────────┘
                           ▼
                 Oracle Free FREEPDB1
                 schemas HR + FIN (lab data)
```

## Components

| Component | Role |
|-----------|------|
| **Auth0** | Identity, OAuth login, roles, API permissions, JWT signing |
| **OpenCode** | MCP client; browser OAuth; stores tokens in `~/.local/share/opencode/mcp-auth.json` |
| **ORDS** | MCP server (`/mcp`); JWT validation; pool routing; SQL tools |
| **Oracle Free** | Data + least-privilege MCP DB users (no ORDS schema install required for MCP) |

## What lives where

| Concern | Store |
|---------|--------|
| Issuer, audience, JWKS URL, role claim pointer | ORDS config volume (`/etc/ords/config`) |
| Pool host/user/password, `mcp.role`, `mcp.scope` | ORDS config + wallet |
| Users, roles, API permissions | Auth0 |
| Role names on JWT (`roles2`) | Auth0 Action (post-login / credentials-exchange) |
| Sample tables | Oracle schemas `HR`, `FIN` |
| OpenCode tokens | Local OpenCode auth file (not in git) |

## Authorization model (two stages)

ORDS MCP authorizes in **two** stages (see Oracle MCP docs + this lab’s pool settings):

### 1. Global MCP access

Valid JWT:

- Signature via Auth0 JWKS  
- `iss` = `https://<AUTH0_DOMAIN>/` (trailing slash)  
- `aud` = API Identifier = MCP URL (`http://127.0.0.1:8080/mcp`)  
- Token carries MCP access, typically:

  - `permissions`: `["urn:oracle:dbtools:ords:mcpserver:all"]` and/or  
  - `scope` containing that string  

Lab pools also set `mcp.scope` to that value.

### 2. Per-pool access

ORDS config:

- `mcp.security.jwt.profile.role.claim.name` = `/roles2`  
- Pool `mcp-hr`: `mcp.role` = `POOL.HR`  
- Pool `mcp-fin`: `mcp.role` = `POOL.FIN`  

Token claim:

```json
"roles2": ["POOL.FIN"]
```

→ user only sees/uses **mcp-fin**.

## Working access token (example)

After a successful OpenCode login for a user with role `POOL.FIN` **and** that role’s MCP permission:

```json
{
  "iss": "https://dev-xxxxx.us.auth0.com/",
  "aud": "http://127.0.0.1:8080/mcp",
  "sub": "google-oauth2|…",
  "roles2": ["POOL.FIN"],
  "permissions": ["urn:oracle:dbtools:ords:mcpserver:all"],
  "scope": "urn:oracle:dbtools:ords:mcpserver:all"
}
```

| Missing piece | ORDS / OpenCode symptom |
|---------------|-------------------------|
| Bad/missing API Identifier vs MCP URL | Auth0: **Service not found: http://127.0.0.1:8080/mcp** |
| No `roles2` / wrong claim name `roles` | ORDS: **Missing Role Claim** → 401 |
| `roles2` OK but empty `permissions` | ORDS: **403 Forbidden**; OpenCode: **needs_auth** after “Authorization successful” |
| Role on user but not re-login | Old JWT kept; still empty claims |

## Why `roles2` (not `roles`)

Auth0 reserves claim name **`roles`** and will not put your custom role list there.  
This lab follows the same pattern as Jeff Smith’s ORDS MCP Auth0 notes: use **`roles2`**, and point ORDS at JSON pointer **`/roles2`**.

## Why API Identifier = MCP URL

OpenCode’s authorize request includes:

```text
resource=http://127.0.0.1:8080/mcp
```

Auth0 maps `resource` to an **API Identifier**. They must match **exactly** (scheme, host, port, path).  
A separate API such as `https://ords.lab/mcp` does **not** satisfy OpenCode’s `resource` unless you change the MCP URL everywhere (including HTTPS). This lab stays on plain **HTTP** localhost.

## OpenCode OAuth details

| Item | Value |
|------|--------|
| MCP URL | `http://127.0.0.1:8080/mcp` |
| App type | **Native** (Authorization Code + PKCE) |
| Callback | `http://127.0.0.1:19876/mcp/oauth/callback` |
| Scopes requested | `urn:oracle:dbtools:ords:mcpserver:all offline_access` |
| Client secret | Not required for public Native + PKCE |

Callback port **19876** must be free (only one `opencode mcp auth` at a time).

## Lab vs work

| Lab | Work |
|-----|------|
| One Oracle Free, two schemas as “databases” | One MCP pool per real DB/service |
| Auth0 free tenant | Entra / Okta / Auth0 Enterprise (same JWT shape) |
| HTTP `127.0.0.1:8080` | HTTPS public MCP URL = API Identifier = `aud` (dedicated host `/mcp`; see [REVERSE_PROXY.md](./REVERSE_PROXY.md)) |
| Docker Compose | Kubernetes + secrets |

See [WORK_REPRODUCTION.md](./WORK_REPRODUCTION.md).

## References

- [Jeff Smith — ORDS MCP](https://www.thatjeffsmith.com/archive/2026/07/ords-now-a-streaming-http-mcp-server-for-oracle-database/)
- [Oracle — Using ORDS MCP](https://docs.oracle.com/en/database/oracle/oracle-rest-data-services/26.2/orddg/using-ords-model-context-protocol-mcp.html)
- [OpenCode MCP](https://opencode.ai/docs/mcp-servers/)
