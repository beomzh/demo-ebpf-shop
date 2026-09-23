#!/usr/bin/env bash
# 쇼핑몰 다섯 서비스 + 데모 장치(택배사 DNS, 방화벽, 부하 발생기)를 배포한다.
# 배포 직후 상태 = "월요일 밤 이전" 정상 상태 (DNS → 예전 IP, 방화벽 → 예전 IP 허용)
source "$(dirname "$0")/lib.sh"
load_env

K="$ROOT/k8s"

info "cli=${KC} registry-mode=${REGISTRY_MODE} pull=$(pull_registry)"

info "namespaces"
kc apply -f "$K/00-namespaces.yaml"

if [[ "$REGISTRY_MODE" == ocp-internal ]]; then
  info "ImageStream 태그 확인 (${APP_NS}/shop-*:${TAG})"
  for svc in "${SERVICES[@]}"; do
    kc -n "$APP_NS" get istag "$(image_name "$svc"):${TAG}" >/dev/null 2>&1 \
      || die "이미지 $(image_name "$svc"):${TAG} 가 ImageStream 에 없습니다. './demo.sh push' 를 먼저 실행하세요."
  done
  ok "이미지 5개 확인"
fi

[[ -f "$ROOT/courier-ext/certs/ca.crt" ]] \
  || die "courier-ext/certs/ca.crt 가 없습니다. './demo.sh certs' 로 만들고 택배사 호스트에도 같은 인증서를 배포하세요."
info "courier-ca secret (택배사 사설 CA — 공개 인증서만 올리고 ca.key 는 올리지 않음)"
kc -n "$APP_NS" create secret generic courier-ca \
  --from-file=ca.crt="$ROOT/courier-ext/certs/ca.crt" --dry-run=client -o yaml | kc apply -f -

# MySQL 접속 정보는 git 에 두지 않는다. 처음 배포할 때 무작위로 만들고 이후에는 그대로 둔다.
if kc -n "$APP_NS" get secret mysql-auth >/dev/null 2>&1; then
  info "mysql-auth secret 이미 있음 (유지)"
else
  info "mysql-auth secret 생성 (무작위 비밀번호)"
  kc -n "$APP_NS" create secret generic mysql-auth \
    --from-literal=MYSQL_USER=shop \
    --from-literal=MYSQL_DATABASE=shop \
    --from-literal=MYSQL_PASSWORD="$(openssl rand -hex 16)" \
    --from-literal=MYSQL_ROOT_PASSWORD="$(openssl rand -hex 16)" >/dev/null
fi

info "courier-dns (택배사 도메인 → ${COURIER_OLD_IP})"
render "$K/40-courier-dns.yaml" | kc apply -f -
kc -n "$INFRA_NS" rollout status deploy/courier-dns --timeout=120s
dns_ip="$(courier_dns_ip)"
[[ -n "$dns_ip" ]] || die "courier-dns ClusterIP 를 가져오지 못했습니다."
info "courier-dns ClusterIP = ${dns_ip}"

info "mysql + 다섯 서비스"
render "$K/10-mysql.yaml" | kc apply -f -
render "$K/20-services.yaml" | kc apply -f -
render "$K/30-delivery.yaml" "$dns_ip" | kc apply -f -

info "방화벽 (배송 서비스 egress: 택배사 DNS + ${COURIER_OLD_IP}:443)"
render "$K/50-firewall.yaml" | kc apply -f -

info "서비스 간 인바운드 격리 (필요한 호출 경로만 허용)"
render "$K/55-network-isolation.yaml" | kc apply -f -

info "rollout 대기"
kc -n "$APP_NS" rollout status deploy/mysql --timeout=300s
for d in member-service product-service order-service payment-service delivery-service; do
  kc -n "$APP_NS" rollout status "deploy/$d" --timeout=300s
done

info "loadgen (주문 서비스로 트래픽 발생)"
render "$K/60-loadgen.yaml" | kc apply -f -
kc -n "$INFRA_NS" rollout status deploy/loadgen --timeout=120s

ok "배포 완료. 상태 확인: ./demo.sh status / 보안 점검: ./demo.sh security"
