# Lab walkthrough (zero → working OpenCode MCP)

End-to-end path that matches a **validated** setup.

## Prerequisites

- Docker Engine + Compose v2  
- ~4–8 GB RAM (Oracle Free)  
- Auth0 tenant  
- OpenCode (`opencode --version`)  
- `python3` + optional `python-jose` for token inspection  

## Phase A — Auth0

Complete **[AUTH0_SETUP.md](./AUTH0_SETUP.md)** fully, especially:

1. API Identifier = `http://127.0.0.1:8080/mcp`  
2. Permission `urn:oracle:dbtools:ords:mcpserver:all` on the API  
3. Roles `POOL.HR` / `POOL.FIN` with that **permission on each role**  
4. Native app + callback `http://127.0.0.1:19876/mcp/oauth/callback`  
5. Trigger **post-login** → `roles2`  
6. User has the correct role assigned  

## Phase B — Lab files

```bash
cd /path/to/ords
cp .env.example .env
# fill AUTH0_DOMAIN, AUTH0_AUDIENCE, AUTH0_CLIENT_ID
# AUTH0_AUDIENCE=http://127.0.0.1:8080/mcp
# MCP_ROLE_CLAIM=/roles2

cp opencode.json.example opencode.json
```

## Phase C — Start infrastructure

```bash
docker compose up -d --build
docker compose ps
```

Expect `ords` and `ords-oracle` **healthy**.

First Oracle volume creation runs `sql/01_lab_schemas.sql` (HR/FIN + MCP users).

Verify DB:

```bash
docker exec -i ords-oracle sqlplus -s sys/${ORACLE_PWD:-OracleFree123}@//localhost/FREEPDB1 as sysdba <<'SQL'
SELECT username FROM dba_users
 WHERE username IN ('HR','FIN','HR_MCP_RO','FIN_MCP_RO')
 ORDER BY 1;
SQL
```

Verify ORDS MCP + Auth0 wiring:

```bash
curl -sI http://127.0.0.1:8080/mcp | head -10
curl -s http://127.0.0.1:8080/.well-known/oauth-protected-resource/mcp
docker exec ords ords --config /etc/ords/config config list | grep -iE 'audience|issuer|role.claim|feature.mcp'
```

## Phase D — OpenCode OAuth

```bash
ss -ltnp | grep 19876 || echo "callback port free"
set -a && source .env && set +a
opencode mcp logout ords-mcp 2>/dev/null
opencode mcp auth ords-mcp
```

Complete browser login. Then:

```bash
opencode mcp list
```

**Done when:**

```text
✓ ords-mcp connected (OAuth)
```

## Phase E — Use it

```bash
opencode
```

Examples:

- “Using ords-mcp, list the databases I can access.”  
- “On mcp-fin, run: select * from invoices”  
- “On mcp-fin, run: select * from session_identity”  

## Phase F — Optional smoke scripts

```bash
# With token from OpenCode file:
export MCP_ACCESS_TOKEN=$(python3 - <<'PY'
import json
from pathlib import Path
print(json.loads(Path.home().joinpath(".local/share/opencode/mcp-auth.json").read_text())["ords-mcp"]["tokens"]["accessToken"])
PY
)
./scripts/mcp-curl-smoke.sh
```

## Reset procedures

| Goal | Command |
|------|---------|
| Restart ORDS only | `docker compose restart ords` |
| Rebuild ORDS JWT/pool config | `docker compose stop ords && docker compose rm -f ords && docker volume rm ords_ords-config && docker compose up -d ords` |
| Wipe DB + ORDS config | `docker compose down -v && docker compose up -d --build` |
| Clear OpenCode tokens | `opencode mcp logout ords-mcp` |

## Success criteria

- [ ] `/mcp` returns 401 without token  
- [ ] Resource metadata `resource` = `http://127.0.0.1:8080/mcp`  
- [ ] Access token has `roles2` and `permissions` including MCP scope  
- [ ] `opencode mcp list` → **connected (OAuth)**  
- [ ] `database_list` matches user roles (FIN → mcp-fin only)  
- [ ] SQL on allowed pool works  

## Next

- Day-to-day OpenCode: [OPENCODE.md](./OPENCODE.md)  
- Errors: [TROUBLESHOOTING.md](./TROUBLESHOOTING.md)  
- Work/K8s: [WORK_REPRODUCTION.md](./WORK_REPRODUCTION.md)  
