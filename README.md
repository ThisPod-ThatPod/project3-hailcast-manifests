# Hailcast Kubernetes Manifests

Hailcast는 기상 데이터와 실제 호출 흐름을 바탕으로 택시 호출 수요를 예측하고, 예측 결과와 실시간 큐 적체를 함께 사용해 Worker 규모를 조절하는 AI 기반 서비스입니다. 예측에 따른 선제 확장, SQS 적체에 반응하는 KEDA 확장, 늘어난 Pod를 수용하기 위한 Karpenter 노드 공급 과정을 하나의 흐름으로 구현합니다.

이 저장소는 Hailcast 애플리케이션과 플랫폼 구성의 Kubernetes **desired state**를 관리하는 GitOps 저장소입니다. Argo CD가 `dev` 브랜치를 감시하며 App-of-Apps 구조로 클러스터 상태를 Git에 선언된 상태와 지속적으로 동기화합니다.

## 이 저장소의 역할과 관리 범위

이 저장소가 관리하는 범위는 다음과 같습니다.

- Hailcast 애플리케이션 6개의 Kubernetes 리소스
- AWS 연계 Controller와 오토스케일링 구성
- Prometheus, Grafana, Alertmanager, OpenCost 관측 구성
- External Secrets Operator를 통한 RDS Secret 연동
- Argo CD Root/Child Application과 Sync Wave
- 검증, 배포, 상태 확인, teardown 진입점

다음 항목은 이 저장소의 관리 범위가 아닙니다.

- 애플리케이션 소스 코드와 이미지 빌드 Workflow
- EKS, VPC, RDS, SQS, S3, ECR, IAM 등 Terraform 인프라
- 이미지 빌드·태그 갱신 자동화와 GitHub 저장소 설정
- 상세 장애 대응 및 서비스 운영 runbook

## 전체 서비스 및 요청 처리 흐름

```text
사용자
  │
  ▼
ALB Ingress
  ├── /                         ──▶ frontend
  ├── /api/dashboard|scaling|prediction ──▶ predict
  ├── /api/simulator/*          ──▶ simulator
  └── /api/*                    ──▶ call-api
                                      │
                                      ▼
                                     SQS ──▶ worker ──▶ RDS

weather-cron ──▶ S3 기상 데이터 ──▶ predict
predict ──▶ KEDA ScaledObject 최소 replica 기준 patch
SQS 적체 ──▶ KEDA/HPA ──▶ worker Pod 확장
Pending Pod ──▶ Karpenter ──▶ Spot Node 공급
```

Ingress는 하나의 ALB group을 공유합니다. Predict 경로, 일반 API, Frontend catch-all 순으로 평가되도록 group order가 구분되어 있습니다. `weather-cron`과 `worker`는 외부 Ingress를 갖지 않습니다.

CloudFront, DNS, 인증서와 AWS 네트워크는 인프라 범위에서 관리하며, 이 저장소는 Kubernetes의 ALB Ingress 계약만 선언합니다.

## GitOps App-of-Apps 구조

[`argocd/app-of-apps.yaml`](argocd/app-of-apps.yaml)의 `hailcast-root` Application이 [`argocd/applications/`](argocd/applications/) 아래 Child Application 16개를 등록합니다.

```text
hailcast-root
  ├── platform addons
  │   ├── metrics-server
  │   ├── aws-load-balancer-controller
  │   ├── external-secrets
  │   ├── karpenter
  │   ├── keda
  │   ├── kube-prometheus-stack
  │   ├── grafana-dashboards
  │   ├── platform-monitoring
  │   ├── opencost
  │   └── platform-secrets
  └── applications
      ├── call-api
      ├── frontend
      ├── predict
      ├── simulator
      ├── weather-cron
      └── worker
```

Root Application과 모든 Child Application은
이 저장소의 dev 브랜치를 Git source로 사용합니다.

