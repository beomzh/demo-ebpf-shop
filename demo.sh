#!/usr/bin/env bash
# 데모 실행 진입점. make 없이 bash 만으로 모든 단계를 실행한다.
#   ./demo.sh help
set -euo pipefail
cd "$(dirname "$0")"
S=./scripts

usage() {
  cat <<'EOF'
사용법: ./demo.sh <명령>

[준비 — 순서대로 한 번]
  certs            택배사 사설 CA·서버 인증서 생성 (courier-ext/certs)
  registry-route   OpenShift 내부 레지스트리 default route 열기 (클러스터당 한 번, cluster-admin)
  check            사전 점검: 로그인·route·커널·CNI·택배사 도달·인증서
  push             이미지 빌드 → ImageStream 생성 → 내부 레지스트리 route 로 push
  deploy           클러스터에 배포 (정상 상태로 시작)
  security         배포 후 보안 점검 (SCC·securityContext·네트워크 정책)

[촬영]
  status           현재 상태 요약 (DNS 응답·연결 가능 여부·방화벽 규칙·배송 조회 1건)
  incident         사건 발생: 택배사가 IP 를 새 IP 로 변경
  firewall         방화벽 규칙 목록 (데모 3)
  fix              해결: 방화벽에 새 IP 허용 (데모 4)
  reset            다음 테이크 준비 (새 IP 규칙 삭제, DNS → 예전 IP)
  baseline         reset 과 같음
  traffic          부하 발생기 로그 실시간 보기 (Ctrl+C 로 종료)

[유지보수]
  build            이미지 빌드만 (push 안 함)
  restart          다섯 서비스 재시작 (같은 TAG 로 다시 push 한 뒤 반영할 때)
  images           ImageStream 과 태그 목록
  cleanup          shop, demo-infra 네임스페이스 삭제 (ImageStream 포함)

[로컬 스모크 테스트 — 클러스터 없이 podman/docker 로 앱만 확인]
  local-up | local-fail | local-heal | local-down
EOF
}

# ── 로컬 스모크 테스트 (demo.env 불필요) ─────────────────────
local_compose() {
  local engine="${ENGINE:-}"
  if [[ -z "$engine" ]]; then
    if command -v podman >/dev/null; then engine=podman
    elif command -v docker >/dev/null; then engine=docker
    else echo "podman 또는 docker 가 필요합니다." >&2; exit 1; fi
  fi
  # rootless podman 은 UID 를 65536 개만 매핑하므로 작은 UID 로 띄운다
  [[ "$engine" == podman ]] && export LOCAL_UID="${LOCAL_UID:-10001}"
  (cd local && "$engine" compose "$@")
}

cmd="${1:-help}"
shift || true

case "$cmd" in
  certs)          ./courier-ext/gen-certs.sh "$@" ;;
  registry-route) $S/registry-route.sh ;;
  check)          $S/check-prereq.sh ;;
  build)          $S/build-images.sh ;;
  push)           $S/build-images.sh --push ;;
  deploy)         $S/deploy.sh ;;
  security)       $S/security-check.sh ;;
  status|incident|fix|reset|baseline|firewall|traffic)
                  $S/scenario.sh "$cmd" ;;
  restart)
    source $S/lib.sh; load_env
    for svc in "${SERVICES[@]}"; do kc -n "$APP_NS" rollout restart "deploy/$svc"; done
    for svc in "${SERVICES[@]}"; do kc -n "$APP_NS" rollout status "deploy/$svc" --timeout=300s; done
    ;;
  images)
    source $S/lib.sh; load_env
    kc -n "$APP_NS" get imagestreams -o custom-columns='NAME:.metadata.name,TAGS:.status.tags[*].tag,PULL-ADDRESS:.status.dockerImageRepository'
    ;;
  cleanup)        $S/cleanup.sh ;;
  local-up)       ./courier-ext/gen-certs.sh && local_compose up -d --build ;;
  local-fail)     COURIER_IP=10.255.255.1 local_compose up -d delivery-service ;;
  local-heal)     local_compose up -d delivery-service ;;
  local-down)     local_compose down -v ;;
  help|-h|--help) usage ;;
  *) echo "알 수 없는 명령: $cmd" >&2; usage; exit 1 ;;
esac
