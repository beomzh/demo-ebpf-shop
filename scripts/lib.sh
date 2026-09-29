#!/usr/bin/env bash
# 공통 함수: demo.env 로드, 클러스터 CLI(oc/kubectl)·컨테이너 엔진(podman/docker) 선택,
#            이미지 레지스트리 주소 계산, 매니페스트 렌더링, 로그 출력
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NS=demo-shop
INFRA_NS=demo-infra
FW_LABEL=demo.observ/firewall=egress
# 사내 DNS 파드 — k8s/45-corp-dns.yaml
CORP_DNS_PRIMARY_NAME=ns1-corp-dns
CORP_DNS_SECONDARY_NAME=ns2-corp-dns
SERVICES=(gateway-service member-service product-service inventory-service order-service payment-service notification-service delivery-service)

# OpenShift 내부 이미지 레지스트리
OCP_REGISTRY_NS=openshift-image-registry
OCP_REGISTRY_SVC=image-registry.openshift-image-registry.svc:5000   # 클러스터 안에서 pull 할 때 주소

info()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()    { printf '\033[1;32m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn()  { printf '\033[1;33m[%s] WARN\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()   { printf '\033[1;31m[%s] ERROR\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

load_env() {
  local f="${DEMO_ENV:-$ROOT/demo.env}"
  [[ -f "$f" ]] || die "$f 가 없습니다. 'cp demo.env.example demo.env' 후 값을 채우세요."
  # shellcheck disable=SC1090
  set -a; source "$f"; set +a
  : "${TAG:?}" "${COURIER_DOMAIN:?}" "${COURIER_OLD_IP:?}" "${COURIER_NEW_IP:?}"
  : "${CLI:=auto}" "${REGISTRY_MODE:=ocp-internal}" "${REGISTRY:=}"
  : "${CONTAINER_ENGINE:=auto}" "${REGISTRY_TLS_VERIFY:=false}" "${PLATFORM:=linux/amd64}"
  : "${LOADGEN_ORDER_INTERVAL:=1}" "${LOADGEN_TRACKING_INTERVAL:=1}" "${LOADGEN_REPLICAS:=1}" "${LOADGEN_BROWSE_INTERVAL:=1}"
  [[ "$COURIER_OLD_IP" != "$COURIER_NEW_IP" ]] || die "COURIER_OLD_IP 와 COURIER_NEW_IP 가 같습니다."
  : "${PG_DOMAIN:=api.pg.example}" "${PG_IP:=}" "${PG_UNREGISTERED_DOMAIN:=api-new.pg.example}"
  PG_IP="${PG_IP:-$COURIER_OLD_IP}"
  if [[ -n "${CORP_DNS_MODE:-}" && "${CORP_DNS_MODE}" != cluster ]]; then
    warn "CORP_DNS_MODE=${CORP_DNS_MODE} 는 더 이상 쓰지 않습니다. 사내 DNS 는 항상 demo-infra 의 파드(ns1/ns2-corp-dns)입니다 (demo.env 에서 지워도 됨)."
  fi
  case "$REGISTRY_MODE" in
    ocp-internal) ;;
    external) [[ -n "$REGISTRY" ]] || die "REGISTRY_MODE=external 이면 REGISTRY 를 채워야 합니다." ;;
    *) die "REGISTRY_MODE 는 ocp-internal 또는 external 이어야 합니다 (현재: $REGISTRY_MODE)" ;;
  esac
  KC="$(detect_cli)"
  if [[ "$REGISTRY_MODE" == ocp-internal && "$KC" != oc ]]; then
    die "REGISTRY_MODE=ocp-internal 은 oc CLI 가 필요합니다 (현재 CLI: $KC)."
  fi
  # 사내 DNS 주소 = demo-infra 의 ns1/ns2-corp-dns 서비스 ClusterIP (배포 전이면 빈 값)
  CORP_DNS_PRIMARY="$(corp_dns_svc_ip "$CORP_DNS_PRIMARY_NAME")"
  CORP_DNS_SECONDARY="$(corp_dns_svc_ip "$CORP_DNS_SECONDARY_NAME")"
}

# ── 클러스터 CLI ─────────────────────────────────────────────
# CLI=oc|kubectl|auto (auto: oc 가 있으면 oc, 없으면 kubectl)
detect_cli() {
  case "${CLI:-auto}" in
    oc|kubectl)
      command -v "$CLI" >/dev/null || die "CLI=$CLI 인데 명령을 찾을 수 없습니다."
      echo "$CLI" ;;
    auto)
      if command -v oc >/dev/null; then echo oc
      elif command -v kubectl >/dev/null; then echo kubectl
      else die "oc 또는 kubectl 이 필요합니다."; fi ;;
    *) die "CLI 는 oc, kubectl, auto 중 하나여야 합니다 (현재: $CLI)" ;;
  esac
}

# 모든 스크립트는 kubectl/oc 대신 kc 를 쓴다
kc() { "$KC" "$@"; }

