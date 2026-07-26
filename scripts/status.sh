#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
APP_NAMESPACE="${APP_NAMESPACE:-hailcast}"
ROOT_APPLICATION="${ROOT_APPLICATION:-hailcast-root}"
FAIL_COUNT=0

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf '[ERROR] 필수 명령을 찾을 수 없습니다: %s\n' "$1" >&2
    exit 1
  }
}

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
  printf '[PASS] %s\n' "$*"
}

application_name_from_file() {
  awk '
    /^metadata:[[:space:]]*$/ { in_metadata=1; next }
    in_metadata && /^[^[:space:]]/ { in_metadata=0 }
    in_metadata && /^[[:space:]]+name:[[:space:]]+/ {
      print $2
      exit
    }
  ' "$1"
}

deployment_name_from_file() {
  awk '
    /^kind:[[:space:]]+Deployment[[:space:]]*$/ { is_deployment=1; next }
    is_deployment && /^metadata:[[:space:]]*$/ { in_metadata=1; next }
    in_metadata && /^[^[:space:]]/ { in_metadata=0 }
    in_metadata && /^[[:space:]]+name:[[:space:]]+/ {
      print $2
      exit
    }
  ' "$1"
}

require_command kubectl
require_command awk
require_command find
require_command jq

current_context="$(kubectl config current-context 2>/dev/null)" || {
  printf '[ERROR] 현재 kubectl context를 확인할 수 없습니다.\n' >&2
  exit 1
}
printf '[status] kubectl context: %s\n' "$current_context"
api_server="$(
  kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null
)"
[[ -n "$api_server" ]] || {
  printf '[ERROR] 현재 context의 API server 주소를 확인할 수 없습니다.\n' >&2
  exit 1
}
printf '[status] API server: %s\n' "$api_server"

kubectl version --request-timeout=10s >/dev/null 2>&1 || {
  printf '[ERROR] Kubernetes API server에 연결할 수 없습니다.\n' >&2
  exit 1
}
pass 'Kubernetes API server 연결'

if ! kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
  printf '[ERROR] Argo CD Application CRD가 없습니다. Argo CD 설치 상태를 확인하세요.\n' >&2
  exit 1
fi
pass 'Argo CD Application CRD 존재'

if ! kubectl get namespace "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
  printf '[ERROR] namespace/%s가 없습니다.\n' "$ARGOCD_NAMESPACE" >&2
  exit 1
fi

if kubectl -n "$ARGOCD_NAMESPACE" get application "$ROOT_APPLICATION" >/dev/null 2>&1; then
  pass "Application/$ROOT_APPLICATION 존재"
else
  fail "Application/$ROOT_APPLICATION 없음 — 최초 등록은 make deploy로 수행"
fi

printf '\n%s\n' '[status] Argo CD Applications'
kubectl -n "$ARGOCD_NAMESPACE" get applications \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'

expected_applications=("$ROOT_APPLICATION")
while IFS= read -r -d '' application_file; do
  application_name="$(application_name_from_file "$application_file")"
  if [[ -n "$application_name" ]]; then
    expected_applications+=("$application_name")
  else
    fail "Application 이름을 읽을 수 없음: ${application_file#"$REPO_ROOT"/}"
  fi
done < <(find "$REPO_ROOT/argocd/applications" -maxdepth 1 -type f -name '*.yaml' -print0)

for application in "${expected_applications[@]}"; do
  if ! application_status="$(
    kubectl -n "$ARGOCD_NAMESPACE" get application "$application" \
      -o jsonpath='{.status.sync.status}{" "}{.status.health.status}' 2>/dev/null
  )"; then
    fail "Application/$application 조회 실패 또는 미등록"
    continue
  fi

  read -r sync_status health_status <<<"$application_status"
  if [[ "$sync_status" == 'Synced' && "$health_status" == 'Healthy' ]]; then
    pass "Application/$application Synced/Healthy"
  else
    fail "Application/$application 상태: sync=${sync_status:-unknown}, health=${health_status:-unknown}"
  fi
done

printf '\n%s\n' "[status] namespace/$APP_NAMESPACE Deployments"
if ! kubectl get namespace "$APP_NAMESPACE" >/dev/null 2>&1; then
  fail "namespace/$APP_NAMESPACE 없음 — Application 동기화 상태 확인 필요"
else
  kubectl -n "$APP_NAMESPACE" get deployments

  while IFS= read -r -d '' deployment_file; do
    deployment_name="$(deployment_name_from_file "$deployment_file")"
    if [[ -z "$deployment_name" ]]; then
      fail "Deployment 이름을 읽을 수 없음: ${deployment_file#"$REPO_ROOT"/}"
      continue
    fi

    if ! deployment_json="$(
      kubectl -n "$APP_NAMESPACE" get deployment "$deployment_name" -o json 2>/dev/null
    )"; then
      fail "Deployment/$APP_NAMESPACE/$deployment_name 조회 실패 또는 미배포"
      continue
    fi

    desired="$(jq -r '.spec.replicas // 0' <<<"$deployment_json")"
    ready="$(jq -r '.status.readyReplicas // 0' <<<"$deployment_json")"
    updated="$(jq -r '.status.updatedReplicas // 0' <<<"$deployment_json")"
    unavailable="$(jq -r '.status.unavailableReplicas // 0' <<<"$deployment_json")"
    if ((ready == desired && updated == desired && unavailable == 0)); then
      pass "Deployment/$deployment_name 준비 완료 (${ready}/${desired})"
    else
      fail "Deployment/$deployment_name 상태: desired=$desired, ready=$ready, updated=$updated, unavailable=$unavailable"
    fi
  done < <(find "$REPO_ROOT/apps" -mindepth 2 -maxdepth 2 -type f -name 'deployment.yaml' -print0)

  printf '\n%s\n' "[status] namespace/$APP_NAMESPACE Pods"
  kubectl -n "$APP_NAMESPACE" get pods -o wide
  pod_json="$(kubectl -n "$APP_NAMESPACE" get pods -o json)"
  pod_count="$(jq '.items | length' <<<"$pod_json")"
  unhealthy_pods="$(
    jq -r '
      .items[]
      | select(
          (.status.phase != "Running" and .status.phase != "Succeeded")
          or (
            .status.phase == "Running"
            and any(.status.containerStatuses[]?; .ready != true)
          )
        )
      | "\(.metadata.name) phase=\(.status.phase)"
    ' <<<"$pod_json"
  )"

  if ((pod_count == 0)); then
    fail "namespace/$APP_NAMESPACE에 Pod가 없음"
  elif [[ -n "$unhealthy_pods" ]]; then
    while IFS= read -r unhealthy_pod; do
      [[ -n "$unhealthy_pod" ]] && fail "비정상 Pod: $unhealthy_pod"
    done <<<"$unhealthy_pods"
  else
    pass "namespace/$APP_NAMESPACE Pod ${pod_count}개 정상"
  fi
fi

printf '\n[status] Summary: FAIL=%d\n' "$FAIL_COUNT"
((FAIL_COUNT == 0))
