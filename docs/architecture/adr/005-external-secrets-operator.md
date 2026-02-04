# ADR 005: Use External Secrets Operator with AWS Secrets Manager

## Status
Accepted

## Context

Kubernetes workloads need secrets (API keys, database credentials, tokens). Options for secrets management:

1. **External Secrets Operator (ESO)** - Syncs from external stores to K8s secrets
2. **SOPS with Age/KMS** - Encrypted secrets in Git, decrypted by FluxCD
3. **Sealed Secrets** - Bitnami controller encrypts for Git storage
4. **Native K8s Secrets** - Plain YAML in Git (encrypted at rest in etcd)
5. **HashiCorp Vault** - Full-featured secrets management platform

Requirements:
- Secrets not stored in Git (even encrypted)
- Central management outside cluster
- IRSA-compatible authentication
- Rotation support
- Audit logging

## Decision

Use **External Secrets Operator** syncing from **AWS Secrets Manager**.

## Rationale

### Why External Secrets Operator

1. **Source of truth outside cluster**: Secrets Manager is the source, K8s is a consumer
2. **Automatic sync**: ESO polls and updates K8s secrets on change
3. **IRSA native**: Works seamlessly with IAM Roles for Service Accounts
4. **Multi-backend**: Can switch to Vault later without changing app manifests
5. **GitOps friendly**: ExternalSecret CRDs stored in Git, values never exposed
6. **Rotation support**: Secrets Manager rotation automatically propagates

### Why AWS Secrets Manager (vs Parameter Store)

- Native secret rotation support
- Better for sensitive credentials
- Cross-account sharing easier
- JSON structured secrets

### Why not SOPS

- Secrets still in Git (even encrypted)
- Must manage encryption keys
- No central secret visibility
- Rotation requires Git commits

### Why not Sealed Secrets

- Cluster-specific encryption
- Disaster recovery complexity
- No external secret rotation
- Harder to audit

### Why not HashiCorp Vault

- Significant operational overhead
- Overkill for single dev environment
- Cost of running Vault cluster
- ESO can connect to Vault later if needed

## Consequences

### Positive
- Secrets never touch Git
- Central audit trail in AWS CloudTrail
- Easy rotation via Secrets Manager console/API
- Familiar AWS patterns for team

### Negative
- ESO controller running in cluster (resource overhead)
- Secrets Manager costs ($0.40/secret/month)
- Slight sync delay (configurable refresh interval)

### Mitigations
- Set appropriate refresh intervals (5-60 seconds)
- Use Parameter Store for non-sensitive config (cheaper)
- Monitor ESO sync status

## Implementation Notes

### Install ESO via FluxCD
```yaml
# clusters/dev/infrastructure/external-secrets/helmrelease.yaml
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
  values:
    serviceAccount:
      annotations:
        eks.amazonaws.com/role-arn: ${ESO_ROLE_ARN}
```

### SecretStore Configuration
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: ca-central-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
```

### ExternalSecret Example
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: app-secrets
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: aws-secrets-manager
  target:
    name: app-secrets
  data:
    - secretKey: DATABASE_URL
      remoteRef:
        key: dev/app/database
        property: url
```

### IAM Policy for ESO
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret"
    ],
    "Resource": "arn:aws:secretsmanager:ca-central-1:*:secret:dev/*"
  }]
}
```

## Alternatives Considered

### SOPS with FluxCD Decryption
Rejected because: Encrypted secrets still in Git, no external rotation, key management burden.

### Sealed Secrets
Rejected because: Cluster-specific keys, disaster recovery concerns, no external audit trail.

### HashiCorp Vault
Rejected because: Operational complexity overkill for single dev environment. Can migrate later.

### Native K8s Secrets
Rejected because: Secrets in Git (even with RBAC), no rotation support, poor audit trail.

## References

- [External Secrets Operator](https://external-secrets.io/)
- [ESO AWS Provider](https://external-secrets.io/latest/provider/aws-secrets-manager/)
- [Secrets Manager Pricing](https://aws.amazon.com/secrets-manager/pricing/)
