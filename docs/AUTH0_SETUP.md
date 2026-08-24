# Auth0 setup guide (exhaustive)

Complete these steps **in order**. This matches a **working** lab with OpenCode + ORDS MCP over plain HTTP.

**You need:** Auth0 account (~20–30 minutes the first time).

---

## Values checklist

| Variable / setting | Exact lab value | Notes |
|--------------------|-----------------|--------|
| `AUTH0_DOMAIN` | e.g. `dev-xxxx.us.auth0.com` | No `https://` |
| API **Identifier** / `AUTH0_AUDIENCE` | `http://127.0.0.1:8080/mcp` | Must equal OpenCode MCP URL |
| API permission | `urn:oracle:dbtools:ords:mcpserver:all` | On API **and** on each **role** |
| Roles | `POOL.HR`, `POOL.FIN` | Exact strings = ORDS `mcp.role` |
| JWT role claim | `roles2` | **Not** `roles` (Auth0-reserved) |
| ORDS `MCP_ROLE_CLAIM` | `/roles2` | JSON pointer |
| App type | **Native** | OpenCode PKCE |
| `AUTH0_CLIENT_ID` | Native app Client ID | No client secret required for PKCE |
| Callback URL | `http://127.0.0.1:19876/mcp/oauth/callback` | Exact path |

---

## Step 1 — Dashboard and domain

