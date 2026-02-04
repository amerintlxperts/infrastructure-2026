# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## Overview

This is the **infrastructure-2026** monorepo - a production-ready EKS GitOps platform on AWS.

## Repository Structure

```
infrastructure-2026/
├── CLAUDE.md                  # Claude Code instructions (this file)
├── .claude/                   # Claude Code skills and configuration
│   └── skills/terraform/      # Terraform best practices skill
├── bootstrap/
│   ├── hydrate.sh             # One-time setup: S3, DynamoDB, OIDC, secrets
│   ├── cleanup.sh             # Tear down everything (validates first)
│   └── .hydration-config      # Saved config (gitignored, share securely)
├── .github/workflows/
│   ├── terraform.yml          # Plan on PR, apply on merge
│   └── terraform-destroy.yml  # Manual destroy workflow
├── terraform/environments/dev/
│   ├── _providers.tf          # AWS, Helm, Kubernetes providers
│   ├── _variables.tf          # Input variables
│   ├── _locals.tf             # Derived values, subnet config
│   ├── _outputs.tf            # All outputs
│   ├── vpc.tf                 # VPC, subnets, gateways, routes
│   ├── vpc_endpoints.tf       # Interface + gateway endpoints
│   ├── security_groups.tf     # SGs for endpoints, EKS, nodes, FortiWeb
│   ├── eks.tf                 # EKS cluster, OIDC, KMS
│   ├── eks_addons.tf          # VPC CNI, CoreDNS, kube-proxy
│   ├── eks_nodes.tf           # Managed node group
│   ├── irsa.tf                # External Secrets IRSA role
│   ├── fortiweb.tf            # FortiWeb WAF instance
│   ├── argocd.tf              # ArgoCD Helm + root Application
│   └── external_secrets.tf    # External Secrets Operator
├── manifests-platform/
│   ├── argocd/                # ArgoCD Application CRDs
│   │   ├── cert-manager.yaml
│   │   ├── fortiweb-bootstrap.yaml
│   │   ├── reloader.yaml
│   │   ├── platform-resources.yaml
│   │   └── applications.yaml  # Points to manifests-apps/
│   └── resources/             # Actual K8s manifests
│       ├── cert-manager/
│       ├── external-secrets/
│       ├── fortiweb-bootstrap/  # Password bootstrap job
│       └── fortiweb-controller/ # FortiWebIngress CRD + certs
├── manifests-apps/            # Application deployments go here
│   └── .gitkeep
└── docs/                      # Documentation
    ├── architecture/          # ADRs, diagrams, guides
    ├── spec/                  # Module specifications
    └── prompts/               # Implementation prompts for Claude
```

## Project Status

**Phase: Implementation Complete**

- VPC, EKS, FortiWeb, ArgoCD, External Secrets deployed via Terraform
- Platform services defined in manifests-platform/
- CI/CD workflows configured with least-privilege IAM
- Bootstrap/cleanup scripts ready

## Key Configuration

| Setting | Value |
|---------|-------|
| AWS Region | ca-central-1 |
| GitHub Org | amerintlxperts |
| GitHub Repo | infrastructure-2026 |
| Environment | dev |
| EKS Version | 1.31 |
| CNI Plugin | AWS VPC CNI |
| GitOps Tool | ArgoCD |
| Ingress | FortiWeb |
| Node Type | t3.large |
| Node Count | 2 (scalable to 3) |

## Deployment Workflow

```
1. ./bootstrap/hydrate.sh           # One-time: S3, DynamoDB, OIDC, secrets
2. cd terraform/environments/dev
3. terraform init -migrate-state    # One-time: migrate to S3 backend
4. terraform plan && terraform apply

--- Platform running ---

5. Push to manifests-apps/          # Deploy apps via GitOps
6. Push to terraform/               # GitHub Actions runs plan/apply
```

## ArgoCD Sync Waves

| Wave | Component | Purpose |
|------|-----------|---------|
| 1 | cert-manager, reloader | Core operators |
| 2 | platform-resources | ClusterSecretStore, ClusterIssuers, ExternalSecrets |
| 2.5 | fortiweb-bootstrap | Bootstrap FortiWeb admin password |
| 3 | fortiweb-controller | FortiWebIngress CRD controller |
| 10 | applications | User applications (last) |

**Note**: External Secrets Operator is managed by Terraform (not ArgoCD) to keep AWS account ID out of git.

**Note**: All FortiWeb resources (controller, credentials, bootstrap job, certificates) are in the `fortiweb-controller` namespace.

## Key Patterns

### ArgoCD Application (Helm chart)
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager
  namespace: argocd
spec:
  source:
    repoURL: https://charts.jetstack.io
    chart: cert-manager
    targetRevision: v1.16.1
  destination:
    server: https://kubernetes.default.svc
    namespace: cert-manager
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### ArgoCD Application (Git directory)
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform-resources
spec:
  source:
    repoURL: https://github.com/amerintlxperts/infrastructure-2026
    path: manifests-platform/resources
    targetRevision: main
  # ...
```

### ExternalSecret
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: my-secret
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  data:
    - secretKey: password
      remoteRef:
        key: dev/my-app
        property: password
```

## Testing Commands

### Terraform
```bash
cd terraform/environments/dev
terraform fmt -check
terraform validate
terraform plan
```

### Configure kubectl
```bash
# Configure kubectl to access the EKS cluster
aws eks update-kubeconfig --region ca-central-1 --name xperts-dev
```

### Kubernetes
```bash
kubectl get nodes
kubectl get pods -A
kubectl get applications -n argocd
```

