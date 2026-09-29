#!/usr/bin/env bash
# 사내 DNS(주·보조) 조작 — demo-infra 네임스페이스의 파드  ns1-corp-dns-0 (주), ns2-corp-dns-0 (보조)
#
#   up                        주·보조 DNS 배포 (deploy 가 자동으로 함)
#   down                      삭제
#   status                    파드·서비스 IP·레코드
#   logs [primary|secondary|all]   질의 로그 (기본 all: 두 서버를 한 화면에 → 주 → 보조 전환 확인)
#   records                   등록된 레코드 목록
#   record-add [도메인] [IP]  레코드 등록·변경 (기본: PG_DOMAIN → PG_IP)
#   record-remove [도메인]    레코드 삭제 → NXDOMAIN (기본: PG_DOMAIN)
#   primary-down              주 DNS 파드 삭제 (StatefulSet 0 개로 — 다시 뜨지 않음) → 보조 DNS 가 응답
#   primary-up                주 DNS 파드 다시 기동
source "$(dirname "$0")/lib.sh"
load_env

cmd="${1:-status}"
arg="${2:-}"
arg_ip="${3:-}"
P="$CORP_DNS_PRIMARY_NAME" S2="$CORP_DNS_SECONDARY_NAME"

corp_up() {
  info "사내 DNS 파드 배포 (주 ${P}, 보조 ${S2})"
  render "$ROOT/k8s/45-corp-dns.yaml" | kc apply -f - >/dev/null
  CORP_DNS_PRIMARY="$(corp_dns_svc_ip "$P")"
  CORP_DNS_SECONDARY="$(corp_dns_svc_ip "$S2")"
  [[ -n "$CORP_DNS_PRIMARY" && -n "$CORP_DNS_SECONDARY" ]] || die "사내 DNS 서비스 ClusterIP 를 가져오지 못했습니다."
  local records; records="$(corp_records)"
  if [[ -z "$records" ]]; then
    records="${PG_DOMAIN} ${PG_IP}"   # 처음 배포: PG 도메인 + 택배사 도메인(예전 IP)
    info "존 생성: ${PG_DOMAIN} → ${PG_IP}, ${COURIER_DOMAIN} → ${COURIER_OLD_IP}"
  else
    info "기존 레코드 유지"
  fi
  # 택배사 도메인 레코드가 없으면 예전 IP 로 넣는다
  if ! printf '%s\n' "$records" | awk -v d="$COURIER_DOMAIN" '$1 == d { f = 1 } END { exit !f }'; then
    records="$(printf '%s\n%s %s' "$records" "$COURIER_DOMAIN" "$COURIER_OLD_IP")"
  fi
  corp_zone_apply "$records"
  kc -n "$INFRA_NS" rollout status "statefulset/$P" --timeout=120s >/dev/null
  kc -n "$INFRA_NS" rollout status "statefulset/$S2" --timeout=120s >/dev/null
  ok "사내 DNS: 주 ${P} ${CORP_DNS_PRIMARY}, 보조 ${S2} ${CORP_DNS_SECONDARY}"
}

# wait_zone <도메인> <present|absent|IP> : 응답하는 서버가 모두 기대한 결과를 낼 때까지 기다린다 (주 DNS 가 없으면 그 서버는 건너뜀)
wait_zone() {
  local d="$1" want="$2" waited=0 out
  kc -n "$APP_NS" get deploy payment-service >/dev/null 2>&1 || return 0
  while :; do
    out="$(dns_query "$d" 2>/dev/null || true)"
    if [[ -n "$out" ]] && printf '%s\n' "$out" | awk -v want="$want" '
        $3 ~ /^(TIMEOUT|CONNREFUSED)/ { next }
        want == "present" && $3 !~ /^[0-9.,]+$/ { bad = 1 }
        want ~ /^[0-9.]+$/ && $3 != want        { bad = 1 }
        want == "absent"  && $3 !~ /^NXDOMAIN/  { bad = 1 }
        END { exit bad }'; then
      return 0
    fi
    if (( waited >= 60 )); then
      warn "ConfigMap 반영이 늦어 사내 DNS 파드를 재시작합니다"
      kc -n "$INFRA_NS" rollout restart "statefulset/$P" "statefulset/$S2" >/dev/null
      kc -n "$INFRA_NS" rollout status "statefulset/$P" --timeout=120s >/dev/null
      kc -n "$INFRA_NS" rollout status "statefulset/$S2" --timeout=120s >/dev/null
      return 0
    fi
    sleep 2; waited=$((waited + 2))
    # kubelet 이 새 ConfigMap 을 받기 전에 다시 마운트했을 수 있으므로 4초마다 다시 건드린다
    (( waited % 4 == 0 )) && kc -n "$INFRA_NS" annotate pod -l app=corp-dns --overwrite "demo.observ/zone-sync=$(date +%s)" >/dev/null 2>&1
  done
}

