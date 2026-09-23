#!/usr/bin/env bash
# 다섯 서비스 이미지를 빌드한다.  --push 를 주면 레지스트리에 올린다.
#   ./scripts/build-images.sh            # 로컬 빌드만
#   ./scripts/build-images.sh --push     # 빌드 + push
source "$(dirname "$0")/lib.sh"
load_env

push=false
[[ "${1:-}" == "--push" ]] && push=true

for svc in member-service product-service order-service payment-service delivery-service; do
  image="${REGISTRY}/shop-${svc}:${TAG}"
  info "build ${image} (${PLATFORM})"
  if $push; then
    docker buildx build --platform "$PLATFORM" -t "$image" --push "$ROOT/services/$svc"
  else
    docker buildx build --platform "$PLATFORM" -t "$image" --load "$ROOT/services/$svc"
  fi
done
ok "done"
