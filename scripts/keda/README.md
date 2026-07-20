# KEDA verification

KEDA 2.20.1의 Argo CD 관리 상태, Operator, CRD와 AWS 인증 오류를 검증한다.
KEDA chart와 리소스의 유일한 배포 주체는 `argocd/applications/keda.yaml`이다.
별도의 Helm release가 발견되면 소유권 충돌로 실패한다.

KEDA IRSA Role ARN은 C1이 확정한 값을 `addons/keda/values.yaml`의
ServiceAccount annotation에 직접 반영하며, 이 디렉터리는 ARN 전달을 자동화하지 않는다.

## Commands

```bash
scripts/keda/verify.sh
```

상세 계약은 `docs/keda-irsa-delivery.md`를 따른다.
