# =============================================================================
# Outputs
# =============================================================================
# Values exported for use by subsequent modules and for reference.
# These outputs will be consumed by Module 2 (EKS), Module 3 (Nodes), etc.
# =============================================================================

# -----------------------------------------------------------------------------
# VPC Outputs
# -----------------------------------------------------------------------------

output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.main.cidr_block
}

# -----------------------------------------------------------------------------
# Subnet Outputs
# -----------------------------------------------------------------------------

output "private_subnet_ids" {
  description = "IDs of private subnets (for EKS nodes)"
  value       = [for k in local.private_subnet_keys : aws_subnet.main[k].id]
}

output "public_subnet_ids" {
  description = "IDs of public subnets (for NAT/Ingress)"
  value       = [for k in local.public_subnet_keys : aws_subnet.main[k].id]
}

output "endpoints_subnet_id" {
  description = "ID of the VPC endpoints subnet"
  value       = aws_subnet.main["endpoints"].id
}

# -----------------------------------------------------------------------------
# Gateway Outputs
# -----------------------------------------------------------------------------

output "nat_gateway_id" {
  description = "ID of the NAT Gateway"
  value       = aws_nat_gateway.main.id
}

output "internet_gateway_id" {
  description = "ID of the Internet Gateway"
  value       = aws_internet_gateway.main.id
}

# -----------------------------------------------------------------------------
# Security Group Outputs
# -----------------------------------------------------------------------------

output "vpc_endpoints_security_group_id" {
  description = "Security group ID for VPC endpoints"
  value       = aws_security_group.vpc_endpoints.id
}

output "eks_cluster_security_group_id" {
  description = "Security group ID for EKS cluster"
  value       = aws_security_group.eks_cluster.id
}

output "eks_nodes_security_group_id" {
  description = "Security group ID for EKS nodes"
  value       = aws_security_group.eks_nodes.id
}

# -----------------------------------------------------------------------------
# EKS Cluster Outputs
# -----------------------------------------------------------------------------

output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_certificate_authority" {
  description = "Cluster CA certificate (base64 encoded)"
  value       = aws_eks_cluster.main.certificate_authority[0].data
  sensitive   = true
}

output "cluster_version" {
  description = "EKS cluster Kubernetes version"
  value       = aws_eks_cluster.main.version
}

# -----------------------------------------------------------------------------
# OIDC / IRSA Outputs
# -----------------------------------------------------------------------------

output "oidc_provider_arn" {
  description = "OIDC provider ARN for IRSA"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "oidc_provider_url" {
  description = "OIDC provider URL (without https://)"
  value       = replace(aws_iam_openid_connect_provider.eks.url, "https://", "")
}

# -----------------------------------------------------------------------------
# Derived Values
# -----------------------------------------------------------------------------

output "availability_zones" {
  description = "Availability zones used"
  value       = var.availability_zones
}

output "my_public_ip" {
  description = "Public IP used for EKS API access restriction"
  value       = local.my_public_ip
}

# -----------------------------------------------------------------------------
# Node Group Outputs
# -----------------------------------------------------------------------------

output "node_group_name" {
  description = "EKS node group name"
  value       = aws_eks_node_group.main.node_group_name
}

output "node_role_arn" {
  description = "IAM role ARN for EKS nodes"
  value       = aws_iam_role.eks_nodes.arn
}

# -----------------------------------------------------------------------------
# IRSA Role Outputs
# -----------------------------------------------------------------------------

output "external_secrets_role_arn" {
  description = "IAM role ARN for External Secrets Operator"
  value       = aws_iam_role.external_secrets.arn
}

# -----------------------------------------------------------------------------
# Kubectl Configuration
# -----------------------------------------------------------------------------

output "kubectl_config_command" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.main.name}"
}

# -----------------------------------------------------------------------------
# ArgoCD Outputs
# -----------------------------------------------------------------------------

output "argocd_namespace" {
  description = "ArgoCD namespace"
  value       = "argocd"
}

output "argocd_server_service" {
  description = "ArgoCD server service name"
  value       = "argocd-server"
}

output "argocd_port_forward_command" {
  description = "Command to port-forward ArgoCD UI"
  value       = "kubectl port-forward svc/argocd-server -n argocd 8080:443"
}

output "argocd_initial_password_command" {
  description = "Command to get ArgoCD initial admin password"
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d && echo"
}

output "argocd_gitops_repo" {
  description = "GitOps repository URL being watched by ArgoCD"
  value       = var.gitops_repo_url
}

# -----------------------------------------------------------------------------
# FortiWeb Outputs
# -----------------------------------------------------------------------------

output "fortiweb_public_ip" {
  description = "FortiWeb public IP (point DNS here)"
  value       = aws_eip.fortiweb.public_ip
}

output "fortiweb_port1_private_ip" {
  description = "FortiWeb port1 private IP - use for ingress controller API config"
  value       = aws_network_interface.fortiweb_port1.private_ip
}

output "fortiweb_port2_private_ip" {
  description = "FortiWeb port2 private IP (internal interface to EKS pods)"
  value       = aws_network_interface.fortiweb_port2.private_ip
}

# NOTE: Instance ID is intentionally NOT output here because it's the default password.
# Retrieve it via AWS CLI when needed for initial setup.

output "fortiweb_mgmt_url" {
  description = "FortiWeb management GUI URL"
  value       = "https://${aws_eip.fortiweb.public_ip}:8443"
}

output "fortiweb_setup_instructions" {
  description = "FortiWeb initial setup instructions"
  value       = <<-EOT
    FortiWeb is configured with two admin accounts:

    1. CONSOLE ACCESS (admin):
       URL: https://${aws_eip.fortiweb.public_ip}:8443
       Username: admin
       Password: <instance-id> (retrieve with command below)

       Get instance ID:
       aws ec2 describe-instances \
         --filters "Name=tag:Name,Values=${var.project_name}-${var.environment}-fortiweb" \
         --query 'Reservations[0].Instances[0].InstanceId' --output text

    2. API ACCESS (apiadmin) - used by ingress controller:
       Username: apiadmin
       Password: <from Secrets Manager: ${var.environment}/fortiweb>
       This user is auto-created via cloud-init.

    The ingress controller uses apiadmin credentials from:
       kubectl get secret fortiweb-credentials -n kube-system
  EOT
}

# -----------------------------------------------------------------------------
# DNS / Route53 Outputs
# -----------------------------------------------------------------------------

output "route53_zone_id" {
  description = "Route53 hosted zone ID"
  value       = aws_route53_zone.main.zone_id
}

output "route53_name_servers" {
  description = "Name servers to configure at your domain registrar"
  value       = aws_route53_zone.main.name_servers
}

output "domain_name" {
  description = "Domain name for the platform"
  value       = var.domain_name
}

output "external_dns_role_arn" {
  description = "IAM role ARN for External-DNS"
  value       = aws_iam_role.external_dns.arn
}

output "cert_manager_role_arn" {
  description = "IAM role ARN for cert-manager DNS-01 challenges"
  value       = aws_iam_role.cert_manager.arn
}
