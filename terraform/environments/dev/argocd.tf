# =============================================================================
# ArgoCD - GitOps Continuous Delivery
# =============================================================================
# Installs ArgoCD for GitOps-based deployments. ArgoCD watches Git repositories
# and automatically synchronizes Kubernetes resources to match the desired state.
#
# HOW ARGOCD WORKS:
# -----------------
#   1. ArgoCD is installed in the cluster (this file handles that)
#   2. You define "Applications" that point to Git repos containing manifests
#   3. ArgoCD polls the repo (or receives webhooks) for changes
#   4. When changes are detected, ArgoCD syncs the cluster to match
#   5. The UI shows sync status, health, and provides manual controls
#
# ACCESS METHODS:
# ---------------
#   - Web UI: Port-forward to argocd-server service
#   - CLI: argocd CLI tool (authenticates via API)
#   - API: RESTful API for automation
#
# INITIAL SETUP AFTER INSTALL:
# ----------------------------
#   1. Get the initial admin password:
#      kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
#
#   2. Port-forward to access the UI:
#      kubectl port-forward svc/argocd-server -n argocd 8080:443
#
#   3. Login at https://localhost:8080 with:
#      Username: admin
#      Password: (from step 1)
#
#   4. Change the admin password via UI or CLI:
#      argocd login localhost:8080 --insecure
#      argocd account update-password
#
# APP OF APPS PATTERN:
# --------------------
#   Instead of defining each app manually in ArgoCD UI, use the "App of Apps"
#   pattern. Create one root Application that points to a Git directory
#   containing Application manifests. ArgoCD then manages all child apps.
#
#   Example root application (apply after ArgoCD is running):
#   ---
#   apiVersion: argoproj.io/v1alpha1
#   kind: Application
#   metadata:
#     name: root
#     namespace: argocd
#   spec:
#     project: default
#     source:
#       repoURL: https://github.com/amerintlxperts/infrastructure-2026
#       path: apps
#       targetRevision: main
#     destination:
#       server: https://kubernetes.default.svc
#       namespace: argocd
#     syncPolicy:
#       automated:
#         prune: true
#         selfHeal: true
#
# =============================================================================

# -----------------------------------------------------------------------------
# ArgoCD Helm Release
# -----------------------------------------------------------------------------
# Using the official Argo Helm chart. This is the standard way to install
# ArgoCD in production environments.
#
# Chart: https://github.com/argoproj/argo-helm/tree/main/charts/argo-cd
# Values: https://github.com/argoproj/argo-helm/blob/main/charts/argo-cd/values.yaml
#
# Note: Namespace is created by Helm (create_namespace = true) to avoid
# Terraform needing Kubernetes API access.
# -----------------------------------------------------------------------------

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "5.55.0" # Pin version for reproducibility

  # Wait for deployment to be ready
  wait    = true
  timeout = 600 # 10 minutes - ArgoCD can take a while on small nodes

  # -----------------------------------------------------------------------------
  # ArgoCD Configuration Values
  # -----------------------------------------------------------------------------
  # Minimalist dev configuration:
  #   - Single replica for each component (not HA)
  #   - No ingress (use port-forward)
  #   - Server runs insecure (TLS terminated elsewhere if needed)
  #   - Resource limits appropriate for t3.medium nodes
  # -----------------------------------------------------------------------------

  values = [
    yamlencode({
      # Global settings
      global = {
        # Add default labels to all resources
        additionalLabels = {
          environment = var.environment
          managed-by  = "terraform"
        }
      }

      # ArgoCD Server (API + UI)
      server = {
        # Single replica for dev
        replicas = 1

        # Run in insecure mode (no TLS) - we'll port-forward
        extraArgs = ["--insecure"]

        # Resource limits for t3.medium
        resources = {
          requests = {
            cpu    = "50m"
            memory = "128Mi"
          }
          limits = {
            cpu    = "500m"
            memory = "512Mi"
          }
        }

        # Service configuration
        service = {
          type = "ClusterIP"
        }
      }

      # Repository Server (clones and caches Git repos)
      repoServer = {
        replicas = 1

        resources = {
          requests = {
            cpu    = "50m"
            memory = "128Mi"
          }
          limits = {
            cpu    = "500m"
            memory = "512Mi"
          }
        }
      }

      # Application Controller (watches and syncs applications)
      controller = {
        replicas = 1

        resources = {
          requests = {
            cpu    = "100m"
            memory = "256Mi"
          }
          limits = {
            cpu    = "1000m"
            memory = "1Gi"
          }
        }
      }

      # Redis (caching)
      redis = {
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

      # Dex (OIDC provider) - disabled for dev, use built-in auth
      dex = {
        enabled = false
      }

      # ApplicationSet Controller - enables ApplicationSet CRD
      applicationSet = {
        enabled  = true
        replicas = 1

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

      # Notifications Controller - disabled for dev simplicity
      notifications = {
        enabled = false
      }

      # Config settings
      configs = {
        # Don't create the initial admin secret in values
        # (it's auto-created by ArgoCD)
        secret = {
          createSecret = true
        }

        # Repository credentials (none for public repos)
        repositories = {}

        # RBAC configuration
        rbac = {
          # Default policy: read-only for authenticated users
          "policy.default" = "role:readonly"
        }
      }
    })
  ]

  depends_on = [
    aws_eks_node_group.main,
    aws_eks_access_policy_association.ci
  ]
}

# -----------------------------------------------------------------------------
# Root Application (App of Apps)
# -----------------------------------------------------------------------------
# This bootstraps GitOps by creating a single "root" Application that points
# to your GitOps repository. ArgoCD will then discover and manage all other
# Applications defined in that repo.
#
# MONOREPO STRUCTURE:
# -------------------
#   eks-platform/
#   ├── terraform/                    # Infrastructure as Code
#   │   └── environments/dev/
#   ├── manifests-platform/           # Cluster services
#   │   ├── argocd/                   # ArgoCD Application definitions
#   │   │   ├── cert-manager.yaml
#   │   │   ├── external-secrets.yaml
#   │   │   └── platform-resources.yaml
#   │   └── resources/                # Actual K8s resources
#   │       ├── cert-manager/
#   │       └── external-secrets/
#   └── manifests-apps/               # Your applications
#       └── <app-name>/
#
# The root app watches 'manifests-platform/argocd/' and creates child Applications.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Wait for External Secrets to Sync ArgoCD Credentials
# -----------------------------------------------------------------------------
# The ExternalSecret needs time to sync the SSH key from Secrets Manager.
# Without this wait, the root app may be created before credentials are ready,
# causing ArgoCD to cache a "no credentials" error.
# -----------------------------------------------------------------------------

resource "time_sleep" "wait_for_argocd_credentials" {
  depends_on = [kubectl_manifest.argocd_repo_credentials]

  create_duration = "30s"
}

resource "kubectl_manifest" "argocd_root_app" {
  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name       = "root"
      namespace  = "argocd"
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.gitops_repo_url
        path           = var.gitops_apps_path
        targetRevision = var.gitops_target_revision
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }
      syncPolicy = {
        automated = {
          prune    = true # Delete resources removed from Git
          selfHeal = true # Revert manual changes
        }
        syncOptions = [
          "CreateNamespace=true"
        ]
      }
    }
  })

  depends_on = [
    helm_release.argocd,
    time_sleep.wait_for_argocd_credentials
  ]
}
