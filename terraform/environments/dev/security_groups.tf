# =============================================================================
# Security Groups
# =============================================================================
# Security groups control network traffic at the instance level.
# This file creates security groups for:
# - VPC Endpoints (HTTPS access from VPC)
# - EKS Cluster (placeholder for Module 2)
# - EKS Nodes (placeholder for Module 3)
# =============================================================================

# -----------------------------------------------------------------------------
# VPC Endpoints Security Group
# -----------------------------------------------------------------------------
# Allows HTTPS (443) access to VPC endpoints from within the VPC.
# VPC endpoints use HTTPS for all AWS API calls.
# -----------------------------------------------------------------------------

resource "aws_security_group" "vpc_endpoints" {
  name        = "${local.cluster_name}-vpc-endpoints"
  description = "Security group for VPC endpoints"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.cluster_name}-vpc-endpoints-sg"
  }
}

# -----------------------------------------------------------------------------
# EKS Cluster Security Group
# -----------------------------------------------------------------------------
# Controls traffic between the EKS control plane and worker nodes.
# The control plane needs to communicate with nodes for:
# - Kubelet API (10250): Execute commands, get logs, port-forward
# - HTTPS (443): API server webhook callbacks
# -----------------------------------------------------------------------------

resource "aws_security_group" "eks_cluster" {
  name        = "${local.cluster_name}-eks-cluster"
  description = "Security group for EKS cluster control plane"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.cluster_name}-eks-cluster-sg"
  }
}

# Ingress: Allow HTTPS from nodes (for API server communication)
resource "aws_security_group_rule" "eks_cluster_ingress_nodes_https" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_cluster.id
  source_security_group_id = aws_security_group.eks_nodes.id
  description              = "HTTPS from nodes"
}

# Egress: Allow HTTPS to nodes (for webhooks, metrics-server, etc.)
resource "aws_security_group_rule" "eks_cluster_egress_nodes_https" {
  type                     = "egress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_cluster.id
  source_security_group_id = aws_security_group.eks_nodes.id
  description              = "HTTPS to nodes"
}

# Egress: Allow Kubelet API to nodes (for exec, logs, port-forward)
resource "aws_security_group_rule" "eks_cluster_egress_nodes_kubelet" {
  type                     = "egress"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_cluster.id
  source_security_group_id = aws_security_group.eks_nodes.id
  description              = "Kubelet API to nodes"
}

# -----------------------------------------------------------------------------
# EKS Nodes Security Group
# -----------------------------------------------------------------------------
# Controls traffic to/from EKS worker nodes.
# Nodes need to communicate with:
# - Control plane (API server, webhooks)
# - Other nodes (pod-to-pod traffic)
# - VPC endpoints (AWS API calls)
# -----------------------------------------------------------------------------

resource "aws_security_group" "eks_nodes" {
  name        = "${local.cluster_name}-eks-nodes"
  description = "Security group for EKS worker nodes"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.cluster_name}-eks-nodes-sg"
  }
}

# Ingress: Allow all traffic from other nodes (pod-to-pod)
resource "aws_security_group_rule" "eks_nodes_ingress_self" {
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.eks_nodes.id
  self              = true
  description       = "Node to node communication"
}

# Ingress: Allow HTTPS from control plane (webhooks, metrics)
resource "aws_security_group_rule" "eks_nodes_ingress_cluster_https" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_nodes.id
  source_security_group_id = aws_security_group.eks_cluster.id
  description              = "HTTPS from control plane"
}

# Ingress: Allow Kubelet API from control plane (exec, logs, port-forward)
resource "aws_security_group_rule" "eks_nodes_ingress_cluster_kubelet" {
  type                     = "ingress"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_nodes.id
  source_security_group_id = aws_security_group.eks_cluster.id
  description              = "Kubelet API from control plane"
}

# Egress: Allow all outbound (needed for pulling images, AWS APIs, etc.)
resource "aws_security_group_rule" "eks_nodes_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.eks_nodes.id
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Allow all outbound"
}

# Ingress: Allow traffic from FortiWeb port2 (internal interface)
# FortiWeb forwards inspected traffic via port2 to pods
resource "aws_security_group_rule" "eks_nodes_ingress_fortiweb" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_nodes.id
  source_security_group_id = aws_security_group.fortiweb_internal.id
  description              = "Traffic from FortiWeb WAF (port2)"
}

# -----------------------------------------------------------------------------
# FortiWeb Internal Security Group (port2)
# -----------------------------------------------------------------------------
# Security group for FortiWeb's internal interface (port2).
# port2 is used ONLY for forwarding traffic to EKS pods after WAF inspection.
# No inbound access - this is an egress-only interface.
# -----------------------------------------------------------------------------

resource "aws_security_group" "fortiweb_internal" {
  name        = "${local.cluster_name}-fortiweb-internal"
  description = "Security group for FortiWeb internal interface (port2)"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.cluster_name}-fortiweb-internal-sg"
  }
}

# Egress: Allow FortiWeb to forward traffic to EKS nodes
resource "aws_security_group_rule" "fortiweb_internal_to_eks_nodes" {
  type                     = "egress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.eks_nodes.id
  security_group_id        = aws_security_group.fortiweb_internal.id
  description              = "Forward traffic to EKS nodes"
}