1. Open [https://manage.auth0.com/](https://manage.auth0.com/)
2. Create or select a tenant.
3. Note **Domain** (top-left tenant menu), e.g. `dev-xxxx.us.auth0.com`  
   → **`AUTH0_DOMAIN`**

---

## Step 2 — API (resource server)

OpenCode sends `resource=http://127.0.0.1:8080/mcp`. Auth0 only accepts that if an API exists with that **Identifier**.

1. Left menu: **Applications → APIs** (top-level **APIs**, not inside an Application).
2. **+ Create API**

| Field | Value |
|-------|--------|
| **Name** | `ORDS MCP Local` |
| **Identifier** | `http://127.0.0.1:8080/mcp` |
| **Signing Algorithm** | RS256 |

**Copy carefully:**

- `http` (not `https`)
- `127.0.0.1` (not `localhost`)
- `:8080`
- `/mcp`
- **no** trailing slash

Auth0 **cannot rename** Identifier later. If you created `https://ords.lab/mcp` earlier, **create a new API** with the localhost Identifier. Leave the old one unused.

3. **Create**

### 2a. Permission

API → **Permissions** → **Add**:

| Permission | Description |
|------------|-------------|
| `urn:oracle:dbtools:ords:mcpserver:all` | ORDS MCP global access |

### 2b. API settings

API → **Settings**:

| Setting | Value |
|---------|--------|
| **Enable RBAC** | On |
| **Add Permissions in the Access Token** | On |
| **Allow Offline Access** | On (for OpenCode `offline_access`) |

**Save**.

### 2c. About “APIs” on the Application

**Native** apps often **do not** show an **APIs** or **Permissions** tab. That is normal.

- **Permissions** are defined on the **API**.
- **Role → Permissions** attach the MCP permission to roles (Step 3).
- User login uses Authorization Code + `resource=` / scopes from OpenCode; first-party Native apps in the same tenant can request this API without an M2M-style “authorize app” row.

**Machine to Machine Applications** on the API page lists **only M2M apps**, not Native. Ignore for OpenCode.

→ **`AUTH0_AUDIENCE`** = `http://127.0.0.1:8080/mcp`

---

## Step 3 — Roles + permission on each role

### 3a. Create roles

**User Management → Roles → Create Role**

| Name | Description |
|------|-------------|
| `POOL.HR` | ORDS pool `mcp-hr` |
| `POOL.FIN` | ORDS pool `mcp-fin` |

Names must match ORDS `mcp.role` **exactly**.

### 3b. Attach MCP permission to **each** role (critical)

For **`POOL.FIN`** and **`POOL.HR`**:

1. Open the role  
2. **Permissions** tab  
3. **Add Permissions**  
4. Select API **ORDS MCP Local** (`http://127.0.0.1:8080/mcp`)  
5. Check **`urn:oracle:dbtools:ords:mcpserver:all`**  
6. Add  

**Why:**  

| Token has | ORDS / OpenCode result |
|-----------|-------------------------|
| `roles2: ["POOL.FIN"]` only | **403 Forbidden**; OpenCode stays **needs_auth** after browser success |
| `roles2` **and** `permissions: ["urn:oracle:dbtools:ords:mcpserver:all"]` | **Works** — pools filtered by role |

---

## Step 4 — Native application (OpenCode)

1. **Applications → Applications → Create Application**
2. Name: e.g. `OpenCode Native`
3. Type: **Native**  
   - Do **not** use Machine to Machine for OpenCode (no auth code / browser login).  
   - Switching M2M → Native disables Client Credentials on that app (expected).
4. **Create**

### Settings

| Setting | Value |
|---------|--------|
| **Client ID** | → `AUTH0_CLIENT_ID` |
| **Client Secret** | Not needed for OpenCode PKCE (leave out of `.env`) |
| **Allowed Callback URLs** | see below |
| **Allowed Logout URLs** | `http://127.0.0.1:19876`, `http://localhost:19876` |
| **Allowed Web Origins** (if shown) | same hosts |

**Allowed Callback URLs** (exact):

```text
http://127.0.0.1:19876/mcp/oauth/callback,
http://localhost:19876/mcp/oauth/callback
```

Path must be `/mcp/oauth/callback` (not only `/callback`).

**Save Changes**.

### Grant types

**Settings → Advanced Settings → Grant Types**:

- **Authorization Code** = On  
- **Refresh Token** = On (recommended)  
- Client Credentials = Off for Native (OK)

**Save**.

---

## Step 5 — Trigger Action: put roles on the JWT as `roles2`

Auth0 **reserves** claim name **`roles`**. Custom role lists must use another name.  
This lab uses **`roles2`** ([Jeff Smith / ORDS MCP + Auth0](https://www.thatjeffsmith.com/archive/2026/07/ords-now-a-streaming-http-mcp-server-for-oracle-database/)).

UI label is **Actions → Triggers** (not “Flows”).

### 5a. post-login (users / OpenCode / Google login)

1. **Actions → Library → Build Custom**  
2. Trigger: **Login / Post Login**  
3. Name: `ORDS MCP roles2`  
4. Code:

```javascript
/**
 * Auth0 reserves "roles". ORDS reads claim "roles2" (MCP_ROLE_CLAIM=/roles2).
 * event.authorization.roles is populated when RBAC is on and roles are assigned to the user.
 */
exports.onExecutePostLogin = async (event, api) => {
  const roles = event.authorization?.roles || [];
  api.accessToken.setCustomClaim("roles2", roles);
};
```

5. **Deploy**  
6. **Actions → Triggers → `post-login`**  
7. Add this action into the pipeline → **Apply**

Library-only (not on the trigger) = **never runs**.

### 5b. credentials-exchange (optional M2M / `scripts/test_auth0.py`)

Only if you use a separate **Machine to Machine** app for automated tests:

**Triggers → `credentials-exchange`:**

```javascript
exports.onExecuteCredentialsExchange = async (event, api) => {
  api.accessToken.setCustomClaim("roles2", ["POOL.HR", "POOL.FIN"]);
};
```

Deploy + attach to **credentials-exchange**. Authorize that M2M app on the API with the MCP permission.

---

## Step 6 — Users

**User Management → Users**

| Approach | Notes |
|----------|--------|
| Database user | Create user, set password, assign role(s) |
| Google / social | After first login, open that user (`google-oauth2|…`) and assign **Roles** |

For each test identity:

| User intent | Assign role |
|-------------|-------------|
| FIN only | `POOL.FIN` only |
| HR only | `POOL.HR` only |
| Both pools | both roles |

**Roles tab on the user** assigns the role.  
**Permissions on the role** (Step 3b) supply `permissions` on the token.

---

## Step 7 — Lab `.env`

```bash
cd /path/to/ords
cp .env.example .env
```

```bash
AUTH0_DOMAIN=dev-xxxx.us.auth0.com
AUTH0_AUDIENCE=http://127.0.0.1:8080/mcp
AUTH0_CLIENT_ID=<Native Client ID>
# Do not set AUTH0_CLIENT_SECRET for Native PKCE OpenCode

MCP_ROLE_CLAIM=/roles2

ORACLE_PWD=OracleFree123
ORDS_MODE=mcp
ORDS_HTTP_PORT=8080
ORDS_ENABLE_HTTPS=false
```

---

## Step 8 — Start the stack

First boot runs `sql/01_lab_schemas.sql` into a **new** Oracle volume.

```bash
docker compose up -d --build
docker compose ps
```

If you changed Auth0 audience/issuer after ORDS already ran:

```bash
docker compose stop ords && docker compose rm -f ords
docker volume rm ords_ords-config
docker compose up -d ords
```

### Health checks

```bash
curl -sI http://127.0.0.1:8080/mcp
# 401 + resource_metadata=.../oauth-protected-resource/mcp

curl -s http://127.0.0.1:8080/.well-known/oauth-protected-resource/mcp
# "resource":"http://127.0.0.1:8080/mcp"
# "authorization_servers":["https://YOUR_DOMAIN"]

docker exec ords curl -fsSI "https://${AUTH0_DOMAIN}/.well-known/jwks.json" | head -5
# ORDS container must resolve Auth0 (compose sets dns 1.1.1.1 / 8.8.8.8)
```

ORDS JWT settings (via `scripts/configure-mcp.sh`):

| Setting | Value |
|---------|--------|
| `feature.mcp` | `true` |
| `mcp.security.jwt.profile.issuer` | `https://<domain>/` |
| `mcp.security.jwt.profile.audience` | `http://127.0.0.1:8080/mcp` |
| `mcp.security.jwt.profile.jwk.url` | `https://<domain>/.well-known/jwks.json` |
| `mcp.security.jwt.profile.role.claim.name` | `/roles2` |
| pool `mcp-hr` | `mcp.role=POOL.HR`, `mcp.scope=urn:oracle:dbtools:ords:mcpserver:all` |
| pool `mcp-fin` | `mcp.role=POOL.FIN`, same scope |

---

## Step 9 — OpenCode

See [OPENCODE.md](./OPENCODE.md). Short version:

```bash
cp opencode.json.example opencode.json
set -a && source .env && set +a

# only one auth process (port 19876)
ss -ltnp | grep 19876 || echo "callback port free"

opencode mcp logout ords-mcp 2>/dev/null
opencode mcp auth ords-mcp
# complete browser login; wait for CLI

opencode mcp list
# expect: ✓ ords-mcp connected (OAuth)
```

---

## Working token shape

Decode access token (jwt.io or script in OPENCODE.md):

```json
{
  "iss": "https://dev-xxxx.us.auth0.com/",
  "aud": "http://127.0.0.1:8080/mcp",
  "sub": "google-oauth2|…",
  "roles2": ["POOL.FIN"],
  "permissions": ["urn:oracle:dbtools:ords:mcpserver:all"],
  "scope": "urn:oracle:dbtools:ords:mcpserver:all"
}
```

| Claim | Required for |
|-------|----------------|
| `aud` | Match ORDS audience / API Identifier |
| `roles2` | Pool filter (`mcp.role`) |
| `permissions` and/or `scope` with MCP permission | Global MCP access (else **403**) |

**Always re-login after Auth0 role/permission/Action changes** — JWTs are immutable.

---

## Optional: automated test script

```bash
python3 scripts/test_auth0.py
```

- Uses **client_credentials** if a confidential/M2M client is configured (Native alone cannot).  
- Prefer verifying via OpenCode token file after `mcp auth` (see OPENCODE.md).  
- Password grant is **off** on Native apps by default (do not enable in production).

---

## Auth0 UI map (where things live)

| What you need | Where |
|---------------|--------|
| API Identifier, permissions, RBAC, offline access | **Applications → APIs → [API]** |
| Roles + **role permissions** | **User Management → Roles → [role] → Permissions** |
| Assign role to user | **Users → [user] → Roles** |
| Native app, callbacks, grant types | **Applications → Applications → [app]** |
| `roles2` on login tokens | **Actions → Triggers → post-login** |
| `roles2` on M2M tokens | **Actions → Triggers → credentials-exchange** |

---

## Mental model

```text
User (+ Google or DB login)
  + Auth0 role POOL.FIN
  + role permission urn:oracle:dbtools:ords:mcpserver:all
  + post-login Action → roles2
        │
        ▼
Access token
  aud = http://127.0.0.1:8080/mcp
  roles2 = ["POOL.FIN"]
  permissions = ["urn:oracle:dbtools:ords:mcpserver:all"]
        │
        ▼
ORDS /mcp
  → allow MCP
  → database_list = [mcp-fin] only
```

Next: [OPENCODE.md](./OPENCODE.md) · [LAB_WALKTHROUGH.md](./LAB_WALKTHROUGH.md) · [TROUBLESHOOTING.md](./TROUBLESHOOTING.md)
