# =============================================================================
# FortiWeb-VM (Web Application Firewall)
# =============================================================================
# Deploys FortiWeb-VM from AWS Marketplace as the ingress point for the cluster.
# FortiWeb provides WAF protection, load balancing, and SSL termination.
#
# ARCHITECTURE (Dual-Interface):
# ------------------------------
#   Internet → port1 (public) → FortiWeb WAF → port2 (private) → EKS Pods
#
#   port1 (External): Public subnet - receives internet traffic + management
#   port2 (Internal): Private subnet - forwards inspected traffic to pods
#
# HOW IT WORKS WITH THE INGRESS CONTROLLER:
# -----------------------------------------
#   1. FortiWeb-VM runs in AWS with two interfaces
#   2. fortiweb-ingress controller runs in EKS, watches Ingress resources
#   3. Controller calls FortiWeb REST API via port1 to configure WAF
#   4. Internet traffic arrives on port1, gets inspected by WAF
#   5. Clean traffic forwarded via port2 to pod IPs
#
# LICENSING:
# ----------
#   FortiWeb-VM requires a license. Options:
#   - BYOL (Bring Your Own License) - use existing Fortinet license
#   - PAYG (Pay As You Go) - billed hourly via AWS Marketplace
#
#   Update the AMI ID based on your licensing model and region.
#
# INITIAL SETUP:
# --------------
#   1. Access FortiWeb GUI: https://<fortiweb_public_ip>:8443
#   2. Default credentials: admin / (instance-id)
#   3. Complete initial setup wizard
#   4. Enable REST API access for the ingress controller
#   5. Create API user credentials
#   6. Store credentials in AWS Secrets Manager (dev/fortiweb)
#
# =============================================================================

# -----------------------------------------------------------------------------
# FortiWeb AMI Lookup
# -----------------------------------------------------------------------------
# Finds the latest FortiWeb-VM AMI from AWS Marketplace.
# You must subscribe to FortiWeb-VM in AWS Marketplace before this works.
#
# Marketplace links:
#   BYOL: https://aws.amazon.com/marketplace/pp/prodview-wkzpzlvdqqkri
#   PAYG: https://aws.amazon.com/marketplace/pp/prodview-uhyvc6nggcgum
# -----------------------------------------------------------------------------

data "aws_ami" "fortiweb" {
  most_recent = true
  owners      = ["aws-marketplace"]

  filter {
    name   = "name"
    values = ["FortiWeb-AWS-*BYOL*"] # Using BYOL license
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# -----------------------------------------------------------------------------
# FortiWeb API Credentials (Auto-generated)
# -----------------------------------------------------------------------------
# Generates a complex random password for the apiadmin user and stores it in
# Secrets Manager. External Secrets syncs this to K8s for the IC to use.
# -----------------------------------------------------------------------------

resource "random_password" "fortiweb" {
  length      = 18
  special     = false
  min_lower   = 4
  min_upper   = 4
  min_numeric = 4
}

resource "aws_secretsmanager_secret" "fortiweb" {
  name        = "${var.environment}/fortiweb"
  description = "FortiWeb API credentials for ingress controller (auto-generated)"

  # Immediate deletion without recovery window - prevents conflicts on redeploy
  recovery_window_in_days = 0

  tags = {
    Name = "${local.cluster_name}-fortiweb-credentials"
  }
}

resource "aws_secretsmanager_secret_version" "fortiweb" {
  secret_id = aws_secretsmanager_secret.fortiweb.id
  secret_string = jsonencode({
    username = "apiadmin"
    password = random_password.fortiweb.result
  })
}

locals {
  fortiweb_creds = {
    username = "apiadmin"
    password = random_password.fortiweb.result
  }
  # S3 bucket created by hydrate.sh (same as Terraform state bucket)
  fortiweb_config_bucket = "${var.project_name}-terraform-state-${var.region}"
  fortiweb_config_key    = "fortiweb/${var.environment}/config.txt"
}

# -----------------------------------------------------------------------------
# FortiWeb Cloud-Init Config (S3)
# -----------------------------------------------------------------------------
# Uploads CLI configuration to S3. FortiWeb fetches this during boot.
# This is required because FortiWeb AWS doesn't support inline user-data config.
# -----------------------------------------------------------------------------

resource "aws_s3_object" "fortiweb_config" {
  bucket = local.fortiweb_config_bucket
  key    = local.fortiweb_config_key
  content = templatefile("${path.module}/templates/fortiweb-config.txt.tpl", {
    api_password  = random_password.fortiweb.result
    vpc_cidr      = aws_vpc.main.cidr_block
    port2_gateway = cidrhost(aws_subnet.main["private-a"].cidr_block, 1)
    acme_email    = var.acme_email
  })

  # Ensure config is updated if template changes
  etag = md5(templatefile("${path.module}/templates/fortiweb-config.txt.tpl", {
    api_password  = random_password.fortiweb.result
    vpc_cidr      = aws_vpc.main.cidr_block
    port2_gateway = cidrhost(aws_subnet.main["private-a"].cidr_block, 1)
    acme_email    = var.acme_email
  }))

  tags = {
    Name = "${local.cluster_name}-fortiweb-config"
  }
}

# -----------------------------------------------------------------------------
# FortiWeb IAM Role (for S3 access)
# -----------------------------------------------------------------------------
# Allows FortiWeb to read its config from S3 during cloud-init.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "fortiweb" {
  name = "${local.cluster_name}-fortiweb"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = {
    Name = "${local.cluster_name}-fortiweb-role"
  }
}

resource "aws_iam_role_policy" "fortiweb_s3_read" {
  name = "${local.cluster_name}-fortiweb-s3-read"
  role = aws_iam_role.fortiweb.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::${local.fortiweb_config_bucket}",
          "arn:aws:s3:::${local.fortiweb_config_bucket}/${local.fortiweb_config_key}"
        ]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "fortiweb" {
  name = "${local.cluster_name}-fortiweb"
  role = aws_iam_role.fortiweb.name
}

# -----------------------------------------------------------------------------
# FortiWeb Security Group
# -----------------------------------------------------------------------------
# Controls traffic to/from FortiWeb-VM.
# -----------------------------------------------------------------------------

resource "aws_security_group" "fortiweb" {
  name        = "${local.cluster_name}-fortiweb"
  description = "Security group for FortiWeb WAF"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.cluster_name}-fortiweb-sg"
  }
}

