#!/usr/bin/env bash
# 다섯 서비스 이미지를 빌드한다.  --push 를 주면 레지스트리에 올린다.
#   ./scripts/build-images.sh            # 로컬 빌드만
#   ./scripts/build-images.sh --push     # 빌드 + push
#
# 컨테이너 엔진은 demo.env 의 CONTAINER_ENGINE 으로 고른다 (docker | podman | auto).
#   docker : docker buildx build (--load / --push)
#   podman : podman build → podman push  (OCP·RHEL 환경. rootless 가능)
# 빌드 호스트와 PLATFORM 아키텍처가 다르면 에뮬레이션(qemu-user-static)이 필요하다.
source "$(dirname "$0")/lib.sh"
load_env

push=false
[[ "${1:-}" == "--push" ]] && push=true

ENGINE="$(detect_engine)"
info "container engine: ${ENGINE}, platform: ${PLATFORM}, push: ${push}"

build_docker() {
  local image="$1" dir="$2"
  if $push; then
    docker buildx build --platform "$PLATFORM" -t "$image" --push "$dir"
  else
    docker buildx build --platform "$PLATFORM" -t "$image" --load "$dir"
  fi
}

build_podman() {
  local image="$1" dir="$2"
  podman build --platform "$PLATFORM" -t "$image" "$dir"
  if $push; then
    # OCP 내부 레지스트리 route 처럼 사설 인증서면 REGISTRY_TLS_VERIFY=false
    podman push --tls-verify="$REGISTRY_TLS_VERIFY" "$image"
  fi
}

for svc in member-service product-service order-service payment-service delivery-service; do
  image="${REGISTRY}/shop-${svc}:${TAG}"
  info "build ${image}"
  "build_${ENGINE}" "$image" "$ROOT/services/$svc"
done
ok "done"
