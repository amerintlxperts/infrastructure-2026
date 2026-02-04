# Kubernetes Resource Schemas

Reference schemas for key Kubernetes resources used in this platform.

## FluxCD Resources

### GitRepository

Source for Git repositories.

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: gitops-platform
  namespace: flux-system
spec:
  # Polling interval
  interval: 1m

  # Repository URL (HTTPS for GitHub App auth)
  url: https://github.com/amerintlxperts/gitops-platform

  # Branch/tag/commit reference
  ref:
    branch: main
    # OR: tag: v1.0.0
    # OR: commit: abc123

  # Secret containing credentials
  secretRef:
    name: flux-system

  # Ignore paths (optional)
  ignore: |
    # Exclude CI files
    .github/
    # Exclude docs
    *.md
```

### Kustomization

Reconciles Kustomize overlays.

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: app-name
  namespace: flux-system
spec:
  # Reconciliation interval
  interval: 5m

  # Retry interval on failure
  retryInterval: 1m

  # Timeout for apply
  timeout: 5m

  # Source reference
  sourceRef:
    kind: GitRepository
    name: gitops-platform

  # Path within repository
  path: ./apps/app-name/overlays/dev

  # Delete resources removed from Git
  prune: true

  # Wait for resources to be ready
  wait: true

  # Dependencies
  dependsOn:
    - name: infrastructure

  # Target namespace (if not in manifests)
  targetNamespace: app-namespace

  # Patches applied to all resources
  patches:
    - patch: |
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: all
        spec:
          template:
            spec:
              nodeSelector:
                role: apps
      target:
        kind: Deployment

  # Health checks
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: app-name
      namespace: app-namespace
```

### HelmRelease

Manages Helm chart installations.

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: external-secrets
  namespace: external-secrets
spec:
  # Reconciliation interval
  interval: 1h

  # Chart specification
  chart:
    spec:
      chart: external-secrets
      version: "0.9.x"  # Semver constraint
      sourceRef:
        kind: HelmRepository
        name: external-secrets
        namespace: flux-system

  # Helm install options
  install:
    createNamespace: true
    remediation:
      retries: 3

  # Helm upgrade options
  upgrade:
    remediation:
      retries: 3
      remediateLastFailure: true

  # Values inline
  values:
    serviceAccount:
      annotations:
        eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT:role/eso-role
    replicaCount: 2

  # Values from ConfigMap/Secret
  valuesFrom:
    - kind: ConfigMap
      name: chart-values
      valuesKey: values.yaml
```

### HelmRepository

Source for Helm charts.

```yaml
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: HelmRepository
metadata:
  name: external-secrets
  namespace: flux-system
spec:
  interval: 1h
  url: https://charts.external-secrets.io
  # For OCI registries:
  # type: oci
  # url: oci://registry.example.com/charts
```

## External Secrets Resources

### ClusterSecretStore

Cluster-wide secret store configuration.

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: ca-central-1

      # IRSA authentication
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
```

### ExternalSecret

Syncs a secret from external store.

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: app-secrets
  namespace: app-namespace
spec:
  # Refresh interval
  refreshInterval: 1h

  # Reference to store
  secretStoreRef:
    kind: ClusterSecretStore
    name: aws-secrets-manager

  # Target K8s secret
  target:
    name: app-secrets
    creationPolicy: Owner
    template:
      type: Opaque
      data:
        # Template with values
        config.json: |
          {
            "database": "{{ .DATABASE_URL }}",
            "api_key": "{{ .API_KEY }}"
          }

  # Data mappings
  data:
    # Single property from JSON secret
    - secretKey: DATABASE_URL
      remoteRef:
        key: dev/app/database
        property: url

    # Entire secret as single key
    - secretKey: API_KEY
      remoteRef:
        key: dev/app/api-key

  # Or use dataFrom for all keys
  dataFrom:
    - extract:
        key: dev/app/all-secrets
```

## Application Resources

### Deployment

Standard application deployment.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-name
  labels:
    app: app-name
spec:
  replicas: 2

  selector:
    matchLabels:
      app: app-name

  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0

  template:
    metadata:
      labels:
        app: app-name
    spec:
      # Service account for IRSA
      serviceAccountName: app-name

      containers:
        - name: app
          # ECR pull-through cache image reference
          image: ACCOUNT.dkr.ecr.ca-central-1.amazonaws.com/ghcr/amerintlxperts/app:v1.0.0

          ports:
            - containerPort: 8080
              name: http

          # Environment from secrets
          envFrom:
            - secretRef:
                name: app-secrets

          # Resource limits
          resources:
            requests:
              memory: "128Mi"
              cpu: "100m"
            limits:
              memory: "256Mi"
              cpu: "500m"

          # Health checks
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10

          readinessProbe:
            httpGet:
              path: /ready
              port: http
            initialDelaySeconds: 5
            periodSeconds: 5

          # Security context
          securityContext:
            runAsNonRoot: true
            readOnlyRootFilesystem: true
```

### Service

Exposes deployment internally.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: app-name
spec:
  selector:
    app: app-name

  ports:
    - port: 80
      targetPort: http
      name: http

  type: ClusterIP
```

### ServiceAccount (with IRSA)

Service account with IAM role.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: app-name
  annotations:
    # IRSA annotation
    eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT:role/app-name-role
```

### Ingress (FortiWeb)

Ingress resource for FortiWeb.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-ingress
  annotations:
    # FortiWeb-specific annotations
    fortiweb.fortinet.com/policy: "standard-waf"
    fortiweb.fortinet.com/ssl-certificate: "app-cert"
spec:
  ingressClassName: fortiweb

  tls:
    - hosts:
        - app.example.com
      secretName: app-tls

  rules:
    - host: app.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: app-name
                port:
                  number: 80
```

### HorizontalPodAutoscaler

Auto-scaling based on metrics.

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: app-name
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: app-name

  minReplicas: 2
  maxReplicas: 10

  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70

    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 80

  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Percent
          value: 10
          periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - type: Percent
          value: 100
          periodSeconds: 15
```

## Kustomize Patterns

### Base kustomization.yaml

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - deployment.yaml
  - service.yaml
  - serviceaccount.yaml
  - hpa.yaml

commonLabels:
  app.kubernetes.io/name: app-name
  app.kubernetes.io/part-of: platform
```

### Overlay kustomization.yaml

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: app-namespace

resources:
  - ../../base

# Environment-specific patches
patches:
  - path: deployment-patch.yaml

# Image replacement
images:
  - name: ghcr.io/amerintlxperts/app
    newName: ACCOUNT.dkr.ecr.ca-central-1.amazonaws.com/ghcr/amerintlxperts/app
    newTag: v1.2.3

# ConfigMap from files
configMapGenerator:
  - name: app-config
    files:
      - config.yaml

# Replicas override
replicas:
  - name: app-name
    count: 3
```

### Patch Example

```yaml
# deployment-patch.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-name
spec:
  template:
    spec:
      containers:
        - name: app
          resources:
            limits:
              memory: "512Mi"
          env:
            - name: ENVIRONMENT
              value: "dev"
```
