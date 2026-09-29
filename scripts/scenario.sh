#!/usr/bin/env bash
# 사건 시나리오 전환 스크립트
#
#   baseline   정상 상태        사내 DNS 의 택배사 레코드 → 예전 IP, 방화벽: 예전 IP 만 허용   (월요일 밤 이전)
#   incident   사건 발생        사내 DNS 의 택배사 레코드 → 새 IP,   방화벽: 예전 IP 만 허용   (월요일 밤: 택배사가 IP 변경)
#   fix        해결             방화벽에 새 IP 허용 규칙 추가                (화요일 09:40)
#   reset      baseline 과 같음 (다음 촬영 준비)
#   status     현재 DNS 응답·방화벽 규칙·연결 가능 여부·배송 조회 결과 요약
#   firewall   방화벽 규칙 목록만 출력 (데모 3-4 "방화벽 규칙 확인" 장면용)
#   traffic    부하 발생기 로그 실시간 보기
#
# 추가 시나리오 — 외부 PG사 도메인 DNS 장애 (결제 서비스만 사내 DNS 로 PG 도메인 조회)
#   pg-missing       PG사가 새 도메인으로 이전 → 결제 서비스는 새 도메인으로 배포됐지만 사내 DNS 에 등록 누락
#                    → NXDOMAIN (결제 서비스 로그 'DNS NXDOMAIN', 체크아웃 502)
#   pg-register      해결: 사내 DNS 에 새 도메인 등록 → 앱 재시작 없이 회복 (corporate 모드: 등록될 때까지 기다림)
#   pg-primary-down  사내 주 DNS 장애 → 타임아웃 후 보조 DNS 로 넘어감 (결제 약 2초 지연, dns fallback 로그)
#   pg-reset         PG 시나리오 원상 복구 (다음 테이크 준비)
#   pg-status        사내 DNS 서버별 응답과 체크아웃 1건 결과
source "$(dirname "$0")/lib.sh"
load_env

NEW_RULE="fw-allow-courier-$(dashed "$COURIER_NEW_IP")"

# 택배사 도메인은 사내 DNS(주·보조)의 A 레코드 한 줄이다. 택배사가 IP 를 바꾸면 이 레코드가 바뀐다
set_courier_ip() {
  local ip="$1" waited=0
  info "사내 DNS: ${COURIER_DOMAIN} → ${ip}"
  if managed_dns; then
    corpdns record-add "$COURIER_DOMAIN" "$ip" >/dev/null
    return
  fi
  # corporate: 실제 사내 DNS 는 건드리지 않는다 → 담당자가 바꿀 때까지 기다림
  courier_resolves_to "$ip" && return
  info "사내 DNS 담당자에게 요청할 내용 (주 ${CORP_DNS_PRIMARY}, 보조 ${CORP_DNS_SECONDARY} 모두):"
  echo "    A 레코드  ${COURIER_DOMAIN}  →  ${ip}   (TTL 5~60초)"
  until courier_resolves_to "$ip"; do
    (( waited >= 600 )) && die "600초 안에 사내 DNS 에서 ${COURIER_DOMAIN} → ${ip} 가 조회되지 않았습니다"
    sleep 5; waited=$((waited + 5))
  done
}

# 사내 DNS 가 택배사 도메인을 ip 로 답하면 0 (응답하는 서버 기준)
courier_resolves_to() {
  local out; out="$(pg_dns_query "$COURIER_DOMAIN" 2>/dev/null)" || return 1
  [[ -n "$out" ]] && printf '%s\n' "$out" | awk -v ip="$1" '
    $3 ~ /^(TIMEOUT|CONNREFUSED)/ { next }
    { answered = 1 }
    $3 != ip { bad = 1 }
    END { exit (bad || !answered) }'
}

