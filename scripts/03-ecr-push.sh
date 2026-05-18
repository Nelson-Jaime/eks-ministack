#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
source "$(dirname "$0")/lib/aws.sh"

APP_VERSION="${1:-dev}"
BACKEND_IMAGE="localhost:4566/eks-ministack/backend"
FRONTEND_IMAGE="localhost:4566/eks-ministack/frontend"
REGISTRY="localhost:4566"

require_tool docker aws

info "Logging in to MiniStack ECR..."
aws_local ecr get-login-password --region "${AWS_DEFAULT_REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}"

info "Pushing backend: ${BACKEND_IMAGE}:${APP_VERSION}"
docker push "${BACKEND_IMAGE}:${APP_VERSION}"
docker push "${BACKEND_IMAGE}:latest"

info "Pushing frontend: ${FRONTEND_IMAGE}:${APP_VERSION}"
docker push "${FRONTEND_IMAGE}:${APP_VERSION}"
docker push "${FRONTEND_IMAGE}:latest"

info "Images in MiniStack ECR:"
aws_local ecr list-images \
  --repository-name eks-ministack/backend \
  --region "${AWS_DEFAULT_REGION}" \
  --query 'imageIds[*].imageTag' --output table

aws_local ecr list-images \
  --repository-name eks-ministack/frontend \
  --region "${AWS_DEFAULT_REGION}" \
  --query 'imageIds[*].imageTag' --output table

info "Push complete"
