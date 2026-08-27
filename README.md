# Hailcast Kubernetes Manifests

Hailcast는 기상 데이터와 호출 흐름으로 택시 수요를 예측하고, 예측 결과와 실시간 SQS 적체를 함께 사용해 Worker 처리 용량을 조절하는 서비스입니다. 예측에 따른 선제 확장, KEDA의 반응형 Pod 확장, Karpenter의 Spot Node 공급을 하나의 closed loop로 구성합니다.

이 저장소는 Hailcast의 Kubernetes **desired state**를 관리하는 통합 지점입니다. 애플리케이션 배포뿐 아니라 Argo CD GitOps, AWS 연계, Autoscaling, Observability, Alert, FinOps 구성을 함께 선언합니다.

## 3개 저장소와 배포 관계

| 저장소 | 역할 |
|---|---|
| [`project3-hailcast-infra`](https://github.com/ThisPod-ThatPod/project3-hailcast-infra) | Terraform으로 VPC, EKS, RDS, SQS, S3, ECR, IAM/IRSA, CloudFront와 비용 데이터 기반을 제공합니다. |
| [`project3-hailcast-app`](https://github.com/ThisPod-ThatPod/project3-hailcast-app) | Frontend, Backend/AI 소스, Dockerfile과 이미지 빌드 Workflow를 관리합니다. |
| `project3-hailcast-manifests` | ECR 이미지를 EKS에 배포하고 AWS 리소스와 연결하며 GitOps, Scaling, Monitoring, FinOps 상태를 선언합니다. |

```text
app dev 변경
  → GitHub Actions가 변경된 서비스만 build
  → ECR에 immutable SHA tag push
  → manifests dev의 해당 image tag 갱신
  → Argo CD 자동 sync
  → EKS 배포
```

Root와 Child Application은 모두 manifests의 dev 브랜치를 감시합니다. hailcast-dev-*의 dev는 AWS 환경 이름이며 Git 브랜치명과는 별개의 값입니다.

## 서비스 아키텍처

```text
사용자
  │
  ▼
CloudFront → ALB Ingress
  ├── /                              → frontend
  ├── /api/dashboard|scaling|prediction → predict
  ├── /api/simulator/*               → simulator
  └── /api/*                         → call-api
                                           │
                                           ▼
                                          SQS → worker → RDS

weather-cron → S3 기상 데이터 → predict
predict → KEDA ScaledObject의 최소 replica 조정
SQS 적체 → KEDA가 생성한 HPA → worker Pod 확장
Pending Pod → Karpenter → Spot Node 공급
```

세 Ingress는 하나의 ALB group을 공유하며 Predict, 일반 API, Frontend catch-all 순으로 평가됩니다. ALB는 infra가 제공한 전용 Security Group을 사용해 CloudFront prefix list에서 들어오는 HTTPS만 허용합니다. `weather-cron`과 `worker`는 외부 Ingress를 갖지 않습니다.

## GitOps App-of-Apps

[`argocd/app-of-apps.yaml`](argocd/app-of-apps.yaml)의 `hailcast-root`가 [`argocd/applications/`](argocd/applications/) 아래 Child Application 16개를 등록합니다.

```text
hailcast-root
  ├── platform
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
  └── workloads
      ├── call-api
      ├── frontend
      ├── predict (재학습 CronJob 포함)
      ├── simulator
      ├── weather-cron
      └── worker
```

모든 Application은 자동 sync, prune, self-heal을 사용합니다. Controller가 소유하는 Worker replica, KEDA 최소 replica, Secret data 등은 필요한 필드만 diff에서 제외해 GitOps와 런타임 제어가 충돌하지 않도록 합니다.

| Sync Wave | 대상 | 목적 |
|---:|---|---|
| `-2` | Metrics Server | resource metrics API 준비 |
| `-1` | ALB Controller, External Secrets, Karpenter, KEDA, kube-prometheus-stack | Controller와 CRD 기반 플랫폼 준비 |
| `0` | Grafana Dashboards, PrometheusRule, OpenCost | 관측·알림·비용 구성 배치 |
| `1` | RDS Secret 연동 | 애플리케이션이 참조할 Secret 준비 |
| `2` | Hailcast workload | 플랫폼 의존성 이후 애플리케이션 배치 |

## 애플리케이션과 MLOps

| 구성 | 역할과 주요 연계 |
|---|---|
| `call-api` | 호출 요청을 SQS에 발행하고 RDS에 요청 상태를 기록합니다. 호출·SQS publish metric을 `/metrics`로 제공합니다. |
| `frontend` | nginx 기반 Web UI를 제공하며 same-origin `/api` 경로로 Backend를 호출합니다. |
| `predict` | 기상·호출 데이터를 사용한 예측, 스케일링 판단, 운영 상태와 대시보드 API를 제공합니다. RBAC으로 Worker ScaledObject의 최소 replica를 조정합니다. |
| `simulator` | 시연 트래픽을 만들고 상태를 S3에 기록합니다. 자체 Ingress 대신 공용 ALB의 simulator 경로를 사용합니다. |
| `weather-cron` | Open-Meteo 예보를 주기적으로 수집해 S3에 저장하는 상시 Deployment입니다. Kubernetes CronJob이 아니라 내부 스케줄러를 사용합니다. |
| `worker` | SQS 메시지를 소비해 RDS에 기록합니다. heartbeat 파일의 최신성으로 실제 polling 동작을 liveness probe에서 확인합니다. |

### Prediction 재학습 흐름

Predict는 예측과 실제 수요의 오차가 기준을 넘으면 DynamoDB 오답노트에 재학습용 데이터를 기록합니다. `predict-retraining` CronJob은 매일 실행되어 아직 학습하지 않은 데이터가 충분할 때 S3의 기존 모델을 불러와 이어 학습하고, 갱신된 모델과 metadata를 다시 S3에 저장합니다.

재학습은 일반 Predict Pod와 분리된 `retraining-sa`를 사용합니다. infra의 전용 IRSA가 DynamoDB 읽기·갱신과 S3 모델 읽기·쓰기에 필요한 권한만 제공합니다. CronJob 실패는 Prometheus 기본 Job alert와 Alertmanager 경로로 전달됩니다.

## Autoscaling

### Prediction + KEDA + HPA

```text
예측 수요 ──→ predict ──patch──→ ScaledObject minReplicaCount
SQS 적체 ──→ KEDA aws-sqs-queue trigger ──→ KEDA 관리 HPA
                                         └──→ hailcast-worker
```

- Predict는 예측 수요를 Worker 수로 환산해 선제 확장을 위한 최소 replica 기준을 조정합니다.
- KEDA ScaledObject는 SQS visible message에 반응해 1~20 replica 범위에서 Worker를 확장합니다.
- 별도 HPA manifest는 없습니다. KEDA가 `keda-hpa-hailcast-worker-scaler`를 생성·관리합니다.
- Argo CD는 Worker Deployment의 `spec.replicas`와 ScaledObject의 `minReplicaCount`를 self-heal 대상으로 삼지 않아 Predict와 KEDA의 변경을 보존합니다.

### Karpenter

기존 노드에 Worker Pod를 배치할 수 없으면 Karpenter가 [`EC2NodeClass`](addons/karpenter/ec2nodeclass.yaml)와 [`NodePool`](addons/karpenter/nodepool.yaml)의 조건에 맞는 Spot Node를 공급합니다. NodePool은 Spot Node의 프로비저닝 조건과 리소스 한도, consolidation 정책을 선언하며, 필요한 AWS 인프라와 IAM 구성은 infra와 연계됩니다.

## Observability와 Alert

`kube-prometheus-stack`으로 Prometheus, Grafana, Alertmanager를 배포합니다. Prometheus는 namespace 제한 없이 ServiceMonitor, PodMonitor, PrometheusRule을 선택하고, Call API와 Predict의 `/metrics`를 각각 30초 간격으로 수집합니다. Metrics Server는 Kubernetes resource metrics API를 제공합니다.

Grafana sidecar는 [`addons/grafana-dashboards/`](addons/grafana-dashboards/)에서 생성한 dashboard ConfigMap을 읽습니다. 현재 대시보드는 운영 흐름과 영역별 상세 화면을 함께 제공합니다.

| Dashboard | 관측 범위 |
|---|---|
| `01 예측 기반 스케일링` | 예측 수요, Predict 상태, 예측 replica와 실제 Worker |
| `02 처리 대기열 및 KEDA` | Call/SQS publish 처리량, Queue, KEDA/HPA 반응 |
| `03 Worker 및 Kubernetes` | Worker 공급·가용성·리소스와 Node 상태 |
| `04 Hailcast 비용 / FinOps` | Kubernetes 모델 비용과 AWS 실제 비용 |
| `99 Hailcast 운영 요약` | Prediction → Queue/HPA → Worker로 이어지는 closed loop 핵심 상태 |

이상 탐지와 전달은 다음 두 경로를 하나의 Alertmanager로 모읍니다.

- [`PrometheusRule`](platform/monitoring/rules/hailcast-alerts.yaml): Pod/Deployment 불일치, CrashLoop, 메모리, Node pressure, Prometheus target, Queue backlog, HPA 상태를 감시합니다.
- **Grafana managed Alert**: Infinity datasource로 Predict의 prediction scheduler와 weather 상태를 직접 확인합니다.

선택한 Kubernetes 기본 alert와 Hailcast warning/critical alert는 Alertmanager에서 공통 grouping·inhibition·메시지 템플릿을 적용한 뒤 Telegram으로 전달됩니다. Telegram 인증 정보는 별도 Kubernetes Secret으로 관리하며 Git에는 저장하지 않습니다.

## FinOps

OpenCost는 kube-prometheus-stack의 Prometheus와 연결되며, 비용 대시보드는 서로 성격이 다른 두 비용을 구분해 보여줍니다.

- **Kubernetes 모델 비용**: CPU·Memory allocation metric으로 Node, namespace, Hailcast 전체와 Worker의 비용 발생 위치·추세를 추정합니다.
- **AWS 실제 비용**: CUR 저장 버킷, Glue Data Catalog, Athena workgroup을 OpenCost Cloud Cost가 IRSA로 조회하고 Grafana가 `/cloudCost`의 CUR 기반 Net Cost를 일별·AWS service별·category별로 표시합니다.

이를 통해 Worker replica와 운영 부하의 변화뿐 아니라 비용이 어느 계층에서 발생하는지 같은 화면에서 확인할 수 있습니다. Kubernetes allocation 값은 모델 기반 추정치이고 CUR 값은 지연 반영되는 AWS 비용 데이터이므로 같은 수치로 해석하지 않습니다. AWS 실제 비용 조회를 위해 CUR report definition과 관련 비용 데이터 구성이 사전에 준비되어야 합니다.

## AWS 권한과 Secret 연결

애플리케이션과 Controller는 Kubernetes ServiceAccount에 연결된 IRSA로 AWS 권한을 얻습니다.

| 대상 | AWS 연계 |
|---|---|
| call-api / worker | SQS 발행 또는 소비, RDS 연결 |
| predict / retraining | S3 모델·상태, SQS 조회, DynamoDB 오답노트 |
| weather-cron / simulator | S3 기상·시뮬레이터 상태 |
| ALB Controller / KEDA / Karpenter | ALB, SQS metric, EC2 Node lifecycle |
| External Secrets / OpenCost | Secrets Manager·Parameter Store, CUR·Glue·Athena |

RDS 접속 정보는 [`platform/external-secrets/`](platform/external-secrets/)에서 동기화합니다. Secrets Manager의 자격증명은 `DB_USER`, `DB_PASSWORD`, Parameter Store의 endpoint는 `DB_HOST`가 되어 하나의 `hailcast-rds-secret`에 병합됩니다. call-api, predict, worker는 External Secrets Operator를 통해 동기화된 hailcast-rds-secret을 참조하며, Secret 실값은 Git 저장소에 기록하지 않습니다.

## 운영과 재구축

### 준비 사항

- 대상 EKS cluster와 올바른 `kubectl` context
- `git`, `make`, `bash`, `kubectl`, `jq`, `helm`, Python 3/PyYAML, AWS CLI
- infra에서 제공하는 AWS 리소스와 IAM/IRSA 등 Kubernetes 연계 구성
- External Secrets, Karpenter, ALB 등 플랫폼 구성에 필요한 선행 인프라
- CUR report definition과 Telegram Secret 등 별도 운영 설정

destroy 후 재구축에서는 변경된 AWS 리소스 식별자를 scripts/replace_rebuild_values.sh로 검증·치환할 수 있습니다.

### 기본 진입점

| 명령 | 역할 |
|---|---|
| `make validate` | Dashboard JSON, Kustomization, shell 구문, Git whitespace 정적 검사 |
| `make install-argocd` | Helm으로 Argo CD 설치·갱신 후 Root Application 등록 |
| `make bootstrap-all` | Argo CD, External Secrets CRD, RDS Secret 동기화를 멱등하게 부트스트랩 |
| `make deploy-dry-run` | Root Application server-side dry-run |
| `make deploy` | Root 최초 등록 또는 기존 GitOps 상태 확인 |
| `make status` | Root/Child Application과 Hailcast Deployment/Pod 상태 확인 |

배포는 Root Application과 Argo CD 자동 sync를 기준으로 합니다.

```bash
# GitOps와 workload
kubectl -n argocd get applications
kubectl -n hailcast get deployment,pod,service,ingress
kubectl -n hailcast get cronjob,scaledobject,triggerauthentication,hpa

# Observability와 FinOps
kubectl -n monitoring get pod,servicemonitor,prometheusrule
kubectl -n opencost get pod,servicemonitor
```

관리 UI는 필요할 때 로컬로 전달합니다.

```bash
kubectl -n monitoring port-forward service/kube-prometheus-stack-grafana 3000:80
kubectl -n monitoring port-forward service/kube-prometheus-stack-prometheus 9090:9090
kubectl -n monitoring port-forward service/kube-prometheus-stack-alertmanager 9093:9093
kubectl -n opencost port-forward service/opencost 9003:9003
```

### Teardown

AWS 인프라보다 먼저 Kubernetes workload와 ALB 연계 리소스를 정리합니다.

```bash
CONFIRM=yes make teardown
```

CONFIRM=yes가 없으면 삭제 대상을 확인만 합니다. 스크립트는 Argo CD Application을 삭제한 뒤 Ingress/LoadBalancer 소거 여부를 확인합니다. 인프라 삭제 전에는 Kubernetes 잔존 리소스가 없는지 확인해야 합니다.

## 저장소 구조

```text
.
├── apps/                         # 서비스 6개와 Predict 재학습 Kubernetes 리소스
├── addons/
│   ├── argocd/                   # Argo CD Helm values
│   ├── aws-load-balancer-controller/
│   ├── external-secrets/
│   ├── grafana-dashboards/       # 운영·Scaling·FinOps dashboard 5개
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
├── scripts/                      # 검증, 배포, 부트스트랩, 재구축, teardown
├── Makefile
└── README.md
```
