# ADR 006: Use Fortinet FortiWeb as Ingress Controller

## Status
Accepted

## Context

External traffic needs to reach services running in EKS. Standard options include:

1. **AWS ALB Ingress Controller** - AWS-native, integrates with WAF/Shield
2. **Nginx Ingress Controller** - Community standard, portable
3. **Traefik** - Modern, auto-discovery, GitOps-friendly
4. **Fortinet FortiWeb** - Enterprise WAF with Kubernetes integration

The organization has standardized on Fortinet for network security.

## Decision

Use **Fortinet FortiWeb** as the ingress controller and web application firewall.

## Rationale

### Why FortiWeb

1. **Organizational standard**: Consistent with existing network security infrastructure
2. **Integrated WAF**: Application-layer protection built into ingress
3. **Compliance**: May be required for certain regulatory frameworks
4. **Centralized management**: FortiManager integration for policy consistency
5. **Advanced threat protection**: ML-based bot detection, API protection

### Trade-offs Accepted

- More complex deployment than standard ingress controllers
- Requires FortiWeb license and expertise
- Less community documentation compared to Nginx/ALB
- Vendor lock-in for ingress layer

### Comparison with Alternatives

| Feature | FortiWeb | ALB Controller | Nginx |
|---------|----------|----------------|-------|
| WAF Integration | Built-in | AWS WAF (separate) | ModSecurity (addon) |
| Org Standard | Yes | No | No |
| Setup Complexity | High | Medium | Low |
| Cost | License | Usage-based | Free (compute) |
| Portability | FortiWeb-specific | AWS-only | Highly portable |

## Consequences

### Positive
- Unified security platform with existing Fortinet infrastructure
- Single pane of glass for security policies
- Advanced WAF features without additional components
- Potential FortiGate integration for network segmentation

### Negative
- Steeper learning curve for Kubernetes team
- License cost overhead
- Dependent on Fortinet-specific documentation
- Ingress manifests may use custom annotations

### Mitigations
- Document FortiWeb-specific ingress patterns
- Create reusable ingress templates
- Train team on FortiWeb Kubernetes integration
- Maintain fallback to ALB for emergencies

## Implementation Notes

### Deployment Options

1. **FortiWeb as Service (SaaS)** - Cloud-managed, routes traffic to cluster
2. **FortiWeb VM in VPC** - Self-managed VM, more control
3. **FortiWeb Container** - Runs in cluster as ingress (requires Kubernetes operator)

### Integration Pattern (VM-based)
```
Internet → FortiWeb VM → NLB → K8s Service (NodePort/LoadBalancer)
```

### Ingress Example
```yaml
# FortiWeb-specific ingress annotations
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-ingress
  annotations:
    # FortiWeb-specific annotations (consult FortiWeb K8s docs)
    fortiweb.fortinet.com/policy: "standard-waf"
    fortiweb.fortinet.com/ssl-profile: "tls-1-2"
spec:
  ingressClassName: fortiweb
  rules:
    - host: app.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: app-service
                port:
                  number: 80
```

### Architecture Considerations

- FortiWeb needs network path to EKS nodes
- Consider placement in public subnet with routes to private node subnets
- SSL termination at FortiWeb, clear text to cluster (or re-encrypt)
- Health check endpoints must be accessible

## Alternatives Considered

### AWS ALB Ingress Controller
Not selected because: Organization has standardized on Fortinet for web application firewall capabilities.

### Nginx Ingress Controller
Not selected because: Would require additional WAF solution, not aligned with organizational standards.

### Traefik
Not selected because: Good for GitOps but doesn't provide the enterprise WAF features required.

## References

- [FortiWeb Kubernetes Integration](https://docs.fortinet.com/product/fortiweb)
- [FortiWeb Ingress Controller](https://github.com/fortinet/fortiweb-ingress)
- [AWS ALB Controller (for reference)](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)

## Open Questions

- [ ] Confirm FortiWeb deployment model (SaaS vs VM vs Container)
- [ ] Identify FortiWeb version and license type available
- [ ] Determine SSL certificate management approach
- [ ] Establish FortiManager integration requirements
