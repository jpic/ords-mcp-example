# Production guide (`yourlabs/ords`)

How to build, audit, and run the **production** ORDS MCP image.

For full roadmap detail see [PRODUCTION_IMAGE_PLAN.md](./PRODUCTION_IMAGE_PLAN.md).

## What “production-ready” means here

| Capability | Status |
|------------|--------|
| Pinned base image digest | ✅ `deploy/docker/versions.env` |
| Pinned ORDS version + SHA256 verify | ✅ |
| Non-root user (54321) | ✅ |
| No default DB passwords in prod scripts | ✅ `init-config.sh` |
| Fail-closed missing JWT/pools | ✅ |
| init / serve split | ✅ |
| Healthcheck tolerant of MCP 401 | ✅ |
| CI lint + Trivy + SBOM | ✅ `.github/workflows/ci.yml` |
| Helm chart + NetworkPolicy | ✅ `deploy/k8s/ords-mcp` |
| Cosign push to registry | ⚪ Enable in CI when credentials exist |
| Corporate IdP/DB values | ⚪ You supply via Helm values / secrets |

## Build

```bash
./deploy/docker/build.sh
docker images 'yourlabs/ords*'
```

## Local smoke against lab Oracle

1. Lab DB running (`docker compose up -d oracle` from repo root).  
2. Pool files under `deploy/pools/smoke` + secrets (gitignored).  
3. Auth0 JWT env exported.  
4. `ORDS_AUTO_INIT=true` compose file: `deploy/docker/docker-compose.prod-smoke.yml`.

## Kubernetes

1. Build & push image to your registry (tag + digest).  
2. Create secret with pool password files.  
3. Fill `values.yaml` JWT audience = **public MCP URL**.  
4. `helm upgrade --install ords-mcp ./deploy/k8s/ords-mcp -f values-prod.yaml`.  

Init container runs `init`; main container runs `serve` only.

## Audits on every release

1. CI green (hadolint, shellcheck, gitleaks, Trivy HIGH+, SBOM artifact)  
2. Record image **digest** in change ticket  
3. Staging smoke: OAuth + `database_list` role isolation  
4. Promote **digest** to prod (not `:latest`)  

## Lab vs production images

| | Lab (`Dockerfile` → `yourlabs/ords:lab`) | Prod (`deploy/docker/Dockerfile`) |
|--|------------------------------------------|-------------------------------------|
| Bootstrap pools from compose env | Yes | No |
| Default passwords | Only if you set compose env (lab) | Impossible without secrets |
| AUTO_INIT | Yes via compose | No (initContainer) |
| netcat | Yes (wait-for-db optional) | No |

## Bundled client tools

The production image also ships CLI clients (non-root `oracle` user, on `PATH`):

| Tool | Binary | Source |
|------|--------|--------|
| SQL*Plus | `sqlplus` | Instant Client Basic Light + SQL*Plus (`IC_*` in `versions.env`) |
| SQLcl | `sql` and `sqlcl` | SQLcl zip (`SQLCL_*`) |
| Python | `python3` | Ubuntu `python3` + pip |
| python-oracledb | `import oracledb` | PyPI pin `ORACLEDB_VERSION` (thin mode; Instant Client available for thick) |

`sqlplus` needs Instant Client libs (`LD_LIBRARY_PATH=/opt/oracle/instantclient`). SQLcl uses the image JRE. python-oracledb defaults to thin mode and does not require Instant Client.

## Upgrade ORDS / clients

1. Download new zip(s); compute SHA256  
2. Update `deploy/docker/versions.env` (`ORDS_*`, and/or `IC_*`, `SQLCL_*`, `ORACLEDB_VERSION`)  
3. PR → CI → staging → prod digest  
