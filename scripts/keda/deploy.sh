#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/keda/_lib.sh
source "$SCRIPT_DIR/_lib.sh"

MODE="workflow"
ASSUME_YES="false"
DRY_RUN="false"
VERIFY_ONLY="false"
FORCE_OWNERSHIP_RISK="false"
INFRA_ENV_DIR="${INFRA_ENV_DIR:-$KEDA_REPO_ROOT/../project3-hailcast-infra/envs/dev}"
KEDA_ROLE_ARN_OUTPUT_NAME="${KEDA_ROLE_ARN_OUTPUT_NAME:-eks_irsa_role_arns}"
KEDA_ROLE_ARN_OUTPUT_KEY="${KEDA_ROLE_ARN_OUTPUT_KEY-keda}"
KEDA_EXPECTED_CONTEXT="${KEDA_EXPECTED_CONTEXT:-}"

usage() {
  cat <<'EOF'
Usage: deploy.sh [options]

Options:
  --mode workflow|gitops
  --yes
  --dry-run
  --verify-only
  --force-ownership-risk
  --infra-env-dir <path>
  --terraform-output-name <name>
  --terraform-output-key <key>
  --expected-context <name>
  -h, --help
EOF
}

while (($#)); do
  case "$1" in
    --mode)
      [[ $# -ge 2 ]] || keda_die "--mode 값이 필요합니다."
      MODE="$2"
      shift 2
      ;;
    --yes)
      ASSUME_YES="true"
      shift
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --verify-only)
      VERIFY_ONLY="true"
      shift
      ;;
    --force-ownership-risk)
      FORCE_OWNERSHIP_RISK="true"
      shift
      ;;
    --infra-env-dir)
      [[ $# -ge 2 ]] || keda_die "--infra-env-dir 값이 필요합니다."
      INFRA_ENV_DIR="$2"
      shift 2
      ;;
    --terraform-output-name)
      [[ $# -ge 2 ]] || keda_die "--terraform-output-name 값이 필요합니다."
      KEDA_ROLE_ARN_OUTPUT_NAME="$2"
      shift 2
      ;;
    --terraform-output-key)
      [[ $# -ge 2 ]] || keda_die "--terraform-output-key 값이 필요합니다."
      KEDA_ROLE_ARN_OUTPUT_KEY="$2"
      shift 2
      ;;
    --expected-context)
      [[ $# -ge 2 ]] || keda_die "--expected-context 값이 필요합니다."
      KEDA_EXPECTED_CONTEXT="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      keda_die "알 수 없는 옵션: $1"
      ;;
  esac
done

[[ "$MODE" == "workflow" || "$MODE" == "gitops" ]] ||
  keda_die "--mode는 workflow 또는 gitops여야 합니다."
[[ "$DRY_RUN" != "true" || "$VERIFY_ONLY" != "true" ]] ||
  keda_die "--dry-run과 --verify-only는 함께 사용할 수 없습니다."

keda_require_command helm
keda_require_command kubectl
keda_require_command jq

keda_info "mode=$MODE, dry-run=$DRY_RUN, verify-only=$VERIFY_ONLY"
keda_info "kubectl context: $(keda_current_context)"

if [[ "$VERIFY_ONLY" == "true" ]]; then
  exec "$SCRIPT_DIR/verify.sh" --mode "$MODE"
fi

keda_check_ownership "$MODE" "$FORCE_OWNERSHIP_RISK" "$DRY_RUN"

TEMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "$MODE" == "gitops" ]]; then
  : "${PRIVATE_VALUES_REPO:?PRIVATE_VALUES_REPO가 필요합니다.}"
  : "${PRIVATE_VALUES_REVISION:?PRIVATE_VALUES_REVISION이 필요합니다.}"
  : "${PRIVATE_VALUES_PATH:?PRIVATE_VALUES_PATH가 필요합니다.}"

  PATCHED_APPLICATION="$TEMP_DIR/keda.yaml"
  "$SCRIPT_DIR/configure-gitops-source.sh" \
    --repo-url "$PRIVATE_VALUES_REPO" \
    --revision "$PRIVATE_VALUES_REVISION" \
    --values-path "$PRIVATE_VALUES_PATH" \
    --output "$PATCHED_APPLICATION"

  keda_info "GitOps Application 패치 렌더링과 검증을 완료했습니다."
  if [[ "$DRY_RUN" == "true" ]]; then
    keda_info "dry-run 완료: 저장소 파일과 클러스터를 변경하지 않았습니다."
    exit 0
  fi

  keda_die "gitops 모드는 Git commit과 ArgoCD sync가 배포 주체입니다. configure-gitops-source.sh --in-place 실행 후 검토·커밋하십시오."
fi

ROLE_ARN="${KEDA_ROLE_ARN:-}"
if [[ -z "$ROLE_ARN" ]]; then
  keda_require_command terraform
  [[ -d "$INFRA_ENV_DIR" ]] ||
    keda_die "KEDA_ROLE_ARN이 없고 Terraform fallback 디렉터리도 찾을 수 없습니다: $INFRA_ENV_DIR"
  [[ -n "$KEDA_ROLE_ARN_OUTPUT_NAME" ]] ||
    keda_die "Terraform fallback output 이름이 비어 있습니다."
  keda_info "KEDA_ROLE_ARN이 없어 선택적 Terraform output fallback을 사용합니다."
  if ! terraform_output="$(
    terraform -chdir="$INFRA_ENV_DIR" output -json "$KEDA_ROLE_ARN_OUTPUT_NAME" 2>/dev/null
  )"; then
    keda_die "KEDA_ROLE_ARN이 없고 Terraform output fallback 조회에도 실패했습니다. KEDA_ROLE_ARN을 주입하거나 fallback 설정을 확인하십시오."
  fi
  if [[ -n "$KEDA_ROLE_ARN_OUTPUT_KEY" ]]; then
    ROLE_ARN="$(
      jq -r --arg key "$KEDA_ROLE_ARN_OUTPUT_KEY" \
        'if type == "object" then .[$key] // empty else empty end' \
        <<<"$terraform_output"
    )"
  else
    ROLE_ARN="$(jq -r 'if type == "string" then . else empty end' <<<"$terraform_output")"
  fi
fi

keda_valid_role_arn "$ROLE_ARN" ||
  keda_die "KEDA_ROLE_ARN이 비어 있거나 null이거나 형식이 잘못되었거나 role 이름에 keda가 없습니다."
keda_info "KEDA Role ARN 검증 완료: $(keda_mask_role_arn "$ROLE_ARN")"

PRIVATE_VALUES="$TEMP_DIR/keda-irsa-values.yaml"
KEDA_ROLE_ARN="$ROLE_ARN" "$SCRIPT_DIR/render-private-values.sh" \
  --output "$PRIVATE_VALUES"
[[ "$(stat -c '%a' "$PRIVATE_VALUES")" == "600" ]] ||
  keda_die "임시 private values 권한이 0600이 아닙니다."

keda_ensure_chart_repo

if [[ "$DRY_RUN" == "true" ]]; then
  keda_require_command python3
  python3 -c 'import yaml' >/dev/null 2>&1 ||
    keda_die "dry-run 렌더링 검증에는 Python PyYAML 모듈이 필요합니다."
  RENDERED="$TEMP_DIR/keda-rendered.yaml"
  helm template "$KEDA_RELEASE" "$KEDA_CHART_REF" \
    --version "$KEDA_CHART_VERSION" \
    --namespace "$KEDA_NAMESPACE" \
    --include-crds \
    -f "$KEDA_BASE_VALUES" \
    -f "$PRIVATE_VALUES" >"$RENDERED"

  rendered_arn="$(
    python3 - "$RENDERED" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    documents = yaml.safe_load_all(stream)
    for document in documents:
        if not isinstance(document, dict):
            continue
        metadata = document.get("metadata", {})
        if (
            document.get("kind") == "ServiceAccount"
            and metadata.get("namespace") == "keda"
            and metadata.get("name") == "keda-operator"
        ):
            print(
                metadata.get("annotations", {}).get(
                    "eks.amazonaws.com/role-arn", ""
                )
            )
            break
PY
  )"
  if [[ "$rendered_arn" != "$ROLE_ARN" ]]; then
    keda_die "렌더링된 keda-operator ServiceAccount의 IRSA annotation 검증에 실패했습니다."
  fi
  keda_info "dry-run 성공: chart 렌더링 및 마스킹된 IRSA annotation 검증 완료"
  exit 0
