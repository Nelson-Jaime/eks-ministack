#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

PROJECT="eks-ministack"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config-${PROJECT}}"

PASS=0
FAIL=0

check() {
  local description="$1"
  shift
  if "$@" &>/dev/null; then
    info  "PASS  ${description}"
    PASS=$((PASS + 1))
  else
    error "FAIL  ${description}"
    FAIL=$((FAIL + 1))
  fi
}

echo ""
info "=== Layer 1: Cluster nodes ==="
check "5 nodes present" bash -c \
  '[[ "$(kubectl get nodes --no-headers | wc -l)" -eq 5 ]]'
check "All nodes Ready" bash -c \
  '[[ "$(kubectl get nodes --no-headers | grep -c " Ready ")" -eq 5 ]]'
check "AZ labels on workers" bash -c \
  '[[ "$(kubectl get nodes --show-labels | grep -c topology.kubernetes.io/zone)" -ge 4 ]]'

echo ""
info "=== Layer 2: Infrastructure pods ==="
check "NGINX controller Running" bash -c \
  'kubectl get pods -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx \
   --no-headers | grep -q Running'
check "cert-manager Running" bash -c \
  'kubectl get pods -n cert-manager -l app=cert-manager \
   --no-headers | grep -q Running'
check "ArgoCD server Running" bash -c \
  'kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server \
   --no-headers | grep -q Running'

echo ""
info "=== Layer 3: NGINX reachable ==="
check "NGINX responds on :8080" bash -c \
  'curl -sf --max-time 5 http://localhost:8080 -o /dev/null -w "%{http_code}" \
   | grep -qE "^(200|404)$"'

echo ""
info "=== Layer 4: ArgoCD apps ==="
check "ArgoCD applications exist" bash -c \
  '[[ "$(kubectl get applications -n argocd --no-headers 2>/dev/null | wc -l)" -gt 0 ]]'
check "All apps Synced" bash -c \
  '[[ "$(kubectl get applications -n argocd \
        -o jsonpath='"'"'{range .items[*]}{.status.sync.status}{"\n"}{end}'"'"' 2>/dev/null \
        | grep -cv "^Synced$" || true)" -eq 0 ]]'
check "ArgoCD UI responds on :9090" bash -c \
  'curl -sf --max-time 5 http://localhost:9090 -o /dev/null'

echo ""
info "=== Layer 5: Application ==="
check "backend pods Running" bash -c \
  'kubectl get pods -n apps -l app=backend --no-headers | grep -q Running'
check "frontend pods Running" bash -c \
  'kubectl get pods -n apps -l app=frontend --no-headers | grep -q Running'
check "app /health returns 200" bash -c \
  'curl -sf --max-time 5 -H "Host: app.eks-ministack.local" \
   http://localhost:8080/health -o /dev/null'
check "app /api/ proxies to backend" bash -c \
  'curl -sf --max-time 5 -H "Host: app.eks-ministack.local" \
   http://localhost:8080/api/health | grep -q "ok"'

echo ""
info "=== Layer 6: Observability ==="
check "Prometheus pods Running" bash -c \
  'kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus \
   --no-headers 2>/dev/null | grep -q Running'
check "Grafana pod Running" bash -c \
  'kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana \
   --no-headers 2>/dev/null | grep -q Running'
check "Grafana responds on :8080" bash -c \
  'curl -sf --max-time 5 -H "Host: grafana.eks-ministack.local" \
   http://localhost:8080/api/health | grep -q "ok"'

echo ""
if [[ $FAIL -eq 0 ]]; then
  info "All ${PASS} checks passed"
else
  warn "${PASS} passed, ${FAIL} failed"
  exit 1
fi
