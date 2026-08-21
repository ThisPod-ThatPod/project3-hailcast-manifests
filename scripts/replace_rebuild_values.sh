#!/bin/bash
# =============================================================
# 파일위치 : project3-hailcast-manifests/scripts/replace_rebuild_values.sh
# 소유      : 그룹 C (용빈)
# 역할      : destroy→apply 재구축 후 바뀐 값 6종을 매니페스트에 일괄 치환한다.
#            재구축_체크리스트.md 8-1(배포팀이 고쳐야 하는 줄)의 자동화판.
# 배경      : 8/18 재구축에서 손으로 5종을 고쳤고 python 치환 1회로 1분 이내였다.
#            8/25 촬영은 값 교체 시간이 곧 촬영 분량이라 당일 즉흥 대응을 없앤다(D-4 (a) 조건).
# 사용      : 아래 "새 값" 6개만 채우고 실행. git 커밋은 하지 않는다(사람이 확인 후 커밋).
#            ./scripts/replace_rebuild_values.sh
# 안전장치  : 값 형식 검증 → 대상 건수 검증 → 치환 → 잔존 확인. 하나라도 어긋나면 즉시 중단.
# =============================================================
set -euo pipefail

# ─────────────────────────────────────────────
# 여기만 채운다 (apply 출력 / AWS CLI 조회 결과)
# ─────────────────────────────────────────────
NEW_CERT_UUID=""      # ACM 인증서 UUID  예: ac119b3a-0135-4ce2-b6d3-024f9d2acda2
NEW_SG_ID=""          # ALB용 CloudFront 전용 SG  예: sg-02050c3eb49f83935
NEW_MODEL_SUFFIX=""   # 모델 아티팩트 버킷 접미사  예: 58b4f8fd
NEW_VPC_ID=""         # VPC ID  예: vpc-03fe7938497b3ed0c
NEW_RDS_SECRET=""     # RDS 마스터 시크릿 접미사  예: 1530d81c-e164-48df-83d2-06f4d952552e-sVe4XH
NEW_CUR_SUFFIX=""     # CUR 버킷 접미사  예: 15c95bad   (opencost Athena 연동용)

# ─────────────────────────────────────────────
# 조회 명령 (값을 모를 때 참고)
# ─────────────────────────────────────────────
#   인증서   aws acm list-certificates --region ap-northeast-2 \
#              --query "CertificateSummaryList[?DomainName=='hailcast.myminiinfra.store'].CertificateArn" --output text
#   SG       aws ec2 describe-security-groups --region ap-northeast-2 \
#              --filters Name=group-name,Values=hailcast-dev-sg-alb-cloudfront --query 'SecurityGroups[0].GroupId' --output text
#   VPC      aws ec2 describe-vpcs --region ap-northeast-2 \
#              --filters Name=tag:Name,Values=hailcast-dev-vpc --query 'Vpcs[0].VpcId' --output text
#   RDS      aws rds describe-db-instances --region ap-northeast-2 \
#              --db-instance-identifier hailcast-dev-rds-postgres \
#              --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text
#   버킷     aws s3 ls | grep hailcast-dev-model-artifacts
#            aws s3 ls | grep hailcast-dev-cur

info() { printf '[replace] %s\n' "$*"; }
err()  { printf '[replace][ERROR] %s\n' "$*" >&2; }

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# ── 1. 빈 값 검사 ──
MISSING=0
for V in NEW_CERT_UUID NEW_SG_ID NEW_MODEL_SUFFIX NEW_VPC_ID NEW_RDS_SECRET NEW_CUR_SUFFIX; do
  if [[ -z "${!V}" ]]; then err "$V 가 비어 있습니다"; MISSING=1; fi
done
[[ $MISSING -eq 0 ]] || { err "위 값을 채우고 다시 실행하세요."; exit 1; }

