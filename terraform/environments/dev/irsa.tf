# =============================================================================
# IRSA (IAM Roles for Service Accounts)
# =============================================================================
# Creates IAM roles that Kubernetes pods can assume via their ServiceAccount.
# Each role is scoped to a specific namespace:serviceaccount combination.
#
# HOW IRSA WORKS:
# ---------------
#   1. EKS cluster has an OIDC provider (created in eks.tf)
#   2. IAM role trusts tokens from that OIDC provider
#   3. Trust is scoped to specific namespace:serviceaccount
#   4. Pod with that ServiceAccount gets JWT token injected
#   5. AWS SDK uses token to call sts:AssumeRoleWithWebIdentity
#   6. Pod gets temporary credentials for the IAM role
#
# WHAT'S INCLUDED:
# ----------------
#   - External Secrets Operator role (reads from AWS Secrets Manager)
#
# WHAT'S SKIPPED (add later if needed):
# -------------------------------------
#   - CloudWatch Agent role (for container metrics to CloudWatch)
#   - Fluent Bit role (for container logs to CloudWatch)
#   - FluxCD roles (FluxCD uses deploy keys for Git, not IRSA)
#   - App-specific roles (add as needed for your applications)
#
# TO ADD A NEW IRSA ROLE:
# -----------------------
#   1. Copy the external_secrets role/policy pattern below
#   2. Change the name, namespace, serviceaccount in trust policy
#   3. Change the IAM permissions to match your use case
#   4. Add output for the role ARN
#   5. Create matching ServiceAccount in Kubernetes with annotation:
#      eks.amazonaws.com/role-arn: <role_arn>
#
# =============================================================================

locals {
  # OIDC provider URL without https:// prefix (needed for trust policy conditions)
  oidc_issuer = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
}

# -----------------------------------------------------------------------------
# External Secrets Operator Role
# -----------------------------------------------------------------------------
# Allows ESO to read secrets from AWS Secrets Manager and create Kubernetes
# Secrets from them. This is the most common IRSA use case.
#
# PERMISSIONS:
#   - secretsmanager:GetSecretValue - Read secret values
#   - secretsmanager:DescribeSecret - Get secret metadata
#   - secretsmanager:ListSecrets    - List available secrets
#
# RESOURCE SCOPE:
#   Only secrets matching: arn:aws:secretsmanager:REGION:ACCOUNT:secret:dev/*
#   To use this, name your secrets with "dev/" prefix in Secrets Manager.
#
# TRUST SCOPE:
#   namespace=external-secrets, serviceaccount=external-secrets
#
# USAGE:
#   1. Deploy External Secrets Operator (via Helm or manifests)
#
#   2. Create ServiceAccount with role annotation:
#      ---
#      apiVersion: v1
#      kind: ServiceAccount
#      metadata:
#        name: external-secrets
#        namespace: external-secrets
#        annotations:
#          eks.amazonaws.com/role-arn: ${external_secrets_role_arn}
#
#   3. Create SecretStore pointing to AWS Secrets Manager:
#      ---
#      apiVersion: external-secrets.io/v1beta1
#      kind: SecretStore
#      metadata:
#        name: aws-secrets-manager
#        namespace: external-secrets
#      spec:
#        provider:
#          aws:
#            service: SecretsManager
#            region: ca-central-1
#            auth:
#              jwt:
#                serviceAccountRef:
#                  name: external-secrets
#
#   4. Create ExternalSecret to sync a secret:
#      ---
#      apiVersion: external-secrets.io/v1beta1
#      kind: ExternalSecret
#      metadata:
#        name: my-secret
#        namespace: default
#      spec:
#        refreshInterval: 1h
#        secretStoreRef:
#          name: aws-secrets-manager
#          kind: SecretStore
#        target:
#          name: my-secret
#        data:
#          - secretKey: password
#            remoteRef:
#              key: dev/my-app/database    # Secret name in AWS
#              property: password           # JSON key within secret
#
# -----------------------------------------------------------------------------

