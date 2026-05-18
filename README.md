# End-to-End EKS Platform — MiniStack Simulation

A local simulation of a production-grade Kubernetes platform on AWS EKS, using:
- **MiniStack** (`localhost:4566`) — AWS API emulation (ECR, EKS, S3, IAM, Route53, VPC)
- **kind** — actual Kubernetes cluster (5 nodes, 2 AZs)
- **Terraform** — IaC provisioning against MiniStack
- **ArgoCD** — GitOps (App-of-Apps pattern)
- **Prometheus + Grafana** — observability
- **FastAPI** — sample application

---

## Architecture

```
CI/CD (Makefile)
  └─► Terraform → MiniStack (VPC, ECR, EKS API, IAM, Route53, S3)
  └─► Docker build + Trivy scan → MiniStack ECR (localhost:4566)
  └─► kind cluster (actual Kubernetes)
        ├─ NGINX Ingress Controller   (hostPort 8080/8443)
        ├─ cert-manager              (self-signed ClusterIssuer)
        ├─ ArgoCD                    (GitOps, watches k8s/apps/)
        ├─ ExternalDNS               (→ MiniStack Route53)
        ├─ Prometheus + Grafana      (monitoring stack)
        └─ fastapi-app               (sample app, 2 replicas, 2 AZs)
```

### MiniStack ↔ kind Mapping

| AWS EKS Concept        | Local Simulation                                     |
|------------------------|------------------------------------------------------|
| EKS Control Plane      | kind control-plane container                         |
| Managed Node Group     | kind worker containers (4 nodes)                     |
| AZ placement           | `topology.kubernetes.io/zone` node labels            |
| Amazon ECR             | MiniStack ECR (`localhost:4566/v2/`)                 |
| ALB / NLB              | NGINX Ingress (NodePort, hostPort 8080/8443)         |
| Route53 DNS            | `/etc/hosts` + MiniStack Route53 (ExternalDNS)       |
| IRSA / OIDC            | MiniStack IAM + OIDC URL (simulated trust)           |
| Terraform state S3     | MiniStack S3 bucket                                  |

---

## Phases

### Phase 0 — Install Tools

**What**: Install all missing binaries and configure Docker for MiniStack.

**Run**: `make install-tools`

Tools installed (ARM64):

| Tool       | Version  | Purpose                        |
|------------|----------|--------------------------------|
| Terraform  | 1.15.3   | IaC provisioning               |
| kubectl    | v1.36.1  | Kubernetes CLI                 |
| Helm       | v4.2.0   | Kubernetes package manager     |
| kind       | v0.31.0  | Local Kubernetes via Docker    |
| Trivy      | v0.70.0  | Container vulnerability scan   |
| Checkov    | latest   | IaC security scan              |
| passt      | apt      | Rootless Docker networking     |

One-time system config:
```bash
# Increase inotify limits (required for Prometheus watching many files)
echo "fs.inotify.max_user_watches=524288" | sudo tee /etc/sysctl.d/99-kind.conf
echo "fs.inotify.max_user_instances=512"  | sudo tee -a /etc/sysctl.d/99-kind.conf
sudo sysctl --system

# Allow Docker to push to MiniStack ECR (insecure registry)
cat > ~/.config/docker/daemon.json <<'EOF'
{"insecure-registries": ["localhost:4566"]}
EOF
systemctl --user restart docker

# Required for kind with rootless Docker — add to ~/.zshrc
export DOCKER_HOST=unix:///run/user/1000/docker.sock
export KUBECONFIG=~/.kube/config-eks-ministack
```

---

### Phase 1 — Terraform IaC

**What**: Provision all AWS resources in MiniStack via Terraform.

**Run**: `make tf-init && make tf-apply`

Resources created:

| Module   | Resources                                               |
|----------|---------------------------------------------------------|
| VPC      | VPC `10.0.0.0/16`, IGW, 4 subnets, 2 NAT GWs, routes  |
| ECR      | Repo `eks-ministack/fastapi-app`, lifecycle policy      |
| EKS      | Cluster + node group (MiniStack API simulation)         |
| IAM      | Cluster role, node role, IRSA role (ExternalDNS)        |
| Route53  | Zone `eks-ministack.local`, A records                   |

Terraform provider config targets MiniStack:
```hcl
provider "aws" {
  access_key = "test"
  secret_key = "test"
  skip_credentials_validation = true
  s3_use_path_style           = true
  endpoints {
    ec2 = "http://localhost:4566"
    ecr = "http://localhost:4566"
    eks = "http://localhost:4566"
    iam = "http://localhost:4566"
    route53 = "http://localhost:4566"
    s3  = "http://localhost:4566"
    sts = "http://localhost:4566"
  }
}
```

IaC scan runs before apply: `checkov -d terraform/ --framework terraform`

---

### Phase 2 — Docker Build + ECR Push

**What**: Build the FastAPI sample app, scan it with Trivy, push to MiniStack ECR.

**Run**: `make build push`

- Image: `localhost:4566/eks-ministack/fastapi-app:latest`
- Base: `python:3.12-slim` (multi-arch, ARM64 native)
- Trivy scan fails on HIGH/CRITICAL vulnerabilities (configurable)
- Login: `aws ecr get-login-password --endpoint-url http://localhost:4566 | docker login --username AWS --password-stdin localhost:4566`

