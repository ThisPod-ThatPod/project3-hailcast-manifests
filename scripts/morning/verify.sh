#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/morning/_lib.sh
source "$SCRIPT_DIR/_lib.sh"

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
REMEDIES=()

usage() {
  cat <<'EOF'
Usage: verify.sh [--skip-window-check]

야간절전(02:00~10:00 KST) 복원 후 기반·애드온 상태를 점검한다.
아침 복원 체크리스트 1단계(배포팀 담당)를 자동화한 것이다.

이 스크립트는 조회만 한다. 클러스터를 고치지 않으며, 조치가 필요하면
실행할 명령을 출력만 한다.

옵션:
  --skip-window-check  절전 시간대여도 점검을 강행한다(디버깅용)
  -h, --help           이 도움말

종료 코드:
  0  전부 통과(또는 절전 시간대라 점검 생략)
  1  WARN 있음(대개 시간이 더 필요하거나 파드 재시작이 필요)
  2  FAIL 있음(사람이 봐야 함)
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

remedy() {
  REMEDIES+=("$1")
}

SKIP_WINDOW_CHECK=0
while (($#)); do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --skip-window-check)
      SKIP_WINDOW_CHECK=1
      shift
      ;;
    *)
      morning_error "알 수 없는 인자: $1"
      usage >&2
      exit 2
      ;;
  esac
done

morning_require_command kubectl
morning_require_command aws
morning_require_command awk

printf '=== 야간절전 아침 복원 점검 · %s ===\n\n' "$(morning_kst_now)"

# 0. 절전 시간대면 점검 자체가 무의미하다.
#    이 구간의 "노드 0대·파드 없음"은 정상이며 장애가 아니다.
if ((SKIP_WINDOW_CHECK == 0)) && morning_in_shutdown_window; then
  morning_info "지금은 절전 시간대(02:00~10:00 KST)입니다."
  morning_info "노드 0대·파드 없음이 정상이며 장애가 아닙니다. 점검을 생략합니다."
  morning_info "이 시간대에 강제로 점검하려면 --skip-window-check 를 쓰세요."
  exit 0
fi

GRACE=0
if morning_in_grace_window; then
  GRACE=1
  morning_info "복원 직후(10:00~10:15)입니다. 미완성 항목은 FAIL 대신 WARN으로 처리합니다."
  printf '\n'
fi

# 소프트 실패: 유예 구간이면 WARN, 아니면 FAIL
soft_fail() {
  if ((GRACE == 1)); then
    warn "$1 (복원 직후라 몇 분 더 기다려보세요)"
  else
    fail "$1"
  fi
}

# 1. 컨텍스트 확인 — 틀린 클러스터를 점검하면 모든 결과가 무의미하다.
printf '%s\n' '--- 1. 클러스터 컨텍스트 ---'
if morning_context_is_eks; then
  pass "컨텍스트: $(morning_current_context)"
else
  fail "EKS 컨텍스트가 아닙니다: $(morning_current_context)"
  remedy "aws eks update-kubeconfig --name $MORNING_CLUSTER_NAME --region $MORNING_REGION"
  printf '\n'
  morning_error "컨텍스트가 틀려 이후 점검을 진행할 수 없습니다."
  exit 2
fi

if morning_cluster_reachable; then
  pass "API 서버 응답 정상"
else
  fail "API 서버에 접근할 수 없습니다"
  printf '\n'
  exit 2
fi
printf '\n'

# 2. 노드 복원 (10:00 스케줄)
printf -- '--- 2. 노드 (기대 %d대) ---\n' "$MORNING_EXPECTED_NODES"
READY_NODES="$(morning_ready_node_count)"
if ((READY_NODES >= MORNING_EXPECTED_NODES)); then
  pass "Ready 노드 ${READY_NODES}대"
else
  soft_fail "Ready 노드가 ${READY_NODES}대뿐입니다 (기대 ${MORNING_EXPECTED_NODES}대)"
  remedy "kubectl get nodes    # NotReady 사유 확인"
fi
printf '\n'

# 3. RDS 복원 (09:50 스케줄 — 노드보다 먼저 시작하지만 기동에 수 분 걸린다)
printf '%s\n' '--- 3. RDS ---'
RDS_STATUS="$(morning_rds_status)"
case "$RDS_STATUS" in
  available)
    pass "RDS available"
    ;;
  starting | configuring-enhanced-monitoring | backing-up | modifying)
    warn "RDS 기동 중입니다 (상태: $RDS_STATUS)"
    ;;
  unknown)
    fail "RDS 상태를 조회하지 못했습니다 (AWS 자격증명·리전 확인)"
    ;;
  *)
    soft_fail "RDS가 available이 아닙니다 (상태: $RDS_STATUS)"
    ;;
esac
printf '\n'

