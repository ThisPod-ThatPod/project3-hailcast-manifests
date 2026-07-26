#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EXPECTED_CLUSTER_NAME="${EXPECTED_CLUSTER_NAME:-hailcast-dev-eks}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ROOT_APPLICATION="${ROOT_APPLICATION:-hailcast-root}"
ROOT_MANIFEST="$REPO_ROOT/argocd/app-of-apps.yaml"
DEPLOY_TIMEOUT_SECONDS="${DEPLOY_TIMEOUT_SECONDS:-300}"
DEPLOY_POLL_INTERVAL_SECONDS="${DEPLOY_POLL_INTERVAL_SECONDS:-10}"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf '[ERROR] 필수 명령을 찾을 수 없습니다: %s\n' "$1" >&2
    exit 1
  }
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

print_application_statuses() {
  kubectl -n "$ARGOCD_NAMESPACE" get applications \
    -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
}

require_command kubectl
require_command jq
require_command awk
require_command find

[[ "$DEPLOY_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || {
  printf '[ERROR] DEPLOY_TIMEOUT_SECONDS는 0 이상의 정수여야 합니다: %s\n' \
    "$DEPLOY_TIMEOUT_SECONDS" >&2
  exit 1
}
[[ "$DEPLOY_POLL_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || {
  printf '[ERROR] DEPLOY_POLL_INTERVAL_SECONDS는 1 이상의 정수여야 합니다: %s\n' \
    "$DEPLOY_POLL_INTERVAL_SECONDS" >&2
  exit 1
}
DEPLOY_TIMEOUT_SECONDS=$((10#$DEPLOY_TIMEOUT_SECONDS))
DEPLOY_POLL_INTERVAL_SECONDS=$((10#$DEPLOY_POLL_INTERVAL_SECONDS))
((DEPLOY_POLL_INTERVAL_SECONDS >= 1)) || {
  printf '[ERROR] DEPLOY_POLL_INTERVAL_SECONDS는 1 이상이어야 합니다: %s\n' \
    "$DEPLOY_POLL_INTERVAL_SECONDS" >&2
  exit 1
}
((DEPLOY_TIMEOUT_SECONDS >= DEPLOY_POLL_INTERVAL_SECONDS)) || {
  printf '[ERROR] DEPLOY_TIMEOUT_SECONDS(%s)는 DEPLOY_POLL_INTERVAL_SECONDS(%s) 이상이어야 합니다.\n' \
    "$DEPLOY_TIMEOUT_SECONDS" "$DEPLOY_POLL_INTERVAL_SECONDS" >&2
  exit 1
}

[[ -f "$ROOT_MANIFEST" ]] || {
  printf '[ERROR] root Application manifest가 없습니다: %s\n' "$ROOT_MANIFEST" >&2
  exit 1
}

current_context="$(kubectl config current-context 2>/dev/null)" || {
  printf '[ERROR] 현재 kubectl context를 확인할 수 없습니다.\n' >&2
  exit 1
}
printf '[deploy] kubectl context: %s\n' "$current_context"

case "$current_context" in
  "$EXPECTED_CLUSTER_NAME" | *":cluster/$EXPECTED_CLUSTER_NAME")
    ;;
  *)
    printf '[ERROR] 대상 클러스터가 아닙니다. 현재=%s, 기대=%s\n' \
      "$current_context" "$EXPECTED_CLUSTER_NAME" >&2
    exit 1
    ;;
esac

api_server="$(
  kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null
)"
[[ -n "$api_server" ]] || {
  printf '[ERROR] 현재 context의 API server 주소를 확인할 수 없습니다.\n' >&2
  exit 1
}
printf '[deploy] API server: %s\n' "$api_server"

kubectl version --request-timeout=10s >/dev/null 2>&1 || {
  printf '[ERROR] Kubernetes API server에 연결할 수 없습니다.\n' >&2
  exit 1
}

kubectl get crd applications.argoproj.io >/dev/null 2>&1 || {
  printf '[ERROR] Argo CD Application CRD가 없습니다. Argo CD를 먼저 설치하세요.\n' >&2
  exit 1
}

kubectl get namespace "$ARGOCD_NAMESPACE" >/dev/null 2>&1 || {
  printf '[ERROR] namespace/%s가 없습니다. Argo CD 설치 상태를 확인하세요.\n' \
    "$ARGOCD_NAMESPACE" >&2
  exit 1
}

controller_pods="$(
  kubectl -n "$ARGOCD_NAMESPACE" get pods \
    -l app.kubernetes.io/name=argocd-application-controller -o json
)"
controller_count="$(jq '.items | length' <<<"$controller_pods")"
controller_ready="$(
  jq '[
    .items[]
    | select(
        .status.phase == "Running"
        and any(.status.containerStatuses[]?; .ready == true)
      )
  ] | length' <<<"$controller_pods"
)"
if ((controller_count == 0 || controller_ready == 0)); then
  printf '[ERROR] Ready 상태의 Argo CD Application Controller를 찾을 수 없습니다.\n' >&2
  exit 1
