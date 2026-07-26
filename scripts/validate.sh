#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf '[ERROR] 필수 명령을 찾을 수 없습니다: %s\n' "$1" >&2
    exit 1
  }
}

require_command git
require_command jq
require_command kubectl
require_command bash
require_command find

cd "$REPO_ROOT"

printf '%s\n' '[validate] Grafana Dashboard JSON 구문 검사'
dashboard_count=0
while IFS= read -r -d '' dashboard; do
  printf '  - %s\n' "${dashboard#"$REPO_ROOT"/}"
  jq empty "$dashboard"
  dashboard_count=$((dashboard_count + 1))
done < <(find "$REPO_ROOT/addons/grafana-dashboards" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null)
printf '  통과: %d개\n' "$dashboard_count"

printf '%s\n' '[validate] kustomization 렌더링'
kustomization_count=0
while IFS= read -r -d '' kustomization; do
  kustomization_dir="$(dirname "$kustomization")"
  printf '  - %s\n' "${kustomization_dir#"$REPO_ROOT"/}"
  kubectl kustomize "$kustomization_dir" >/dev/null
  kustomization_count=$((kustomization_count + 1))
done < <(
  find "$REPO_ROOT" -type f \
    \( -name 'kustomization.yaml' -o -name 'kustomization.yml' -o -name 'Kustomization' \) \
    -print0
)
printf '  통과: %d개\n' "$kustomization_count"

printf '%s\n' '[validate] shell script 구문 검사'
script_count=0
while IFS= read -r -d '' script; do
  printf '  - %s\n' "${script#"$REPO_ROOT"/}"
  bash -n "$script"
  script_count=$((script_count + 1))
done < <(find "$REPO_ROOT/scripts" -type f -name '*.sh' -print0 2>/dev/null)
printf '  통과: %d개\n' "$script_count"

printf '%s\n' '[validate] Git whitespace 오류 검사'
git diff --check
git diff --cached --check

printf '%s\n' '[validate] 모든 정적 검증을 통과했습니다.'
