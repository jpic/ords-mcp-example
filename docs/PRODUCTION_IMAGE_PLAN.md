# Production-ready ORDS MCP image — build & audit plan

Plan and status for evolving the lab image into **yourlabs/ords** for a work registry, CI gates, and controlled runtime.

**Implemented in-repo (see [PRODUCTION.md](./PRODUCTION.md)):** Phase 1 image + Phase 2 CI skeleton + Phase 3 Helm chart.  
**Still on you at work:** registry push credentials, cosign keys/OIDC, real values/secrets, staging smoke, legal sign-off.

**Baseline today (lab):** Temurin 21 JRE, ORDS from `ords-latest.zip`, non-root `oracle`, lab `configure-mcp.sh` with default pool passwords, HTTP, Auth0-oriented env.

---

## 1. Goals and non-goals

### Goals

| Goal | Success looks like |
|------|-------------------|
| **Reproducible builds** | Same git SHA + lockfile → same image digest |
| **Supply-chain integrity** | Pinned base + pinned ORDS artifact + verified checksums |
| **No secrets in image** | No passwords, tokens, or private keys in layers |
| **Fail-closed config** | Missing required env → container exits; no lab defaults |
| **Auditable releases** | SBOM, scan reports, provenance, signed tags retained |
| **Operable runtime** | Health/readiness, metrics/logs, config separate from image |
| **Least privilege** | Non-root, drop caps, read-only rootfs where possible |
| **MCP-safe defaults** | JWT required; pool users least-privilege; audit path documented |

### Non-goals (phase 1)

- Replacing corporate IdP (Auth0/Entra) design  
- Shipping Oracle Database inside the ORDS image  
- Multi-arch until amd64 pipeline is solid  
- Full FIPS unless legal/security mandates it  

---

## 2. Target architecture

```text
                    ┌─────────────────────────────────────┐
                    │  CI (GitHub Actions / GitLab / etc.) │
                    │  1. lint / unit                      │
                    │  2. build (pinned args)              │
                    │  3. checksum verify ORDS zip         │
                    │  4. trivy/grype + policy gate        │
                    │  5. SBOM (syft) + attest             │
                    │  6. cosign sign                      │
                    │  7. push immutable tag + digest      │
                    └─────────────────┬───────────────────┘
                                      │
                                      ▼
                         Private registry (work only)
                                      │
              ┌───────────────────────┼───────────────────────┐
              ▼                       ▼                       ▼
         dev/POC                  staging                  prod
    (sandbox DBs)            (read-only replicas)     (strict NetworkPolicy)
              │                       │                       │
              └───────────────────────┴───────────────────────┘
                                      │
                         K8s: Deployment + PVC/emptyDir config
                              Secrets (DB + optional TLS)
                              Ingress TLS
                              IdP JWKS egress only + DB listeners
```

**Split concerns:**

| Layer | Contents |
|-------|----------|
| **Image** | JRE + ORDS binaries + thin entrypoint (no env-specific pools) |
| **Config** | JWT profile + pool list (generated once or via init container) |
| **Secrets** | DB passwords, TLS keys — K8s Secret / Vault, never Dockerfile |

---

## 3. Image design (production Dockerfile)

### 3.1 Layout proposal

```text
deploy/docker/
  Dockerfile.ords          # production
  Dockerfile.ords.lab      # optional: keep current lab file renamed
  entrypoint.sh            # serve-only or init|serve modes
  scripts/
    render-config.sh       # optional: generate config from templates
  versions.env             # BASE_DIGEST, ORDS_VERSION, ORDS_SHA256
  policy/
    trivy.yaml
    cosign-policy.yaml
```

Lab `Dockerfile` stays for local compose; production build uses `Dockerfile.ords`.

### 3.2 Pinning and provenance

```bash
# versions.env (committed)
ORDS_VERSION=26.2.2.204.1619
ORDS_ZIP_URL=https://download.oracle.com/otn_software/java/ords/ords-${ORDS_VERSION}.zip
ORDS_SHA256=<publish after first verified download>
TEMURIN_IMAGE=eclipse-temurin:21.0.x_x-jre-jammy@sha256:<digest>
```

Build:

