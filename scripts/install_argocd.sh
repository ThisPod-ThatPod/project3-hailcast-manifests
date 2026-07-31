#!/bin/bash
# =============================================================
# 파일위치 : project3-hailcast-manifests/scripts/install_argocd.sh
# 소유      : 그룹 C (용빈·지윤)
# 역할      : EKS 클러스터에 Argo CD 를 처음 설치한다 (부트스트랩 — GitOps 관리 '밖').
#            Helm 기반(배포팀 가이드 방식②, 2026-07-31 팀 확정) — 버전 고정·재현 가능.
# 호출      : make install-argocd / 재구축 런북 4절. 사람이 1회 실행.
#            app-of-apps 적용까지 이 스크립트가 끝낸다(가이드 3-1 그대로 —
#            deploy.sh 와 역할이 겹치지만, deploy.sh는 재실행해도 idempotent라 무해함).
# 전제      : helm CLI 필요. kubectl 컨텍스트가 hailcast EKS 를 가리켜야 한다.
# =============================================================
set -euo pipefail

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
# argo-cd 앱 버전 v3.4.5(현재 클러스터 실제 버전)에 대응하는 차트 버전.
# 2026-07-31 helm search repo argo/argo-cd --versions | grep v3.4.5 로 직접 확인함:
#   argo/argo-cd    10.2.1          v3.4.5
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-10.2.1}"

MANIFESTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALUES_FILE="${VALUES_FILE:-$MANIFESTS_ROOT/addons/argocd/values.yaml}"
APP_OF_APPS="${APP_OF_APPS:-$MANIFESTS_ROOT/argocd/app-of-apps.yaml}"

info() { printf '[install-argocd] %s\n' "$*"; }
err()  { printf '[install-argocd][ERROR] %s\n' "$*" >&2; }

# ── 엉뚱한 클러스터(로컬 kubeadm 등)에 설치하는 사고 방지 ──
# (teardown_manifest.sh·deploy.sh 와 동일한 패턴 — 이 레포 스크립트들의 확립된 관례)
CTX=$(kubectl config current-context 2>/dev/null || echo "")
if [[ "$CTX" != *"hailcast"* ]]; then
    err "kubectl 컨텍스트가 'hailcast'를 포함하지 않습니다: '${CTX}'"
    err "aws eks update-kubeconfig --name hailcast-dev-eks --region ap-northeast-2 먼저 실행하세요."
    exit 1
fi

command -v helm >/dev/null 2>&1 || {
    err "helm CLI가 없습니다. https://helm.sh/docs/intro/install/ 참고."
    exit 1
}

info "Helm repo 준비"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null

info "네임스페이스 준비: ${ARGOCD_NAMESPACE}"
kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# ── 멱등: helm upgrade --install — 없으면 install, 있으면 upgrade ──
# CRD 존재 여부로만 skip 판단하면, teardown이 중간에 끊겨 CRD만 남고 본체(Deployment)는
# 없는 상태에서도 "설치됨"으로 오판해 app-of-apps를 바로 적용하다 실패할 수 있다.
# helm upgrade --install은 이런 부분삭제 상태에서도 안전하게 복구·재현한다(Helm 표준
# 멱등 관용구). --wait이 rollout까지 기다려주므로 별도 rollout status 체크는 불필요.
info "Argo CD 설치/갱신 (chart argo-cd ${ARGOCD_CHART_VERSION}, helm upgrade --install)"
helm upgrade --install argocd argo/argo-cd \
    -n "$ARGOCD_NAMESPACE" \
    --version "$ARGOCD_CHART_VERSION" \
    -f "$VALUES_FILE" \
    --wait --timeout 300s

kubectl get crd applications.argoproj.io >/dev/null 2>&1 || {
    err "CRD가 여전히 없습니다 — 설치 실패로 보입니다. helm 로그를 확인하세요."
    exit 1
}

# ── app-of-apps 연결 (가이드 3-1 그대로) ──
# 참고: deploy.sh 도 같은 일을 하는데(root 최초 등록), kubectl apply는 idempotent라
# 여기서 먼저 적용해도 이후 deploy.sh/make deploy 재실행이 깨지지 않는다.
info "app-of-apps(hailcast-root) 적용"
kubectl apply -f "$APP_OF_APPS"

# argocd-initial-admin-secret 은 Helm 차트도 최초 기동 때 런타임에 만든다(차트 템플릿에
# 없음). 비밀번호를 이미 바꿨다면 삭제되고 없을 수 있는데, 그건 설치 실패가 아니므로
# set -e 상태에서 여기서 죽지 않게 한다.
info "완료. 초기 admin 비밀번호:"
if PW=$(kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret \
        -o jsonpath='{.data.password}' 2>/dev/null) && [ -n "$PW" ]; then
    printf '%s\n' "$PW" | base64 -d; printf '\n'
else
    info "  (initial-admin-secret 없음 — 비밀번호를 이미 변경했거나 삭제된 상태)"
    info "  대체: kubectl exec -n ${ARGOCD_NAMESPACE} deployment/argocd-server -- argocd admin initial-password -n ${ARGOCD_NAMESPACE}"
fi

info "Argo CD 설치 완료(app-of-apps 포함)."
info "참고: ESO CRD는 별도 필요(installCRDs:false) — infra docs/비용관리.md '재구축 시 hailcast-rds-secret' 절 참고."
