#!/usr/bin/env bash
# 가상 "사내 DNS" (주 DNS + 보조 DNS) — bastion 등 클러스터 밖 호스트에서 실행한다 (CORP_DNS_MODE=bastion).
# 외부 PG사 도메인(PG_DOMAIN)을 PG_IP 로 답하고, 없는 이름에는 NXDOMAIN 을 돌려준다 (실제 사내 DNS 처럼 권한 있는 응답).
#
#   sudo ./run.sh up              주·보조 DNS 기동 (CORP_DNS_PRIMARY / CORP_DNS_SECONDARY 의 53 에서만 받음)
#   sudo ./run.sh down            정지·삭제
#   sudo ./run.sh status          상태와 현재 레코드
#   sudo ./run.sh logs [primary|secondary]
#   sudo ./run.sh record-remove [도메인]   레코드 삭제 → NXDOMAIN (기본: PG_DOMAIN)
#   sudo ./run.sh record-add [도메인]      레코드 등록 → PG_IP     (기본: PG_DOMAIN)
#   sudo ./run.sh records                  등록된 레코드 목록
#   sudo ./run.sh primary-down    주 DNS 멈춤 (응답 없음 → 클라이언트 타임아웃) (시나리오: 주 DNS 장애)
#   sudo ./run.sh primary-up      주 DNS 복구
#
# 설정은 ../demo.env 에서 읽는다 (환경변수로 덮어쓸 수 있음):
#   CORP_DNS_PRIMARY, CORP_DNS_SECONDARY, PG_DOMAIN, PG_IP(비우면 COURIER_OLD_IP)
# 두 IP 는 호스트에 미리 붙어 있어야 한다 (../courier-ext/setup-ips.sh). 53 은 특권 포트라 root 로 실행한다.
set -euo pipefail

cd "$(dirname "$0")"
IMAGE=registry.k8s.io/coredns/coredns:v1.11.3
RENDER=.rendered

if [[ -f ../demo.env ]]; then
  # shellcheck disable=SC1091
  eval "$(set -a; source ../demo.env; set +a; \
    printf 'CORP_DNS_PRIMARY=%q CORP_DNS_SECONDARY=%q PG_DOMAIN=%q PG_IP=%q COURIER_OLD_IP=%q' \
      "${CORP_DNS_PRIMARY:-}" "${CORP_DNS_SECONDARY:-}" "${PG_DOMAIN:-}" "${PG_IP:-}" "${COURIER_OLD_IP:-}")"
fi
PG_DOMAIN="${PG_DOMAIN:-api.pg.example}"
PG_IP="${PG_IP:-${COURIER_OLD_IP:-}}"
: "${CORP_DNS_PRIMARY:?CORP_DNS_PRIMARY 가 필요합니다 (demo.env)}"
: "${CORP_DNS_SECONDARY:?CORP_DNS_SECONDARY 가 필요합니다 (demo.env)}"
: "${PG_IP:?PG_IP 또는 COURIER_OLD_IP 가 필요합니다 (demo.env)}"

if [[ -n "${ENGINE:-}" ]]; then :
elif command -v podman >/dev/null; then ENGINE=podman
elif command -v docker >/dev/null; then ENGINE=docker
else echo "podman 또는 docker 가 필요합니다." >&2; exit 1; fi

mkdir -p "$RENDER"

# 레코드 목록: "<도메인> <IP>" 한 줄씩. 존 파일은 이 목록으로 만든다
RECORDS="$RENDER/records"