```dockerfile
FROM ${TEMURIN_IMAGE}   # digest-only in CI

ARG ORDS_ZIP_URL
ARG ORDS_SHA256
# COPY ords.zip from CI artifact cache OR curl then:
RUN echo "${ORDS_SHA256}  /tmp/ords.zip" | sha256sum -c - \
 && unzip ... && rm /tmp/ords.zip
```

**Prefer:** CI downloads ORDS zip to artifact cache, verifies checksum, `COPY` into build (no egress to Oracle during `docker build` in locked networks).

### 3.3 Minimal OS surface

| Keep | Drop / avoid |
|------|----------------|
| `ca-certificates` | Full `curl` if healthcheck can use Java/wget-static |
| Shell for entrypoint | Compilers, package managers left installed |
| | `netcat` if K8s probes replace wait-for-db |

Production entrypoint should **not** require waiting for Docker DNS name `oracle` — K8s readiness handles ordering.

Suggested packages: `ca-certificates` only (+ `curl` only if needed for health until a better probe exists).

### 3.4 User and filesystem

- User `oracle` uid/gid **54321** (or org-standard non-root UID)  
- `USER oracle`  
- Optional: `gosu`/no — stay non-root only  
- Directories: `/opt/oracle/ords` (ro in K8s), `/etc/ords/config` (rw volume), `/tmp` (emptyDir)  
- K8s: `readOnlyRootFilesystem: true` + writable mounts for config/tmp  

### 3.5 Entrypoint modes

```text
ords-mcp serve              # default: assume config already present
ords-mcp init               # one-shot: write JWT + pools from env/files, exit 0
ords-mcp serve --check      # validate config, exit non-zero if incomplete
```

**Do not** rewrite pool passwords on every pod restart unless explicitly `ORDS_RECONFIGURE=true`.

### 3.6 Fail-closed configuration

Required at init (examples):

```text
ORDS_JWT_ISSUER
ORDS_JWT_AUDIENCE          # must equal public MCP URL
ORDS_JWT_JWKS_URL
ORDS_JWT_ROLE_CLAIM        # e.g. /roles2
ORDS_MCP_SCOPE             # urn:oracle:dbtools:ords:mcpserver:all
ORDS_POOLS_FILE            # path to pools.yaml (see below)
```

**Forbidden:** default passwords like `HrMcp_ChangeMe1`.

### 3.7 Pool definition (data-driven)

`pools.yaml` (ConfigMap; secrets by reference):

```yaml
pools:
  - name: mcp-fin
    description: Finance read-only
    hostname: fin-scan.db.svc
    port: 1521
    service: FIN.PDB
    username: FIN_MCP_RO
    passwordSecretKey: fin-mcp-ro-password   # from env or file
    role: POOL.FIN
    scope: urn:oracle:dbtools:ords:mcpserver:all
```

Init container renders ORDS config + `ords config secret --password-stdin`.

### 3.8 Health / readiness

| Probe | Suggestion |
|-------|------------|
| **Liveness** | TCP 8080 or HTTP path that does not require JWT (if ORDS exposes one) |
| **Readiness** | HTTP that confirms Jetty up; optional separate admin port |
| **Avoid** | `curl -f http://127.0.0.1:8080/mcp` (401 with JWT required fails `-f`) |

Options:

1. Lightweight `/` or static OK endpoint if ORDS serves it without auth  
2. Exec: `ords …` config verify + process check  
3. Sidecar / ServiceMonitor only for deep checks  

Document chosen probe in Helm chart.

### 3.9 Labels (OCI)

```text
org.opencontainers.image.title=ords-mcp
org.opencontainers.image.version=<ORDS_VERSION>
org.opencontainers.image.revision=<git sha>
org.opencontainers.image.source=<repo url>
org.opencontainers.image.licenses=...
com.example.ords.version=<ORDS_VERSION>
com.example.build.pipeline=<ci run id>
```

---

## 4. CI/CD pipeline (build + audits)

### 4.1 Pipeline stages

```text
lint ──► build ──► verify ──► scan ──► sbom ──► sign ──► push ──► deploy-dev (optional)
                │
                └── fail any HIGH/CRITICAL per policy (with exception process)
```

### 4.2 Lint / static