모든 Application은 자동 동기화, prune, self-heal을 사용합니다. Controller가 관리하는 런타임 필드에 대해서만 필요한 범위의 Argo CD diff ignore를 사용합니다.

### Sync Wave

| Wave | 대상 | 목적 |
|---:|---|---|
| `-2` | Metrics Server | 기반 metrics API 선행 배치 |
| `-1` | AWS Load Balancer Controller, External Secrets Operator, Karpenter, KEDA, kube-prometheus-stack | Controller와 CRD 기반 플랫폼 선행 배치 |
| `0` | Grafana Dashboards, PrometheusRule, OpenCost | 관측 리소스와 비용 가시성 배치 |
| `1` | RDS Secret 연동 리소스 | 앱이 참조할 Secret 준비 |
| `2` | Hailcast 애플리케이션 6개 | 플랫폼 이후 애플리케이션 배치 |

Application 내부 리소스 사이에도 필요한 적용 순서를 보장하도록 리소스 수준 wave를 사용합니다.

## 애플리케이션 구성

| 앱 | 실제 리소스 | 역할과 주요 연계 |
|---|---|---|
| `call-api` | Deployment, Service, Ingress, ServiceAccount | 호출 요청을 SQS에 전달하고 S3·RDS를 사용하며, IRSA ServiceAccount로 AWS에 연동합니다. |
| `frontend` | Deployment, Service, Ingress | 정적 Web UI를 제공하며, AWS API를 직접 호출하지 않아 별도 IRSA ServiceAccount를 사용하지 않습니다. |
| `predict` | Deployment, Service, Ingress, ServiceAccount, Role/RoleBinding, ServiceMonitor | 예측·스케일링·대시보드 API와 S3·SQS·RDS 연계를 제공하며, KEDA ScaledObject patch 권한과 Prometheus 수집 구성을 포함합니다. |
| `simulator` | Deployment, Service, ServiceAccount | 시연 트래픽을 생성하며, 자체 Ingress 없이 call-api Ingress의 simulator 경로로 노출됩니다. |
| `weather-cron` | **Deployment**, Service, ServiceAccount | 외부 기상 데이터를 주기적으로 수집하는 상시 Deployment로, Kubernetes CronJob이 아니라 내부 스케줄러를 사용합니다. |
| `worker` | Deployment, ServiceAccount, ScaledObject, TriggerAuthentication | SQS 메시지를 소비해 RDS에 기록하며, Service와 Ingress 없이 KEDA의 확장 대상으로 동작합니다. |

애플리케이션 이미지에는 `latest` 대신 app Git commit을 식별할 수 있는 immutable SHA 형식의 태그를 사용합니다. 서비스마다 마지막으로 변경된 commit이 다를 수 있으므로 모든 Deployment가 같은 태그일 필요는 없습니다.

## 플랫폼·오토스케일링 구성

### AWS Load Balancer Controller

Helm Chart와 [`addons/aws-load-balancer-controller/values.yaml`](addons/aws-load-balancer-controller/values.yaml)로 배포합니다. IRSA ServiceAccount를 사용하며 애플리케이션 Ingress로부터 AWS ALB 리소스를 구성합니다.

### External Secrets Operator

Helm Chart와 [`addons/external-secrets/values.yaml`](addons/external-secrets/values.yaml)로 배포합니다. AWS Secrets Manager와 Parameter Store 접근에는 IRSA를 사용합니다.

이 저장소의 values는 `installCRDs: false`이므로 External Secrets Operator CRD는 Root Application을 등록하기 전에 별도로 준비되어 있어야 합니다.

### KEDA: SQS에서 Worker Pod까지

```text
SQS visible messages
  └── KEDA aws-sqs-queue trigger
        └── KEDA가 관리하는 HPA
              └── hailcast-worker Deployment replicas
```

Worker ScaledObject는 Worker 컨테이너의 SQS 환경변수를 사용하고, 최소·최대 replica와 queue length 기준을 선언합니다. TriggerAuthentication은 AWS pod identity 방식을 사용합니다.

