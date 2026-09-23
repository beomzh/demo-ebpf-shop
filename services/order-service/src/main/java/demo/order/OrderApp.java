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
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicLong;
import java.util.logging.Logger;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 주문 서비스 (Java) — 회원·상품·결제·배송 서비스를 호출하는 진입점.
 *
 *   POST /api/orders                  회원 → 상품 → 결제 호출 후 주문 생성
 *   GET  /api/orders/{id}/delivery    배송 서비스 호출 (배송 조회)
 *
 * 서비스 간 호출은 평문 HTTP/1.1 로 한다 (h2c 업그레이드를 쓰지 않도록 고정).
 * 배송 서비스 호출 타임아웃은 배송 서비스의 택배사 타임아웃(5초)보다 길게 잡아,
 * 배송 서비스가 돌려준 5xx 가 그대로 기록되게 한다.
 */
public class OrderApp {
    private static final Logger log = Logger.getLogger("order-service");

    private static final String MEMBER_URL = env("MEMBER_URL", "http://member-service:8080");
    private static final String PRODUCT_URL = env("PRODUCT_URL", "http://product-service:8080");
    private static final String PAYMENT_URL = env("PAYMENT_URL", "http://payment-service:8080");
    private static final String DELIVERY_URL = env("DELIVERY_URL", "http://delivery-service:8080");
    private static final Duration DEFAULT_TIMEOUT = Duration.ofSeconds(3);
    private static final Duration DELIVERY_TIMEOUT = Duration.ofSeconds(Long.parseLong(env("DELIVERY_TIMEOUT_SECONDS", "10")));

    private static final Pattern DELIVERY_PATH = Pattern.compile("^/api/orders/(\\d+)/delivery$");
    private static final Pattern MEMBER_ID = Pattern.compile("\"memberId\"\\s*:\\s*(\\d+)");
    private static final Pattern PRODUCT_ID = Pattern.compile("\"productId\"\\s*:\\s*(\\d+)");
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
        server.createContext("/api/orders", OrderApp::route);
        server.setExecutor(Executors.newFixedThreadPool(64));
        server.start();
        log.info("listening on :" + port + " delivery=" + DELIVERY_URL + " deliveryTimeout=" + DELIVERY_TIMEOUT);
    }

    private static void route(HttpExchange ex) throws IOException {
        String path = ex.getRequestURI().getPath();
        String method = ex.getRequestMethod();
        try {
            if ("POST".equals(method) && ("/api/orders".equals(path) || "/api/orders/".equals(path))) {
                createOrder(ex);
                return;
            }
            Matcher m = DELIVERY_PATH.matcher(path);
            if ("GET".equals(method) && m.matches()) {
                trackDelivery(ex, m.group(1));
                return;
            }
            send(ex, 404, "{\"error\":\"not found\"}");
        } catch (Exception e) {
            log.warning("unhandled error " + method + " " + path + ": " + e);
            send(ex, 500, "{\"error\":\"internal error\"}");
        }
    }

    private static void createOrder(HttpExchange ex) throws Exception {
        String body = readBody(ex.getRequestBody());
        String memberId = find(MEMBER_ID, body, "1");
        String productId = find(PRODUCT_ID, body, "1");

        HttpResponse<String> member = get(MEMBER_URL + "/members/" + memberId, DEFAULT_TIMEOUT);
        if (member.statusCode() != 200) {
            log.warning("member lookup failed memberId=" + memberId + " status=" + member.statusCode());
            send(ex, 502, "{\"error\":\"member-service returned " + member.statusCode() + "\"}");
            return;
        }

        HttpResponse<String> product = get(PRODUCT_URL + "/products/" + productId, DEFAULT_TIMEOUT);
        if (product.statusCode() != 200) {
            log.warning("product lookup failed productId=" + productId + " status=" + product.statusCode());
            send(ex, 502, "{\"error\":\"product-service returned " + product.statusCode() + "\"}");
            return;
        }

        long orderId = ORDER_SEQ.incrementAndGet();
        String price = find(PRICE, product.body(), "0");
        HttpResponse<String> payment = HTTP.send(HttpRequest.newBuilder(URI.create(PAYMENT_URL + "/payments"))
                        .timeout(DEFAULT_TIMEOUT)
                        .header("Content-Type", "application/json")
                        .POST(HttpRequest.BodyPublishers.ofString("{\"orderId\":" + orderId + ",\"amount\":" + price + "}"))
                        .build(),
                HttpResponse.BodyHandlers.ofString());
        if (payment.statusCode() != 201) {
            log.warning("payment failed orderId=" + orderId + " status=" + payment.statusCode());
            send(ex, 502, "{\"error\":\"payment-service returned " + payment.statusCode() + "\"}");
            return;
        }

        send(ex, 201, "{\"orderId\":" + orderId + ",\"memberId\":" + memberId
                + ",\"productId\":" + productId + ",\"amount\":" + price + "}");
    }

    private static void trackDelivery(HttpExchange ex, String orderId) throws IOException {
        long started = System.nanoTime();
        try {
            HttpResponse<String> resp = get(DELIVERY_URL + "/deliveries/" + orderId + "/tracking", DELIVERY_TIMEOUT);
            long ms = (System.nanoTime() - started) / 1_000_000;
            if (resp.statusCode() == 200) {
                send(ex, 200, resp.body());
                return;
            }
            log.warning("delivery tracking failed orderId=" + orderId + " status=" + resp.statusCode() + " elapsedMs=" + ms);
            send(ex, 502, "{\"error\":\"delivery-service returned " + resp.statusCode() + "\",\"orderId\":" + orderId + "}");
        } catch (Exception e) {
            long ms = (System.nanoTime() - started) / 1_000_000;
            log.warning("delivery tracking error orderId=" + orderId + " elapsedMs=" + ms + " err=" + e);
            send(ex, 504, "{\"error\":\"delivery-service unreachable\",\"orderId\":" + orderId + "}");
        }
    }

    private static HttpResponse<String> get(String url, Duration timeout) throws IOException, InterruptedException {
        return HTTP.send(HttpRequest.newBuilder(URI.create(url)).timeout(timeout).GET().build(),
                HttpResponse.BodyHandlers.ofString());
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
