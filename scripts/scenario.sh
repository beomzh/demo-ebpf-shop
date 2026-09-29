#!/usr/bin/env bash
# 사건 시나리오 전환 스크립트 — 시나리오 3개
#
# ① 방화벽 차단 (배송 서비스 → 외부 택배사)
#   baseline   정상 상태   사내 DNS 의 택배사 레코드 → 예전 IP, 방화벽: 예전 IP 만 허용   (월요일 밤 이전)
#   incident   사건 발생   사내 DNS 의 택배사 레코드 → 새 IP,   방화벽: 예전 IP 만 허용   (월요일 밤: 택배사가 IP 변경)
#   firewall   방화벽 규칙 목록 (원인 확인 장면)
#   fix        해결        방화벽에 새 IP 허용 규칙 추가
#   reset      baseline 과 같음 (다음 촬영 준비)
#   status     사내 DNS 의 택배사 레코드·배송 파드의 DNS 응답과 연결·방화벽 규칙·배송 조회 1건
#
# ② DNS 이름 변경 → 없는 이름 조회 (결제 서비스 → 외부 PG사)
#   pg-missing   PG사가 새 도메인으로 이전 → 결제 서비스는 새 도메인으로 배포됐지만 사내 DNS 에 등록 누락
#                → 결제 서비스 예외 'getaddrinfo ENOTFOUND', 체크아웃 502
#   pg-register  해결: 사내 DNS 에 새 도메인 등록 → 앱 재시작 없이 회복
#   pg-reset     원래 도메인으로 (다음 테이크 준비)
#   pg-status    사내 DNS 서버별 조회 결과 + 체크아웃 1건
#
# ③ 주 DNS 장애 (주 DNS 파드 삭제 → 보조 DNS 로 정상 동작)
#   dns-primary-down  주 DNS 파드(ns1-corp-dns-0) 삭제 → 결제·배송 서비스는 보조 DNS(ns2) 로 조회, 서비스 정상
#   dns-primary-up    주 DNS 파드 다시 기동
#   dns-status        사내 DNS 파드·서버별 조회 결과 + 체크아웃 1건 + 배송 조회 1건
#
#   traffic    부하 발생기 로그 실시간 보기
source "$(dirname "$0")/lib.sh"
load_env

NEW_RULE="fw-allow-courier-$(dashed "$COURIER_NEW_IP")"

corpdns() { "$ROOT/scripts/corpdns.sh" "$@"; }

# dns_table <도메인> : 사내 DNS 서버별 조회 결과 (결제 파드에서)
dns_table() {
  dns_query "$1" | sed "s/^/  /; s/ \([^ ]*\) \([^ ]*ms\)$/  $1 → \1 (\2)/" || warn "payment-service exec 실패"
}

# call_gateway <요청ID> <메서드> <경로> [JSON] : 게이트웨이로 1건 요청 → HTTP 코드·소요시간, 실패하면 실패 경로
call_gateway() {
  local id="$1" method="$2" path="$3" data="${4:-}" out code_line body epath
  local args=(curl -s -m 20 -H "X-Request-Id: $id" -X "$method" -w '\n%{http_code} %{time_total}s')
  [[ -n "$data" ]] && args+=(-H 'Content-Type: application/json' -d "$data")
  out="$(kc -n "$INFRA_NS" exec deploy/loadgen -- "${args[@]}" \
    "http://gateway-service.${APP_NS}.svc.cluster.local:8080${path}" 2>&1 || true)"
  code_line="$(printf '%s\n' "$out" | tail -n 1)"
  body="$(printf '%s\n' "$out" | sed '$d')"
  echo "  HTTP ${code_line}"
  # 실패하면 서비스들이 이어 붙인 실패 경로(errorPath)를 보여준다
  epath="$(printf '%s' "$body" | sed -n 's/.*"errorPath":"\([^"]*\)".*/\1/p')"
  [[ -n "$epath" ]] && echo "  실패 경로: ${epath}"
  return 0
}
checkout() { call_gateway "$1" POST /api/checkout '{"memberId":10,"productId":3,"qty":1}'; }
tracking() { call_gateway "$1" GET /api/orders/1001/tracking; }

# ── ① 방화벽 차단 ─────────────────────────────────────────────
# 택배사 도메인은 사내 DNS 의 A 레코드 한 줄이다. 택배사가 IP 를 바꾸면 이 레코드가 바뀐다
set_courier_ip() {
  info "사내 DNS: ${COURIER_DOMAIN} → $1"
  corpdns record-add "$COURIER_DOMAIN" "$1" >/dev/null
}

allow_new_ip() {
  info "방화벽: ${COURIER_NEW_IP}:443 허용 규칙 추가 (${NEW_RULE})"
  kc apply -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${NEW_RULE}
  namespace: ${APP_NS}
  labels:
    demo.observ/firewall: egress
  annotations:
    demo.observ/description: "택배사 API (${COURIER_DOMAIN}) ${COURIER_NEW_IP}:443 허용"
spec:
  podSelector:
    matchLabels: { app: delivery-service }
  policyTypes: [Egress]
  egress:
    - to:
        - ipBlock: { cidr: ${COURIER_NEW_IP}/32 }
      ports:
        - { protocol: TCP, port: 443 }
YAML
}

remove_new_ip() {
  kc -n "$APP_NS" delete netpol "$NEW_RULE" --ignore-not-found >/dev/null
  info "방화벽: ${COURIER_NEW_IP} 허용 규칙 제거"
}

show_firewall() {
  kc -n "$APP_NS" get netpol -l "$FW_LABEL" \
    -o custom-columns='RULE:.metadata.name,DESCRIPTION:.metadata.annotations.demo\.observ/description'
}

status() {
  info "사내 DNS 의 택배사 레코드 (서버별 조회)"
  dns_table "$COURIER_DOMAIN"

  info "배송 서비스 파드에서 본 DNS 응답과 443 연결 (3초 제한)"
  kc -n "$APP_NS" exec deploy/delivery-service -- python -c "
import socket
host='${COURIER_DOMAIN}'
try:
    ip=socket.gethostbyname(host)
except OSError as e:
    print(f'  DNS  {host} 조회 실패 ({e})'); raise SystemExit(0)
print(f'  DNS  {host} -> {ip}')
try:
    socket.create_connection((ip,443),3).close(); print(f'  TCP  {ip}:443 연결 성공')
except OSError as e:
    print(f'  TCP  {ip}:443 연결 실패 ({e})')
" || warn "delivery-service exec 실패"

  info "방화벽 규칙"
  show_firewall

  info "게이트웨이 → 주문 → 배송을 거친 배송 조회 1건"
  tracking status-check
}

# ── ② DNS 이름 변경 ──────────────────────────────────────────
set_pg_domain() {
  info "결제 서비스 PG_DOMAIN=$1 (재시작)"
  kc -n "$APP_NS" set env deploy/payment-service "PG_DOMAIN=$1" >/dev/null
  kc -n "$APP_NS" rollout status deploy/payment-service --timeout=180s >/dev/null
}

current_pg_domain() {
  kc -n "$APP_NS" get deploy payment-service \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="PG_DOMAIN")].value}' 2>/dev/null
}

