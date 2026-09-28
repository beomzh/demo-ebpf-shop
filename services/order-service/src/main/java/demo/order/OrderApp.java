package demo.order;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.UUID;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicLong;
import java.util.logging.Logger;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 주문 서비스 (Java) — 게이트웨이가 호출하고, 주문 처리를 위해 여러 서비스를 차례로 호출한다.
 *
 *   POST /orders                 회원 확인 → 재고 차감 → 결제(→회원) → 알림(→회원)
 *   GET  /orders/{id}/delivery   배송 서비스 호출 (배송 조회 — 데모 사건 경로)
 *
 * 받은 X-Request-Id 를 모든 하위 호출에 그대로 넘긴다.
 * 서비스 간 호출은 평문 HTTP/1.1 로 고정한다 (h2c 업그레이드를 쓰지 않음).
 * 배송 호출 타임아웃(10초)은 배송 서비스의 택배사 타임아웃(5초)보다 길게 잡아,
 * 배송 서비스가 돌려준 5xx 가 그대로 기록되게 한다.
 */
public class OrderApp {
    private static final Logger log = Logger.getLogger("order-service");

    private static final String MEMBER_URL = env("MEMBER_URL", "http://member-service:8080");
    private static final String INVENTORY_URL = env("INVENTORY_URL", "http://inventory-service:8080");
    private static final String PAYMENT_URL = env("PAYMENT_URL", "http://payment-service:8080");
    private static final String NOTIFICATION_URL = env("NOTIFICATION_URL", "http://notification-service:8080");
    private static final String DELIVERY_URL = env("DELIVERY_URL", "http://delivery-service:8080");
    private static final Duration DEFAULT_TIMEOUT = Duration.ofSeconds(3);
    private static final Duration DELIVERY_TIMEOUT = Duration.ofSeconds(Long.parseLong(env("DELIVERY_TIMEOUT_SECONDS", "10")));

    private static final Pattern DELIVERY_PATH = Pattern.compile("^/orders/(\\d+)/delivery$");
    private static final Pattern MEMBER_ID = Pattern.compile("\"memberId\"\\s*:\\s*(\\d+)");
    private static final Pattern PRODUCT_ID = Pattern.compile("\"productId\"\\s*:\\s*(\\d+)");
    private static final Pattern QTY = Pattern.compile("\"qty\"\\s*:\\s*(\\d+)");
    private static final Pattern PRICE = Pattern.compile("\"price\"\\s*:\\s*(\\d+)");

    private static final AtomicLong ORDER_SEQ = new AtomicLong(1000);
    private static final HttpClient HTTP = HttpClient.newBuilder()
            .version(HttpClient.Version.HTTP_1_1)
            .connectTimeout(Duration.ofSeconds(2))
            .build();

    public static void main(String[] args) throws IOException {
        System.setProperty("java.util.logging.SimpleFormatter.format", "%1$tFT%1$tT %4$s order-service %5$s%6$s%n");
        int port = Integer.parseInt(env("PORT", "8080"));
        HttpServer server = HttpServer.create(new InetSocketAddress(port), 0);
        server.createContext("/health", ex -> send(ex, 200, "{\"status\":\"UP\"}"));
        server.createContext("/orders", OrderApp::route);
        server.setExecutor(Executors.newFixedThreadPool(64));
        server.start();
        log.info("listening on :" + port + " delivery=" + DELIVERY_URL + " deliveryTimeout=" + DELIVERY_TIMEOUT);
    }

    private static void route(HttpExchange ex) throws IOException {
        String path = ex.getRequestURI().getPath();
        String method = ex.getRequestMethod();
        String reqId = requestId(ex);
        try {
            if ("POST".equals(method) && ("/orders".equals(path) || "/orders/".equals(path))) {
                createOrder(ex, reqId);
                return;
            }
            Matcher m = DELIVERY_PATH.matcher(path);
            if ("GET".equals(method) && m.matches()) {
                trackDelivery(ex, reqId, m.group(1));
                return;
            }
            send(ex, 404, "{\"error\":\"not found\"}");
        } catch (Exception e) {
            log.warning("unhandled error req=" + reqId + " " + method + " " + path + ": " + e);
            send(ex, 500, "{\"error\":\"internal error\"}");
        }
    }

