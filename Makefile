SHELL := /bin/bash
PROJECT   := eks-ministack
APP_VERSION ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)

AWS_ENDPOINT := http://localhost:4566
AWS_REGION   := us-east-1
IMAGE        := localhost:4566/$(PROJECT)/fastapi-app

export AWS_ACCESS_KEY_ID     := test
export AWS_SECRET_ACCESS_KEY := test
export AWS_DEFAULT_REGION    := $(AWS_REGION)
export DOCKER_HOST           := unix:///run/user/$(shell id -u)/docker.sock
export KUBECONFIG            := $(HOME)/.kube/config-$(PROJECT)

.PHONY: install-tools tf-init tf-validate tf-plan tf-apply tf-destroy \
        build scan push cluster-create cluster-delete load-image \
        helm-bootstrap argocd-bootstrap verify status tf-state clean all help

## ── Phase 0: Tools ───────────────────────────────────────────────────────
install-tools:  ## Install terraform, kubectl, helm, kind, trivy, checkov, passt
	@bash scripts/00-install-tools.sh

## ── Phase 1: IaC ─────────────────────────────────────────────────────────
tf-init:        ## Create S3 backend bucket in MiniStack + terraform init
	@bash scripts/01-terraform-init.sh

tf-validate:    ## terraform validate + checkov IaC scan
	@cd terraform && terraform validate
	@checkov -d terraform/ --framework terraform --quiet

tf-plan: tf-validate  ## Terraform plan against MiniStack
	@cd terraform && terraform plan -var="project_name=$(PROJECT)"

tf-apply: tf-validate  ## Provision VPC, ECR, EKS, IAM, Route53 in MiniStack
	@cd terraform && terraform apply -auto-approve -var="project_name=$(PROJECT)"

tf-destroy:     ## Destroy all MiniStack resources
	@cd terraform && terraform destroy -auto-approve -var="project_name=$(PROJECT)"

## ── Phase 2: Docker ──────────────────────────────────────────────────────
build:          ## Build FastAPI Docker image + Trivy scan
	@bash scripts/02-docker-build.sh $(APP_VERSION)

scan:           ## Trivy scan only (no build)
	@trivy image --severity HIGH,CRITICAL $(IMAGE):$(APP_VERSION)

push:           ## Login + push image to MiniStack ECR
	@bash scripts/03-ecr-push.sh $(APP_VERSION)

## ── Phase 3: kind cluster ────────────────────────────────────────────────
cluster-create: ## Create 5-node kind cluster (1 CP + 4 workers, 2 AZs)
	@bash scripts/04-kind-create.sh

cluster-delete: ## Delete kind cluster
	@DOCKER_HOST=$(DOCKER_HOST) kind delete cluster --name $(PROJECT)

load-image:     ## Load Docker image into all kind nodes
	@DOCKER_HOST=$(DOCKER_HOST) kind load docker-image $(IMAGE):latest --name $(PROJECT)

## ── Phase 4: Helm bootstrap ──────────────────────────────────────────────
helm-bootstrap: ## Install NGINX Ingress, cert-manager, ArgoCD via Helm
	@bash scripts/05-helm-bootstrap.sh

## ── Phase 5: GitOps ──────────────────────────────────────────────────────
argocd-bootstrap: ## Apply App-of-Apps + wait for all apps to sync
	@bash scripts/06-argocd-bootstrap.sh

## ── Verify ───────────────────────────────────────────────────────────────
verify:         ## Layer-by-layer smoke tests
	@bash scripts/07-verify.sh

## ── Utility ──────────────────────────────────────────────────────────────
status:         ## Show cluster nodes, ArgoCD apps, unhealthy pods
	@echo "=== Nodes ===" && kubectl get nodes -o wide
	@echo "=== ArgoCD Apps ===" && kubectl get applications -n argocd 2>/dev/null || true
	@echo "=== Unhealthy Pods ===" && kubectl get pods -A | grep -Ev 'Running|Completed' || echo "all pods healthy"

tf-state:       ## Show MiniStack resources via AWS CLI
	@echo "=== VPCs ===" && AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
	  aws ec2 describe-vpcs --endpoint-url $(AWS_ENDPOINT) --region $(AWS_REGION) --output table
	@echo "=== ECR ===" && AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
	  aws ecr describe-repositories --endpoint-url $(AWS_ENDPOINT) --region $(AWS_REGION) --output table
	@echo "=== EKS ===" && AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
	  aws eks list-clusters --endpoint-url $(AWS_ENDPOINT) --region $(AWS_REGION)

clean: cluster-delete tf-destroy  ## Delete kind cluster + destroy MiniStack resources
	@docker rmi $(IMAGE):latest 2>/dev/null || true

all: install-tools tf-apply build push cluster-create load-image helm-bootstrap argocd-bootstrap verify
	@echo "Full pipeline complete!"

help:           ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
