# =============================================================
# 파일 위치 : project3-hailcast-manifests/Makefile
# 소유      : 그룹 C (용빈·지윤)
# 역할      : Kubernetes·GitOps 검증 및 Argo CD 운영 진입점.
# 사용      : 이 레포에서 make <target> / ops 에서 make -C manifests deploy
# =============================================================

.DEFAULT_GOAL := help

.PHONY: help validate install-argocd deploy-dry-run deploy status teardown destroy

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
	@echo "  make install-argocd  Argo CD 최초 설치(Helm) + app-of-apps 등록 (부트스트랩, 멱등)"
	@echo "  make deploy-dry-run  root Application 서버 검증만 수행 (클러스터 변경 없음)"
	@echo "  make deploy          root가 없으면 실제 최초 등록 후 GitOps 상태 확인"
	@echo "                       (root 외 workload/child Application은 직접 apply하지 않음)"
	@echo "  make status          Argo CD Application 및 hailcast Deployment/Pod 읽기 전용 확인"
	@echo ""
	@echo "  [ 파괴 작업 ]"
	@echo "  make teardown   ArgoCD Application 삭제 + Ingress/ALB 소거 확인 (CONFIRM=yes 필요)"
	@echo "                  삭제 경로는 ARGOCD_DELETE_PATH=argocd|kubectl 로 지정(기본 argocd, C-1)"
	@echo "  make destroy    teardown 호환 별칭"
	@echo ""

validate: ## 클러스터 없이 manifests 정적 검증
	@bash scripts/validate.sh

install-argocd: ## Argo CD 최초 설치(Helm) + app-of-apps 등록 (부트스트랩, 멱등)
	@bash scripts/install_argocd.sh

deploy-dry-run: validate ## root Application server-side dry-run (클러스터 변경 없음)
	@echo "[deploy-dry-run] Argo CD root Application을 server-side dry-run으로 검증합니다."
	@kubectl apply --dry-run=server -f argocd/app-of-apps.yaml
	@echo "[deploy-dry-run] 서버 검증을 통과했습니다. 클러스터 리소스는 변경하지 않았습니다."

deploy: validate ## Argo CD root 최초 등록 또는 기존 GitOps 상태 확인
	@bash scripts/deploy.sh

status: ## Argo CD와 hailcast 핵심 리소스 상태 확인(읽기 전용)
	@bash scripts/status.sh

teardown: ## ArgoCD Application 삭제 + Ingress/ALB 소거 확인 (CONFIRM=yes 필요, ARGOCD_DELETE_PATH로 경로 지정)
	@bash scripts/teardown_manifest.sh

destroy: teardown ## teardown 호환 별칭
