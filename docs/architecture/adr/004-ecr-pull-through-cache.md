# ADR 004: Use ECR Pull-Through Cache for GHCR Images

## Status
Accepted

## Context

Application containers are stored in GitHub Container Registry (GHCR). EKS nodes need to pull these images. Options:

1. **ECR Pull-through Cache** - ECR proxies and caches GHCR images
2. **Direct GHCR Pull** - Nodes pull directly using imagePullSecrets
3. **Mirror to ECR** - CI/CD pushes to both GHCR and ECR

Considerations:
- Network reliability and latency
- Image pull speed
- Credential management
- Registry availability
- Cost

## Decision

Use **ECR Pull-through Cache** to proxy GHCR images through Amazon ECR.

## Rationale

### Why Pull-through Cache

1. **Faster pulls**: Images cached in-region, subsequent pulls are ECR-speed
2. **Resilience**: Cluster continues working if GHCR is temporarily unavailable
3. **Simpler auth**: ECR auth via instance role, no imagePullSecrets needed
4. **Single point of control**: Can add ECR scanning, replication later
5. **AWS network**: Pulls stay within AWS network after initial cache

### Why not Direct GHCR Pull

- Every pull traverses internet (latency, bandwidth costs)
- Requires managing imagePullSecrets in every namespace
- GHCR outage = deployment failures
- Rate limiting concerns at scale

### Why not Mirror to ECR

- Requires CI/CD changes to push to both registries
- Must keep two registries in sync
- More complex build pipelines
- Easy to have sync drift

## Consequences

### Positive
- Fast, reliable image pulls after first cache
- No imagePullSecrets management
- Leverages ECR's regional presence
- Can add vulnerability scanning via ECR

### Negative
- First pull still goes to GHCR (cold cache)
- Costs for ECR storage (cached images)
- Must configure pull-through cache rules

### Mitigations
- Use lifecycle policies to age out unused cached images
- Pre-warm cache for critical images
- Monitor cache hit rates

## Implementation Notes

### Terraform Configuration
```hcl
# Create pull-through cache rule for GHCR
resource "aws_ecr_pull_through_cache_rule" "ghcr" {
  ecr_repository_prefix = "ghcr"
  upstream_registry_url = "ghcr.io"

  # Credential for private GHCR repos
  credential_arn = aws_secretsmanager_secret.ghcr_token.arn
}

# Secret for GHCR authentication
resource "aws_secretsmanager_secret" "ghcr_token" {
  name = "${var.prefix}-ghcr-token"
}
```

### Image Reference Pattern
```yaml
# Original GHCR reference
image: ghcr.io/amerintlxperts/my-app:v1.0.0

# Pull-through cache reference
image: ${AWS_ACCOUNT}.dkr.ecr.ca-central-1.amazonaws.com/ghcr/amerintlxperts/my-app:v1.0.0
```

### ECR Lifecycle Policy
```json
{
  "rules": [{
    "rulePriority": 1,
    "description": "Expire untagged images after 7 days",
    "selection": {
      "tagStatus": "untagged",
      "countType": "sinceImagePushed",
      "countUnit": "days",
      "countNumber": 7
    },
    "action": { "type": "expire" }
  }]
}
```

## Alternatives Considered

### Direct GHCR Pull with imagePullSecrets
Rejected because: Operational burden of secret management, internet latency on every pull, GHCR availability dependency.

### Dual Push (GHCR + ECR)
Rejected because: Requires CI/CD changes, risk of sync drift, more complex pipelines.

## References

- [ECR Pull-through Cache](https://docs.aws.amazon.com/AmazonECR/latest/userguide/pull-through-cache.html)
- [GHCR Authentication](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)