Predict ServiceAccount에는 Worker ScaledObject를 조회·patch하고 Worker Deployment를 조회할 수 있는 namespace 범위 RBAC가 있습니다. 이를 통해 Predict가 예측 결과에 따라 KEDA의 최소 replica 기준을 조정할 수 있습니다. 예측 계산 로직 자체는 애플리케이션 저장소의 책임입니다.

### Karpenter: Worker Pod에서 Node까지

KEDA가 Worker Pod를 늘렸지만 기존 노드에 배치할 자원이 부족하면 스케줄링 수요가 발생합니다. Karpenter는 [`EC2NodeClass`](addons/karpenter/ec2nodeclass.yaml)와 [`NodePool`](addons/karpenter/nodepool.yaml)에 선언된 조건으로 Spot Node를 공급합니다.

NodePool은 아키텍처, 운영체제, 용량 유형, 인스턴스 범위, 전체 CPU 한도와 consolidation 정책을 선언합니다. 실제 VPC discovery tag, node role, interruption queue와 IAM 권한은 선행 인프라가 제공해야 합니다.

### Metrics Server

Helm Chart로 배포하며 Kubernetes resource metrics API를 제공합니다. 이 저장소에서는 ServiceMonitor를 활성화하지 않습니다.

## 모니터링·알림·비용 가시성

### Prometheus와 Grafana

`kube-prometheus-stack` Helm Chart로 Prometheus, Grafana, Alertmanager를 배포합니다.

- Predict의 ServiceMonitor가 `/metrics`를 수집합니다.
- Prometheus는 namespace 제한 없이 ServiceMonitor, PodMonitor, PrometheusRule을 선택합니다.
- Grafana sidecar가 `monitoring` namespace의 dashboard ConfigMap을 자동 탐색합니다.
- [`addons/grafana-dashboards/`](addons/grafana-dashboards/)의 JSON 4개가 Hailcast dashboard ConfigMap으로 생성됩니다.

Dashboard는 Predict 상태, SQS/KEDA, Worker와 Kubernetes Node, 전체 스케일링 흐름을 보여줍니다.

### Alertmanager와 PrometheusRule

[`platform/monitoring/rules/hailcast-alerts.yaml`](platform/monitoring/rules/hailcast-alerts.yaml)은 Hailcast Pod, Deployment, container, Prometheus target, queue backlog, HPA 상태를 감시합니다. Alertmanager는 선택된 Kubernetes 핵심 alert와 Hailcast platform warning/critical alert를 Telegram receiver로 전달합니다.

알림의 세부 threshold와 메시지 템플릿은 매니페스트에서 관리하지만, Telegram 인증 값은 저장소에 기록하지 않습니다.

### OpenCost

OpenCost는 별도 Helm Chart로 배포되며 kube-prometheus-stack의 Prometheus를 데이터 소스로 사용합니다. OpenCost ServiceMonitor를 통해 비용 metric을 수집하고, Grafana 운영 요약 dashboard에서 Hailcast workload와 Node의 비용 가시성을 제공합니다.

## Secret 관리 원칙

이 저장소는 Public 저장소입니다. Secret 실값, token, credential을 Git에 저장하거나 README에 기록하지 않습니다.

### RDS Secret

RDS 연결 정보는 [`platform/external-secrets/`](platform/external-secrets/)에서 관리합니다.

- AWS Secrets Manager의 자격증명은 `DB_USER`, `DB_PASSWORD`로 동기화합니다.
- AWS Parameter Store의 endpoint는 `DB_HOST`로 동기화합니다.
- 두 ExternalSecret은 같은 Kubernetes Secret에 `creationPolicy: Merge`로 값을 병합합니다.
- Merge 대상이 먼저 존재하도록 data가 없는 placeholder Secret을 GitOps로 생성합니다.

애플리케이션 중 call-api, predict, worker가 이 Secret을 참조합니다.

### Alertmanager Telegram Secret