| Check | Tool |
|-------|------|
| Shell scripts | `shellcheck` entrypoint + configure scripts |
| Dockerfile | `hadolint` (allowlisted rules) |
| Secrets in tree | `gitleaks` / `trufflehog` on PR |
| YAML/Helm | `kubeconform` / `helm lint` when charts exist |

### 4.3 Build

| Practice | Detail |
|----------|--------|
| BuildKit | `--sbom=true --provenance=mode=max` (or syft/cosign separately) |
| No `latest` as only tag | Tags: `26.2.2-<gitsha>`, `26.2.2`, digest |
| Multi-stage if needed | Fetch/verify zip in builder; final stage copy only ORDS tree |
| Build identity | CI OIDC to registry (no long-lived robot passwords in Git) |

### 4.4 Artifact verification

| Audit | Tool / action |
|-------|----------------|
| ORDS zip checksum | `sha256sum -c` against committed `ORDS_SHA256` |
| Base image digest | Must match `versions.env` |
| Image config | `docker inspect`: User≠root, no secret env in Config.Env |
| Smoke | Run container `ords --version`; optional `init --dry-run` |

### 4.5 Vulnerability scanning

| Layer | Tool | Gate |
|-------|------|------|
| OS packages | Trivy / Grype / work-standard scanner | Fail CRITICAL; HIGH with SLA |
| Java/ORDS | Same scanner (jar/war coverage varies) | Track Oracle CPU advisories |
| Base image | Continuous re-scan of digest in registry | Rebuild on new CVE |

Policy file example (conceptual):

```yaml
# policy/trivy.yaml
severity: CRITICAL,HIGH
ignore-unfixed: false
exit-code: 1
```

**Exception process:** ticket ID + expiry in `.trivyignore` with owner.

### 4.6 SBOM and attestations

| Artifact | Tool | Storage |
|----------|------|---------|
| SBOM (SPDX or CycloneDX) | Syft | Registry attach / artifact store |
| Provenance (SLSA) | BuildKit attest / cosign attest | Registry |
| Signature | Cosign keyless (OIDC) or org key | Registry |
| Scan report | Trivy JSON | CI artifacts ≥ 90 days |

Verify before deploy:

```bash
cosign verify $IMAGE
cosign verify-attestation --type cyclonedx $IMAGE
```

### 4.7 Image promotion

| Environment | Rule |
|-------------|------|
| **dev** | Any signed image from `main` or release branch |
| **staging** | Same digest after staging smoke + security review |
| **prod** | **Digest pin only** (no floating tag); change via PR |

Never deploy `:latest` to prod.

### 4.8 Audit log (what to retain)

| Record | Retention (suggest) |
|--------|---------------------|
| CI run ID, git SHA, image digest | 2+ years |
| SBOM + scan report for that digest | 2+ years |
| Who approved prod digest | Per change-mgmt policy |
| Runtime: which digest runs in each cluster | Continuous (GitOps) |

---

## 5. Runtime (Kubernetes) — production shape

### 5.1 Workload

```yaml
# Conceptual
Deployment:
  replicas: 2+
  strategy: RollingUpdate
  pod:
    serviceAccountName: ords-mcp
    securityContext:
      runAsNonRoot: true
      runAsUser: 54321
      fsGroup: 54321
      seccompProfile: RuntimeDefault
    containers:
      - name: ords
        image: registry.example.com/ords-mcp@sha256:…
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities: { drop: ["ALL"] }
        envFrom: [secretRef, configMapRef]
        volumeMounts: [config, tmp, optional-tls]
        ports: [{ containerPort: 8080 }]
        readinessProbe: …
        livenessProbe: …
    volumes:
      - config (PVC or emptyDir filled by init)
      - tmp emptyDir
```

### 5.2 Init vs serve

```text
initContainer: ords-mcp init   # reads pools.yaml + secret files → /etc/ords/config
container:     ords-mcp serve  # no reconfigure
```

### 5.3 Network

| Direction | Allow |
|-----------|--------|
| Ingress | Ingress controller → 8080 only |
| Egress | IdP JWKS HTTPS; each DB listener; DNS; nothing else |
| Deny | Arbitrary internet, metadata IPs if applicable |

### 5.4 TLS

| Option | When |
|--------|------|
| Ingress terminates TLS | Default; ORDS HTTP in-cluster |
| ORDS HTTPS | If policy requires TLS to pod |

