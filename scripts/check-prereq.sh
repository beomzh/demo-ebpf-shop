#!/usr/bin/env bash
# 데모 전 환경 점검: 커널 버전, NetworkPolicy 지원 CNI, 택배사 호스트 도달 여부
source "$(dirname "$0")/lib.sh"
load_env

fail=0

if kc api-resources --api-group=security.openshift.io 2>/dev/null | grep -q securitycontextconstraints; then
  ok "OpenShift 감지 — 앱 파드는 restricted-v2 SCC, Observ 노드 에이전트만 privileged SCC 필요"
fi

info "0) 클러스터 접속 (${KC})"
if who="$(kc whoami 2>/dev/null)"; then ok "  로그인: ${who}"; else who="$(kc config current-context 2>/dev/null || true)"; [[ -n "$who" ]] && ok "  context: ${who}" || { warn "  클러스터에 접속되어 있지 않습니다."; fail=1; }; fi
if [[ "$REGISTRY_MODE" == ocp-internal ]]; then
  host="$(registry_route_host)"
  if [[ -n "$host" ]]; then ok "  내부 레지스트리 route: ${host}"
  else warn "  내부 레지스트리 default route 없음 — './demo.sh registry-route' 필요 (cluster-admin)"; fail=1; fi
  if [[ -z "$(kc whoami -t 2>/dev/null || true)" ]]; then
    warn "  토큰 로그인이 아닙니다 — push 하려면 'oc login -u <사용자> <API URL>' 로 로그인하세요"; fail=1
  fi
fi

info "1) 노드 커널 버전 (eBPF 노드 에이전트: 4.16 이상, RHEL 8 이상)"
while read -r node kernel; do
  major="${kernel%%.*}"; rest="${kernel#*.}"; minor="${rest%%.*}"
  if (( major > 4 || (major == 4 && minor >= 16) )); then
    ok "  $node  $kernel"
  else
    warn "  $node  $kernel  ← 4.16 미만"; fail=1
  fi
done < <(kc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.nodeInfo.kernelVersion}{"\n"}{end}')

info "2) NetworkPolicy 를 집행하는 CNI (방화벽 역할)"
cni=$(kc get pods -A -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
      | grep -Eo '^(ovnkube-node|calico-node|cilium|antrea-agent|kube-router|weave-net)' | sort -u | tr '\n' ' ' || true)
if [[ -n "$cni" ]]; then
  ok "  감지: $cni"
else
  warn "  OVN-Kubernetes/Calico/Cilium 등 NetworkPolicy 지원 CNI 를 찾지 못했습니다. (flannel 단독이면 방화벽 차단이 동작하지 않음)"; fail=1
fi

info "3) OpenTelemetry 에이전트/SDK 가 섞여 있지 않은지 (eBPF 데이터만 보이게)"
if kc -n "$APP_NS" get pods -o yaml 2>/dev/null | grep -Eqi 'opentelemetry|otel|javaagent'; then
  warn "  shop 네임스페이스 파드에 OpenTelemetry/javaagent 흔적이 있습니다."; fail=1
else
  ok "  없음"
fi

info "4) 택배사 IP 로 443 연결 (방화벽 적용 전 경로 확인)"
# demo.env.example 의 예시 IP 를 그대로 쓰고 있으면 먼저 알려준다
for ip in "$COURIER_OLD_IP" "$COURIER_NEW_IP"; do
  if [[ "$ip" == 10.0.0.51 || "$ip" == 10.0.0.52 ]]; then
    warn "  demo.env 의 택배사 IP(${ip})가 예시값입니다. 실제 택배사 호스트 IP 로 바꿨는지 확인하세요."
  fi
done

# 실패 메시지를 보고 원인을 추정한다
probe_hint() {
  case "$1" in
    *"timed out waiting"*|*ImagePull*|*ErrImage*|*"pod default/"*)
      echo "테스트 파드가 뜨지 못함 → 노드가 docker.io 이미지를 받을 수 있는지 확인 (README 12. 폐쇄망)" ;;
    *"Connection timed out"*|*"Operation timed out"*|*"timed out after"*)
      echo "응답 없음(타임아웃) → IP 오타, 택배사 호스트에 IP 가 붙어 있는지, 경로상 방화벽·라우팅 확인" ;;
    *"Connection refused"*)
      echo "연결 거부 → IP 는 살아 있지만 443 에서 nginx 가 안 떠 있음 (택배사 호스트: sudo ./run.sh status)" ;;
    *"No route to host"*|*"Network is unreachable"*|*"Host is unreachable"*)
      echo "경로 없음 → 노드에서 해당 IP 대역으로 라우팅이 되는지 확인" ;;
    *"HTTP 404"*|*"HTTP 5"*)
      echo "다른 웹서버가 응답함 → 그 IP 의 443 을 택배사 nginx 가 쓰고 있는지 확인" ;;
    *) echo "위 메시지를 확인하세요" ;;
  esac
}

# 4-a) 작업 PC(클러스터 밖)에서
if command -v curl >/dev/null; then
  for ip in "$COURIER_OLD_IP" "$COURIER_NEW_IP"; do
    out="$(curl -sSk -m 5 -o /dev/null -w 'HTTP %{http_code}' --resolve "${COURIER_DOMAIN}:443:${ip}" \
           "https://${COURIER_DOMAIN}/health" 2>&1 || true)"
    out="$(printf '%s' "$out" | tr '\n' ' ' | sed 's/  */ /g; s/ $//')"
    if [[ "$out" == *"HTTP 200"* ]]; then
      ok "  [작업 PC → 택배사] ${ip}:443 응답 OK"
    else
      warn "  [작업 PC → 택배사] ${ip}:443 실패: ${out}"
      warn "      → $(probe_hint "$out")"
    fi
  done
fi

# 4-b) 클러스터 안(임시 파드)에서 — 이 결과가 통과해야 한다
for ip in "$COURIER_OLD_IP" "$COURIER_NEW_IP"; do
  out="$(kc run "courier-probe-$RANDOM" -n default --rm -i --restart=Never --quiet \
         --pod-running-timeout=90s --image=docker.io/curlimages/curl:8.10.1 -- \
         sh -c "curl -sSk -m 5 -o /dev/null -w 'HTTP %{http_code}' --resolve '${COURIER_DOMAIN}:443:${ip}' 'https://${COURIER_DOMAIN}/health' 2>&1" \
         2>&1 || true)"
  out="$(printf '%s' "$out" | grep -v '^pod .* deleted' | tr '\n' ' ' | sed 's/  */ /g; s/ $//')"
  if [[ "$out" == *"HTTP 200"* ]]; then
    ok "  [클러스터 → 택배사] ${ip}:443 응답 OK"
  else
    warn "  [클러스터 → 택배사] ${ip}:443 실패: ${out:-출력 없음}"
    warn "      → $(probe_hint "$out")"
    fail=1
  fi
done

info "5) 택배사 인증서"
if [[ -f "$ROOT/courier-ext/certs/ca.crt" ]]; then ok "  courier-ext/certs/ca.crt 있음"
else warn "  courier-ext/certs/ca.crt 없음 — './demo.sh certs' 필요 (없으면 배포가 중단됩니다)"; fail=1; fi

(( fail == 0 )) && ok "점검 통과" || die "점검 항목을 확인하세요."
