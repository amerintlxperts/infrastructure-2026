# System Overview Diagram

## High-Level Architecture

```mermaid
graph TB
    subgraph "External"
        DEV[Developer]
        GH[GitHub<br/>amerintlxperts org]
        GHCR[GitHub Container<br/>Registry]
    end

    subgraph "AWS Cloud - ca-central-1"
        subgraph "VPC"
            subgraph "Public Subnets"
                FW[FortiWeb<br/>WAF/Ingress]
                NAT[NAT Gateway]
            end

            subgraph "Private Subnets"
                subgraph "EKS Cluster"
                    CP[Control Plane<br/>Managed by AWS]

                    subgraph "Node Group"
                        N1[Node 1<br/>t3.medium]
                        N2[Node 2<br/>t3.medium]
                    end

                    subgraph "System Pods"
                        FLUX[FluxCD]
                        ESO[External Secrets<br/>Operator]
                        CW[CloudWatch<br/>Agent]
                        FB[Fluent Bit]
                    end

                    subgraph "Application Pods"
                        APP1[App 1]
                        APP2[App 2]
                        EMB[Embedding<br/>Service]
                    end
                end
            end
        end

        subgraph "AWS Services"
            ECR[ECR<br/>Pull-through Cache]
            SM[Secrets Manager]
            CWL[CloudWatch Logs]
            CWM[CloudWatch Metrics]
            SSM[SSM Parameters]
        end

        subgraph "VPC Endpoints"
            VPCE[Interface Endpoints<br/>ECR, SM, Logs, STS]
        end
    end

    DEV -->|kubectl| CP
    DEV -->|git push| GH
    GH -->|FluxCD sync| FLUX
    GHCR -->|images| ECR
    ECR -->|pull| N1
    ECR -->|pull| N2

    FLUX -->|deploy| APP1
    FLUX -->|deploy| APP2
    FLUX -->|deploy| EMB

    ESO -->|sync secrets| SM
    FB -->|logs| CWL
    CW -->|metrics| CWM

    FW -->|ingress| APP1
    N1 ---|pods| APP1
    N2 ---|pods| APP2

    APP1 -->|IRSA| SM
    APP2 -->|IRSA| SM

    style CP fill:#ff9900
    style FLUX fill:#326ce5
    style ESO fill:#326ce5
    style FW fill:#da3b01
```

## Component Descriptions

### External Components

| Component | Purpose |
|-----------|---------|
| **Developer** | Interacts via kubectl and git |
| **GitHub (amerintlxperts)** | Hosts infrastructure and GitOps repositories |
| **GHCR** | Source container registry for application images |

### VPC Components

| Component | Purpose |
|-----------|---------|
| **FortiWeb** | WAF and ingress controller, routes external traffic |
| **NAT Gateway** | Outbound internet access for nodes |
| **EKS Control Plane** | Managed Kubernetes API server |
| **Node Group** | EC2 instances running pods |

### System Pods

| Component | Purpose |
|-----------|---------|
| **FluxCD** | GitOps operator, syncs from GitHub |
| **External Secrets Operator** | Syncs secrets from AWS Secrets Manager |
| **CloudWatch Agent** | Collects container metrics |
| **Fluent Bit** | Ships logs to CloudWatch Logs |

### AWS Services

| Service | Purpose |
|---------|---------|
| **ECR** | Container registry with GHCR pull-through cache |
| **Secrets Manager** | Stores application secrets |
| **CloudWatch** | Logs, metrics, and monitoring |
| **SSM Parameters** | Non-sensitive configuration values |

## Data Flow Summary

1. **Deployment Flow**: Git push → GitHub → FluxCD → Kubernetes API → Pods
2. **Image Pull Flow**: GHCR → ECR (cache) → Node → Pod
3. **Secret Flow**: Secrets Manager → ESO → Kubernetes Secret → Pod
4. **Ingress Flow**: Internet → FortiWeb → Service → Pod
5. **Observability Flow**: Pod → Fluent Bit/CW Agent → CloudWatch
