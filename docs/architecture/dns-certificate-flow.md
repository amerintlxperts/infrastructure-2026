# DNS and Certificate Architecture Flow

This document explains how DNS resolution and TLS certificate issuance work in the platform, including which manifests and Terraform resources are involved at each stage.

## Architecture Overview

```
                                    Internet
                                        │
                                        ▼
                              ┌─────────────────┐
                              │    GoDaddy      │
                              │  (Registrar)    │
                              │                 │
                              │ NS → Route53    │
                              │ Delegation Set  │
                              └────────┬────────┘
                                       │
                                       ▼
                              ┌─────────────────┐
                              │    Route53      │
                              │  Hosted Zone    │
                              │                 │
                              │ amerintlxperts.com A    │
                              │  → FortiWeb EIP │
                              │ myapp.* CNAME    │
                              │  → amerintlxperts.com   │
                              │ TXT → ACME      │
                              └────────┬────────┘
                                       │
                                       ▼
                              ┌─────────────────┐
                              │    FortiWeb     │
                              │   (VIP: 10.0.1.100)
                              │                 │
                              │ TLS Termination │
                              │ WAF Protection  │
                              └────────┬────────┘
                                       │
                                       ▼
                              ┌─────────────────┐
                              │  Gateway Ingress│
                              │                 │
                              │ Host Routing:   │
                              │ myapp.amerintlxperts.com │
                              │ xperts.amerintlxperts.com│
                              └────────┬────────┘
                                       │
                          ┌────────────┴────────────┐
                          ▼                         ▼
                 ┌─────────────────┐      ┌─────────────────┐
                 │ my-app │      │     xperts      │
                 │   namespace     │      │   namespace     │
                 └─────────────────┘      └─────────────────┘
```

---

## Stage 1: DNS Infrastructure (Terraform)

### What Happens
Route53 hosted zone is created with a reusable delegation set for consistent nameservers across destroy/recreate cycles.

### Resources Involved

| Resource | File | Purpose |
|----------|------|---------|
| `aws_route53_zone.main` | `terraform/environments/dev/route53.tf` | Creates the hosted zone for `amerintlxperts.com` |
| Delegation Set | `bootstrap/hydrate.sh` | Ensures nameservers don't change on zone recreation |

### Flow
```
1. hydrate.sh creates reusable delegation set (one-time)
2. Terraform creates Route53 zone using that delegation set
3. User configures GoDaddy NS records to point to delegation set nameservers
```

---

## Stage 2: External-DNS Controller (ArgoCD + Terraform)

### What Happens
External-DNS watches Ingress resources and creates/updates Route53 A records automatically.

### Resources Involved

| Resource | File | Purpose |
|----------|------|---------|
| IRSA Role | `terraform/environments/dev/irsa.tf` | `aws_iam_role.external_dns` - Route53 write permissions |
| Helm Release | `terraform/environments/dev/external_dns.tf` | Deploys external-dns with IRSA annotation |
| Ingress Annotation | `manifests-platform/gateway/ingress.yaml` | `external-dns.alpha.kubernetes.io/hostname` triggers record creation |

### Flow
```
1. Terraform creates IRSA role with Route53 permissions
2. Terraform deploys external-dns Helm chart with IRSA annotation
3. Terraform creates apex A record: amerintlxperts.com → FortiWeb EIP (public IP)
4. external-dns watches Ingress resources
5. When gateway ingress is created, external-dns reads hostname/target annotations
6. external-dns creates CNAME: myapp.amerintlxperts.com → amerintlxperts.com
7. Traffic resolves: myapp.amerintlxperts.com → CNAME → amerintlxperts.com → A → FortiWeb EIP
```

### Key Annotation
```yaml
# manifests-platform/gateway/ingress.yaml
metadata:
  annotations:
    external-dns.alpha.kubernetes.io/hostname: "myapp.amerintlxperts.com,xperts.amerintlxperts.com"
```

---

## Stage 3: Cert-Manager Installation (Terraform)

### What Happens
Cert-manager is deployed via Terraform (not ArgoCD) to inject the IRSA role ARN for Route53 access.

### Resources Involved

| Resource | File | Purpose |
|----------|------|---------|
| IRSA Role | `terraform/environments/dev/irsa.tf` | `aws_iam_role.cert_manager` - Route53 TXT record permissions |
| Helm Release | `terraform/environments/dev/cert_manager.tf` | Deploys cert-manager with IRSA annotation |

### Why Terraform Instead of ArgoCD?
The IRSA role ARN contains the AWS account ID. Deploying via Terraform keeps the account ID out of git manifests.

### Flow
```
1. Terraform creates IRSA role with Route53 permissions for DNS-01 challenges
2. Terraform deploys cert-manager Helm chart
3. ServiceAccount is annotated with IRSA role ARN
4. cert-manager pods can now create Route53 TXT records
```

