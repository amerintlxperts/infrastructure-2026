# Architecture Documentation

This folder contains comprehensive architecture documentation for the EKS GitOps platform.

## Overview

This project deploys a Kubernetes platform on Amazon EKS with:
- **GitOps** via FluxCD for declarative cluster management
- **GHCR integration** via ECR pull-through cache
- **AWS service access** via IRSA (IAM Roles for Service Accounts)
- **Secrets management** via External Secrets Operator + AWS Secrets Manager
- **Ingress** via Fortinet FortiWeb
- **Observability** via AWS CloudWatch Container Insights

## Architecture Diagram

```
                                    ┌─────────────────────────────────────────────────────────────┐
                                    │                        AWS Cloud                             │
                                    │                      (ca-central-1)                          │
┌──────────────┐                    │  ┌────────────────────────────────────────────────────────┐  │
│   GitHub     │                    │  │                         VPC                             │  │
│  (amerintlxperts)    │                    │  │  ┌─────────────────┐    ┌─────────────────────────────┐│  │
│              │                    │  │  │  Public Subnet  │    │      Private Subnets        ││  │
│ ┌──────────┐ │    FluxCD Sync     │  │  │                 │    │                             ││  │
│ │ gitops-  │◄├────────────────────┼──┼──┤   FortiWeb      │    │  ┌─────────────────────┐   ││  │
│ │ platform │ │                    │  │  │   (Ingress)     │────┼──►    EKS Cluster      │   ││  │
│ └──────────┘ │                    │  │  │                 │    │  │   (k8s 1.31)        │   ││  │
│              │                    │  │  └─────────────────┘    │  │                     │   ││  │
│ ┌──────────┐ │                    │  │                         │  │  ┌───────────────┐ │   ││  │
│ │   eks-   │ │  Terraform Apply   │  │                         │  │  │ Managed Node  │ │   ││  │
│ │  infra   │─┼───────────────────►│  │                         │  │  │    Groups     │ │   ││  │
│ └──────────┘ │                    │  │                         │  │  │ (t3.medium)   │ │   ││  │
│              │                    │  │                         │  │  └───────────────┘ │   ││  │
│ ┌──────────┐ │                    │  │                         │  │                     │   ││  │
│ │   GHCR   │ │    Pull-through    │  │  ┌───────────────┐      │  │  ┌───────────────┐ │   ││  │
│ │ Registry │─┼────────────────────┼──┼──►     ECR       │──────┼──┼──►   Pods        │ │   ││  │
│ └──────────┘ │                    │  │  │ (cache)       │      │  │  └───────────────┘ │   ││  │
└──────────────┘                    │  │  └───────────────┘      │  └─────────────────────┘   ││  │
                                    │  │                         │                             ││  │
                                    │  └─────────────────────────┼─────────────────────────────┘│  │
                                    │                            │                               │  │
                                    │  ┌─────────────────────────▼───────────────────────────┐  │  │
                                    │  │                   AWS Services                       │  │  │
                                    │  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │  │  │
                                    │  │  │  Secrets    │  │ CloudWatch  │  │   SageMaker │  │  │  │
                                    │  │  │  Manager    │  │ (Insights)  │  │  (future)   │  │  │  │
                                    │  │  └─────────────┘  └─────────────┘  └─────────────┘  │  │  │
                                    │  └─────────────────────────────────────────────────────┘  │  │
                                    └───────────────────────────────────────────────────────────┘  │
                                    └─────────────────────────────────────────────────────────────┘
```

## Documentation Structure

| Folder | Purpose |
|--------|---------|
| [`adr/`](./adr/) | Architecture Decision Records - why we made key choices |
| [`diagrams/`](./diagrams/) | Mermaid diagrams for system visualization |
| [`guides/`](./guides/) | Operational how-to guides |
| [`data-models/`](./data-models/) | Schema definitions and data structures |

## Architecture Decision Records