pg_status() {
  local host; host="$(current_pg_domain)"; host="${host:-$PG_DOMAIN}"   # pg-missing 뒤에는 새 도메인
  info "사내 DNS 서버별 ${host} 조회 (결제 서비스가 쓰는 도메인)"
  dns_table "$host"
  info "게이트웨이 → 주문 → 결제 → PG 를 거친 체크아웃 1건"
  checkout pg-status-check
}

# ── ③ 주 DNS 장애 ────────────────────────────────────────────
dns_status() {
  info "사내 DNS 파드"
  kc -n "$INFRA_NS" get pods -l app=corp-dns -o custom-columns='POD:.metadata.name,ROLE:.metadata.labels.dns-role,STATUS:.status.phase' 2>/dev/null
  [[ "$(kc -n "$INFRA_NS" get statefulset "$CORP_DNS_PRIMARY_NAME" -o jsonpath='{.spec.replicas}' 2>/dev/null)" == 0 ]] \
    && warn "주 DNS 파드 없음 (dns-primary-down 상태)"
  info "사내 DNS 서버별 조회"
  dns_table "$PG_DOMAIN"
  dns_table "$COURIER_DOMAIN"
  info "체크아웃 1건 (결제 → PG 도메인 조회)"
  checkout dns-status-checkout
  info "배송 조회 1건 (배송 → 택배사 도메인 조회)"
  tracking dns-status-tracking
}

case "${1:-}" in
  baseline|reset)
    remove_new_ip
    set_courier_ip "$COURIER_OLD_IP"
    ok "정상 상태: 사내 DNS 택배사 레코드 → ${COURIER_OLD_IP}, 방화벽 → ${COURIER_OLD_IP} 허용"
    ;;
  incident)
    remove_new_ip
    set_courier_ip "$COURIER_NEW_IP"
    ok "사건 발생: 택배사가 IP 를 ${COURIER_NEW_IP} 로 변경. 방화벽에는 ${COURIER_OLD_IP} 만 허용된 상태"
    ;;
  fix)
    allow_new_ip
    ok "해결: 방화벽에 ${COURIER_NEW_IP}:443 허용 추가"
    ;;
  status)   status ;;
  firewall) show_firewall ;;

  pg-missing)
    # PG사가 새 도메인으로 이전 → 앱은 새 도메인으로 배포됐지만 사내 DNS 에 등록이 누락된 상황
    corpdns record-remove "$PG_UNREGISTERED_DOMAIN" >/dev/null
    set_pg_domain "$PG_UNREGISTERED_DOMAIN"
    ok "사내 DNS 에 ${PG_UNREGISTERED_DOMAIN} 없음 — 체크아웃이 실패합니다 (결제 서비스 예외: getaddrinfo ENOTFOUND ${PG_UNREGISTERED_DOMAIN})"
    ok "해결 장면: './demo.sh pg-register' (사내 DNS 에 등록)"
    ;;
  pg-register)
    [[ "$(current_pg_domain)" == "$PG_UNREGISTERED_DOMAIN" ]] || warn "앱이 아직 ${PG_UNREGISTERED_DOMAIN} 를 쓰고 있지 않습니다 — 먼저 './demo.sh pg-missing'"
    corpdns record-add "$PG_UNREGISTERED_DOMAIN" "$PG_IP"
    ok "앱 재시작 없이 다음 요청부터 회복됩니다"
    pg_status
    ;;
  pg-reset)
    [[ "$(current_pg_domain)" == "$PG_DOMAIN" ]] || set_pg_domain "$PG_DOMAIN"
    corpdns record-remove "$PG_UNREGISTERED_DOMAIN" >/dev/null
    ok "PG 시나리오 복구 (앱 PG 도메인: ${PG_DOMAIN}, ${PG_UNREGISTERED_DOMAIN} 레코드 삭제)"
    ;;
  pg-status) pg_status ;;

  dns-primary-down)
    corpdns primary-down
    ok "주 DNS 장애 — 결제·배송 서비스는 보조 DNS 로 조회해 정상 동작합니다 ('./demo.sh dns-status' 로 확인)"
    ;;
  dns-primary-up) corpdns primary-up ;;
  dns-status) dns_status ;;

  traffic)  kc -n "$INFRA_NS" logs -f deploy/loadgen --tail=20 ;;
  *)
    sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
