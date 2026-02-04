# Getting Started Guide

This guide walks through deploying the EKS GitOps platform from scratch.

## Prerequisites

### Tools Required

| Tool | Version | Purpose |
|------|---------|---------|
| AWS CLI | 2.x | AWS resource management |
| Terraform | >= 1.5 | Infrastructure provisioning |
| kubectl | 1.31.x | Kubernetes CLI |
| flux | 2.x | FluxCD CLI |
| git | 2.x | Version control |

### AWS Requirements

- AWS account with admin access
- IAM user or role with permissions to create:
  - VPC, subnets, route tables, NAT gateway
  - EKS cluster and node groups
  - IAM roles and policies
  - ECR repositories
  - Secrets Manager secrets
  - CloudWatch log groups

### GitHub Requirements

- GitHub organization: `amerintlxperts`
- GitHub App created with:
  - Repository contents: Read
  - Repository metadata: Read
- Access to create repositories

## Step 1: Create GitHub Repositories

### 1.1 Create Infrastructure Repository

```bash
# Create eks-infrastructure repository in amerintlxperts org
gh repo create amerintlxperts/eks-infrastructure --private --description "EKS cluster Terraform infrastructure"

# Clone locally
git clone https://github.com/amerintlxperts/eks-infrastructure.git
cd eks-infrastructure
```

### 1.2 Create GitOps Repository

```bash
# Create gitops-platform repository
gh repo create amerintlxperts/gitops-platform --private --description "FluxCD GitOps manifests"

# Clone locally
git clone https://github.com/amerintlxperts/gitops-platform.git
cd gitops-platform
```

## Step 2: Configure GitHub App

### 2.1 Create GitHub App

1. Navigate to `amerintlxperts` organization settings
2. Go to Developer settings → GitHub Apps → New GitHub App
3. Configure:
   - Name: `amerintlxperts-fluxcd`
   - Homepage URL: `https://github.com/amerintlxperts`
   - Webhook: Deactivate (not needed)
   - Permissions:
     - Repository contents: Read-only
     - Repository metadata: Read-only
   - Where can this app be installed: Only on this account

4. Create the app and note:
   - App ID
   - Generate and download private key

### 2.2 Install App on Repositories

1. Go to GitHub App settings → Install App
2. Select `amerintlxperts` organization
3. Choose "Only select repositories"
4. Select: `gitops-platform`
5. Note the Installation ID from URL

### 2.3 Store Credentials in AWS

```bash
# Store GitHub App private key in Secrets Manager
aws secretsmanager create-secret \
  --name "dev/github-app/private-key" \
  --secret-string file://path/to/private-key.pem \
  --region ca-central-1

# Store App ID and Installation ID
aws secretsmanager create-secret \
  --name "dev/github-app/config" \
  --secret-string '{"app_id": "123456", "installation_id": "12345678"}' \
  --region ca-central-1
```

## Step 3: Deploy Infrastructure

### 3.1 Configure Terraform Backend

```bash
cd eks-infrastructure

# Create S3 bucket for state
aws s3 mb s3://amerintlxperts-terraform-state-ca-central-1 --region ca-central-1

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket amerintlxperts-terraform-state-ca-central-1 \
  --versioning-configuration Status=Enabled

# Create DynamoDB table for locking
aws dynamodb create-table \
  --table-name amerintlxperts-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ca-central-1
```

### 3.2 Initialize Terraform

```bash
cd terraform/environments/dev

# Create terraform.tfvars
cat > terraform.tfvars << 'EOF'
project_name = "amerintlxperts"
environment  = "dev"
aws_region   = "ca-central-1"

# VPC Configuration
vpc_cidr = "10.0.0.0/16"

# EKS Configuration
eks_version       = "1.31"
node_instance_types = ["t3.medium"]
node_desired_size = 2
node_min_size     = 1
node_max_size     = 4

# GitHub Configuration
github_org = "amerintlxperts"
EOF

# Initialize Terraform
terraform init \
  -backend-config="bucket=amerintlxperts-terraform-state-ca-central-1" \
  -backend-config="key=eks/dev/terraform.tfstate" \
  -backend-config="region=ca-central-1" \
  -backend-config="dynamodb_table=amerintlxperts-terraform-locks"
```

### 3.3 Deploy Infrastructure

```bash
# Review plan
terraform plan -out=tfplan

# Apply (takes ~15-20 minutes)
terraform apply tfplan

# Save outputs for later
terraform output -json > outputs.json
```

## Step 4: Configure kubectl

### 4.1 Update kubeconfig

```bash
# Configure kubectl to access the EKS cluster
aws eks update-kubeconfig --region ca-central-1 --name xperts-dev

# Verify connection
kubectl get nodes
```

This command:
- Downloads the cluster certificate
- Configures kubectl context
- Sets up AWS IAM authentication

