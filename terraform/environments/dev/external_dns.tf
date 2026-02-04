# =============================================================================
# External-DNS Controller
# =============================================================================
# Automatically creates Route53 DNS records from Kubernetes resources.
# Uses IRSA for AWS authentication (no long-lived credentials).
#
# SUPPORTED SOURCES:
# ------------------
#   1. Ingress: annotation external-dns.alpha.kubernetes.io/hostname: app.amerintlxperts.com
#   2. DNSEndpoint CRD: Custom resources for programmatic DNS management
#
# HOW IT WORKS:
# -------------
#   1. External-DNS watches Ingress and DNSEndpoint resources
#   2. Creates/updates A record in Route53 pointing to target IP
#   3. When resource is deleted, DNS record is removed (sync policy)
#
# USAGE (Ingress):
# ----------------
#   Add these annotations to your Ingress:
#     external-dns.alpha.kubernetes.io/hostname: myapp.amerintlxperts.com
#     external-dns.alpha.kubernetes.io/ttl: "300"
#
# USAGE (DNSEndpoint):
# --------------------
#   apiVersion: externaldns.k8s.io/v1alpha1
#   kind: DNSEndpoint
#   metadata:
#     name: myapp-dns
#   spec:
#     endpoints:
#       - dnsName: myapp.amerintlxperts.com
#         recordType: A
#         targets:
#           - 1.2.3.4
#
# =============================================================================

resource "helm_release" "external_dns" {
  name             = "external-dns"
  repository       = "https://kubernetes-sigs.github.io/external-dns"
  chart            = "external-dns"
  version          = "1.14.3"
  namespace        = "external-dns"
  create_namespace = true

  # Increase timeout - pod may restart during IRSA token initialization
  timeout = 600

  # AWS provider configuration
  set {
    name  = "provider.name"
    value = "aws"
  }

  set {
    name  = "env[0].name"
    value = "AWS_DEFAULT_REGION"
  }

  set {
    name  = "env[0].value"
    value = var.region
  }

  # Only manage records for our domain
  set {
    name  = "domainFilters[0]"
    value = var.domain_name
  }

  # Sync policy: create and delete records (vs upsert-only which never deletes)
  set {
    name  = "policy"
    value = "sync"
  }

  # Watch Ingress and DNSEndpoint CRD resources
  set {
    name  = "sources[0]"
    value = "ingress"
  }

  set {
    name  = "sources[1]"
    value = "crd"
  }

  # TXT record prefix to identify records managed by external-dns
  set {
    name  = "txtOwnerId"
    value = local.cluster_name
  }

  # Prefix for TXT ownership records to avoid CNAME conflicts
  # Without this, external-dns tries to create both CNAME and TXT at same name
  # which DNS doesn't allow. This creates _externaldns.myapp.amerintlxperts.com TXT instead.
  set {
    name  = "txtPrefix"
    value = "_externaldns."
  }

  # Exclude ingresses with external-dns.alpha.kubernetes.io/exclude=true
  # This prevents ACME solver ingresses from conflicting with app DNS records
  set {
    name  = "annotationFilter"
    value = "external-dns.alpha.kubernetes.io/exclude notin (true)"
  }

  # IRSA: ServiceAccount annotation for AWS credentials
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.external_dns.arn
  }

  depends_on = [
    aws_route53_zone.main,
    aws_iam_role.external_dns,
    aws_eks_access_policy_association.ci # Ensure CI role has K8s access before Helm runs
  ]
}
