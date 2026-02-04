# Application Onboarding Guide

This guide explains how to deploy an application to the platform with FortiWeb WAF protection and automatic DNS management.

## Architecture Overview

```
                                    Internet
                                        |
                                        v
                              +------------------+
                              |   Route53 DNS    |
                              | myapp.amerintlxperts.com  |
                              +------------------+
                                        |
                                        v
                              +------------------+
                              |  FortiWeb EIP    |
                              |   3.96.5.206     |
                              +------------------+
                                        |
                                        v
                              +------------------+
                              |    FortiWeb      |
                              | (WAF Appliance)  |
                              | - Virtual Server |
                              | - Server Policy  |
                              | - Content Routes |
                              +------------------+
                                        |
                                        v
                              +------------------+
                              |   EKS Cluster    |
                              | - App Pods       |
                              | - Services       |
                              +------------------+
```

## Components Involved

| Component | Role | Configuration Source |
|-----------|------|---------------------|
| **FortiWebIngress CR** | Declares app routing | `manifests-apps/<app>/fortiwebingress.yaml` |
| **FortiWeb Controller** | Configures FortiWeb WAF | `github.com/amerintlxperts/crds_fortiweb` |
| **FortiWeb Appliance** | WAF + Reverse Proxy | Terraform: `fortiweb.tf` |
| **External-DNS** | Creates Route53 records | Terraform: `external_dns.tf` |
| **DNSEndpoint CRD** | DNS record definition | Created by controller |
| **Application Pods** | Your application | `manifests-apps/<app>/` |

## Onboarding Flow

### Step 1: Create Application Manifests

Create your application's Kubernetes manifests in `manifests-apps/<app-name>/`:

```
manifests-apps/
└── my-app/
    ├── namespace.yaml       # App namespace
    ├── deployment.yaml      # Application pods
    ├── service.yaml         # ClusterIP service (NOT LoadBalancer)
    └── kustomization.yaml   # Kustomize configuration
```

**Key Points:**
- Service must be `ClusterIP` (not LoadBalancer or NodePort)
- No Ingress resource needed - FortiWebIngress handles routing
- Service port can differ from container port (controller resolves targetPort)

**Example `service.yaml`:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app
  namespace: my-app
spec:
  type: ClusterIP
  selector:
    app: my-app
  ports:
    - port: 80           # Service port (used in FortiWebIngress)
      targetPort: 8080   # Container port (resolved by controller)
```

### Step 2: Create FortiWebIngress Resource

Create a FortiWebIngress CR to configure WAF routing and DNS:

**File:** `manifests-apps/my-app/fortiwebingress.yaml`

```yaml
apiVersion: fortiwebingress.io/v1
kind: FortiWebIngress
metadata:
  name: gateway                    # Can be shared across apps or per-app
  namespace: fortiweb-controller   # Controller namespace
spec:
  # FortiWeb connection settings
  fortiweb:
    address: "10.0.10.100:8443"              # FortiWeb private IP
    credentialsSecret: fortiweb-credentials   # Secret with admin creds
    credentialsSecretNamespace: fortiweb-ingress

  # Virtual server configuration
  virtualServer:
    name: gateway
    ip: "10.0.1.100"           # Internal VIP (not used if useInterfaceIP=true)
    interface: port1           # FortiWeb interface facing EKS
    useInterfaceIP: true       # Use interface IP instead of dedicated VIP

  # WAF policy settings
  policy:
    name: gateway-policy
    webProtectionProfile: "Inline Standard Protection"  # FortiWeb WAF profile
    synCookie: "enable"
    httpToHttps: "disable"     # Set to "enable" for HTTPS redirect

  # DNS configuration (creates Route53 records via external-dns)
  dns:
    enabled: true
    target: "3.96.5.206"       # FortiWeb PUBLIC IP (EIP)

  # Application routes
  routes:
    - host: my-app.amerintlxperts.com
      path: /
      backend:
        serviceName: my-app          # Kubernetes service name
        serviceNamespace: my-app     # Kubernetes namespace
        port: 80                     # Service port (NOT container port)
