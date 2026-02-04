# ADR 002: Use IRSA for AWS Service Authentication

## Status
Accepted

## Context

Kubernetes pods need to authenticate with AWS services (Secrets Manager, S3, SageMaker, etc.). The options are:

1. **IRSA (IAM Roles for Service Accounts)** - OIDC-based identity federation
2. **EKS Pod Identity** - AWS-native pod identity (newer)
3. **Instance Profile** - Node-level IAM role
4. **Access Keys** - Long-lived credentials in secrets

Our security requirements:
- Least privilege access per workload
- No long-lived credentials
- Audit trail of API calls
- Compatible with External Secrets Operator

## Decision

Use **IRSA (IAM Roles for Service Accounts)** for all pod-to-AWS authentication.

## Rationale

### Why IRSA

1. **Pod-level isolation**: Each service account gets its own IAM role with minimal permissions
2. **No credentials to manage**: Temporary credentials via STS, auto-rotated
3. **Mature and proven**: Widely adopted since 2019, extensive documentation
4. **External Secrets compatibility**: ESO officially supports IRSA
5. **Fine-grained CloudTrail**: API calls traceable to specific pods/roles

### Why not EKS Pod Identity

- Newer service (GA December 2023), less community experience
- Requires EKS Pod Identity Agent addon
- IRSA works identically, no compelling reason to switch
- May consider for future projects once more mature

### Why not Instance Profile

- All pods share the same permissions (violates least privilege)
- Cannot differentiate access between workloads
- Security anti-pattern for multi-tenant clusters
- Cannot audit which pod made which API call

### Why not Access Keys

- Long-lived credentials are a security risk
- Must manually rotate and distribute
- If leaked, provides persistent access
- Violates AWS security best practices

## Consequences

### Positive
- Strong security posture from day one
- CloudTrail shows which workload accessed which resource
- No credential rotation burden
- Terraform can automate role creation per service account

### Negative
- Must create IAM role + policy per service account needing AWS access
- Slightly more complex than instance profile
- OIDC provider must be created during cluster setup

### Mitigations
- Use Terraform modules to standardize IRSA role creation
- Document common role patterns (S3 read, Secrets Manager, etc.)
- Create reusable policy templates

## Implementation Notes

### Terraform Pattern
```hcl
# Create OIDC provider (once per cluster)
resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
}

# Create role per service account
resource "aws_iam_role" "app_role" {
  name = "${var.prefix}-app-role"

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
          "${local.oidc_issuer}:sub" = "system:serviceaccount:${var.namespace}:${var.service_account}"
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}
```

### Kubernetes Annotation
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: my-app
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT:role/my-app-role
```

## Alternatives Considered

### EKS Pod Identity
Rejected because: Newer with less ecosystem support. Will reconsider for future clusters once adoption increases.

### Instance Profile
Rejected because: Security anti-pattern. All pods share permissions, violating least privilege principle.

### Access Keys in Secrets
Rejected because: Long-lived credentials require manual rotation and pose security risk if leaked.

## References

- [IRSA Documentation](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
- [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)
- [External Secrets IRSA](https://external-secrets.io/latest/provider/aws-secrets-manager/)
