#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/keda/_lib.sh
source "$SCRIPT_DIR/_lib.sh"

MODE="workflow"
KEDA_VERIFY_LOG_SINCE="${KEDA_VERIFY_LOG_SINCE:-10m}"
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

usage() {
  cat <<'EOF'
Usage: verify.sh [--mode workflow|gitops]
EOF
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf '[PASS] %s\n' "$*"
}

warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  printf '[WARN] %s\n' "$*" >&2
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '[FAIL] %s\n' "$*" >&2
}

while (($#)); do
  case "$1" in
    --mode)
      [[ $# -ge 2 ]] || keda_die "--mode 값이 필요합니다."
      MODE="$2"
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
[[ "$KEDA_VERIFY_LOG_SINCE" =~ ^([0-9]+(ms|s|m|h))+$ ]] ||
  keda_die "KEDA_VERIFY_LOG_SINCE 형식이 잘못되었습니다: $KEDA_VERIFY_LOG_SINCE"

keda_require_command kubectl
keda_require_command jq
if [[ "$MODE" == "workflow" ]]; then
  keda_require_command helm
fi

keda_info "kubectl context: $(keda_current_context)"
keda_cluster_reachable || keda_die "Kubernetes API에 연결할 수 없습니다."

if kubectl get namespace "$KEDA_NAMESPACE" >/dev/null 2>&1; then
  pass "namespace/$KEDA_NAMESPACE 존재"
else
  fail "namespace/$KEDA_NAMESPACE 없음"
fi

if [[ "$MODE" == "workflow" ]]; then
  if keda_helm_release_exists; then
    pass "Helm release $KEDA_NAMESPACE/$KEDA_RELEASE 존재"
  else
    fail "Helm release $KEDA_NAMESPACE/$KEDA_RELEASE 없음"
  fi
  if keda_argocd_application_exists; then
    fail "workflow 모드인데 ArgoCD Application/keda도 존재함"
  fi
else
  if keda_argocd_application_exists; then
    pass "ArgoCD Application/argocd/$KEDA_APPLICATION 존재"
    sync_status="$(keda_argocd_sync_status)"
    health_status="$(
      kubectl -n argocd get application "$KEDA_APPLICATION" \
        -o jsonpath='{.status.health.status}' 2>/dev/null || true
    )"
    if [[ "$sync_status" == "Synced" ]]; then
      pass "ArgoCD sync status=Synced"
    else
      fail "ArgoCD sync status=${sync_status:-unknown}"
    fi
    if [[ "$health_status" == "Healthy" ]]; then
      pass "ArgoCD health status=Healthy"
    else
      fail "ArgoCD health status=${health_status:-unknown}"
    fi
  else
    fail "ArgoCD Application/argocd/$KEDA_APPLICATION 없음"
  fi
  if keda_helm_release_exists; then
    fail "gitops 모드인데 독립 Helm release도 존재함"
  fi
fi

if sa_json="$(kubectl -n "$KEDA_NAMESPACE" get serviceaccount keda-operator -o json 2>/dev/null)"; then
  pass "ServiceAccount $KEDA_NAMESPACE/keda-operator 존재"
  role_arn="$(
    jq -r '.metadata.annotations["eks.amazonaws.com/role-arn"] // empty' <<<"$sa_json"
  )"
  if [[ -z "$role_arn" ]]; then
    fail "ServiceAccount IRSA annotation 없음"
  elif keda_valid_role_arn "$role_arn"; then
    pass "ServiceAccount IRSA annotation 유효: $(keda_mask_role_arn "$role_arn")"
  else
    fail "ServiceAccount IRSA annotation 형식 오류: $(keda_mask_role_arn "$role_arn")"
  fi
else
  fail "ServiceAccount $KEDA_NAMESPACE/keda-operator 없음"
fi

operator_sa="$(
  kubectl -n "$KEDA_NAMESPACE" get deployment keda-operator \
    -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || true
)"
if [[ "$operator_sa" == "keda-operator" ]]; then
  pass "Deployment/keda-operator serviceAccountName 일치"
else
  fail "Deployment/keda-operator serviceAccountName=${operator_sa:-missing}"
fi

