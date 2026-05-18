#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

INSTALL_DIR="${HOME}/.local/bin"
mkdir -p "${INSTALL_DIR}"

if [[ ":${PATH}:" != *":${INSTALL_DIR}:"* ]]; then
  warn "${INSTALL_DIR} is not in PATH — add it to ~/.zshrc or ~/.bashrc"
  export PATH="${INSTALL_DIR}:${PATH}"
fi

install_if_missing() {
  local name="$1"
  local check_cmd="${2:-$1}"
  if command -v "${check_cmd}" &>/dev/null; then
    info "${name} already installed"
    return 0
  fi
  return 1
}

# ── All sudo work upfront (one auth prompt, before long installs) ──────────
info "Running sudo preflight (apt packages + sysctl)..."
PKGS=()
command -v passt &>/dev/null       || PKGS+=(passt)
python3 -m venv --help &>/dev/null || PKGS+=(python3-venv)

if [[ ${#PKGS[@]} -gt 0 ]]; then
  sudo apt-get install -y -q "${PKGS[@]}"
fi

CURRENT_WATCHES=$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo 0)
if [[ "${CURRENT_WATCHES}" -lt 524288 ]]; then
  warn "inotify limits too low (${CURRENT_WATCHES}). Run these once to fix:"
  echo "  sudo tee /etc/sysctl.d/99-kind.conf > /dev/null <<'EOF'"
  echo "  fs.inotify.max_user_watches = 524288"
  echo "  fs.inotify.max_user_instances = 512"
  echo "  EOF"
  echo "  sudo sysctl --system"
else
  info "inotify limits already sufficient (${CURRENT_WATCHES})"
fi

# ── Terraform ──────────────────────────────────────────────────────────────
TF_VERSION="1.15.3"
if ! install_if_missing "Terraform ${TF_VERSION}" terraform; then
  info "Installing Terraform ${TF_VERSION} (ARM64)..."
  TMP=$(mktemp -d)
  curl -fsSL "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_arm64.zip" \
    -o "${TMP}/terraform.zip"
  unzip -q "${TMP}/terraform.zip" -d "${TMP}"
  install "${TMP}/terraform" "${INSTALL_DIR}/terraform"
  rm -rf "${TMP}"
  info "Terraform installed"
fi

# ── kubectl ────────────────────────────────────────────────────────────────
KUBECTL_VERSION="v1.36.1"
if ! install_if_missing "kubectl ${KUBECTL_VERSION}" kubectl; then
  info "Installing kubectl ${KUBECTL_VERSION} (ARM64)..."
  curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/arm64/kubectl" \
    -o "${INSTALL_DIR}/kubectl"
  chmod +x "${INSTALL_DIR}/kubectl"
  info "kubectl installed"
fi

# ── Helm ───────────────────────────────────────────────────────────────────
HELM_VERSION="v3.17.3"
if ! install_if_missing "Helm ${HELM_VERSION}" helm; then
  info "Installing Helm ${HELM_VERSION} (ARM64)..."
  TMP=$(mktemp -d)
  curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-arm64.tar.gz" \
    -o "${TMP}/helm.tar.gz"
  tar -xzf "${TMP}/helm.tar.gz" -C "${TMP}"
  install "${TMP}/linux-arm64/helm" "${INSTALL_DIR}/helm"
  rm -rf "${TMP}"
  info "Helm installed"
fi

# ── kind ───────────────────────────────────────────────────────────────────
KIND_VERSION="v0.31.0"
if ! install_if_missing "kind ${KIND_VERSION}" kind; then
  info "Installing kind ${KIND_VERSION} (ARM64)..."
  curl -fsSL "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-arm64" \
    -o "${INSTALL_DIR}/kind"
  chmod +x "${INSTALL_DIR}/kind"
  info "kind installed"
fi

# ── Trivy ──────────────────────────────────────────────────────────────────
if ! install_if_missing "Trivy" trivy; then
  info "Installing Trivy via official install script (ARM64)..."
  curl -fsSL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
    | sh -s -- -b "${INSTALL_DIR}"
  info "Trivy installed"
fi

# ── Checkov ────────────────────────────────────────────────────────────────
if ! command -v checkov &>/dev/null; then
  info "Installing Checkov via Python venv..."
  python3 -m venv "${HOME}/.venv/checkov"
  "${HOME}/.venv/checkov/bin/pip" install --quiet checkov
  cat > "${INSTALL_DIR}/checkov" <<'SHIM'
#!/usr/bin/env bash
exec "${HOME}/.venv/checkov/bin/checkov" "$@"
SHIM
  chmod +x "${INSTALL_DIR}/checkov"
  info "Checkov installed"
else
  info "Checkov already installed"
fi

# ── passt ─────────────────────────────────────────────────────────────────
if command -v passt &>/dev/null; then
  info "passt already installed"
else
  info "passt installed (via apt above)"
fi

# ── Docker: allow push to MiniStack ECR (insecure registry) ───────────────
DOCKER_CFG="${HOME}/.config/docker/daemon.json"
mkdir -p "$(dirname "${DOCKER_CFG}")"
if ! grep -q "localhost:4566" "${DOCKER_CFG}" 2>/dev/null; then
  info "Configuring Docker insecure registry for MiniStack ECR..."
  echo '{"insecure-registries": ["localhost:4566"]}' > "${DOCKER_CFG}"
  systemctl --user restart docker || true
  sleep 2
  info "Docker daemon config updated"
else
  info "Docker insecure registry already configured"
fi

# ── Shell exports reminder ─────────────────────────────────────────────────
echo ""
info "─────────────────────────────────────────────────────────"
info "Add these to ~/.zshrc / ~/.bashrc if not already present:"
echo ""
echo "  export PATH=\"\${HOME}/.local/bin:\${PATH}\""
echo "  export DOCKER_HOST=unix:///run/user/\${UID}/docker.sock"
echo "  export KUBECONFIG=\${HOME}/.kube/config-eks-ministack"
info "─────────────────────────────────────────────────────────"
echo ""

# ── Summary ────────────────────────────────────────────────────────────────
info "Phase 0 complete. Tool versions:"
terraform version 2>/dev/null | head -1 | xargs -I{} printf "  %-12s %s\n" "terraform" "{}"
kubectl version --client 2>/dev/null | grep 'Client Version' | xargs -I{} printf "  %-12s %s\n" "kubectl" "{}"
helm version --short 2>/dev/null | xargs -I{} printf "  %-12s %s\n" "helm" "{}"
kind version 2>/dev/null | xargs -I{} printf "  %-12s %s\n" "kind" "{}"
trivy --version 2>/dev/null | head -1 | xargs -I{} printf "  %-12s %s\n" "trivy" "{}"
checkov --version 2>/dev/null | xargs -I{} printf "  %-12s %s\n" "checkov" "{}"
