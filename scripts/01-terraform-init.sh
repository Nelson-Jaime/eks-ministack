#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
source "$(dirname "$0")/lib/aws.sh"

BUCKET="eks-ministack-tfstate"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

info "Checking MiniStack is reachable..."
if ! curl -sf "${MINISTACK_ENDPOINT}/_ministack/health" &>/dev/null && \
   ! curl -sf "${MINISTACK_ENDPOINT}/_localstack/health" &>/dev/null; then
  error "MiniStack is not running at ${MINISTACK_ENDPOINT}"
  error "Start it with: docker start ministack (or check docker ps)"
  exit 1
fi
info "MiniStack is up"

info "Creating S3 backend bucket: ${BUCKET}"
if aws_local s3api head-bucket --bucket "${BUCKET}" --region "${REGION}" &>/dev/null; then
  info "Bucket already exists — skipping"
else
  aws_local s3api create-bucket \
    --bucket "${BUCKET}" \
    --region "${REGION}"
  info "Bucket created"
fi

info "Running terraform init..."
cd "$(dirname "$0")/../terraform"
terraform init -reconfigure

info "tf-init complete — ready for: make tf-plan"