deployments=(
  keda-operator
  keda-operator-metrics-apiserver
  keda-admission-webhooks
)
for deployment in "${deployments[@]}"; do
  available="$(
    kubectl -n "$KEDA_NAMESPACE" get deployment "$deployment" \
      -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true
  )"
  if [[ "$available" == "True" ]]; then
    pass "Deployment/$deployment Available"
  else
    fail "Deployment/$deployment Available 상태가 아님"
  fi
done

pod_summary="$(
  kubectl -n "$KEDA_NAMESPACE" get pods -o json 2>/dev/null |
    jq -r '
      [.items[] | select(
        (.metadata.labels["app.kubernetes.io/part-of"] == "keda-operator") or
        ((.metadata.labels["app.kubernetes.io/name"] // "") | startswith("keda"))
      )] as $pods |
      {
        total: ($pods | length),
        notReady: ([
          $pods[] |
          select(
            (.status.phase != "Running") or
            (any(.status.containerStatuses[]?; .ready != true))
          )
        ] | length)
      } |
      "\(.total) \(.notReady)"
    ' 2>/dev/null || true
)"
read -r pod_total pod_not_ready <<<"${pod_summary:-0 0}"
if [[ "${pod_total:-0}" -gt 0 && "${pod_not_ready:-0}" -eq 0 ]]; then
  pass "KEDA Pod Ready (${pod_total}개)"
else
  fail "KEDA Pod Ready 실패 (total=${pod_total:-0}, notReady=${pod_not_ready:-0})"
fi

crds=(
  scaledobjects.keda.sh
  triggerauthentications.keda.sh
  clustertriggerauthentications.keda.sh
  scaledjobs.keda.sh
)
for crd in "${crds[@]}"; do
  established="$(
    kubectl get crd "$crd" \
      -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null || true
  )"
  if [[ "$established" == "True" ]]; then
    pass "CRD/$crd Established"
  else
    fail "CRD/$crd 미설치 또는 Established 아님"
  fi
done

if kubectl api-resources --api-group=keda.sh -o name 2>/dev/null |
  grep -Eq '^triggerauthentications(\.keda\.sh)?$'; then
  pass "TriggerAuthentication API 사용 가능"
else
  fail "TriggerAuthentication API를 찾을 수 없음"
fi

auth_error_pattern='AccessDenied|WebIdentity|NoCredentialProviders|InvalidIdentityToken|AssumeRoleWithWebIdentity|failed to refresh cached credentials|unable to retrieve credentials'
operator_logs="$(
  kubectl -n "$KEDA_NAMESPACE" logs deployment/keda-operator \
    --all-pods=true --since="$KEDA_VERIFY_LOG_SINCE" 2>/dev/null || true
)"
if [[ -z "$operator_logs" ]]; then
  warn "KEDA Operator 로그를 읽지 못했거나 최근 ${KEDA_VERIFY_LOG_SINCE} 로그가 비어 있음"
elif grep -Eiq "$auth_error_pattern" <<<"$operator_logs"; then
  fail "KEDA Operator 최근 ${KEDA_VERIFY_LOG_SINCE} 로그에서 AWS 인증 오류 패턴 발견(로그 값은 출력하지 않음)"
else
  pass "KEDA Operator 최근 ${KEDA_VERIFY_LOG_SINCE} 로그에 대표 AWS 인증 오류 없음"
fi

if kubectl get namespace hailcast >/dev/null 2>&1; then
  if kubectl -n hailcast get scaledobject hailcast-worker-scaler >/dev/null 2>&1; then
    scaled_ready="$(
      kubectl -n hailcast get scaledobject hailcast-worker-scaler \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true
    )"
    if [[ "$scaled_ready" == "True" ]]; then
      pass "ScaledObject hailcast/hailcast-worker-scaler Ready"
    else
      fail "ScaledObject hailcast/hailcast-worker-scaler Ready 상태가 아님"
    fi
  else
    warn "hailcast namespace는 있으나 Worker ScaledObject가 아직 없음"
  fi
else
  warn "hailcast namespace가 아직 없어 Worker ScaledObject 검사를 건너뜀"
fi

printf '\nSummary: PASS=%d WARN=%d FAIL=%d\n' \
  "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
((FAIL_COUNT == 0))
