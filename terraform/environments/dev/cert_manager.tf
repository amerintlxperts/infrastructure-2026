# =============================================================================
# Cert-Manager
# =============================================================================
# Installs cert-manager via Helm with IRSA configuration for DNS-01 challenges.
# This is managed by Terraform (not ArgoCD) because:
#   1. The IRSA role ARN contains AWS account ID which we keep out of Git
#   2. DNS-01 challenges require Route53 access via IRSA
#
# HOW CERT-MANAGER WORKS:
# -----------------------
#   1. cert-manager controller watches Certificate resources
#   2. For DNS-01 challenges, it creates TXT records in Route53
#   3. Let's Encrypt verifies domain ownership via DNS
#   4. cert-manager stores the certificate in a Kubernetes Secret
#
# AFTER THIS IS DEPLOYED:
# -----------------------
#   1. ClusterIssuers are created via platform-resources
#   2. Create Certificate resources or use ingress annotations
#
# =============================================================================

# -----------------------------------------------------------------------------
# Cert-Manager Helm Release
# -----------------------------------------------------------------------------
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.16.1"

  wait    = true
  timeout = 300

  values = [
    yamlencode({
      # Install CRDs
      installCRDs = true

      # ServiceAccount with IRSA annotation for Route53 access
      serviceAccount = {
        create = true
        name   = "cert-manager"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.cert_manager.arn
        }
      }

      # DNS configuration for ACME challenges
      # Uses public DNS to verify domain ownership
      dns01RecursiveNameserversOnly = true
      dns01RecursiveNameservers     = "8.8.8.8:53,1.1.1.1:53"

      # Resource limits for t3.medium nodes
      resources = {
        requests = {
          cpu    = "50m"
          memory = "64Mi"
        }
        limits = {
          cpu    = "200m"
          memory = "256Mi"
        }
      }

      webhook = {
        resources = {
          requests = {
            cpu    = "20m"
            memory = "32Mi"
          }
          limits = {
            cpu    = "100m"
            memory = "128Mi"
          }
        }
      }

      cainjector = {
        resources = {
          requests = {
            cpu    = "50m"
            memory = "64Mi"
          }
          limits = {
            cpu    = "200m"
            memory = "256Mi"
          }
        }
      }
    })
  ]

  depends_on = [
    aws_eks_node_group.main,
    aws_iam_role.cert_manager,
    aws_eks_access_policy_association.ci
  ]
}

# -----------------------------------------------------------------------------
# Wait for Cert-Manager Webhook
# -----------------------------------------------------------------------------
# The webhook needs time to become ready before ClusterIssuers can be created.
# -----------------------------------------------------------------------------

resource "null_resource" "wait_for_cert_manager_webhook" {
  triggers = {
    helm_release_id = helm_release.cert_manager.id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.main.name} --kubeconfig /tmp/kubeconfig-cm
      export KUBECONFIG=/tmp/kubeconfig-cm

      echo "Waiting for cert-manager webhook deployment to be ready..."
      kubectl wait --for=condition=available deployment/cert-manager-webhook \
        -n cert-manager --timeout=120s

      echo "Waiting for webhook endpoint to be populated..."
      for i in {1..30}; do
        ENDPOINTS=$(kubectl get endpoints cert-manager-webhook -n cert-manager -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")
        if [ -n "$ENDPOINTS" ]; then
          echo "Webhook endpoint ready: $ENDPOINTS"
          break
        fi
        echo "Waiting for endpoint... ($i/30)"
        sleep 2
      done

      rm -f /tmp/kubeconfig-cm
    EOT
  }

  depends_on = [helm_release.cert_manager]
}
