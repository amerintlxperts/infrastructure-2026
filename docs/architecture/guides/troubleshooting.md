# Troubleshooting Guide

Common issues and solutions for the EKS GitOps platform.

## FluxCD Issues

### Reconciliation Stuck

**Symptoms**: Kustomization shows "progressing" indefinitely

**Diagnosis**:
```bash
# Check Kustomization status
flux get kustomizations

# View detailed events
kubectl describe kustomization APP_NAME -n flux-system

# Check controller logs
kubectl logs -n flux-system deploy/kustomize-controller --tail=100
```

**Common Causes**:
1. **Invalid YAML**: Syntax error in manifests
2. **Missing dependency**: Parent Kustomization not ready
3. **Resource conflict**: Another controller owns the resource

**Solutions**:
```bash
# Suspend and resume
flux suspend kustomization APP_NAME
flux resume kustomization APP_NAME

# Force reconciliation
flux reconcile kustomization APP_NAME --with-source
```

### Git Authentication Failed

**Symptoms**: `authentication required` or `permission denied`

**Diagnosis**:
```bash
# Check source status
flux get sources git

# View source controller logs
kubectl logs -n flux-system deploy/source-controller | grep -i error
```

**Solutions**:
```bash
# Verify secret exists
kubectl get secret flux-system -n flux-system

# Re-create credentials
flux create secret git github-credentials \
  --url=https://github.com/amerintlxperts/gitops-platform \
  --github-app-id=$APP_ID \
  --github-app-installation-id=$INSTALL_ID \
  --github-app-private-key-file=/path/to/key.pem
```

### Image Pull Errors

**Symptoms**: Pods stuck in `ImagePullBackOff`

**Diagnosis**:
```bash
# Check pod events
kubectl describe pod POD_NAME

# Check ECR pull-through cache
aws ecr describe-pull-through-cache-rules --region ca-central-1
```

**Common Causes**:
1. ECR pull-through cache not configured
2. GHCR authentication failed
3. Image doesn't exist

**Solutions**:
```bash
# Verify ECR cache rule
aws ecr describe-pull-through-cache-rules

# Check GHCR secret in ECR
aws secretsmanager get-secret-value --secret-id ecr-ghcr-credentials

# Test image pull manually
docker pull ACCOUNT.dkr.ecr.ca-central-1.amazonaws.com/ghcr/amerintlxperts/IMAGE:TAG
```

## EKS Issues

### Node Not Ready

**Symptoms**: Node shows `NotReady` status

**Diagnosis**:
```bash
# Check node conditions
kubectl describe node NODE_NAME

# Check kubelet logs (via SSM)
aws ssm start-session --target INSTANCE_ID
journalctl -u kubelet -f
```

**Common Causes**:
1. **Disk pressure**: Node disk full
2. **Memory pressure**: OOM kills
3. **Network issues**: Cannot reach API server
4. **CNI issues**: VPC CNI not working

**Solutions**:
```bash
# Cordon and drain
kubectl cordon NODE_NAME
kubectl drain NODE_NAME --ignore-daemonsets --delete-emptydir-data

# For persistent issues, replace node
# Scale down node group to remove unhealthy node
aws eks update-nodegroup-config \
  --cluster-name CLUSTER \
  --nodegroup-name NODEGROUP \
  --scaling-config desiredSize=1
```

### Pod Cannot Reach AWS Services

**Symptoms**: Pods timeout when calling AWS APIs

**Diagnosis**:
```bash
# Test from pod
kubectl exec -it POD_NAME -- curl -I https://sts.ca-central-1.amazonaws.com

# Check VPC endpoint
aws ec2 describe-vpc-endpoints --filters Name=service-name,Values=com.amazonaws.ca-central-1.sts
```

**Common Causes**:
1. VPC endpoint not created
2. Security group blocking traffic
3. IRSA not configured

**Solutions**:
```bash
# Verify endpoint exists
terraform plan -target=aws_vpc_endpoint.sts

# Check security group rules
aws ec2 describe-security-groups --group-ids sg-xxx

# Verify IRSA annotation on ServiceAccount
kubectl get sa SERVICE_ACCOUNT -o yaml
```

### API Server Unreachable

**Symptoms**: kubectl commands timeout

**Diagnosis**:
```bash
# Check kubectl config
kubectl config view

# Test API endpoint directly
curl -k https://EKS_ENDPOINT/healthz
```

**Common Causes**:
1. kubeconfig expired
2. Network connectivity (if private cluster)
3. Security group misconfigured

**Solutions**:
```bash
# Refresh kubeconfig
aws eks update-kubeconfig --region ca-central-1 --name CLUSTER_NAME

# For private clusters, ensure VPN/bastion connectivity
```