Telegram Alertmanager Secret은 `monitoring` 네임스페이스의 `alertmanager-telegram` Secret(Opaque)에 저장하여 관리합니다.

Telegram Bot Token은 초기 설정 이후 변경 빈도가 낮아 현재는 Kubernetes Secret을 운영자가 수동으로 생성하는 방식을 사용합니다. Secret 실값은 Git 저장소나 프로젝트 문서에 저장하지 않습니다.

Alertmanager가 요구하는 key 이름은 다음과 같습니다.

- `bot-token`
- `chat-id`

`monitoring` 네임스페이스와 `kube-prometheus-stack`이 준비된 뒤 `alertmanager-telegram` Secret을 생성합니다. 이후 Alertmanager가 Secret을 정상적으로 참조하는지 확인합니다.

## 브랜치·배포 계약

현재 이미지 배포와 GitOps 동기화는 다음 흐름을 사용합니다.

```text
app dev
  └── 변경된 서비스 이미지 build
        └── ECR에 immutable SHA 태그 push
              └── manifests dev의 해당 Deployment 이미지 태그 갱신
                    └── Argo CD가 manifests dev 감지
                          └── EKS 배포
```

이미지 태그 자동화는 애플리케이션 저장소 Workflow와 GitHub 저장소 설정에 의존합니다. 이 저장소에는 이미지 태그를 갱신하는 GitHub Actions Workflow가 없습니다.

## 재구축 가이드

### 1. 저장소와 인프라 기준 확인

인프라가 먼저 준비되어 다음 Kubernetes manifest 의존성을 제공해야 합니다.

- 대상 EKS cluster와 올바른 `kubectl` context
- Manifest가 참조하는 IAM Role과 IRSA 신뢰 관계
- S3, SQS, RDS, ECR 및 Parameter Store/Secrets Manager 항목
- Karpenter discovery tag, node role과 interruption queue
- ALB가 사용할 네트워크와 인증서

매니페스트의 AWS 식별자는 재구축에 필요한 참조로만 사용하고, README 등 문서에 옮겨 적지 않습니다.

### 2. 로컬 도구 준비

- `git`
- `make`
- `bash`
- `kubectl`
- `jq`
- `helm` — `make install-argocd` 실행 시 필요
- 대상 EKS 인증에 필요한 AWS CLI 구성

### 3. GitOps 선행 Secret과 CRD 준비

Root Application 등록 전에 다음을 준비합니다.

1. External Secrets Operator CRD가 설치되어 있는지 확인합니다.
2. AWS 원격 Secret/Parameter가 존재하고 ESO IRSA가 읽을 수 있는지 확인합니다.

CRD나 Secret의 실값을 Git에 추가하지 않습니다.

### 4. 정적 검증

```bash
make validate
```

Dashboard JSON, Kustomization 렌더링, shell 구문과 Git whitespace를 검사합니다. 이 명령은 모든 standalone YAML의 Kubernetes schema를 검증하는 명령은 아닙니다.

Argo CD 설치 이후에는 Root Application을 실제 적용하지 않고 사전 검증할 수 있습니다.

```bash
make deploy-dry-run
```

### 5. Argo CD와 Root Application 등록

신규 cluster에 Argo CD가 없으면 다음 명령이 내부 설치 스크립트를 호출해 Helm `upgrade --install` 방식으로 Argo CD 설치 상태를 맞추고 `dev`를 가리키는 Root Application을 등록합니다.

```bash
make install-argocd
```

이후 `make deploy`는 Root Application을 최초 등록하거나 기존 GitOps 상태를 확인하는 데 사용합니다.

```bash
make deploy
```

`monitoring` namespace와 kube-prometheus-stack이 준비되면 승인된 보안 방식으로 `alertmanager-telegram` Secret을 수동 생성합니다.

Secret 생성 후 Alertmanager가 정상 상태로 복구되고
Telegram 알림이 정상적으로 전송되는지 확인합니다.

