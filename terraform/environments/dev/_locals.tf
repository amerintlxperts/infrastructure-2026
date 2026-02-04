# =============================================================================
# Local Values
# =============================================================================
# Computed values, subnet definitions, and endpoint configurations.
# This separates WHAT to create from HOW to create it.
# =============================================================================

locals {
  # ---------------------------------------------------------------------------
  # Naming
  # ---------------------------------------------------------------------------
  cluster_name = "${var.project_name}-${var.environment}"

  # ---------------------------------------------------------------------------
  # Common Tags (applied via provider default_tags, but available for merging)
  # ---------------------------------------------------------------------------
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # ---------------------------------------------------------------------------
  # Subnet Definitions
  # ---------------------------------------------------------------------------
  # Defines WHAT subnets to create. The aws_subnet resource uses for_each
  # to create all subnets from this map.
  #
  # EKS Subnet Tags:
  # - kubernetes.io/cluster/<name> = shared  : EKS can use this subnet
  # - kubernetes.io/role/elb = 1             : Public LBs (internet-facing)
  # - kubernetes.io/role/internal-elb = 1    : Internal LBs (private)
  # ---------------------------------------------------------------------------
  subnets = {
    "public-a" = {
      cidr        = "10.0.1.0/24"
      az          = var.availability_zones[0]
      public      = true
      eks_elb_tag = "elb"
    }
    "public-b" = {
      cidr        = "10.0.2.0/24"
      az          = var.availability_zones[1]
      public      = true
      eks_elb_tag = "elb"
    }
    "private-a" = {
      cidr        = "10.0.10.0/24"
      az          = var.availability_zones[0]
      public      = false
      eks_elb_tag = "internal-elb"
    }
    "private-b" = {
      cidr        = "10.0.11.0/24"
      az          = var.availability_zones[1]
      public      = false
      eks_elb_tag = "internal-elb"
    }
    "endpoints" = {
      cidr        = "10.0.100.0/24"
      az          = var.availability_zones[0]
      public      = false
      eks_elb_tag = null
    }
  }

  # Derived subnet lists for easy reference
  public_subnet_keys  = [for k, v in local.subnets : k if v.public]
  private_subnet_keys = [for k, v in local.subnets : k if !v.public && k != "endpoints"]

  # ---------------------------------------------------------------------------
  # VPC Interface Endpoints
  # ---------------------------------------------------------------------------
  # These endpoints allow private access to AWS services without going through
  # the NAT Gateway, improving security and reducing data transfer costs.
  #
  # Required for EKS:
  # - ecr.api, ecr.dkr : Pull container images from ECR
  # - sts              : IRSA token exchange
  # - logs             : CloudWatch container logs
  # - ec2              : Node management
  # - secretsmanager   : External Secrets Operator
  # ---------------------------------------------------------------------------
  interface_endpoints = {
    "ecr-api"        = "com.amazonaws.${var.region}.ecr.api"
    "ecr-dkr"        = "com.amazonaws.${var.region}.ecr.dkr"
    "secretsmanager" = "com.amazonaws.${var.region}.secretsmanager"
    "sts"            = "com.amazonaws.${var.region}.sts"
    "logs"           = "com.amazonaws.${var.region}.logs"
    "ec2"            = "com.amazonaws.${var.region}.ec2"
  }

  # ---------------------------------------------------------------------------
  # EKS Public Access CIDRs
  # ---------------------------------------------------------------------------
  # Includes BOTH:
  #   1. admin_cidr (user's IP from hydrate.sh) - for local kubectl access
  #   2. runner_cidr (GitHub runner IP) - for Terraform to manage K8s resources
  #
  # This allows Terraform on GitHub Actions to create namespaces, deploy Helm
  # charts, etc. while still restricting general API access to known IPs.
  # ---------------------------------------------------------------------------
  my_public_ip = chomp(data.http.my_ip.response_body)
  runner_cidr  = "${local.my_public_ip}/32"
  admin_cidr   = var.admin_cidr != "" ? var.admin_cidr : local.runner_cidr

  # Allow public access to EKS API endpoint
  # Security is enforced by IAM authentication (OIDC roles), not CIDR restrictions
  # GitHub Actions runners have dynamic IPs that can't be predicted
  eks_public_access_cidrs = ["0.0.0.0/0"]

  # Restrict admin access (FortiWeb management, SSH) to known IPs
  admin_access_cidrs = [local.admin_cidr]
}

# -----------------------------------------------------------------------------
# Data Sources
# -----------------------------------------------------------------------------

# Fetch current public IP for EKS API access restriction
data "http" "my_ip" {
  url = "https://checkip.amazonaws.com"
}

# Get current AWS account ID
data "aws_caller_identity" "current" {}
