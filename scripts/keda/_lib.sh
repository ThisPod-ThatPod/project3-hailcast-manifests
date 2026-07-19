#!/usr/bin/env bash

KEDA_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEDA_REPO_ROOT="$(cd "$KEDA_SCRIPT_DIR/../.." && pwd)"

KEDA_CHART_REPO_NAME="kedacore"
KEDA_CHART_REPO_URL="https://kedacore.github.io/charts"
KEDA_CHART_REF="${KEDA_CHART_REPO_NAME}/keda"
KEDA_CHART_VERSION="2.20.1"
KEDA_RELEASE="keda"
KEDA_NAMESPACE="keda"
KEDA_APPLICATION="keda"
KEDA_BASE_VALUES="$KEDA_REPO_ROOT/addons/keda/values.yaml"
KEDA_APPLICATION_FILE="$KEDA_REPO_ROOT/argocd/applications/keda.yaml"

keda_info() {
  printf '[INFO] %s\n' "$*"
}

keda_warn() {
  printf '[WARN] %s\n' "$*" >&2
}

keda_error() {
  printf '[ERROR] %s\n' "$*" >&2
}

keda_die() {
  keda_error "$*"
  exit 1
}

keda_require_command() {
  command -v "$1" >/dev/null 2>&1 || keda_die "필수 명령을 찾을 수 없습니다: $1"
}

keda_valid_role_arn() {
  local arn="${1:-}"
  [[ "$arn" =~ ^arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$ ]] &&
    [[ "${arn,,}" == *keda* ]]
}

keda_mask_role_arn() {
  local arn="${1:-}"
  if keda_valid_role_arn "$arn"; then
    printf 'arn:aws:iam::************:role/***keda***\n'
  else
    printf '<invalid-or-missing-role-arn>\n'
  fi
}

keda_current_context() {
  kubectl config current-context 2>/dev/null || printf '<none>\n'
}

keda_cluster_reachable() {
  kubectl version --request-timeout=5s >/dev/null 2>&1
}

keda_argocd_application_exists() {
  kubectl get crd applications.argoproj.io >/dev/null 2>&1 &&
    kubectl -n argocd get application "$KEDA_APPLICATION" >/dev/null 2>&1
}

keda_argocd_sync_status() {
  kubectl -n argocd get application "$KEDA_APPLICATION" \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || true
}

keda_helm_release_exists() {
  helm status "$KEDA_RELEASE" -n "$KEDA_NAMESPACE" >/dev/null 2>&1
}

keda_resource_tracking_owner() {
  local tracking release_annotation
  tracking="$(
    kubectl -n "$KEDA_NAMESPACE" get deployment keda-operator \
      -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}' 2>/dev/null || true
  )"
  release_annotation="$(
    kubectl -n "$KEDA_NAMESPACE" get deployment keda-operator \
      -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || true
  )"

  if [[ -n "$tracking" ]]; then
    printf 'argocd\n'
  elif [[ "$release_annotation" == "$KEDA_RELEASE" ]]; then
    printf 'helm\n'
  else
    printf 'unknown\n'
  fi
}

keda_check_ownership() {
  local mode="$1"
  local force_risk="$2"
  local dry_run="$3"
  local argocd_namespace="false"
  local application_crd="false"
  local argocd_exists="false"
  local helm_exists="false"
  local owner="unknown"
  local sync_status=""

  if ! keda_cluster_reachable; then
    if [[ "$dry_run" == "true" ]]; then
      keda_warn "dry-run 중 Kubernetes API에 연결할 수 없어 소유권 검사를 건너뜁니다."
      return 0
    fi
    keda_die "Kubernetes API에 연결할 수 없어 KEDA 소유권을 확인할 수 없습니다. kubectl context=$(keda_current_context)"
  fi

  if kubectl get namespace argocd >/dev/null 2>&1; then
    argocd_namespace="true"
  fi
  if kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
    application_crd="true"
  fi
  if keda_argocd_application_exists; then
    argocd_exists="true"
    sync_status="$(keda_argocd_sync_status)"
  fi
  if keda_helm_release_exists; then
    helm_exists="true"
  fi
  owner="$(keda_resource_tracking_owner)"

  keda_info "소유권 상태: argocd namespace=${argocd_namespace}, Application CRD=${application_crd}, KEDA Application=${argocd_exists}, sync=${sync_status:-unknown}, Helm release=${helm_exists}, resource owner=${owner}"

  if [[ "$mode" == "workflow" &&
    ("$argocd_exists" == "true" || "$owner" == "argocd") ]]; then
    if [[ "$force_risk" != "true" ]]; then
      keda_die "ArgoCD가 KEDA Application 또는 리소스를 관리 중입니다. workflow 모드는 중단합니다. 먼저 ArgoCD 소유권을 해제하거나 --force-ownership-risk를 명시하십시오."
    fi
    keda_warn "ArgoCD 관리 상태에서 workflow 모드를 강제합니다. 리소스 원복·소유권 충돌 위험이 있습니다."
  fi

  if [[ "$mode" == "gitops" &&
    ("$helm_exists" == "true" || "$owner" == "helm") ]]; then
    if [[ "$force_risk" != "true" ]]; then
      keda_die "독립 Helm release 또는 Helm 관리 리소스가 존재합니다. gitops 모드는 중단합니다. 먼저 Helm 소유권을 정리하거나 --force-ownership-risk를 명시하십시오."
    fi
    keda_warn "독립 Helm release가 있는 상태에서 gitops 모드를 강제합니다. 이중 관리 위험이 있습니다."
  fi
}

keda_ensure_chart_repo() {
  if ! helm repo list -o json 2>/dev/null |
    jq -e --arg name "$KEDA_CHART_REPO_NAME" --arg url "$KEDA_CHART_REPO_URL" \
      '.[] | select(.name == $name and .url == $url)' >/dev/null; then
    keda_info "Helm repository를 등록합니다: $KEDA_CHART_REPO_NAME"
    helm repo add "$KEDA_CHART_REPO_NAME" "$KEDA_CHART_REPO_URL" >/dev/null
  fi
}

keda_is_path_inside_repo() {
  local candidate="$1"
  local resolved
  resolved="$(realpath -m "$candidate")"
  [[ "$resolved" == "$KEDA_REPO_ROOT" || "$resolved" == "$KEDA_REPO_ROOT/"* ]]
}
