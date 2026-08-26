# Production ORDS MCP image — pinned base + checksummed ORDS / Instant Client / SQLcl zips.
# Build: see deploy/docker/build.sh or .github/workflows/ci.yml
#
# syntax=docker/dockerfile:1.6

ARG TEMURIN_IMAGE=eclipse-temurin@sha256:eebd356ad7358b7094758e5787a6726f332917cfd56feab6457c56dab895cdbf
FROM ${TEMURIN_IMAGE}

ARG ORDS_VERSION=26.2.2.204.1619
ARG ORDS_ZIP_URL=https://download.oracle.com/otn_software/java/ords/ords-26.2.2.204.1619.zip
ARG ORDS_SHA256=f4894611e24ab34baa3bff5a6ac4e12d7df2f55bc58aa6c3b16dacd47f10a44e
ARG IC_VERSION=23.26.3.0.0
ARG IC_DIR=instantclient_23_26
ARG IC_BASICLITE_URL=https://download.oracle.com/otn_software/linux/instantclient/2326300/instantclient-basiclite-linux.x64-23.26.3.0.0.zip
ARG IC_BASICLITE_SHA256=88c2b59d473f0d34615556dbee51cb90cce61a9104b4c1c772d13c344fba19c9
ARG IC_SQLPLUS_URL=https://download.oracle.com/otn_software/linux/instantclient/2326300/instantclient-sqlplus-linux.x64-23.26.3.0.0.zip
ARG IC_SQLPLUS_SHA256=6570d7939856767cdbb549b51e1423d6a5f53143c57c30c015669706f65a632a
ARG SQLCL_VERSION=26.2.1.222.1617
ARG SQLCL_URL=https://download.oracle.com/otn_software/java/sqldeveloper/sqlcl-26.2.1.222.1617.zip
ARG SQLCL_SHA256=ff810954993927836b3049eb7c6404d3da72eb539b2a3f725504f72973672fa3
ARG ORACLEDB_VERSION=4.0.2
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
      com.yourlabs.instantclient.version="${IC_VERSION}" \
      com.yourlabs.sqlcl.version="${SQLCL_VERSION}" \
      com.yourlabs.oracledb.version="${ORACLEDB_VERSION}" \
      com.yourlabs.component="ords-mcp"

ENV ORDS_HOME=/opt/oracle/ords \
    ORDS_CONFIG=/etc/ords/config \
    ORDS_POOLS_DIR=/etc/ords/pools.d \
    SQLCL_HOME=/opt/oracle/sqlcl \
    ORACLE_CLIENT_HOME=/opt/oracle/instantclient \
    LD_LIBRARY_PATH=/opt/oracle/instantclient \
    JAVA_OPTS="-Djava.security.egd=file:/dev/./urandom -XX:+UseContainerSupport" \
    PATH="/opt/oracle/ords/bin:/opt/oracle/instantclient:/opt/oracle/sqlcl/bin:${PATH}" \
    LANG=C.UTF-8

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# OS deps: curl/ca-certs for JWKS + health; libaio/libnsl for sqlplus;
# python3 + pip for oracledb (thin mode does not require Instant Client).
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
         ca-certificates \
         curl \
         unzip \
         libaio1 \
         libnsl2 \
         python3 \
         python3-pip \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 54321 oracle \
    && useradd --uid 54321 --gid oracle --home-dir /home/oracle --create-home \
         --shell /usr/sbin/nologin oracle \
    && mkdir -p "${ORDS_HOME}" "${ORDS_CONFIG}" "${ORDS_POOLS_DIR}" \
         /opt/oracle/scripts /tmp/stage \
    && curl -fsSL -o /tmp/stage/ords.zip "${ORDS_ZIP_URL}" \
    && curl -fsSL -o /tmp/stage/instantclient-basiclite.zip "${IC_BASICLITE_URL}" \
    && curl -fsSL -o /tmp/stage/instantclient-sqlplus.zip "${IC_SQLPLUS_URL}" \
    && curl -fsSL -o /tmp/stage/sqlcl.zip "${SQLCL_URL}" \
    && printf '%s  %s\n' \
         "${ORDS_SHA256}" /tmp/stage/ords.zip \
         "${IC_BASICLITE_SHA256}" /tmp/stage/instantclient-basiclite.zip \
         "${IC_SQLPLUS_SHA256}" /tmp/stage/instantclient-sqlplus.zip \
         "${SQLCL_SHA256}" /tmp/stage/sqlcl.zip \
       | sha256sum -c - \
    && unzip -qo /tmp/stage/ords.zip -d "${ORDS_HOME}" \
    && unzip -qo /tmp/stage/instantclient-basiclite.zip -d /opt/oracle \
    && unzip -qo /tmp/stage/instantclient-sqlplus.zip -d /opt/oracle \
    && unzip -qo /tmp/stage/sqlcl.zip -d /opt/oracle \
    && rm -rf /tmp/stage \
    && ln -sfn "/opt/oracle/${IC_DIR}" /opt/oracle/instantclient \
    && ln -sfn sql /opt/oracle/sqlcl/bin/sqlcl \
    && echo /opt/oracle/instantclient > /etc/ld.so.conf.d/oracle-instantclient.conf \
    && ldconfig \
    && chmod +x "${ORDS_HOME}/bin/ords" /opt/oracle/sqlcl/bin/sql \
    && python3 -m pip install --no-cache-dir "oracledb==${ORACLEDB_VERSION}" \
    && chown -R oracle:oracle /opt/oracle /etc/ords /home/oracle \
    && "${ORDS_HOME}/bin/ords" --version \
    && sqlplus -V \
    && sql -V \
    && python3 -c "import oracledb; print('oracledb', oracledb.__version__)"

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
