# KEDA IRSA delivery

## 1. 목적

Terraform이 생성한 KEDA IAM Role ARN을 public Git에 노출하지 않고 KEDA
Operator ServiceAccount에 전달한다. KEDA는 ArgoCD 또는 Helm 중 하나만 관리한다.

## 2. 현재 계약

| 항목 | 값 |
|---|---|
| Helm repository | `https://kedacore.github.io/charts` |
| chart/version | `keda` / `2.20.1` |
| release/namespace | `keda` / `keda` |
| ServiceAccount | `keda-operator` |
| annotation | `eks.amazonaws.com/role-arn` |
| Terraform environment | `project3-hailcast-infra/envs/dev` |
| Terraform output | `eks_irsa_role_arns["keda"]` |
| IAM trust subject | `system:serviceaccount:keda:keda-operator` |

실제 AWS Account ID와 IAM Role ARN은 이 저장소에 기록하지 않는다.

## 3. 지원 아키텍처

```text
Terraform output
  → 환경별 private values repository
  → ArgoCD multi-source
  → KEDA Helm rendering
  → EKS
  → scripts/keda/verify.sh
```

Private repository가 준비되기 전에는 workflow 모드로 같은 값을 임시 0600
values에 렌더링하고 Helm으로 배포할 수 있다.

## 4. Mode A: gitops

GitOps 모드는 private values repository와 ArgoCD 접근 계약이 확정된 이후 사용할
운영 경로다.

1. public `addons/keda/values.yaml`을 기본값으로 유지한다.
2. private repository에는 IRSA override만 둔다.
3. ArgoCD `valueFiles`는 public values, private values 순으로 적용한다.
4. Git에 반영된 KEDA Application을 ArgoCD가 단독 관리한다.

Private override 형식:

```yaml
serviceAccount:
  operator:
    annotations:
      eks.amazonaws.com/role-arn: <terraform-output-value>
```

연결 정보가 확정되면 다음 명령으로 검토용 결과를 생성한다.

```bash
scripts/keda/configure-gitops-source.sh \
  --repo-url "$PRIVATE_VALUES_REPO" \
  --revision "$PRIVATE_VALUES_REVISION" \
  --values-path "$PRIVATE_VALUES_PATH" \
  --output /tmp/keda.yaml
```

검토 후에만 `--in-place`로 public Application을 수정한다. 스크립트는 빈 값,
placeholder, `example.com`, `CHANGEME`, `TODO`를 거부한다. `--in-place`는
`yaml.safe_dump()` 특성상 파일 전체 formatting을 바꾸고 comments를 제거할 수
있으므로 실행 후 반드시 `git diff -- argocd/applications/keda.yaml`을 검토한다.
기본 동작은 stdout 또는 별도 출력 파일 생성이다.

## 5. Mode B: workflow

Workflow 모드는 private repository와 ArgoCD 연결 계약이 준비되기 전 사용할 수 있는
임시 자동화 경로다. Helm이 KEDA를 단독 관리하며 실제 ARN은 임시 values에만 존재한다.

값 우선순위:

1. `KEDA_ROLE_ARN` 환경변수
   - 로컬의 `export KEDA_ROLE_ARN=...`
   - GitHub Actions Secret을 동일한 환경변수로 주입
2. 선택적 로컬 Terraform output fallback

로컬 dry-run:

```bash
KEDA_ROLE_ARN=... scripts/keda/deploy.sh \
  --mode workflow \
  --dry-run \
  --yes
```

실제 배포:

```bash
KEDA_ROLE_ARN=... scripts/keda/deploy.sh \
  --mode workflow \
  --yes
```

스크립트는 `mktemp -d`, mode `0600`, `trap` 정리를 사용하고 Helm에는 실제 ARN이
포함된 `--set` 인자를 전달하지 않는다.

## 6. 값의 출처와 우선순위

공식 입력 계약은 `KEDA_ROLE_ARN` 환경변수 하나다. C1이 계약된 값을 제공하면 C2
배포 도구가 이를 소비하며, C2는 C1의 Terraform resource, module, state 구현 상세를
알 필요가 없다.

로컬에서는 환경변수가 없을 때만 선택적 Terraform fallback을 사용할 수 있다.
`INFRA_ENV_DIR`, `KEDA_ROLE_ARN_OUTPUT_NAME`, `KEDA_ROLE_ARN_OUTPUT_KEY` 환경변수나
동일 목적의 CLI 옵션으로 조회 위치와 output 구조를 바꿀 수 있다. 기본값은 현재 dev
환경을 위한 편의값이며 필수 배포 계약이 아니다. GitHub Actions는 Terraform state를
읽지 않고 `KEDA_ROLE_ARN` Secret만 사용한다.

ARN은 빈 값, `null`, IAM Role ARN 형식, role 이름의 `keda` 포함 여부를 검증한다.

AWS ARN은 자격증명은 아니지만 프로젝트 규약에 따라 Account ID가 들어간 식별자를
public 코드와 공개 로그에 기록하지 않는다.

## 7. ArgoCD/Helm 소유권 전환

### Workflow → GitOps

1. private values repository와 ArgoCD credential을 준비한다.
2. private source가 연결된 KEDA Application을 검토·커밋한다.
3. 기존 Helm release와 리소스의 보존/재생성 계획을 정한다.
4. 유지보수 창에서 Helm release 소유권을 정리한다.
5. KEDA Application을 sync한다.
6. `verify.sh --mode gitops`를 실행한다.

Helm uninstall은 KEDA와 CRD 삭제 영향을 검토하기 전에는 실행하지 않는다. CRD
삭제 시 ScaledObject 등 custom resource가 영향을 받을 수 있다.

