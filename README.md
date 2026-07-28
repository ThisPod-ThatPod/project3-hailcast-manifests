# project3-hailcast-manifests
hailcast 배포 정의 (ArgoCD가 감시) · 담당: 그룹 C (조용빈·이지윤)

## 구조
- apps/     : 우리 앱 배포 정의(deployment·service·sa·scaledobject·servicemonitor)
- addons/   : 플랫폼 도구 8종(aws-load-balancer-controller·external-secrets·grafana-dashboards·karpenter·keda·kube-prometheus-stack·metrics-server·opencost)
- argocd/   : app-of-apps
- platform/ : ESO ExternalSecret·SecretStore, PrometheusRule 등 플랫폼 리소스
- scripts/  : teardown·KEDA IRSA 검증 등 운영 스크립트
- docs/     : 운영 절차 문서(Alertmanager 알림 채널, KEDA IRSA 배선 등)
- Makefile  : `make help`로 명령 목록 확인 (validate·deploy-dry-run·deploy·status·teardown)

## 원칙
- 클러스터 안 상태는 전부 여기(Git)에 선언 → ArgoCD가 동기화(selfHeal)
- 이미지 태그는 CI가 갱신, 사람이 직접 건드리지 않음 — 신규 매니페스트는 `<GITHUB_SHA>` placeholder로 둔다
- 진실의 원천은 하나로 — 같은 값을 두 곳에서 따로 관리하는 설계는 피한다