allow_new_ip() {
  info "방화벽: ${COURIER_NEW_IP}:443 허용 규칙 추가 (${NEW_RULE})"
  kc apply -f - <<EOF
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
EOF
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
  pg_dns_query "$COURIER_DOMAIN" | sed "s/^/  /; s/ \([^ ]*\) \([^ ]*ms\)$/  ${COURIER_DOMAIN} → \1 (\2)/" || warn "payment-service exec 실패"

  info "배송 서비스 파드에서 본 DNS 응답과 443 연결 (3초 제한)"
  kc -n "$APP_NS" exec deploy/delivery-service -- python -c "
import socket
host='${COURIER_DOMAIN}'
ip=socket.gethostbyname(host)
print(f'  DNS  {host} -> {ip}')
try:
    socket.create_connection((ip,443),3).close(); print(f'  TCP  {ip}:443 연결 성공')
except OSError as e:
    print(f'  TCP  {ip}:443 연결 실패 ({e})')
" || warn "delivery-service exec 실패"

  info "방화벽 규칙"
  show_firewall

  info "게이트웨이 → 주문 → 배송을 거친 배송 조회 1건"
  local out code_line body path
  out="$(kc -n "$INFRA_NS" exec deploy/loadgen -- \
    curl -s -m 20 -H 'X-Request-Id: status-check' -w '\n%{http_code} %{time_total}s' \
    "http://gateway-service.${APP_NS}.svc.cluster.local:8080/api/orders/1001/tracking" 2>&1 || true)"
  code_line="$(printf '%s\n' "$out" | tail -n 1)"
  body="$(printf '%s\n' "$out" | sed '$d')"
  echo "  HTTP ${code_line}"
  # 실패하면 서비스들이 이어 붙인 실패 경로(errorPath)를 보여준다
  path="$(printf '%s' "$body" | sed -n 's/.*"errorPath":"\([^"]*\)".*/\1/p')"
  [[ -n "$path" ]] && echo "  실패 경로: ${path}"
  return 0
}

# ── PG 도메인 DNS 시나리오 ────────────────────────────────────
PG_NETPOL=fw-corpdns-primary-unreachable

# 사내 DNS 조작 (cluster: ns1/ns2-corp-dns 파드, bastion: bastion 컨테이너) — scripts/corpdns.sh
corpdns() { "$ROOT/scripts/corpdns.sh" "$@"; }

# 레코드 삭제·등록과 주 DNS 멈춤을 실제로 할 수 있는 모드인가 (corporate 는 실제 사내 DNS 라 건드리지 않음)
managed_dns() { [[ "$CORP_DNS_MODE" != corporate ]]; }

set_pg_domain() {
  info "결제 서비스 PG_DOMAIN=$1 (재시작)"
  kc -n "$APP_NS" set env deploy/payment-service "PG_DOMAIN=$1" >/dev/null
  kc -n "$APP_NS" rollout status deploy/payment-service --timeout=180s >/dev/null
}

block_primary_dns() {
  info "결제 서비스 → 주 DNS(${CORP_DNS_PRIMARY}) 패킷 차단 (응답 없음 = 타임아웃)"
  kc apply -f - >/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${PG_NETPOL}
  namespace: ${APP_NS}
  labels:
    demo.observ/scenario: pg-dns
  annotations:
    demo.observ/description: "주 사내 DNS ${CORP_DNS_PRIMARY} 장애 흉내 (corporate 모드)"
spec:
  podSelector:
    matchLabels: { app: payment-service }
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector: {}
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except: ["${CORP_DNS_PRIMARY}/32"]
EOF
}

# 결제 파드에서 도메인을 주·보조 DNS 에 각각 조회해, 응답하는 서버가 모두 IP 를 돌려주면 0
# (주 DNS 장애 중이면 그 서버는 건너뛴다. 응답하는 서버가 하나도 없으면 실패)
pg_resolves_everywhere() {
  local out; out="$(pg_dns_query "$1" 2>/dev/null)" || return 1
  [[ -n "$out" ]] && printf '%s\n' "$out" | awk '
    $3 ~ /^(TIMEOUT|CONNREFUSED)/ { next }
    { answered = 1 }
    $3 !~ /^[0-9.,]+$/ { bad = 1 }
    END { exit (bad || !answered) }'
}

current_pg_domain() {
  kc -n "$APP_NS" get deploy payment-service \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="PG_DOMAIN")].value}' 2>/dev/null
}

pg_register() {
  local d="$PG_UNREGISTERED_DOMAIN" waited=0 limit="${PG_REGISTER_WAIT:-600}"
  [[ "$(current_pg_domain)" == "$d" ]] || warn "앱이 아직 ${d} 를 쓰고 있지 않습니다 — 먼저 './demo.sh pg-missing'"
  if managed_dns; then
    corpdns record-add "$d"
  else
    info "사내 DNS 담당자에게 요청할 내용 (주 ${CORP_DNS_PRIMARY}, 보조 ${CORP_DNS_SECONDARY} 모두):"
    echo "    A 레코드  ${d}  →  ${PG_IP}   (TTL 5~60초)"
    echo "    직접 관리하는 BIND 라면 주 DNS 존 파일에 '${d%%.*}  IN A  ${PG_IP}' 추가 + SOA 시리얼 증가 + 'rndc reload'"
    info "등록될 때까지 기다립니다 (최대 ${limit}초, Ctrl+C 로 중단 가능)"
  fi
  until pg_resolves_everywhere "$d"; do
    (( waited >= limit )) && die "${limit}초 안에 주·보조 DNS 모두에서 ${d} 가 조회되지 않았습니다 ('./demo.sh pg-status' 로 서버별 결과 확인)"
    (( waited % 15 == 0 )) && info "  아직 조회 안 됨 (${waited}s) — 주·보조 모두 등록돼야 합니다"
    sleep 5; waited=$((waited + 5))
  done
  ok "주·보조 사내 DNS 모두 ${d} → ${PG_IP} 조회됨 — 앱 재시작 없이 다음 요청부터 회복됩니다"
}

