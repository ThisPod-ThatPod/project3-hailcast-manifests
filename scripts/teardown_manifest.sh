#!/bin/bash
# =============================================================
# 파일위치 : project3-hailcast-manifests/scripts/teardown_manifest.sh
# 소유      : 그룹 C (용빈·지윤)
# 역할      : K8s 워크로드·ALB 를 먼저 정리한다 (VPC destroy 를 막는 원인 제거).
# 호출      : ops 의 teardown.sh 가 '가장 먼저' 부른다.
# 삭제 경로 : 팀 결정(teardown_체크리스트.md 6장 게이트②)에 따라 ARGOCD_DELETE_PATH로 분기.
#            argocd = argocd CLI (finalizer 자동 부여, 권장)
#            kubectl = kubectl delete application --all (finalizer 없는 7종은 하위자원 잔존 — 4단계에서 직접 확인 필요)
# 안전      : 실제 삭제 명령은 CONFIRM=yes 일 때만 실행. ops 의 --yes 는 단계별
#            진행 프롬프트만 건너뛸 뿐 CONFIRM 을 넣어주지 않는다(ops/teardown.sh는
#            infra 단계에만 CONFIRM=yes 를 주입함) — 실제로 지우려면 CONFIRM=yes 를
#            직접 넘겨야 한다(예: CONFIRM=yes bash scripts/teardown_manifest.sh).
# =============================================================
set -uo pipefail   # -e는 의도적으로 뺌: 삭제 단계 중 일부 실패해도 확인(③)까지는 마저 돌리고 싶어서.
                    # 대신 각 삭제 명령의 실패는 FAILED로 누적해 마지막에 종료 코드로 반영한다.

CONFIRM="${CONFIRM:-}"
ARGOCD_DELETE_PATH="${ARGOCD_DELETE_PATH:-kubectl}"   # ★ 팀 결정(게이트②) 확정되면 기본값을 그걸로 바꿔도 됨
ROOT_APP="${ROOT_APP:-hailcast-root}"                 # 파일명(app-of-apps.yaml)과 다름 — 실제 Application 이름
FAILED=0

run() {
    echo "  \$ $*"
    if [ "$CONFIRM" = "yes" ]; then
        "$@" || { echo "    [ERROR] 실패: $*"; FAILED=1; }
    else
        echo "    (미실행 — CONFIRM=yes 필요. ops --yes 만으로는 실행되지 않음)"
    fi
}

echo "[manifest] K8s 워크로드·ALB 정리 시작 (삭제 경로: ${ARGOCD_DELETE_PATH})"

# ── 클러스터 컨텍스트 확인 (엉뚱한 클러스터를 지우는 사고 방지) ──────
CTX=$(kubectl config current-context 2>/dev/null || echo "")
if [[ "$CTX" != *"hailcast"* ]]; then
    echo "[manifest][WARN] 현재 kubectl 컨텍스트가 'hailcast'를 포함하지 않습니다: '${CTX}'"
    echo "               aws eks update-kubeconfig --name hailcast-dev-eks --region ap-northeast-2 먼저 실행하세요."
    if [ "$CONFIRM" = "yes" ]; then
        echo "[manifest][ERROR] CONFIRM=yes 상태에서 잘못된 클러스터를 지울 위험 — 중단합니다."
        exit 1
    fi
fi

# ── ① Application 삭제 — 경로 분기 ──────────────────────────
if [ "$ARGOCD_DELETE_PATH" = "argocd" ]; then
    echo "[manifest] 경로 A(argocd CLI) — cascade가 finalizer를 자동 부여, finalizer 없는 7종도 함께 정리됨"
    if [ "$CONFIRM" = "yes" ]; then
        PW=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
        if [ -z "$PW" ]; then
            echo "  [WARN] 초기 admin 비밀번호를 못 가져옴 — 비밀번호를 바꿨다면 ARGOCD_PASSWORD 환경변수로 넘기세요."
            PW="${ARGOCD_PASSWORD:-}"
        fi
        kubectl -n argocd port-forward svc/argocd-server 8080:443 >/tmp/argocd-pf.log 2>&1 &
        PF_PID=$!
        sleep 3
        argocd login localhost:8080 --username admin --password "$PW" --insecure \
            && run argocd app delete "$ROOT_APP" --cascade --yes
        kill "$PF_PID" 2>/dev/null || true
    else
        echo "  \$ argocd app delete ${ROOT_APP} --cascade --yes"
        echo "    (미실행 — CONFIRM=yes 필요. ops --yes 만으로는 실행되지 않음)"
    fi
else
    echo "[manifest] 경로 B(kubectl) — finalizer 없는 7종(grafana-dashboards·karpenter·keda·"
    echo "           kube-prometheus-stack·metrics-server·opencost·platform-monitoring)은"
    echo "           Application만 사라지고 Karpenter 노드·EBS 등 하위 자원이 남을 수 있습니다."
    echo "           → infra teardown_infra.sh의 Karpenter 노드 가드가 잡아줄 것이나, 직접 확인도 권장."
    run kubectl -n argocd delete application --all
fi

# ── ② Ingress/ALB 실제 소거 대기 (최대 3분 폴링) ────────────
echo "[manifest] Ingress/ALB 소거 확인 (최대 3분 폴링, CONFIRM=yes일 때만 대기)"
if [ "$CONFIRM" = "yes" ]; then
    for i in $(seq 1 18); do
        REMAIN_ING=$(kubectl get ingress -A --no-headers 2>/dev/null | wc -l)
        REMAIN_LB=$(kubectl get svc -A --no-headers 2>/dev/null | grep -ci loadbalancer || true)
        if [ "$REMAIN_ING" -eq 0 ] && [ "$REMAIN_LB" -eq 0 ]; then
            echo "  [OK] Ingress/LoadBalancer 전부 제거됨 (${i}0초 소요)"
            break
        fi
        if [ "$i" -eq 18 ]; then
            echo "  [WARN] 3분 넘겨도 Ingress/LB가 남아있습니다 — infra destroy 진행 전 원인 파악 필요"
            FAILED=1
        fi
        sleep 10
    done
fi

# ── ③ 최종 상태 확인 (항상 실행 — CONFIRM 여부 무관, 눈으로 보는 용도) ──
echo "[manifest] 남은 LoadBalancer/Ingress 확인:"
kubectl get ingress -A 2>/dev/null || true
kubectl get svc -A 2>/dev/null | grep -i loadbalancer || echo "  LoadBalancer 타입 서비스 없음(정상)"
aws elbv2 describe-load-balancers --region ap-northeast-2 \
    --query 'LoadBalancers[].LoadBalancerName' --output text 2>/dev/null || true

if [ "$FAILED" -ne 0 ]; then
    echo "[manifest] 일부 단계 실패/미확인 — infra 단계로 넘어가기 전에 위 로그를 확인하세요."
    exit 1
fi
echo "[manifest] 점검 종료."