```

### Step 3: Commit and Push

```bash
git add manifests-apps/my-app/
git commit -m "Add my-app deployment"
git push
```

ArgoCD will automatically sync the application manifests.

## What Happens Behind the Scenes

### 1. FortiWeb Controller Reconciliation

**Source:** `github.com/amerintlxperts/crds_fortiweb/controller/main.py`

When the FortiWebIngress CR is created/updated:

```
FortiWebIngress CR Created
         |
         v
+------------------+
| Controller sees  |  <- kopf watches fortiwebingresses.fortiwebingress.io
| CR via watch     |
+------------------+
         |
         v
+------------------+
| Resolve Service  |  <- Looks up Service -> gets targetPort from spec
| Endpoints        |  <- Gets Pod IPs from Endpoints resource
+------------------+
         |
         v
+------------------+
| Configure        |  <- REST API calls to FortiWeb
| FortiWeb         |
+------------------+
         |
         v
+------------------+
| Create           |  <- If dns.enabled=true
| DNSEndpoint      |
+------------------+
```

**Key code sections in `main.py`:**

```python
# Line 63-77: Service port to target port resolution
for svc_port in service.spec.ports or []:
    if svc_port.port == port:
        if isinstance(svc_port.target_port, int):
            target_port = svc_port.target_port
        ...

# Line 167: Create virtual server
result = client.create_virtual_server(vserver_name)

# Line 175: Add VIP to virtual server
vip_result = client.add_vip_to_vserver(...)

# Line 253: Create server policy bound to virtual server
policy_result = client.create_policy(name=policy_name, vserver=vserver_name, ...)

# Line 380-401: Create DNSEndpoint for external-dns
if dns_enabled and dns_target:
    create_dns_endpoint(name=name, namespace=namespace, hostnames=hostnames, ...)
```

### 2. FortiWeb Configuration

The controller creates these FortiWeb objects via REST API:

| FortiWeb Object | API Endpoint | Purpose |
|-----------------|--------------|---------|
| Virtual Server | `/cmdb/server-policy/vserver` | Listener on port1 |
| VIP | `/cmdb/server-policy/vserver/vip-list` | Bind to interface IP |
| Server Pool | `/cmdb/server-policy/server-pool` | Backend pod IPs |
| Pool Members | `/cmdb/server-policy/server-pool/pserver-list` | Pod IP:port entries |
| Content Routing | `/cmdb/server-policy/http-content-routing-policy` | Host-based routing |
| Match Conditions | `/server/httpcontentrouting.matchlist` | Host header matching |
| Server Policy | `/cmdb/server-policy/policy` | Ties it all together |

**Source:** `github.com/amerintlxperts/crds_fortiweb/controller/fortiweb_client.py`

### 3. DNS Record Creation

**Flow:**
```
FortiWeb Controller                External-DNS                    Route53
       |                                |                              |
       | Creates DNSEndpoint            |                              |
       |------------------------------->|                              |
       |                                | Watches DNSEndpoint CRDs     |
       |                                | (--source=crd)               |
       |                                |                              |
       |                                | Creates A record             |
       |                                |----------------------------->|
       |                                |                              |
       |                                | Creates TXT record           |
       |                                | (_externaldns.myapp.amerintlxperts.com)|
       |                                |----------------------------->|
```

**DNSEndpoint created by controller:**
```yaml
apiVersion: externaldns.k8s.io/v1alpha1
kind: DNSEndpoint
metadata:
  name: gateway-dns
  namespace: fortiweb-controller
  ownerReferences:          # Garbage collected when FortiWebIngress deleted
    - apiVersion: fortiwebingress.io/v1
      kind: FortiWebIngress
      name: gateway
spec:
  endpoints:
    - dnsName: myapp.amerintlxperts.com
      recordType: A
      targets:
        - 3.96.5.206        # FortiWeb EIP
      recordTTL: 300
```

**External-DNS configuration:**

**File:** `terraform/environments/dev/external_dns.tf`

```hcl
# Line 58-67: Sources configuration
set {
  name  = "sources[0]"
  value = "ingress"
}

