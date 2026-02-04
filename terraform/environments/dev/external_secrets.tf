# =============================================================================
# External Secrets Operator
# =============================================================================
# Installs External Secrets Operator via Helm with IRSA configuration.
# This is managed by Terraform (not ArgoCD) because:
#   1. It's a platform bootstrap component required for GitOps to work
#   2. The IRSA role ARN contains AWS account ID which we keep out of Git
#   3. It must be running before other applications can sync their secrets
#
# HOW EXTERNAL SECRETS WORKS:
# ---------------------------
#   1. ESO controller watches ExternalSecret resources in the cluster
#   2. When found, it reads from AWS Secrets Manager using IRSA credentials
#   3. Creates/updates Kubernetes Secrets with the retrieved values
#   4. Periodically refreshes based on refreshInterval
#
# AFTER THIS IS DEPLOYED:
# -----------------------
#   1. Create ClusterSecretStore (in manifests-platform/resources/)
#   2. Create ExternalSecrets for your applications
#   3. Reference the synced Secrets in your Deployments
#
# =============================================================================

# -----------------------------------------------------------------------------
# External Secrets Helm Release
# -----------------------------------------------------------------------------
# Using the official External Secrets Helm chart.
#
# Chart: https://github.com/external-secrets/external-secrets
# Values: https://github.com/external-secrets/external-secrets/blob/main/deploy/charts/external-secrets/values.yaml
#
# Note: Namespace is created by Helm (create_namespace = true) to avoid
# Terraform needing Kubernetes API access via the kubernetes provider.
# -----------------------------------------------------------------------------

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "0.9.11" # Pin version for reproducibility

  wait    = true
  timeout = 300 # 5 minutes

  values = [
    yamlencode({
      # ServiceAccount with IRSA annotation
      serviceAccount = {
        create = true
        name   = "external-secrets"
        annotations = {
          # This injects the IRSA role ARN - keeps AWS account ID out of Git
          "eks.amazonaws.com/role-arn" = aws_iam_role.external_secrets.arn
        }
      }

      # Install CRDs
      installCRDs = true

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

      # Webhook configuration
      webhook = {
        create = true
        resources = {
          requests = {
            cpu    = "25m"
            memory = "32Mi"
          }
          limits = {
            cpu    = "100m"
            memory = "128Mi"
          }
        }
      }

      # Cert controller resources
      certController = {
        resources = {
          requests = {
            cpu    = "25m"
            memory = "32Mi"
          }
          limits = {
            cpu    = "100m"
            memory = "128Mi"
          }
        }
      }
    })
  ]

  depends_on = [
    aws_eks_node_group.main,
    aws_iam_role.external_secrets,
    aws_eks_access_policy_association.ci
  ]
}

# -----------------------------------------------------------------------------
# Wait for External Secrets Webhook
# -----------------------------------------------------------------------------
# The Helm release completes when resources are created, but the webhook
# needs additional time to become ready and register with the API server.
# Without this wait, ClusterSecretStore creation fails with:
#   "failed calling webhook: Address is not allowed"
#
# Uses kubectl wait instead of time_sleep for deterministic readiness.
# -----------------------------------------------------------------------------

resource "null_resource" "wait_for_external_secrets_webhook" {
  triggers = {
    helm_release_id = helm_release.external_secrets.id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.main.name} --kubeconfig /tmp/kubeconfig-eso
      export KUBECONFIG=/tmp/kubeconfig-eso

      echo "Waiting for External Secrets webhook deployment to be ready..."
      kubectl wait --for=condition=available deployment/external-secrets-webhook \
        -n external-secrets --timeout=120s

      echo "Waiting for webhook endpoint to be populated..."
      for i in {1..30}; do
        ENDPOINTS=$(kubectl get endpoints external-secrets-webhook -n external-secrets -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")
        if [ -n "$ENDPOINTS" ]; then
          echo "Webhook endpoint ready: $ENDPOINTS"
          break
        fi
        echo "Waiting for endpoint... ($i/30)"
        sleep 2
      done

      rm -f /tmp/kubeconfig-eso
    EOT
  }

  depends_on = [helm_release.external_secrets]
}

# -----------------------------------------------------------------------------
# ClusterSecretStore - AWS Secrets Manager
# -----------------------------------------------------------------------------
# Deployed via Terraform (not ArgoCD) to break chicken-and-egg problem:
# ArgoCD needs credentials → ExternalSecret needs ClusterSecretStore →
# ClusterSecretStore in ArgoCD → ArgoCD needs credentials
#
# By deploying this via Terraform, External Secrets can sync the ArgoCD
# repo credentials before ArgoCD tries to sync from the private repo.
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "cluster_secret_store" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ClusterSecretStore"
    metadata = {
      name = "aws-secrets-manager"
    }
    spec = {
      provider = {
        aws = {
          service = "SecretsManager"
          region  = var.region
          auth = {
            jwt = {
              serviceAccountRef = {
                name      = "external-secrets"
                namespace = "external-secrets"
              }
            }
          }
        }
      }
    }
  })

  depends_on = [null_resource.wait_for_external_secrets_webhook]
}

# -----------------------------------------------------------------------------
# ArgoCD Repository Credentials ExternalSecret
# -----------------------------------------------------------------------------
# Syncs the SSH private key from AWS Secrets Manager to a Kubernetes secret
# that ArgoCD uses for Git repository authentication.
#
# The SSH key is generated by hydrate.sh and stored in Secrets Manager.
# This must be deployed via Terraform (not ArgoCD) because ArgoCD needs
# these credentials before it can sync from the private repository.
# -----------------------------------------------------------------------------

resource "kubectl_manifest" "argocd_repo_credentials" {
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "repo-github-ssh"
      namespace = "argocd"
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "aws-secrets-manager"
        kind = "ClusterSecretStore"
      }
      target = {
        name           = "repo-github-ssh"
        creationPolicy = "Owner"
        template = {
          metadata = {
            labels = {
              "argocd.argoproj.io/secret-type" = "repository"
            }
          }
          data = {
            type          = "git"
            url           = "git@github.com:${var.github_org}/${var.github_repo}.git"
            sshPrivateKey = "{{ .sshPrivateKey }}"
          }
        }
      }
      data = [{
        secretKey = "sshPrivateKey"
        remoteRef = {
          key = "${var.environment}/argocd-repo-ssh"
        }
      }]
    }
  })

  depends_on = [
    kubectl_manifest.cluster_secret_store,
    helm_release.argocd
  ]
}
