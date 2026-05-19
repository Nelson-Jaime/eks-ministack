#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

PROJECT="eks-ministack"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HELM_DIR="${ROOT_DIR}/helm"

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config-${PROJECT}}"

require_tool helm kubectl

# ── Label control-plane for NGINX hostPort scheduling ──────────────────────
info "Labeling control-plane node with ingress-ready=true..."
kubectl label node eks-ministack-control-plane ingress-ready=true --overwrite

# ── Helm repositories ──────────────────────────────────────────────────────
info "Adding Helm repositories..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
helm repo add jetstack      https://charts.jetstack.io                  --force-update
helm repo add argo          https://argoproj.github.io/argo-helm        --force-update
helm repo update

# ── Namespaces (idempotent) ────────────────────────────────────────────────
for ns in ingress-nginx cert-manager argocd; do
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f -
done

# ── 1. NGINX Ingress Controller ────────────────────────────────────────────
info "Installing NGINX Ingress Controller..."
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --values "${HELM_DIR}/nginx-ingress-values.yaml" \
  --timeout 3m \
  --wait

kubectl rollout status deployment/ingress-nginx-controller \
  --namespace ingress-nginx --timeout=120s
info "NGINX Ingress ready"

# ── 2. cert-manager ────────────────────────────────────────────────────────
info "Installing cert-manager..."
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --values "${HELM_DIR}/cert-manager-values.yaml" \
  --timeout 3m \
  --wait

kubectl rollout status deployment/cert-manager-webhook \
  --namespace cert-manager --timeout=120s
info "cert-manager ready"

# ── 3. ArgoCD ──────────────────────────────────────────────────────────────
info "Installing ArgoCD..."
helm upgrade --install argo-cd argo/argo-cd \
  --namespace argocd \
  --values "${HELM_DIR}/argocd-values.yaml" \
  --timeout 5m \
  --wait

kubectl rollout status deployment/argo-cd-argocd-server \
  --namespace argocd --timeout=180s
info "ArgoCD ready"

# ── ArgoCD initial admin password ─────────────────────────────────────────
wait_for "argocd-initial-admin-secret" 24 5 \
  kubectl get secret argocd-initial-admin-secret -n argocd

ARGOCD_PASSWORD=$(
  kubectl get secret argocd-initial-admin-secret \
    -n argocd -o jsonpath='{.data.password}' \
  | base64 --decode
)

info "Phase 4 complete — Helm bootstrap done"
echo ""
echo "  NGINX Ingress : http://localhost:8080   (HTTP)"
echo "                  https://localhost:8443  (HTTPS)"
echo "  ArgoCD UI     : http://localhost:9090"
echo "  ArgoCD login  : admin / ${ARGOCD_PASSWORD}"
echo ""
info "Next: make argocd-bootstrap"