set {
  name  = "sources[1]"
  value = "crd"          # Enables DNSEndpoint watching
}
```

### 4. Traffic Flow (Runtime)

```
Client Request: GET http://myapp.amerintlxperts.com/
         |
         v
+------------------+
| DNS Resolution   |  <- Route53 returns 3.96.5.206
+------------------+
         |
         v
+------------------+
| FortiWeb EIP     |  <- 3.96.5.206 (Elastic IP)
| (Public)         |
+------------------+
         |
         v
+------------------+
| FortiWeb port1   |  <- 10.0.1.100 (Private, in public subnet)
| Virtual Server   |
+------------------+
         |
         v
+------------------+
| Server Policy    |  <- WAF inspection, content routing
| gateway-policy   |
+------------------+
         |
         v
+------------------+
| Content Routing  |  <- Match: Host header = myapp.amerintlxperts.com
| gateway-cr-r0    |
+------------------+
         |
         v
+------------------+
| Server Pool      |  <- Backend: 10.0.10.195:8080 (Pod IP)
| gateway-pool-r0  |
+------------------+
         |
         v
+------------------+
| Pod              |  <- frontend pod in my-app namespace
| 10.0.10.195:8080 |
+------------------+
```

## Key Files Reference

### Infrastructure (Terraform)

| File | Purpose | Key Sections |
|------|---------|--------------|
| `terraform/environments/dev/fortiweb.tf` | FortiWeb EC2 instance | Security groups, EIP, AMI |
| `terraform/environments/dev/external_dns.tf` | External-DNS Helm release | `sources[1] = "crd"` enables DNSEndpoint |
| `terraform/environments/dev/irsa.tf` | IAM roles for external-dns | Route53 permissions |
| `terraform/environments/dev/security_groups.tf` | Network access rules | FortiWeb ingress on port 80/443 |

### FortiWeb Controller

| File | Purpose | Key Sections |
|------|---------|--------------|
| `crds/fortiwebingress.yaml` | CRD definition | spec.dns, spec.routes schema |
| `controller/main.py` | Reconciliation logic | `reconcile_fortiweb_ingress()`, `create_dns_endpoint()` |
| `controller/fortiweb_client.py` | FortiWeb REST API client | `create_policy()`, `add_vip_to_vserver()` |
| `deploy/rbac.yaml` | Controller permissions | `externaldns.k8s.io` permissions |

**Controller Deployment:**

The FortiWeb controller is deployed via Kustomize with a pinned image digest for reproducibility:

**File:** `manifests-platform/resources/fortiweb-controller/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  # Controller deployment from fortiweb_crds repo (pinned to specific commit)
  - https://github.com/<YOUR_ORG>/fortiweb-controller//deploy?ref=5c8deec873aa7715d58bbd512ac9c5d64b0bb45d
  # Local resources
  - certificates.yaml
  - gateway.yaml

# Pin image to specific digest for reproducible deployments
images:
  - name: ghcr.io/<YOUR_ORG>/fortiweb-controller
    digest: sha256:f4c3df732050e8ea8b30890c5f3a0c6491d6d17c5b3c2344ec5a7256a1fad576
```

**Why pinned digests?**
- ArgoCD cannot detect changes when using `:latest` tags (manifest stays identical)
- SHA256 digests ensure exact image version is deployed
- Kustomize `images:` transformer rewrites the tag to `@sha256:...` format

**Note:** Replace `<YOUR_ORG>` with your GitHub organization name.

### Application Manifests

| File | Purpose |
|------|---------|
| `manifests-apps/<app>/namespace.yaml` | App namespace |
| `manifests-apps/<app>/deployment.yaml` | App pods |
| `manifests-apps/<app>/service.yaml` | ClusterIP service |
| `manifests-apps/<app>/fortiwebingress.yaml` | WAF routing + DNS |

## Adding Multiple Applications

For multiple apps, you can either:

### Option A: Shared Gateway (Recommended)

Single FortiWebIngress with multiple routes:

```yaml
spec:
  routes:
    - host: myapp.amerintlxperts.com
      backend:
        serviceName: frontend
        serviceNamespace: my-app
        port: 80
    - host: api.amerintlxperts.com
      backend:
        serviceName: api-server
        serviceNamespace: api
        port: 8080
    - host: admin.amerintlxperts.com
      backend:
        serviceName: admin-ui
        serviceNamespace: admin
        port: 3000