# HTTPS from internet (web traffic)
resource "aws_security_group_rule" "fortiweb_https_ingress" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.fortiweb.id
  description       = "HTTPS from internet"
}

# HTTP from internet (redirect to HTTPS or ACME challenges)
resource "aws_security_group_rule" "fortiweb_http_ingress" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.fortiweb.id
  description       = "HTTP from internet"
}

# Management GUI (restrict to admin IP)
resource "aws_security_group_rule" "fortiweb_mgmt_ingress" {
  type              = "ingress"
  from_port         = 8443
  to_port           = 8443
  protocol          = "tcp"
  cidr_blocks       = local.admin_access_cidrs
  security_group_id = aws_security_group.fortiweb.id
  description       = "Management GUI from admin IP"
}

# SSH for management (restrict to admin IP)
resource "aws_security_group_rule" "fortiweb_ssh_ingress" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = local.admin_access_cidrs
  security_group_id = aws_security_group.fortiweb.id
  description       = "SSH from admin IP"
}

# Note: Traffic to EKS nodes is handled by port2 (fortiweb_internal SG)
# port1 only needs internet egress for updates/licensing

# Allow FortiWeb to reach internet (for updates, license validation)
resource "aws_security_group_rule" "fortiweb_internet_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.fortiweb.id
  description       = "To internet"
}

# Allow EKS nodes to reach FortiWeb management API (for ingress controller)
resource "aws_security_group_rule" "eks_nodes_to_fortiweb" {
  type                     = "ingress"
  from_port                = 8443
  to_port                  = 8443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.eks_nodes.id
  security_group_id        = aws_security_group.fortiweb.id
  description              = "Management API from ingress controller"
}

# -----------------------------------------------------------------------------
# FortiWeb Network Interfaces (Dual-Interface Architecture)
# -----------------------------------------------------------------------------
# port1 (External): Public subnet - internet traffic, management, API
# port2 (Internal): Private subnet - forwards traffic to EKS pods
# -----------------------------------------------------------------------------

# port1 - External interface (public subnet)
# Fixed IP allows hardcoding in K8s Ingress annotations (GitOps friendly)
resource "aws_network_interface" "fortiweb_port1" {
  subnet_id         = aws_subnet.main["public-a"].id
  private_ips       = ["10.0.1.100"]
  security_groups   = [aws_security_group.fortiweb.id]
  source_dest_check = false

  tags = {
    Name = "${local.cluster_name}-fortiweb-port1"
  }
}

