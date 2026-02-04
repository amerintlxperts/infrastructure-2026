# ADR 007: Hybrid Repository Structure

## Status
Accepted

## Context

We need to organize code and configuration across multiple concerns:

1. **Infrastructure** (Terraform) - AWS resources, EKS cluster, IAM
2. **GitOps manifests** (FluxCD) - Kubernetes deployments, Helm releases
3. **Application code** - Container source code

Repository structure options:

1. **Monorepo** - Everything in one repository
2. **Multi-repo** - Separate repos for infra, gitops, each app
3. **Hybrid** - Terraform separate, apps + manifests together

Considerations:
- Team size (small)
- Environment count (single dev)
- Change coupling
- Access control needs

## Decision

Use **Hybrid** repository structure:
- One repository for **Terraform infrastructure**
- One repository for **GitOps manifests + application definitions**

## Rationale

### Why Hybrid

1. **Separation of concerns**: Infrastructure changes (VPC, EKS) have different lifecycle than app deployments
2. **Access control**: Platform team vs application teams may have different permissions
3. **Change velocity**: Apps deploy frequently, infrastructure changes are rare
4. **Blast radius**: Infrastructure mistakes shouldn't mix with app deploy history
5. **Simpler than full multi-repo**: Don't need per-app repos for small team

### Repository Layout

**Repository 1: `amerintlxperts/eks-infrastructure`**
```
eks-infrastructure/
├── terraform/
│   ├── environments/
│   │   └── dev/
│   │       ├── main.tf
│   │       ├── variables.tf
│   │       └── terraform.tfvars
│   └── modules/
│       ├── vpc/
│       ├── eks/
│       ├── irsa/
│       └── ecr/
├── scripts/
│   └── bootstrap.sh
└── README.md
```

**Repository 2: `amerintlxperts/gitops-platform`**
```
gitops-platform/
├── clusters/
│   └── dev/
│       ├── flux-system/          # FluxCD bootstrap
│       ├── infrastructure/       # Cluster-wide: ESO, ingress
│       └── apps/                 # Application deployments
├── apps/
│   ├── app-name/
│   │   ├── base/                 # Kustomize base
│   │   └── overlays/
│   │       └── dev/
│   └── another-app/
├── charts/
│   └── common/                   # Shared Helm charts
└── README.md
```

### Why not Full Monorepo

- Terraform state management separate from GitOps
- Different CI/CD patterns (terraform plan vs flux sync)
- Infrastructure rarely changes after initial setup
- Git history cleaner when separated

### Why not Full Multi-repo

- Overkill for small team
- More repos to manage
- Cross-repo changes harder to coordinate
- Single GitOps repo is FluxCD best practice

## Consequences

### Positive
- Clean separation between infrastructure and workloads
- Single GitOps repo for all K8s resources (FluxCD recommended)
- Terraform changes don't trigger app reconciliation
- Clear ownership boundaries

### Negative
- Must ensure infrastructure outputs are available to GitOps
- Two repos to maintain (vs one)
- Cross-repo references need documentation

### Mitigations
- Terraform outputs to SSM Parameter Store for GitOps consumption
- Clear documentation of repo boundaries
- GitHub App has access to both repos

## Implementation Notes

### Cross-repo Data Sharing

Terraform writes values that GitOps needs:
```hcl
# In eks-infrastructure terraform
resource "aws_ssm_parameter" "eks_endpoint" {
  name  = "/eks/dev/endpoint"
  value = aws_eks_cluster.main.endpoint
}

resource "aws_ssm_parameter" "ecr_registry" {
  name  = "/eks/dev/ecr-registry"
  value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}
```

GitOps can reference via External Secrets or init containers.

### FluxCD Multi-repo (if needed later)
```yaml
# Can add additional GitRepositories for app-specific repos
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: app-repo
spec:
  url: https://github.com/amerintlxperts/specific-app
```

### Branch Strategy

Both repos use:
- `main` - Production-ready (for dev environment)
- Feature branches for changes
- PR-based workflow

## Alternatives Considered

### Full Monorepo
Rejected because: Terraform and GitOps have different lifecycles, mixing them creates noisy Git history and complicated CI/CD.

### Full Multi-repo (per-app repos)
Rejected because: Overkill for small team, coordination overhead, more repos than necessary.

### Terraform + Manifests in one, Apps separate
Considered but: Keeping manifests with apps is also valid, but FluxCD works best with dedicated GitOps repo.

## References

- [FluxCD Repository Structure](https://fluxcd.io/flux/guides/repository-structure/)
- [Terraform Workspace Patterns](https://developer.hashicorp.com/terraform/language/state/workspaces)
