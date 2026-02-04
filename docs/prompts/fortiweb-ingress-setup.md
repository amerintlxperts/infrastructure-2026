# FortiWeb Ingress Setup Guide

This guide explains how FortiWeb ingress works end-to-end and provides a complete post-deployment setup and troubleshooting guide.

---

## Architecture Overview

```
Internet → Route53 (DNS) → FortiWeb EIP → FortiWeb VM (WAF) → EKS Pods
                                              ↑
                                              │ REST API
                                              │
                           FortiWeb Ingress Controller (in kube-system)
                                              │
                                              │ watches
                                              ↓
                                    Kubernetes Ingress Resources
```

---

## How It Works (Step by Step)

### 1. Infrastructure Deployment (Terraform)
- FortiWeb VM deployed in public subnet with Elastic IP
- Security groups allow: 80/443 from internet, 8443/22 from admin IP
- FortiWeb can reach EKS nodes on all TCP ports

### 2. Credential Setup (Manual)
- Admin logs into FortiWeb GUI (`https://<EIP>:8443`) with default creds (`admin/<instance-id>`)
- Changes admin password
- Creates API user for ingress controller
- Stores credentials in AWS Secrets Manager at `dev/fortiweb`

### 3. Credential Sync (External Secrets Operator)
- ExternalSecret syncs `dev/fortiweb` → K8s Secret `fortiweb-credentials` in `kube-system`
- Refresh interval: 1 hour

### 4. Ingress Controller Deployment (ArgoCD sync wave 3)
- Helm chart `fwb-k8s-ctrl` deployed to `kube-system`
- Reads credentials from `fortiweb-credentials` secret
- Starts watching for Ingress resources with class `fortiweb`

### 5. Application Ingress Created
- Developer creates Ingress resource with `kubernetes.io/ingress.class: fortiweb`
- **Must include FortiWeb-specific annotations** (IP, port, VIP, etc.)

### 6. Controller Configures FortiWeb
- Controller detects new Ingress
- Calls FortiWeb REST API to create:
  - Virtual Server (VIP)
  - Server Pool (pointing to pod IPs)
  - Server Policy (WAF protection profile)
  - Content Routing rules

### 7. Traffic Flows
- User → DNS → FortiWeb EIP → WAF inspection → Pod IP

---

## Post-Deployment Setup

### Phase 1: Get FortiWeb Access Info

```bash
# Get FortiWeb IPs
cd terraform/environments/dev
terraform output fortiweb_public_ip    # For management GUI and DNS
terraform output fortiweb_private_ip   # For ingress controller config
terraform output fortiweb_mgmt_url     # Management URL

# Get default password (instance ID)
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=xperts-dev-fortiweb" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text
```

### Phase 2: Configure FortiWeb (GUI)

1. **Access GUI**: `https://<fortiweb_public_ip>:8443`
2. **Login**: `admin` / `<instance-id>`
3. **Change Admin Password**:
   - System → Admin → Administrators → admin → Edit
   - Set strong password
4. **Enable REST API**:
   - System → Admin → Settings
   - Enable "REST API Access"
   - Note the API port (usually 443 or 8443)
5. **Create API User** (for ingress controller):
   - System → Admin → Administrators → Create New
   - Username: `api-user` (or similar)
   - Password: strong password
   - Access Profile: Full access or custom profile with API permissions
   - Enable "REST API Access" for this user

### Phase 3: Update AWS Secrets Manager

```bash
# Update with the API user credentials you just created
aws secretsmanager put-secret-value \
  --secret-id dev/fortiweb \
  --secret-string '{"username":"api-user","password":"YOUR_API_PASSWORD"}'
```

### Phase 4: Verify Kubernetes Integration

```bash
# Configure kubectl
aws eks update-kubeconfig --region ca-central-1 --name xperts-dev

# Wait for External Secrets to sync (or force it)
kubectl get externalsecret -n kube-system
kubectl delete secret fortiweb-credentials -n kube-system  # Forces re-sync

# Check ingress controller pod
kubectl get pods -n kube-system -l app.kubernetes.io/name=fwb-k8s-ctrl
kubectl logs -n kube-system -l app.kubernetes.io/name=fwb-k8s-ctrl
```