# 존 파일: 루트(.) 존을 맡아 모든 이름에 권한 있는 응답을 한다 → 목록에 없는 이름은 NXDOMAIN
write_zone() {
  touch "$RECORDS"
  {
    echo "\$ORIGIN ."
    echo "\$TTL 5"
    echo ".                 IN SOA ns1.corp.example. admin.corp.example. ( $(date +%s) 60 60 600 5 )"
    echo ".                 IN NS  ns1.corp.example."
    echo "ns1.corp.example. IN A   ${CORP_DNS_PRIMARY}"
    echo "ns2.corp.example. IN A   ${CORP_DNS_SECONDARY}"
    while read -r name ip_; do
      [[ -n "$name" ]] && echo "${name}.   IN A   ${ip_}"
    done < "$RECORDS"
  } > "$RENDER/db.corp.tmp"
  mv "$RENDER/db.corp.tmp" "$RENDER/db.corp"   # 원자적으로 교체 (reload 가 반쯤 쓴 파일을 읽지 않게)
}

record_add() {
  touch "$RECORDS"
  grep -v "^$1 " "$RECORDS" > "$RECORDS.tmp" || true
  echo "$1 ${PG_IP}" >> "$RECORDS.tmp"
  mv "$RECORDS.tmp" "$RECORDS"
  write_zone
}

record_remove() {
  touch "$RECORDS"
  grep -v "^$1 " "$RECORDS" > "$RECORDS.tmp" || true
  mv "$RECORDS.tmp" "$RECORDS"
  write_zone
}

write_corefile() {
  local role="$1" ip="$2"
  cat > "$RENDER/Corefile.$role" <<EOF
.:53 {
    bind ${ip}
    file /etc/coredns/db.corp . {
        reload 2s
    }
    log . "{remote} corp-dns-${role} {type} {name} {rcode} {duration}"
    errors
}
EOF
}

require_ip() {
  ip -4 -o addr show 2>/dev/null | grep -q " $1/" \
    || { echo "ERROR: $1 가 이 호스트에 없습니다. 먼저 'sudo ../courier-ext/setup-ips.sh add <NIC> $1/<prefix>'" >&2; exit 1; }
}

start_one() {
  local role="$1" ip="$2"
  write_corefile "$role" "$ip"
  "$ENGINE" rm -f "corp-dns-$role" >/dev/null 2>&1 || true
  "$ENGINE" run -d --name "corp-dns-$role" --network host --restart unless-stopped \
    -v "$PWD/$RENDER:/etc/coredns:ro,Z" \
    "$IMAGE" -conf "/etc/coredns/Corefile.$role" >/dev/null
}

# port_holder <IP> <포트> : 그 IP:포트를 듣고 있는 프로세스 (없으면 빈 문자열)
port_holder() {
  ss -Hlnup 2>/dev/null | awk -v a="$1:$2" '{for (i = 1; i <= NF; i++) if ($i == a) { print $NF; exit }}'
}

has_record() { grep -q "^$1 " "$RECORDS" 2>/dev/null; }