```

**Pros:** Single FortiWeb policy, easier management
**Cons:** All apps share WAF profile

### Option B: Per-App FortiWebIngress

Separate FortiWebIngress per app (different policy names):

```yaml
# App 1
metadata:
  name: shop-gateway
spec:
  policy:
    name: shop-policy
  routes:
    - host: myapp.amerintlxperts.com
      ...

# App 2
metadata:
  name: api-gateway
spec:
  policy:
    name: api-policy
  routes:
    - host: api.amerintlxperts.com
      ...
```

**Pros:** Per-app WAF profiles
**Cons:** Multiple FortiWeb policies to manage

## Troubleshooting

### Check Controller Logs
```bash
kubectl logs -n fortiweb-controller -l app.kubernetes.io/name=fortiweb-controller
```

### Check FortiWebIngress Status
```bash
kubectl get fortiwebingress -n fortiweb-controller -o yaml
```

### Check DNSEndpoint
```bash
kubectl get dnsendpoints -n fortiweb-controller
```

### Check External-DNS Logs
```bash
kubectl logs -n external-dns -l app.kubernetes.io/name=external-dns
```

### Verify DNS Resolution
```bash
dig myapp.amerintlxperts.com +short
# Should return: 3.96.5.206
```

### Test Traffic
```bash
curl -v http://myapp.amerintlxperts.com/
```

## Maintenance

### Updating the FortiWeb Controller

When updating the FortiWeb controller (after fixes or new features), you must update both the commit reference and the image digest in `manifests-platform/resources/fortiweb-controller/kustomization.yaml`.

**Step 1: Make changes and push to fortiweb_crds repo**

```bash
cd /path/to/fortiweb_crds
# Make your changes
git add -A && git commit -m "fix: your change description" && git push
```

**Step 2: Wait for GitHub Actions to build the image**

```bash
# Check build status
gh run list --limit 3

# Wait for completion
gh run watch <RUN_ID> --exit-status
```

**Step 3: Get the new commit SHA and image digest**

```bash
# Get full commit hash
git rev-parse HEAD
# Example: 5c8deec873aa7715d58bbd512ac9c5d64b0bb45d

# Get image digest from build logs
gh run view <RUN_ID> --log 2>&1 | grep -E "pushing manifest.*latest"
# Look for: sha256:f4c3df732050e8ea8b30890c5f3a0c6491d6d17c5b3c2344ec5a7256a1fad576
```

**Step 4: Update kustomization.yaml in infrastructure-2026**

Edit `manifests-platform/resources/fortiweb-controller/kustomization.yaml`:

```yaml
resources:
  # Update the ref= to the new commit SHA
  - https://github.com/<YOUR_ORG>/fortiweb-controller//deploy?ref=<NEW_COMMIT_SHA>
  - certificates.yaml
  - gateway.yaml

images:
  - name: ghcr.io/<YOUR_ORG>/fortiweb-controller
    # Update the digest to the new image SHA
    digest: sha256:<NEW_IMAGE_DIGEST>
```

**Step 5: Commit and push**

```bash
git add -A && git commit -m "chore: update fortiweb-controller to <SHORT_SHA>" && git push
```

ArgoCD will automatically sync and deploy the new controller version.

**Step 6: Trigger reconciliation (if needed)**

If the controller needs to re-apply FortiWeb configuration (e.g., after a certificate upload fix):

```bash
kubectl annotate fortiwebingress gateway -n fortiweb-controller \
  reconcile-trigger="$(date +%s)" --overwrite
```

### Verify Controller Update

```bash
# Check deployed image digest
kubectl get deploy fortiweb-controller -n fortiweb-controller \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
# Should show: ghcr.io/amerintlxperts/crds_fortiweb@sha256:<DIGEST>

# Check pod is running
kubectl get pods -n fortiweb-controller

# Check logs for errors
kubectl logs -n fortiweb-controller -l app.kubernetes.io/name=fortiweb-controller --tail=50
```