---

## Creating Ingress Resources

### Required Annotations

Ingress resources need FortiWeb-specific annotations:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  namespace: my-namespace
  annotations:
    kubernetes.io/ingress.class: fortiweb
    # FortiWeb connection settings (required)
    fortiweb-ip: "<FORTIWEB_PRIVATE_IP>"      # From terraform output
    fortiweb-port: "443"
    fortiweb-ctrl-log: "enable"
    # Virtual server configuration (required)
    virtual-server-ip: "<FORTIWEB_PUBLIC_IP>" # EIP for external traffic
    virtual-server-addr-type: "ipv4"
    virtual-server-interface: "port1"
    # Security policy
    server-policy-web-protection-profile: "Inline Standard Protection"
spec:
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-service
                port:
                  number: 80
```

### Annotation Reference

| Annotation | Required | Description |
|------------|----------|-------------|
| `kubernetes.io/ingress.class` | Yes | Must be `fortiweb` |
| `fortiweb-ip` | Yes | FortiWeb private IP (for API calls) |
| `fortiweb-port` | Yes | API port (usually `443`) |
| `virtual-server-ip` | Yes | FortiWeb public EIP (for external traffic) |
| `virtual-server-addr-type` | Yes | Usually `ipv4` |
| `virtual-server-interface` | No | Network interface (default: `port1`) |
| `server-policy-web-protection-profile` | No | WAF profile name |
| `fortiweb-ctrl-log` | No | Enable logging (`enable`/`disable`) |

---

## Troubleshooting

### Verify Infrastructure

```bash
# Check FortiWeb is running
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=xperts-dev-fortiweb" \
  --query 'Reservations[0].Instances[0].[State.Name,PublicIpAddress,PrivateIpAddress]'

# Test FortiWeb management access
curl -k https://<public_ip>:8443
```

### Verify Kubernetes Resources

```bash
# Check ingress controller is running
kubectl get pods -n kube-system -l app.kubernetes.io/name=fwb-k8s-ctrl

# Check controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=fwb-k8s-ctrl

# Verify credentials secret exists
kubectl get secret fortiweb-credentials -n kube-system

# Check ExternalSecret status
kubectl get externalsecret -n kube-system

# Check Ingress resources
kubectl get ingress -A
```

### Common Issues

| Symptom | Likely Cause | Solution |
|---------|--------------|----------|
| Controller pod CrashLoopBackOff | Bad credentials | Check `fortiweb-credentials` secret matches FortiWeb API user |
| Controller logs: "connection refused" | REST API not enabled | Enable in FortiWeb GUI: System → Admin → Settings |
| Controller logs: "401 unauthorized" | Wrong credentials | Update AWS Secrets Manager + delete K8s secret to force sync |
| No virtual server in FortiWeb | Missing annotations | Add `fortiweb-ip`, `virtual-server-ip` annotations to Ingress |
| 502 Bad Gateway | Pods not reachable | Check security groups allow FortiWeb → EKS nodes |
| Timeout accessing app | Wrong VIP | Ensure `virtual-server-ip` is the FortiWeb EIP |

---

## Critical Files

| File | Purpose |
|------|---------|
| `terraform/environments/dev/fortiweb.tf` | FortiWeb infrastructure |
| `terraform/environments/dev/_outputs.tf` | Get FortiWeb IPs |
| `manifests-platform/argocd/fortiweb-ingress.yaml` | Controller deployment |
| `manifests-platform/resources/external-secrets/fortiweb-credentials.yaml` | Credentials sync |
| `manifests-apps/*/ingress.yaml` | Application ingress with FortiWeb annotations |

---

## Summary: What Happens

1. **Terraform deploys** FortiWeb VM with EIP (automated)
2. **You configure FortiWeb** via GUI (manual - change password, enable API, create API user)
3. **You update Secrets Manager** with API credentials (manual)
4. **External Secrets syncs** credentials to K8s (automated)
5. **Ingress controller connects** to FortiWeb API (automated)
6. **You create Ingress** with proper annotations (manual)
7. **Controller configures FortiWeb** with virtual server/pool (automated)
8. **Traffic flows** Internet → FortiWeb → Pods (automated)
