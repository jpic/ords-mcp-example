# Production ORDS MCP image — pinned base + checksummed ORDS zip.
# Build: see deploy/docker/build.sh or .github/workflows/ci.yml
#
# syntax=docker/dockerfile:1.6

ARG TEMURIN_IMAGE=eclipse-temurin@sha256:eebd356ad7358b7094758e5787a6726f332917cfd56feab6457c56dab895cdbf
FROM ${TEMURIN_IMAGE}

ARG ORDS_VERSION=26.2.2.204.1619
ARG ORDS_ZIP_URL=https://download.oracle.com/otn_software/java/ords/ords-26.2.2.204.1619.zip
ARG ORDS_SHA256=f4894611e24ab34baa3bff5a6ac4e12d7df2f55bc58aa6c3b16dacd47f10a44e
ARG GIT_SHA=unknown
ARG BUILD_DATE=unknown

LABEL org.opencontainers.image.title="yourlabs/ords" \
      org.opencontainers.image.description="Production Oracle REST Data Services (standalone MCP)" \
      org.opencontainers.image.version="${ORDS_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.source="https://github.com/yourlabs/ords" \
      org.opencontainers.image.vendor="yourlabs" \
      com.yourlabs.ords.version="${ORDS_VERSION}" \
      com.yourlabs.component="ords-mcp"

ENV ORDS_HOME=/opt/oracle/ords \
    ORDS_CONFIG=/etc/ords/config \
    ORDS_POOLS_DIR=/etc/ords/pools.d \
    JAVA_OPTS="-Djava.security.egd=file:/dev/./urandom -XX:+UseContainerSupport" \
    PATH="/opt/oracle/ords/bin:${PATH}" \
    LANG=C.UTF-8

# Minimal tools: curl for optional health; ca-certs for JWKS TLS
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
         ca-certificates \
         curl \
         unzip \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 54321 oracle \
    && useradd --uid 54321 --gid oracle --home-dir /home/oracle --create-home \
         --shell /usr/sbin/nologin oracle \
    && mkdir -p "${ORDS_HOME}" "${ORDS_CONFIG}" "${ORDS_POOLS_DIR}" \
         /opt/oracle/scripts /tmp/ords \
    && curl -fsSL -o /tmp/ords/ords.zip "${ORDS_ZIP_URL}" \
    && echo "${ORDS_SHA256}  /tmp/ords/ords.zip" | sha256sum -c - \
    && unzip -q /tmp/ords/ords.zip -d "${ORDS_HOME}" \
    && rm -rf /tmp/ords \
    && chmod +x "${ORDS_HOME}/bin/ords" \
    && chown -R oracle:oracle /opt/oracle /etc/ords /home/oracle \
    && "${ORDS_HOME}/bin/ords" --version

COPY --chown=oracle:oracle entrypoint.sh /opt/oracle/scripts/entrypoint.sh
COPY --chown=oracle:oracle init-config.sh /opt/oracle/scripts/init-config.sh
RUN chmod 0555 /opt/oracle/scripts/entrypoint.sh /opt/oracle/scripts/init-config.sh

USER oracle
WORKDIR /home/oracle

EXPOSE 8080

# Config and optional pool defs are runtime mounts (not baked in)
VOLUME ["/etc/ords/config"]

# /mcp requires JWT (401); treat 401 as "process up" for liveness-style checks
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=5 \
  CMD curl -sS -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/mcp \
    | grep -Eq '^(200|401|403)$' || exit 1

ENTRYPOINT ["/opt/oracle/scripts/entrypoint.sh"]
CMD ["serve"]