case "${1:-status}" in
  up)
    require_ip "$CORP_DNS_PRIMARY"; require_ip "$CORP_DNS_SECONDARY"
    "$ENGINE" rm -f corp-dns-primary corp-dns-secondary >/dev/null 2>&1 || true
    sleep 1
    if ss -Hlnu 2>/dev/null | awk '{print $4}' | grep -qE '^(0\.0\.0\.0|\*|\[::\]):53$'; then
      echo "ERROR: 다른 프로그램이 모든 IP 의 53/udp 를 쓰고 있습니다 (sudo ss -lunp | grep ':53 ')." >&2
      echo "       README 5-5b '53 을 이미 다른 프로그램이 쓰고 있을 때' 참고." >&2
      exit 1
    fi
    for ip_ in "$CORP_DNS_PRIMARY" "$CORP_DNS_SECONDARY"; do
      holder="$(port_holder "$ip_" 53)"
      if [[ -n "$holder" ]]; then
        echo "ERROR: ${ip_}:53 을 이미 다른 프로세스가 쓰고 있습니다: ${holder}" >&2
        if [[ "$holder" == *named* ]]; then
          echo "       bastion 의 named(BIND) 는 listen-on 이 any 면 새로 붙인 IP 의 53 도 자동으로 잡습니다." >&2
          echo "       /etc/named.conf 의 listen-on 을 named 가 원래 쓰던 IP 로 좁히세요 (README 5-5b '53 을 bastion 의 named 가 쓰는 경우')." >&2
        fi
        exit 1
      fi
    done
    [[ -s "$RECORDS" ]] || echo "${PG_DOMAIN} ${PG_IP}" > "$RECORDS"   # 처음 기동: PG 도메인 등록
    write_zone
    start_one primary "$CORP_DNS_PRIMARY"
    start_one secondary "$CORP_DNS_SECONDARY"
    sleep 2
    "$ENGINE" ps --filter name=corp-dns --format '{{.Names}}\t{{.Status}}'
    echo "사내 DNS: primary ${CORP_DNS_PRIMARY}, secondary ${CORP_DNS_SECONDARY}  |  ${PG_DOMAIN} → ${PG_IP}"
    ;;
  down)
    "$ENGINE" rm -f corp-dns-primary corp-dns-secondary >/dev/null 2>&1 || true
    command -v nft >/dev/null && nft delete table inet corpdns_demo 2>/dev/null || true
    echo "사내 DNS 정지"
    ;;
  status)
    "$ENGINE" ps -a --filter name=corp-dns --format '{{.Names}}\t{{.Status}}'
    if "$ENGINE" inspect -f '{{.State.Status}}' corp-dns-primary 2>/dev/null | grep -q paused \
       || { command -v nft >/dev/null && nft list table inet corpdns_demo >/dev/null 2>&1; }; then
      echo "주 DNS: 응답 중지 상태 (primary-down)"
    fi
    echo "등록된 레코드:"; sed 's/^/  /; s/ \([0-9.]*\)$/ → \1/' "$RECORDS" 2>/dev/null || echo "  (없음)"
    ;;
  logs)
    "$ENGINE" logs -f "corp-dns-${2:-primary}"
    ;;
  record-remove)
    record_remove "${2:-$PG_DOMAIN}"
    echo "사내 DNS 에서 ${2:-$PG_DOMAIN} 레코드 삭제 → 2초 안에 NXDOMAIN"
    ;;
  record-add)
    record_add "${2:-$PG_DOMAIN}"
    echo "사내 DNS 에 ${2:-$PG_DOMAIN} → ${PG_IP} 레코드 등록 (2초 안에 반영)"
    ;;
  records)
    sed 's/ / → /' "$RECORDS" 2>/dev/null || echo "(없음)"
    ;;
  primary-down)
    # 1순위: 일시정지 — 소켓은 남아 있지만 응답하지 않는다 → 클라이언트는 타임아웃 후 보조 DNS 로 넘어간다
    if "$ENGINE" pause corp-dns-primary >/dev/null 2>&1; then
      echo "주 DNS(${CORP_DNS_PRIMARY}) 응답 중지 (일시정지) — 질의는 타임아웃됩니다"
    elif command -v nft >/dev/null; then
      # 2순위(일시정지를 못 하는 호스트): 주 DNS IP 의 53 으로 들어오는 패킷만 버린다 (데모 전용 테이블, 다른 규칙·IP 는 그대로)
      nft -f - <<EOF
table inet corpdns_demo {
  chain input {
    type filter hook input priority -10; policy accept;
    ip daddr ${CORP_DNS_PRIMARY} udp dport 53 drop
    ip daddr ${CORP_DNS_PRIMARY} tcp dport 53 drop
  }
}
EOF
      echo "주 DNS(${CORP_DNS_PRIMARY}) 응답 중지 (nftables drop, 테이블 inet corpdns_demo) — 질의는 타임아웃됩니다"
    else
      echo "ERROR: 컨테이너 일시정지도 nft 도 쓸 수 없습니다." >&2
      exit 1
    fi
    ;;
  primary-up)
    "$ENGINE" unpause corp-dns-primary >/dev/null 2>&1 || true
    command -v nft >/dev/null && nft delete table inet corpdns_demo 2>/dev/null || true
    echo "주 DNS(${CORP_DNS_PRIMARY}) 복구"
    ;;
  *)
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
