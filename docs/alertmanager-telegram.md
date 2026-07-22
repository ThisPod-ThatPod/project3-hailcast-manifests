# Alertmanager Telegram 운영 절차

## 1. 현재 구성과 전달 범위

기존 `kube-prometheus-stack`의 Alertmanager와 Telegram receiver는
`addons/kube-prometheus-stack/values.yaml`에 구성되어 있다. 새 Helm Release나 별도
Alertmanager를 만들지 않는다.

Alertmanager의 기본 receiver는 `null`이다. 다음 조건을 모두 만족하는 Hailcast
Platform Alert만 Telegram으로 전달한다.

- `component="platform"`
- `severity=~"warning|critical"`

`Watchdog`, `InfoInhibitor`는 명시적으로 `null` receiver에 전달하며 Telegram에서
제외한다. 그 밖의 알림도 Telegram route와 일치하지 않으므로 기본 `null` receiver로
처리한다. Telegram receiver는 firing과 resolved 알림을 모두 전송한다.

Telegram 메시지는 상태를 `FIRING`/`RESOLVED`로 구분하고 severity와 Kubernetes 대상,
summary만 표시한다. 한 메시지에는 최대 4개 Alert만 표시하며, 나머지는 전체 건수와 함께
생략해 Telegram 메시지 길이 제한을 넘지 않도록 한다. 전체 labels와 source URL은
출력하지 않는다.

## 2. Secret 계약과 보안 원칙

Telegram 자격증명은 values나 Kubernetes manifest에 직접 기록하지 않는다. 실제 Bot
Token, chat ID, Base64 값은 Git, 문서, 로그, artifact에 저장하지 않는다.

Alertmanager가 참조하는 Existing Kubernetes Secret 계약은 다음과 같다.

| 항목 | 값 |
| --- | --- |
| Namespace | `monitoring` |
| Secret 이름 | `alertmanager-telegram` |
| Bot token key | `bot-token` |
| Chat ID key | `chat-id` |
| Mount path | `/etc/alertmanager/secrets/alertmanager-telegram/` |

`alertmanager.alertmanagerSpec.secrets`가 Secret을 마운트하고, Telegram receiver의
`bot_token_file`과 `chat_id_file`이 마운트된 파일을 읽는다.
`alertmanagerSpec.useExistingSecret`은 사용하지 않는다.

## 3. 배포 전 선행 조건

`alertmanager-telegram` Secret은 Alertmanager 배포보다 먼저 `monitoring` namespace에
존재해야 한다. Secret이 없으면 Alertmanager Pod가 Secret volume을 마운트하지 못해
정상적으로 Ready 상태가 되지 않을 수 있다.

Secret 생성 및 갱신은 승인된 클러스터와 별도의 보안 절차에서 수행한다. 이 저장소에는
Secret YAML이나 실값을 추가하지 않는다. 배포 전에는 값 자체를 출력하지 않고 Secret과
필수 key의 존재만 확인한다.

```bash
kubectl config current-context
kubectl get namespace monitoring
kubectl -n monitoring get secret alertmanager-telegram \
  -o go-template='{{if and (index .data "bot-token") (index .data "chat-id")}}required keys present{{else}}required key missing{{end}}{{"\n"}}'
```

출력이 `required keys present`인지 확인한 후 Alertmanager를 배포하거나 동기화한다.

## 4. 배포 및 설정 확인

Argo CD Application과 Alertmanager 상태를 확인한다.

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

## 5. Firing 및 resolved 테스트

아래 테스트 Alert는 실제 Telegram route와 동일하게 `component="platform"` 및
`severity="warning"` label을 사용한다. 테스트는 승인된 클러스터와 Telegram 채널에서만
수행한다.

```bash
curl --fail --silent --show-error \
  -H 'Content-Type: application/json' \
  -d '[{"labels":{"alertname":"HailcastTelegramIntegrationTest","namespace":"hailcast","component":"platform","severity":"warning"},"annotations":{"summary":"Hailcast Telegram integration firing test"}}]' \
  http://127.0.0.1:9093/api/v2/alerts
```

현재 `group_wait`인 30초 이후 firing 메시지를 확인한다. 같은 label 집합에 종료 시각을
지정해 resolved 상태를 전송한다.

```bash
ENDS_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
curl --fail --silent --show-error \
  -H 'Content-Type: application/json' \
  -d "[{\"labels\":{\"alertname\":\"HailcastTelegramIntegrationTest\",\"namespace\":\"hailcast\",\"component\":\"platform\",\"severity\":\"warning\"},\"endsAt\":\"$ENDS_AT\"}]" \
  http://127.0.0.1:9093/api/v2/alerts
unset ENDS_AT
```

`send_resolved: true` 설정에 따라 resolved 메시지가 도착하는지 확인한다. resolved 알림은
현재 `group_interval`의 영향을 받을 수 있다.

라우팅 제외도 확인하려면 `component`가 없거나 다른 값을 가진 테스트 Alert를 전송하고
Telegram 메시지가 생성되지 않는지 확인한다. `Watchdog`와 `InfoInhibitor`는 별도
`null` route가 있으므로 Telegram으로 전달되지 않아야 한다.

## 6. Secret 누락 문제 해결

Alertmanager Pod가 Pending 또는 NotReady이면 Secret을 먼저 확인한다.

```bash
kubectl -n monitoring get secret alertmanager-telegram
kubectl -n monitoring describe alertmanager kube-prometheus-stack-alertmanager
kubectl -n monitoring describe pods \
  -l alertmanager=kube-prometheus-stack-alertmanager
kubectl -n monitoring get events \
  --field-selector involvedObject.namespace=monitoring \
  --sort-by='.lastTimestamp'
```

다음을 점검한다.

- Secret이 `monitoring` namespace에 있는가
- Secret 이름이 `alertmanager-telegram`인가
- `bot-token`, `chat-id` key가 모두 있는가
- Alertmanager CR의 `spec.secrets`에 `alertmanager-telegram`이 있는가
- Pod event에 `FailedMount` 또는 Secret not found가 기록되어 있는가

자격증명 값을 확인하기 위해 Secret 내용을 출력하거나 decode하지 않는다.

## 7. Token 회전 후 재검증

Token은 승인된 보안 절차를 통해 동일한 `alertmanager-telegram` Secret의 `bot-token`
key에서 회전한다. Git의 values, 문서 또는 manifest에는 값을 기록하지 않는다.

회전 후 다음 순서로 재검증한다.

1. Secret과 필수 key의 존재를 값 출력 없이 확인한다.
2. Alertmanager Pod에서 Secret volume 갱신과 Ready 상태를 확인한다.
3. 운영 정책상 필요하면 Alertmanager StatefulSet을 재시작해 새 credential 파일을 확실히
   다시 읽게 한다.
4. Alertmanager ready 상태를 확인한다.
5. Platform warning 테스트 Alert로 firing과 resolved 전달을 다시 확인한다.
6. Alertmanager 로그에서 Telegram 인증 또는 전송 오류가 없는지 확인한다.

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

## 8. 현재 검증 범위

현재 저장소에서는 YAML 문법, Helm Chart 렌더링, Alertmanager routing 및 Secret 파일 경로만 검증한다.

실제 Secret 생성, EKS 배포, Telegram API 호출, firing/resolved 메시지 수신, Token 회전은 아직 실클러스터에서 수행하지 않은 운영 검증 단계다.