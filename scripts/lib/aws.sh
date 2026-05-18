#!/usr/bin/env bash
# AWS CLI wrapper — always targets MiniStack at localhost:4566

export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"
export MINISTACK_ENDPOINT="http://localhost:4566"

aws_local() {
  aws --endpoint-url "${MINISTACK_ENDPOINT}" "$@"
}
