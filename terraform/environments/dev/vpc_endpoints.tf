# =============================================================================
# VPC Endpoints
# =============================================================================
# VPC endpoints allow private access to AWS services without traversing the
# internet. This improves security (no public exposure) and can reduce costs
# (no NAT Gateway data transfer charges for AWS API calls).
#
# Interface Endpoints: Create ENIs in the endpoints subnet, cost ~$7.30/month each
# Gateway Endpoints: Route table entries only, FREE
# =============================================================================

# -----------------------------------------------------------------------------
# Interface Endpoints
# -----------------------------------------------------------------------------
# These endpoints create ENIs in the endpoints subnet and enable private DNS
# so that standard AWS SDK calls automatically use the private endpoints.
#
# Required for EKS private cluster operation:
# - ecr.api/ecr.dkr : Pull container images without internet
# - sts             : IRSA (IAM Roles for Service Accounts) authentication
# - logs            : Ship container logs to CloudWatch
# - ec2             : Node management and instance metadata
# - secretsmanager  : External Secrets Operator access
# -----------------------------------------------------------------------------

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = aws_vpc.main.id
  service_name        = each.value
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.main["endpoints"].id]
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "${local.cluster_name}-${each.key}-endpoint"
  }
}

# -----------------------------------------------------------------------------
# S3 Gateway Endpoint
# -----------------------------------------------------------------------------
# Gateway endpoints are FREE and don't require ENIs.
# S3 is used heavily by ECR (image layers stored in S3) so this
# eliminates significant NAT Gateway data transfer costs.
# -----------------------------------------------------------------------------

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = {
    Name = "${local.cluster_name}-s3-endpoint"
  }
}
