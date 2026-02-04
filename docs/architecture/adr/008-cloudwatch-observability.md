# ADR 008: Use AWS CloudWatch for Observability

## Status
Accepted

## Context

We need observability (logs, metrics, traces) for EKS workloads. Options:

1. **AWS CloudWatch** - Container Insights, CloudWatch Logs, X-Ray
2. **Prometheus + Grafana** - Self-hosted, community standard
3. **Datadog** - Commercial SaaS
4. **New Relic** - Commercial SaaS
5. **OpenTelemetry + backends** - Vendor-neutral collection

Requirements:
- Cost minimization (dev environment)
- Minimal operational overhead
- Integration with AWS services
- Sufficient for debugging and basic monitoring

## Decision

Use **AWS CloudWatch** with Container Insights for observability.

## Rationale

### Why CloudWatch

1. **No infrastructure to manage**: No Prometheus/Grafana servers
2. **Cost-effective for dev**: Pay-per-use, no base cost
3. **AWS integration**: Native EKS, Lambda, SageMaker correlation
4. **Sufficient features**: Logs, metrics, basic dashboards, alarms
5. **Container Insights**: Pre-built EKS dashboards and metrics

### Why not Prometheus + Grafana

- Must run and maintain servers in cluster
- Resource overhead (Prometheus can be hungry)
- Configuration complexity
- Overkill for single dev environment
- Can add later for production if needed

### Why not Commercial SaaS

- Per-host pricing adds up
- Overkill for development
- Another vendor relationship
- Can migrate later if value justified

## Consequences

### Positive
- Zero infrastructure to maintain
- AWS support and integration
- Container Insights provides good defaults
- Logs searchable via CloudWatch Logs Insights

### Negative
- CloudWatch Logs Insights less powerful than Loki/Elasticsearch
- Alerting less flexible than Prometheus Alertmanager
- Dashboards less customizable than Grafana
- Potential log costs at scale

### Mitigations
- Set log retention policies (7-14 days for dev)
- Use metric filters to reduce noise
- Document common Logs Insights queries
- Plan migration path to Prometheus for production

## Implementation Notes

### Container Insights Setup

```yaml
# FluxCD HelmRelease for CloudWatch agent
apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: aws-cloudwatch
  namespace: amazon-cloudwatch
spec:
  interval: 1h
  chart:
    spec:
      chart: aws-cloudwatch-metrics
      sourceRef:
        kind: HelmRepository
        name: eks-charts
        namespace: flux-system
  values:
    clusterName: dev-cluster
```

### Fluent Bit for Logs
```yaml
apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: fluent-bit
  namespace: amazon-cloudwatch
spec:
  interval: 1h
  chart:
    spec:
      chart: aws-for-fluent-bit
      sourceRef:
        kind: HelmRepository
        name: eks-charts
  values:
    cloudWatch:
      region: ca-central-1
      logGroupName: /aws/eks/dev-cluster/containers
      logRetentionDays: 14
```

### IRSA for CloudWatch Agent
```hcl
resource "aws_iam_role" "cloudwatch_agent" {
  name = "${var.prefix}-cloudwatch-agent"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer}:sub" = "system:serviceaccount:amazon-cloudwatch:cloudwatch-agent"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.cloudwatch_agent.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}
```

### Key Metrics to Monitor

| Metric | Source | Alert Threshold |
|--------|--------|-----------------|
| Node CPU | Container Insights | >80% sustained |
| Node Memory | Container Insights | >85% |
| Pod restarts | Container Insights | >3 in 5 min |
| API latency | Custom metric | p99 >500ms |

### Log Groups Structure
```
/aws/eks/dev-cluster/
├── cluster           # Control plane logs (if enabled)
├── containers        # Pod logs via Fluent Bit
└── performance       # Container Insights metrics
```

## Cost Optimization

- **Log retention**: 14 days for dev (reduce from default 365)
- **Metric resolution**: Standard (60s) not high-res (1s)
- **Log filtering**: Exclude noisy logs at Fluent Bit level
- **Disable unused control plane logs**

## Alternatives Considered

### Prometheus + Grafana Stack
Rejected because: Operational overhead of running stateful services, resource costs, overkill for dev environment.

### Datadog/New Relic
Rejected because: Per-host pricing not justified for cost-sensitive dev environment.

### OpenTelemetry + Jaeger
Rejected because: Additional infrastructure to run, complexity not warranted for current scale.

## Migration Path

If production needs require more advanced observability:
1. Deploy Prometheus Operator via FluxCD
2. Add Grafana with CloudWatch datasource (hybrid)
3. Gradually migrate dashboards
4. Consider Thanos for long-term storage

## References

- [Container Insights for EKS](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Container-Insights-setup-EKS-quickstart.html)
- [Fluent Bit on EKS](https://docs.aws.amazon.com/eks/latest/userguide/fargate-logging.html)
- [CloudWatch Pricing](https://aws.amazon.com/cloudwatch/pricing/)
