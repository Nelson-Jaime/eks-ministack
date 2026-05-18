#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

APP_VERSION="${1:-dev}"
BACKEND_IMAGE="localhost:4566/eks-ministack/backend"
FRONTEND_IMAGE="localhost:4566/eks-ministack/frontend"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

require_tool docker trivy

# ── Backend ────────────────────────────────────────────────────────────────
info "Building backend image: ${BACKEND_IMAGE}:${APP_VERSION}"
docker build \
  --label "git.sha=$(git -C "${ROOT_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)" \
  --label "build.version=${APP_VERSION}" \
  -t "${BACKEND_IMAGE}:${APP_VERSION}" \
  -t "${BACKEND_IMAGE}:latest" \
  "${ROOT_DIR}/app/backend/"

info "Scanning backend with Trivy..."
trivy image \
  --severity HIGH,CRITICAL \
  --exit-code 0 \
  --no-progress \
  "${BACKEND_IMAGE}:${APP_VERSION}"

# ── Frontend ───────────────────────────────────────────────────────────────
info "Building frontend image: ${FRONTEND_IMAGE}:${APP_VERSION}"
docker build \
  --label "git.sha=$(git -C "${ROOT_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)" \
  --label "build.version=${APP_VERSION}" \
  -t "${FRONTEND_IMAGE}:${APP_VERSION}" \
  -t "${FRONTEND_IMAGE}:latest" \
  "${ROOT_DIR}/app/frontend/"

info "Scanning frontend with Trivy..."
trivy image \
  --severity HIGH,CRITICAL \
  --exit-code 0 \
  --no-progress \
  "${FRONTEND_IMAGE}:${APP_VERSION}"

info "Build complete:"
docker images | grep "localhost:4566/eks-ministack" | grep -v "<none>"
