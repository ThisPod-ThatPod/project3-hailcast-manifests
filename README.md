# Hailcast Kubernetes Manifests

Hailcast 애플리케이션과 플랫폼 애드온의 Kubernetes **desired state**를 관리하는 GitOps 저장소입니다.

Argo CD가 `dev` 브랜치를 감시하며 **App-of-Apps** 구조를 통해 클러스터 상태를 Git에 선언된 상태와 지속적으로 동기화합니다.

애플리케이션 소스 코드와 AWS 인프라(Terraform)는 이 저장소의 관리 범위에 포함되지 않습니다.

---

# GitOps 구조

```text
argocd/app-of-apps.yaml
        └── argocd/applications/*.yaml
              ├── apps/       애플리케이션 워크로드
              ├── addons/     클러스터 애드온 및 관측 플랫폼
              └── platform/   Secret 연동 및 PrometheusRule
```

`hailcast-root` Application이 `argocd/applications` 아래의 Child Application을 등록하며, 각 Application은 Argo CD 자동 동기화 정책을 기반으로 선언된 상태를 유지합니다.

리소스 적용 순서는 **Sync Wave**로 제어됩니다.

| Wave | 대상 |
|------|------|
| `-2` | Metrics Server |
| `-1` | AWS Load Balancer Controller, External Secrets, Karpenter, KEDA, kube-prometheus-stack |
| `0` | Grafana Dashboard, PrometheusRule, OpenCost |
| `1` | 애플리케이션 ExternalSecret |
| `2` | Hailcast 애플리케이션 |

런타임에서 변경되는 일부 리소스(예: Worker Deployment replica, KEDA ScaledObject의 `minReplicaCount`)는 Argo CD가 운영 중인 값을 되돌리지 않도록 필요한 diff 예외가 적용되어 있습니다.

---

# 관리 대상

## 애플리케이션

- **call-api**
  - Deployment
  - Service
  - Ingress
  - ServiceAccount

- **frontend**
  - Deployment
  - Service
  - Ingress

- **predict**
  - Deployment
  - Service
  - Ingress
  - ServiceAccount
  - ServiceMonitor
  - RBAC

- **simulator**
  - Deployment
  - Service
  - ServiceAccount

- **weather-cron**
  - Deployment
  - Service
  - ServiceAccount

- **worker**
  - Deployment
  - ServiceAccount
  - KEDA ScaledObject
  - TriggerAuthentication

---

## 플랫폼 및 관측

- AWS Load Balancer Controller
- External Secrets Operator
- SecretStore / ExternalSecret
- Karpenter
- KEDA
- Metrics Server
- kube-prometheus-stack
  - Prometheus
  - Grafana
  - Alertmanager
- Hailcast Grafana Dashboard
- Hailcast PrometheusRule
- OpenCost

외부 Helm Chart 버전과 values는 각 Argo CD Application에서 관리합니다.

---

# 저장소 구조

```text
.
├── apps/                  # Hailcast 애플리케이션 Manifest
├── addons/                # Helm Values 및 애드온 리소스
├── argocd/
│   ├── app-of-apps.yaml   # Root Application
│   └── applications/      # Child Application
├── platform/
│   ├── external-secrets/  # ExternalSecret, SecretStore
│   └── monitoring/        # PrometheusRule
├── scripts/               # 검증 및 운영 보조 스크립트
├── Makefile               # 공통 운영 명령
└── README.md
```

민감한 운영 자료와 자격증명 관리 절차는 별도 저장소에서 관리합니다.

이 Public 저장소에는 Secret 실값이나 민감한 정보를 저장하지 않습니다.

---

# 사전 조건

- Kubernetes Cluster 접근 권한
- 올바른 `kubectl` Context
- Argo CD 설치 (`make install-argocd`로 최초 설치 가능, `applications.argoproj.io` CRD로 설치 여부 확인)
- `make`
- `bash`
- `kubectl`
- `jq`
- `helm` (`make install-argocd` 실행 시 필요)
- Manifest가 참조하는 AWS IAM Role 및 리소스
- AWS Secrets Manager / Parameter Store 값

---

# 검증

클러스터에 적용하지 않고 Manifest와 운영 스크립트를 검증합니다.

```bash
make validate
```

Root Application을 서버 측 Dry Run으로 검증하려면 다음을 실행합니다.

```bash
make deploy-dry-run
```

---

# 배포

Argo CD가 클러스터에 없다면 먼저 설치합니다(Helm 기반, 멱등 — 이미 있으면 건너뜀).

```bash
make install-argocd
```

Root Application을 최초 등록하거나 GitOps 배포를 시작합니다.

```bash
make deploy
```

현재 Application 및 Hailcast 워크로드 상태를 확인합니다.

```bash
make status
```

ArgoCD Application을 삭제하고 Ingress/ALB 소거까지 확인합니다(`CONFIRM=yes` 필요).

```bash
make teardown   # 또는 make destroy (동일)
```

---

# 운영 원칙

- 클러스터의 Desired State는 Git을 단일 진실의 원천(Source of Truth)으로 관리합니다.
- 이미지는 CI가 `<GITHUB_SHA>` 태그를 갱신하며, 사람이 직접 수정하지 않습니다.
- 런타임에서 변경되는 리소스는 필요한 범위에서만 Argo CD diff 예외를 적용합니다.
- Child Application이나 개별 Manifest를 직접 적용하기보다 Root Application과 Argo CD 동기화를 공식 배포 진입점으로 사용합니다.