fi
printf '[deploy] Argo CD Application Controller Ready (%d/%d)\n' \
  "$controller_ready" "$controller_count"

root_applied=0
if ! root_application_name="$(
  kubectl -n "$ARGOCD_NAMESPACE" get application "$ROOT_APPLICATION" \
    --ignore-not-found -o name
)"; then
  printf '[ERROR] Application/%s 존재 여부를 확인하는 중 kubectl 오류가 발생했습니다.\n' \
    "$ROOT_APPLICATION" >&2
  exit 1
fi

if [[ -n "$root_application_name" ]]; then
  printf '[deploy] Application/%s가 이미 등록되어 있습니다. 직접 apply 또는 강제 sync를 수행하지 않습니다.\n' \
    "$ROOT_APPLICATION"
else
  printf '[deploy] Application/%s 최초 등록: %s\n' \
    "$ROOT_APPLICATION" "${ROOT_MANIFEST#"$REPO_ROOT"/}"
  kubectl apply -f "$ROOT_MANIFEST"
  root_applied=1
fi

if ((root_applied == 1)); then
  expected_applications=("$ROOT_APPLICATION")
  while IFS= read -r -d '' application_file; do
    application_name="$(application_name_from_file "$application_file")"
    [[ -n "$application_name" ]] || {
      printf '[ERROR] Application 이름을 읽을 수 없습니다: %s\n' \
        "${application_file#"$REPO_ROOT"/}" >&2
      exit 1
    }
    expected_applications+=("$application_name")
  done < <(find "$REPO_ROOT/argocd/applications" -maxdepth 1 -type f -name '*.yaml' -print0)

  printf '[deploy] Argo CD 동기화를 대기합니다 (timeout=%ss, interval=%ss, applications=%d).\n' \
    "$DEPLOY_TIMEOUT_SECONDS" "$DEPLOY_POLL_INTERVAL_SECONDS" "${#expected_applications[@]}"

  polling_started_at=$SECONDS
  polling_deadline=$((polling_started_at + DEPLOY_TIMEOUT_SECONDS))
  while true; do
    elapsed=$((SECONDS - polling_started_at))
    printf '\n[deploy] Application 상태 (%ss 경과)\n' "$elapsed"
    print_application_statuses

    all_ready=1
    for application in "${expected_applications[@]}"; do
      if ! application_status="$(
        kubectl -n "$ARGOCD_NAMESPACE" get application "$application" \
          --ignore-not-found \
          -o jsonpath='{.metadata.name}{"|"}{.status.sync.status}{"|"}{.status.health.status}'
      )"; then
        printf '[ERROR] Application/%s 조회 중 kubectl 오류가 발생했습니다.\n' \
          "$application" >&2
        exit 1
      fi

      if [[ -z "$application_status" ]]; then
        printf '  [WAIT] %-32s 미등록\n' "$application"
        all_ready=0
        continue
      fi

      IFS='|' read -r _ sync_status health_status <<<"$application_status"
      if [[ "$sync_status" == 'Synced' && "$health_status" == 'Healthy' ]]; then
        printf '  [READY] %-31s Synced/Healthy\n' "$application"
      else
        printf '  [WAIT] %-32s sync=%s health=%s\n' \
          "$application" "${sync_status:-unknown}" "${health_status:-unknown}"
        all_ready=0
      fi
    done

    if ((all_ready == 1)); then
      printf '[deploy] 모든 예상 Application이 Synced/Healthy 상태입니다.\n'
      break
    fi

    remaining=$((polling_deadline - SECONDS))
    if ((remaining <= 0)); then
      printf '\n[ERROR] Argo CD 동기화 제한 시간(%ss)을 초과했습니다. 현재 상태:\n' \
        "$DEPLOY_TIMEOUT_SECONDS" >&2
      print_application_statuses >&2
      exit 1
    fi

    sleep_seconds=$DEPLOY_POLL_INTERVAL_SECONDS
    if ((sleep_seconds > remaining)); then
      sleep_seconds=$remaining
    fi
    sleep "$sleep_seconds"
  done
fi

printf '%s\n' '[deploy] Argo CD automated sync 결과를 확인합니다.'
bash "$SCRIPT_DIR/status.sh"
printf '%s\n' '[deploy] 모든 Application과 핵심 리소스가 정상 상태입니다.'
