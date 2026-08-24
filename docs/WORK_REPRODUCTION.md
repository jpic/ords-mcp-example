# Reproducing this lab at work

Port the **same security model** from Docker + Auth0 + OpenCode to Kubernetes and a corporate IdP.

## What to keep identical

| Concept | Lab value | Work |
|---------|-----------|------|
| MCP protocol | ORDS standalone `/mcp` | Same (not Tomcat for MCP) |
| JWT validation | iss, aud, JWKS | Corporate issuer + JWKS |
| Role claim | `roles2` (or IdP-safe name) | Map groups → same strings OR change ORDS pointer |
| Role strings | `POOL.HR`, `POOL.FIN` | Stable app roles / groups |
| Global MCP scope | `urn:oracle:dbtools:ords:mcpserver:all` | Same string on API/scope |
| Pool binding | `mcp.role` + `mcp.scope` per pool | One pool per real database |
| Client | OpenCode OAuth PKCE | OpenCode or other MCP client with OAuth |

## What must change

| Lab | Work |
|-----|------|
| API Identifier / MCP URL `http://127.0.0.1:8080/mcp` | Public HTTPS URL, e.g. `https://ords-mcp.company.com/mcp` |
| Auth0 free tenant | Entra ID / Okta / Auth0 Enterprise |
| One Oracle Free, two schemas | N databases; one MCP pool each |
| Docker Compose | Deployment + Ingress + Secrets + NetworkPolicy |
| Sample passwords in `.env` | Vault / External Secrets |

**Rule:** Auth0/Entra **API Identifier (audience)** = **exact MCP URL** the client uses (including scheme and path), because clients send OAuth `resource=` equal to that URL.

## Suggested work rollout

1. **POC (this lab)** — OpenCode + Auth0 + role isolation proven.  
2. **Staging ORDS** — HTTPS Ingress; API Identifier = public MCP URL; same `roles2` + permissions model.  
3. **IdP cutover** — Point ORDS JWT profile at corporate issuer/JWKS; map groups to `POOL.*` (or rename pools/roles consistently).  
4. **Pool catalog** — GitOps table: pool name, DB connection, `mcp.role`, owner team.  
5. **Hardening** — read-only DB users, replicas, NetworkPolicy, audit (`DBTOOLS$MCP_LOG`, session module/action), short-lived tokens.  

## ORDS settings to export

From `scripts/configure-mcp.sh` / running config:

```text
feature.mcp = true
mcp.security.jwt.profile.issuer
mcp.security.jwt.profile.audience          # = public MCP URL
mcp.security.jwt.profile.jwk.url
mcp.security.jwt.profile.authorization.server.url
mcp.security.jwt.profile.role.claim.name   # /roles2 or corporate claim pointer
# per pool:
db.hostname, db.port, db.servicename, db.username
mcp.role, mcp.scope
db.password (wallet / secret)
```

## IdP mapping notes

| Lab Auth0 | Corporate example |
|-----------|-------------------|
| Role `POOL.FIN` | App role or group `POOL.FIN` |
| Claim `roles2` | Custom claim (avoid IdP-reserved names) |
| Permission on role | App role includes MCP API scope/permission |
| Native app + PKCE | Public client for developer workstations |
| post-login Action | Entra optional claims / token configuration |

## OpenCode at work

- Callback URLs must include whatever redirect OpenCode uses (lab: `http://127.0.0.1:19876/mcp/oauth/callback`).  
- Corporate Conditional Access / device compliance may apply to the Auth0/Entra app.  
- Prefer separate Auth0/Entra apps: **interactive (Native)** vs **automation (M2M)**.  

## Security baseline

- [ ] Least-privilege, preferably **read-only** pool DB users  
- [ ] Prefer replicas / non-prod for LLM SQL  
- [ ] TLS everywhere in shared environments  
- [ ] Audience locked to MCP URL  
- [ ] Audit MCP SQL and sessions  
- [ ] Separate ORDS process from classic APEX/REST Tomcat if both exist  
- [ ] No long-lived DB passwords on laptops  

## Validation matrix (reuse lab tests)

| Test | Expect |
|------|--------|
| User with only POOL.FIN | `database_list` = fin pool only |
| User with only POOL.HR | hr pool only |
| User with both | both pools |
| Token without MCP permission | 403 / client needs_auth |
| Token without roles claim | 401 Missing Role Claim |
| Wrong audience | 401 |

## Related lab docs

- [ARCHITECTURE.md](./ARCHITECTURE.md)  
- [AUTH0_SETUP.md](./AUTH0_SETUP.md)  
- [OPENCODE.md](./OPENCODE.md)  
- [TROUBLESHOOTING.md](./TROUBLESHOOTING.md)  
