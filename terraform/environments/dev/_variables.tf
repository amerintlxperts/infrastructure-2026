# =============================================================================
# Input Variables
# =============================================================================
# All input variables for the dev environment.
# Values are set in terraform.tfvars
# =============================================================================

# -----------------------------------------------------------------------------
# Project Configuration
# -----------------------------------------------------------------------------

variable "project_name" {
  description = "Project name used for resource naming and tagging"
  type        = string
  default     = "xperts"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"
}

# -----------------------------------------------------------------------------
# AWS Configuration
# -----------------------------------------------------------------------------

variable "region" {
  description = "AWS region for all resources"
  type        = string
  default     = "ca-central-1"
}

variable "availability_zones" {
  description = "List of availability zones to use"
  type        = list(string)
  default     = ["ca-central-1a", "ca-central-1b"]
}

# -----------------------------------------------------------------------------
# Network Configuration
# -----------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

# -----------------------------------------------------------------------------
# EKS Configuration
# -----------------------------------------------------------------------------

variable "eks_version" {
  description = "Kubernetes version for EKS cluster"
  type        = string
  default     = "1.31"
}

variable "eks_enabled_log_types" {
  description = "EKS control plane log types to enable"
  type        = list(string)
  default     = ["api", "audit", "authenticator"]
}

# -----------------------------------------------------------------------------
# GitHub Configuration
# -----------------------------------------------------------------------------

variable "github_org" {
  description = "GitHub organization or username"
  type        = string
  default     = "amerintlxperts"
}

variable "github_repo" {
  description = "GitHub repository name"
  type        = string
  default     = "infrastructure-2026"
}

# -----------------------------------------------------------------------------
# GitOps Configuration (Monorepo)
# -----------------------------------------------------------------------------

variable "gitops_repo_url" {
  description = "URL of the monorepo (SSH for private repos)"
  type        = string
  default     = "git@github.com:amerintlxperts/infrastructure-2026.git"
}

variable "gitops_apps_path" {
  description = "Path within the monorepo containing ArgoCD Application manifests"
  type        = string
  default     = "manifests-platform/argocd"
}

variable "gitops_target_revision" {
  description = "Git branch, tag, or commit to track"
  type        = string
  default     = "main"
}

# -----------------------------------------------------------------------------
# FortiWeb Configuration
# -----------------------------------------------------------------------------

variable "fortiweb_instance_type" {
  description = "EC2 instance type for FortiWeb-VM (t3.medium for dev, c5.large for prod)"
  type        = string
  default     = "t3.medium"
}

variable "fortiflex_token" {
  description = "FortiFlex token for FortiWeb licensing. Set via TF_VAR_fortiflex_token from hydrate.sh"
  type        = string
  default     = "" # Empty means skip FortiFlex (use PAYG or manual BYOL)
  sensitive   = true
}

# -----------------------------------------------------------------------------
# Access Control
# -----------------------------------------------------------------------------

variable "admin_cidr" {
  description = "CIDR block for admin access (EKS API, FortiWeb management). Set via TF_VAR_admin_cidr from hydrate.sh"
  type        = string
  default     = "" # Empty means use dynamic IP lookup (GitHub runner IP)
}

variable "admin_role_arn" {
  description = "IAM role ARN for cluster admin access (kubectl). Set via TF_VAR_admin_role_arn from hydrate.sh"
  type        = string
  default     = "" # Empty means skip creating admin access entry
}

variable "additional_cluster_admins" {
  description = "Additional IAM ARNs to grant cluster admin access. Set via TF_VAR_additional_cluster_admins from hydrate.sh"
  type        = list(string)
  default     = []
}

# -----------------------------------------------------------------------------
# DNS Configuration
# -----------------------------------------------------------------------------

variable "domain_name" {
  description = "Root domain name for the platform. Set via TF_VAR_domain_name from hydrate.sh"
  type        = string
}

variable "acme_email" {
  description = "Email address for Let's Encrypt certificate notifications. Set via TF_VAR_acme_email from hydrate.sh"
  type        = string
}

variable "delegation_set_id" {
  description = <<-EOT
    Route53 reusable delegation set ID for consistent nameservers across zone recreations.
    Set via TF_VAR_delegation_set_id from hydrate.sh (--set-delegation-set flag).

    WHY THIS MATTERS:
    -----------------
    When you destroy/recreate infrastructure, Route53 assigns NEW nameservers to the hosted zone.
    This breaks DNS because your domain registrar (GoDaddy) still points to the OLD nameservers.

    A reusable delegation set provides FIXED nameservers that persist across zone recreations.
    You only need to update your registrar's nameservers ONCE.

    USAGE:
    ------
    1. Run: ./bootstrap/hydrate.sh --set-delegation-set
    2. Update your domain registrar with the nameservers shown
    3. Done - nameservers never change, even after terraform destroy/apply
  EOT
  type        = string
  default     = "" # Empty means Route53 assigns random nameservers (changes on recreate)
}