App endpoints:
- `GET /` — pod name + version
- `GET /health` — liveness check
- `GET /ready` — readiness check
- `GET /metrics` — Prometheus metrics (request count + latency)

---

### Phase 3 — kind Cluster

**What**: Create a 5-node kind cluster simulating EKS with 2 availability zones.

**Run**: `make cluster-create`

Cluster layout:
```
eks-ministack-control-plane   zone: us-east-1a  (hostPort 8080, 8443, 9090)
eks-ministack-worker          zone: us-east-1a
eks-ministack-worker2         zone: us-east-1a
eks-ministack-worker3         zone: us-east-1b
eks-ministack-worker4         zone: us-east-1b
```

Image loaded into kind nodes (bypasses ECR pull, uses `imagePullPolicy: Never`):
```bash
kind load docker-image localhost:4566/eks-ministack/fastapi-app:latest --name eks-ministack
```

> **Note**: `DOCKER_HOST=unix:///run/user/1000/docker.sock` is required for all kind commands with rootless Docker.

---

### Phase 4 — Helm Bootstrap

**What**: Install the three foundational components that must exist before ArgoCD takes over.

**Run**: `make helm-bootstrap`

Order matters:
1. **NGINX Ingress** — NodePort service, exposes port 8080/8443 on host
2. **cert-manager** — CRDs + controller + webhook
3. **ArgoCD** — with custom Ingress health check (prevents `Progressing` loop with NodePort)

---

### Phase 5 — ArgoCD GitOps

**What**: Apply App-of-Apps and let ArgoCD sync all remaining components from Git.

**Run**: `make argocd-bootstrap`

Sync wave order:
| Wave | App               |
|------|-------------------|
| -6   | nginx-ingress     |
| -5   | cert-manager      |
| -4   | cert-manager-config (self-signed ClusterIssuer) |
|  0   | external-dns      |
|  0   | monitoring        |
|  5   | fastapi-app       |

Add to `/etc/hosts` for local DNS:
```
127.0.0.1  app.eks-ministack.local
127.0.0.1  argocd.eks-ministack.local
127.0.0.1  grafana.eks-ministack.local
```

Access:
- **App**: `http://localhost:8080` (Host: `app.eks-ministack.local`)
- **ArgoCD UI**: `http://localhost:9090`
- **Grafana**: `http://localhost:8080` (Host: `grafana.eks-ministack.local`) — admin/admin123

---

## Makefile Quick Reference

```bash
make install-tools      # Phase 0: install all tools
make tf-init            # Create S3 backend + terraform init
make tf-validate        # terraform validate + checkov scan
make tf-apply           # Provision AWS infra in MiniStack
make build              # Build FastAPI image + Trivy scan
make push               # Push to MiniStack ECR
make cluster-create     # Create 5-node kind cluster
make load-image         # Load image into kind nodes
make helm-bootstrap     # Install NGINX, cert-manager, ArgoCD
make argocd-bootstrap   # Apply App-of-Apps, wait for sync
make verify             # Layer-by-layer smoke tests
make status             # Show nodes + apps + unhealthy pods
make tf-state           # Show MiniStack resources via AWS CLI
make all                # Full pipeline (all phases)
make clean              # Delete cluster + destroy MiniStack resources
```

---

## Repository Structure

```
eks-ministack/
├── Makefile
├── kind-config.yaml
├── scripts/
│   ├── 00-install-tools.sh
│   ├── 01-terraform-init.sh
│   ├── 02-docker-build.sh
│   ├── 03-ecr-push.sh
│   ├── 04-kind-create.sh
│   ├── 05-helm-bootstrap.sh
│   ├── 06-argocd-bootstrap.sh
│   ├── 07-verify.sh
│   └── lib/{common.sh,aws.sh}
├── terraform/
│   ├── {main,backend,versions,variables,outputs}.tf
│   └── modules/{vpc,ecr,eks,iam,route53}/
├── helm/               # Helm values files
├── k8s/
│   ├── argocd/         # ArgoCD project + App-of-Apps
│   ├── apps/           # One ArgoCD Application per component
│   └── cert-manager-config/
├── app/
│   ├── main.py         # FastAPI application
│   ├── Dockerfile
│   ├── requirements.txt
│   └── k8s/            # App manifests
└── monitoring/
    └── dashboards/     # Grafana JSON dashboards
```

---

## Verification

```bash
# MiniStack resources
aws ec2 describe-vpcs --endpoint-url http://localhost:4566 --region us-east-1 \
  --query 'Vpcs[0].CidrBlock'                           # "10.0.0.0/16"
aws eks describe-cluster --name eks-ministack \
  --endpoint-url http://localhost:4566 --region us-east-1 \
  --query 'cluster.status'                              # "ACTIVE"

# Cluster nodes
kubectl get nodes --show-labels | grep zone             # 4 workers with AZ labels

# ArgoCD apps
kubectl get applications -n argocd                      # all Synced/Healthy

# Application
curl -H "Host: app.eks-ministack.local" http://localhost:8080/health
# {"status":"ok","version":"..."}

# Prometheus scraping
kubectl port-forward svc/prometheus-operated 9090:9090 -n monitoring &
curl "http://localhost:9090/api/v1/query?query=http_requests_total" | grep fastapi
```