---

## Stage 4: ClusterIssuer Configuration (ArgoCD)

### What Happens
ClusterIssuers define how certificates are obtained from Let's Encrypt using DNS-01 challenges.

### Resources Involved

| Resource | File | Purpose |
|----------|------|---------|
| ClusterIssuer | `manifests-platform/resources/cert-manager/cluster-issuers.yaml` | Defines letsencrypt-staging and letsencrypt-prod issuers |
| ArgoCD App | `manifests-platform/argocd/platform-resources.yaml` | Syncs the ClusterIssuers to the cluster |

### Why DNS-01 Instead of HTTP-01?
HTTP-01 challenges require a temporary ingress to serve the ACME token. With FortiWeb, each ingress creates a virtual server, and multiple virtual servers can't bind to the same IP:port. DNS-01 avoids this by using Route53 TXT records instead.

### ClusterIssuer Configuration
```yaml
# manifests-platform/resources/cert-manager/cluster-issuers.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    email: ajammes@fortinet.com
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
      - dns01:
          route53:
            region: ca-central-1
```

---

## Stage 5: Certificate Request (ArgoCD)

### What Happens
Certificate resources request TLS certificates from Let's Encrypt. The certificate is stored in the `fortiweb-ingress` namespace for use by the gateway ingress.

### Resources Involved

| Resource | File | Purpose |
|----------|------|---------|
| Certificate | `manifests-platform/gateway/certificates.yaml` | Requests xperts.amerintlxperts.com certificate |
| ArgoCD App | `manifests-platform/argocd/gateway.yaml` | Syncs the Certificate to the cluster |

### Certificate Configuration
```yaml
# manifests-platform/gateway/certificates.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: xperts-tls
  namespace: fortiweb-ingress
spec:
  secretName: xperts-tls
  dnsNames:
    - xperts.amerintlxperts.com
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
```

### Flow
```
1. ArgoCD syncs Certificate resource to cluster
2. cert-manager sees new Certificate, creates CertificateRequest
3. cert-manager creates Order with Let's Encrypt
4. Let's Encrypt returns Challenge (prove you own the domain)
5. cert-manager creates Route53 TXT record: _acme-challenge.xperts.amerintlxperts.com
6. Let's Encrypt verifies TXT record exists
7. Let's Encrypt issues certificate
8. cert-manager stores certificate in Secret: xperts-tls
9. cert-manager deletes TXT record
```

---

## Stage 6: Gateway Ingress (ArgoCD)

### What Happens
The gateway ingress provides centralized routing for all applications. FortiWeb terminates TLS using the certificate from the Secret.

### Resources Involved

| Resource | File | Purpose |
|----------|------|---------|
| Ingress | `manifests-platform/gateway/ingress.yaml` | Single ingress with all host rules |
| ExternalName Services | `manifests-platform/gateway/externalname-services.yaml` | Routes to app namespaces |
| ArgoCD App | `manifests-platform/argocd/gateway.yaml` | Syncs gateway resources (wave 4) |

### Why a Centralized Gateway?
FortiWeb Ingress Controller creates one virtual server per Ingress. Multiple virtual servers can't bind to the same IP:port (10.0.1.100:443). By using a single gateway ingress, all apps share one virtual server with host-based routing.

### IP Address Distinction
- **FortiWeb EIP** (e.g., 3.x.x.x) - Public Elastic IP, what DNS points to, receives internet traffic
- **VIP 10.0.1.100** - Private IP on port1 interface, where FortiWeb IC binds the virtual server internally
- Traffic flow: Internet → EIP → FortiWeb → VIP virtual server → backend pods

### Gateway Ingress Configuration
```yaml
# manifests-platform/gateway/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: gateway
  namespace: fortiweb-ingress
  annotations:
    # FortiWeb virtual server config
    virtual-server-ip: "10.0.1.100"
    virtual-server-interface: "port1"
    # TLS certificate chain for FortiWeb
    server-policy-intermediate-certificate-group: "fortiweb-ingress_gateway_ca-group"
    # DNS record creation
    external-dns.alpha.kubernetes.io/hostname: "myapp.amerintlxperts.com,xperts.amerintlxperts.com"
spec:
  ingressClassName: fwb-ingress-controller
  tls:
    - hosts:
        - xperts.amerintlxperts.com
      secretName: xperts-tls
  rules:
    - host: myapp.amerintlxperts.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app-frontend
                port:
                  number: 80
    - host: xperts.amerintlxperts.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: xperts-backend
                port:
                  number: 8080
```

### ExternalName Services
```yaml
# manifests-platform/gateway/externalname-services.yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app-frontend
  namespace: fortiweb-ingress
spec:
  type: ExternalName
  externalName: frontend.my-app.svc.cluster.local
---
apiVersion: v1
kind: Service
metadata:
  name: xperts-backend
  namespace: fortiweb-ingress
spec:
  type: ExternalName
  externalName: xperts.xperts.svc.cluster.local
```

