#!/bin/bash
# =============================================================
# 파일위치 : project3-hailcast-manifests/scripts/bootstrap_all.sh
# 소유      : 그룹 C (용빈)
# 역할      : terraform apply 직후, 사람이 손으로 하던 부트스트랩 3단계를
#            명령 하나로 묶는다 (C-6 · 2026-08-20 신설).
#              ① Argo CD 설치        (install_argocd.sh 재사용)
#              ② ESO CRD 설치        (installCRDs:false 라 별도 필요)
#              ③ rds-secret 강제 동기화 (refreshInterval 1h 대기 회피)
# 호출      : make bootstrap-all / 재구축 런북 8-2 3번.
# 배경      : 8/18 재구축에서 ①은 자동이었으나 ②③을 손으로 처리했고,
#            그 과정에서 CRD 버전 불일치·rds-secret 부분 동기화로 시간을 썼다.
#            (ops 재구축_체크리스트.md 8-3-1 · 8-3-2 참고)
# 전제      : helm·kubectl·jq. kubectl 컨텍스트가 hailcast EKS.
# 멱등      : 3단계 전부 재실행 안전. 실패 시 같은 명령을 다시 실행하면 된다.
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ESO 차트 버전 — argocd/applications/external-secrets-app.yaml 의
# targetRevision 과 반드시 같아야 한다. 다르면 컨트롤러가
# "no matches for kind ExternalSecret in version external-secrets.io/v1" 로
# 크래시루프에 빠진다 (8/18 실측).
ESO_CHART_VERSION="${ESO_CHART_VERSION:-2.5.0}"
ESO_NAMESPACE="${ESO_NAMESPACE:-external-secrets}"
APP_NAMESPACE="${APP_NAMESPACE:-hailcast}"

info() { printf '[bootstrap-all] %s\n' "$*"; }
err()  { printf '[bootstrap-all][ERROR] %s\n' "$*" >&2; }

# ── 컨텍스트 가드 (이 레포 스크립트들의 확립된 관례) ──
CTX=$(kubectl config current-context 2>/dev/null || echo "")
if [[ "$CTX" != *"hailcast"* ]]; then
  err "kubectl 컨텍스트가 'hailcast'를 포함하지 않습니다: ${CTX:-<없음>}"
  err "  aws eks update-kubeconfig --name hailcast-dev-eks --region ap-northeast-2"
  exit 1
fi

# ─────────────────────────────────────────────
info "① Argo CD 설치"
# ─────────────────────────────────────────────
bash "$SCRIPT_DIR/install_argocd.sh"

# ─────────────────────────────────────────────
info "② ESO CRD 설치 (차트 ${ESO_CHART_VERSION})"
# ─────────────────────────────────────────────
# GitHub 태그의 deploy/crds/bundle.yaml 을 그대로 쓰면 안 된다 —
# conversion 블록이 Helm 템플릿 변수라 정적 파일은 값이 비어 있고,
# API 서버가 "spec.conversion.strategy: Required value" 로 거부한다.
# 차트에서 직접 렌더링해야 실제 배포와 같은 CRD가 나온다 (8/18 실측).
helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
helm repo update external-secrets >/dev/null

TMP_CRD="$(mktemp)"
trap 'rm -f "$TMP_CRD"' EXIT

helm template external-secrets external-secrets/external-secrets \
  --version "$ESO_CHART_VERSION" \
  -f "$MANIFESTS_ROOT/addons/external-secrets/values.yaml" \
  --set installCRDs=true \
  --set crds.createClusterExternalSecret=true \
  --set crds.createClusterGenerator=true \
  --set crds.createClusterPushSecret=true \
  --namespace "$ESO_NAMESPACE" \
  | python3 -c '
import sys, yaml
docs = list(yaml.safe_load_all(sys.stdin))
crds = [d for d in docs if d and d.get("kind") == "CustomResourceDefinition"]
sys.stderr.write(f"[bootstrap-all] CRD {len(crds)}개 추출\n")
yaml.safe_dump_all(crds, sys.stdout)
' > "$TMP_CRD"

kubectl apply --server-side --force-conflicts -f "$TMP_CRD"

info "② ESO 컨트롤러 기동 대기"
kubectl -n "$ESO_NAMESPACE" rollout status deploy/external-secrets --timeout=180s || {
  err "ESO 컨트롤러가 안 떴습니다. CRD 버전 충돌이면 아래로 복구합니다:"
  err "  kubectl delete crd externalsecrets.external-secrets.io \\"
  err "    secretstores.external-secrets.io clustersecretstores.external-secrets.io"
  err "  그 뒤 이 스크립트를 다시 실행하세요 (ops 8-3-2 참고)"
  exit 1
}

# ─────────────────────────────────────────────
info "③ rds-secret 강제 동기화"
# ─────────────────────────────────────────────
# ESO 컨트롤러가 막 뜬 직후에는 ClusterSecretStore 검증이 아직 안 끝나
# 첫 reconcile 이 실패할 수 있다. refreshInterval 이 1h 라 자동 재시도가
# 최대 한 시간 뒤다 — force-sync 로 즉시 다시 돌린다 (ops 8-3-1).
info "③ ExternalSecret 생성 대기"
for _ in $(seq 1 30); do
  if kubectl -n "$APP_NAMESPACE" get externalsecret rds-credentials >/dev/null 2>&1 \
  && kubectl -n "$APP_NAMESPACE" get externalsecret rds-endpoint >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

TS="$(date +%s)"
for ES in rds-credentials rds-endpoint; do
  kubectl -n "$APP_NAMESPACE" annotate externalsecret "$ES" \
    "force-sync=$TS" --overwrite >/dev/null 2>&1 \
    || info "③ $ES 가 아직 없습니다 — platform-secrets sync 후 수동 실행 필요"
done
sleep 5

KEYS=$(kubectl -n "$APP_NAMESPACE" get secret hailcast-rds-secret \
         -o jsonpath='{.data}' 2>/dev/null | jq -r 'keys | join(",")' 2>/dev/null || echo "")
if [[ "$KEYS" == *"DB_HOST"* && "$KEYS" == *"DB_USER"* && "$KEYS" == *"DB_PASSWORD"* ]]; then
  info "③ hailcast-rds-secret 3키 확인: $KEYS"
else
  err "③ hailcast-rds-secret 키 부족(현재: ${KEYS:-<없음>}) — 아직 sync 중일 수 있습니다."
  err "   잠시 후 확인: kubectl -n $APP_NAMESPACE get secret hailcast-rds-secret -o jsonpath='{.data}' | jq 'keys'"
  err "   그래도 비면 force-sync 재실행 (ops 8-3-1)"
fi

info "완료. 다음 단계는 재구축 런북 8-2 의 4번(배포팀 5줄 반영)입니다."
info "  확인: kubectl -n argocd get application"
