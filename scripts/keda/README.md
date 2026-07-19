# KEDA delivery scripts

KEDA 2.20.1의 IRSA 값 전달과 배포 검증을 담당한다. 실제 IAM Role ARN은
저장소 파일에 기록하지 않는다.

공식 입력 계약은 `KEDA_ROLE_ARN` 환경변수다. GitHub Secret도 workflow에서 같은
환경변수로 주입한다. Terraform output 조회는 로컬 개발 편의를 위한 선택적
fallback이며 C2 배포의 필수 계약이 아니다.

## Modes

- `workflow`: 임시 private values를 생성하고 Helm이 KEDA release를 단독 관리한다.
- `gitops`: private values repository 정보로 ArgoCD Application 패치를 렌더링한다.
  실제 배포는 검토·커밋 후 ArgoCD가 수행한다.

두 모드는 같은 KEDA release를 동시에 관리할 수 없다. 스크립트는 ArgoCD
Application, Helm release, 리소스 tracking annotation을 검사하고 충돌 시 중단한다.

## Commands

```bash
# 실제 ARN은 환경변수 또는 Terraform output에서 읽는다.
KEDA_ROLE_ARN=... scripts/keda/deploy.sh --mode workflow --dry-run --yes

# Terraform output fallback
scripts/keda/deploy.sh \
  --mode workflow \
  --dry-run \
  --infra-env-dir ../project3-hailcast-infra/envs/dev \
  --terraform-output-name eks_irsa_role_arns \
  --terraform-output-key keda

# 비대화형 실제 배포는 기대 context를 반드시 지정한다.
KEDA_ROLE_ARN=... scripts/keda/deploy.sh \
  --mode workflow \
  --expected-context <approved-context> \
  --yes

# 배포 상태 검증
scripts/keda/deploy.sh --mode workflow --verify-only
scripts/keda/verify.sh --mode gitops

# private values 생성
KEDA_ROLE_ARN=... scripts/keda/render-private-values.sh \
  --output /secure/path/keda-irsa-values.yaml

# private source가 연결된 Application을 별도 파일로 생성
scripts/keda/configure-gitops-source.sh \
  --repo-url <approved-private-repository> \
  --revision <approved-revision> \
  --values-path <approved-values-path> \
  --output /tmp/keda.yaml
```

`render-private-values.sh`의 `--output`은 필수이며, stdout과 public repository
내부 경로는 허용하지 않는다.

`--force-ownership-risk`는 이중 관리 위험을 이해하고 복구 계획이 있을 때만 사용한다.
`--in-place` GitOps 구성을 사용하면 YAML formatting/comments가 바뀔 수 있으므로
반드시 Application diff를 검토한다.
상세 운영 절차는 `docs/keda-irsa-delivery.md`를 따른다.
