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

docker build \
  -f "${ROOT}/deploy/docker/Dockerfile" \
  --build-arg "TEMURIN_IMAGE=${TEMURIN_IMAGE}" \
  --build-arg "ORDS_VERSION=${ORDS_VERSION}" \
  --build-arg "ORDS_ZIP_URL=${ORDS_ZIP_URL}" \
  --build-arg "ORDS_SHA256=${ORDS_SHA256}" \
  --build-arg "GIT_SHA=${GIT_SHA}" \
  --build-arg "BUILD_DATE=${BUILD_DATE}" \
  -t "${FULL_IMAGE}" \
  -t "${IMAGE_NAME}:${IMAGE_TAG_PREFIX}-${ORDS_VERSION}" \
  "${ROOT}/deploy/docker"

echo "Built ${FULL_IMAGE}"
docker run --rm --entrypoint /opt/oracle/ords/bin/ords "${FULL_IMAGE}" --version 2>&1 | tail -8
echo "${FULL_IMAGE}" >"${ROOT}/deploy/docker/.last-image"
