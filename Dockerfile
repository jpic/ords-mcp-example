# Oracle REST Data Services — latest (MCP-capable standalone, 26.2+)
FROM eclipse-temurin:21-jre-jammy

LABEL org.opencontainers.image.title="Oracle ORDS MCP lab" \
      org.opencontainers.image.description="Standalone ORDS for MCP lab (Auth0 JWT)"

ARG ORDS_URL=https://download.oracle.com/otn_software/java/ords/ords-latest.zip

ENV ORDS_HOME=/opt/oracle/ords \
    ORDS_CONFIG=/etc/ords/config \
    JAVA_OPTS="-Djava.security.egd=file:/dev/./urandom" \
    PATH="/opt/oracle/ords/bin:${PATH}"

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl unzip ca-certificates netcat-openbsd \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -g 54321 oracle \
    && useradd -u 54321 -g oracle -d /home/oracle -m -s /bin/bash oracle \
    && mkdir -p "${ORDS_HOME}" "${ORDS_CONFIG}" /opt/oracle/scripts \
    && curl -fsSL -o /tmp/ords.zip "${ORDS_URL}" \
    && unzip -q /tmp/ords.zip -d "${ORDS_HOME}" \
    && rm -f /tmp/ords.zip \
    && chmod +x "${ORDS_HOME}/bin/ords" \
    && chown -R oracle:oracle /opt/oracle /etc/ords /home/oracle \
    && "${ORDS_HOME}/bin/ords" --version

COPY --chown=oracle:oracle entrypoint.sh /opt/oracle/scripts/entrypoint.sh
COPY --chown=oracle:oracle scripts/configure-mcp.sh /opt/oracle/scripts/configure-mcp.sh
RUN chmod +x /opt/oracle/scripts/entrypoint.sh /opt/oracle/scripts/configure-mcp.sh

USER oracle
WORKDIR /home/oracle

EXPOSE 8080 8443
VOLUME ["${ORDS_CONFIG}"]

HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=10 \
  CMD curl -fsS "http://127.0.0.1:8080/" >/dev/null || curl -fsS "http://127.0.0.1:8080/mcp" >/dev/null || exit 1

ENTRYPOINT ["/opt/oracle/scripts/entrypoint.sh"]
CMD ["serve"]