### 6. 배포 상태 확인

```bash
make status
```

Root와 Child Application 전수의 Synced/Healthy 상태, `hailcast` namespace의 Deployment와 Pod 준비 상태를 확인합니다.

추가로 다음 항목의 준비 상태를 확인합니다.

- ExternalSecret이 RDS Secret key를 동기화했는지
- KEDA ScaledObject가 Ready인지
- Ingress가 ALB Controller에 의해 처리됐는지
- Predict target이 Prometheus에 수집되는지
- Grafana dashboard와 Alertmanager가 준비됐는지
- OpenCost가 Prometheus에 연결됐는지

## 검증·배포·상태 확인

| 명령 | 역할 | 클러스터 변경 |
|---|---|---|
| `make validate` | Dashboard JSON, Kustomization, shell, Git whitespace 정적 검사 | 없음 |
| `make deploy-dry-run` | Root Application server-side dry-run | 없음 |
| `make deploy` | Root가 없을 때 최초 등록 후 GitOps 상태 확인 | 최초 등록 시 있음 |
| `make status` | Application, Deployment, Pod 상태 확인 | 없음 |

Child Application이나 개별 workload manifest를 직접 apply하는 대신 Root Application과 Argo CD 자동 동기화를 공식 배포 경로로 사용합니다.

## teardown

Kubernetes workload와 ALB 연계 리소스를 인프라보다 먼저 정리하려면 다음 명령을 사용합니다.

```bash
CONFIRM=yes make teardown
```

- 기본 삭제 경로는 `ARGOCD_DELETE_PATH=argocd`입니다.
- `CONFIRM=yes`가 없으면 삭제 명령을 실행하지 않고 대상을 확인합니다.
- `make destroy`는 `make teardown`의 호환 alias입니다.
- 스크립트는 Argo CD Application 삭제와 Ingress/LoadBalancer 소거 여부를 확인합니다.
- 이 단계는 Kubernetes workload, Application, Ingress와 LoadBalancer 연계 리소스를 정리하는 단계입니다.
- EKS, VPC, RDS, SQS, S3, ECR, IAM 등 AWS 인프라 전체를 destroy하지 않습니다.

실제 AWS 인프라 destroy는 별도 인프라 절차의 책임입니다. teardown 결과에서 Ingress나 LoadBalancer가 남아 있으면 인프라 삭제로 진행하기 전에 원인을 확인해야 합니다.

## 저장소 구조

```text
.
├── apps/                         # 애플리케이션 6개의 Kubernetes manifest
├── addons/
│   ├── argocd/                   # Argo CD Helm values
│   ├── aws-load-balancer-controller/
│   ├── external-secrets/
│   ├── grafana-dashboards/
│   ├── karpenter/
│   ├── keda/
│   ├── kube-prometheus-stack/
│   ├── metrics-server/
│   └── opencost/
├── platform/
│   ├── external-secrets/         # ClusterSecretStore, ExternalSecret, placeholder
│   └── monitoring/               # PrometheusRule
├── argocd/
│   ├── app-of-apps.yaml          # Root Application
│   └── applications/             # Child Application 16개
├── scripts/
│   ├── deploy.sh
│   ├── install_argocd.sh
│   ├── status.sh
│   ├── teardown_manifest.sh
│   ├── validate.sh
│   ├── keda/                     # KEDA 검증 보조 스크립트
│   └── morning/                  # 야간 절전 후 복원 확인 스크립트
├── Makefile
└── README.md
```

## 알려진 제한 및 개선기간 확인사항

- External Secrets Operator CRD는 Root Application 등록 전에 별도로 준비해야 합니다.
- Telegram Alertmanager Secret은 운영자가 수동으로 생성합니다.
- 일부 Child Application의 cascade finalizer는 개선기간에 보완할 예정입니다.
- 이미지 태그 자동화는 애플리케이션 저장소 Workflow와 GitHub 저장소 설정에 의존합니다.
