# ORDS MCP behind a reverse proxy

This page is only about the reverse proxy in front of **ORDS**. The corporate IdP (authorize, token, JWKS, OIDC discovery) is a **different host**. Do not put those IdP URLs on the ORDS proxy, and do not treat IdP `/.well-known/jwks.json` as the ORDS `/.well-known/oauth-protected-resource/mcp` document.

```text
 OpenCode / MCP client
        │
        │  1. POST https://ords-mcp.company.com/mcp
        ▼
 public reverse proxy  ──►  ORDS  :8080/mcp
        │                     │
        │                     │  3. ORDS fetches JWKS (server-side)
        │                     ▼
        │              https://login.company.com/.well-known/jwks.json
        │
        │  2. Browser OAuth (authorize / token) — not via the ORDS proxy
        ▼
 https://login.company.com/authorize
```

| URL | Host | Who calls it |
|-----|------|----------------|
| `https://ords-mcp.company.com/mcp` | ORDS (this proxy) | MCP client |
| `https://ords-mcp.company.com/.well-known/oauth-protected-resource/mcp` | ORDS (this proxy) | MCP client (RFC 9728 **resource** metadata) |
| `https://login.company.com/authorize` (token, etc.) | Corporate IdP | Browser / OpenCode |
| `https://login.company.com/.well-known/jwks.json` | Corporate IdP | **ORDS** (outbound; must reach the IdP from the ORDS process) |
| `https://login.company.com/.well-known/openid-configuration` | Corporate IdP | MCP client / OpenCode |

`mcp.security.jwt.profile.issuer`, `.jwk.url`, and `.authorization.server.url` are IdP URLs. They are not reverse-proxy paths.

ORDS MCP is a **host-root** endpoint. It is **not** served under the `/ords` REST context.

Oracle documents MCP at `/mcp` on the ORDS host, with OAuth **resource** discovery at `/.well-known/oauth-protected-resource/mcp` (still on the ORDS host). Jeff Smith: *there is no `ords` in that URL*. `standalone.context.path` (default `/ords`) is REST/APEX only and does **not** move MCP.

There is **no** ORDS setting for a reverse-proxy path prefix (`X-Forwarded-Prefix`, public base URL, mount MCP at `/ords/mcp`). Audience is not that setting.

## Audience = public MCP URL

`mcp.security.jwt.profile.audience` is the **public MCP URL**: the exact string clients send as OAuth `resource=`, and the exact IdP API identifier / JWT `aud`.

Same value in all four places:

| Place | Example (preferred) | Example (path prefix — avoid if you can) |
|-------|---------------------|------------------------------------------|
| Client MCP URL | `https://ords-mcp.company.com/mcp` | `https://my-proxy/ords/mcp` |
| IdP API identifier | same | same |
| JWT `aud` | same | same |
| ORDS `mcp.security.jwt.profile.audience` | same | same |

Match **scheme, host, port, path**. No trailing slash unless every side has one.  
`https://my-proxy/mcp` and `https://my-proxy/ords/mcp` are different audiences.

This is **JWT validation only**. Setting audience to `https://my-proxy/ords/mcp` does **not** make ORDS generate `/ords/mcp` in `WWW-Authenticate` or protected-resource metadata.

### OpenCode

OpenCode is why this must be exact.

`opencode.json` `mcp.<name>.url` is sent as OAuth `resource=` on authorize:

```text
https://<idp>/authorize
  ?…
  &resource=https://ords-mcp.company.com/mcp
```

Auth0/Entra map `resource=` to the API identifier; that becomes JWT `aud`; ORDS checks `aud` against `mcp.security.jwt.profile.audience`.

Use the **public** URL the workstation reaches, not the internal `http://ords:8080/mcp`.

If OpenCode is pointed at `https://my-proxy/ords/mcp` but the IdP API / ORDS audience is `https://my-proxy/mcp` (or the reverse), you get Auth0 **Service not found** / **Service not enabled**, or ORDS **401** for wrong `aud`.

OpenCode has no special audience. Same rule as any MCP client that implements resource indicators (RFC 8707).

## What ORDS can configure (proxy-related)

```bash
ords --config "$ORDS_CONFIG" config set --global \
  mcp.security.jwt.profile.audience "https://ords-mcp.company.com/mcp"

ords --config "$ORDS_CONFIG" config set --global \
  security.httpsHeaderCheck "X-Forwarded-Proto: https"
```

| Setting | What it does |
|---------|----------------|
| `mcp.security.jwt.profile.audience` | Expected JWT `aud` = public MCP URL |
| `security.httpsHeaderCheck` | `X-Forwarded-Proto: https` so ORDS knows TLS was terminated at the proxy |
| `security.externalSessionTrustedOrigins` | CORS allowlist if a browser Origin is the public host |
| `standalone.context.path` | REST/APEX only — **does not** move `/mcp` |

Helm: `config.jwtAudience` must be that same public URL (`deploy/k8s/ords-mcp/values.yaml`).

## Preferred topology: hostname, no path strip

Give **ORDS** a hostname. Do **not** strip `/ords`. Do **not** front the IdP on this host.

```text
https://ords-mcp.company.com/mcp
  → http://ords:8080/mcp

https://ords-mcp.company.com/.well-known/oauth-protected-resource/mcp
  → http://ords:8080/.well-known/oauth-protected-resource/mcp
```

Proxy those two ORDS paths without rewriting them. Set audience to `https://ords-mcp.company.com/mcp`.

That is what Oracle’s MCP docs, this lab, and the Helm chart assume (`ingress.hosts[].paths` default `/` on a dedicated ORDS host). A catch-all `/` is fine **only** because this hostname is ORDS, not the IdP.

