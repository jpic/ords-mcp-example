#!/usr/bin/env bash
# Build production yourlabs/ords image with pinned inputs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/deploy/docker/versions.env"

GIT_SHA="${GIT_SHA:-$(git -C "${ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)}"
BUILD_DATE="${BUILD_DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
REGISTRY="${REGISTRY:-}"
IMAGE_NAME="${IMAGE_NAME:-yourlabs/ords}"
TAG="${TAG:-${IMAGE_TAG_PREFIX}-${ORDS_VERSION}-${GIT_SHA}}"

if [[ -n "${REGISTRY}" ]]; then
  FULL_IMAGE="${REGISTRY%/}/${IMAGE_NAME}:${TAG}"
else
  FULL_IMAGE="${IMAGE_NAME}:${TAG}"
fi

echo "Building ${FULL_IMAGE}"
echo "  TEMURIN_IMAGE=${TEMURIN_IMAGE}"
echo "  ORDS_VERSION=${ORDS_VERSION}"
echo "  ORDS_SHA256=${ORDS_SHA256}"
echo "  IC_VERSION=${IC_VERSION}"
echo "  SQLCL_VERSION=${SQLCL_VERSION}"
echo "  ORACLEDB_VERSION=${ORACLEDB_VERSION}"

docker build \
  -f "${ROOT}/deploy/docker/Dockerfile" \
  --build-arg "TEMURIN_IMAGE=${TEMURIN_IMAGE}" \
  --build-arg "ORDS_VERSION=${ORDS_VERSION}" \
  --build-arg "ORDS_ZIP_URL=${ORDS_ZIP_URL}" \
  --build-arg "ORDS_SHA256=${ORDS_SHA256}" \
  --build-arg "IC_VERSION=${IC_VERSION}" \
  --build-arg "IC_DIR=${IC_DIR}" \
  --build-arg "IC_BASICLITE_URL=${IC_BASICLITE_URL}" \
  --build-arg "IC_BASICLITE_SHA256=${IC_BASICLITE_SHA256}" \
  --build-arg "IC_SQLPLUS_URL=${IC_SQLPLUS_URL}" \
  --build-arg "IC_SQLPLUS_SHA256=${IC_SQLPLUS_SHA256}" \
  --build-arg "SQLCL_VERSION=${SQLCL_VERSION}" \
  --build-arg "SQLCL_URL=${SQLCL_URL}" \
  --build-arg "SQLCL_SHA256=${SQLCL_SHA256}" \
  --build-arg "ORACLEDB_VERSION=${ORACLEDB_VERSION}" \
  --build-arg "GIT_SHA=${GIT_SHA}" \
  --build-arg "BUILD_DATE=${BUILD_DATE}" \
  -t "${FULL_IMAGE}" \
  -t "${IMAGE_NAME}:${IMAGE_TAG_PREFIX}-${ORDS_VERSION}" \
  "${ROOT}/deploy/docker"

echo "Built ${FULL_IMAGE}"
docker run --rm --entrypoint /opt/oracle/ords/bin/ords "${FULL_IMAGE}" --version 2>&1 | tail -8
docker run --rm --entrypoint sqlplus "${FULL_IMAGE}" -V
docker run --rm --entrypoint sql "${FULL_IMAGE}" -V
docker run --rm --entrypoint sqlcl "${FULL_IMAGE}" -V
docker run --rm --entrypoint python3 "${FULL_IMAGE}" -c "import oracledb; print('oracledb', oracledb.__version__)"
echo "${FULL_IMAGE}" >"${ROOT}/deploy/docker/.last-image"
