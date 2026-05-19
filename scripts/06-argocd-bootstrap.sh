#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

PROJECT="eks-ministack"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config-${PROJECT}}"

require_tool kubectl

# ── metrics-server (required for HPA) ─────────────────────────────────────
info "Installing metrics-server..."
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# kind requires --kubelet-insecure-tls (no valid certs on kind nodes)
kubectl patch deployment metrics-server -n kube-system \
  --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' \
  2>/dev/null || true   # idempotent — patch is a no-op if already present

# ── Apply ArgoCD project + App-of-Apps ────────────────────────────────────
info "Applying ArgoCD AppProject..."
kubectl apply -f "${ROOT_DIR}/k8s/argocd/project.yaml"

info "Applying App-of-Apps root Application..."
kubectl apply -f "${ROOT_DIR}/k8s/argocd/apps-app.yaml"

# ── Wait for all apps to sync ─────────────────────────────────────────────
info "Waiting for all ArgoCD applications to sync (timeout 15m)..."
max_attempts=60   # 60 × 15s = 15 minutes
attempt=0
until \
  [[ "$(kubectl get applications -n argocd --no-headers 2>/dev/null | wc -l)" -gt 0 ]] && \
  [[ "$(kubectl get applications -n argocd \
        -o jsonpath='{range .items[*]}{.status.sync.status}{"\n"}{end}' 2>/dev/null \
        | grep -cv '^Synced$' || true)" -eq 0 ]]; do
  attempt=$((attempt + 1))
  if [[ $attempt -ge $max_attempts ]]; then
    error "Timed out — check ArgoCD UI at http://localhost:9090"
    kubectl get applications -n argocd
    exit 1
  fi
  echo -n "."
  sleep 15
done
echo ""

info "Phase 5 complete — all apps synced"
echo ""
kubectl get applications -n argocd
echo ""
echo "  App             : http://app.eks-ministack.local (via http://localhost:8080)"
echo "  ArgoCD UI       : http://localhost:9090"
echo "  Grafana         : http://grafana.eks-ministack.local (via http://localhost:8080)"
echo "  Grafana login   : admin / admin123"
echo ""
echo "  Add to /etc/hosts if not present:"
echo "    127.0.0.1  app.eks-ministack.local"
echo "    127.0.0.1  argocd.eks-ministack.local"
echo "    127.0.0.1  grafana.eks-ministack.local"
echo ""
info "Next: make verify"
