# Lab image — for local docker-compose only.
# Production builds: deploy/docker/Dockerfile + deploy/docker/build.sh
#
# Prefer production image for anything beyond laptop lab:
#   ./deploy/docker/build.sh

ARG TEMURIN_IMAGE=eclipse-temurin@sha256:eebd356ad7358b7094758e5787a6726f332917cfd56feab6457c56dab895cdbf
FROM ${TEMURIN_IMAGE}

LABEL org.opencontainers.image.title="yourlabs/ords-lab" \
      org.opencontainers.image.description="Lab ORDS MCP (use deploy/docker for production)"

ARG ORDS_VERSION=26.2.2.204.1619
ARG ORDS_ZIP_URL=https://download.oracle.com/otn_software/java/ords/ords-26.2.2.204.1619.zip
ARG ORDS_SHA256=f4894611e24ab34baa3bff5a6ac4e12d7df2f55bc58aa6c3b16dacd47f10a44e

ENV ORDS_HOME=/opt/oracle/ords \
    ORDS_CONFIG=/etc/ords/config \
    ORDS_POOLS_DIR=/etc/ords/pools.d \
    JAVA_OPTS="-Djava.security.egd=file:/dev/./urandom" \
    PATH="/opt/oracle/ords/bin:${PATH}"

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
         ca-certificates curl unzip netcat-openbsd \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 54321 oracle \
    && useradd --uid 54321 --gid oracle --home-dir /home/oracle --create-home \
         --shell /bin/bash oracle \
    && mkdir -p "${ORDS_HOME}" "${ORDS_CONFIG}" "${ORDS_POOLS_DIR}" /opt/oracle/scripts \
    && curl -fsSL -o /tmp/ords.zip "${ORDS_ZIP_URL}" \
    && echo "${ORDS_SHA256}  /tmp/ords.zip" | sha256sum -c - \
    && unzip -q /tmp/ords.zip -d "${ORDS_HOME}" \
    && rm -f /tmp/ords.zip \
    && chmod +x "${ORDS_HOME}/bin/ords" \
    && chown -R oracle:oracle /opt/oracle /etc/ords /home/oracle \
    && "${ORDS_HOME}/bin/ords" --version

# Lab uses production entrypoint with ORDS_AUTO_INIT=true from compose
COPY --chown=oracle:oracle deploy/docker/entrypoint.sh /opt/oracle/scripts/entrypoint.sh
COPY --chown=oracle:oracle deploy/docker/init-config.sh /opt/oracle/scripts/init-config.sh
COPY --chown=oracle:oracle deploy/docker/lab-entrypoint-wrapper.sh /opt/oracle/scripts/lab-entrypoint-wrapper.sh
COPY --chown=oracle:oracle scripts/lab-bootstrap-pools.sh /opt/oracle/scripts/lab-bootstrap-pools.sh
RUN chmod 0555 /opt/oracle/scripts/*.sh

USER oracle
WORKDIR /home/oracle

EXPOSE 8080 8443
VOLUME ["${ORDS_CONFIG}"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=10 \
  CMD curl -sS -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/mcp \
    | grep -Eq '^(200|401|403)$' || exit 1

ENTRYPOINT ["/opt/oracle/scripts/lab-entrypoint-wrapper.sh"]
CMD ["serve"]
