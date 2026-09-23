#!/usr/bin/env bash
# 다섯 서비스 이미지를 빌드하고(--push 면) 레지스트리에 올린다.
#   ./scripts/build-images.sh            # 빌드만
#   ./scripts/build-images.sh --push     # 빌드 + push
#
# REGISTRY_MODE=ocp-internal (기본) 에서 --push 하면:
#   1) shop 네임스페이스 생성 (이미지는 이 네임스페이스의 ImageStream 에 저장된다)
#   2) ImageStream 5개 생성 (shop-member-service ...)
#   3) 내부 레지스트리 default route 로 로그인 (oc whoami -t 토큰, 표준입력으로 전달)
#   4) <route>/shop/shop-<서비스>:<TAG> 로 빌드·push
#   5) ImageStream 에 태그가 들어왔는지 확인
# 클러스터는 image-registry.openshift-image-registry.svc:5000/shop/... 에서 pull 한다 (deploy.sh).
#
# CONTAINER_ENGINE: podman(기본 우선) | docker
source "$(dirname "$0")/lib.sh"
load_env

push=false
[[ "${1:-}" == "--push" ]] && push=true

ENGINE="$(detect_engine)"

if $push; then
  REG="$(push_registry)"
else
  # 빌드만 할 때는 로컬 태그만 붙인다
  REG="localhost/${APP_NS}"
fi
info "engine=${ENGINE} cli=${KC} mode=${REGISTRY_MODE} platform=${PLATFORM} push=${push}"
info "image prefix: ${REG}"

registry_login() {
  local host="${REG%%/*}"
  if [[ "$REGISTRY_MODE" == ocp-internal ]]; then
    local user token
    user="$(kc whoami)" || die "oc 로그인이 필요합니다: oc login <API URL>"
    token="$(kc whoami -t 2>/dev/null || true)"
    [[ -n "$token" ]] || die "토큰이 없는 로그인입니다 (예: system:admin kubeconfig). 'oc login -u <사용자> <API URL>' 로 토큰 로그인 후 다시 실행하세요."
    info "registry login: ${host} (user: ${user})"
    if [[ "$ENGINE" == podman ]]; then
      printf '%s' "$token" | podman login -u "$user" --password-stdin --tls-verify="$REGISTRY_TLS_VERIFY" "$host" >/dev/null
    else
      printf '%s' "$token" | docker login -u "$user" --password-stdin "$host" >/dev/null
    fi
    ok "logged in to ${host}"
  else
    info "external registry: ${host} — 로그인은 미리 해 두세요 (${ENGINE} login ${host})"
  fi
}

prepare_imagestreams() {
  info "namespace ${APP_NS} / ImageStream 준비"
  kc apply -f "$ROOT/k8s/00-namespaces.yaml" >/dev/null
  for svc in "${SERVICES[@]}"; do
    kc -n "$APP_NS" create imagestream "$(image_name "$svc")" --dry-run=client -o yaml | kc apply -f - >/dev/null
  done
  ok "ImageStream: $(printf '%s ' "${SERVICES[@]/#/shop-}")"
}

build_one() {
  local image="$1" dir="$2"
  if [[ "$ENGINE" == podman ]]; then
    podman build --platform "$PLATFORM" -t "$image" "$dir"
    if $push; then podman push --tls-verify="$REGISTRY_TLS_VERIFY" "$image"; fi
  else
    if $push; then
      docker buildx build --platform "$PLATFORM" -t "$image" --push "$dir"
    else
      docker buildx build --platform "$PLATFORM" -t "$image" --load "$dir"
    fi
  fi
}

if $push; then
  [[ "$REGISTRY_MODE" == ocp-internal ]] && prepare_imagestreams
  registry_login
fi

for svc in "${SERVICES[@]}"; do
  image="${REG}/$(image_name "$svc"):${TAG}"
  info "build ${image}"
  build_one "$image" "$ROOT/services/$svc"
done

if $push && [[ "$REGISTRY_MODE" == ocp-internal ]]; then
  info "ImageStream 확인 (클러스터는 $(pull_registry)/<이름>:${TAG} 로 pull)"
  kc -n "$APP_NS" get imagestreams -o custom-columns='NAME:.metadata.name,TAGS:.status.tags[*].tag,PULL:.status.dockerImageRepository'
  for svc in "${SERVICES[@]}"; do
    kc -n "$APP_NS" get istag "$(image_name "$svc"):${TAG}" >/dev/null 2>&1 \
      || die "ImageStreamTag $(image_name "$svc"):${TAG} 가 없습니다. push 로그를 확인하세요."
  done
fi
ok "done"