fi

CURRENT_CONTEXT="$(keda_current_context)"
keda_cluster_reachable ||
  keda_die "실제 배포를 중단합니다. Kubernetes API에 연결할 수 없습니다. kubectl context=$CURRENT_CONTEXT"
if [[ -n "$KEDA_EXPECTED_CONTEXT" && "$CURRENT_CONTEXT" != "$KEDA_EXPECTED_CONTEXT" ]]; then
  keda_die "실제 배포를 중단합니다. kubectl context가 기대값과 다릅니다. current=$CURRENT_CONTEXT, expected=$KEDA_EXPECTED_CONTEXT"
fi
if [[ "$ASSUME_YES" == "true" && -z "$KEDA_EXPECTED_CONTEXT" ]]; then
  keda_die "--yes를 사용한 실제 배포에는 KEDA_EXPECTED_CONTEXT 또는 --expected-context가 필요합니다."
fi
keda_info "배포 대상: mode=workflow, context=$CURRENT_CONTEXT, namespace=$KEDA_NAMESPACE, release=$KEDA_RELEASE"
keda_info "KEDA Role ARN: $(keda_mask_role_arn "$ROLE_ARN")"

if [[ "$ASSUME_YES" != "true" ]]; then
  printf 'context=%s에 KEDA를 workflow/Helm 모드로 배포합니다. 계속하시겠습니까? [y/N] ' \
    "$CURRENT_CONTEXT"
  read -r answer
  [[ "$answer" =~ ^[Yy]$ ]] || keda_die "사용자가 배포를 취소했습니다."
fi

helm upgrade --install "$KEDA_RELEASE" "$KEDA_CHART_REF" \
  --version "$KEDA_CHART_VERSION" \
  --namespace "$KEDA_NAMESPACE" \
  --create-namespace \
  --atomic \
  --wait \
  --timeout 10m \
  -f "$KEDA_BASE_VALUES" \
  -f "$PRIVATE_VALUES"

"$SCRIPT_DIR/verify.sh" --mode workflow