Audience / API Identifier / MCP public URL must stay **identical** (OpenCode `resource=`).

### 5.5 Secrets

| Secret | Source |
|--------|--------|
| Pool DB passwords | ExternalSecrets / Vault → K8s Secret → files preferred over env |
| TLS material | cert-manager |
| Never | Git, image labels, CI logs |

### 5.6 Observability & audit (MCP)

| Signal | Implementation |
|--------|----------------|
| Access logs | ORDS access log to stdout → cluster logging |
| App logs | JSON if available; ship to SIEM |
| DB session | `MODULE`/`ACTION` from ORDS MCP; monitor |
| MCP SQL log | `DBTOOLS$MCP_LOG` (pool user schema) + central audit |
| Metrics | JVM/process metrics (JMX exporter or distro standard) |
| Alerts | Probe fail, 5xx spike, egress deny, cert expiry |

### 5.7 MCP data-plane safety (beyond the image)

| Control | Requirement |
|---------|-------------|
| Pool DB user | Least privilege; prefer **read-only** |
| Target DB | Non-prod or replica for LLM use cases first |
| IdP | Roles + global MCP permission on tokens (lab lesson) |
| Client allowlist | Corporate OpenCode/IdP app; no public client secrets |

---

## 6. Security control matrix

| Control | Lab today | Production target |
|---------|-----------|-------------------|
| Non-root user | Yes | Yes + K8s securityContext |
| Pin base digest | No | Yes |
| Pin ORDS version + SHA256 | No (`latest`) | Yes |
| Default DB passwords in scripts | Yes | **Removed** |
| Secrets in image | No | No |
| Image scan gate | No | Yes |
| SBOM + sign | No | Yes |
| TLS to clients | No (HTTP lab) | Ingress/HTTPS |
| NetworkPolicy | No | Yes |
| Reconfigure every start | Yes | Init once |
| Healthcheck vs JWT 401 | Fragile | Fixed probe |
| Floating `:latest` deploy | Local only | Forbidden in prod |

---

## 7. Compliance / legal checklist

- [ ] ORDS license (Free Use Terms vs any paid packaging) reviewed by SAM  
- [ ] Base image on **approved** corporate list (Temurin vs RHEL UBI Temurin)  
- [ ] Data classification of DBs exposed via MCP  
- [ ] LLM / AI use policy for SQL generation  
- [ ] Logging retention meets audit requirements  
- [ ] DPIA / security review if personal data in MCP-accessible schemas  

---

## 8. Implementation phases

### Phase 0 — Decision (1–2 days)

- Confirm registry, CI system, scanner, signing standard  
- Confirm IdP (Auth0 vs Entra) and public MCP URL pattern  
- Confirm ORDS version to pin  

### Phase 1 — Hardened image (3–5 days)

- [ ] `versions.env` with digests + ORDS SHA256  
- [ ] `Dockerfile.ords` production  
- [ ] Entrypoint: `init` / `serve`; no default passwords  
- [ ] `pools.yaml` schema + renderer  
- [ ] Fixed health/readiness  
- [ ] Hadolint + shellcheck clean  

### Phase 2 — CI audits (3–5 days)

- [ ] PR pipeline: gitleaks, hadolint, shellcheck  
- [ ] Build + Trivy gate + Syft SBOM  
- [ ] Cosign sign + push to **dev** registry  
- [ ] Retain scan/SBOM artifacts  

### Phase 3 — K8s runtime (1–2 weeks)

- [ ] Helm/Kustomize chart  
- [ ] NetworkPolicy, PDB, HPA (optional)  
- [ ] ExternalSecrets  
- [ ] Staging deploy of **digest**  
- [ ] Smoke: OAuth login + `database_list` role isolation  

### Phase 4 — Prod readiness (1–2 weeks)

- [ ] Security review / threat model sign-off  
- [ ] Runbook + on-call alerts  
- [ ] Prod digest promotion process  
- [ ] Backup/restore of ORDS config if stateful  
- [ ] DR: rebuild from git + versions.env only  

---

## 9. Suggested CI job sketch (GitHub Actions–style)

