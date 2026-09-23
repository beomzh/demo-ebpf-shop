#!/usr/bin/env bash
# 외부 택배사 API(nginx) 기동/정지. docker 와 podman 모두 지원한다.
#   sudo ./run.sh up | down | logs | status
#   ENGINE=podman sudo -E ./run.sh up      # 엔진 강제 지정 (기본: podman 우선, 없으면 docker)
#
# - host 네트워크로 떠서 호스트의 예전 IP·새 IP 양쪽 443 을 받는다.
# - 443 은 특권 포트이므로 root 로 실행한다 (rootless podman 은 443 바인딩 불가).
# - RHEL 등 SELinux 환경을 위해 볼륨에 :Z 라벨을 붙인다.
set -euo pipefail

cd "$(dirname "$0")"
IMAGE=docker.io/library/nginx:1.27-alpine
NAME=courier-api

if [[ -n "${ENGINE:-}" ]]; then :
elif command -v podman >/dev/null; then ENGINE=podman
elif command -v docker >/dev/null; then ENGINE=docker
else echo "podman 또는 docker 가 필요합니다." >&2; exit 1; fi

[[ -f certs/courier.crt && -f certs/courier.key ]] || { echo "certs/ 에 인증서가 없습니다. 작업 PC 에서 'make certs' 후 복사하세요." >&2; exit 1; }

case "${1:-up}" in
  up)
    "$ENGINE" rm -f "$NAME" >/dev/null 2>&1 || true
    "$ENGINE" run -d --name "$NAME" --network host --restart unless-stopped \
      -v "$PWD/nginx.conf:/etc/nginx/nginx.conf:ro,Z" \
      -v "$PWD/certs:/etc/nginx/certs:ro,Z" \
      "$IMAGE"
    echo "[$ENGINE] $NAME started. check: curl -sk --resolve api.courier.example:443:<IP> https://api.courier.example/health"
    ;;
  down)   "$ENGINE" rm -f "$NAME" ;;
  logs)   "$ENGINE" logs -f "$NAME" ;;
  status) "$ENGINE" ps --filter "name=$NAME" ;;
  *) echo "usage: $0 up|down|logs|status" >&2; exit 1 ;;
esac
