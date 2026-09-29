#!/usr/bin/env bash
# 사내 DNS(주·보조) 조작 — demo.env 의 CORP_DNS_MODE 에 따라 대상이 다르다
#   cluster   : demo-infra 네임스페이스의 파드  ns1-corp-dns-0 (주), ns2-corp-dns-0 (보조)
#   bastion   : bastion 의 컨테이너 (corpdns-ext/run.sh 로 넘김)
#   corporate : 실제 사내 DNS — 이 스크립트로 조작하지 않는다
#
#   up                      주·보조 DNS 배포 (deploy 가 자동으로 함)
#   down                    삭제
#   status                  파드·서비스 IP·주 DNS 차단 여부·레코드
#   logs [primary|secondary|all]   질의 로그 (기본 all: 두 서버를 한 화면에 → 주 → 보조 전환 확인)
#   records                 등록된 레코드 목록
#   record-add [도메인] [IP]  레코드 등록·변경 (기본: PG_DOMAIN → PG_IP). 택배사 IP 변경은 incident 가 이걸로 한다
#   record-remove [도메인]  레코드 삭제 → NXDOMAIN (기본: PG_DOMAIN)
#   primary-down            주 DNS 장애: 결제 → 주 DNS 허용 정책 삭제 → 질의가 버려짐 (응답 없음 → 결제 서비스는 2초 뒤 보조 DNS 로)
#   primary-up              주 DNS 복구
source "$(dirname "$0")/lib.sh"

# bastion 모드는 클러스터 CLI 없이도 쓰므로 load_env 전에 넘긴다
mode="$(set -a; source "${DEMO_ENV:-$ROOT/demo.env}" 2>/dev/null; echo "${CORP_DNS_MODE:-cluster}")"
if [[ "$mode" == bastion ]]; then
  runner=("$ROOT/corpdns-ext/run.sh" "$@")
  [[ $EUID -eq 0 ]] || runner=(sudo "${runner[@]}")
  exec "${runner[@]}"
fi
load_env
[[ "$CORP_DNS_MODE" == cluster ]] \
  || die "CORP_DNS_MODE=${CORP_DNS_MODE}: 실제 사내 DNS 는 이 스크립트로 조작하지 않습니다 (README 5-5b)."

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
  # 택배사 도메인 레코드가 없으면 예전 IP 로 넣는다 (courier-dns 를 쓰던 버전에서 올라온 경우 포함)
  if ! printf '%s\n' "$records" | awk -v d="$COURIER_DOMAIN" '$1 == d { f = 1 } END { exit !f }'; then
    records="$(printf '%s\n%s %s' "$records" "$COURIER_DOMAIN" "$COURIER_OLD_IP")"
  fi
  corp_zone_apply "$records"
  kc -n "$INFRA_NS" rollout status "statefulset/$P" --timeout=120s >/dev/null
  kc -n "$INFRA_NS" rollout status "statefulset/$S2" --timeout=120s >/dev/null
  ok "사내 DNS: 주 ${P} ${CORP_DNS_PRIMARY}, 보조 ${S2} ${CORP_DNS_SECONDARY}"
}

# wait_zone <도메인> <present|absent|IP> : 응답하는 서버가 모두 기대한 결과를 낼 때까지 기다린다 (주 DNS 차단 중이면 그 서버는 건너뜀)
wait_zone() {
  local d="$1" want="$2" waited=0 out
  kc -n "$APP_NS" get deploy payment-service >/dev/null 2>&1 || return 0
  while :; do
    out="$(pg_dns_query "$d" 2>/dev/null || true)"
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

primary_is_down() {
  kc -n "$INFRA_NS" get statefulset "$P" >/dev/null 2>&1 \
    && ! kc -n "$INFRA_NS" get netpol "$CORP_DNS_PRIMARY_ALLOW" >/dev/null 2>&1
}

case "$cmd" in
  up) corp_up ;;
  down)
    kc -n "$INFRA_NS" delete statefulset "$P" "$S2" --ignore-not-found >/dev/null
    kc -n "$INFRA_NS" delete svc "$P" "$S2" --ignore-not-found >/dev/null
    kc -n "$INFRA_NS" delete configmap corp-dns-corefile corp-dns-zone --ignore-not-found >/dev/null
    kc -n "$INFRA_NS" delete netpol "$CORP_DNS_PRIMARY_ALLOW" allow-corp-dns-secondary-from-payment --ignore-not-found >/dev/null
    ok "사내 DNS 파드 삭제 (결제 서비스는 다시 deploy 해야 새 주소를 받습니다)"
    ;;
  status)
    kc -n "$INFRA_NS" get pods -l app=corp-dns \
      -o custom-columns='POD:.metadata.name,ROLE:.metadata.labels.dns-role,STATUS:.status.phase,POD-IP:.status.podIP,NODE:.spec.nodeName'
    echo "서비스: 주 ${P} ${CORP_DNS_PRIMARY:-없음}, 보조 ${S2} ${CORP_DNS_SECONDARY:-없음}"
    if primary_is_down; then
      echo "주 DNS: 응답 중지 상태 (primary-down — 허용 정책 ${CORP_DNS_PRIMARY_ALLOW} 없음, 질의는 기본 차단 정책이 버림)"
    fi
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
    kc -n "$INFRA_NS" delete netpol "$CORP_DNS_PRIMARY_ALLOW" --ignore-not-found >/dev/null
    ok "주 DNS(${P} ${CORP_DNS_PRIMARY}) 응답 중지 — 질의는 타임아웃되고 결제 서비스는 보조 DNS(${S2}) 로 넘어갑니다"
    ;;
  primary-up)
    render "$ROOT/k8s/45-corp-dns.yaml" | kc apply -f - >/dev/null   # 허용 정책을 되살림 (나머지는 그대로)
    ok "주 DNS(${P}) 복구"
    ;;
  *)
    sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
