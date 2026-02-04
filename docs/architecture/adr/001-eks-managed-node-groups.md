# ADR 001: Use EKS Managed Node Groups

## Status
Accepted

## Context

We need to decide how to provision compute capacity for our EKS cluster. The main options are:

1. **Managed Node Groups** - AWS-managed EC2 Auto Scaling groups
2. **Self-managed nodes** - DIY EC2 instances with EKS bootstrap
3. **Fargate** - Serverless, per-pod billing
4. **Karpenter** - Open-source autoscaler with just-in-time provisioning

Our workloads include:
- Web applications
- Lambda-style functions (long-running containers)
- ML embedding models
- Future SageMaker integration

We have a cost-minimization priority and a small team with limited Kubernetes operational experience.

## Decision

Use **EKS Managed Node Groups** as the primary compute strategy.

## Rationale

### Why Managed Node Groups

1. **Operational simplicity**: AWS handles AMI updates, node draining during upgrades, and Auto Scaling group lifecycle
2. **Cost predictability**: EC2 pricing is well-understood, Spot instances supported for savings
3. **Flexibility**: Can run any workload type including DaemonSets, stateful apps, and custom networking
4. **GPU support**: Can add GPU node groups later for ML inference without architectural changes
5. **Proven reliability**: Most common EKS deployment pattern, extensive documentation

### Why not Fargate

- Cannot run DaemonSets (needed for monitoring agents, log collectors)
- No persistent volume support via EBS
- Higher per-vCPU cost for sustained workloads
- Limited to specific pod configurations
- FortiWeb ingress controller likely requires node access

### Why not Karpenter

- Higher operational complexity
- Requires understanding of provisioners, node templates, consolidation
- Better suited for highly variable workloads
- Overkill for a 1-2 node development environment
- Can migrate to Karpenter later if scaling needs increase

### Why not Self-managed

- Significant operational burden (AMI management, bootstrap scripts)
- No benefit over managed for our use case
- Higher risk of misconfiguration

## Consequences

### Positive
- Simple deployment and maintenance
- AWS handles security patching for node OS
- Easy to add specialized node groups (GPU, ARM) later
- Good integration with Cluster Autoscaler if needed

### Negative
- Less flexibility than self-managed for custom AMIs
- Slightly slower scaling than Karpenter
- Must pre-define instance types (vs Karpenter's flexibility)

### Mitigations
- Use multiple instance types in node group for availability
- Configure appropriate scaling policies
- Document path to Karpenter migration if needed

## Alternatives Considered

### Fargate
Rejected because: Cannot run DaemonSets, no EBS support, higher cost for sustained workloads, ingress controller compatibility concerns.

### Karpenter
Rejected because: Over-engineering for a 1-2 node dev environment. Will reconsider when scaling to production or if workload patterns become highly variable.

### Self-managed Nodes
Rejected because: Unnecessary operational burden with no benefits for our use case.

## References

- [EKS Node Groups Documentation](https://docs.aws.amazon.com/eks/latest/userguide/managed-node-groups.html)
- [Karpenter vs Cluster Autoscaler](https://karpenter.sh/docs/concepts/nodepools/)
- [Fargate Considerations](https://docs.aws.amazon.com/eks/latest/userguide/fargate.html)