# port2 - Internal interface (private subnet, management/API)
# Fixed IP allows hardcoding in K8s Ingress annotations (GitOps friendly)
resource "aws_network_interface" "fortiweb_port2" {
  subnet_id         = aws_subnet.main["private-a"].id
  private_ips       = ["10.0.10.100"]
  security_groups   = [aws_security_group.fortiweb_internal.id]
  source_dest_check = false

  tags = {
    Name = "${local.cluster_name}-fortiweb-port2"
  }
}

# -----------------------------------------------------------------------------
# FortiWeb Elastic IP
# -----------------------------------------------------------------------------
# Public IP for FortiWeb - this is where external traffic arrives.
# Point your DNS records to this IP. Attached to port1 (external interface).
# -----------------------------------------------------------------------------

resource "aws_eip" "fortiweb" {
  domain            = "vpc"
  network_interface = aws_network_interface.fortiweb_port1.id

  tags = {
    Name = "${local.cluster_name}-fortiweb-eip"
  }

  # Must wait for instance to be running before associating EIP with its ENI
  depends_on = [aws_internet_gateway.main, aws_instance.fortiweb]
}

# -----------------------------------------------------------------------------
# FortiWeb EC2 Instance
# -----------------------------------------------------------------------------
# The FortiWeb-VM appliance. Sized for dev workloads.
#
# Instance sizing guide:
#   - t3.medium: Dev/test, <200 Mbps throughput
#   - c5.large:  Production, up to 500 Mbps
#   - c5.xlarge: High traffic, up to 1 Gbps
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# FortiWeb Network Config (Secrets Manager)
# -----------------------------------------------------------------------------
# Stores FortiWeb IPs in Secrets Manager so External Secrets can sync them
# to a Kubernetes ConfigMap. This avoids Terraform needing K8s API access.
#
# The ExternalSecret is defined in manifests-platform/resources/external-secrets/
# and creates the fortiweb-config ConfigMap in kube-system namespace.
# -----------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "fortiweb_network" {
  name        = "${var.environment}/fortiweb-network"
  description = "FortiWeb network configuration (IPs) for ingress controller"

  # Immediate deletion without recovery window - prevents conflicts on redeploy
  recovery_window_in_days = 0

  tags = {
    Name = "${local.cluster_name}-fortiweb-network"
  }
}

resource "aws_secretsmanager_secret_version" "fortiweb_network" {
  secret_id = aws_secretsmanager_secret.fortiweb_network.id
  secret_string = jsonencode({
    # FortiWeb port2 (internal) - for ingress controller API connection
    FORTIWEB_IP = aws_network_interface.fortiweb_port2.private_ip
    # FortiWeb public IP - for virtual server VIP (where traffic arrives)
    FORTIWEB_PUBLIC_IP = aws_eip.fortiweb.public_ip
    # FortiWeb port1 private IP - for virtual server interface
    FORTIWEB_PORT1_IP = aws_network_interface.fortiweb_port1.private_ip
    # API port
    FORTIWEB_PORT = "8443"
    # Instance ID - default password for bootstrap job
    instance_id = aws_instance.fortiweb.id
  })

  depends_on = [
    aws_network_interface.fortiweb_port1,
    aws_network_interface.fortiweb_port2,
    aws_eip.fortiweb
  ]
}

resource "aws_instance" "fortiweb" {
  ami           = data.aws_ami.fortiweb.id
  instance_type = var.fortiweb_instance_type

  # IAM instance profile for S3 access (cloud-init config)
  iam_instance_profile = aws_iam_instance_profile.fortiweb.name

  # port1 - External interface (device_index 0 = port1 in FortiWeb)
  network_interface {
    network_interface_id = aws_network_interface.fortiweb_port1.id
    device_index         = 0
  }

  # port2 - Internal interface (device_index 1 = port2 in FortiWeb)
  network_interface {
    network_interface_id = aws_network_interface.fortiweb_port2.id
    device_index         = 1
  }

  # Cloud-init: reference S3-hosted config file
  # FortiWeb AWS requires config in S3, not inline user-data
  user_data = jsonencode({
    "cloud-initd" = "enable"
    "bucket"      = local.fortiweb_config_bucket
    "region"      = var.region
    "config"      = local.fortiweb_config_key
    "flex_token"  = var.fortiflex_token
  })

  # Root volume
  root_block_device {
    volume_size           = 40
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  # Log volume
  ebs_block_device {
    device_name           = "/dev/sdb"
    volume_size           = 30
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name = "${local.cluster_name}-fortiweb"
  }

  # Prevent accidental termination
  lifecycle {
    ignore_changes = [ami, user_data] # Don't replace on AMI or user_data updates
  }
}
