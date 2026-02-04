# Data Flow Diagrams

## Deployment Flow (GitOps)

```mermaid
sequenceDiagram
    participant Dev as Developer
    participant GH as GitHub
    participant Flux as FluxCD
    participant K8s as Kubernetes API
    participant Pod as Application Pod
    participant ECR as ECR Cache
    participant GHCR as GHCR

    Dev->>GH: git push (manifests)
    Note over GH: PR merged to main

    loop Every 1 minute
        Flux->>GH: Check for changes
        GH-->>Flux: New commits detected
    end

    Flux->>K8s: Apply manifests
    K8s->>Pod: Create/Update Pod

    Pod->>ECR: Pull image

    alt Image not cached
        ECR->>GHCR: Fetch image
        GHCR-->>ECR: Image data
        ECR-->>Pod: Cached image
    else Image cached
        ECR-->>Pod: Cached image
    end

    Pod->>Pod: Container starts
```

## Secret Synchronization Flow

```mermaid
sequenceDiagram
    participant Admin as Administrator
    participant SM as AWS Secrets Manager
    participant ESO as External Secrets Operator
    participant K8s as Kubernetes API
    participant Pod as Application Pod

    Admin->>SM: Create/Update secret
    Note over SM: Secret stored encrypted

    loop Every refresh interval (1h default)
        ESO->>SM: GetSecretValue (via IRSA)
        SM-->>ESO: Secret data
        ESO->>K8s: Create/Update K8s Secret
    end

    Pod->>K8s: Mount secret volume
    K8s-->>Pod: Secret data

    Note over Pod: Uses DATABASE_URL env var
```

## Request Flow (Ingress)

```mermaid
sequenceDiagram
    participant User as End User
    participant DNS as Route 53
    participant FW as FortiWeb
    participant SVC as K8s Service
    participant Pod as Application Pod
    participant AWS as AWS Services

    User->>DNS: app.example.com
    DNS-->>User: FortiWeb IP

    User->>FW: HTTPS Request
    Note over FW: TLS Termination
    Note over FW: WAF Inspection

    FW->>SVC: HTTP Request
    SVC->>Pod: Route to healthy pod

    Pod->>AWS: Call AWS API (IRSA)
    AWS-->>Pod: Response

    Pod-->>SVC: HTTP Response
    SVC-->>FW: Response
    FW-->>User: HTTPS Response
```

## Observability Flow

```mermaid
flowchart LR
    subgraph "EKS Cluster"
        subgraph "Node"
            Pod[Application Pod]
            FB[Fluent Bit]
            CWA[CloudWatch Agent]
        end
    end

    subgraph "AWS CloudWatch"
        CWL[CloudWatch Logs]
        CWM[CloudWatch Metrics]
        CI[Container Insights]
        Dash[Dashboards]
        Alarm[Alarms]
    end

    Pod -->|stdout/stderr| FB
    FB -->|logs| CWL

    Pod -->|metrics| CWA
    CWA -->|metrics| CWM
    CWA -->|performance| CI

    CWL --> Dash
    CWM --> Dash
    CI --> Dash

    CWM --> Alarm
    Alarm -->|notify| SNS[SNS Topic]
```

## Infrastructure Provisioning Flow

```mermaid
flowchart TB
    subgraph "Developer Machine"
        TF[Terraform CLI]
        TFVARS[terraform.tfvars]
    end

    subgraph "AWS"
        S3[S3 Backend<br/>State Storage]
        DDB[DynamoDB<br/>State Locking]

        subgraph "Resources Created"
            VPC[VPC]
            EKS[EKS Cluster]
            NG[Node Groups]
            IAM[IAM Roles]
            ECR2[ECR Repos]
        end
    end

    subgraph "GitHub"
        REPO[eks-infrastructure<br/>repository]
    end

    REPO -->|clone| TF
    TF -->|read| TFVARS
    TF -->|read/write state| S3
    TF -->|lock state| DDB
    TF -->|create| VPC
    TF -->|create| EKS
    TF -->|create| NG
    TF -->|create| IAM
    TF -->|create| ECR2
```

## Image Build and Deploy Flow

```mermaid
flowchart LR
    subgraph "Developer"
        Code[Source Code]
    end

    subgraph "GitHub"
        GHA[GitHub Actions]
        GHCR2[GHCR]
        GitOps[gitops-platform<br/>repo]
    end

    subgraph "AWS"
        ECR3[ECR Cache]

        subgraph "EKS"
            Flux2[FluxCD]
            Pod2[New Pod]
        end
    end

    Code -->|push| GHA
    GHA -->|build & push| GHCR2
    GHA -->|update image tag| GitOps

    Flux2 -->|detect change| GitOps
    Flux2 -->|deploy| Pod2
    Pod2 -->|pull image| ECR3
    ECR3 -->|cache miss| GHCR2
```

## Key Flow Characteristics

| Flow | Trigger | Latency | Failure Mode |
|------|---------|---------|--------------|
| **Deployment** | Git push | 1-5 minutes | FluxCD retry with backoff |
| **Secret Sync** | Scheduled (1h) | Near-instant | ESO retry, K8s secret unchanged |
| **Request** | User action | <100ms (target) | FortiWeb failover, pod restart |
| **Observability** | Continuous | 1-5 minutes | Buffer in Fluent Bit |
| **Infrastructure** | Manual | 10-30 minutes | Terraform state rollback |
