# ADR 003: Use FluxCD with GitHub App Authentication

## Status
Accepted

## Context

We need a GitOps solution to reconcile Kubernetes manifests from GitHub repositories to the EKS cluster. Options considered:

**GitOps Tools**:
1. FluxCD - CNCF graduated project
2. ArgoCD - Popular alternative with UI
3. Jenkins X - CI/CD focused
4. Manual kubectl/Helm deployments

**Authentication Methods**:
1. GitHub App - Fine-grained, per-installation permissions
2. Deploy Keys (SSH) - Per-repository access
3. Personal Access Token - User-scoped access

Requirements:
- Automatic sync from GitHub to cluster
- Support for Helm charts and Kustomize
- Integration with External Secrets Operator
- Minimal operational overhead

## Decision

Use **FluxCD v2** with **GitHub App** authentication.

## Rationale

### Why FluxCD

1. **CNCF Graduated**: Production-ready, active development, strong community
2. **Multi-tenancy native**: Good namespace isolation for future growth
3. **Helm + Kustomize**: First-class support for both
4. **No UI required**: Operates headlessly, status via kubectl/CLI
5. **Notification support**: Slack, Teams, webhook alerts built-in
6. **Image automation**: Can auto-update image tags from registries

### Why not ArgoCD

- Requires running a web UI (resource overhead, security surface)
- More complex RBAC model
- Better suited for teams wanting visual deployment management
- For a cost-minimized dev environment, FluxCD is leaner

### Why GitHub App Authentication

1. **Fine-grained permissions**: Read-only to specific repos, no org-wide access
2. **Rotatable credentials**: App tokens can be regenerated without cluster changes
3. **Organization-friendly**: Standard pattern for amerintlxperts org
4. **Audit trail**: GitHub logs show app access separately from user access
5. **No user dependency**: Not tied to individual developer accounts

### Why not Deploy Keys

- Per-repository management burden
- Less visibility in audit logs
- Key rotation more manual

### Why not PAT

- Tied to user account (bus factor)
- Broad permissions hard to scope
- Expires with user, requires rotation

## Consequences

### Positive
- Clean separation between human and machine access
- Easy to revoke/rotate app credentials
- FluxCD's `flux bootstrap github` command supports GitHub Apps directly
- Consistent pattern for org-wide automation

### Negative
- Must create and manage GitHub App in org settings
- Slightly more setup than deploy key
- App installation permissions require org admin

### Mitigations
- Document GitHub App creation in implementation guide
- Store app private key in AWS Secrets Manager
- Use External Secrets to sync key to cluster

## Implementation Notes

### GitHub App Setup
1. Create GitHub App in amerintlxperts org settings
2. Permissions needed:
   - Repository contents: Read
   - Repository metadata: Read
3. Install app on target repositories
4. Generate and store private key in Secrets Manager

### FluxCD Bootstrap
```bash
# Bootstrap with GitHub App
flux bootstrap github \
  --owner=amerintlxperts \
  --repository=gitops-manifests \
  --path=clusters/dev \
  --github-app-id=${APP_ID} \
  --github-app-installation-id=${INSTALLATION_ID} \
  --github-app-private-key-path=/path/to/private-key.pem
```

### Repository Structure (gitops-manifests)
```
clusters/
  dev/
    flux-system/        # FluxCD components
    infrastructure/     # Cluster-wide resources
    apps/               # Application deployments
```

## Alternatives Considered

### ArgoCD
Rejected because: UI overhead unnecessary for dev environment, more complex than needed for single environment.

### Deploy Keys
Rejected because: Per-repo management burden, less audit visibility, harder rotation.

### Personal Access Token
Rejected because: Tied to user account, bus factor risk, broad permissions.

## References

- [FluxCD Documentation](https://fluxcd.io/docs/)
- [GitHub Apps](https://docs.github.com/en/apps/creating-github-apps)
- [FluxCD GitHub Bootstrap](https://fluxcd.io/flux/installation/bootstrap/github/)
