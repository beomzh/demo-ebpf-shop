#!/usr/bin/env bash
# 쇼핑몰 다섯 서비스 + 데모 장치(택배사 DNS, 방화벽, 부하 발생기)를 배포한다.
# 배포 직후 상태 = "월요일 밤 이전" 정상 상태 (DNS → 예전 IP, 방화벽 → 예전 IP 허용)
source "$(dirname "$0")/lib.sh"
load_env

K="$ROOT/k8s"

info "namespaces"
kubectl apply -f "$K/00-namespaces.yaml"

if [[ -f "$ROOT/courier-ext/certs/ca.crt" ]]; then
  info "courier-ca secret (택배사 사설 CA)"
  kubectl -n "$APP_NS" create secret generic courier-ca \
    --from-file=ca.crt="$ROOT/courier-ext/certs/ca.crt" --dry-run=client -o yaml | kubectl apply -f -
else
  warn "courier-ext/certs/ca.crt 가 없어 courier-ca 시크릿을 건너뜁니다 (배송 서비스는 인증서 검증 없이 동작)."
fi

info "courier-dns (택배사 도메인 → ${COURIER_OLD_IP})"
render "$K/40-courier-dns.yaml" | kubectl apply -f -
kubectl -n "$INFRA_NS" rollout status deploy/courier-dns --timeout=120s
dns_ip="$(courier_dns_ip)"
[[ -n "$dns_ip" ]] || die "courier-dns ClusterIP 를 가져오지 못했습니다."
info "courier-dns ClusterIP = ${dns_ip}"

info "mysql + 다섯 서비스"
render "$K/10-mysql.yaml" | kubectl apply -f -
render "$K/20-services.yaml" | kubectl apply -f -
render "$K/30-delivery.yaml" "$dns_ip" | kubectl apply -f -

info "방화벽 (배송 서비스 egress: 클러스터 내부 + ${COURIER_OLD_IP}:443)"
render "$K/50-firewall.yaml" | kubectl apply -f -

info "rollout 대기"
kubectl -n "$APP_NS" rollout status deploy/mysql --timeout=300s
for d in member-service product-service order-service payment-service delivery-service; do
  kubectl -n "$APP_NS" rollout status "deploy/$d" --timeout=300s
done

info "loadgen (주문 서비스로 트래픽 발생)"
render "$K/60-loadgen.yaml" | kubectl apply -f -
kubectl -n "$INFRA_NS" rollout status deploy/loadgen --timeout=120s

ok "배포 완료. 상태 확인: ./scripts/scenario.sh status"
