#!/usr/bin/env bash
# 사건 시나리오 전환 스크립트 — 시나리오 2개
#
# ① 주 DNS 장애 → 보조 DNS 가 방화벽에 막힘 (배송·결제 → 외부 택배사·PG)
#   결제·배송 파드 → DNS 포워더(dns-forwarder) → 사내 주 DNS(ns1) → 실패하면 보조 DNS(ns2)
#   baseline   정상 상태   주·보조 DNS·포워더 기동, 방화벽: 포워더 → 주 DNS 만 허용 (보조 DNS 는 등록 누락)
#   incident   사건 발생   주 DNS 파드(ns1-corp-dns-0) 삭제(replica=0) → 포워더가 보조 DNS 로 넘어가지만 방화벽에 막혀 타임아웃
#                          → 택배사·PG 도메인 조회 실패: 배송 조회·체크아웃 모두 실패
#                          포워더 로그: read udp <포워더>-><주 DNS IP>:53: i/o timeout → ...-><보조 DNS IP>:53: i/o timeout
#   firewall   방화벽 규칙 목록 (원인 확인 장면: 주 DNS 만 있고 보조 DNS 가 없음)
#   fix        해결        방화벽에 포워더 → 보조 DNS 허용 규칙 추가 → 주 DNS 가 죽은 채로 회복
#   reset      baseline 과 같음 (다음 촬영 준비: 보조 DNS 규칙 삭제, 주 DNS 다시 기동)
#   status     DNS 파드·포워더 최근 오류(어느 IP 로 질의했다 실패했는지)·방화벽 규칙·배송 조회·체크아웃 1건씩
#
# ② DNS 이름 변경 → 없는 이름 조회 (결제 서비스 → 외부 PG사)
#   pg-missing   PG사가 새 도메인으로 이전 → 결제 서비스는 새 도메인으로 배포됐지만 사내 DNS 에 등록 누락
#                → 결제 서비스 예외 'getaddrinfo ENOTFOUND', 체크아웃 502
#   pg-register  해결: 사내 DNS 에 새 도메인 등록 → 앱 재시작 없이 회복
#   pg-reset     원래 도메인으로 (다음 테이크 준비)
#   pg-status    사내 DNS 서버별 조회 결과 + 체크아웃 1건
#
#   traffic    부하 발생기 로그 실시간 보기
source "$(dirname "$0")/lib.sh"
load_env

SECONDARY_RULE=fw-allow-corp-dns-secondary

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

# ── ① 주 DNS 장애 → 보조 DNS 방화벽 차단 ─────────────────────
allow_secondary_dns() {
  info "방화벽: DNS 포워더 → 사내 보조 DNS(${CORP_DNS_SECONDARY_NAME}) 허용 규칙 추가 (${SECONDARY_RULE})"
  kc apply -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${SECONDARY_RULE}
  namespace: ${INFRA_NS}
  labels:
    demo.observ/firewall: egress
  annotations:
    demo.observ/description: "DNS 포워더 → 사내 보조 DNS (${CORP_DNS_SECONDARY_NAME} ${CORP_DNS_SECONDARY}) 53 허용"
spec:
  podSelector:
    matchLabels: { app: ${DNS_FORWARDER_NAME} }
  policyTypes: [Egress]
  egress:
    - to:
        - podSelector:
            matchLabels: { app: corp-dns, dns-role: secondary }
      ports:
        - { protocol: UDP, port: 1053 }
        - { protocol: TCP, port: 1053 }
YAML
}

remove_secondary_dns() {
  kc -n "$INFRA_NS" delete netpol "$SECONDARY_RULE" --ignore-not-found >/dev/null
  kc -n "$APP_NS" delete netpol "$SECONDARY_RULE" --ignore-not-found >/dev/null   # 이전 버전(배송 → 보조 DNS) 규칙
  info "방화벽: 보조 DNS 허용 규칙 제거 (방화벽 신청 때 누락된 상태)"
}

show_firewall() {
  kc get netpol -A -l "$FW_LABEL" \
    -o custom-columns='NAMESPACE:.metadata.namespace,RULE:.metadata.name,DESCRIPTION:.metadata.annotations.demo\.observ/description'
}

