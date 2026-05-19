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

---

## Troubleshooting

### Phase 0 — Install Tools

**`sudo: A terminal is required to authenticate`**
`make install-tools` runs non-interactively, so sudo prompts fail after the session expires. Run the sysctl step manually in your terminal:
```bash
sudo tee /etc/sysctl.d/99-kind.conf > /dev/null <<'EOF'
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
EOF
sudo sysctl --system
```

**`python3 -m venv` fails — `ensurepip not available`**
Python venv support is a separate package on Ubuntu:
```bash
sudo apt-get install -y python3-venv
```

**Tool not found after install**
`~/.local/bin` may not be on your PATH. Add to `~/.zshrc` or `~/.bashrc`:
```bash
export PATH="${HOME}/.local/bin:${PATH}"
```
Then `source ~/.zshrc` and re-run the failed command.

---

### Phase 1 — Terraform

**`MiniStack is not running at http://localhost:4566`**
The container stopped. Restart it:
```bash
DOCKER_HOST=unix:///run/user/${UID}/docker.sock docker ps -a   # find the container name
DOCKER_HOST=unix:///run/user/${UID}/docker.sock docker start <container-name>
```

**`InvalidClientTokenId` / STS auth failure during `terraform init`**
Terraform tried to reach the real AWS instead of MiniStack. `AWS_ENDPOINT_URL` was not exported. The Makefile sets it, but if you run `terraform` directly from the `terraform/` directory, set it manually:
```bash
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_ENDPOINT_URL=http://localhost:4566
terraform init
```

**`Backend initialization required` after editing `backend.tf`**
Any change to `backend.tf` requires re-init:
```bash
make tf-init
```

**Checkov fails with unexpected checks**
Checkov skips are configured in `terraform/.checkov.yaml`. If a new check fires, add it there with a comment explaining why it's acceptable for a local simulation.

**New Terraform module not found after adding it to `main.tf`**
Adding a new module call always requires re-init before plan/apply:
```bash
make tf-init
make tf-apply
```

---

### Phase 2 — Docker Build + ECR Push

**`docker: command not found` or `Cannot connect to Docker daemon`**
The rootless Docker socket must be set. Either source `.env.local` or export manually:
```bash
export DOCKER_HOST=unix:///run/user/${UID}/docker.sock
```

**Build fails — `python3-venv` or pip not available inside container**
This happens if the builder stage can't reach the internet. Check Docker's DNS:
```bash
docker run --rm python:3.12-slim pip install fastapi   # test connectivity
```
If it times out, restart the Docker daemon:
```bash
systemctl --user restart docker
```

**Trivy scan finds HIGH/CRITICAL CVEs**
The build uses `--exit-code 0` so CVEs are reported but don't block the build. This is intentional for a local simulation. In production pipelines, set `--exit-code 1` to fail the build on CRITICAL findings.

To see the full report without building:
```bash
make scan
```

**`docker login` to MiniStack ECR returns an error**
MiniStack must be running and Docker must allow the insecure registry. Verify both:
```bash
# MiniStack running?
curl -s http://localhost:4566/_ministack/health

# Insecure registry configured?
cat ~/.config/docker/daemon.json   # should contain "localhost:4566"
```
If the daemon.json was just updated, restart Docker:
```bash
systemctl --user restart docker
```

**`requested access to the resource is denied` when pushing**
The ECR repository must exist in MiniStack before pushing. Make sure Phase 1 Terraform has been applied:
```bash
make tf-state   # should show both backend and frontend repos
```
If missing, run `make tf-apply` to create them.

---

### Phase 3 — kind Cluster

**`sudo: A terminal is required to authenticate` during iptables switch**
The script tries to switch `iptables` to legacy mode but can't prompt for a password in a non-TTY context. The script warns and continues — `iptables-nft` works fine with kind v0.31.0 on this system. If you later see inter-pod routing failures, switch manually in a terminal:
```bash
sudo update-alternatives --set iptables /usr/sbin/iptables-legacy
sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
```
Then recreate the cluster: `make clean && make cluster-create`

**`kind create cluster` hangs at "Preparing nodes"**
Two common causes on rootless Docker ARM64:

1. `DOCKER_HOST` not set — kind can't find the Docker socket:
   ```bash
   export DOCKER_HOST=unix:///run/user/${UID}/docker.sock
   make cluster-create
   ```
2. `passt` not installed — rootless Docker needs it for container networking:
   ```bash
   sudo apt-get install -y passt
   systemctl --user restart docker
   make cluster-create
   ```

**`kind create cluster` hangs at "Starting control-plane"**
Usually an inotify limit issue when the monitoring stack is preloaded. Apply the kernel tuning and recreate:
```bash
sudo tee /etc/sysctl.d/99-kind.conf > /dev/null <<'EOF'
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
EOF
sudo sysctl --system
make clean && make cluster-create
```

**`kubectl wait` times out — nodes never reach Ready**
Check node status and CNI logs:
```bash
kubectl get nodes
kubectl describe node eks-ministack-worker | tail -20
kubectl get pods -n kube-system   # look for CrashLoopBackOff in kindnet/coredns
```
A CNI crash is usually the iptables issue above. Switch to legacy and recreate.

**`kind load docker-image` fails — image not found**
The image must exist locally before loading. Verify:
```bash
DOCKER_HOST=unix:///run/user/${UID}/docker.sock docker images | grep eks-ministack
```
If missing, rebuild first: `make build`

**AZ labels not appearing on nodes**
Confirm kind v0.17.0+ is installed (the `labels:` node field is unavailable in older versions):
```bash
kind version   # must be v0.17.0 or later
kubectl get nodes --show-labels | grep topology
```
If labels are missing despite a correct `kind-config.yaml`, delete and recreate the cluster — labels are only applied at node join time:
```bash
make clean && make cluster-create
```

**Cluster already exists error when re-running `make cluster-create`**
The script is idempotent — it skips creation if the cluster exists. If you need a clean rebuild:
```bash
make clean          # deletes cluster + destroys MiniStack resources
make tf-apply       # re-provision MiniStack
make build push     # rebuild and re-push images
make cluster-create # fresh cluster
```
