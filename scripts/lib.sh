#!/usr/bin/env bash
# 공통 함수: demo.env 로드, 클러스터 CLI(oc/kubectl)·컨테이너 엔진(podman/docker) 선택,
#            이미지 레지스트리 주소 계산, 매니페스트 렌더링, 로그 출력
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NS=demo-shop
INFRA_NS=demo-infra
FW_LABEL=demo.observ/firewall=egress
SERVICES=(gateway-service member-service product-service inventory-service order-service payment-service notification-service delivery-service)

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
  : "${LOADGEN_ORDER_INTERVAL:=1}" "${LOADGEN_TRACKING_INTERVAL:=1}" "${LOADGEN_REPLICAS:=1}" "${LOADGEN_BROWSE_INTERVAL:=1}"
  [[ "$COURIER_OLD_IP" != "$COURIER_NEW_IP" ]] || die "COURIER_OLD_IP 와 COURIER_NEW_IP 가 같습니다."
  : "${PG_DOMAIN:=api.pg.example}" "${PG_IP:=}" "${CORP_DNS_MODE:=bastion}" "${PG_UNREGISTERED_DOMAIN:=api-new.pg.example}"
  : "${CORP_DNS_PRIMARY:=}" "${CORP_DNS_SECONDARY:=}"
  PG_IP="${PG_IP:-$COURIER_OLD_IP}"
  case "$CORP_DNS_MODE" in bastion|corporate) ;; *) die "CORP_DNS_MODE 는 bastion 또는 corporate 이어야 합니다 (현재: $CORP_DNS_MODE)" ;; esac
  [[ -n "$CORP_DNS_PRIMARY" && -n "$CORP_DNS_SECONDARY" ]] || die "demo.env 에 CORP_DNS_PRIMARY, CORP_DNS_SECONDARY 를 채우세요 (demo.env.example 참고)."
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

# OpenShift 여부 (SCC API 가 있으면 OpenShift). 한 번만 확인한다
is_ocp() {
  if [[ -z "${_IS_OCP:-}" ]]; then
    if kc api-resources --api-group=security.openshift.io 2>/dev/null | grep -q securitycontextconstraints; then
      _IS_OCP=yes
    else
      _IS_OCP=no
    fi
  fi
  [[ "$_IS_OCP" == yes ]]
}

# 점검용 임시 파드 실행: probe <이름> <이미지> <명령...>
# Pod Security "restricted" 를 강제하는 클러스터에서도 뜨도록 보안 설정을 붙인다.
# OpenShift 는 UID 를 자동 부여하므로 지정하지 않고, 그 밖의 쿠버네티스는 비 root UID(65532)를 지정한다.
probe() {
  local pod="$1-$RANDOM" image="$2"; shift 2
  local uid=''
  is_ocp || uid='"runAsUser":65532,'
  kc run "$pod" -n default --rm -i --restart=Never --quiet --pod-running-timeout=90s --image="$image" \
    --override-type=strategic \
    --overrides="{\"spec\":{\"securityContext\":{${uid}\"runAsNonRoot\":true,\"seccompProfile\":{\"type\":\"RuntimeDefault\"}},\"containers\":[{\"name\":\"${pod}\",\"securityContext\":{\"allowPrivilegeEscalation\":false,\"capabilities\":{\"drop\":[\"ALL\"]}}}]}}" \
    -- "$@"
}

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
#   push : 클러스터 밖(작업 PC)에서 → default route   <route-host>/demo-shop/<이미지>
#   pull : 클러스터 안(노드)에서    → 내부 서비스     image-registry.openshift-image-registry.svc:5000/demo-shop/<이미지>
# 이미지를 push 하면 demo-shop 네임스페이스의 같은 이름 ImageStream 에 태그가 쌓인다.
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
# __NONOCP_RUN_AS_USER__ : 이미지의 USER 가 숫자가 아닌 파드(loadgen, courier-dns)용.
#   OpenShift 는 UID 를 자동 부여하므로 줄을 지우고, 그 밖의 쿠버네티스는 runAsUser 를 넣는다
render() {
  local reg uid_rule; reg="$(pull_registry)"
  if is_ocp; then uid_rule='/__NONOCP_RUN_AS_USER__/d'; else uid_rule='s#__NONOCP_RUN_AS_USER__#runAsUser: 65532#'; fi
  sed \
    -e "$uid_rule" \
    -e "s#__REGISTRY__#${reg}#g" \
    -e "s#__TAG__#${TAG}#g" \
    -e "s#__COURIER_DOMAIN__#${COURIER_DOMAIN}#g" \
    -e "s#__COURIER_OLD_IP_DASHED__#$(dashed "$COURIER_OLD_IP")#g" \
    -e "s#__COURIER_OLD_IP__#${COURIER_OLD_IP}#g" \
    -e "s#__COURIER_DNS_IP__#${2:-__COURIER_DNS_IP__}#g" \
    -e "s#__LOADGEN_ORDER_INTERVAL__#${LOADGEN_ORDER_INTERVAL}#g" \
    -e "s#__LOADGEN_TRACKING_INTERVAL__#${LOADGEN_TRACKING_INTERVAL}#g" \
    -e "s#__LOADGEN_REPLICAS__#${LOADGEN_REPLICAS}#g" \
    -e "s#__LOADGEN_BROWSE_INTERVAL__#${LOADGEN_BROWSE_INTERVAL}#g" \
    -e "s#__PG_DOMAIN__#${PG_DOMAIN}#g" \
    -e "s#__PG_DNS_SERVERS__#${CORP_DNS_PRIMARY},${CORP_DNS_SECONDARY}#g" \
    "$1"
}

courier_dns_ip() {
  kc -n "$INFRA_NS" get svc courier-dns -o jsonpath='{.spec.clusterIP}'
}
