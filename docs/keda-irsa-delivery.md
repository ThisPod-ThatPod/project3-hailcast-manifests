# KEDA IRSA 운영 정책

## 소유권(Ownership)

KEDA Helm Release의 소유자는 `argocd/applications/keda.yaml` 하나만 사용합니다.

Argo CD는 원격 KEDA Helm Chart와
`addons/keda/values.yaml`을 함께 참조하여 KEDA를 배포합니다.

별도의 Helm 설치나 다른 Workflow에서 KEDA를 배포하거나 업데이트하지 않습니다.

## IAM Role ARN

최종 KEDA IAM Role ARN은 C1이 제공합니다.

ARN의 Source of Truth는
`addons/keda/values.yaml`의
`serviceAccount.operator.annotations.eks.amazonaws.com/role-arn`
값입니다.

해당 Annotation은 Argo CD Desired State의 일부이며, KEDA IRSA는 이 값을 기준으로 관리합니다.

머지 전에는 IAM Role Trust Policy의 Subject가 아래와 정확히 일치하는지 확인합니다.

```
system:serviceaccount:keda:keda-operator
```

## 배포 후 검증

Argo CD Sync 완료 후 아래 스크립트를 실행합니다.

```bash
scripts/keda/verify.sh
```

검증 항목은 다음과 같습니다.

- Argo CD Application 존재 여부
- 별도 Helm Release 중복 배포 여부
- KEDA Operator ServiceAccount Annotation 확인
- KEDA Deployment 상태
- CRD 생성 여부
- Pod 상태
- 최근 AWS 인증(IRSA) 오류 여부