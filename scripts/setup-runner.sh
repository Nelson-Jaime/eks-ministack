#!/usr/bin/env bash
# Register this Pi as a GitHub Actions self-hosted runner for eks-ministack.
#
# Run once as the 'nelson' user. Requires a runner registration token:
#   https://github.com/Nelson-Jaime/eks-ministack/settings/actions/runners/new
#
# Usage:
#   export RUNNER_TOKEN="<token-from-github>"
#   bash scripts/setup-runner.sh

set -euo pipefail

RUNNER_VERSION="2.323.0"
RUNNER_ARCH="arm64"
RUNNER_DIR="${HOME}/actions-runner"
REPO_URL="https://github.com/Nelson-Jaime/eks-ministack"
RUNNER_NAME="pi-$(hostname)"
RUNNER_LABELS="self-hosted,linux,arm64"

# ── Validate ───────────────────────────────────────────────────────────────
if [[ -z "${RUNNER_TOKEN:-}" ]]; then
  echo "ERROR: RUNNER_TOKEN is not set."
  echo ""
  echo "Get a token from:"
  echo "  ${REPO_URL}/settings/actions/runners/new"
  echo ""
  echo "Then run:"
  echo "  export RUNNER_TOKEN=<your-token>"
  echo "  bash scripts/setup-runner.sh"
  exit 1
fi

# ── Step 1: Download runner binary ─────────────────────────────────────────
echo "=== Step 1: Download runner (ARM64 v${RUNNER_VERSION}) ==="
mkdir -p "${RUNNER_DIR}"

TARBALL="actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
DOWNLOAD_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${TARBALL}"

if [[ -f "${RUNNER_DIR}/run.sh" ]]; then
  echo "Runner binary already present — skipping download"
else
  curl -fsSL "${DOWNLOAD_URL}" -o "/tmp/${TARBALL}"
  tar -xzf "/tmp/${TARBALL}" -C "${RUNNER_DIR}"
  rm "/tmp/${TARBALL}"
  echo "Runner extracted to ${RUNNER_DIR}"
fi

# ── Step 2: Configure runner ───────────────────────────────────────────────
echo ""
echo "=== Step 2: Configure runner ==="
"${RUNNER_DIR}/config.sh" \
  --url "${REPO_URL}" \
  --token "${RUNNER_TOKEN}" \
  --name "${RUNNER_NAME}" \
  --labels "${RUNNER_LABELS}" \
  --work "${RUNNER_DIR}/_work" \
  --unattended \
  --replace

# ── Step 3: Write environment file ────────────────────────────────────────
echo ""
echo "=== Step 3: Write environment file ==="
# systemd services don't inherit login-shell env vars.
# PATH must include ~/.local/bin (terraform, kubectl, helm, kind, trivy, checkov).
# DOCKER_HOST must point to the rootless Docker socket.
cat > "${RUNNER_DIR}/.env" <<EOF
DOCKER_HOST=unix:///run/user/1000/docker.sock
KUBECONFIG=${HOME}/.kube/config-eks-ministack
PATH=${HOME}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
AWS_ACCESS_KEY_ID=test
AWS_SECRET_ACCESS_KEY=test
AWS_DEFAULT_REGION=us-east-1
AWS_ENDPOINT_URL=http://localhost:4566
EOF
chmod 600 "${RUNNER_DIR}/.env"
echo "Environment file: ${RUNNER_DIR}/.env"

# ── Step 4: Install user-level systemd service ────────────────────────────
echo ""
echo "=== Step 4: Install systemd user service ==="
# User-level (not system-level) because:
# - Docker socket unix:///run/user/1000/docker.sock is a user-session resource
# - loginctl enable-linger keeps /run/user/1000/ alive across reboots
mkdir -p "${HOME}/.config/systemd/user"
cat > "${HOME}/.config/systemd/user/github-runner.service" <<EOF
[Unit]
Description=GitHub Actions runner (eks-ministack)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${RUNNER_DIR}
EnvironmentFile=${RUNNER_DIR}/.env
ExecStart=${RUNNER_DIR}/run.sh
Restart=on-failure
RestartSec=10s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=github-runner

[Install]
WantedBy=default.target
EOF

# Enable lingering so the user session (and /run/user/1000/) persists at boot
loginctl enable-linger "${USER}" 2>/dev/null \
  || echo "NOTE: loginctl enable-linger may need sudo — run: sudo loginctl enable-linger ${USER}"

systemctl --user daemon-reload
systemctl --user enable github-runner.service
systemctl --user start  github-runner.service

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "=== Runner status ==="
systemctl --user status github-runner.service --no-pager || true

echo ""
echo "=== Setup complete ==="
echo ""
echo "Useful commands:"
echo "  systemctl --user status  github-runner   # check status"
echo "  systemctl --user restart github-runner   # restart"
echo "  journalctl --user -u github-runner -f    # tail logs"
echo ""
echo "To deregister:"
echo "  ${RUNNER_DIR}/config.sh remove --token <removal-token>"
echo "  systemctl --user disable --now github-runner"
