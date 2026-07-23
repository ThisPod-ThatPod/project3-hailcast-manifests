# Alertmanager Discord 운영 절차

## 1. 현재 구성과 전달 범위

`addons/kube-prometheus-stack/values.yaml`의 Alertmanager는 `telegram-discord`라는
단일 receiver로 Telegram과 Discord에 동시에 전달한다. 새 Helm Release나 별도
Alertmanager를 만들지 않는다.

라우팅 조건(어떤 Alert가 전달되는가)은 `docs/alertmanager-telegram.md` 1절과 완전히
동일하다. `telegram-discord` receiver로 가는 route가 Telegram과 Discord 양쪽에
동시에 적용되기 때문에, 라우팅 규칙을 바꿀 때는 두 채널 모두에 영향을 준다는 점을
염두에 둔다.

Discord 메시지는 embed 형태로 전송되며, title에 상태(FIRING/RESOLVED)와 alertname을,
message(embed description)에 Telegram과 동일한 내용(상태, severity, Kubernetes 대상,
summary)을 Discord 마크다운(`**bold**`)으로 표시한다. 최대 4개 Alert만 표시하고
나머지는 전체 건수와 함께 생략한다. Telegram과 달리 HTML 이스케이프는 사용하지 않는다
(Discord는 마크다운을 쓰며 HTML 엔티티를 그대로 표시하면 오히려 깨져 보인다).

## 2. Secret 계약과 보안 원칙

Discord Webhook URL은 values나 Kubernetes manifest에 직접 기록하지 않는다. 실제 URL
값은 Git, 문서, 로그, artifact에 저장하지 않는다. Webhook URL 자체가 인증 정보이므로
Bot Token과 동일한 수준으로 취급한다.

Alertmanager가 참조하는 Existing Kubernetes Secret 계약은 다음과 같다.

| 항목 | 값 |
| --- | --- |
| Namespace | `monitoring` |
| Secret 이름 | `alertmanager-discord` |
| Webhook URL key | `webhook-url` |
| Mount path | `/etc/alertmanager/secrets/alertmanager-discord/` |

`alertmanager.alertmanagerSpec.secrets`가 Secret을 마운트하고, Discord receiver의
`webhook_url_file`이 마운트된 파일을 읽는다. `alertmanagerSpec.useExistingSecret`은
사용하지 않는다.

## 3. Discord 쪽 사전 준비 (팀 디스코드 서버)

1. 알림을 받을 채널에서 채널 설정 → 연동(Integrations) → 웹후크(Webhooks) → 새 웹후크
   생성
2. 웹후크 이름을 `hailcast-alertmanager` 등으로 지정(선택)
3. **웹후크 URL 복사** — 이 값이 Secret에 들어갈 값이다. URL을 팀 채팅방이나 문서에
   붙여넣지 않는다

## 4. 배포 전 선행 조건

`alertmanager-discord` Secret은 Alertmanager 배포보다 먼저 `monitoring` namespace에
존재해야 한다. Secret이 없으면 Alertmanager Pod가 Secret volume을 마운트하지 못해
정상적으로 Ready 상태가 되지 않을 수 있다(Telegram Secret이 이미 있어도 마찬가지다 —
`alertmanagerSpec.secrets` 목록에 있는 Secret이 하나라도 없으면 전체 Pod가 영향을 받는다).

Secret 생성 및 갱신은 승인된 클러스터와 별도의 보안 절차에서 수행한다. 이 저장소에는
Secret YAML이나 실값을 추가하지 않는다.

```bash
kubectl config current-context
kubectl get namespace monitoring
kubectl -n monitoring create secret generic alertmanager-discord \
  --from-literal=webhook-url='<Discord Webhook URL>'
```

생성 후 값 자체를 출력하지 않고 필수 key의 존재만 확인한다.

```bash
kubectl -n monitoring get secret alertmanager-discord \
  -o go-template='{{if index .data "webhook-url"}}required key present{{else}}required key missing{{end}}{{"\n"}}'
```

출력이 `required key present`인지 확인한 후 Alertmanager를 배포하거나 동기화한다.

## 5. 배포 및 설정 확인

Argo CD Application과 Alertmanager 상태를 확인한다. Telegram과 동일한 `kube-prometheus-stack`
Application 하나로 관리되므로 절차가 같다.

```bash
kubectl -n argocd get application kube-prometheus-stack \
  -o jsonpath='sync={.status.sync.status} health={.status.health.status}{"\n"}'
kubectl -n monitoring get alertmanager kube-prometheus-stack-alertmanager
kubectl -n monitoring get pods \
  -l alertmanager=kube-prometheus-stack-alertmanager
```

승인된 환경에서 Alertmanager API를 확인해야 할 때는 로컬로 port-forward한다.

```bash
kubectl -n monitoring port-forward \
  service/kube-prometheus-stack-alertmanager 9093:9093
```

별도 터미널에서 Alertmanager 준비 상태와 로드된 설정 정보를 확인한다.

