# Production image: `yourlabs/ords`

## Build

```bash
./deploy/docker/build.sh
# → yourlabs/ords:mcp-26.2.2.204.1619-<gitsha>
```

Pinned inputs: `versions.env` (Temurin digest, ORDS version + SHA256).

## Run modes

| Command | Purpose |
|---------|---------|
| `init` | Write JWT + pools from env + `/etc/ords/pools.d/*.env`, then exit |
| `serve` | Start ORDS (requires prior init, unless `ORDS_AUTO_INIT=true`) |
| `check` | Exit 0 if config marker present |

## Required env (init)

- `ORDS_JWT_ISSUER`
- `ORDS_JWT_AUDIENCE` — must equal public MCP URL
- `ORDS_JWT_JWKS_URL`
- Optional: `ORDS_JWT_AUTH_SERVER_URL`, `ORDS_JWT_ROLE_CLAIM` (default `/roles2`)

## Pools

See [../pools/README.md](../pools/README.md). **No default passwords.**

## CI

GitHub Actions: `.github/workflows/ci.yml` — lint, build, Trivy, SBOM.

## K8s

```bash
helm lint deploy/k8s/ords-mcp
helm upgrade --install ords-mcp deploy/k8s/ords-mcp -f my-values.yaml
```
