#!/usr/bin/env bash
# 데모 리소스 전체 삭제 (shop, demo-infra 네임스페이스)
source "$(dirname "$0")/lib.sh"
load_env

echo "shop, demo-infra 네임스페이스를 삭제합니다."
[[ "$REGISTRY_MODE" == ocp-internal ]] && echo "shop 네임스페이스의 ImageStream(push 한 이미지)도 함께 삭제되어, 다시 배포하려면 push 부터 다시 해야 합니다."
read -r -p "계속할까요? [y/N] " yn
[[ "$yn" =~ ^[Yy]$ ]] || { info "취소"; exit 0; }
kc delete namespace "$APP_NS" "$INFRA_NS" --ignore-not-found
ok "삭제 완료"
