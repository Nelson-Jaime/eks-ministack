#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

PROJECT="eks-ministack"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKEND_IMAGE="localhost:4566/${PROJECT}/backend"
FRONTEND_IMAGE="localhost:4566/${PROJECT}/frontend"

export DOCKER_HOST="${DOCKER_HOST:-unix:///run/user/$(id -u)/docker.sock}"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config-${PROJECT}}"

require_tool kind kubectl docker

# ── iptables preflight ──────────────────────────────────────────────────────
# kind inter-pod routing breaks with iptables-nft on some Ubuntu ARM64 systems
if command -v update-alternatives &>/dev/null; then
  current_ipt="$(update-alternatives --query iptables 2>/dev/null | awk '/Value:/{print $2}')"
  if [[ "${current_ipt}" == *"nft"* ]]; then
    warn "iptables-nft detected; attempting switch to legacy for kind compatibility"
    sudo update-alternatives --set iptables /usr/sbin/iptables-legacy 2>/dev/null \
      || warn "Could not switch iptables (no sudo terminal) — proceeding anyway"
  fi
fi

# ── Create cluster ──────────────────────────────────────────────────────────
if DOCKER_HOST="${DOCKER_HOST}" kind get clusters 2>/dev/null | grep -q "^${PROJECT}$"; then
  info "Cluster '${PROJECT}' already exists — skipping creation"
else
  info "Creating kind cluster: ${PROJECT}"
  mkdir -p "$(dirname "${KUBECONFIG}")"
  DOCKER_HOST="${DOCKER_HOST}" kind create cluster \
    --name "${PROJECT}" \
    --config "${ROOT_DIR}/kind-config.yaml" \
    --kubeconfig "${KUBECONFIG}"
  info "Cluster created"
fi

# ── Wait for nodes ──────────────────────────────────────────────────────────
info "Waiting for all nodes to be Ready (timeout 5m)..."
kubectl wait --for=condition=Ready node --all --timeout=300s
kubectl get nodes -o wide

# ── Load images ─────────────────────────────────────────────────────────────
info "Loading backend image into kind nodes..."
DOCKER_HOST="${DOCKER_HOST}" kind load docker-image "${BACKEND_IMAGE}:latest" --name "${PROJECT}"

info "Loading frontend image into kind nodes..."
DOCKER_HOST="${DOCKER_HOST}" kind load docker-image "${FRONTEND_IMAGE}:latest" --name "${PROJECT}"

info "Phase 3 complete — 5-node cluster ready, images loaded"
info "Next: make helm-bootstrap"
