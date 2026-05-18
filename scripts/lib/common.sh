#!/usr/bin/env bash
# Shared helpers for all pipeline scripts

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

wait_for() {
  local description="$1"
  local max_attempts="${2:-30}"
  local sleep_sec="${3:-5}"
  shift 3
  local attempt=0
  info "Waiting for: ${description}"
  until "$@" &>/dev/null; do
    attempt=$((attempt + 1))
    if [[ $attempt -ge $max_attempts ]]; then
      error "Timed out waiting for: ${description}"
      return 1
    fi
    echo -n "."
    sleep "${sleep_sec}"
  done
  echo ""
  info "Ready: ${description}"
}

require_tool() {
  for tool in "$@"; do
    if ! command -v "${tool}" &>/dev/null; then
      error "Required tool not found: ${tool}. Run: make install-tools"
      exit 1
    fi
  done
}