### ArgoCD
```bash
# Get password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d

# Port-forward
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

## Common Operations

### Deploy an application

Apps don't have their own Ingress resources. All routing is handled by the FortiWebIngress gateway CRD.

```bash
# 1. Create app manifests (Deployment, Service only - NO ingress)
cd manifests-apps
mkdir my-app
# Add namespace.yaml, deployment.yaml, service.yaml, kustomization.yaml

# 2. Add routing to the FortiWebIngress gateway
cd manifests-platform/resources/fortiweb-controller

# Add route in gateway.yaml under spec.routes:
#   - host: my-app.amerintlxperts.com
#     path: /
#     backend:
#       serviceName: my-service
#       serviceNamespace: my-app
#       port: 80
#     tls:
#       enabled: true
#       secretName: my-app-tls

# 3. (If HTTPS) Add Certificate in certificates.yaml:
#   apiVersion: cert-manager.io/v1
#   kind: Certificate
#   metadata:
#     name: my-app-tls
#     namespace: fortiweb-controller
#   spec:
#     secretName: my-app-tls
#     commonName: my-app.amerintlxperts.com
#     dnsNames:
#       - my-app.amerintlxperts.com
#     issuerRef:
#       name: letsencrypt-staging
#       kind: ClusterIssuer

# 4. Commit and push
git add . && git commit -m "Add my-app" && git push
# ArgoCD syncs automatically - controller configures FortiWeb + DNS
```

### Add a platform service
```bash
cd manifests-platform/argocd
# Add new-service.yaml (ArgoCD Application)
git add . && git commit -m "Add new-service" && git push
```

### Tear down everything
```bash
./bootstrap/cleanup.sh
```

## Documentation

| Document | Path | Description |
|----------|------|-------------|
| Architecture Overview | `docs/architecture/README.md` | High-level architecture |
| ADRs | `docs/architecture/adr/` | Architecture Decision Records |
| Diagrams | `docs/architecture/diagrams/` | System diagrams |
| Getting Started | `docs/architecture/guides/getting-started.md` | Setup guide |
| Troubleshooting | `docs/architecture/guides/troubleshooting.md` | Common issues |
| Module Specs | `docs/spec/` | Detailed module specifications |
| Implementation Prompts | `docs/prompts/` | Prompts for Claude Code |

## Cost Awareness

Estimated monthly cost: ~$229

| Component | Cost |
|-----------|------|
| EKS control plane | $73 |
| EC2 node (t3.medium) | ~$30 |
| FortiWeb (t3.medium) | ~$30 |
| NAT Gateway | ~$32 |
| VPC Endpoints | ~$52 |
| Other | ~$12 |

## Post-Deployment Security Steps

### FortiWeb Admin Password (Required)

FortiWeb boots with a **default password** of the EC2 instance ID - this is insecure and must be changed immediately:

```bash
# 1. Get FortiWeb URL
cd terraform/environments/dev
terraform output fortiweb_mgmt_url

# 2. Get default password (instance ID via AWS CLI - not in Terraform output for security)
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=xperts-dev-fortiweb" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text

# 3. Login to FortiWeb console and change password
#    URL: <from step 1>
#    Username: admin
#    Password: <instance_id from step 2>
#    Change at: System > Admin > Administrator

# 4. Update Secrets Manager with the new password
aws secretsmanager put-secret-value \
  --secret-id dev/fortiweb \
  --secret-string '{"username":"admin","password":"YOUR_NEW_PASSWORD"}'

# 5. External Secrets Operator will sync automatically (within refreshInterval)
#    Or force sync:
kubectl delete secret fortiweb-credentials -n fortiweb-controller
```

### Why This Matters

| Credential | Default | Risk |
|------------|---------|------|
| Admin console | `admin/<instance-id>` | Instance ID visible in AWS Console (requires AWS access to retrieve) |
| API (Secrets Manager) | What you entered in `hydrate.sh` | Secure, but must match FortiWeb config |

**Note**: Instance ID is intentionally NOT in Terraform outputs to avoid exposure in CI/CD logs.

## Security Notes

- **No AWS account ID in git** - IRSA ARN injected by Terraform at deploy time
- **Least-privilege CI/CD** - GitHub Actions uses scoped IAM policy, not AdministratorAccess
- **OIDC authentication** - No long-lived AWS credentials in GitHub
- **Secrets in AWS** - FortiWeb credentials in Secrets Manager, synced via External Secrets
- **`.hydration-config` is gitignored** - Share securely with collaborators (1Password, SSM, etc.)
- **FortiWeb default password** - Must be changed immediately after deployment (see above)

## Important Notes

- ArgoCD root app points to `manifests-platform/argocd/`
- External Secrets is managed by Terraform to keep AWS account ID out of git
- IRSA role ARN is automatically injected by Terraform at deploy time
- FortiWeb credentials must be stored in AWS Secrets Manager at `dev/fortiweb`
- Cleanup script validates infrastructure is destroyed before deleting state
- GitHub Actions uses least-privilege IAM policy (not AdministratorAccess)
- **Gateway architecture**: All apps share a single FortiWebIngress CRD (`gateway`) in `fortiweb-controller` namespace. FortiWeb can't bind multiple virtual servers to the same IP:port, so one gateway handles all host-based routing. Add routes to `gateway.yaml`, NOT per-app Ingress resources.

## For Claude Code Users

This repository includes:
- **`.claude/skills/terraform/`** - Terraform best practices skill for generating quality IaC
- **`docs/prompts/`** - Implementation prompts you can reference for specific modules
- **`docs/spec/`** - Detailed specifications for each infrastructure module

When making changes, Claude Code will automatically use the Terraform skill to ensure code follows organizational standards.
