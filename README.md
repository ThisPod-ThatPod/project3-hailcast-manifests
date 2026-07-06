# project3-hailcast-manifests
hailcast 배포 정의 (ArgoCD가 감시) · 담당: 그룹 C (조용빈·이지윤)

## 구조
- apps/   : 우리 앱 배포 정의(deployment·service·sa·scaledobject·servicemonitor)
- addons/ : 플랫폼(keda·karpenter·prometheus·opencost·alb-controller)
- argocd/ : app-of-apps
## 원칙
클러스터 안 상태는 전부 여기(Git)에 선언 → ArgoCD가 동기화(selfHeal)
