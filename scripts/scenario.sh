#!/usr/bin/env bash
# 사건 시나리오 전환 스크립트
#
#   baseline   정상 상태        DNS → 예전 IP, 방화벽: 예전 IP 만 허용       (월요일 밤 이전)
#   incident   사건 발생        DNS → 새 IP,   방화벽: 예전 IP 만 허용       (월요일 밤: 택배사가 IP 변경)
#   fix        해결             방화벽에 새 IP 허용 규칙 추가                (화요일 09:40)
#   reset      baseline 과 같음 (다음 촬영 준비)
#   status     현재 DNS 응답·방화벽 규칙·연결 가능 여부·배송 조회 결과 요약
#   firewall   방화벽 규칙 목록만 출력 (데모 3-4 "방화벽 규칙 확인" 장면용)
#   traffic    부하 발생기 로그 실시간 보기
source "$(dirname "$0")/lib.sh"
load_env

NEW_RULE="fw-allow-courier-$(dashed "$COURIER_NEW_IP")"

set_courier_ip() {
  local ip="$1"
  info "택배사 DNS: ${COURIER_DOMAIN} → ${ip}"
  kc -n "$INFRA_NS" create configmap courier-hosts \
    --from-literal="courier.hosts=${ip} ${COURIER_DOMAIN}" --dry-run=client -o yaml | kc apply -f - >/dev/null
  # ConfigMap 볼륨 전파(최대 ~1분)를 기다리지 않도록 재시작해 즉시 반영
  kc -n "$INFRA_NS" rollout restart deploy/courier-dns >/dev/null
  kc -n "$INFRA_NS" rollout status deploy/courier-dns --timeout=120s >/dev/null
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
  info "택배사 DNS 설정 (courier-hosts)"
  kc -n "$INFRA_NS" get configmap courier-hosts -o jsonpath='{.data.courier\.hosts}'; echo

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

  info "주문 서비스를 거친 배송 조회 1건"
  kc -n "$INFRA_NS" exec deploy/loadgen -- \
    curl -s -m 15 -o /dev/null -w '  HTTP %{http_code}  %{time_total}s\n' \
    "http://order-service.${APP_NS}.svc.cluster.local:8080/api/orders/1001/delivery" || true
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
  status)   status ;;
  firewall) show_firewall ;;
  traffic)  kc -n "$INFRA_NS" logs -f deploy/loadgen --tail=20 ;;
  *)
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
