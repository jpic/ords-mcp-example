#!/usr/bin/env python3
"""
Test Auth0 + ORDS MCP lab wiring.

Loads credentials from repo .env (never prints secrets).

Usage:
  python3 scripts/test_auth0.py

  # Prefer a real user token (roles on the JWT):
  AUTH0_TEST_USERNAME='user@example.com' AUTH0_TEST_PASSWORD='...' \\
    python3 scripts/test_auth0.py

Exit codes: 0 = all critical checks passed, 1 = failure.
"""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load_dotenv(path: Path) -> None:
    if not path.is_file():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        k, v = k.strip(), v.strip().strip("'").strip('"')
        os.environ.setdefault(k, v)


def http_json(
    url: str,
    *,
    method: str = "GET",
    data: dict | None = None,
    headers: dict | None = None,
    form: bool = False,
) -> tuple[int, dict | str]:
    hdrs = dict(headers or {})
    body = None
    if data is not None:
        if form:
            body = urllib.parse.urlencode(data).encode()
            hdrs.setdefault("Content-Type", "application/x-www-form-urlencoded")
        else:
            body = json.dumps(data).encode()
            hdrs.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(url, data=body, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode()
            code = resp.status
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors="replace")
        code = e.code
    try:
        return code, json.loads(raw) if raw else {}
    except json.JSONDecodeError:
        return code, raw


def ok(msg: str) -> None:
    print(f"  OK  {msg}")


def fail(msg: str) -> None:
    print(f" FAIL {msg}")


def warn(msg: str) -> None:
    print(f" WARN {msg}")


def section(title: str) -> None:
    print(f"\n== {title} ==")


