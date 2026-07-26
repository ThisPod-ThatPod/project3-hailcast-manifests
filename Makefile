# =============================================================
# 파일 위치 : project3-hailcast-manifests/Makefile
# 소유      : 그룹 C (용빈·지윤)
# 역할      : Kubernetes·GitOps 검증 및 Argo CD 운영 진입점.
# 사용      : 이 레포에서 make <target> / ops 에서 make -C manifests deploy
# =============================================================

.DEFAULT_GOAL := help

.PHONY: help validate deploy-dry-run deploy status teardown destroy

help: ## 명령 목록
	@echo ""
	@echo "====================================================="
	@echo "  Hailcast manifests · Kubernetes/GitOps 운영 명령"
	@echo "====================================================="
	@echo ""
	@echo "  [ 정적 검증 · AWS 자격증명/kubeconfig 불필요 ]"
	@echo "  make validate   Dashboard JSON, kustomize, shell 구문, git diff 검사"
	@echo ""
	@echo "  [ 실클러스터 · 유효한 kubeconfig/EKS 인증 필요 ]"
	@echo "  make deploy-dry-run  root Application 서버 검증만 수행 (클러스터 변경 없음)"
	@echo "  make deploy          root가 없으면 실제 최초 등록 후 GitOps 상태 확인"
	@echo "                       (root 외 workload/child Application은 직접 apply하지 않음)"
	@echo "  make status          Argo CD Application 및 hailcast Deployment/Pod 읽기 전용 확인"
	@echo ""
	@echo "  [ 파괴 작업 ]"
	@echo "  make teardown   기존 정리 스크립트 호출 (실제 삭제는 CONFIRM=yes 필요)"
	@echo "                  현재 legacy 스크립트는 전체 삭제 완료를 보장하지 않으므로 잔존 확인 필요"
	@echo "  make destroy    teardown 호환 별칭"
	@echo ""

validate: ## 클러스터 없이 manifests 정적 검증
	@bash scripts/validate.sh

deploy-dry-run: validate ## root Application server-side dry-run (클러스터 변경 없음)
	@echo "[deploy-dry-run] Argo CD root Application을 server-side dry-run으로 검증합니다."
	@kubectl apply --dry-run=server -f argocd/app-of-apps.yaml
	@echo "[deploy-dry-run] 서버 검증을 통과했습니다. 클러스터 리소스는 변경하지 않았습니다."

deploy: validate ## Argo CD root 최초 등록 또는 기존 GitOps 상태 확인
	@bash scripts/deploy.sh

status: ## Argo CD와 hailcast 핵심 리소스 상태 확인(읽기 전용)
	@bash scripts/status.sh

# 기존 Ops 및 직접 호출 계약을 유지한다. 삭제 로직은 이번 범위에서 재설계하지 않는다.
teardown: ## 기존 K8s 정리 스크립트 호출 (CONFIRM=yes 필요, 잔존 확인 필수)
	@echo "[WARN] legacy teardown 진입점입니다. 실행 후 Application/Ingress/LoadBalancer 잔존 여부를 확인하세요."
	@bash scripts/teardown_manifest.sh

destroy: teardown ## teardown 호환 별칭