```yaml
# Conceptual — adapt to org templates
jobs:
  build-ords-mcp:
    steps:
      - checkout
      - source deploy/docker/versions.env
      - download ORDS zip; echo "$ORDS_SHA256  ords.zip" | sha256sum -c
      - docker build \
          --build-arg TEMURIN_IMAGE \
          --build-arg ORDS_SHA256 \
          -t $REGISTRY/ords-mcp:$ORDS_VERSION-$GIT_SHA \
          -f deploy/docker/Dockerfile.ords .
      - trivy image --exit-code 1 --severity CRITICAL,HIGH $IMAGE
      - syft $IMAGE -o cyclonedx-json > sbom.cdx.json
      - cosign sign --yes $IMAGE
      - cosign attach sbom --sbom sbom.cdx.json $IMAGE
      - docker push $IMAGE
      - upload-artifact scan+sbom
```

---

## 10. Test & audit plan (quality gates)

### Build-time tests

| Test | Pass criteria |
|------|----------------|
| `ords --version` in image | Matches `ORDS_VERSION` |
| `USER` in inspect | non-root |
| No `PASSWORD=` in image Config.Env | clean |
| Checksum of zip | matches commit |
| Trivy | policy pass |

### Integration tests (staging)

| Test | Pass criteria |
|------|----------------|
| Unauthenticated `/mcp` | 401 + WWW-Authenticate |
| Token with role A | `database_list` only pool A |
| Token with role B | only pool B |
| Token missing MCP permission | 403 |
| Token missing roles claim | 401 |
| JWKS unreachable simulation | fail closed (no open MCP) |

### Periodic audits

| Cadence | Activity |
|---------|----------|
| Weekly | Re-scan prod digest; ticket if new CRITICAL |
| Per Oracle CPU | Evaluate ORDS upgrade; bump versions.env |
| Quarterly | Access review: who can deploy digests; IdP app owners |
| Per incident | Verify audit logs for MCP SQL |

---

## 11. Risks and mitigations

| Risk | Mitigation |
|------|------------|
| ORDS zip URL / license change | Internal artifact mirror |
| Scanner false positives | Exception registry with expiry |
| LLM destructive SQL | Read-only DB user; no DDL; optional SQL allowlist later |
| Token claim drift (IdP) | Contract tests on JWT shape in CI against mock JWKS |
| Config drift across envs | GitOps only; no kubectl edit |
| Lab image accidentally promoted | Different image name (`ords-mcp` vs `local/ords`); deny `:latest` in prod admission |

---

## 12. Deliverables checklist

- [ ] `deploy/docker/Dockerfile.ords`  
- [ ] `deploy/docker/versions.env`  
- [ ] Production entrypoint (`init`/`serve`)  
- [ ] `pools.schema.json` + example `pools.yaml`  
- [ ] CI workflow with scan + SBOM + sign  
- [ ] Helm chart + NetworkPolicy  
- [ ] Runbook: upgrade ORDS, rotate DB password, rotate IdP  
- [ ] Security review record  
- [ ] First staging digest deployed and smoke-tested  

---

## 13. Relation to current lab repo

| Lab artifact | Production fate |
|--------------|-----------------|
| `Dockerfile` | Keep as lab; or rename `Dockerfile.lab` |
| `configure-mcp.sh` | Replace with fail-closed, multi-pool renderer |
| `docker-compose.yml` | Dev-only; not prod manifests |
| `docs/AUTH0_*` / OpenCode | Reuse as IdP/client runbooks |
| `local/ords:latest` | Do not promote |

---

## 14. Recommended immediate next implementation slice

If implementing after this plan, do **Phase 1 only** first:

1. Pin Temurin digest + ORDS version/SHA256  
2. Strip default passwords; require secrets  
3. Split `init` / `serve`  
4. Add Trivy + hadolint in CI  
5. Document image tags and “not for prod DB” until Phase 3  

---

## Summary

A production ORDS MCP image is **not** “scan the lab image and push.” It is:

1. **Pinned, checksummed, minimal, non-root image**  
2. **CI audits:** lint, CVE gate, SBOM, signature, provenance  
3. **Runtime:** secrets outside image, TLS, NetworkPolicy, init-once config  
4. **MCP-specific:** JWT contract, least-privilege pools, SQL/session audit  
5. **Process:** digest promotion, retention of build evidence, legal sign-off  

The current lab image is a valid **prototype** of (1)’s shape; production needs the full audit and runtime envelope above before work-wide use.
