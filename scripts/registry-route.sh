#!/usr/bin/env bash
# OpenShift 내부 이미지 레지스트리의 default route 를 연다 (클러스터에 한 번만, cluster-admin 필요).
# 작업 PC 에서 podman push 할 주소가 된다: default-route-openshift-image-registry.apps.<클러스터 도메인>
source "$(dirname "$0")/lib.sh"
load_env

[[ "$REGISTRY_MODE" == ocp-internal ]] || die "REGISTRY_MODE=ocp-internal 에서만 사용합니다."

host="$(registry_route_host)"
if [[ -n "$host" ]]; then
  ok "default route 가 이미 있습니다: ${host}"
  exit 0
fi

info "configs.imageregistry.operator.openshift.io/cluster 에 defaultRoute=true 설정"
kc patch configs.imageregistry.operator.openshift.io/cluster --type merge -p '{"spec":{"defaultRoute":true}}' \
  || die "패치 실패 — cluster-admin 권한이 필요합니다. 관리자에게 요청하세요."

for _ in $(seq 1 30); do
  host="$(registry_route_host)"
  [[ -n "$host" ]] && break
  sleep 2
done
[[ -n "$host" ]] || die "route 가 생성되지 않았습니다: ${KC} -n ${OCP_REGISTRY_NS} get route"
ok "default route: ${host}"