# ── 2. 형식 검사 (오타를 여기서 잡는다) ──
[[ "$NEW_CERT_UUID"    =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
  || { err "NEW_CERT_UUID 형식이 UUID가 아닙니다: $NEW_CERT_UUID"; exit 1; }
[[ "$NEW_SG_ID"        =~ ^sg-[0-9a-f]{17}$ ]] \
  || { err "NEW_SG_ID 형식 오류(sg- + 17자리): $NEW_SG_ID"; exit 1; }
[[ "$NEW_VPC_ID"       =~ ^vpc-[0-9a-f]{17}$ ]] \
  || { err "NEW_VPC_ID 형식 오류(vpc- + 17자리): $NEW_VPC_ID"; exit 1; }
[[ "$NEW_MODEL_SUFFIX" =~ ^[0-9a-f]{8}$ ]] \
  || { err "NEW_MODEL_SUFFIX 형식 오류(hex 8자리): $NEW_MODEL_SUFFIX"; exit 1; }
[[ "$NEW_CUR_SUFFIX"   =~ ^[0-9a-f]{8}$ ]] \
  || { err "NEW_CUR_SUFFIX 형식 오류(hex 8자리): $NEW_CUR_SUFFIX"; exit 1; }
[[ "$NEW_RDS_SECRET"   =~ ^[0-9a-f-]{36}-[A-Za-z0-9]{6}$ ]] \
  || { err "NEW_RDS_SECRET 형식 오류(UUID-6자리): $NEW_RDS_SECRET"; exit 1; }

info "값 형식 검증 통과"

# ── 3. 치환 (기대 건수와 다르면 중단) ──
python3 - "$NEW_CERT_UUID" "$NEW_SG_ID" "$NEW_MODEL_SUFFIX" "$NEW_VPC_ID" "$NEW_RDS_SECRET" "$NEW_CUR_SUFFIX" <<'PYEOF'
import io, re, sys

cert, sg, model, vpc, rds, cur = sys.argv[1:7]

# (파일, 옛값 정규식, 새값, 기대 건수)
JOBS = [
    ("apps/predict/ingress.yaml",   r"certificate/[0-9a-f-]{36}",        f"certificate/{cert}", 1),
    ("apps/call-api/ingress.yaml",  r"certificate/[0-9a-f-]{36}",        f"certificate/{cert}", 1),
    ("apps/frontend/ingress.yaml",  r"certificate/[0-9a-f-]{36}",        f"certificate/{cert}", 1),
    ("apps/predict/ingress.yaml",   r"sg-[0-9a-f]{17}",                  sg, 1),
    ("apps/call-api/ingress.yaml",  r"sg-[0-9a-f]{17}",                  sg, 1),
    ("apps/frontend/ingress.yaml",  r"sg-[0-9a-f]{17}",                  sg, 1),
    ("apps/predict/deployment.yaml",     r"model-artifacts-[0-9a-f]{8}", f"model-artifacts-{model}", 1),
    ("apps/call-api/deployment.yaml",    r"model-artifacts-[0-9a-f]{8}", f"model-artifacts-{model}", 1),
    ("apps/simulator/deployment.yaml",   r"model-artifacts-[0-9a-f]{8}", f"model-artifacts-{model}", 1),
    ("apps/weather-cron/deployment.yaml",r"model-artifacts-[0-9a-f]{8}", f"model-artifacts-{model}", 1),
    ("addons/aws-load-balancer-controller/values.yaml", r"vpc-[0-9a-f]{17}", vpc, 1),
    ("platform/external-secrets/externalsecret-rds-credentials.yaml",
     r"rds!db-[0-9a-f-]{36}-[A-Za-z0-9]{6}", f"rds!db-{rds}", 2),
    # opencost Athena 연동(PR#82). 머지 전이면 0건이라 건너뛴다.
    ("addons/opencost/values.yaml", r"hailcast-dev-cur-[0-9a-f]{8}", f"hailcast-dev-cur-{cur}", None),
]

total = 0
for path, pat, new, expect in JOBS:
    try:
        s = io.open(path, encoding="utf-8").read()
    except FileNotFoundError:
        print(f"  SKIP {path} (파일 없음)")
        continue
    n = len(re.findall(pat, s))
    if expect is None:
        if n == 0:
            print(f"  SKIP {path} (대상 0건 — PR#82 미머지로 보임)")
            continue
    elif n != expect:
        sys.exit(f"[ERROR] {path}: {pat} 를 {n}건 찾음(기대 {expect}) — 중단")
    io.open(path, "w", encoding="utf-8").write(re.sub(pat, new, s))
    print(f"  OK   {path}  ({n}건)")
    total += n
print(f"\n총 {total}건 치환")
PYEOF

# ── 4. 잔존 확인 ──
info "치환 후 남은 값 확인"
LEFT=$(grep -rEn "certificate/[0-9a-f-]{36}|sg-[0-9a-f]{17}|model-artifacts-[0-9a-f]{8}|vpc-[0-9a-f]{17}|rds!db-[0-9a-f-]{36}|hailcast-dev-cur-[0-9a-f]{8}" \
         --include='*.yaml' . 2>/dev/null \
       | grep -v "$NEW_CERT_UUID" | grep -v "$NEW_SG_ID" | grep -v "$NEW_MODEL_SUFFIX" \
       | grep -v "$NEW_VPC_ID" | grep -v "$NEW_RDS_SECRET" | grep -v "$NEW_CUR_SUFFIX" || true)
if [[ -n "$LEFT" ]]; then
  err "옛 값이 남아 있습니다:"
  printf '%s\n' "$LEFT" >&2
  exit 1
fi
info "옛 값 잔존 0건"

# ── 5. YAML 문법 ──
python3 -c "
import glob, yaml, sys
bad=[]
for f in sorted(glob.glob('**/*.yaml', recursive=True)):
    try: list(yaml.safe_load_all(open(f)))
    except Exception as e: bad.append(f)
if bad: sys.exit('[ERROR] YAML 파싱 실패: ' + ', '.join(bad))
print('[replace] YAML 문법 통과')
"

info "완료. git diff 로 확인 후 커밋하세요."
info "  git diff --stat"
