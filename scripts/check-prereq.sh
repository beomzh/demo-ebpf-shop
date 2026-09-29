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
      | grep -Eo '(ovnkube-node|calico-node|canal|cilium|antrea-agent|kube-router|weave-net|kube-ovn-cni)' | sort -u | tr '\n' ' ' || true)
if [[ -n "$cni" ]]; then
  ok "  감지: $cni"
else
  warn "  OVN-Kubernetes/Calico/Cilium 등 NetworkPolicy 지원 CNI 를 찾지 못했습니다. (flannel 단독이면 방화벽 차단이 동작하지 않음)"; fail=1
fi

info "3) OpenTelemetry 에이전트/SDK 가 섞여 있지 않은지 (eBPF 데이터만 보이게)"
if kc -n "$APP_NS" get pods -o yaml 2>/dev/null | grep -Eqi 'opentelemetry|otel|javaagent'; then
  warn "  demo-shop 네임스페이스 파드에 OpenTelemetry/javaagent 흔적이 있습니다."; fail=1
else
  ok "  없음"
fi

info "4) 택배사 IP 로 443 연결 (방화벽 적용 전 경로 확인)"
# demo.env.example 의 예시 IP 를 그대로 쓰고 있으면 먼저 알려준다
for ip in "$COURIER_OLD_IP" "$COURIER_NEW_IP"; do
  if [[ "$ip" == 10.0.0.61 || "$ip" == 10.0.0.62 ]]; then
    warn "  demo.env 의 택배사 IP(${ip})가 예시값입니다. 실제 택배사 호스트 IP 로 바꿨는지 확인하세요."
  fi
done

# 실패 메시지를 보고 원인을 추정한다
probe_hint() {
  # curl 자체의 실패를 먼저 판별한다 (curl 이 실패하면 점검 파드도 Error 로 끝나므로, 파드 문제로 오판하지 않게)
  case "$1" in
    *"violates PodSecurity"*)
      echo "점검 파드가 Pod Security 정책에 막힘 → 스크립트를 최신으로 (git pull)" ;;
    *"Connection timed out"*|*"Operation timed out"*|*"timed out after"*|*"Timeout was reached"*)
      echo "응답 없음(타임아웃) → IP 오타, 택배사 호스트에 IP 가 붙어 있는지, 경로상 방화벽·라우팅 확인" ;;
    *"Connection refused"*|*"연결이 거부됨"*|*"Could not connect to server"*)
      echo "연결 거부 → 그 IP 까지는 닿지만 443 에서 nginx 가 안 떠 있음 (택배사 호스트: ./courier-ext/run.sh up / status)" ;;
    *"No route to host"*|*"Network is unreachable"*|*"Host is unreachable"*)
      echo "경로 없음 → 노드에서 해당 IP 대역으로 라우팅이 되는지 확인" ;;
    *"HTTP 404"*|*"HTTP 5"*)
      echo "다른 웹서버가 응답함 → 그 IP:443 이 이 데모의 nginx 가 아님. PG_IP 는 nginx 가 듣는 IP(비우면 COURIER_OLD_IP)여야 함" ;;
    *"timed out waiting"*|*ImagePull*|*ErrImage*)
      echo "테스트 파드가 뜨지 못함 → 노드가 docker.io 이미지를 받을 수 있는지 확인 (README 12. 폐쇄망)" ;;
    *) echo "위 메시지를 확인하세요" ;;
  esac
}

# 점검 파드 출력에서 kubectl 의 부가 메시지를 지운다 (파드 종료 알림, attach 경고)
clean_probe() {
  printf '%s' "$1" | grep -vE "^pod .* (deleted|terminated)|couldn't attach to pod" \
    | sed -E 's/pod [a-z-]+\/[a-z0-9-]+ terminated \(Error\)//g' | tr '\n' ' ' | sed 's/  */ /g; s/ $//'
}

# 4-a) 작업 PC(클러스터 밖)에서
if command -v curl >/dev/null; then
  for ip in "$COURIER_OLD_IP" "$COURIER_NEW_IP"; do
    out="$(LC_ALL=C curl -sSk -m 5 -o /dev/null -w 'HTTP %{http_code}' --resolve "${COURIER_DOMAIN}:443:${ip}" \
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
  out="$(probe courier-probe docker.io/curlimages/curl:8.10.1 \
         sh -c "curl -sSk -m 5 -o /dev/null -w 'HTTP %{http_code}' --resolve '${COURIER_DOMAIN}:443:${ip}' 'https://${COURIER_DOMAIN}/health' 2>&1" \
         2>&1 || true)"
  out="$(clean_probe "$out")"
  if [[ "$out" == *"HTTP 200"* ]]; then
    ok "  [클러스터 → 택배사] ${ip}:443 응답 OK"
  else
    warn "  [클러스터 → 택배사] ${ip}:443 실패: ${out:-출력 없음}"
    warn "      → $(probe_hint "$out")"
    fail=1
  fi
done