# 4. 플랫폼 애드온 — ArgoCD가 먼저, 그다음 ESO
printf '%s\n' '--- 4. 플랫폼 애드온 ---'
for ns in argocd external-secrets; do
  RUNNING="$(morning_running_pod_count "$ns")"
  UNHEALTHY="$(morning_unhealthy_pods "$ns")"
  if ((RUNNING > 0)) && [[ -z "$UNHEALTHY" ]]; then
    pass "$ns 파드 ${RUNNING}개 Running"
  elif ((RUNNING == 0)); then
    soft_fail "$ns 에 Running 파드가 없습니다"
  else
    soft_fail "$ns 에 비정상 파드가 있습니다: $(echo "$UNHEALTHY" | tr '\n' ' ')"
  fi
done
printf '\n'

# 5. ESO가 Secret을 다시 만들었는지
#    밤새 사라졌다가 아침에 ESO가 재생성한다. 앱이 이걸 기다린다.
printf '%s\n' '--- 5. Secret 재생성 ---'
if morning_secret_key_exists "$MORNING_APP_NAMESPACE" "$MORNING_RDS_SECRET" "DB_HOST"; then
  pass "$MORNING_RDS_SECRET 존재 (DB_HOST 키 확인)"
else
  soft_fail "$MORNING_RDS_SECRET 이 아직 없거나 키가 비어 있습니다"
  remedy "kubectl get externalsecret -n $MORNING_APP_NAMESPACE    # ESO 동기화 상태 확인"
fi
printf '\n'

# 6. 앱 파드 — Secret이 앱보다 늦게 준비되면 CrashLoop/ConfigError가 난다.
#    이건 순서 문제라 파드만 다시 뜨면 대개 해결된다.
printf -- '--- 6. 앱 파드 (%s) ---\n' "$MORNING_APP_NAMESPACE"
APP_RUNNING="$(morning_running_pod_count "$MORNING_APP_NAMESPACE")"
APP_UNHEALTHY="$(morning_unhealthy_pods "$MORNING_APP_NAMESPACE")"
if ((APP_RUNNING == 0)); then
  soft_fail "$MORNING_APP_NAMESPACE 에 Running 파드가 없습니다"
elif [[ -z "$APP_UNHEALTHY" ]]; then
  pass "앱 파드 ${APP_RUNNING}개 Running, 비정상 없음"
else
  warn "비정상 파드가 있습니다 (${APP_RUNNING}개는 Running):"
  while read -r pod status; do
    [[ -z "$pod" ]] && continue
    printf '         - %s (%s)\n' "$pod" "$status" >&2
    case "$status" in
      CrashLoopBackOff | CreateContainerConfigError | Error)
        remedy "kubectl delete pod -n $MORNING_APP_NAMESPACE $pod    # Secret 준비 후 재기동"
        ;;
    esac
  done <<<"$APP_UNHEALTHY"
fi
printf '\n'

# 7. ArgoCD Application 전수 — 위가 다 정상이어도 sync가 틀어질 수 있다.
printf '%s\n' '--- 7. ArgoCD Application ---'
DEGRADED="$(morning_degraded_applications)"
if [[ -z "$DEGRADED" ]]; then
  pass "모든 Application이 Synced/Healthy"
else
  warn "Synced/Healthy가 아닌 Application:"
  while read -r app status; do
    [[ -z "$app" ]] && continue
    printf '         - %s (%s)\n' "$app" "$status" >&2
  done <<<"$DEGRADED"
  remedy "kubectl patch application <이름> -n argocd --type merge -p '{\"metadata\": {\"annotations\": {\"argocd.argoproj.io/refresh\": \"hard\"}}}'"
fi
printf '\n'

# 결과 요약
printf '=== 요약: PASS %d · WARN %d · FAIL %d ===\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"

if ((${#REMEDIES[@]} > 0)); then
  printf '\n조치가 필요할 수 있습니다. 아래 명령을 확인 후 직접 실행하세요:\n'
  for cmd in "${REMEDIES[@]}"; do
    printf '  %s\n' "$cmd"
  done
  printf '\n클러스터에서만 고친 설정은 selfHeal로 되돌아갑니다.\n'
  printf '설정 변경이 필요하면 git에도 반드시 반영하세요.\n'
fi

if ((FAIL_COUNT > 0)); then
  printf '\n실패 항목이 있습니다. 배포팀 -> 이미선님(인프라) -> 팀장 순으로 공유하세요.\n'
  exit 2
elif ((WARN_COUNT > 0)); then
  printf '\n경고 항목이 있습니다. 몇 분 뒤 다시 실행해보세요.\n'
  exit 1
fi

printf '\n1단계 통과입니다. 앱팀에 "테스트 가능" 알림을 보내세요.\n'
exit 0