    private static void createOrder(HttpExchange ex, String reqId) throws Exception {
        String body = readBody(ex.getRequestBody());
        String memberId = find(MEMBER_ID, body, "1");
        String productId = find(PRODUCT_ID, body, "1");
        String qty = find(QTY, body, "1");
        long amount = Long.parseLong(find(PRICE, body, "0")) * Long.parseLong(qty);
        long orderId = ORDER_SEQ.incrementAndGet();

        // 1) 회원 확인 (회원 → MySQL)
        HttpResponse<String> member = get(MEMBER_URL + "/members/" + memberId, reqId, DEFAULT_TIMEOUT);
        if (member.statusCode() != 200) {
            fail(ex, reqId, "member-service", member.statusCode(), "memberId=" + memberId);
            return;
        }

        // 2) 재고 차감 (재고 → Redis)
        HttpResponse<String> stock = post(INVENTORY_URL + "/inventory/" + productId + "/reserve", reqId,
                "{\"qty\":" + qty + "}");
        if (stock.statusCode() != 200) {
            fail(ex, reqId, "inventory-service", stock.statusCode(), "productId=" + productId);
            return;
        }

        // 3) 결제 (결제 → 회원)
        HttpResponse<String> payment = post(PAYMENT_URL + "/payments", reqId,
                "{\"orderId\":" + orderId + ",\"memberId\":" + memberId + ",\"amount\":" + amount + "}");
        if (payment.statusCode() != 201) {
            fail(ex, reqId, "payment-service", payment.statusCode(), "orderId=" + orderId);
            return;
        }

        // 4) 알림 (알림 → 회원). 알림 실패는 주문을 실패시키지 않는다
        try {
            HttpResponse<String> noti = post(NOTIFICATION_URL + "/notifications", reqId,
                    "{\"orderId\":" + orderId + ",\"memberId\":" + memberId + "}");
            if (noti.statusCode() != 202) {
                log.warning("notification failed req=" + reqId + " orderId=" + orderId + " status=" + noti.statusCode());
            }
        } catch (IOException e) {
            log.warning("notification error req=" + reqId + " orderId=" + orderId + " err=" + e);
        }

        send(ex, 201, "{\"orderId\":" + orderId + ",\"memberId\":" + memberId + ",\"productId\":" + productId
                + ",\"qty\":" + qty + ",\"amount\":" + amount + "}");
    }

    private static void trackDelivery(HttpExchange ex, String reqId, String orderId) throws IOException {
        long started = System.nanoTime();
        try {
            HttpResponse<String> resp = get(DELIVERY_URL + "/deliveries/" + orderId + "/tracking", reqId, DELIVERY_TIMEOUT);
            long ms = (System.nanoTime() - started) / 1_000_000;
            if (resp.statusCode() == 200) {
                send(ex, 200, resp.body());
                return;
            }
            log.warning("delivery tracking failed req=" + reqId + " orderId=" + orderId + " status=" + resp.statusCode() + " elapsedMs=" + ms);
            send(ex, 502, "{\"error\":\"delivery-service returned " + resp.statusCode() + "\",\"orderId\":" + orderId + "}");
        } catch (Exception e) {
            long ms = (System.nanoTime() - started) / 1_000_000;
            log.warning("delivery tracking error req=" + reqId + " orderId=" + orderId + " elapsedMs=" + ms + " err=" + e);
            send(ex, 504, "{\"error\":\"delivery-service unreachable\",\"orderId\":" + orderId + "}");
        }
    }

    private static void fail(HttpExchange ex, String reqId, String service, int status, String detail) throws IOException {
        log.warning("order failed req=" + reqId + " " + service + " status=" + status + " " + detail);
        send(ex, 502, "{\"error\":\"" + service + " returned " + status + "\"}");
    }

    private static HttpResponse<String> get(String url, String reqId, Duration timeout) throws IOException, InterruptedException {
        return HTTP.send(HttpRequest.newBuilder(URI.create(url)).timeout(timeout)
                        .header("X-Request-Id", reqId).GET().build(),
                HttpResponse.BodyHandlers.ofString());
    }

    private static HttpResponse<String> post(String url, String reqId, String json) throws IOException, InterruptedException {
        return HTTP.send(HttpRequest.newBuilder(URI.create(url)).timeout(DEFAULT_TIMEOUT)
                        .header("X-Request-Id", reqId)
                        .header("Content-Type", "application/json")
                        .POST(HttpRequest.BodyPublishers.ofString(json)).build(),
                HttpResponse.BodyHandlers.ofString());
    }

    private static String requestId(HttpExchange ex) {
        String v = ex.getRequestHeaders().getFirst("X-Request-Id");
        return v == null || v.isBlank() ? UUID.randomUUID().toString().replace("-", "").substring(0, 16) : v;
    }

    private static String find(Pattern p, String s, String def) {
        Matcher m = p.matcher(s == null ? "" : s);
        return m.find() ? m.group(1) : def;
    }

    private static String readBody(InputStream in) throws IOException {
        try (in) {
            return new String(in.readAllBytes(), StandardCharsets.UTF_8);
        }
    }

    private static void send(HttpExchange ex, int status, String json) throws IOException {
        byte[] body = json.getBytes(StandardCharsets.UTF_8);
        ex.getResponseHeaders().set("Content-Type", "application/json");
        ex.sendResponseHeaders(status, body.length);
        try (OutputStream os = ex.getResponseBody()) {
            os.write(body);
        }
    }

    private static String env(String key, String def) {
        String v = System.getenv(key);
        return v == null || v.isBlank() ? def : v;
    }
}