| ADR | Title | Status |
|-----|-------|--------|
| [001](./adr/001-eks-managed-node-groups.md) | EKS Managed Node Groups | Accepted |
| [002](./adr/002-irsa-for-aws-authentication.md) | IRSA for AWS Authentication | Accepted |
| [003](./adr/003-fluxcd-with-github-app.md) | FluxCD with GitHub App | Accepted |
| [004](./adr/004-ecr-pull-through-cache.md) | ECR Pull-Through Cache for GHCR | Accepted |
| [005](./adr/005-external-secrets-operator.md) | External Secrets Operator | Accepted |
| [006](./adr/006-fortiweb-ingress.md) | Fortinet FortiWeb Ingress | Accepted |
| [007](./adr/007-hybrid-repository-structure.md) | Hybrid Repository Structure | Accepted |
| [008](./adr/008-cloudwatch-observability.md) | CloudWatch Observability | Accepted |

## Module Overview

The implementation is divided into modules that can be deployed incrementally:

| Module | Name | Description | Dependencies |
|--------|------|-------------|--------------|
| 1 | VPC & Networking | VPC, subnets, endpoints, security groups | None |
| 2 | EKS Cluster | Control plane, OIDC provider, initial config | Module 1 |
| 3 | Node Groups | Managed node groups, instance configuration | Module 2 |
| 4 | ECR & Registry | ECR repos, pull-through cache for GHCR | Module 1 |
| 5 | IAM & IRSA | IAM roles for service accounts | Module 2 |
| 6 | FluxCD Bootstrap | FluxCD installation, GitHub App config | Modules 2, 3 |
| 7 | Core Platform | External Secrets, ingress config, observability | Module 6 |
| 8 | Applications | Application deployments via GitOps | Module 7 |

## Key Design Decisions Summary

### Compute
- **EKS Managed Node Groups** for simplified node lifecycle
- **t3.medium/large** instances for cost optimization
- **1-2 nodes** initial capacity with autoscaling ready

### Networking
- **Public + Private** cluster access (API public, nodes private)
- **FortiWeb** ingress controller (organizational standard)
- **VPC endpoints** for private AWS service access

### GitOps
- **FluxCD v2** for cluster state management
- **GitHub App** authentication for fine-grained access
- **Hybrid repo structure**: Terraform separate, GitOps + apps together

### Security
- **IRSA** for pod-to-AWS authentication
- **External Secrets Operator** syncing from AWS Secrets Manager
- **ECR pull-through cache** for container images

### Observability
- **CloudWatch Container Insights** for metrics
- **Fluent Bit** for log aggregation
- **14-day log retention** for cost optimization

## Repository Structure

### Infrastructure Repository (`amerintlxperts/eks-infrastructure`)
```
eks-infrastructure/
├── terraform/
│   ├── environments/dev/      # Dev environment configuration
│   └── modules/               # Reusable Terraform modules
│       ├── vpc/
│       ├── eks/
│       ├── irsa/
│       └── ecr/
├── scripts/                   # Helper scripts
└── README.md
```

### GitOps Repository (`amerintlxperts/gitops-platform`)
```
gitops-platform/
├── clusters/dev/              # Cluster-specific configuration
│   ├── flux-system/           # FluxCD components
│   ├── infrastructure/        # Platform components (ESO, etc.)
│   └── apps/                  # Application references
├── apps/                      # Application definitions
│   └── app-name/
│       ├── base/              # Kustomize base
│       └── overlays/dev/      # Dev-specific patches
└── charts/                    # Shared Helm charts
```

## Cost Estimate

| Component | Monthly Cost | Notes |
|-----------|-------------|-------|
| EKS Control Plane | $73 | Fixed per-cluster |
| EC2 Nodes (2x t3.medium) | ~$60 | On-demand pricing |
| VPC Endpoints | ~$22 | ECR, Secrets Manager, logs |
| ECR Storage | ~$5 | Pull-through cache |
| CloudWatch | ~$10 | Logs + Container Insights |
| **Total** | **~$170/month** | Development environment |

### Cost Optimization Notes
- Use Spot instances for non-critical workloads (up to 70% savings)
- Scale to zero nodes when not in use
- 14-day log retention vs default 365 days
- Single NAT Gateway (vs HA) for dev

## Quick Links

- [System Overview Diagram](./diagrams/system-overview.md)
- [Data Flow Diagram](./diagrams/data-flow.md)
- [Network Architecture](./diagrams/network-architecture.md)
- [GitOps Flow](./diagrams/gitops-flow.md)
- [Getting Started Guide](./guides/getting-started.md)
- [Troubleshooting Guide](./guides/troubleshooting.md)