### GitOps → Workflow

1. KEDA Application의 automated sync를 중지한다.
2. Application과 resource finalizer 동작을 확인한다.
3. ArgoCD tracking을 제거하거나 Application 관리 범위에서 KEDA를 제외한다.
4. 리소스 충돌이 없는 상태에서 workflow 배포를 실행한다.

두 관리자가 동시에 활성화된 상태는 정상 상태가 아니다.

## 8. Private values repository 연결

ArgoCD에는 private Git repository를 읽을 credential이 필요하다. repository URL,
revision, values path가 확정되기 전에는 public KEDA Application에 비활성 가짜 source를
추가하지 않는다.

권장 파일은 환경별로 분리한다.

```text
environments/dev/keda-irsa-values.yaml
```

Repository credential은 ArgoCD의 승인된 credential 관리 방식으로 등록하며 이
저장소에 토큰, SSH private key, 비밀번호를 저장하지 않는다.

## 9. GitHub Secret

Workflow 환경 `dev`에 다음 Secret이 필요하다.

```text
KEDA_ROLE_ARN
```

현재 GitHub Actions가 EKS에 접속하는 역할과 kubeconfig 계약은 없다. 따라서
`.github/workflows/deploy-keda.yaml`은 dry-run만 실행 가능하며 실제 배포와
verify-only 요청은 명시적으로 실패한다. 계약이 확정될 때까지 가짜 Secret 이름이나
과도한 `id-token: write` 권한을 추가하지 않는다. 배포·검증 단계는 조건부로 정의되어
있지만, 승인된 EKS 인증 단계를 추가하고 앞단의 안전 차단을 제거하기 전에는 도달하지
않는다. 실제 CI 배포를 활성화할 때는 승인된 kubeconfig와 함께
`KEDA_EXPECTED_CONTEXT`도 주입해야 한다.

## 10. 실행 방법

옵션:

```text
--mode workflow|gitops
--yes
--dry-run
--verify-only
--force-ownership-risk
--infra-env-dir <path>
--terraform-output-name <name>
--terraform-output-key <key>
--expected-context <name>
```

기본 모드는 `workflow`다. dry-run은 Kubernetes API에 연결할 수 없어도 정적
렌더링을 계속한다. 실제 배포는 Kubernetes API 접근이 불가능하면 중단한다.
대화형 실행은 현재 context를 확인 문구에 포함하고, `--yes` 실제 배포는
`KEDA_EXPECTED_CONTEXT` 또는 `--expected-context`가 반드시 필요하다.

## 11. 검증

```bash
scripts/keda/verify.sh --mode workflow
scripts/keda/verify.sh --mode gitops
```

검증 항목:

- 선택한 배포 관리자의 상태
- namespace와 ServiceAccount
- 마스킹된 IRSA annotation 형식
- Operator Deployment의 ServiceAccount
- 주요 Deployment Available
- KEDA Pod Ready
- KEDA CRD Established
- TriggerAuthentication API
- Operator 로그의 AWS 인증 오류
- Worker ScaledObject 상태

FAIL이 하나라도 있으면 non-zero로 종료한다.
Operator 로그는 기본적으로 최근 10분만 검사하며 `KEDA_VERIFY_LOG_SINCE`로 범위를
조정할 수 있다.

## 12. 롤백

- Workflow 배포 실패: `--atomic`이 Helm release를 이전 상태로 되돌린다.
- GitOps 실패: private values 변경을 revert하고 ArgoCD에서 이전 Git revision을 sync한다.
- 소유권 전환 실패: 두 관리자를 동시에 재시도하지 말고 원래 관리자만 복구한다.
- CRD는 custom resource 보존 여부를 확인하기 전 수동 삭제하지 않는다.

## 13. 보안 주의사항

- 실제 ARN을 `echo`, artifact, public values, PR 본문에 출력하지 않는다.
- 임시 values는 mode `0600`으로 만들고 종료 시 삭제한다.
- GitHub Actions에서는 `::add-mask::`를 ARN 출력보다 먼저 등록한다.
- workflow artifact에 렌더링 결과나 임시 values를 업로드하지 않는다.
- `--role-arn` 옵션보다 환경변수 전달을 우선한다.
- `--force-ownership-risk`는 복구 계획이 있을 때만 사용한다.

## 14. 미확정 팀 결정

- Private values repository URL, branch, path
- ArgoCD private repository credential 등록 방식과 담당자
- GitHub Actions의 EKS 접근 역할 및 kubeconfig 생성 방식
- 실제 CI 배포에서 사용할 `KEDA_EXPECTED_CONTEXT`
- Workflow → GitOps 전환 시 기존 Helm release 보존 절차
- GitOps Application의 실제 sync를 수행할 승인 절차

## 15. Karpenter 확장

향후 동일한 구조를 다음 값에 적용할 수 있다.

- Karpenter controller role ARN
- node IAM role name
- interruption queue name
- cluster name과 endpoint

`_lib.sh`의 명령 검사, ARN 마스킹, kubectl 연결 및 소유권 탐지 패턴은 재사용할 수
있다. KEDA chart 이름과 리소스명은 일반화하지 않고 Karpenter 전용 스크립트에서
별도로 정의한다.

역할 경계는 동일하게 유지한다. C1은 AWS/EKS/IAM 기반 값을 제공하고, C2는 제공된
값을 환경변수 또는 명시적 입력으로 소비해 Helm/ArgoCD 설치와 Kubernetes 운영
검증을 담당한다.
