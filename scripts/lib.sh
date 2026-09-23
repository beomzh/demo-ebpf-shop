#!/usr/bin/env bash
# 공통 함수: demo.env 로드, 클러스터 CLI(oc/kubectl)·컨테이너 엔진(podman/docker) 선택,
#            이미지 레지스트리 주소 계산, 매니페스트 렌더링, 로그 출력
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NS=shop
INFRA_NS=demo-infra
FW_LABEL=demo.observ/firewall=egress
SERVICES=(member-service product-service order-service payment-service delivery-service)

# OpenShift 내부 이미지 레지스트리
OCP_REGISTRY_NS=openshift-image-registry
OCP_REGISTRY_SVC=image-registry.openshift-image-registry.svc:5000   # 클러스터 안에서 pull 할 때 주소

info()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()    { printf '\033[1;32m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn()  { printf '\033[1;33m[%s] WARN\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()   { printf '\033[1;31m[%s] ERROR\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

load_env() {
  local f="${DEMO_ENV:-$ROOT/demo.env}"
  [[ -f "$f" ]] || die "$f 가 없습니다. 'cp demo.env.example demo.env' 후 값을 채우세요."
  # shellcheck disable=SC1090
  set -a; source "$f"; set +a
  : "${TAG:?}" "${COURIER_DOMAIN:?}" "${COURIER_OLD_IP:?}" "${COURIER_NEW_IP:?}"
  : "${CLI:=auto}" "${REGISTRY_MODE:=ocp-internal}" "${REGISTRY:=}"
  : "${CONTAINER_ENGINE:=auto}" "${REGISTRY_TLS_VERIFY:=false}" "${PLATFORM:=linux/amd64}"
  : "${LOADGEN_ORDER_INTERVAL:=1}" "${LOADGEN_TRACKING_INTERVAL:=1}"
  [[ "$COURIER_OLD_IP" != "$COURIER_NEW_IP" ]] || die "COURIER_OLD_IP 와 COURIER_NEW_IP 가 같습니다."
  case "$REGISTRY_MODE" in
    ocp-internal) ;;
    external) [[ -n "$REGISTRY" ]] || die "REGISTRY_MODE=external 이면 REGISTRY 를 채워야 합니다." ;;
    *) die "REGISTRY_MODE 는 ocp-internal 또는 external 이어야 합니다 (현재: $REGISTRY_MODE)" ;;
  esac
  KC="$(detect_cli)"
  if [[ "$REGISTRY_MODE" == ocp-internal && "$KC" != oc ]]; then
    die "REGISTRY_MODE=ocp-internal 은 oc CLI 가 필요합니다 (현재 CLI: $KC)."
  fi
}

# ── 클러스터 CLI ─────────────────────────────────────────────
# CLI=oc|kubectl|auto (auto: oc 가 있으면 oc, 없으면 kubectl)
detect_cli() {
  case "${CLI:-auto}" in
    oc|kubectl)
      command -v "$CLI" >/dev/null || die "CLI=$CLI 인데 명령을 찾을 수 없습니다."
      echo "$CLI" ;;
    auto)
      if command -v oc >/dev/null; then echo oc
      elif command -v kubectl >/dev/null; then echo kubectl
      else die "oc 또는 kubectl 이 필요합니다."; fi ;;
    *) die "CLI 는 oc, kubectl, auto 중 하나여야 합니다 (현재: $CLI)" ;;
  esac
}

# 모든 스크립트는 kubectl/oc 대신 kc 를 쓴다
kc() { "$KC" "$@"; }

# ── 컨테이너 엔진 ────────────────────────────────────────────
# CONTAINER_ENGINE=podman|docker|auto (auto: podman 우선, 없으면 docker)
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

# ── 이미지 레지스트리 ────────────────────────────────────────
# push 주소와 pull 주소가 다르다 (ocp-internal):
#   push : 클러스터 밖(작업 PC)에서 → default route   <route-host>/shop/<이미지>
#   pull : 클러스터 안(노드)에서    → 내부 서비스     image-registry.openshift-image-registry.svc:5000/shop/<이미지>
# 이미지를 push 하면 shop 네임스페이스의 같은 이름 ImageStream 에 태그가 쌓인다.
registry_route_host() {
  kc -n "$OCP_REGISTRY_NS" get route default-route -o jsonpath='{.spec.host}' 2>/dev/null || true
}

push_registry() {
  if [[ "$REGISTRY_MODE" == ocp-internal ]]; then
    local host; host="$(registry_route_host)"
    [[ -n "$host" ]] || die "내부 레지스트리 default route 가 없습니다. './demo.sh registry-route' 를 먼저 실행하세요 (cluster-admin)."
    echo "${host}/${APP_NS}"
  else
    echo "$REGISTRY"
  fi
}

pull_registry() {
  if [[ "$REGISTRY_MODE" == ocp-internal ]]; then echo "${OCP_REGISTRY_SVC}/${APP_NS}"; else echo "$REGISTRY"; fi
}

image_name() { echo "shop-$1"; }   # 서비스명 → 이미지(ImageStream) 이름

dashed() { echo "${1//./-}"; }

# render <manifest> [COURIER_DNS_IP] → stdout
render() {
  local reg; reg="$(pull_registry)"
  sed \
    -e "s#__REGISTRY__#${reg}#g" \
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
  kc -n "$INFRA_NS" get svc courier-dns -o jsonpath='{.spec.clusterIP}'
}
