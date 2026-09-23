#!/usr/bin/env bash
# 공통 함수: demo.env 로드, 매니페스트 렌더링, 로그 출력
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NS=shop
INFRA_NS=demo-infra
FW_LABEL=demo.observ/firewall=egress

info()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()    { printf '\033[1;32m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn()  { printf '\033[1;33m[%s] WARN\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()   { printf '\033[1;31m[%s] ERROR\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

load_env() {
  local f="${DEMO_ENV:-$ROOT/demo.env}"
  [[ -f "$f" ]] || die "$f 가 없습니다. 'cp demo.env.example demo.env' 후 값을 채우세요."
  # shellcheck disable=SC1090
  set -a; source "$f"; set +a
  : "${REGISTRY:?}" "${TAG:?}" "${COURIER_DOMAIN:?}" "${COURIER_OLD_IP:?}" "${COURIER_NEW_IP:?}"
  : "${PLATFORM:=linux/amd64}" "${LOADGEN_ORDER_INTERVAL:=1}" "${LOADGEN_TRACKING_INTERVAL:=1}"
  : "${CONTAINER_ENGINE:=auto}" "${REGISTRY_TLS_VERIFY:=true}"
  [[ "$COURIER_OLD_IP" != "$COURIER_NEW_IP" ]] || die "COURIER_OLD_IP 와 COURIER_NEW_IP 가 같습니다."
}

# 컨테이너 엔진 결정: CONTAINER_ENGINE=docker|podman|auto (auto: podman 우선, 없으면 docker)
detect_engine() {
  case "${CONTAINER_ENGINE:-auto}" in
    docker|podman)
      command -v "$CONTAINER_ENGINE" >/dev/null || die "CONTAINER_ENGINE=$CONTAINER_ENGINE 인데 명령을 찾을 수 없습니다."
      echo "$CONTAINER_ENGINE" ;;
    auto)
      if command -v podman >/dev/null; then echo podman
      elif command -v docker >/dev/null; then echo docker
      else die "podman 또는 docker 가 필요합니다."; fi ;;
    *) die "CONTAINER_ENGINE 은 docker, podman, auto 중 하나여야 합니다 (현재: $CONTAINER_ENGINE)" ;;
  esac
}

dashed() { echo "${1//./-}"; }

# render <manifest> [COURIER_DNS_IP] → stdout
render() {
  sed \
    -e "s#__REGISTRY__#${REGISTRY}#g" \
    -e "s#__TAG__#${TAG}#g" \
    -e "s#__COURIER_DOMAIN__#${COURIER_DOMAIN}#g" \
    -e "s#__COURIER_OLD_IP_DASHED__#$(dashed "$COURIER_OLD_IP")#g" \
    -e "s#__COURIER_OLD_IP__#${COURIER_OLD_IP}#g" \
    -e "s#__COURIER_DNS_IP__#${2:-__COURIER_DNS_IP__}#g" \
    -e "s#__LOADGEN_ORDER_INTERVAL__#${LOADGEN_ORDER_INTERVAL}#g" \
    -e "s#__LOADGEN_TRACKING_INTERVAL__#${LOADGEN_TRACKING_INTERVAL}#g" \
    "$1"
}

courier_dns_ip() {
  kubectl -n "$INFRA_NS" get svc courier-dns -o jsonpath='{.spec.clusterIP}'
}
