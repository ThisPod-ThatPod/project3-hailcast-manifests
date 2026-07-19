#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/keda/_lib.sh
source "$SCRIPT_DIR/_lib.sh"

REPO_URL=""
REVISION=""
VALUES_PATH=""
OUTPUT="-"
IN_PLACE="false"

usage() {
  cat <<'EOF'
Usage: configure-gitops-source.sh --repo-url <url> --revision <rev> --values-path <path> [options]

Options:
  --output <path|->   패치된 Application 출력. 기본값 stdout(-)
  --in-place          argocd/applications/keda.yaml을 직접 수정
  -h, --help          도움말
EOF
}

reject_placeholder() {
  local value="$1"
  [[ -n "$value" ]] || return 0
  [[ "$value" =~ \<.*\> ]] && return 0
  [[ "${value,,}" == *"example.com"* ]] && return 0
  [[ "${value^^}" == *"CHANGEME"* ]] && return 0
  [[ "${value^^}" == *"TODO"* ]] && return 0
  return 1
}

while (($#)); do
  case "$1" in
    --repo-url)
      [[ $# -ge 2 ]] || keda_die "--repo-url 값이 필요합니다."
      REPO_URL="$2"
      shift 2
      ;;
    --revision)
      [[ $# -ge 2 ]] || keda_die "--revision 값이 필요합니다."
      REVISION="$2"
      shift 2
      ;;
    --values-path)
      [[ $# -ge 2 ]] || keda_die "--values-path 값이 필요합니다."
      VALUES_PATH="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || keda_die "--output 값이 필요합니다."
      OUTPUT="$2"
      shift 2
      ;;
    --in-place)
      IN_PLACE="true"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      keda_die "알 수 없는 옵션: $1"
      ;;
  esac
done

for value in "$REPO_URL" "$REVISION" "$VALUES_PATH"; do
  if reject_placeholder "$value"; then
    keda_die "빈 값 또는 placeholder는 사용할 수 없습니다."
  fi
done

[[ "$VALUES_PATH" != /* && "$VALUES_PATH" != *".."* ]] ||
  keda_die "--values-path는 repository root 기준 상대경로여야 합니다."
[[ "$REPO_URL" =~ ^(https://|ssh://|git@) ]] ||
  keda_die "--repo-url은 지원되는 Git URL이어야 합니다."
[[ ! "$REPO_URL" =~ ^https://[^/]*@ ]] ||
  keda_die "--repo-url에 credential(user:token@...)을 포함할 수 없습니다."
[[ ! "$REPO_URL" =~ ^ssh://[^/]*:[^/]*@ ]] ||
  keda_die "--repo-url에 credential(user:token@...)을 포함할 수 없습니다."
[[ "$IN_PLACE" != "true" || "$OUTPUT" == "-" ]] ||
  keda_die "--in-place와 --output은 함께 사용할 수 없습니다."

keda_require_command python3
python3 -c 'import yaml' >/dev/null 2>&1 ||
  keda_die "Python PyYAML 모듈이 필요합니다."

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
PATCHED="$TEMP_DIR/keda.yaml"

python3 - "$KEDA_APPLICATION_FILE" "$PATCHED" "$REPO_URL" "$REVISION" "$VALUES_PATH" <<'PY'
import sys
import yaml

source_path, output_path, repo_url, revision, values_path = sys.argv[1:]
with open(source_path, encoding="utf-8") as stream:
    app = yaml.safe_load(stream)

if app.get("apiVersion") != "argoproj.io/v1alpha1" or app.get("kind") != "Application":
    raise SystemExit("KEDA Application 형식이 아닙니다.")

sources = app.get("spec", {}).get("sources")
if not isinstance(sources, list):
    raise SystemExit("spec.sources가 없습니다.")

chart_source = next((item for item in sources if item.get("chart") == "keda"), None)
public_source = next((item for item in sources if item.get("ref") == "values"), None)
if chart_source is None or public_source is None:
    raise SystemExit("KEDA chart source 또는 public values source를 찾을 수 없습니다.")

value_files = chart_source.setdefault("helm", {}).setdefault("valueFiles", [])
public_value = "$values/addons/keda/values.yaml"
if public_value not in value_files:
    raise SystemExit("public KEDA values 연결이 없습니다.")

value_files[:] = [item for item in value_files if not item.startswith("$privateValues/")]
public_index = value_files.index(public_value)
value_files.insert(public_index + 1, f"$privateValues/{values_path}")

sources[:] = [item for item in sources if item.get("ref") != "privateValues"]
sources.append({
    "repoURL": repo_url,
    "targetRevision": revision,
    "ref": "privateValues",
})

with open(output_path, "w", encoding="utf-8") as stream:
    yaml.safe_dump(app, stream, sort_keys=False)

with open(output_path, encoding="utf-8") as stream:
    checked = yaml.safe_load(stream)
checked_sources = checked["spec"]["sources"]
checked_chart = next(item for item in checked_sources if item.get("chart") == "keda")
expected = [
    "$values/addons/keda/values.yaml",
    f"$privateValues/{values_path}",
]
if checked_chart["helm"]["valueFiles"][:2] != expected:
    raise SystemExit("values 우선순위 검증에 실패했습니다.")
if not any(item.get("ref") == "privateValues" for item in checked_sources):
    raise SystemExit("privateValues source 검증에 실패했습니다.")
PY

if [[ "$IN_PLACE" == "true" ]]; then
  keda_warn "--in-place는 YAML 전체 formatting을 바꾸고 comments를 제거할 수 있습니다."
  keda_warn "반영 후 반드시 git diff -- argocd/applications/keda.yaml을 검토하십시오."
  cp "$PATCHED" "$KEDA_APPLICATION_FILE"
  keda_info "KEDA Application에 private values source를 반영했습니다."
  keda_info "다음 단계: git diff -- argocd/applications/keda.yaml"
elif [[ "$OUTPUT" == "-" ]]; then
  cat "$PATCHED"
else
  mkdir -p "$(dirname "$OUTPUT")"
  cp "$PATCHED" "$OUTPUT"
  keda_info "패치된 KEDA Application을 생성했습니다: $OUTPUT"
fi
