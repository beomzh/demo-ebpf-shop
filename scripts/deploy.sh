#!/usr/bin/env bash
# 쇼핑몰 여덟 서비스 + MySQL·Redis + 데모 장치(사내 DNS 주·보조, 방화벽, 부하 발생기)를 배포한다.
# 배포 직후 상태 = "월요일 밤 이전" 정상 상태 (주·보조 DNS 모두 기동, 방화벽: 배송 → 주 DNS·택배사 허용)
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
  ok "이미지 ${#SERVICES[@]}개 확인"
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
if kc -n "$APP_NS" get secret redis-auth >/dev/null 2>&1; then
  info "redis-auth secret 이미 있음 (유지)"
else
  info "redis-auth secret 생성 (무작위 비밀번호)"
  kc -n "$APP_NS" create secret generic redis-auth \
    --from-literal=REDIS_PASSWORD="$(openssl rand -hex 16)" >/dev/null
fi

# 예전 버전의 택배사 전용 DNS(courier-dns)가 남아 있으면 지운다 — 택배사 도메인도 사내 DNS 가 답한다
kc -n "$INFRA_NS" delete deploy/courier-dns svc/courier-dns cm/courier-dns-corefile cm/courier-hosts \
  netpol/allow-courier-dns-from-delivery --ignore-not-found >/dev/null 2>&1 || true

"$ROOT/scripts/corpdns.sh" up
CORP_DNS_PRIMARY="$(corp_dns_svc_ip "$CORP_DNS_PRIMARY_NAME")"
CORP_DNS_SECONDARY="$(corp_dns_svc_ip "$CORP_DNS_SECONDARY_NAME")"
[[ -n "$CORP_DNS_PRIMARY" && -n "$CORP_DNS_SECONDARY" ]] || die "사내 DNS 주소가 비어 있습니다."
info "결제·배송 서비스의 DNS 서버: 주 ${CORP_DNS_PRIMARY}, 보조 ${CORP_DNS_SECONDARY}"
# 예전 버전의 주 DNS 차단 정책이 남아 있으면 지운다
kc -n "$INFRA_NS" delete netpol allow-corp-dns-primary-from-payment allow-corp-dns-secondary-from-payment allow-corp-dns-from-delivery \
  --ignore-not-found >/dev/null 2>&1 || true
kc -n "$APP_NS" delete netpol fw-corpdns-primary-unreachable --ignore-not-found >/dev/null 2>&1 || true

info "mysql + redis + 여덟 서비스"
render "$K/10-mysql.yaml" | kc apply -f -
render "$K/15-redis.yaml" | kc apply -f -
render "$K/20-services.yaml" | kc apply -f -
render "$K/30-delivery.yaml" | kc apply -f -

info "방화벽 (배송 서비스 egress: 사내 주 DNS + ${COURIER_IP}:443 만 허용 — 보조 DNS 는 등록 누락)"
# 이전 버전·이전 테이크의 방화벽 규칙(택배사 새 IP, 보조 DNS 허용 등)을 지우고 기본 상태로 다시 만든다
kc -n "$APP_NS" delete netpol -l "$FW_LABEL" --ignore-not-found >/dev/null
render "$K/50-firewall.yaml" | kc apply -f -

info "서비스 간 인바운드 격리 (필요한 호출 경로만 허용)"
render "$K/55-network-isolation.yaml" | kc apply -f -

info "rollout 대기"
kc -n "$APP_NS" rollout status deploy/mysql --timeout=300s
kc -n "$APP_NS" rollout status deploy/redis --timeout=300s
for d in "${SERVICES[@]}"; do
  kc -n "$APP_NS" rollout status "deploy/$d" --timeout=300s
done

info "loadgen (게이트웨이로 트래픽 발생)"
render "$K/60-loadgen.yaml" | kc apply -f -
kc -n "$INFRA_NS" rollout status deploy/loadgen --timeout=120s

ok "배포 완료. 상태 확인: ./demo.sh status / 보안 점검: ./demo.sh security"
