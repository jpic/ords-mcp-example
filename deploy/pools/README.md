# Pool definition files

Place one `*.env` file per MCP database pool in a directory mounted at  
`/etc/ords/pools.d` when running **`init`**.

## Required keys

| Key | Example | Description |
|-----|---------|-------------|
| `NAME` | `mcp-fin` | ORDS pool name (URL path segment) |
| `HOST` | `fin-db.example.com` | DB hostname |
| `PORT` | `1521` | Listener port |
| `SERVICE` | `FINPDB` | Service name |
| `USERNAME` | `FIN_MCP_RO` | Direct DB user (not ORDS_PUBLIC_USER) |
| `ROLE` | `POOL.FIN` | JWT `roles2` value required for this pool |

## Password (exactly one)

| Key | Description |
|-----|-------------|
| `PASSWORD_FILE` | Path to file containing password (preferred in K8s) |
| `PASSWORD` | Inline password (**avoid** in Git; OK via sealed secret env) |

## Optional

| Key | Default |
|-----|---------|
| `DESCRIPTION` | `MCP pool <NAME>` |
| `SCOPE` | `urn:oracle:dbtools:ords:mcpserver:all` |

## Example

See `mcp-fin.env.example` and `mcp-hr.env.example`.

In Kubernetes, mount:

- ConfigMap → `/etc/ords/pools.d/mcp-fin.env` (without PASSWORD)
- Secret file → `/var/run/secrets/ords/fin-password`  
  and set `PASSWORD_FILE=/var/run/secrets/ords/fin-password` in the env file or overlay.