# OpenShift 여부 (SCC API 가 있으면 OpenShift). 한 번만 확인한다
is_ocp() {
  if [[ -z "${_IS_OCP:-}" ]]; then
    if kc api-resources --api-group=security.openshift.io 2>/dev/null | grep -q securitycontextconstraints; then
      _IS_OCP=yes
    else
      _IS_OCP=no
    fi
  fi
  [[ "$_IS_OCP" == yes ]]
}

# 점검용 임시 파드 실행: probe <이름> <이미지> <명령...>
# Pod Security "restricted" 를 강제하는 클러스터에서도 뜨도록 보안 설정을 붙인다.
# OpenShift 는 UID 를 자동 부여하므로 지정하지 않고, 그 밖의 쿠버네티스는 비 root UID(65532)를 지정한다.
probe() {
  local pod="$1-$RANDOM" image="$2"; shift 2
  local uid=''
  is_ocp || uid='"runAsUser":65532,'
  kc run "$pod" -n default --rm -i --restart=Never --quiet --pod-running-timeout=90s --image="$image" \
    --override-type=strategic \
    --overrides="{\"spec\":{\"securityContext\":{${uid}\"runAsNonRoot\":true,\"seccompProfile\":{\"type\":\"RuntimeDefault\"}},\"containers\":[{\"name\":\"${pod}\",\"securityContext\":{\"allowPrivilegeEscalation\":false,\"capabilities\":{\"drop\":[\"ALL\"]}}}]}}" \
    -- "$@"
}

# ── 컨테이너 엔진 ────────────────────────────────────────────
# CONTAINER_ENGINE=podman|docker|auto (auto: podman 우선, 없으면 docker)
detect_engine() {
  case "${CONTAINER_ENGINE:-auto}" in
    docker|podman)
      command -v "$CONTAINER_ENGINE" >/dev/null || die "CONTAINER_ENGINE=$CONTAINER_ENGINE 인데 명령을 찾을 수 없습니다."
      echo "$CONTAINER_ENGINE" ;;
    auto)
      if command -v podman >/dev/null; then echo podman
      elif command -v docker >/dev/null; then echo docker
      else die "podman 또는 docker 가 필요합니다."; fi ;;
    *) die "CONTAINER_ENGINE 은 docker, podman, auto 중 하나여야 합니다 (현재: $CONTAINER_ENGINE)" ;;
  esac
}

# ── 이미지 레지스트리 ────────────────────────────────────────
# push 주소와 pull 주소가 다르다 (ocp-internal):
#   push : 클러스터 밖(작업 PC)에서 → default route   <route-host>/demo-shop/<이미지>
#   pull : 클러스터 안(노드)에서    → 내부 서비스     image-registry.openshift-image-registry.svc:5000/demo-shop/<이미지>
# 이미지를 push 하면 demo-shop 네임스페이스의 같은 이름 ImageStream 에 태그가 쌓인다.
registry_route_host() {
  kc -n "$OCP_REGISTRY_NS" get route default-route -o jsonpath='{.spec.host}' 2>/dev/null || true
}

push_registry() {
  if [[ "$REGISTRY_MODE" == ocp-internal ]]; then
    local host; host="$(registry_route_host)"
    [[ -n "$host" ]] || die "내부 레지스트리 default route 가 없습니다. './demo.sh registry-route' 를 먼저 실행하세요 (cluster-admin)."
    echo "${host}/${APP_NS}"
  else
    echo "$REGISTRY"
  fi
}

pull_registry() {
  if [[ "$REGISTRY_MODE" == ocp-internal ]]; then echo "${OCP_REGISTRY_SVC}/${APP_NS}"; else echo "$REGISTRY"; fi
}

image_name() { echo "shop-$1"; }   # 서비스명 → 이미지(ImageStream) 이름

dashed() { echo "${1//./-}"; }

# ca_fingerprint [파일] : CA 인증서의 SHA256 지문 (콜론 없는 소문자 앞 16자). 없으면 none
ca_fingerprint() {
  local f="${1:-$ROOT/courier-ext/certs/ca.crt}"
  [[ -f "$f" ]] || { echo none; return; }
  openssl x509 -in "$f" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f' | cut -c1-16
}

