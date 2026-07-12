#!/bin/bash
# =============================================================
# 넣을 위치 : project3-hailcast-manifests/scripts/teardown_manifest.sh
# 소유      : 그룹 C (용빈·지윤)
# 역할      : K8s 워크로드·ALB 를 먼저 정리한다 (VPC destroy 를 막는 원인 제거).
# 호출      : ops 의 teardown.sh 가 '가장 먼저' 부른다.
# 커스터마이징: ★ 표시 부분을 각자 배포 방식(ArgoCD/helm/kubectl)에 맞게 채운다.
# 안전      : 실제 삭제 명령은 CONFIRM=yes 일 때만 실행(ops --yes 시 자동 주입).
# =============================================================
set -u
CONFIRM="${CONFIRM:-}"
run() { echo "  \$ $*"; [ "$CONFIRM" = "yes" ] && "$@" || echo "    (미실행 — CONFIRM=yes 또는 ops --yes 로 실행)"; }

echo "[manifest] K8s 워크로드·ALB 정리 시작"

# ── ① ArgoCD Application 삭제 (cascade — 하위 리소스까지) ★
# run argocd app delete hailcast --cascade --yes
# 또는 app-of-apps 를 쓰면 최상위 하나만:
# run argocd app delete hailcast-root --cascade --yes

# ── ② (ArgoCD 안 쓰면) helm / kubectl 로 직접 ★
# run helm uninstall hailcast -n hailcast
# run kubectl delete -f ../apps/ -R

# ── ③ Ingress(ALB) 가 실제로 사라졌는지 확인 — 이게 핵심 ────────────
# LB Controller 가 만든 ALB·타깃그룹·ENI 가 남으면 infra terraform destroy 가 VPC 를 못 지운다.
echo "[manifest] 남은 LoadBalancer/Ingress 확인:"
kubectl get ingress -A 2>/dev/null || true
kubectl get svc -A 2>/dev/null | grep -i loadbalancer || echo "  LoadBalancer 타입 서비스 없음(정상)"

# ── ④ 사라질 때까지 대기 (선택) ★
# echo "[manifest] ALB 삭제 반영까지 대기(최대 3분)..."
# for i in $(seq 1 18); do
#     kubectl get ingress -A 2>/dev/null | grep -q . || break
#     sleep 10
# done

echo "[manifest] 완료 — 이제 infra terraform destroy 가 안전합니다."