pg_status() {
  local host; host="$(current_pg_domain)"; host="${host:-$PG_DOMAIN}"   # pg-missing 뒤에는 새 도메인
  info "사내 DNS (${CORP_DNS_MODE} 모드) — 결제 서비스 파드에서 서버별로 ${host} 조회"
  pg_dns_query "$host" | sed "s/^/  /; s/ \([^ ]*\) \([^ ]*ms\)$/  ${host} → \1 (\2)/" || warn "payment-service exec 실패"
  if managed_dns; then info "사내 DNS (${CORP_DNS_MODE})"; corpdns status || true; fi
  kc -n "$APP_NS" get netpol "$PG_NETPOL" >/dev/null 2>&1 && warn "주 DNS 차단 정책(${PG_NETPOL}) 적용 중"

  info "게이트웨이 → 주문 → 결제 → PG 를 거친 체크아웃 1건"
  local out code_line body path
  out="$(kc -n "$INFRA_NS" exec deploy/loadgen -- \
    curl -s -m 20 -H 'X-Request-Id: pg-status-check' -H 'Content-Type: application/json' -X POST \
    -d '{"memberId":10,"productId":3,"qty":1}' -w '\n%{http_code} %{time_total}s' \
    "http://gateway-service.${APP_NS}.svc.cluster.local:8080/api/checkout" 2>&1 || true)"
  code_line="$(printf '%s\n' "$out" | tail -n 1)"
  body="$(printf '%s\n' "$out" | sed '$d')"
  echo "  HTTP ${code_line}"
  path="$(printf '%s' "$body" | sed -n 's/.*"errorPath":"\([^"]*\)".*/\1/p')"
  [[ -n "$path" ]] && echo "  실패 경로: ${path}"
  return 0
}

case "${1:-}" in
  baseline|reset)
    remove_new_ip
    set_courier_ip "$COURIER_OLD_IP"
    ok "정상 상태: DNS → ${COURIER_OLD_IP}, 방화벽 → ${COURIER_OLD_IP} 허용"
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
  pg-missing)
    # PG사가 새 도메인으로 이전 → 앱은 새 도메인으로 배포됐지만 사내 DNS 에 등록이 누락된 상황
    managed_dns && corpdns record-remove "$PG_UNREGISTERED_DOMAIN" >/dev/null
    set_pg_domain "$PG_UNREGISTERED_DOMAIN"
    ok "사내 DNS 에 ${PG_UNREGISTERED_DOMAIN} 없음 — 체크아웃이 실패합니다 (결제 서비스 로그: DNS NXDOMAIN)"
    ok "해결 장면: './demo.sh pg-register' (사내 DNS 에 등록)"
    ;;
  pg-register)
    pg_register
    pg_status
    ;;
  pg-primary-down)
    if managed_dns; then
      corpdns primary-down
    else
      block_primary_dns
    fi
    ok "주 DNS 장애 재현 — 체크아웃이 약 2초 느려지고 결제 서비스에 dns fallback 로그가 남습니다"
    ;;
  pg-reset)
    if managed_dns; then
      corpdns primary-up
      corpdns record-add "$PG_DOMAIN" >/dev/null
      corpdns record-remove "$PG_UNREGISTERED_DOMAIN" >/dev/null
    fi
    kc -n "$APP_NS" delete netpol "$PG_NETPOL" --ignore-not-found >/dev/null
    [[ "$(current_pg_domain)" == "$PG_DOMAIN" ]] || set_pg_domain "$PG_DOMAIN"
    ok "PG 시나리오 복구 (앱 PG 도메인: ${PG_DOMAIN})"
    if [[ "$CORP_DNS_MODE" == corporate ]] && pg_resolves_everywhere "$PG_UNREGISTERED_DOMAIN"; then
      warn "사내 DNS 에 ${PG_UNREGISTERED_DOMAIN} 가 등록돼 있습니다 — 'pg-missing' 을 다시 시연하려면 이 레코드를 삭제해야 합니다"
    fi
    ;;
  pg-status) pg_status ;;
  status)   status ;;
  firewall) show_firewall ;;
  traffic)  kc -n "$INFRA_NS" logs -f deploy/loadgen --tail=20 ;;
  *)
    sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