---

## Stage 7: Intermediate Certificate Upload (ArgoCD)

### What Happens
FortiWeb needs the Let's Encrypt intermediate certificate to complete the TLS chain. A Kubernetes Job downloads and uploads it to FortiWeb.

### Resources Involved

| Resource | File | Purpose |
|----------|------|---------|
| Job | `manifests-apps/xperts-dependencies/job.yaml` | Downloads intermediate cert, uploads to FortiWeb |
| RBAC | `manifests-apps/xperts-dependencies/rbac.yaml` | Allows job to read secrets from fortiweb-ingress namespace |
| ArgoCD App | `manifests-platform/argocd/xperts-dependencies.yaml` | Syncs job (wave 3, before gateway) |

### Why This Is Needed
Let's Encrypt certificates are signed by an intermediate CA. Browsers need the full chain (leaf + intermediate) to validate. FortiWeb must have the intermediate certificate configured in a "certificate group" referenced by the ingress annotation.

### Job Flow
```
1. Job waits for xperts-tls secret to be populated (certificate issued)
2. Job extracts the certificate from the secret
3. Job parses "CA Issuers" URL from certificate
4. Job downloads intermediate certificate from Let's Encrypt
5. Job uploads intermediate to FortiWeb via API
6. Job creates certificate group: fortiweb-ingress_gateway_ca-group
7. Job adds intermediate to the group
8. Gateway ingress references this group in annotation
```

---

## Complete Request Flow

When a user visits `https://xperts.amerintlxperts.com`:

```
1. DNS Resolution
   └── Browser queries xperts.amerintlxperts.com
   └── GoDaddy NS → Route53 delegation set nameservers
   └── Route53 returns CNAME: xperts.amerintlxperts.com → amerintlxperts.com
   └── Route53 returns A record: amerintlxperts.com → FortiWeb EIP (public IP)

2. TLS Handshake
   └── Browser connects to FortiWeb:443
   └── FortiWeb presents xperts-tls certificate + intermediate chain
   └── Browser validates chain up to Let's Encrypt root CA

3. HTTP Request
   └── FortiWeb terminates TLS, applies WAF rules
   └── FortiWeb forwards to gateway ingress
   └── Ingress matches host: xperts.amerintlxperts.com
   └── Routes to ExternalName service: xperts-backend

4. Backend Routing
   └── ExternalName resolves to xperts.xperts.svc.cluster.local
   └── kube-proxy routes to xperts pod in xperts namespace
   └── Response flows back through FortiWeb to browser
```

---

## Sync Wave Order

Resources are deployed in order using ArgoCD sync waves:

| Wave | Component | File | Purpose |
|------|-----------|------|---------|
| - | cert-manager | `terraform/environments/dev/cert_manager.tf` | Terraform deploys before ArgoCD |
| 1 | reloader | `manifests-platform/argocd/reloader.yaml` | Restarts pods on secret changes |
| 2 | platform-resources | `manifests-platform/argocd/platform-resources.yaml` | ClusterIssuers, ClusterSecretStore |
| 3 | fortiweb-ingress | `manifests-platform/argocd/fortiweb-ingress.yaml` | FortiWeb Ingress Controller |
| 3 | xperts-dependencies | `manifests-platform/argocd/xperts-dependencies.yaml` | Intermediate cert job |
| 4 | gateway | `manifests-platform/argocd/gateway.yaml` | Centralized ingress + certificates |
| 4 | xperts | `manifests-platform/argocd/xperts.yaml` | Application deployment |
| 10 | applications | `manifests-platform/argocd/applications.yaml` | App-of-apps for manifests-apps/ |

---

## Troubleshooting

### Certificate Not Issuing
```bash
# Check certificate status
kubectl get certificate -n fortiweb-ingress

# Check certificate request
kubectl get certificaterequest -n fortiweb-ingress

# Check ACME challenges
kubectl get challenges -A

# Check cert-manager logs
kubectl logs -n cert-manager deployment/cert-manager
```

### DNS Not Resolving
```bash
# Check Route53 records
aws route53 list-resource-record-sets --hosted-zone-id <ZONE_ID>

# Check external-dns logs
kubectl logs -n external-dns deployment/external-dns

# Verify from internet
dig xperts.amerintlxperts.com
```

### FortiWeb TLS Issues
```bash
# Check if certificate secret exists
kubectl get secret xperts-tls -n fortiweb-ingress

# Check intermediate cert job
kubectl logs -n xperts job/xperts-cert-setup

# Verify FortiWeb has the intermediate cert (via FortiWeb GUI)
# System > Certificates > Intermediate CA
```
