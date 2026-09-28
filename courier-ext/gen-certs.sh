#!/usr/bin/env bash
# 가상 외부 API(택배사·PG사)용 사설 CA 와 서버 인증서를 만든다. 이미 있는 것은 건너뛴다.
#   certs/ca.crt        → 클러스터의 courier-ca 시크릿 (배송·주문·결제 서비스가 검증에 사용)
#   certs/courier.crt   → 택배사 API (nginx)
#   certs/pg.crt        → PG사 API (nginx). SAN: PG_DOMAIN, PG_UNREGISTERED_DOMAIN
#
# 도메인은 ../demo.env 에서 읽고, 없으면 기본값을 쓴다.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="$HERE/certs"
COURIER_DOMAIN="${1:-}"
if [[ -f "$HERE/../demo.env" ]]; then
  eval "$(set -a; source "$HERE/../demo.env"; set +a; \
    printf 'ENV_COURIER=%q PG_DOMAIN=%q PG_UNREGISTERED_DOMAIN=%q' \
      "${COURIER_DOMAIN:-}" "${PG_DOMAIN:-}" "${PG_UNREGISTERED_DOMAIN:-}")"
fi
COURIER_DOMAIN="${COURIER_DOMAIN:-${ENV_COURIER:-api.courier.example}}"
PG_DOMAIN="${PG_DOMAIN:-api.pg.example}"
PG_UNREGISTERED_DOMAIN="${PG_UNREGISTERED_DOMAIN:-api.pg-new.example}"

mkdir -p "$DIR"
cd "$DIR"

# issue <이름> <도메인...> : CA 로 서버 인증서 발급
issue() {
  local name="$1"; shift
  local san; san="$(printf 'DNS:%s,' "$@")"; san="${san%,}"
  openssl req -newkey rsa:2048 -nodes -keyout "$name.key" -out "$name.csr" -subj "/CN=$1" >/dev/null 2>&1
  printf "subjectAltName=%s\nextendedKeyUsage=serverAuth\n" "$san" > "$name.ext"
  openssl x509 -req -in "$name.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
    -days 825 -out "$name.crt" -extfile "$name.ext" >/dev/null 2>&1
  rm -f "$name.csr" "$name.ext" ca.srl
  chmod 600 "$name.key"   # 개인키는 소유자만 읽기
  echo "[gen-certs] $name.crt 발급: $*"
}

if [[ ! -f ca.crt ]]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
    -keyout ca.key -out ca.crt -subj "/CN=Demo External API Root CA" >/dev/null 2>&1
  chmod 600 ca.key
  echo "[gen-certs] CA 생성"
fi

[[ -f courier.crt ]] && echo "[gen-certs] courier.crt 있음 (건너뜀)" || issue courier "$COURIER_DOMAIN"
[[ -f pg.crt ]] && echo "[gen-certs] pg.crt 있음 (건너뜀)" || issue pg "$PG_DOMAIN" "$PG_UNREGISTERED_DOMAIN"

echo "[gen-certs] $DIR"
