# project3-hailcast-manifests
hailcast 배포 정의 (ArgoCD가 감시) · 담당: 그룹 C (조용빈·이지윤)

## 구조
- apps/     : 우리 앱 배포 정의(deployment·service·sa·scaledobject·servicemonitor)
- addons/   : 플랫폼(keda·karpenter·prometheus·opencost·alb-controller·external-secrets)
- argocd/   : app-of-apps
- platform/ : ESO ExternalSecret·SecretStore, PrometheusRule 등 플랫폼 리소스
- scripts/  : teardown·KEDA IRSA 검증 등 운영 스크립트
- docs/     : 운영 절차 문서(Alertmanager 알림 채널, KEDA IRSA 배선 등)
## 원칙
클러스터 안 상태는 전부 여기(Git)에 선언 → ArgoCD가 동기화(selfHeal)
