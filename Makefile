# =============================================================
# 파일 위치 : project3-hailcast-manifests/Makefile
# 소유      : 그룹 C (용빈·지윤)
# 역할      : ops 의 make -C 위임을 받는 진입점(deploy/teardown).
# 사용      : 이 레포에서  make deploy   /  ops 에서  make deploy
# =============================================================

# ★ 커스터마이징: 배포 방식(ArgoCD app-of-apps / helm)은 Phase 4 에서 채운다.

.PHONY: help deploy teardown destroy

help:     ## 명령 목록
	@echo "  make deploy | teardown"

deploy:   ## helm/ArgoCD 배포 (Phase 4에서 구현)
	@echo "TODO(Phase 4): argocd app-of-apps 또는 helm install"
	# 예) kubectl apply -f argocd/app-of-apps.yaml

# K8s 워크로드·ALB 정리 (VPC destroy 를 막는 원인부터 제거 → teardown 최우선 단계)
teardown: ## K8s 워크로드·ALB 정리 (scripts/teardown_manifest.sh)
	@chmod +x scripts/teardown_manifest.sh && bash scripts/teardown_manifest.sh

destroy: teardown