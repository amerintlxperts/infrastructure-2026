# Bootstrap / Hydration

One-time setup and teardown scripts for the EKS platform.

## Prerequisites

- AWS CLI configured with admin credentials
- GitHub CLI (`gh`) authenticated
- `jq` installed

## Quick Start

```bash
# Setup (run once)
./bootstrap/hydrate.sh

# Teardown (destroys everything!)
./bootstrap/cleanup.sh
```

## What It Does

| Step | Resource | Purpose |
|------|----------|---------|
| 1 | S3 Bucket | Terraform state storage |
| 2 | DynamoDB Table | Terraform state locking |
| 3 | OIDC Provider | GitHub Actions → AWS auth (keyless) |
| 4 | IAM Role | Permissions for GitHub Actions |
| 5 | GitHub Secrets | AWS_ROLE_ARN, AWS_REGION |
| 6 | backend.tf | Enable S3 backend |

## Configuration

Override defaults with environment variables:

```bash
PROJECT_NAME=myproject \
ENVIRONMENT=prod \
AWS_REGION=us-east-1 \
GITHUB_ORG=myorg \
GITHUB_REPO=myrepo \
./bootstrap/hydrate.sh
```

## After Hydration

```bash
cd terraform/environments/dev
terraform init -migrate-state  # Migrate local state to S3
terraform plan
terraform apply
```

## GitHub Actions

The workflow (`.github/workflows/terraform.yml`) will:
- Run `terraform plan` on PRs
- Comment the plan on the PR
- Run `terraform apply` when merged to main

Uses OIDC for authentication - no long-lived AWS credentials stored in GitHub.

## Cleanup / Teardown

To destroy everything:

```bash
# Full cleanup (Terraform + bootstrap resources)
./bootstrap/cleanup.sh

# Skip terraform destroy (only remove bootstrap resources)
./bootstrap/cleanup.sh --skip-terraform

# Non-interactive (skip confirmations)
./bootstrap/cleanup.sh --force
```

**What cleanup.sh removes:**
| Resource | Notes |
|----------|-------|
| Terraform infrastructure | EKS, VPC, FortiWeb, etc. |
| S3 bucket | Terraform state (versioned objects too) |
| DynamoDB table | State locking |
| IAM role | GitHub Actions role |
| OIDC provider | Optional (may be shared) |
| GitHub secrets | AWS_ROLE_ARN, AWS_REGION |
| Local files | .terraform, tfstate, backend.tf |

**Via GitHub Actions:**

Use the "Terraform Destroy" workflow for destroying infrastructure only:
1. Go to Actions → Terraform Destroy
2. Select environment
3. Type "destroy" to confirm
4. Run workflow

Note: The GitHub workflow only destroys Terraform resources, not bootstrap resources.
