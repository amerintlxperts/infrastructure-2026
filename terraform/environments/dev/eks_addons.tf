# =============================================================================
# EKS Add-ons
# =============================================================================
# Managed add-ons for core Kubernetes functionality.
# AWS manages updates and compatibility for these components.
#
# VPC CNI:    Pod networking - pods get VPC IPs directly
# CoreDNS:    Cluster DNS for service discovery
# kube-proxy: Service networking (iptables/IPVS rules)
# =============================================================================

# -----------------------------------------------------------------------------
# Add-on Version Data Sources
# -----------------------------------------------------------------------------
# Fetch the latest compatible version for each add-on.
# Using most_recent = true ensures we get the latest patch version.
# -----------------------------------------------------------------------------

data "aws_eks_addon_version" "vpc_cni" {
  addon_name         = "vpc-cni"
  kubernetes_version = aws_eks_cluster.main.version
  most_recent        = true
}

data "aws_eks_addon_version" "coredns" {
  addon_name         = "coredns"
  kubernetes_version = aws_eks_cluster.main.version
  most_recent        = true
}

data "aws_eks_addon_version" "kube_proxy" {
  addon_name         = "kube-proxy"
  kubernetes_version = aws_eks_cluster.main.version
  most_recent        = true
}

# -----------------------------------------------------------------------------
# VPC CNI Add-on
# -----------------------------------------------------------------------------
# Provides pod networking by assigning VPC IPs directly to pods.
# This means pods get routable IPs from our subnet ranges.
# FortiWeb can reach pod IPs directly via VPC routing.
#
# Network Policy is enabled for pod-to-pod traffic control.
# -----------------------------------------------------------------------------

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"

  addon_version = data.aws_eks_addon_version.vpc_cni.version

  # Don't remove on destroy - pods need networking
  preserve = true

  # Resolve conflicts by overwriting manual changes
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    enableNetworkPolicy = "true"
  })

  tags = {
    Name = "${local.cluster_name}-vpc-cni"
  }
}

# -----------------------------------------------------------------------------
# CoreDNS Add-on
# -----------------------------------------------------------------------------
# Provides cluster DNS for service discovery.
# Pods use this to resolve service names to ClusterIPs.
#
# Note: CoreDNS requires at least one node to be running.
# It will be pending until nodes are created in Module 3.
# -----------------------------------------------------------------------------

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"

  addon_version = data.aws_eks_addon_version.coredns.version

  preserve = true

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # Don't wait forever - CoreDNS stays DEGRADED until nodes exist
  timeouts {
    create = "10m"
  }

  tags = {
    Name = "${local.cluster_name}-coredns"
  }

  # CoreDNS pods need nodes to run on
  depends_on = [aws_eks_node_group.main]
}

# -----------------------------------------------------------------------------
# kube-proxy Add-on
# -----------------------------------------------------------------------------
# Manages iptables/IPVS rules for Kubernetes Services.
# Routes traffic from ClusterIP/NodePort to pod endpoints.
# -----------------------------------------------------------------------------

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "kube-proxy"

  addon_version = data.aws_eks_addon_version.kube_proxy.version

  preserve = true

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = {
    Name = "${local.cluster_name}-kube-proxy"
  }

  # Deploy after nodes so DaemonSet pods can be scheduled
  depends_on = [aws_eks_node_group.main]
}