## External Secrets Issues

### Secret Not Syncing

**Symptoms**: ExternalSecret shows error status

**Diagnosis**:
```bash
# Check ExternalSecret status
kubectl get externalsecrets -A
kubectl describe externalsecret SECRET_NAME

# Check ESO logs
kubectl logs -n external-secrets deploy/external-secrets --tail=100
```

**Common Causes**:
1. Secret doesn't exist in Secrets Manager
2. IAM role lacks permissions
3. SecretStore not configured

**Solutions**:
```bash
# Verify secret exists
aws secretsmanager describe-secret --secret-id dev/app/secret

# Check IAM permissions
aws sts get-caller-identity  # Should show ESO role when run from pod

# Verify ClusterSecretStore
kubectl get clustersecretstores
kubectl describe clustersecretstore aws-secrets-manager
```

### IRSA Not Working for ESO

**Symptoms**: ESO cannot assume IAM role

**Diagnosis**:
```bash
# Check ServiceAccount annotation
kubectl get sa external-secrets -n external-secrets -o yaml

# Check OIDC provider
aws iam list-open-id-connect-providers
```

**Solutions**:
```bash
# Verify role trust policy includes correct OIDC issuer
aws iam get-role --role-name eso-role --query 'Role.AssumeRolePolicyDocument'

# Restart ESO pods after fixing
kubectl rollout restart deploy/external-secrets -n external-secrets
```

## Networking Issues

### Pods Cannot Communicate

**Symptoms**: Pod-to-pod traffic fails

**Diagnosis**:
```bash
# Check if pods on same node
kubectl get pods -o wide

# Test connectivity
kubectl exec -it POD_A -- ping POD_B_IP

# Check VPC CNI
kubectl get ds aws-node -n kube-system
```

**Common Causes**:
1. Security group missing intra-node rules
2. VPC CNI issues
3. Network policy blocking

**Solutions**:
```bash
# Check security group allows node-to-node
aws ec2 describe-security-groups --group-ids sg-nodes

# Restart VPC CNI
kubectl rollout restart ds/aws-node -n kube-system
```

### Service Not Accessible

**Symptoms**: Cannot reach Service from within cluster

**Diagnosis**:
```bash
# Check Service
kubectl get svc SERVICE_NAME
kubectl describe svc SERVICE_NAME

# Check endpoints
kubectl get endpoints SERVICE_NAME

# Test DNS
kubectl exec -it POD -- nslookup SERVICE_NAME
```

**Common Causes**:
1. No pods matching selector
2. Pods not ready
3. CoreDNS issues

**Solutions**:
```bash
# Verify selector matches pod labels
kubectl get pods -l app=LABEL

# Check pod readiness
kubectl describe pod POD_NAME | grep -A5 Conditions

# Restart CoreDNS
kubectl rollout restart deploy/coredns -n kube-system
```

## Terraform Issues

### State Lock

**Symptoms**: `Error acquiring the state lock`

**Diagnosis**:
```bash
# Check DynamoDB for lock
aws dynamodb get-item \
  --table-name amerintlxperts-terraform-locks \
  --key '{"LockID": {"S": "amerintlxperts-terraform-state-ca-central-1/eks/dev/terraform.tfstate"}}'
```

**Solutions**:
```bash
# If lock is stale, force unlock
terraform force-unlock LOCK_ID
```

### Resource Replacement

**Symptoms**: Terraform wants to replace critical resource

**Diagnosis**:
```bash
# Review plan carefully
terraform plan -out=tfplan

# Check what triggers replacement
terraform show tfplan
```

**Solutions**:
```bash
# If change is cosmetic, ignore
lifecycle {
  ignore_changes = [attribute]
}

# If state drift, import current state
terraform import aws_resource.name RESOURCE_ID
```

## Useful Debug Commands

```bash
# FluxCD
flux logs --all-namespaces
flux get all --all-namespaces
flux events

# Kubernetes
kubectl get events --sort-by='.lastTimestamp'
kubectl top nodes
kubectl top pods -A

# AWS
aws eks describe-cluster --name CLUSTER
aws sts get-caller-identity
aws logs tail /aws/eks/CLUSTER/cluster --follow

# Network debugging pod
kubectl run debug --rm -it --image=nicolaka/netshoot -- bash
```

## Escalation Checklist

Before escalating, gather:

1. [ ] `flux get all -A` output
2. [ ] `kubectl get events -A --sort-by='.lastTimestamp'` output
3. [ ] Relevant controller logs
4. [ ] `kubectl describe` of affected resources
5. [ ] Recent Git commits to gitops-platform
6. [ ] Recent Terraform changes
7. [ ] AWS CloudTrail events (if IAM related)
