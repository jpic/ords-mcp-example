# Troubleshooting

Errors seen in this lab and how to fix them. Prefer checking the **access token** claims when OpenCode misbehaves after login.

## Quick diagnostics

```bash
# Stack
docker compose ps
curl -sI http://127.0.0.1:8080/mcp | head -15
curl -s http://127.0.0.1:8080/.well-known/oauth-protected-resource/mcp

# OpenCode
opencode mcp list
ss -ltnp | grep 19876 || echo "callback port free"

# Token (after a login attempt)
python3 - <<'PY'
import json
from pathlib import Path
from jose import jwt
p = Path.home() / ".local/share/opencode/mcp-auth.json"
if not p.exists():
    print("no mcp-auth.json")
else:
    at = json.loads(p.read_text())["ords-mcp"]["tokens"]["accessToken"]
    c = jwt.get_unverified_claims(at)
    print("aud        ", c.get("aud"))
    print("roles2     ", c.get("roles2"))
    print("permissions", c.get("permissions"))
    print("scope      ", c.get("scope"))
    print("sub        ", c.get("sub"))
PY

# ORDS JWT errors
docker logs ords 2>&1 | grep -iE 'JWT|Role Claim|JWK|Forbidden' | tail -20
```

---

## Auth0 errors (browser)

### Callback URL mismatch  
`… is not in the list of allowed callback URLs`

**Cause:** Native app Allowed Callback URLs missing OpenCode’s redirect.

**Fix:** Add exactly:

```text
http://127.0.0.1:19876/mcp/oauth/callback
```

(and `http://localhost:19876/mcp/oauth/callback` if needed). Path must include `/mcp/oauth/callback`.

---

### Grant type 'authorization_code' not allowed

**Cause:** App is Machine to Machine, or Authorization Code grant disabled.

**Fix:**

- Application type = **Native** (or SPA)  
- Advanced → Grant Types → **Authorization Code** (+ Refresh Token)  
- Save  

Switching M2M → Native disables Client Credentials on that app — expected for OpenCode.

---

### ORDS advertises `https://my-proxy/mcp` but clients use `https://my-proxy/ords/mcp`

**Cause:** Reverse proxy maps `https://my-proxy/ords/` → `http://ords` (strips `/ords`). MCP is a host-root `/mcp` endpoint, not under `standalone.context.path`. ORDS reconstructs the resource from Host + `/mcp`. There is no public-prefix setting; audience does not rewrite advertised URLs.

**Fix:** Serve MCP on a dedicated host (`https://ords-mcp.company.com/mcp`) without stripping a prefix. Point OpenCode `url`, IdP API identifier, and `mcp.security.jwt.profile.audience` at that URL.

See [REVERSE_PROXY.md](./REVERSE_PROXY.md).

---

### Service not found: http://127.0.0.1:8080/mcp

**Cause:** Auth0 has no API whose **Identifier** equals that string.  
OpenCode sends `resource=http://127.0.0.1:8080/mcp`.  
An API named only `https://ords.lab/mcp` does **not** match.

**Fix:** Create API with Identifier **exactly** `http://127.0.0.1:8080/mcp`  
(http, 127.0.0.1, port 8080, path /mcp).  
Set `AUTH0_AUDIENCE` and ORDS audience to the same value; recreate `ords-config` volume if ORDS had the old audience.

Auth0 error text (token endpoint) looks like:

```text
Service not enabled within domain: http://127.0.0.1:8080/mcp
```

---

### Grant type 'password' / 'password-realm' not allowed

**Cause:** Native app does not enable Resource Owner Password.

**Fix:** Normal for OpenCode (uses auth code). For `scripts/test_auth0.py` user tests, either enable Password grant on a **dev-only** app (not recommended long-term) or use OpenCode tokens / a separate confidential app.

---

## OpenCode CLI errors

### Authentication failed (empty message)

**Common causes:**

1. Port **19876** already taken by another `opencode` process  
2. Callback server could not start  
3. Browser closed before CLI finished  

**Fix:**

```bash
ss -ltnp | grep 19876
kill <pid>          # the opencode holding the port
rm -f ~/.local/share/opencode/mcp-auth.json
set -a && source .env && set +a
opencode mcp auth ords-mcp
```

---

### Browser: Authorization successful · CLI: Unexpected status: needs_auth

**Meaning:** OAuth code exchange often **succeeded** (check `mcp-auth.json` for `accessToken`), but OpenCode still cannot use MCP.

