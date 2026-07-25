#!/usr/bin/env bash

# 야간절전(02:00~10:00 KST) 아침 복원 점검 공통 정의
# 규약서 §5-8 schedule 기준:
#   02:00 노드 min0/desired0 · 02:05 RDS 정지
#   09:50 RDS 시작 · 10:00 노드 min2/desired2

# shellcheck disable=SC2034  # verify.sh 에서 사용
MORNING_CLUSTER_NAME="hailcast-dev-eks"
MORNING_REGION="ap-northeast-2"
MORNING_RDS_INSTANCE="hailcast-dev-rds-postgres"
# shellcheck disable=SC2034  # verify.sh 에서 사용
MORNING_APP_NAMESPACE="hailcast"
# shellcheck disable=SC2034  # verify.sh 에서 사용
MORNING_EXPECTED_NODES=2
# shellcheck disable=SC2034  # verify.sh 에서 사용
MORNING_RDS_SECRET="hailcast-rds-secret"

# 절전 시간대(KST 기준). 이 안이면 인프라가 없는 게 정상이다.
MORNING_SHUTDOWN_START_HOUR=2
MORNING_SHUTDOWN_END_HOUR=10

morning_info() {
  printf '[INFO] %s\n' "$*"
}

morning_error() {
  printf '[ERROR] %s\n' "$*" >&2
}

morning_die() {
  morning_error "$*"
  exit 1
}

morning_require_command() {
  command -v "$1" >/dev/null 2>&1 || morning_die "필수 명령을 찾을 수 없습니다: $1"
}

morning_current_context() {
  kubectl config current-context 2>/dev/null || printf '<none>\n'
}

# 컨텍스트가 EKS인지 확인한다.
# 과거 로컬 kubeadm 클러스터를 EKS로 착각해 시간을 버린 사고가 있었다.
morning_context_is_eks() {
  local ctx
  ctx="$(morning_current_context)"
  [[ "$ctx" == *"$MORNING_CLUSTER_NAME"* ]]
}

morning_cluster_reachable() {
  kubectl version --request-timeout=10s >/dev/null 2>&1
}

# KST 기준 현재 시각(0~23). 로컬 TZ와 무관하게 계산한다.
morning_kst_hour() {
  TZ="Asia/Seoul" date +%-H
}

morning_kst_now() {
  TZ="Asia/Seoul" date '+%Y-%m-%d %H:%M:%S KST'
}

# 지금이 절전 시간대인가. 이 시간엔 노드 0대·파드 없음이 정상이며 장애가 아니다.
morning_in_shutdown_window() {
  local hour
  hour="$(morning_kst_hour)"
  ((hour >= MORNING_SHUTDOWN_START_HOUR && hour < MORNING_SHUTDOWN_END_HOUR))
}

# 복원 직후(10:00~10:15)인가. 이 구간의 미완성은 FAIL이 아니라 WARN으로 다룬다.
morning_in_grace_window() {
  local hour minute
  hour="$(TZ="Asia/Seoul" date +%-H)"
  minute="$(TZ="Asia/Seoul" date +%-M)"
  ((hour == MORNING_SHUTDOWN_END_HOUR && minute < 15))
}

morning_ready_node_count() {
  kubectl get nodes --no-headers 2>/dev/null |
    awk '$2 == "Ready" { count++ } END { print count + 0 }'
}

morning_rds_status() {
  aws rds describe-db-instances \
    --db-instance-identifier "$MORNING_RDS_INSTANCE" \
    --region "$MORNING_REGION" \
    --query 'DBInstances[0].DBInstanceStatus' \
    --output text 2>/dev/null || printf 'unknown\n'
}

# 네임스페이스의 Running이 아닌 파드를 "이름 상태" 형식으로 출력한다.
morning_unhealthy_pods() {
  local namespace="$1"
  kubectl get pods -n "$namespace" --no-headers 2>/dev/null |
    awk '$3 != "Running" && $3 != "Completed" { print $1, $3 }'
}

morning_running_pod_count() {
  local namespace="$1"
  kubectl get pods -n "$namespace" --no-headers 2>/dev/null |
    awk '$3 == "Running" { count++ } END { print count + 0 }'
}

morning_secret_key_exists() {
  local namespace="$1" secret="$2" key="$3"
  kubectl get secret "$secret" -n "$namespace" \
    -o "jsonpath={.data.$key}" 2>/dev/null | grep -q .
}

# Synced/Healthy가 아닌 ArgoCD Application을 "이름 sync/health" 형식으로 출력한다.
morning_degraded_applications() {
  kubectl get applications -n argocd \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.sync.status}{" "}{.status.health.status}{"\n"}{end}' \
    2>/dev/null |
    awk '$2 != "Synced" || $3 != "Healthy" { print $1, $2 "/" $3 }'
}