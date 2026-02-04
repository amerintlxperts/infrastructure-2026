# =============================================================================
# EKS Cluster
# =============================================================================
# Creates the EKS control plane, IAM role, KMS encryption, and OIDC provider.
#
# The EKS control plane is fully managed by AWS - runs in AWS's account with
# cross-account ENIs in our private subnets for API server communication.
# =============================================================================

# -----------------------------------------------------------------------------
# EKS Cluster IAM Role
# -----------------------------------------------------------------------------
# This role allows the EKS service to manage resources on our behalf.
# It's assumed by the EKS service, not by us or our applications.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "eks_cluster" {
  name = "${local.cluster_name}-eks-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
    }]
  })

  tags = {
    Name = "${local.cluster_name}-eks-cluster-role"
  }
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

# -----------------------------------------------------------------------------
# KMS Key for Secrets Encryption
# -----------------------------------------------------------------------------
# Encrypts Kubernetes secrets at rest in etcd. This is a security best practice
# and required for many compliance frameworks.
# -----------------------------------------------------------------------------

resource "aws_kms_key" "eks" {
  description             = "KMS key for EKS secret encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = {
    Name = "${local.cluster_name}-eks-kms"
  }
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${local.cluster_name}-eks"
  target_key_id = aws_kms_key.eks.key_id
}

# -----------------------------------------------------------------------------
# EKS Cluster
# -----------------------------------------------------------------------------
# The control plane runs API server, etcd, controller-manager, and scheduler.
# AWS manages HA across 3 AZs automatically.
#
# Endpoint configuration:
# - Private access: Nodes communicate with API via VPC (required)
# - Public access: kubectl from your machine (restricted to your IP)
# -----------------------------------------------------------------------------

resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  version  = var.eks_version
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    # Deploy control plane ENIs in private subnets
    subnet_ids = [for k in local.private_subnet_keys : aws_subnet.main[k].id]

    # Endpoint access configuration
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = local.eks_public_access_cidrs

    # Security group for cluster communication
    security_group_ids = [aws_security_group.eks_cluster.id]
  }

  # API-only authentication mode for explicit access control
  # - Removes implicit cluster creator access
  # - All access must be explicitly granted via aws_eks_access_entry
  # - More secure and auditable than CONFIG_MAP mode
  access_config {
    authentication_mode = "API"
  }

  # Enable control plane logging to CloudWatch
  enabled_cluster_log_types = var.eks_enabled_log_types

  # Encrypt secrets at rest with KMS
  encryption_config {
    provider {
      key_arn = aws_kms_key.eks.arn
    }
    resources = ["secrets"]
  }

  # Ensure IAM role is ready before creating cluster
  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_cloudwatch_log_group.eks
  ]

  tags = {
    Name = "${local.cluster_name}-eks"
  }
}

# -----------------------------------------------------------------------------
# CloudWatch Log Group for EKS
# -----------------------------------------------------------------------------
# Pre-create the log group to control retention and avoid permission issues.
# EKS will use this for control plane logs (api, audit, authenticator).
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${local.cluster_name}/cluster"
  retention_in_days = 7

  tags = {
    Name = "${local.cluster_name}-eks-logs"
  }
}

# -----------------------------------------------------------------------------
# OIDC Provider for IRSA
# -----------------------------------------------------------------------------
# Enables IAM Roles for Service Accounts (IRSA). This allows Kubernetes
# service accounts to assume IAM roles without storing credentials.
#
# How it works:
# 1. Pod gets a projected service account token (JWT)
# 2. AWS SDK calls sts:AssumeRoleWithWebIdentity with the JWT
# 3. STS validates the JWT against this OIDC provider
# 4. STS returns temporary credentials
# 5. Pod uses credentials to call AWS APIs
# -----------------------------------------------------------------------------

data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer

  client_id_list = ["sts.amazonaws.com"]

  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]

  tags = {
    Name = "${local.cluster_name}-eks-oidc"
  }
}

# -----------------------------------------------------------------------------
# Admin Access Entry
# -----------------------------------------------------------------------------
# Grants cluster-admin access to the specified IAM role (typically an SSO role).
# This ensures admin access survives cluster recreation, unlike the aws-auth
# ConfigMap which only grants access to the principal that created the cluster.
#
# The role ARN is provided via TF_VAR_admin_role_arn from hydrate.sh.
# If not set, these resources are skipped (count = 0).
# -----------------------------------------------------------------------------

resource "aws_eks_access_entry" "admin" {
  count = var.admin_role_arn != "" ? 1 : 0

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.admin_role_arn
  type          = "STANDARD"

  tags = {
    Name = "${local.cluster_name}-admin-access"
  }
}

resource "aws_eks_access_policy_association" "admin" {
  count = var.admin_role_arn != "" ? 1 : 0

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.admin_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}

# -----------------------------------------------------------------------------
# CI/CD Access Entry (GitHub Actions)
# -----------------------------------------------------------------------------
# Grants cluster-admin access to the GitHub Actions OIDC role for Helm deployments.
# This role is created by hydrate.sh and follows the naming pattern:
# ${project_name}-github-actions
# -----------------------------------------------------------------------------

locals {
  ci_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-github-actions"
}

resource "aws_eks_access_entry" "ci" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = local.ci_role_arn
  type          = "STANDARD"

  tags = {
    Name = "${local.cluster_name}-ci-access"
  }
}

resource "aws_eks_access_policy_association" "ci" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = local.ci_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.ci]
}

# -----------------------------------------------------------------------------
# Additional Cluster Admins
# -----------------------------------------------------------------------------
# Grants cluster-admin access to additional IAM principals specified in
# var.additional_cluster_admins. Useful for granting access to other team
# members or automation roles.
# -----------------------------------------------------------------------------

resource "aws_eks_access_entry" "additional_admins" {
  for_each = toset(var.additional_cluster_admins)

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = each.value
  type          = "STANDARD"

  tags = {
    Name = "${local.cluster_name}-additional-admin"
  }
}

resource "aws_eks_access_policy_association" "additional_admins" {
  for_each = toset(var.additional_cluster_admins)

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = each.value
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.additional_admins]
}