# Ingress: Allow EKS pods to reach FortiWeb management API
# Uses VPC CIDR because pod traffic source doesn't match SG-based rules
resource "aws_security_group_rule" "fortiweb_internal_from_vpc" {
  type              = "ingress"
  from_port         = 8443
  to_port           = 8443
  protocol          = "tcp"
  cidr_blocks       = [aws_vpc.main.cidr_block]
  security_group_id = aws_security_group.fortiweb_internal.id
  description       = "Management API from VPC (ingress controller)"
}

# Egress: Allow ICMP from FortiWeb to EKS nodes (health checks)
resource "aws_security_group_rule" "fortiweb_internal_icmp_to_eks" {
  type                     = "egress"
  from_port                = -1
  to_port                  = -1
  protocol                 = "icmp"
  source_security_group_id = aws_security_group.eks_nodes.id
  security_group_id        = aws_security_group.fortiweb_internal.id
  description              = "ICMP to EKS nodes (health checks)"
}

# Ingress: Allow ICMP from FortiWeb to EKS nodes (health checks)
resource "aws_security_group_rule" "eks_nodes_ingress_fortiweb_icmp" {
  type                     = "ingress"
  from_port                = -1
  to_port                  = -1
  protocol                 = "icmp"
  security_group_id        = aws_security_group.eks_nodes.id
  source_security_group_id = aws_security_group.fortiweb_internal.id
  description              = "ICMP from FortiWeb (health checks)"
}

# Ingress: Allow ICMP from EKS nodes to FortiWeb (responses)
resource "aws_security_group_rule" "fortiweb_internal_ingress_eks_icmp" {
  type                     = "ingress"
  from_port                = -1
  to_port                  = -1
  protocol                 = "icmp"
  security_group_id        = aws_security_group.fortiweb_internal.id
  source_security_group_id = aws_security_group.eks_nodes.id
  description              = "ICMP from EKS nodes"
}

# -----------------------------------------------------------------------------
# EKS Managed Security Group Rules
# -----------------------------------------------------------------------------
# EKS creates its own security group (cluster_security_group_id) that is
# attached to node ENIs. We need to add rules to this SG to allow FortiWeb
# traffic, since our custom eks_nodes SG is not used by the managed node group.
# -----------------------------------------------------------------------------

# Ingress: Allow ICMP from FortiWeb to EKS managed SG
resource "aws_security_group_rule" "eks_managed_ingress_fortiweb_icmp" {
  type                     = "ingress"
  from_port                = -1
  to_port                  = -1
  protocol                 = "icmp"
  security_group_id        = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  source_security_group_id = aws_security_group.fortiweb_internal.id
  description              = "ICMP from FortiWeb internal"
}

# Ingress: Allow TCP from FortiWeb to EKS managed SG (application traffic)
resource "aws_security_group_rule" "eks_managed_ingress_fortiweb_tcp" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "tcp"
  security_group_id        = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  source_security_group_id = aws_security_group.fortiweb_internal.id
  description              = "TCP from FortiWeb internal"
}

# Egress: Allow ICMP from FortiWeb to EKS managed SG
resource "aws_security_group_rule" "fortiweb_internal_icmp_to_eks_managed" {
  type                     = "egress"
  from_port                = -1
  to_port                  = -1
  protocol                 = "icmp"
  security_group_id        = aws_security_group.fortiweb_internal.id
  source_security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  description              = "ICMP to EKS managed SG"
}

# Egress: Allow TCP from FortiWeb to EKS managed SG (application traffic)
resource "aws_security_group_rule" "fortiweb_internal_tcp_to_eks_managed" {
  type                     = "egress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "tcp"
  security_group_id        = aws_security_group.fortiweb_internal.id
  source_security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  description              = "TCP to EKS managed SG"
}

# Ingress: Allow ICMP from EKS managed SG to FortiWeb (responses)
resource "aws_security_group_rule" "fortiweb_internal_ingress_eks_managed_icmp" {
  type                     = "ingress"
  from_port                = -1
  to_port                  = -1
  protocol                 = "icmp"
  security_group_id        = aws_security_group.fortiweb_internal.id
  source_security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  description              = "ICMP from EKS managed SG"
}

# Ingress: Allow TCP from EKS managed SG to FortiWeb (responses)
resource "aws_security_group_rule" "fortiweb_internal_ingress_eks_managed_tcp" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "tcp"
  security_group_id        = aws_security_group.fortiweb_internal.id
  source_security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  description              = "TCP from EKS managed SG"
}

# Egress: Allow ICMP from EKS managed SG to FortiWeb (responses)
resource "aws_security_group_rule" "eks_managed_egress_fortiweb_icmp" {
  type                     = "egress"
  from_port                = -1
  to_port                  = -1
  protocol                 = "icmp"
  security_group_id        = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  source_security_group_id = aws_security_group.fortiweb_internal.id
  description              = "ICMP to FortiWeb internal"
}

# Egress: Allow TCP from EKS managed SG to FortiWeb (responses)
resource "aws_security_group_rule" "eks_managed_egress_fortiweb_tcp" {
  type                     = "egress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "tcp"
  security_group_id        = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  source_security_group_id = aws_security_group.fortiweb_internal.id
  description              = "TCP to FortiWeb internal"
}
