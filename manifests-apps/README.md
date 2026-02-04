# Application Manifests

This directory contains Kubernetes manifests for applications deployed via ArgoCD GitOps.

## Directory Structure

```
manifests-apps/
├── README.md              # This file
├── kustomization.yaml     # Root kustomization (lists all apps)
└── <app-name>/            # One directory per application
    ├── kustomization.yaml
    ├── deployment.yaml
    ├── service.yaml
    └── ingress.yaml       # With external-dns annotations
```

## Deploying a New Application

1. Create a directory for your app:
   ```bash
   mkdir manifests-apps/my-app
   ```

2. Add your Kubernetes manifests (deployment, service, etc.)

3. Create an Ingress with the required annotations (see below)

4. Add your app to the root `kustomization.yaml`:
   ```yaml
   resources:
     - my-app  # Add this
   ```

5. Commit and push - ArgoCD will sync automatically

## Ingress Configuration

### External-DNS Annotations (Required for public DNS)

External-DNS watches Ingress resources and creates Route53 DNS records automatically.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  annotations:
    # External-DNS annotations
    external-dns.alpha.kubernetes.io/hostname: myapp.amerintlxperts.com  # DNS name to create
    external-dns.alpha.kubernetes.io/target: amerintlxperts.com          # Points to FortiWeb EIP
    external-dns.alpha.kubernetes.io/ttl: "300"                          # TTL in seconds
```

**Important:** The `target` annotation is required because FortiWeb IC reports its private IP in the Ingress status. Without it, external-dns would create records pointing to the wrong IP.

### FortiWeb IC Annotations (Required for routing)

FortiWeb Ingress Controller configures the FortiWeb appliance to route traffic.

```yaml
annotations:
  # FortiWeb API connection
  fortiweb-ip: "10.0.10.100"           # FortiWeb management IP (fixed)
  fortiweb-port: "8443"
  fortiweb-login: "fortiweb-credentials"
  fortiweb-ctrl-log: "enable"

  # Virtual server configuration
  virtual-server-ip: "10.0.1.100"      # FortiWeb traffic IP (fixed)
  virtual-server-addr-type: "ipv4"
  virtual-server-interface: "port1"
  virtual-server-use-intf-ip: "port1"

  # Server policy
  server-policy-http-service: "HTTP"
  server-policy-https-service: "HTTPS"
  server-policy-syn-cookie: "enable"
  server-policy-http-to-https: "disable"
  server-policy-web-protection-profile: "Inline Standard Protection"
```

### Complete Ingress Example

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  namespace: my-app
  annotations:
    # External-DNS
    external-dns.alpha.kubernetes.io/hostname: myapp.amerintlxperts.com
    external-dns.alpha.kubernetes.io/target: amerintlxperts.com
    external-dns.alpha.kubernetes.io/ttl: "300"
    # FortiWeb IC
    fortiweb-ip: "10.0.10.100"
    fortiweb-port: "8443"
    fortiweb-login: "fortiweb-credentials"
    fortiweb-ctrl-log: "enable"
    virtual-server-ip: "10.0.1.100"
    virtual-server-addr-type: "ipv4"
    virtual-server-interface: "port1"
    virtual-server-use-intf-ip: "port1"
    server-policy-http-service: "HTTP"
    server-policy-https-service: "HTTPS"
    server-policy-syn-cookie: "enable"
    server-policy-http-to-https: "disable"
    server-policy-web-protection-profile: "Inline Standard Protection"
spec:
  ingressClassName: fwb-ingress-controller
  rules:
    - host: myapp.amerintlxperts.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 80
```

## DNS Flow

```
User visits myapp.amerintlxperts.com
        │
        ▼
Route53 (external-dns created this)
  myapp.amerintlxperts.com CNAME → amerintlxperts.com
  amerintlxperts.com A → FortiWeb EIP
        │
        ▼
FortiWeb (FortiWeb IC configured this)
  Receives traffic on EIP
  Routes based on Host header to EKS pods
        │
        ▼
Kubernetes Service → Pods
```

## TLS/HTTPS

FortiWeb handles TLS termination and can automatically obtain Let's Encrypt certificates via ACME HTTP-01 challenge. Configure this in FortiWeb, not in the Ingress manifest.
