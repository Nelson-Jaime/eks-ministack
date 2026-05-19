#!/usr/bin/env bash
# Full-setup orchestrator for eks-ministack.
#
# Usage:
#   ./scripts/pipeline.sh                    # run all phases
#   ./scripts/pipeline.sh --from cluster     # restart from 'cluster' phase
#   ./scripts/pipeline.sh --dry-run          # print what would run, no execution
#   ./scripts/pipeline.sh --dry-run --from docker

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ── Phase registry ─────────────────────────────────────────────────────────
# Format: "name:target1 target2 ..."
PHASES=(
  "tools:install-tools"
  "terraform:tf-init tf-apply"
  "docker:build push"
  "cluster:cluster-create load-image"
  "helm:helm-bootstrap"
  "argocd:argocd-bootstrap"
  "verify:verify"
)

PHASE_NAMES=()
for _entry in "${PHASES[@]}"; do
  PHASE_NAMES+=("${_entry%%:*}")
done

# ── Argument parsing ───────────────────────────────────────────────────────
FROM_PHASE=""
DRY_RUN=false

usage() {
  echo "Usage: $(basename "$0") [--from <phase>] [--dry-run] [--help]"
  echo ""
  echo "Phases: ${PHASE_NAMES[*]}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)
      FROM_PHASE="${2:?--from requires a phase name}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      error "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

# ── Validate --from ────────────────────────────────────────────────────────
if [[ -n "${FROM_PHASE}" ]]; then
  valid=false
  for _n in "${PHASE_NAMES[@]}"; do
    [[ "${_n}" == "${FROM_PHASE}" ]] && valid=true && break
  done
  if [[ "${valid}" != "true" ]]; then
    error "Unknown phase: '${FROM_PHASE}'. Valid: ${PHASE_NAMES[*]}"
    exit 1
  fi
fi

# ── Helpers ────────────────────────────────────────────────────────────────
banner() {
  local num="$1" name="$2" total="${#PHASES[@]}"
  local title="  Phase ${num}/${total}: ${name}  "
  local width=60
  local line; printf -v line '%*s' "${width}" ''; line="${line// /═}"
  echo ""
  echo -e "\033[1;34m${line}\033[0m"
  printf "\033[1;34m%-${width}s\033[0m\n" "${title}"
  echo -e "\033[1;34m${line}\033[0m"
}

run_target() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo -e "  \033[1;33m[DRY-RUN]\033[0m  make $1"
  else
    make "$1"
  fi
}

# ── Main loop ──────────────────────────────────────────────────────────────
[[ "${DRY_RUN}" == "true" ]] && warn "DRY-RUN mode — nothing will execute"

PIPELINE_START=$(date +%s)
SKIPPING=true
[[ -z "${FROM_PHASE}" ]] && SKIPPING=false

phase_num=0
for entry in "${PHASES[@]}"; do
  phase_num=$((phase_num + 1))
  phase_name="${entry%%:*}"
  read -ra targets <<< "${entry#*:}"

  if [[ "${SKIPPING}" == "true" ]]; then
    if [[ "${phase_name}" == "${FROM_PHASE}" ]]; then
      SKIPPING=false
    else
      info "Skipping: ${phase_name}"
      continue
    fi
  fi

  banner "${phase_num}" "${phase_name}"
  phase_start=$(date +%s)

  for target in "${targets[@]}"; do
    info "make ${target}"
    if ! run_target "${target}"; then
      elapsed=$(( $(date +%s) - phase_start ))
      error "Phase '${phase_name}' FAILED at 'make ${target}' after ${elapsed}s"
      error "Resume with: $0 --from ${phase_name}"
      exit 1
    fi
  done

  elapsed=$(( $(date +%s) - phase_start ))
  info "Phase '${phase_name}' done in ${elapsed}s"
done

total=$(( $(date +%s) - PIPELINE_START ))
mins=$(( total / 60 ))
secs=$(( total % 60 ))

echo ""
echo -e "\033[1;32m╔══════════════════════════════════════════╗\033[0m"
printf  "\033[1;32m║  Pipeline complete!  Total: %dm %ds%*s║\033[0m\n" \
  "${mins}" "${secs}" $(( 14 - ${#mins} - ${#secs} )) ""
echo -e "\033[1;32m╚══════════════════════════════════════════╝\033[0m"
echo ""