info "5) 사내 DNS (${CORP_DNS_MODE} 모드) 와 외부 PG — 클러스터 안(임시 파드)에서"
dns_ips=("$CORP_DNS_PRIMARY" "$CORP_DNS_SECONDARY")
if [[ "$CORP_DNS_MODE" == cluster ]]; then
  # 사내 DNS 파드는 결제 서비스만 들어올 수 있으므로(demo-infra 인바운드 기본 차단) 결제 파드에서 조회한다
  dns_ips=()
  if [[ -z "$CORP_DNS_PRIMARY" ]] || ! kc -n "$APP_NS" get deploy payment-service >/dev/null 2>&1; then
    info "  cluster 모드: 사내 DNS 파드(${CORP_DNS_PRIMARY_NAME}, ${CORP_DNS_SECONDARY_NAME})는 deploy 때 만들어집니다 (조회 점검은 배포 후 다시 check)"
  else
    while read -r role server result _; do
      if [[ "$result" == *"$PG_IP"* ]]; then
        ok "  [결제 → 사내 DNS ${role} ${server}] ${PG_DOMAIN} → ${result} OK"
      else
        warn "  [결제 → 사내 DNS ${role} ${server}] ${PG_DOMAIN} 조회 실패: ${result}"
        warn "      → './demo.sh corpdns status' 로 파드·레코드·주 DNS 차단 여부 확인 ('./demo.sh pg-reset' 으로 복구)"
        fail=1
      fi
    done < <(pg_dns_query "$PG_DOMAIN" 2>&1 || echo "? payment-service exec-실패 -")
  fi
fi
for dns_ip in ${dns_ips[@]+"${dns_ips[@]}"}; do
  out="$(probe corpdns-probe docker.io/library/busybox:1.36 \
         nslookup -type=a -timeout=2 "$PG_DOMAIN" "$dns_ip" 2>&1 || true)"
  if printf '%s' "$out" | grep -q "Address: ${PG_IP}\b"; then
    ok "  [클러스터 → 사내 DNS ${dns_ip}] ${PG_DOMAIN} → ${PG_IP} OK"
  else
    warn "  [클러스터 → 사내 DNS ${dns_ip}] ${PG_DOMAIN} 조회 실패: $(clean_probe "$(printf '%s\n' "$out" | grep -vE '^(Server:|Address:.*[#:]53$|$)')")"
    if [[ "$CORP_DNS_MODE" == bastion ]]; then
      warn "      → bastion 에서 './demo.sh corpdns up' 했는지, IP 가 붙어 있는지 확인 (README 5-5b)"
    else
      warn "      → 사내 DNS 에 ${PG_DOMAIN} → ${PG_IP} A 레코드 등록, 노드에서 ${dns_ip}:53/udp 로 갈 수 있는지 확인 (README 5-5b)"
    fi
    fail=1
  fi
done
out="$(probe pg-probe docker.io/curlimages/curl:8.10.1 \
       sh -c "curl -sSk -m 5 -o /dev/null -w 'HTTP %{http_code}' --resolve '${PG_DOMAIN}:443:${PG_IP}' 'https://${PG_DOMAIN}/health' 2>&1" \
       2>&1 || true)"
if [[ "$out" == *"HTTP 200"* ]]; then
  ok "  [클러스터 → PG] ${PG_IP}:443 (${PG_DOMAIN}) 응답 OK"
else
  out="$(clean_probe "$out")"
  warn "  [클러스터 → PG] ${PG_IP}:443 실패: ${out}"
  warn "      → $(probe_hint "$out")"
  fail=1
fi

info "6) 인증서"
[[ -f "$ROOT/courier-ext/certs/pg.crt" ]] && ok "  courier-ext/certs/pg.crt 있음" \
  || { warn "  courier-ext/certs/pg.crt 없음 — './demo.sh certs' 후 './courier-ext/run.sh up' 으로 nginx 재기동"; fail=1; }
if [[ -f "$ROOT/courier-ext/certs/ca.crt" ]]; then ok "  courier-ext/certs/ca.crt 있음 (지문 $(ca_fingerprint))"
else warn "  courier-ext/certs/ca.crt 없음 — './demo.sh certs' 필요 (없으면 배포가 중단됩니다)"; fail=1; fi

# 클러스터 시크릿의 CA 가 지금 CA 와 같은지 (다르면 파드가 'unable to get local issuer certificate' 로 실패)
secret_ca="$(kc -n "$APP_NS" get secret courier-ca -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)"
if [[ -n "$secret_ca" ]]; then
  tmp_ca="$(mktemp)"; printf '%s' "$secret_ca" | base64 -d > "$tmp_ca" 2>/dev/null || true
  if [[ "$(ca_fingerprint "$tmp_ca")" == "$(ca_fingerprint)" ]]; then
    ok "  클러스터 시크릿 courier-ca = 지금 CA"
  else
    warn "  클러스터 시크릿 courier-ca($(ca_fingerprint "$tmp_ca")) 가 지금 CA($(ca_fingerprint)) 와 다름 → './demo.sh deploy' (CA 를 쓰는 파드가 자동 재시작됨)"
    fail=1
  fi
  rm -f "$tmp_ca"
fi

# nginx 가 내미는 택배사·PG 인증서가 지금 CA 로 검증되는지 (작업 PC 에서)
for pair in "${COURIER_DOMAIN}:${COURIER_OLD_IP}" "${PG_DOMAIN}:${PG_IP}"; do
  d="${pair%%:*}"; ip_="${pair#*:}"
  [[ -f "$ROOT/courier-ext/certs/ca.crt" ]] || break
  if out="$(LC_ALL=C curl -sS -m 5 -o /dev/null --cacert "$ROOT/courier-ext/certs/ca.crt" --resolve "${d}:443:${ip_}" "https://${d}/health" 2>&1)"; then
    ok "  [작업 PC] https://${d} (${ip_}) 인증서 검증 OK"
  else
    warn "  [작업 PC] https://${d} (${ip_}) 인증서 검증 실패: ${out%%$'\n'*}"
    warn "      → './demo.sh certs' 후 './courier-ext/run.sh up' (nginx 가 옛 인증서·다른 CA 인증서를 쓰는 중)"
    fail=1
  fi
done

(( fail == 0 )) && ok "점검 통과" || die "점검 항목을 확인하세요."
