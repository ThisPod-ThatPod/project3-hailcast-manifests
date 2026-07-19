#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/keda/_lib.sh
source "$SCRIPT_DIR/_lib.sh"

OUTPUT=""
ROLE_ARN="${KEDA_ROLE_ARN:-}"

usage() {
  cat <<'EOF'
Usage: render-private-values.sh --output <path> [options]

Options:
  --output <path>         출력 파일. 필수 (stdout 미지원)
  --role-arn <arn>        IRSA Role ARN. 환경변수 KEDA_ROLE_ARN 사용을 권장
  -h, --help              도움말
EOF
}

while (($#)); do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || keda_die "--output 값이 필요합니다."
      OUTPUT="$2"
      shift 2
      ;;
    --role-arn)
      [[ $# -ge 2 ]] || keda_die "--role-arn 값이 필요합니다."
      ROLE_ARN="$2"
      shift 2
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

[[ -n "$OUTPUT" ]] ||
  keda_die "--output <path>는 필수입니다."
[[ "$OUTPUT" != "-" ]] ||
  keda_die "stdout 출력은 지원하지 않습니다. --output으로 repository 외부 파일을 지정하십시오."
case "$OUTPUT" in
  /dev/* | /proc/*/fd/*)
    keda_die "device 또는 file descriptor 경로에는 출력할 수 없습니다."
    ;;
esac
if [[ -L "$OUTPUT" || (-e "$OUTPUT" && ! -f "$OUTPUT") ]]; then
  keda_die "--output은 일반 파일 경로여야 합니다."
fi
keda_valid_role_arn "$ROLE_ARN" ||
  keda_die "KEDA Role ARN 형식이 잘못되었거나 role 이름에 keda가 없습니다."

render_yaml() {
  printf '%s\n' \
    'serviceAccount:' \
    '  operator:' \
    '    annotations:' \
    "      eks.amazonaws.com/role-arn: ${ROLE_ARN}"
}

if keda_is_path_inside_repo "$OUTPUT"; then
  keda_die "public 저장소 내부에는 실제 ARN을 출력할 수 없습니다. repository 외부 경로를 지정하십시오."
fi

mkdir -p "$(dirname "$OUTPUT")"
umask 077
install -m 600 /dev/null "$OUTPUT"
render_yaml >"$OUTPUT"
chmod 600 "$OUTPUT"
keda_info "private values를 생성했습니다: $OUTPUT (mode 0600, ARN=$(keda_mask_role_arn "$ROLE_ARN"))"
