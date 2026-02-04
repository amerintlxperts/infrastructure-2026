# =============================================================================
# VPC & Core Networking
# =============================================================================
# Creates the foundational VPC infrastructure:
# - VPC with DNS support (required for EKS)
# - Subnets across 2 AZs (public, private, endpoints)
# - Internet Gateway for public subnet internet access
# - NAT Gateway for private subnet outbound access
# - Route tables with appropriate routing
# =============================================================================

# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------
# The VPC provides an isolated network for all EKS resources.
# DNS hostnames and support are required for EKS node registration
# and VPC endpoint resolution.
# -----------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${local.cluster_name}-vpc"
  }
}

# -----------------------------------------------------------------------------
# Subnets
# -----------------------------------------------------------------------------
# Creates all subnets from the local.subnets map using for_each.
# Each subnet gets EKS-specific tags for load balancer discovery.
# -----------------------------------------------------------------------------

resource "aws_subnet" "main" {
  for_each = local.subnets

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = each.value.public

  tags = merge(
    {
      Name                                          = "${local.cluster_name}-${each.key}"
      "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    },
    each.value.eks_elb_tag != null ? {
      "kubernetes.io/role/${each.value.eks_elb_tag}" = "1"
    } : {}
  )
}

# -----------------------------------------------------------------------------
# Internet Gateway
# -----------------------------------------------------------------------------
# Enables internet access for resources in public subnets.
# Required for NAT Gateway to function.
# -----------------------------------------------------------------------------

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.cluster_name}-igw"
  }
}

# -----------------------------------------------------------------------------
# NAT Gateway
# -----------------------------------------------------------------------------
# Enables outbound internet access for private subnets (EKS nodes).
# Single NAT in public-a for cost optimization in dev environment.
# For production, deploy one NAT per AZ for high availability.
# -----------------------------------------------------------------------------

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${local.cluster_name}-nat-eip"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.main["public-a"].id

  tags = {
    Name = "${local.cluster_name}-nat"
  }

  depends_on = [aws_internet_gateway.main]
}

# -----------------------------------------------------------------------------
# Route Tables
# -----------------------------------------------------------------------------
# Public route table: Routes internet traffic through IGW
# Private route table: Routes internet traffic through NAT Gateway
# -----------------------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${local.cluster_name}-public-rt"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${local.cluster_name}-private-rt"
  }
}

# -----------------------------------------------------------------------------
# Route Table Associations
# -----------------------------------------------------------------------------
# Associates each subnet with the appropriate route table based on
# whether it's public or private.
# -----------------------------------------------------------------------------

resource "aws_route_table_association" "main" {
  for_each = local.subnets

  subnet_id      = aws_subnet.main[each.key].id
  route_table_id = each.value.public ? aws_route_table.public.id : aws_route_table.private.id
}
