# EKS GitOps Platform

A production-ready Kubernetes platform on Amazon EKS with GitOps-based continuous delivery using ArgoCD.

## Overview

This project deploys a complete Kubernetes platform with:

- **Amazon EKS** (v1.31) with managed node groups
- **ArgoCD** for GitOps continuous delivery
- **FortiWeb** WAF for ingress and application security
- **IRSA** (IAM Roles for Service Accounts) for secure AWS access
- **External Secrets Operator** for secrets management
- **Cert-Manager** for automated TLS certificates

## Architecture

```
GitHub (amerintlxperts org)                     AWS (ca-central-1)
┌────────────────────┐                 ┌─────────────────────────────────────┐
│                    │                 │              VPC                     │
│  infrastructure-2026│                 │  ┌─────────────────────────────────┐│
│  (Monorepo)        │                 │  │         EKS Cluster              ││
│  ├─ terraform/     │── Terraform ───►│  │                                  ││
│  ├─ manifests-     │                 │  │  ┌────────┐  ┌────────────────┐ ││
│  │  platform/      │── ArgoCD ──────►│  │  │Managed │  │ Platform Pods  │ ││
│  └─ manifests-     │                 │  │  │ Nodes  │  │ - ArgoCD       │ ││
│     apps/          │                 │  │  │        │  │ - ESO          │ ││
│                    │                 │  │  │        │  │ - Cert-Manager │ ││
└────────────────────┘                 │  │  └────────┘  └────────────────┘ ││
                                       │  └─────────────────────────────────┘│
         Internet                      │                                      │
             │                         │  ┌─────────────┐                     │
             └─────────────────────────┼─►│  FortiWeb   │ (WAF/Ingress)       │
                                       │  └─────────────┘                     │
                                       └─────────────────────────────────────┘
```

## Repository Structure

```
infrastructure-2026/
├── CLAUDE.md                  # Claude Code instructions
├── .claude/                   # Claude Code skills
├── bootstrap/                 # One-time setup scripts
│   ├── hydrate.sh            # Create S3, IAM, GitHub secrets
│   └── cleanup.sh            # Tear down everything
├── .github/workflows/         # CI/CD pipelines
│   ├── terraform.yml         # Plan on PR, apply on merge
│   └── terraform-destroy.yml # Manual destroy
├── terraform/                 # Infrastructure as Code
│   └── environments/dev/     # VPC, EKS, FortiWeb, ArgoCD
├── manifests-platform/        # Cluster services (ArgoCD manages)
│   ├── argocd/               # ArgoCD Application definitions
│   └── resources/            # K8s resources (ClusterIssuers, etc.)
├── manifests-apps/            # Your applications
└── docs/                      # Documentation
    ├── architecture/         # ADRs, diagrams, guides
    ├── spec/                 # Module specifications
    └── prompts/              # Implementation prompts
```

## Quick Start

### Prerequisites

- AWS CLI v2 configured with credentials
- Terraform >= 1.5
- kubectl matching EKS version
- GitHub CLI (`gh`) authenticated

### 1. Bootstrap (One-Time)

```bash
./bootstrap/hydrate.sh
```

This creates:
- S3 bucket for Terraform state
- DynamoDB table for state locking
- GitHub OIDC provider for keyless CI/CD
- Least-privilege IAM role for GitHub Actions
- GitHub secrets (AWS_ROLE_ARN, AWS_REGION)

### 2. Deploy Infrastructure

```bash
cd terraform/environments/dev
terraform init -migrate-state
terraform plan
terraform apply
```

### 3. Access ArgoCD

```bash
# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo

# Port-forward to UI
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Open https://localhost:8080 (admin / <password>)
```

### 4. Secure FortiWeb (Required)

FortiWeb boots with default credentials (`admin/<instance-id>`) which must be changed:

```bash
# Get FortiWeb URL
terraform output fortiweb_mgmt_url

# Get default password (instance ID) - intentionally requires AWS CLI
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=xperts-dev-fortiweb" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text

# Login to FortiWeb UI, change admin password, then update Secrets Manager:
aws secretsmanager put-secret-value \
  --secret-id dev/fortiweb \
  --secret-string '{"username":"admin","password":"YOUR_NEW_PASSWORD"}'
```

### 5. Deploy Applications

```bash
# Add your app to manifests-apps/
mkdir manifests-apps/my-app
# Add deployment.yaml, service.yaml, ingress.yaml
git add . && git commit -m "Add my-app" && git push
# ArgoCD auto-syncs within 3 minutes
```

### Tear Down

```bash
./bootstrap/cleanup.sh
```

## Documentation

| Document | Description |
|----------|-------------|
| [Architecture Overview](docs/architecture/README.md) | High-level architecture and navigation |
| [Architecture Decisions](docs/architecture/adr/) | ADRs explaining key choices |
| [System Diagrams](docs/architecture/diagrams/) | Visual architecture diagrams |
| [Getting Started](docs/architecture/guides/getting-started.md) | Step-by-step setup guide |
| [Troubleshooting](docs/architecture/guides/troubleshooting.md) | Common issues and solutions |
| [Module Specs](docs/spec/) | Detailed module specifications |

## Key Design Decisions

| Decision | Choice | ADR |
|----------|--------|-----|
| Node Strategy | Managed Node Groups | [ADR-001](docs/architecture/adr/001-eks-managed-node-groups.md) |
| AWS Authentication | IRSA | [ADR-002](docs/architecture/adr/002-irsa-for-aws-authentication.md) |
| GitOps Tool | ArgoCD | [ADR-003](docs/architecture/adr/003-fluxcd-with-github-app.md) |
| Secrets Management | External Secrets Operator | [ADR-005](docs/architecture/adr/005-external-secrets-operator.md) |
| Ingress | Fortinet FortiWeb | [ADR-006](docs/architecture/adr/006-fortiweb-ingress.md) |
| Repository Structure | Monorepo | [ADR-007](docs/architecture/adr/007-hybrid-repository-structure.md) |

## Security

- **No AWS account ID in git** - Sensitive values injected at deploy time
- **Least-privilege IAM** - GitHub Actions uses scoped policy, not AdministratorAccess
- **OIDC authentication** - No long-lived AWS credentials stored anywhere
- **Secrets in AWS** - All secrets in Secrets Manager, synced via External Secrets
- **`.hydration-config` gitignored** - Share securely with collaborators

## Cost Estimate

| Component | Monthly Cost |
|-----------|-------------|
| EKS Control Plane | $73 |
| EC2 Nodes (1x t3.medium) | ~$30 |
| FortiWeb (t3.small) | ~$15 |
| NAT Gateway | ~$32 |
| VPC Endpoints | ~$52 |
| Other (CloudWatch, SM) | ~$12 |
| **Total** | **~$214/month** |

## Workflows

| Action | How |
|--------|-----|
| Deploy infrastructure | Push to `terraform/` → GitHub Actions → `terraform apply` |
| Deploy platform service | Push to `manifests-platform/` → ArgoCD syncs |
| Deploy application | Push to `manifests-apps/` → ArgoCD syncs |
| Destroy infrastructure | GitHub Actions → "Terraform Destroy" workflow |
| Full teardown | `./bootstrap/cleanup.sh` |

## For Claude Code Users

This repository includes Claude Code configuration:
- `.claude/skills/terraform/` - Terraform best practices
- `docs/prompts/` - Implementation prompts for modules
- `docs/spec/` - Detailed specifications

See [CLAUDE.md](CLAUDE.md) for full instructions.

## License

Private - amerintlxperts
