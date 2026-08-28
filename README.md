# ORDS MCP lab (Auth0 + Docker + OpenCode)

Personal lab that matches a **work-style** setup:

- **Oracle Free** (sample HR / FIN data)
- **ORDS 26.2+** standalone as an **MCP** server (`/mcp`)
- **Auth0** (OAuth2 + PKCE, JWT with `roles2` + MCP permission)
- **OpenCode** as MCP client (`opencode mcp auth`)

Validated end state: OpenCode shows **`ords-mcp connected (OAuth)`**, and the access token contains both `roles2` and the MCP permission.

## Quick start

### 1. Auth0

Follow the full guide (order matters):

**→ [docs/AUTH0_SETUP.md](docs/AUTH0_SETUP.md)**

You will create:

| Auth0 object | Lab value |
|--------------|-----------|
| API Identifier | `http://127.0.0.1:8080/mcp` |
| API permission | `urn:oracle:dbtools:ords:mcpserver:all` |
| Roles | `POOL.HR`, `POOL.FIN` (**each role must include the MCP permission**) |
| Native app | OpenCode client + callback on port `19876` |
| Trigger `post-login` | `setCustomClaim("roles2", …)` |

### 2. Lab env

```bash
cp .env.example .env
# AUTH0_DOMAIN=your-tenant.region.auth0.com
# AUTH0_AUDIENCE=http://127.0.0.1:8080/mcp
# AUTH0_CLIENT_ID=<Native app client id>
# MCP_ROLE_CLAIM=/roles2
```

### 3. Stack

```bash
docker compose up -d --build
docker compose ps
curl -sI http://127.0.0.1:8080/mcp    # expect 401 + WWW-Authenticate
```

### 4. OpenCode

```bash
cp opencode.json.example opencode.json
set -a && source .env && set +a
opencode mcp auth ords-mcp            # browser login
opencode mcp list                     # expect: connected (OAuth)
opencode
```

Details: [docs/OPENCODE.md](docs/OPENCODE.md).

## Documentation index

| Doc | Contents |
|-----|----------|
| [docs/AUTH0_SETUP.md](docs/AUTH0_SETUP.md) | Exhaustive Auth0 setup (API, roles, app, triggers) |
| [docs/OPENCODE.md](docs/OPENCODE.md) | OpenCode OAuth, token checks, troubleshooting |
| [docs/LAB_WALKTHROUGH.md](docs/LAB_WALKTHROUGH.md) | Full runbook from zero to working MCP |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Security model, token claims, pools |
| [docs/WORK_REPRODUCTION.md](docs/WORK_REPRODUCTION.md) | Port to K8s / corporate IdP |
| [docs/REVERSE_PROXY.md](docs/REVERSE_PROXY.md) | Public URL, audience, path prefix vs dedicated host |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Error → fix map (from real failures) |
| [docs/PRODUCTION.md](docs/PRODUCTION.md) | **Build & run production `yourlabs/ords`** |
| [docs/PRODUCTION_IMAGE_PLAN.md](docs/PRODUCTION_IMAGE_PLAN.md) | Full production roadmap / audit design |

## Pools (Oracle Free `FREEPDB1`)

| ORDS pool | Auth0 role (`roles2`) | DB user | Sample SQL |
|-----------|----------------------|---------|------------|
| `mcp-hr` | `POOL.HR` | `HR_MCP_RO` | `SELECT * FROM employees` |
| `mcp-fin` | `POOL.FIN` | `FIN_MCP_RO` | `SELECT * FROM invoices` |

## Production image

```bash
./deploy/docker/build.sh
# → yourlabs/ords:mcp-26.2.2.204.1619-<gitsha>
```

- Pinned Temurin digest + ORDS / Instant Client / SQLcl zip **SHA256**
- Client tools: `sqlplus`, SQLcl (`sql` / `sqlcl`), `python3` + `oracledb`
- Fail-closed init (no default DB passwords)
- CI: lint, Trivy, SBOM (`.github/workflows/ci.yml`)
- Helm chart: `deploy/k8s/ords-mcp`

See **[docs/PRODUCTION.md](docs/PRODUCTION.md)**.

## Layout

```text
docker-compose.yml              Lab: Oracle Free + ORDS
Dockerfile                      Lab image (pinned ORDS; AUTO_INIT)
deploy/docker/                  Production Dockerfile, build.sh, init/serve
deploy/k8s/ords-mcp/            Helm chart
deploy/pools/                   Pool *.env examples
scripts/test_auth0.py           Auth0 + ORDS smoke test
scripts/mcp-curl-smoke.sh       MCP calls with bearer token
sql/01_lab_schemas.sql          HR/FIN + MCP users (first DB boot)
opencode.json.example           OpenCode remote MCP + OAuth
docs/                           Runbooks + production plan
```

## Hard requirements (do not skip)

1. **API Identifier = MCP URL** = `http://127.0.0.1:8080/mcp` (not `https://ords.lab/mcp` unless everything uses that URL).
2. Claim name is **`roles2`**, never Auth0-reserved **`roles`**.
3. Each Auth0 **role** must include permission **`urn:oracle:dbtools:ords:mcpserver:all`**.
4. After Auth0 changes: **`opencode mcp logout`** then **`opencode mcp auth`** again (JWTs are not updated in place).
5. Only **one** `opencode mcp auth` at a time (callback port **19876**).

## References

- [ORDS as streaming HTTP MCP server (Jeff Smith)](https://www.thatjeffsmith.com/archive/2026/07/ords-now-a-streaming-http-mcp-server-for-oracle-database/)
- [ORDS 26.2 MCP docs](https://docs.oracle.com/en/database/oracle/oracle-rest-data-services/26.2/orddg/using-ords-model-context-protocol-mcp.html)
- [OpenCode MCP servers](https://opencode.ai/docs/mcp-servers/)

## License

MIT. See [LICENSE](LICENSE). Oracle Database / ORDS remain Oracle products; this repo does not redistribute their binaries.
