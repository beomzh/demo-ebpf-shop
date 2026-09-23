#!/usr/bin/env bash
# 배포 후 보안 점검: 각 파드가 받은 SCC, 실행 UID, 보안 설정, 네트워크 정책
source "$(dirname "$0")/lib.sh"
load_env

fail=0
is_ocp=false
kc api-resources --api-group=security.openshift.io 2>/dev/null | grep -q securitycontextconstraints && is_ocp=true

for ns in "$APP_NS" "$INFRA_NS"; do
  info "[$ns] 파드별 SCC · UID · 보안 설정"
  printf '  %-34s %-16s %-12s %-6s %-6s %-6s %-6s\n' POD SCC UID ROOTFS PRIVESC CAPS SA_TOKEN
  while IFS=$'\t' read -r pod scc uid ro esc caps token; do
    [[ -z "$pod" ]] && continue
    printf '  %-34s %-16s %-12s %-6s %-6s %-6s %-6s\n' "$pod" "${scc:--}" "${uid:--}" "${ro:-false}" "${esc:-?}" "${caps:-?}" "${token:-true}"
    if $is_ocp && [[ "$scc" != restricted* ]]; then warn "  $pod: SCC 가 restricted 계열이 아님 ($scc)"; fail=1; fi
    [[ "$esc" == "false" ]] || { warn "  $pod: allowPrivilegeEscalation 이 false 가 아님"; fail=1; }
    [[ "$caps" == *ALL* ]] || { warn "  $pod: capabilities drop ALL 누락"; fail=1; }
    [[ "$token" == "false" ]] || { warn "  $pod: ServiceAccount 토큰이 마운트됨"; fail=1; }
  done < <(kc -n "$ns" get pods --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.openshift\.io/scc}{"\t"}{.spec.containers[0].securityContext.runAsUser}{"\t"}{.spec.containers[0].securityContext.readOnlyRootFilesystem}{"\t"}{.spec.containers[0].securityContext.allowPrivilegeEscalation}{"\t"}{.spec.containers[0].securityContext.capabilities.drop}{"\t"}{.spec.automountServiceAccountToken}{"\n"}{end}')
done

info "Pod Security 라벨"
kc get ns "$APP_NS" "$INFRA_NS" -o custom-columns='NS:.metadata.name,ENFORCE:.metadata.labels.pod-security\.kubernetes\.io/enforce'

info "네트워크 정책"
kc get netpol -n "$APP_NS" -o custom-columns='NAME:.metadata.name,TYPES:.spec.policyTypes' --no-headers | sed "s/^/  $APP_NS  /"
kc get netpol -n "$INFRA_NS" -o custom-columns='NAME:.metadata.name,TYPES:.spec.policyTypes' --no-headers | sed "s/^/  $INFRA_NS  /"

info "git 에 있으면 안 되는 것"
if git -C "$ROOT" ls-files | grep -Eq '(^|/)(demo\.env|.*\.key)$'; then
  warn "  demo.env 또는 개인키가 git 에 추적되고 있습니다."; fail=1
else
  ok "  demo.env · 개인키 미추적"
fi

(( fail == 0 )) && ok "보안 점검 통과" || die "보안 점검 항목을 확인하세요."