```bash
curl --fail --silent --show-error http://127.0.0.1:9093/-/ready
curl --fail --silent --show-error http://127.0.0.1:9093/api/v2/status
```

## 6. Firing 및 resolved 테스트

아래 테스트 Alert는 실제 route와 동일하게 `component="platform"` 및
`severity="warning"` label을 사용한다. `telegram-discord` receiver를 공유하므로
이 테스트는 Telegram과 Discord 양쪽에 동시에 도착해야 정상이다. 테스트는 승인된
클러스터와 채널에서만 수행한다.

```bash
curl --fail --silent --show-error \
  -H 'Content-Type: application/json' \
  -d '[{"labels":{"alertname":"HailcastDiscordIntegrationTest","namespace":"hailcast","component":"platform","severity":"warning"},"annotations":{"summary":"Hailcast Discord integration firing test"}}]' \
  http://127.0.0.1:9093/api/v2/alerts
```

현재 `group_wait`인 30초 이후 firing 메시지를 확인한다. 같은 label 집합에 종료 시각을
지정해 resolved 상태를 전송한다.

```bash
ENDS_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
curl --fail --silent --show-error \
  -H 'Content-Type: application/json' \
  -d "[{\"labels\":{\"alertname\":\"HailcastDiscordIntegrationTest\",\"namespace\":\"hailcast\",\"component\":\"platform\",\"severity\":\"warning\"},\"endsAt\":\"$ENDS_AT\"}]" \
  http://127.0.0.1:9093/api/v2/alerts
unset ENDS_AT
```

`send_resolved: true` 설정에 따라 resolved 메시지가 도착하는지 확인한다. resolved 알림은
현재 `group_interval`의 영향을 받을 수 있다.

## 7. Secret 누락 문제 해결

Alertmanager Pod가 Pending 또는 NotReady이면 두 Secret(`alertmanager-telegram`,
`alertmanager-discord`)을 모두 확인한다. 하나만 없어도 Pod 전체가 영향을 받는다.

```bash
kubectl -n monitoring get secret alertmanager-telegram alertmanager-discord
kubectl -n monitoring describe alertmanager kube-prometheus-stack-alertmanager
kubectl -n monitoring describe pods \
  -l alertmanager=kube-prometheus-stack-alertmanager
kubectl -n monitoring get events \
  --field-selector involvedObject.namespace=monitoring \
  --sort-by='.lastTimestamp'
```

다음을 점검한다.

- Secret이 `monitoring` namespace에 있는가
- Secret 이름이 `alertmanager-discord`인가
- `webhook-url` key가 있는가
- Alertmanager CR의 `spec.secrets`에 `alertmanager-discord`가 있는가
- Pod event에 `FailedMount` 또는 Secret not found가 기록되어 있는가
- Discord 쪽에서 웹후크가 삭제되지 않았는가(채널 설정에서 재확인)

자격증명 값을 확인하기 위해 Secret 내용을 출력하거나 decode하지 않는다.

## 8. Webhook 재발급 후 재검증

Discord에서 웹후크를 재발급한 경우 승인된 보안 절차를 통해 동일한 `alertmanager-discord`
Secret의 `webhook-url` key를 갱신한다. Git, 문서 또는 manifest에는 값을 기록하지 않는다.

재발급 후 다음 순서로 재검증한다.

1. Secret과 필수 key의 존재를 값 출력 없이 확인한다.
2. Alertmanager Pod에서 Secret volume 갱신과 Ready 상태를 확인한다.
3. 운영 정책상 필요하면 Alertmanager StatefulSet을 재시작해 새 URL 파일을 확실히
   다시 읽게 한다.
4. Alertmanager ready 상태를 확인한다.
5. Platform warning 테스트 Alert로 firing과 resolved 전달을 다시 확인한다(Telegram·
   Discord 양쪽).
6. Alertmanager 로그에서 Discord 전송 오류가 없는지 확인한다.

```bash
kubectl -n monitoring rollout status \
  statefulset/alertmanager-kube-prometheus-stack-alertmanager
kubectl -n monitoring logs \
  -l alertmanager=kube-prometheus-stack-alertmanager \
  -c alertmanager --since=10m --prefix
```

StatefulSet 재시작이 필요한 경우 승인된 점검 시간에 다음 명령을 수행한 뒤 rollout 완료를
확인한다.

```bash
kubectl -n monitoring rollout restart \
  statefulset/alertmanager-kube-prometheus-stack-alertmanager
kubectl -n monitoring rollout status \
  statefulset/alertmanager-kube-prometheus-stack-alertmanager
```

## 9. 현재 검증 범위

현재 저장소에서는 YAML 문법과 Alertmanager routing·Secret 파일 경로만 검증한다.

실제 Secret 생성, EKS 배포, Discord Webhook 호출, firing/resolved 메시지 수신, Webhook
재발급은 아직 실클러스터에서 수행하지 않은 운영 검증 단계다.