#!/usr/bin/env bash
# 외부 택배사 API(nginx) 기동/정지. docker 와 podman 모두 지원한다.
#   sudo ./run.sh up | down | logs | status
#
# nginx 가 443 을 받을 IP:
#   1) LISTEN_IPS 환경변수 (공백 구분)          sudo LISTEN_IPS="192.168.200.61 192.168.200.62" ./run.sh up
#   2) 없으면 ../demo.env 의 COURIER_OLD_IP, COURIER_NEW_IP  (bastion 을 택배사 호스트로 쓸 때)
#   3) 둘 다 없으면 호스트의 모든 IP (0.0.0.0:443)
# haproxy 등 다른 프로그램이 443 을 쓰는 호스트에서는 1) 또는 2) 로 IP 를 지정해야 충돌하지 않는다.
#
# - host 네트워크로 뜬다. 지정한 IP 는 호스트에 미리 붙어 있어야 한다 (setup-ips.sh).
# - 443 은 특권 포트이므로 root 로 실행한다 (rootless podman 은 443 바인딩 불가).
# - RHEL 등 SELinux 환경을 위해 볼륨에 :Z 라벨을 붙인다.
# - 엔진 강제 지정: ENGINE=podman|docker (기본: podman 우선, 없으면 docker)
set -euo pipefail

cd "$(dirname "$0")"
IMAGE=docker.io/library/nginx:1.27-alpine
NAME=courier-api
RENDERED=.nginx.rendered.conf

if [[ -n "${ENGINE:-}" ]]; then :
elif command -v podman >/dev/null; then ENGINE=podman
elif command -v docker >/dev/null; then ENGINE=docker
else echo "podman 또는 docker 가 필요합니다." >&2; exit 1; fi

# 택배사 도메인: COURIER_DOMAIN 환경변수 → ../demo.env → 기본값
courier_domain() {
  if [[ -n "${COURIER_DOMAIN:-}" ]]; then echo "$COURIER_DOMAIN"; return; fi
  if [[ -f ../demo.env ]]; then
    # shellcheck disable=SC1091
    ( set -a; source ../demo.env; echo "${COURIER_DOMAIN:-api.courier.example}" )
  else
    echo api.courier.example
  fi
}

listen_ips() {
  if [[ -n "${LISTEN_IPS:-}" ]]; then echo "$LISTEN_IPS"; return; fi
  if [[ -f ../demo.env ]]; then
    # shellcheck disable=SC1091
    ( set -a; source ../demo.env; echo "${COURIER_OLD_IP:-} ${COURIER_NEW_IP:-}" )
  fi
}

render_conf() {
  local ips="$1" ip
  if [[ -z "${ips// /}" ]]; then
    cp nginx.conf "$RENDERED"
    set_courier_domain
    echo "listen: 0.0.0.0:443 (모든 IP)"
    return
  fi
  local holder
  for ip in $ips; do
    ip -4 -o addr show 2>/dev/null | grep -q " ${ip}/" \
      || { echo "ERROR: ${ip} 가 이 호스트에 없습니다. 먼저 'sudo ./setup-ips.sh add <NIC> ${ip}/<prefix>'" >&2; exit 1; }
    holder="$(ss -Hlntp 2>/dev/null | awk -v a="${ip}:443" -v w="0.0.0.0:443" '{for (i = 1; i <= NF; i++) if ($i == a || $i == w || $i == "*:443") { print $NF; exit }}')"
    if [[ -n "$holder" ]]; then
      echo "ERROR: ${ip}:443 (또는 모든 IP 의 443) 을 이미 다른 프로세스가 쓰고 있습니다: ${holder}" >&2
      echo "       README 5-5 '443 을 이미 다른 프로그램이 쓰고 있을 때' 참고." >&2
      exit 1
    fi
  done
  # nginx.conf 의 'listen 443 ssl;' 한 줄을 IP 별 listen 줄로 바꾼다
  awk -v ips="$ips" '
    /^[[:space:]]*listen 443 ssl;/ {
      n = split(ips, a, " ")
      for (i = 1; i <= n; i++) printf "        listen %s:443 ssl;\n", a[i]
      next
    }
    { print }
  ' nginx.conf > "$RENDERED"
  set_courier_domain
  echo "listen: $(echo $ips | sed 's/ /:443, /g'):443"
}

# 택배사 서버 블록의 server_name 을 실제 도메인으로 (TLS SNI 로 블록을 고르므로 다르면 PG 인증서가 나간다)
set_courier_domain() {
  local d; d="$(courier_domain)"
  sed -i.bak "s#server_name api\.courier\.example;#server_name ${d};#" "$RENDERED" && rm -f "$RENDERED.bak"
  echo "courier domain: ${d}"
}

case "${1:-up}" in
  up)
    [[ -f certs/courier.crt && -f certs/courier.key ]] \
      || { echo "certs/ 에 인증서가 없습니다. 작업 PC 에서 './demo.sh certs' 후 복사하세요." >&2; exit 1; }
    "$ENGINE" rm -f "$NAME" >/dev/null 2>&1 || true   # 이전 것부터 지워야 포트 점검이 정확하다
    sleep 1
    render_conf "$(listen_ips)"
    "$ENGINE" run -d --name "$NAME" --network host --restart unless-stopped \
      -v "$PWD/$RENDERED:/etc/nginx/nginx.conf:ro,Z" \
      -v "$PWD/certs:/etc/nginx/certs:ro,Z" \
      "$IMAGE" >/dev/null
    sleep 2
    if "$ENGINE" ps --filter "name=$NAME" --filter status=running -q | grep -q .; then
      echo "[$ENGINE] $NAME started."
      echo "check: curl -sk --resolve $(courier_domain):443:<IP> https://$(courier_domain)/v1/tracking/T1"
    else
      echo "ERROR: $NAME 기동 실패. 로그:" >&2
      "$ENGINE" logs "$NAME" 2>&1 | tail -5 >&2
      exit 1
    fi
    ;;
  down)   "$ENGINE" rm -f "$NAME" ;;
  logs)   "$ENGINE" logs -f "$NAME" ;;
  status) "$ENGINE" ps --filter "name=$NAME" ;;
  *) echo "usage: $0 up|down|logs|status" >&2; exit 1 ;;
esac