# forwarder_errors : 포워더 로그의 최근 실패 — 어느 사내 DNS IP 로 질의했다가 실패했는지 (IP 옆에 서버 이름을 붙임)
forwarder_errors() {
  kc -n "$INFRA_NS" logs "statefulset/$DNS_FORWARDER_NAME" --since=2m 2>/dev/null | grep 'plugin/errors' | tail -n "${1:-4}" \
    | sed -e "s#->${CORP_DNS_PRIMARY}:53#->${CORP_DNS_PRIMARY}:53(${CORP_DNS_PRIMARY_NAME} 주)#" \
          -e "s#->${CORP_DNS_SECONDARY}:53#->${CORP_DNS_SECONDARY}:53(${CORP_DNS_SECONDARY_NAME} 보조)#" \
          -e 's/^/  /'
}

status() {
  info "DNS 파드 (포워더 ${DNS_FORWARDER_IP:-?} → 주 ${CORP_DNS_PRIMARY:-?}, 보조 ${CORP_DNS_SECONDARY:-?})"
  kc -n "$INFRA_NS" get pods -l "app in (corp-dns,${DNS_FORWARDER_NAME})" \
    -o custom-columns='POD:.metadata.name,ROLE:.metadata.labels.dns-role,STATUS:.status.phase' 2>/dev/null
  [[ "$(kc -n "$INFRA_NS" get statefulset "$CORP_DNS_PRIMARY_NAME" -o jsonpath='{.spec.replicas}' 2>/dev/null)" == 0 ]] \
    && warn "주 DNS 파드 없음 (incident 상태)"

  info "배송 서비스 파드에서 택배사 도메인 조회와 443 연결 (OS 리졸버 → 포워더)"
  kc -n "$APP_NS" exec deploy/delivery-service -- python -c "
import socket, time
host='${COURIER_DOMAIN}'
t=time.time()
try:
    ip=socket.gethostbyname(host)
except OSError as e:
    print(f'  DNS  {host} 조회 실패 ({e}) — {time.time()-t:.1f}초'); raise SystemExit(0)
print(f'  DNS  {host} -> {ip} ({time.time()-t:.1f}초)')
try:
    socket.create_connection((ip,443),3).close(); print(f'  TCP  {ip}:443 연결 성공')
except OSError as e:
    print(f'  TCP  {ip}:443 연결 실패 ({e})')
" || warn "delivery-service exec 실패"

  info "DNS 포워더 최근 오류 (2분) — 어느 사내 DNS 로 질의했다가 실패했는지"
  local errs; errs="$(forwarder_errors 4)"
  if [[ -n "$errs" ]]; then echo "$errs"; else echo "  없음"; fi

  info "방화벽 규칙"
  show_firewall

  info "게이트웨이 → 주문 → 배송을 거친 배송 조회 1건"
  tracking status-check
  info "게이트웨이 → 주문 → 결제 → PG 를 거친 체크아웃 1건"
  checkout status-checkout
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

case "${1:-}" in
  baseline|reset)
    remove_secondary_dns
    corpdns primary-up
    ok "정상 상태: 주·보조 DNS·포워더 기동, 방화벽: 포워더 → 주 DNS 만 허용 (보조 DNS 는 등록 누락)"
    ;;
  incident)
    remove_secondary_dns
    corpdns primary-down
    ok "사건 발생: 주 DNS 장애 → 포워더가 보조 DNS 로 넘어가지만 방화벽에 막힘 → 택배사·PG 도메인 조회 실패 (배송 조회·체크아웃 실패)"
    ok "원인 로그: ./demo.sh corpdns logs forwarder  (read udp …-><사내 DNS IP>:53: i/o timeout)"
    ;;
  fix)
    allow_secondary_dns
    ok "해결: 방화벽에 보조 DNS 허용 추가 — 주 DNS 가 죽은 채로도 회복 (포워더가 주 DNS 를 비정상으로 보고 보조 DNS 로 바로 보냄)"
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

  traffic)  kc -n "$INFRA_NS" logs -f deploy/loadgen --tail=20 ;;
  *)
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