def main() -> int:
    load_dotenv(ROOT / ".env")
    try:
        from jose import jwt
        from jose.backends import RSAKey
    except ImportError:
        print("Install: pip install 'python-jose[cryptography]'", file=sys.stderr)
        return 1

    domain = os.environ.get("AUTH0_DOMAIN", "").strip()
    audience = os.environ.get("AUTH0_AUDIENCE", "https://ords.lab/mcp").strip()
    client_id = os.environ.get("AUTH0_CLIENT_ID", "").strip()
    client_secret = os.environ.get("AUTH0_CLIENT_SECRET", "").strip()
    role_claim = os.environ.get("MCP_ROLE_CLAIM", "/roles2").strip() or "/roles2"
    ords_mcp = os.environ.get("ORDS_MCP_URL", "http://127.0.0.1:8080/mcp").rstrip("/")
    mcp_scope = "urn:oracle:dbtools:ords:mcpserver:all"

    errors = 0
    print("Auth0 + ORDS MCP lab test")
    print(f"  domain   = {domain or '(missing)'}")
    print(f"  audience = {audience}")
    print(f"  client   = {client_id[:8]}…{client_id[-4:] if len(client_id) > 12 else ''}")
    print(f"  ords mcp = {ords_mcp}")

    if not domain or not client_id:
        fail("AUTH0_DOMAIN and AUTH0_CLIENT_ID required in .env")
        return 1

    issuer = f"https://{domain}/"
    jwks_url = f"https://{domain}/.well-known/jwks.json"
    token_url = f"https://{domain}/oauth/token"
    oidc_url = f"https://{domain}/.well-known/openid-configuration"

    # --- Discovery / JWKS ---
    section("1. Auth0 discovery & JWKS")
    code, oidc = http_json(oidc_url)
    if code == 200 and isinstance(oidc, dict) and oidc.get("issuer"):
        ok(f"OIDC issuer = {oidc.get('issuer')}")
        if oidc.get("issuer") not in (issuer, issuer.rstrip("/")):
            warn(f"OIDC issuer differs from expected {issuer}")
    else:
        fail(f"OIDC discovery HTTP {code}: {oidc!r}"[:200])
        errors += 1

    code, jwks = http_json(jwks_url)
    if code == 200 and isinstance(jwks, dict) and jwks.get("keys"):
        ok(f"JWKS has {len(jwks['keys'])} key(s)")
    else:
        fail(f"JWKS HTTP {code}")
        errors += 1
        return 1

    # --- Token ---
    section("2. Obtain access token")
    token = None
    token_source = None
    user = os.environ.get("AUTH0_TEST_USERNAME", "").strip()
    password = os.environ.get("AUTH0_TEST_PASSWORD", "").strip()

    if user and password and client_secret:
        code, body = http_json(
            token_url,
            method="POST",
            data={
                "grant_type": "http://auth0.com/oauth/grant-type/password-realm",
                "username": user,
                "password": password,
                "client_id": client_id,
                "client_secret": client_secret,
                "audience": audience,
                "scope": f"openid profile email {mcp_scope}",
                "realm": os.environ.get("AUTH0_REALM", "Username-Password-Authentication"),
            },
        )
        if code == 200 and isinstance(body, dict) and body.get("access_token"):
            token = body["access_token"]
            token_source = f"password-realm user={user}"
            ok(token_source)
        else:
            # try standard password grant
            code2, body2 = http_json(
                token_url,
                method="POST",
                data={
                    "grant_type": "password",
                    "username": user,
                    "password": password,
                    "client_id": client_id,
                    "client_secret": client_secret,
                    "audience": audience,
                    "scope": f"openid profile email {mcp_scope}",
                },
            )
            if code2 == 200 and isinstance(body2, dict) and body2.get("access_token"):
                token = body2["access_token"]
                token_source = f"password grant user={user}"
                ok(token_source)
            else:
                warn(f"user token failed HTTP {code}: {body if isinstance(body, dict) else body}"[:240])
                warn(f"password grant HTTP {code2}: {body2 if isinstance(body2, dict) else body2}"[:240])

    if token is None and client_secret:
        code, body = http_json(
            token_url,
            method="POST",
            data={
                "grant_type": "client_credentials",
                "client_id": client_id,
                "client_secret": client_secret,
                "audience": audience,
            },
        )
        if code == 200 and isinstance(body, dict) and body.get("access_token"):
            token = body["access_token"]
            token_source = "client_credentials (M2M)"
            ok(token_source)
            warn(
                "M2M tokens need claim roles2: [] "
                "(Actions → Triggers → credentials-exchange). "
                f"Also need API permission {mcp_scope}"
            )
        else:
            fail(f"client_credentials HTTP {code}: {body if isinstance(body, dict) else body}"[:300])
            errors += 1
            if isinstance(body, dict) and "scope" in str(body).lower():
                warn(
                    "Authorize this app for the API: Auth0 → APIs → ORDS MCP Lab → "
                    "Machine to Machine Applications → enable the app + MCP permission"
                )

    if not token:
        fail("No access token obtained. Enable client_credentials on the API/app, or set AUTH0_TEST_USERNAME/PASSWORD")
        errors += 1
        section("Summary")
        print(f"  {errors} failure(s). Fix Auth0 app/API grants, then re-run.")
        return 1

    # --- Validate JWT ---
    section("3. Validate JWT signature & claims")
    try:
        header = jwt.get_unverified_header(token)
        kid = header.get("kid")
        key = None
        for jwk in jwks["keys"]:
            if jwk.get("kid") == kid:
                key = jwk
                break
        if key is None:
            key = jwks["keys"][0]
            warn(f"kid {kid} not in JWKS; using first key")

        claims = jwt.decode(
            token,
            key,
            algorithms=["RS256"],
            audience=audience,
            issuer=issuer,
            options={"verify_at_hash": False},
        )
        ok("signature + iss + aud verified")
    except Exception as exc:  # noqa: BLE001
        # Auth0 often puts multiple audiences
        try:
            claims = jwt.decode(
                token,
                key,
                algorithms=["RS256"],
                audience=audience,
                issuer=issuer.rstrip("/"),
                options={"verify_at_hash": False},
            )
            ok("signature verified (issuer without trailing slash)")
        except Exception as exc2:  # noqa: BLE001
            fail(f"JWT validation: {exc}")
            fail(f"retry: {exc2}")
            # still show unverified claims
            claims = jwt.get_unverified_claims(token)
            warn("showing unverified claims for debugging")
            errors += 1

    aud = claims.get("aud")
    iss = claims.get("iss")
    scope = claims.get("scope") or " ".join(claims.get("permissions") or [])
    print(f"  iss    = {iss}")
    print(f"  aud    = {aud}")
    print(f"  sub    = {claims.get('sub')}")
    print(f"  scope  = {scope!r}"[:200])
    print(f"  gty    = {claims.get('gty')}")  # client-credentials

    # Resolve role claim from MCP_ROLE_CLAIM JSON pointer (e.g. /roles2)
    def claim_from_pointer(data: dict, pointer: str):
        if not pointer.startswith("/"):
            return data.get(pointer)
        # unescape ~1 -> / , ~0 -> ~
        key = pointer[1:].replace("~1", "/").replace("~0", "~")
        if key in data:
            return data.get(key)
        return None

    roles = claim_from_pointer(claims, role_claim)
    if roles is None:
        for k, v in claims.items():
            if "role" in k.lower():
                roles = v
                warn(f"role-like claim under {k!r} — set MCP_ROLE_CLAIM=/{k} if needed")
                break

    print(f"  role claim {role_claim} = {roles!r}")
    if claims.get("roles") is not None:
        warn('token has reserved claim "roles" — ORDS lab expects "roles2"')

    if iss and not str(iss).endswith("/"):
        warn("iss has no trailing slash; ORDS is configured with trailing slash")
    if audience not in (aud if isinstance(aud, list) else [aud]):
        fail(f"audience {audience!r} not in token aud {aud!r}")
        errors += 1
    else:
        ok(f"audience includes {audience}")

    if mcp_scope.replace(":", "") in str(scope).replace(":", "") or mcp_scope in str(scope):
        ok(f"MCP scope present: {mcp_scope}")
    elif claims.get("permissions") and mcp_scope in claims.get("permissions", []):
        ok("MCP scope present in permissions[]")
    else:
        warn(f"MCP scope {mcp_scope!r} not obvious in token — authorize API permission on the app/M2M grant")

    if not roles:
        warn(
            "No roles2 claim — bind Action on Triggers (post-login and/or "
            "credentials-exchange) with setCustomClaim('roles2', ...)"
        )
    else:
        ok(f"roles2 (or configured claim) OK: {roles}")

    # --- ORDS resource metadata ---
    section("4. ORDS MCP resource metadata")
    meta_url = ords_mcp.replace("/mcp", "/.well-known/oauth-protected-resource/mcp")
    if not meta_url.endswith("oauth-protected-resource/mcp"):
        meta_url = "http://127.0.0.1:8080/.well-known/oauth-protected-resource/mcp"
    code, meta = http_json(meta_url)
    if code == 200 and isinstance(meta, dict):
        ok(f"resource metadata: {meta.get('authorization_servers')}")
        servers = meta.get("authorization_servers") or []
        if any(domain in s for s in servers):
            ok("ORDS points at your Auth0 domain")
        else:
            fail(f"ORDS authorization_servers {servers} missing {domain}")
            errors += 1
    else:
        fail(f"ORDS metadata HTTP {code} — is docker compose up?")
        errors += 1

    # --- MCP calls ---
    section("5. ORDS MCP calls with Bearer token")
    code, _ = http_json(ords_mcp)
    if code == 401:
        ok("unauthenticated /mcp → 401")
    else:
        warn(f"unauthenticated /mcp → HTTP {code} (expected 401)")

    def mcp_call(method: str, params: dict | None = None, id_: int = 1) -> tuple[int, dict | str]:
        return http_json(
            ords_mcp,
            method="POST",
            data={"jsonrpc": "2.0", "id": id_, "method": method, "params": params or {}},
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/json, text/event-stream",
            },
        )

    code, init = mcp_call(
        "initialize",
        {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "test-auth0", "version": "1.0"},
        },
        1,
    )
    if code == 200 and isinstance(init, dict) and init.get("result"):
        ok(f"initialize → {init['result'].get('serverInfo')}")
    elif code == 401:
        fail("initialize → 401 (JWT rejected by ORDS)")
        errors += 1
        print(f"  body: {init!r}"[:300])
        warn(
            "Check: docker logs ords | grep -i 'JWT\\|Role Claim' "
            "— often Missing Role Claim if token has no roles2:[]"
        )
    elif code == 403:
        fail("initialize → 403")
        errors += 1
    else:
        warn(f"initialize HTTP {code}: {str(init)[:240]}")

    code, tools = mcp_call("tools/list", {}, 2)
    if code == 200 and isinstance(tools, dict) and tools.get("result"):
        names = [t.get("name") for t in tools["result"].get("tools", [])]
        ok(f"tools/list → {names}")
    else:
        warn(f"tools/list HTTP {code}: {str(tools)[:200]}")

    code, dbl = mcp_call(
        "tools/call",
        {"name": "database_list", "arguments": {"show_details": True}},
        3,
    )
    if code == 200 and isinstance(dbl, dict):
        result = dbl.get("result") or {}
        if result.get("isError"):
            warn(f"database_list error: {result}")
        else:
            sc = result.get("structuredContent") or {}
            dbs = sc.get("databases") or []
            if not dbs and result.get("content"):
                # parse text blob
                try:
                    text = result["content"][0].get("text", "{}")
                    dbs = json.loads(text).get("databases", [])
                except Exception:  # noqa: BLE001
                    dbs = []
            ok(f"database_list → {[d.get('name') for d in dbs]}")
            if not dbs:
                warn("empty database list — token missing POOL.HR/POOL.FIN roles (or wrong claim pointer)")
            expected = set()
            if isinstance(roles, list):
                if "POOL.HR" in roles:
                    expected.add("mcp-hr")
                if "POOL.FIN" in roles:
                    expected.add("mcp-fin")
            got = {d.get("name") for d in dbs}
            if expected and got != expected:
                warn(f"expected pools {expected} from roles, got {got}")
            elif expected and got == expected:
                ok("pools match roles")
    elif code == 401:
        fail("database_list → 401")
        errors += 1
    elif code == 403:
        warn("database_list → 403 (authorized to MCP but not to any pool?)")
    else:
        warn(f"database_list HTTP {code}: {str(dbl)[:240]}")

    section("Summary")
    if errors == 0:
        print("  Critical checks passed.")
        if not roles:
            print("  Next: create users + POOL.* roles + Triggers + setCustomClaim('roles2', ...),")
            print("        then re-run with AUTH0_TEST_USERNAME / AUTH0_TEST_PASSWORD.")
        return 0
    print(f"  {errors} critical failure(s). See FAIL lines above.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