You can also get the cluster name dynamically from Terraform:
```bash
aws eks update-kubeconfig \
  --region ca-central-1 \
  --name $(terraform -chdir=terraform/environments/dev output -raw cluster_name)
```

## Step 5: Bootstrap FluxCD

### 5.1 Install Flux CLI

```bash
# macOS
brew install fluxcd/tap/flux

# Linux
curl -s https://fluxcd.io/install.sh | sudo bash
```

### 5.2 Retrieve GitHub App Credentials

```bash
# Get credentials from Secrets Manager
APP_CONFIG=$(aws secretsmanager get-secret-value \
  --secret-id dev/github-app/config \
  --query SecretString --output text)

export GITHUB_APP_ID=$(echo $APP_CONFIG | jq -r '.app_id')
export GITHUB_APP_INSTALLATION_ID=$(echo $APP_CONFIG | jq -r '.installation_id')

# Get private key
aws secretsmanager get-secret-value \
  --secret-id dev/github-app/private-key \
  --query SecretString --output text > /tmp/github-app-key.pem
```

### 5.3 Bootstrap Flux

```bash
flux bootstrap github \
  --owner=amerintlxperts \
  --repository=gitops-platform \
  --path=clusters/dev \
  --branch=main \
  --github-app-id=$GITHUB_APP_ID \
  --github-app-installation-id=$GITHUB_APP_INSTALLATION_ID \
  --github-app-private-key-path=/tmp/github-app-key.pem

# Clean up private key
rm /tmp/github-app-key.pem
```

### 5.4 Verify Flux Installation

```bash
# Check Flux components
flux get all

# Should show:
# - source-controller
# - kustomize-controller
# - helm-controller
# - notification-controller

kubectl get pods -n flux-system
```

## Step 6: Deploy Platform Components

### 6.1 Add Infrastructure Kustomizations

The bootstrap created the initial structure. Now add platform components:

```bash
cd gitops-platform

# Create infrastructure directory
mkdir -p clusters/dev/infrastructure

# Create External Secrets Operator
cat > clusters/dev/infrastructure/external-secrets.yaml << 'EOF'
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: HelmRepository
metadata:
  name: external-secrets
  namespace: flux-system
spec:
  interval: 1h
  url: https://charts.external-secrets.io
---
apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: external-secrets
  namespace: external-secrets
spec:
  interval: 1h
  chart:
    spec:
      chart: external-secrets
      version: "0.9.x"
      sourceRef:
        kind: HelmRepository
        name: external-secrets
        namespace: flux-system
  install:
    createNamespace: true
  values:
    serviceAccount:
      annotations:
        eks.amazonaws.com/role-arn: ${ESO_ROLE_ARN}
EOF

# Commit and push
git add .
git commit -m "Add External Secrets Operator"
git push
```

### 6.2 Wait for Reconciliation

```bash
# Watch reconciliation
flux get kustomizations -w

# Check ESO deployment
kubectl get pods -n external-secrets
```

## Step 7: Verify Installation

### 7.1 Run Health Checks

```bash
# Check all nodes ready
kubectl get nodes

# Check all system pods running
kubectl get pods -n kube-system
kubectl get pods -n flux-system
kubectl get pods -n external-secrets

# Check FluxCD status
flux check

# Test secret sync (if ESO configured)
kubectl get externalsecrets -A
```

### 7.2 Test Application Deployment

```bash
# Create a test application
mkdir -p apps/test-app/base

cat > apps/test-app/base/deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-app
  template:
    metadata:
      labels:
        app: test-app
    spec:
      containers:
      - name: nginx
        image: nginx:latest
        ports:
        - containerPort: 80
EOF

cat > apps/test-app/base/kustomization.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
EOF

# Add to cluster
cat > clusters/dev/apps/test-app.yaml << 'EOF'
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: test-app
  namespace: flux-system
spec:
  interval: 5m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./apps/test-app/base
  prune: true
  targetNamespace: default
EOF

git add .
git commit -m "Add test application"
git push

# Watch deployment
flux get kustomizations -w
kubectl get pods -l app=test-app
```

## Troubleshooting

### Terraform Issues

```bash
# State lock issues
terraform force-unlock LOCK_ID

# Resource stuck
terraform state rm aws_resource.name
```

### FluxCD Issues

```bash
# Force reconciliation
flux reconcile source git flux-system
flux reconcile kustomization flux-system

# View controller logs
kubectl logs -n flux-system deploy/source-controller
kubectl logs -n flux-system deploy/kustomize-controller

# Check Git authentication
kubectl get secret -n flux-system flux-system -o yaml
```

### Node Issues

```bash
# Check node status
kubectl describe node NODE_NAME

# Check kubelet logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-node
```

## Next Steps

1. [Configure FortiWeb Ingress](./fortiweb-setup.md)
2. [Set up CloudWatch Observability](./cloudwatch-setup.md)
3. [Deploy First Application](./deploy-application.md)
4. [Configure GHCR Pull-through Cache](./ecr-pullthrough.md)