resource "aws_iam_role" "external_secrets" {
  name = "${local.cluster_name}-external-secrets"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
          "${local.oidc_issuer}:sub" = "system:serviceaccount:external-secrets:external-secrets"
        }
      }
    }]
  })

  tags = {
    Name = "${local.cluster_name}-external-secrets-role"
  }
}

resource "aws_iam_role_policy" "external_secrets" {
  name = "secrets-manager-read"
  role = aws_iam_role.external_secrets.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GetSecrets"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        # Scoped to secrets with environment prefix
        Resource = "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.environment}/*"
      },
      {
        Sid    = "ListSecrets"
        Effect = "Allow"
        Action = [
          "secretsmanager:ListSecrets"
        ]
        Resource = "*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# External-DNS Role
# -----------------------------------------------------------------------------
# Allows External-DNS to create/update/delete Route53 records based on
# Kubernetes Ingress annotations.
#
# PERMISSIONS:
#   - route53:ChangeResourceRecordSets - Create/update/delete DNS records
#   - route53:ListResourceRecordSets   - List existing records
#   - route53:ListHostedZones          - Find the hosted zone
#
# TRUST SCOPE:
#   namespace=external-dns, serviceaccount=external-dns
# -----------------------------------------------------------------------------

resource "aws_iam_role" "external_dns" {
  name = "${local.cluster_name}-external-dns"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
          "${local.oidc_issuer}:sub" = "system:serviceaccount:external-dns:external-dns"
        }
      }
    }]
  })

  tags = {
    Name = "${local.cluster_name}-external-dns-role"
  }
}

resource "aws_iam_role_policy" "external_dns" {
  name = "route53-record-management"
  role = aws_iam_role.external_dns.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ChangeRecords"
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets"
        ]
        Resource = "arn:aws:route53:::hostedzone/${aws_route53_zone.main.zone_id}"
      },
      {
        Sid    = "ListRecordsAndZones"
        Effect = "Allow"
        Action = [
          "route53:ListHostedZones",
          "route53:ListResourceRecordSets"
        ]
        Resource = "*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Cert-Manager Role
# -----------------------------------------------------------------------------
# Allows cert-manager to create/delete Route53 TXT records for DNS-01 ACME
# challenges. This avoids HTTP-01 ingress conflicts with the gateway.
#
# PERMISSIONS:
#   - route53:GetChange              - Check if DNS change has propagated
#   - route53:ChangeResourceRecordSets - Create/delete TXT records
#   - route53:ListResourceRecordSets - List existing records
#   - route53:ListHostedZones        - Find the hosted zone
#   - route53:ListHostedZonesByName  - Find zone by domain name
#
# TRUST SCOPE:
#   namespace=cert-manager, serviceaccount=cert-manager
# -----------------------------------------------------------------------------

resource "aws_iam_role" "cert_manager" {
  name = "${local.cluster_name}-cert-manager"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
          "${local.oidc_issuer}:sub" = "system:serviceaccount:cert-manager:cert-manager"
        }
      }
    }]
  })

  tags = {
    Name = "${local.cluster_name}-cert-manager-role"
  }
}

resource "aws_iam_role_policy" "cert_manager" {
  name = "route53-dns01-challenge"
  role = aws_iam_role.cert_manager.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GetChange"
        Effect = "Allow"
        Action = [
          "route53:GetChange"
        ]
        Resource = "arn:aws:route53:::change/*"
      },
      {
        Sid    = "ChangeRecords"
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets"
        ]
        Resource = "arn:aws:route53:::hostedzone/${aws_route53_zone.main.zone_id}"
      },
      {
        Sid    = "ListZones"
        Effect = "Allow"
        Action = [
          "route53:ListHostedZones",
          "route53:ListHostedZonesByName"
        ]
        Resource = "*"
      }
    ]
  })
}
