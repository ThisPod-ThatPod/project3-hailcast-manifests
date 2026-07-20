#!/usr/bin/env bash

KEDA_RELEASE="keda"
KEDA_NAMESPACE="keda"
KEDA_APPLICATION="keda"

keda_info() {
  printf '[INFO] %s\n' "$*"
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