# render <manifest> → stdout
# __NONOCP_RUN_AS_USER__ : 이미지의 USER 가 숫자가 아닌 파드(loadgen, 사내 DNS)용.
#   OpenShift 는 UID 를 자동 부여하므로 줄을 지우고, 그 밖의 쿠버네티스는 runAsUser 를 넣는다
render() {
  local reg uid_rule; reg="$(pull_registry)"
  if is_ocp; then uid_rule='/__NONOCP_RUN_AS_USER__/d'; else uid_rule='s#__NONOCP_RUN_AS_USER__#runAsUser: 65532#'; fi
  sed \
    -e "$uid_rule" \
    -e "s#__REGISTRY__#${reg}#g" \
    -e "s#__TAG__#${TAG}#g" \
    -e "s#__COURIER_DOMAIN__#${COURIER_DOMAIN}#g" \
    -e "s#__COURIER_OLD_IP_DASHED__#$(dashed "$COURIER_OLD_IP")#g" \
    -e "s#__COURIER_OLD_IP__#${COURIER_OLD_IP}#g" \
    -e "s#__CORP_DNS_PRIMARY__#${CORP_DNS_PRIMARY}#g" \
    -e "s#__CORP_DNS_SECONDARY__#${CORP_DNS_SECONDARY}#g" \
    -e "s#__LOADGEN_ORDER_INTERVAL__#${LOADGEN_ORDER_INTERVAL}#g" \
    -e "s#__LOADGEN_TRACKING_INTERVAL__#${LOADGEN_TRACKING_INTERVAL}#g" \
    -e "s#__LOADGEN_REPLICAS__#${LOADGEN_REPLICAS}#g" \
    -e "s#__LOADGEN_BROWSE_INTERVAL__#${LOADGEN_BROWSE_INTERVAL}#g" \
    -e "s#__PG_DOMAIN__#${PG_DOMAIN}#g" \
    -e "s#__CA_SHA256__#$(ca_fingerprint)#g" \
    "$1"
}


# ── 사내 DNS (PG 시나리오) ───────────────────────────────────
corp_dns_svc_ip() {
  kc -n "$INFRA_NS" get svc "$1" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true
}

# corp_zone : 표준입력의 "도메인 IP" 줄로 존 파일을 만든다.
# 루트(.) 존을 권한 있게 맡으므로 목록에 없는 이름은 NXDOMAIN. 시리얼이 바뀌어야 CoreDNS 가 다시 읽는다
corp_zone() {
  echo '$ORIGIN .'
  echo '$TTL 5'
  echo ". IN SOA ns1.corp.example. admin.corp.example. ( $(date +%s) 60 60 600 5 )"
  echo ". IN NS ns1.corp.example."
  echo ". IN NS ns2.corp.example."
  [[ -n "$CORP_DNS_PRIMARY" ]] && echo "ns1.corp.example. IN A ${CORP_DNS_PRIMARY}"
  [[ -n "$CORP_DNS_SECONDARY" ]] && echo "ns2.corp.example. IN A ${CORP_DNS_SECONDARY}"
  local name ip
  while read -r name ip; do
    [[ -n "$name" ]] && echo "${name}. IN A ${ip}"
  done
  return 0
}

corp_records() {
  local r; r="$(kc -n "$INFRA_NS" get configmap corp-dns-zone -o jsonpath='{.data.records}' 2>/dev/null || true)"
  [[ -n "$r" ]] && printf '%s\n' "$r"
  return 0
}

# corp_zone_apply <레코드 목록> : corp-dns-zone ConfigMap 갱신 (records = 원본 목록, db.corp = 존 파일)
corp_zone_apply() {
  local records="$1"
  kc -n "$INFRA_NS" create configmap corp-dns-zone \
    --from-literal=records="$records" \
    --from-literal=db.corp="$(printf '%s\n' "$records" | corp_zone)" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null
  # ConfigMap 볼륨 전파(최대 ~1분)를 기다리지 않도록 파드를 건드려 kubelet 이 바로 다시 마운트하게 한다
  kc -n "$INFRA_NS" annotate pod -l app=corp-dns --overwrite "demo.observ/zone-sync=$(date +%s)" >/dev/null 2>&1 || true
}

# dns_query <도메인> : 결제 파드에서 사내 DNS 서버마다 따로 조회한다 (점검용 — 앱은 OS 리졸버를 씀. 타임아웃 2초)
#   출력: "<primary|secondary> <서버> <결과> <ms>" 한 줄씩. 결과는 IP 또는 NXDOMAIN(ENOTFOUND)·TIMEOUT(ETIMEOUT)·CONNREFUSED 등
dns_query() {
  kc -n "$APP_NS" exec deploy/payment-service -- node -e '
const dns = require("node:dns");
const codes = { ENOTFOUND: "NXDOMAIN", ENODATA: "NODATA", ESERVFAIL: "SERVFAIL", EREFUSED: "REFUSED", ETIMEOUT: "TIMEOUT", ECONNREFUSED: "CONNREFUSED" };
(async () => {
  const [host, ...servers] = process.argv.slice(1);
  for (const [i, entry] of servers.entries()) {
    const [name, ip] = entry.split("=");
    const r = new dns.promises.Resolver({ timeout: 2000, tries: 1 });
    r.setServers([ip]);
    const t = Date.now();
    let res;
    try { res = (await r.resolve4(host)).join(","); } catch (e) { res = (codes[e.code] || e.code) + "(" + e.code + ")"; }
    console.log([i ? "secondary" : "primary  ", name + "(" + ip + ")", res, (Date.now() - t) + "ms"].join(" "));
  }
})();' "$1" "${CORP_DNS_PRIMARY_NAME}=${CORP_DNS_PRIMARY}" "${CORP_DNS_SECONDARY_NAME}=${CORP_DNS_SECONDARY}"
}
