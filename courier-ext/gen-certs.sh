#!/usr/bin/env bash
# 가상 택배사 API 용 사설 CA 와 서버 인증서를 만든다.
#   certs/ca.crt        → 클러스터의 courier-ca 시크릿 (배송 서비스가 검증에 사용)
#   certs/courier.crt   → 택배사 호스트의 nginx
set -euo pipefail

DOMAIN="${1:-api.courier.example}"
DIR="$(cd "$(dirname "$0")" && pwd)/certs"
mkdir -p "$DIR"
cd "$DIR"

if [[ -f courier.crt && -f ca.crt ]]; then
  echo "[gen-certs] certs already exist in $DIR (delete them to regenerate)"
  exit 0
fi

openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
  -keyout ca.key -out ca.crt -subj "/CN=Demo Courier Root CA" >/dev/null 2>&1

openssl req -newkey rsa:2048 -nodes \
  -keyout courier.key -out courier.csr -subj "/CN=${DOMAIN}" >/dev/null 2>&1

printf "subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n" "$DOMAIN" > san.ext
openssl x509 -req -in courier.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days 825 -out courier.crt -extfile san.ext >/dev/null 2>&1
rm -f courier.csr san.ext ca.srl
chmod 600 ca.key courier.key   # 개인키는 소유자만 읽기

echo "[gen-certs] created CA and server cert for ${DOMAIN} in ${DIR}"