**Typical ORDS response with that token:** **403 Forbidden**.

**Check token:**

| Claim | Bad | Good |
|-------|-----|------|
| `roles2` | `[]` or missing | `["POOL.FIN"]` |
| `permissions` | `[]` | `["urn:oracle:dbtools:ords:mcpserver:all"]` |

**Fix:**

1. User has Auth0 role (`POOL.FIN` / `POOL.HR`)  
2. **Role → Permissions** includes MCP permission on API `http://127.0.0.1:8080/mcp`  
3. post-login Action sets `roles2`  
4. API: RBAC + Add Permissions in Access Token  
5. `opencode mcp logout` && `opencode mcp auth` again  

When fixed, `opencode mcp list` shows **connected (OAuth)**.

---

### opencode mcp list → needs authentication (after successful auth)

Same as above: token present but ORDS rejects (401/403). Inspect claims and ORDS logs.

---

### No APIs / Permissions tab on Native Application

**Normal.** Configure:

- **Applications → APIs** (resource server)  
- **Roles → Permissions**  
- Not M2M authorize list for Native apps  

---

## ORDS errors (logs / HTTP)

### Missing Role Claim / Unsupported Role Claim Format

```text
JSON Web Token Validation Error: Unsupported Role Claim Format / Missing Role Claim
```

**Cause:** Token has no usable `roles2` array (or ORDS still points at wrong claim pointer).

**Fix:**

- Action: `setCustomClaim("roles2", roles)` — **not** `"roles"`  
- `MCP_ROLE_CLAIM=/roles2` and recreate ORDS config if needed  
- Re-login after Action deploy  

---

### HTTP 401 Unauthorized on /mcp with Bearer token

**Causes:** invalid signature, wrong `iss`/`aud`, JWKS unreachable, missing role claim.

**Fix:**

- ORDS can fetch JWKS:  
  `docker exec ords curl -fsSI https://$AUTH0_DOMAIN/.well-known/jwks.json`  
- Compose sets `dns: 1.1.1.1` / `8.8.8.8` if host DNS fails inside containers  
- `aud` must be `http://127.0.0.1:8080/mcp`  
- `iss` trailing slash  

---

### HTTP 403 Forbidden on /mcp with Bearer token

**Cause (this lab):** JWT valid but **no MCP scope/permission** and/or role not allowed for any pool.

**Fix:** Add API permission to the Auth0 **role**; ensure `roles2` contains `POOL.HR` and/or `POOL.FIN`; re-auth.

---

### No JWK State / UnknownHostException Auth0

**Cause:** ORDS container cannot resolve or reach Auth0.

**Fix:** Check container DNS/network; lab `docker-compose.yml` sets public DNS on `ords`. Restart ords.

---

### ORDS exits: AUTH0_DOMAIN required

**Fix:** Set `AUTH0_DOMAIN` in `.env`; `docker compose up -d ords`.

---

## Database / lab data

### HR / FIN / MCP users missing

**Cause:** `sql/01_lab_schemas.sql` runs only on **first** Oracle data volume create.

**Fix:**

```bash
docker compose down -v
docker compose up -d --build
```

or apply SQL manually against FREEPDB1 as SYS.

---

## Config drift

### Changed Auth0 audience or role claim; ORDS still old

```bash
docker compose stop ords && docker compose rm -f ords
docker volume rm ords_ords-config
docker compose up -d ords
```

`scripts/configure-mcp.sh` runs on each start and applies `.env`.

---

## Mental checklist (working system)

- [ ] API Identifier = `http://127.0.0.1:8080/mcp`  
- [ ] Native app + Authorization Code + callback 19876  
- [ ] Roles include MCP **permission**  
- [ ] Users have roles  
- [ ] post-login sets **`roles2`**  
- [ ] `.env` audience + `/roles2`  
- [ ] ORDS healthy; JWKS reachable  
- [ ] Fresh `opencode mcp auth`  
- [ ] Token has `roles2` **and** `permissions`  
- [ ] `opencode mcp list` → **connected (OAuth)**  

---

## Related

- [AUTH0_SETUP.md](./AUTH0_SETUP.md)  
- [OPENCODE.md](./OPENCODE.md)  
- [ARCHITECTURE.md](./ARCHITECTURE.md)  
- [REVERSE_PROXY.md](./REVERSE_PROXY.md)  
