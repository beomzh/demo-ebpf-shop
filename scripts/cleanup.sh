#!/usr/bin/env bash
# 데모 리소스 전체 삭제 (shop, demo-infra 네임스페이스)
source "$(dirname "$0")/lib.sh"

read -r -p "shop, demo-infra 네임스페이스를 삭제합니다. 계속할까요? [y/N] " yn
[[ "$yn" =~ ^[Yy]$ ]] || { info "취소"; exit 0; }
kubectl delete namespace "$APP_NS" "$INFRA_NS" --ignore-not-found
ok "삭제 완료"