Forward:

- `Host` (public ORDS host) or `X-Forwarded-Host`
- `X-Forwarded-Proto: https`
- `X-Forwarded-For`

Disable response buffering and use long read/send timeouts on `/mcp` (streamable HTTP).

ORDS must still be able to **egress** to the IdP JWKS URL (NetworkPolicy, proxy, DNS). That traffic does not go through this reverse proxy.

### nginx sketch (dedicated ORDS host)

```nginx
# ORDS MCP only. IdP / JWKS stay on login.company.com — do not add them here.

location /mcp {
    proxy_pass http://ords:8080;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header Connection "";
    proxy_buffering off;
    proxy_cache off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
}

# RFC 9728 *resource* metadata on the ORDS host — not JWKS, not OIDC discovery
location /.well-known/oauth-protected-resource/mcp {
    proxy_pass http://ords:8080;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}
```

## Path prefix (`https://my-proxy/ords/` → `http://ords`)

This is the layout that breaks discovery:

```text
https://my-proxy/ords/mcp  →  http://ords/mcp
```

ORDS only sees Host `my-proxy` and path `/mcp`. It advertises:

| What | ORDS reconstructs | Client used |
|------|-------------------|-------------|
| MCP resource | `https://my-proxy/mcp` | `https://my-proxy/ords/mcp` |
| `WWW-Authenticate` `resource_metadata` | `https://my-proxy/.well-known/oauth-protected-resource/mcp` | under `/ords/` if that is all you proxied |

That is expected. There is no prefix knob.

Do **not** forward `https://my-proxy/ords/mcp` to `http://ords/ords/mcp` without stripping: MCP is not at `/ords/mcp` on the backend (404).

If policy forces the `/ords` prefix:

1. Strip `/ords` so POSTs reach `/mcp`.
2. Also publish discovery where clients look.

Minimum extra maps:

```text
https://my-proxy/ords/mcp
  → http://ords/mcp

https://my-proxy/ords/.well-known/oauth-protected-resource/mcp
  → http://ords/.well-known/oauth-protected-resource/mcp
```

RFC 9728 path insertion also tries the **host root**:

```text
https://my-proxy/.well-known/oauth-protected-resource/ords/mcp
```

and ORDS itself advertises:

```text
https://my-proxy/mcp
https://my-proxy/.well-known/oauth-protected-resource/mcp
```

Those last two are **not** under `/ords/`. A location that only proxies `/ords/` never sees them.

Then either:

- also proxy `/mcp` and `/.well-known/oauth-protected-resource/mcp` at the **host root**, and point OpenCode / audience at `https://my-proxy/mcp`, or
- rewrite `WWW-Authenticate` and the JSON `resource` field so they include `/ords` (fragile; not an ORDS feature).

Do not “fix” this by proxying IdP JWKS or OIDC `/.well-known/` onto `my-proxy`. Those stay on the IdP host.

Cleaner: expose MCP at host root (`https://my-proxy/mcp`) and leave `/ords` for classic REST/APEX if you must share a host.

## Endpoints this reverse proxy must reach

Only ORDS:

| Public path (preferred host) | ORDS path | Role |
|------------------------------|-----------|------|
| `/mcp` | `/mcp` | Streamable HTTP MCP + 401 Bearer challenge |
| `/.well-known/oauth-protected-resource/mcp` | same | RFC 9728 **protected-resource** metadata (lists `authorization_servers` if configured) |

Not this proxy:

| URL | Config | Role |
|-----|--------|------|
| IdP JWKS | `mcp.security.jwt.profile.jwk.url` | ORDS validates JWT signatures |
| IdP issuer | `mcp.security.jwt.profile.issuer` | JWT `iss` |
| IdP authorize/token | `mcp.security.jwt.profile.authorization.server.url` | OpenCode browser login; copied into resource metadata as `authorization_servers` |

Unauthenticated `GET`/`POST` `/mcp` should return **401** with `WWW-Authenticate` pointing at the **ORDS** well-known URL above. That document may *name* the IdP; the client then talks to the IdP on its own hostname.

## Verify

Compare advertised URLs to the URL the client actually uses:

```bash
curl -sI https://ords-mcp.company.com/mcp
curl -s  https://ords-mcp.company.com/.well-known/oauth-protected-resource/mcp
```

Expect:

- `401` + `WWW-Authenticate: Bearer … resource_metadata="https://ords-mcp.company.com/.well-known/oauth-protected-resource/mcp"`
- JSON `"resource": "https://ords-mcp.company.com/mcp"`

If those bodies say `https://my-proxy/mcp` while OpenCode uses `https://my-proxy/ords/mcp`, that is Host + `/mcp` reconstruction. Changing audience only fixes JWT validation, not those advertised URLs.

After OAuth, the access token `aud` must equal that same public MCP URL (see [OPENCODE.md](./OPENCODE.md) token dump).

## Related

- [ARCHITECTURE.md](./ARCHITECTURE.md) — why API identifier = MCP URL  
- [OPENCODE.md](./OPENCODE.md) — `resource=` on the authorize URL  
- [AUTH0_SETUP.md](./AUTH0_SETUP.md) — API identifier  
- [WORK_REPRODUCTION.md](./WORK_REPRODUCTION.md) — port to K8s / corporate IdP  
- [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) — Service not found / wrong `aud`  
- [Oracle — Configuring MCP](https://docs.oracle.com/en/database/oracle/oracle-rest-data-services/26.2/ordig/configuring-model-context-protocol-mcp.html)  
- [Oracle — Using ORDS MCP](https://docs.oracle.com/en/database/oracle/oracle-rest-data-services/26.2/orddg/using-ords-model-context-protocol-mcp.html)  
