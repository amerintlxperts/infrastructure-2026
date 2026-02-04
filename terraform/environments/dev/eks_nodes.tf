# =============================================================================
# EKS Node Group
# =============================================================================
# Minimalist node configuration for dev environment.
# 2 nodes for HA and capacity.
# =============================================================================

# -----------------------------------------------------------------------------
# Node IAM Role
# -----------------------------------------------------------------------------
# Allows EC2 instances to function as EKS nodes.
# Needs permissions for: node registration, CNI networking, image pulls.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "eks_nodes" {
  name = "${local.cluster_name}-eks-nodes"

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
    Name = "${local.cluster_name}-eks-nodes-role"
  }
}

# Required: Node registration with EKS
resource "aws_iam_role_policy_attachment" "eks_worker_node" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_nodes.name
}

# Required: CNI networking permissions
# Still needed for Flannel (manages ENIs for host networking)
resource "aws_iam_role_policy_attachment" "eks_cni" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_nodes.name
}

# Required: Pull images from ECR
resource "aws_iam_role_policy_attachment" "ecr_read" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_nodes.name
}

# -----------------------------------------------------------------------------
# Launch Template
# -----------------------------------------------------------------------------
# Customizes node configuration: encrypted volumes, IMDSv2, tags.
# -----------------------------------------------------------------------------

resource "aws_launch_template" "eks_nodes" {
  name = "${local.cluster_name}-eks-nodes"

  # Encrypted root volume
  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 30 # Minimalist: 30GB sufficient for dev
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # IMDSv2 required for security
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # Required for container networking (VPC CNI)
  }

  # Tag instances and volumes
  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${local.cluster_name}-node"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name = "${local.cluster_name}-node-volume"
    }
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${local.cluster_name}-launch-template"
  }
}

# -----------------------------------------------------------------------------
# Managed Node Group
# -----------------------------------------------------------------------------
# 2 nodes for HA and sufficient capacity for platform workloads.
# EKS manages the Auto Scaling group, AMI updates, and node lifecycle.
# -----------------------------------------------------------------------------

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.cluster_name}-nodes"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = [for k in local.private_subnet_keys : aws_subnet.main[k].id]

  # t3.large supports 35 pods (vs 17 for t3.medium)
  instance_types = ["t3.large"]
  capacity_type  = "ON_DEMAND"

  # 2 nodes for HA, can scale to 3 if needed
  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 3
  }

  # Use our launch template
  launch_template {
    id      = aws_launch_template.eks_nodes.id
    version = aws_launch_template.eks_nodes.latest_version
  }

  # Rolling updates: 1 node at a time
  update_config {
    max_unavailable = 1
  }

  # Node labels
  labels = {
    role        = "general"
    environment = var.environment
  }

  # Wait for IAM policies to be ready
  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node,
    aws_iam_role_policy_attachment.eks_cni,
    aws_iam_role_policy_attachment.ecr_read
  ]

  tags = {
    Name = "${local.cluster_name}-node-group"
  }

  # Don't fight with cluster autoscaler or manual scaling
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}