primary_replicas() {
  kc -n "$INFRA_NS" get statefulset "$P" -o jsonpath='{.spec.replicas}' 2>/dev/null || true
}

case "$cmd" in
  up) corp_up ;;
  down)
    kc -n "$INFRA_NS" delete statefulset "$P" "$S2" --ignore-not-found >/dev/null
    kc -n "$INFRA_NS" delete svc "$P" "$S2" --ignore-not-found >/dev/null
    kc -n "$INFRA_NS" delete configmap corp-dns-corefile corp-dns-zone --ignore-not-found >/dev/null
    kc -n "$INFRA_NS" delete netpol allow-corp-dns-from-clients --ignore-not-found >/dev/null
    ok "사내 DNS 파드 삭제 (결제·배송 서비스는 다시 deploy 해야 새 주소를 받습니다)"
    ;;
  status)
    kc -n "$INFRA_NS" get pods -l app=corp-dns \
      -o custom-columns='POD:.metadata.name,ROLE:.metadata.labels.dns-role,STATUS:.status.phase,POD-IP:.status.podIP,NODE:.spec.nodeName'
    echo "서비스: 주 ${P} ${CORP_DNS_PRIMARY:-없음}, 보조 ${S2} ${CORP_DNS_SECONDARY:-없음}"
    if [[ "$(primary_replicas)" == 0 ]]; then echo "주 DNS: 파드 없음 (primary-down) — 보조 DNS 가 응답 중"; fi
    echo "등록된 레코드:"
    corp_records | sed '/^$/d; s/^/  /; s/ \([0-9.]*\)$/ → \1/'
    ;;
  logs)
    case "${arg:-all}" in
      primary)   kc -n "$INFRA_NS" logs -f "statefulset/$P" --tail=20 ;;
      secondary) kc -n "$INFRA_NS" logs -f "statefulset/$S2" --tail=20 ;;
      all)       kc -n "$INFRA_NS" logs -f -l app=corp-dns --prefix --max-log-requests=2 --tail=10 ;;
      *) die "logs [primary|secondary|all]" ;;
    esac
    ;;
  records) corp_records | sed '/^$/d; s/ / → /' ;;
  record-add)
    d="${arg:-$PG_DOMAIN}" ip="${arg_ip:-$PG_IP}"
    corp_zone_apply "$(corp_records | awk -v d="$d" 'NF && $1 != d'; echo "$d $ip")"
    wait_zone "$d" "$ip"
    ok "사내 DNS 에 ${d} → ${ip} 등록 (주·보조 반영)"
    ;;
  record-remove)
    d="${arg:-$PG_DOMAIN}"
    corp_zone_apply "$(corp_records | awk -v d="$d" 'NF && $1 != d')"
    wait_zone "$d" absent
    ok "사내 DNS 에서 ${d} 삭제 → NXDOMAIN"
    ;;
  primary-down)
    kc -n "$INFRA_NS" scale statefulset "$P" --replicas=0 >/dev/null
    kc -n "$INFRA_NS" wait --for=delete pod "${P}-0" --timeout=60s >/dev/null 2>&1 || true
    ok "주 DNS 파드(${P}-0) 삭제 — 결제·배송 서비스는 보조 DNS(${S2}) 로 계속 조회합니다"
    ;;
  primary-up)
    kc -n "$INFRA_NS" scale statefulset "$P" --replicas=1 >/dev/null
    kc -n "$INFRA_NS" rollout status "statefulset/$P" --timeout=120s >/dev/null
    ok "주 DNS 파드(${P}-0) 다시 기동"
    ;;
  *)
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
