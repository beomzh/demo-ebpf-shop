"""배송 서비스 (Python) — 모니터링이 전혀 없는 서비스.

주문 서비스가 GET /deliveries/{orderId}/tracking 을 호출하면
외부 택배사 API(HTTPS)를 호출해 배송 상태를 돌려준다.

데모 조건 (README "데모 환경 조건" 참고):
- 표준 라이브러리만 사용한다. ssl 모듈이 시스템 libssl 을 동적 링크하므로
  eBPF 가 TLS 평문을 볼 수 있다.
- 택배사 호출은 매 요청마다 DNS 를 새로 조회한다(캐시 없음).
- 연결 타임아웃 5초. 실패하면 주문 서비스에 503 을 돌려준다.
  (커널 기본 재시도에 맡기면 약 127초 뒤에야 실패가 기록된다.)
"""

import http.client
import json
import logging
import os
import re
import socket
import ssl
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.getenv("PORT", "8080"))
COURIER_HOST = os.getenv("COURIER_HOST", "api.courier.example")
COURIER_PORT = int(os.getenv("COURIER_PORT", "443"))
COURIER_TIMEOUT = float(os.getenv("COURIER_TIMEOUT_SECONDS", "5"))
COURIER_CA_FILE = os.getenv("COURIER_CA_FILE", "/etc/courier-ca/ca.crt")

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s delivery-service %(message)s",
)
log = logging.getLogger("delivery")

TRACKING_PATH = re.compile(r"^/deliveries/(\d+)/tracking$")


def build_ssl_context() -> ssl.SSLContext:
    # 기본은 fail-closed: CA 파일이 없으면 기동하지 않는다.
    # 검증 없이 띄우려면 COURIER_TLS_INSECURE=true 를 명시해야 한다 (로컬 실험용).
    if COURIER_CA_FILE and os.path.isfile(COURIER_CA_FILE):
        log.info("courier TLS: verifying with CA %s", COURIER_CA_FILE)
        ctx = ssl.create_default_context(cafile=COURIER_CA_FILE)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        return ctx
    if os.getenv("COURIER_TLS_INSECURE", "").lower() == "true":
        log.warning("courier TLS: COURIER_TLS_INSECURE=true, certificate verification DISABLED")
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return ctx
    log.critical("courier TLS: CA file %s not found. Mount the courier-ca secret "
                 "(or set COURIER_TLS_INSECURE=true for local experiments only)", COURIER_CA_FILE)
    raise SystemExit(1)


SSL_CTX = build_ssl_context()


class CourierError(Exception):
    def __init__(self, stage: str, ip: str, cause: Exception):
        super().__init__(f"{stage} failed ip={ip}: {cause!r}")
        self.stage = stage
        self.ip = ip


def tracking_no_for(order_id: str) -> str:
    return f"DX{zlib.crc32(order_id.encode()) % 10**10:010d}"


def call_courier(tracking_no: str) -> dict:
    # DNS 조회 → TCP 연결 → TLS → HTTP 순서로 단계를 나눠 실패 지점을 로그에 남긴다.
    try:
        ip = socket.getaddrinfo(COURIER_HOST, COURIER_PORT, socket.AF_INET, socket.SOCK_STREAM)[0][4][0]
    except OSError as e:
        raise CourierError("dns", "-", e) from e

    try:
        raw = socket.create_connection((ip, COURIER_PORT), timeout=COURIER_TIMEOUT)
    except OSError as e:
        raise CourierError("connect", ip, e) from e

    try:
        tls = SSL_CTX.wrap_socket(raw, server_hostname=COURIER_HOST)
        conn = http.client.HTTPSConnection(COURIER_HOST, COURIER_PORT, timeout=COURIER_TIMEOUT, context=SSL_CTX)
        conn.sock = tls
        conn.request("GET", f"/v1/tracking/{tracking_no}", headers={"Accept": "application/json"})
        resp = conn.getresponse()
        body = resp.read()
        conn.close()
    except (OSError, http.client.HTTPException) as e:
        raw.close()
        raise CourierError("http", ip, e) from e

    if resp.status != 200:
        raise CourierError("http", ip, RuntimeError(f"status {resp.status}"))
    return json.loads(body)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "delivery-service/1.0"

    def log_message(self, fmt, *args):  # 기본 access log 대신 아래에서 한 줄로 남긴다
        pass

    def _send(self, status: int, payload: dict):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._send(200, {"status": "UP"})
            return

        m = TRACKING_PATH.match(self.path)
        if not m:
            self._send(404, {"error": "not found"})
            return

        order_id = m.group(1)
        tracking_no = tracking_no_for(order_id)
        started = time.monotonic()
        try:
            data = call_courier(tracking_no)
        except CourierError as e:
            elapsed = time.monotonic() - started
            log.warning(
                "courier call failed order=%s tracking=%s stage=%s host=%s ip=%s elapsed=%.2fs err=%s",
                order_id, tracking_no, e.stage, COURIER_HOST, e.ip, elapsed, e.__cause__,
            )
            self._send(503, {"error": "courier unavailable", "orderId": order_id})
            return

        elapsed = time.monotonic() - started
        log.info("tracking ok order=%s tracking=%s elapsed=%.3fs", order_id, tracking_no, elapsed)
        self._send(200, {"orderId": order_id, "tracking": data})


def main():
    log.info("listening on :%d courier=%s:%d timeout=%.1fs", PORT, COURIER_HOST, COURIER_PORT, COURIER_TIMEOUT)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
