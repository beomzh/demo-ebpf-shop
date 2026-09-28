package demo.order;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManagerFactory;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyStore;
import java.security.Security;
import java.security.cert.CertificateFactory;
import java.time.Duration;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicLong;
import java.util.logging.Level;
import java.util.logging.Logger;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 주문 서비스 (Java) — 게이트웨이가 호출하고, 주문 처리를 위해 여러 서비스를 차례로 호출한다.
 *
 *   POST /orders                 회원 확인 → 재고 차감 → PG 카드 혜택 조회(외부, 선택) → 결제(→회원→PG 승인) → 알림(→회원)
 *   GET  /orders/{id}/delivery   배송 서비스 호출 (배송 조회 — 데모 사건 경로)
 *
 * 받은 X-Request-Id 를 모든 하위 호출에 그대로 넘긴다.
 * 하위 호출이 실패하면 "어디를 호출하다 실패했는지"를 로그에 남기고, 응답의 errorPath 에 자기 구간을 앞에 붙여 위로 전달한다.
 *   예) order-service → delivery-service[503] → api.courier.example(10.0.0.62:443) [connect: timed out after 5.00s]
 * 서비스 간 호출은 평문 HTTP/1.1 로 고정한다 (h2c 업그레이드를 쓰지 않음).
 * 배송 호출 타임아웃(10초)은 배송 서비스의 택배사 타임아웃(5초)보다 길게 잡아,
 * 배송 서비스가 돌려준 5xx 가 그대로 기록되게 한다.
 */
public class OrderApp {
    private static final Logger log = Logger.getLogger("order-service");
    private static final String SERVICE = "order-service";

    private static final String MEMBER_URL = env("MEMBER_URL", "http://member-service:8080");
    private static final String INVENTORY_URL = env("INVENTORY_URL", "http://inventory-service:8080");
    private static final String PAYMENT_URL = env("PAYMENT_URL", "http://payment-service:8080");
    private static final String NOTIFICATION_URL = env("NOTIFICATION_URL", "http://notification-service:8080");
    private static final String DELIVERY_URL = env("DELIVERY_URL", "http://delivery-service:8080");
    private static final Duration DEFAULT_TIMEOUT = Duration.ofSeconds(3);
    // 결제는 안에서 외부 PG 를 부르고, 주 DNS 장애 시 조회가 2초 더 걸리므로 넉넉히
    private static final Duration PAYMENT_TIMEOUT = Duration.ofSeconds(6);
    private static final String PG_BENEFITS_URL = "https://" + CorpDnsResolverProvider.PG_DOMAIN + "/v1/card-benefits";
    private static final Duration DELIVERY_TIMEOUT = Duration.ofSeconds(Long.parseLong(env("DELIVERY_TIMEOUT_SECONDS", "10")));

    private static final Pattern DELIVERY_PATH = Pattern.compile("^/orders/(\\d+)/delivery$");
    private static final Pattern MEMBER_ID = Pattern.compile("\"memberId\"\\s*:\\s*(\\d+)");
    private static final Pattern PRODUCT_ID = Pattern.compile("\"productId\"\\s*:\\s*(\\d+)");
    private static final Pattern QTY = Pattern.compile("\"qty\"\\s*:\\s*(\\d+)");
    private static final Pattern PRICE = Pattern.compile("\"price\"\\s*:\\s*(\\d+)");
    private static final Pattern ERROR_PATH = Pattern.compile("\"errorPath\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"");

    private static final AtomicLong ORDER_SEQ = new AtomicLong(1000);
    private static final HttpClient HTTP = HttpClient.newBuilder()
            .version(HttpClient.Version.HTTP_1_1)
            .connectTimeout(Duration.ofSeconds(2))
            .build();

    /** 하위 서비스 호출 결과. 연결 실패·타임아웃이면 status 0, error 에 예외. */
    private record Upstream(String target, String method, String url, int status, String body, long ms, Exception error) {
        boolean is(int expected) { return error == null && status == expected; }
    }

    // 외부 PG 호출용 (데모 CA 로 PG 서버 인증서를 검증)
    private static final HttpClient PG_HTTP = pgClient();

    public static void main(String[] args) throws IOException {
        System.setProperty("java.util.logging.SimpleFormatter.format", "%1$tFT%1$tT %4$s order-service %5$s%6$s%n");
        // JDK DNS 캐시를 짧게: 사내 DNS 변화(레코드 삭제·주 DNS 장애)가 곧바로 드러나게 한다
        Security.setProperty("networkaddress.cache.ttl", "2");
        Security.setProperty("networkaddress.cache.negative.ttl", "0");
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
            log.log(Level.SEVERE, "unhandled error req=" + reqId + " " + method + " " + path, e);
            send(ex, 500, "{\"error\":\"internal error\",\"errorPath\":\"" + jsonEscape(SERVICE + " [" + e + "]") + "\"}");
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
        Upstream member = call("member-service", "GET", MEMBER_URL + "/members/" + memberId, reqId, DEFAULT_TIMEOUT, null);
        if (!member.is(200)) { fail(ex, reqId, member, "orderId=" + orderId); return; }

        // 2) 재고 차감 (재고 → Redis)
        Upstream stock = call("inventory-service", "POST", INVENTORY_URL + "/inventory/" + productId + "/reserve", reqId,
                DEFAULT_TIMEOUT, "{\"qty\":" + qty + "}");
        if (!stock.is(200)) { fail(ex, reqId, stock, "orderId=" + orderId); return; }

        // 3) PG 카드 혜택 조회 (외부 PG사, 사내 DNS 로 도메인 조회). 선택 기능 — 실패해도 혜택 없이 진행
        Upstream benefits = pgCardBenefits(reqId);
        if (!benefits.is(200)) logFailure(reqId, benefits, "orderId=" + orderId + " (카드 혜택 없이 진행)");

        // 4) 결제 (결제 → 회원, 결제 → 외부 PG 승인)
        Upstream payment = call("payment-service", "POST", PAYMENT_URL + "/payments", reqId, PAYMENT_TIMEOUT,
                "{\"orderId\":" + orderId + ",\"memberId\":" + memberId + ",\"amount\":" + amount + "}");
        if (!payment.is(201)) { fail(ex, reqId, payment, "orderId=" + orderId); return; }

        // 5) 알림 (알림 → 회원). 알림 실패는 로그만 남기고 주문은 성공시킨다
        Upstream noti = call("notification-service", "POST", NOTIFICATION_URL + "/notifications", reqId, DEFAULT_TIMEOUT,
                "{\"orderId\":" + orderId + ",\"memberId\":" + memberId + "}");
        if (!noti.is(202)) logFailure(reqId, noti, "orderId=" + orderId + " (주문은 계속 진행)");

        send(ex, 201, "{\"orderId\":" + orderId + ",\"memberId\":" + memberId + ",\"productId\":" + productId
                + ",\"qty\":" + qty + ",\"amount\":" + amount + "}");
    }

    private static void trackDelivery(HttpExchange ex, String reqId, String orderId) throws Exception {
        Upstream delivery = call("delivery-service", "GET", DELIVERY_URL + "/deliveries/" + orderId + "/tracking", reqId,
                DELIVERY_TIMEOUT, null);
        if (delivery.is(200)) {
            send(ex, 200, delivery.body());
            return;
        }
        fail(ex, reqId, delivery, "orderId=" + orderId);
    }

    /**
     * 외부 PG 카드 혜택 조회. 먼저 PG 도메인을 사내 DNS 로 조회하고(CorpDnsResolverProvider),
     * 주 DNS 가 실패해 보조 DNS 로 넘어갔으면 그 과정을 WARN 으로 남긴다.
     * DNS 실패는 java.net.UnknownHostException 으로 Upstream.error 에 담긴다.
     */
    private static Upstream pgCardBenefits(String reqId) throws InterruptedException {
        String target = "pg(" + CorpDnsResolverProvider.PG_DOMAIN + ")";
        long started = System.nanoTime();
        CorpDnsResolverProvider.ATTEMPTS.remove();
        try {
            InetAddress.getByName(CorpDnsResolverProvider.PG_DOMAIN);   // 사내 DNS 조회 (JDK 캐시 2초)
        } catch (IOException e) {
            return new Upstream(target, "GET", PG_BENEFITS_URL, 0, "", (System.nanoTime() - started) / 1_000_000, e);
        } finally {
            List<String> attempts = CorpDnsResolverProvider.ATTEMPTS.get();
            if (attempts != null && attempts.size() > 1 && !attempts.get(attempts.size() - 1).contains("NXDOMAIN")) {
                log.warning("dns fallback req=" + reqId + " host=" + CorpDnsResolverProvider.PG_DOMAIN
                        + " attempts=\"" + String.join(" | ", attempts) + "\"");
            }
            CorpDnsResolverProvider.ATTEMPTS.remove();
        }
        try {
            HttpResponse<String> r = PG_HTTP.send(HttpRequest.newBuilder(URI.create(PG_BENEFITS_URL))
                    .timeout(DEFAULT_TIMEOUT).header("X-Request-Id", reqId).GET().build(), HttpResponse.BodyHandlers.ofString());
            return new Upstream(target, "GET", PG_BENEFITS_URL, r.statusCode(), r.body(), (System.nanoTime() - started) / 1_000_000, null);
        } catch (IOException e) {
            return new Upstream(target, "GET", PG_BENEFITS_URL, 0, "", (System.nanoTime() - started) / 1_000_000, e);
        }
    }

    private static HttpClient pgClient() {
        HttpClient.Builder b = HttpClient.newBuilder().version(HttpClient.Version.HTTP_1_1).connectTimeout(Duration.ofSeconds(2));
        Path ca = Path.of(env("PG_CA_FILE", "/etc/demo-ca/ca.crt"));
        if (Files.isReadable(ca)) {
            try (FileInputStream in = new FileInputStream(ca.toFile())) {
                KeyStore ks = KeyStore.getInstance(KeyStore.getDefaultType());
                ks.load(null, null);
                ks.setCertificateEntry("demo-ca", CertificateFactory.getInstance("X.509").generateCertificate(in));
                TrustManagerFactory tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
                tmf.init(ks);
                SSLContext ctx = SSLContext.getInstance("TLS");
                ctx.init(null, tmf.getTrustManagers(), null);
                b.sslContext(ctx);
            } catch (Exception e) {
                log.warning("PG CA load failed file=" + ca + " err=" + e);
            }
        } else {
            log.warning("PG CA file not found (" + ca + ") — using JDK default trust store");
        }
        return b.build();
    }

    /** 하위 서비스 호출. 예외를 던지지 않고 결과(Upstream)로 돌려준다. */
    private static Upstream call(String target, String method, String url, String reqId, Duration timeout, String json)
            throws InterruptedException {
        long started = System.nanoTime();
        HttpRequest.Builder b = HttpRequest.newBuilder(URI.create(url)).timeout(timeout).header("X-Request-Id", reqId);
        if (json == null) {
            b.GET();
        } else {
            b.header("Content-Type", "application/json").POST(HttpRequest.BodyPublishers.ofString(json));
        }
        try {
            HttpResponse<String> r = HTTP.send(b.build(), HttpResponse.BodyHandlers.ofString());
            return new Upstream(target, method, url, r.statusCode(), r.body(), (System.nanoTime() - started) / 1_000_000, null);
        } catch (IOException e) {
            return new Upstream(target, method, url, 0, "", (System.nanoTime() - started) / 1_000_000, e);
        }
    }

    /** 실패 로그를 남기고, 위(게이트웨이)로 errorPath 를 담은 502/504 를 돌려준다. */
    private static void fail(HttpExchange ex, String reqId, Upstream u, String detail) throws IOException {
        String path = logFailure(reqId, u, detail);
        int status = u.error() != null ? 504 : 502;
        send(ex, status, "{\"error\":\"" + u.target() + " call failed\",\"errorPath\":\"" + jsonEscape(path) + "\"}");
    }

    private static String logFailure(String reqId, Upstream u, String detail) {
        String path = errorPath(u);
        String msg = "upstream call failed req=" + reqId + " target=" + u.target() + " call=\"" + u.method() + " " + u.url()
                + "\" status=" + u.status() + " elapsedMs=" + u.ms() + " " + detail + " path=\"" + path + "\"";
        if (u.error() != null) {
            log.log(Level.SEVERE, msg, u.error());   // 연결 실패·타임아웃은 스택 트레이스까지
        } else {
            log.warning(msg);
        }
        return path;
    }

    /** "order-service → <target>[상태]" 뒤에 하위 서비스가 보낸 errorPath 를 이어 붙인다. */
    private static String errorPath(Upstream u) {
        if (u.error() != null) {
            return SERVICE + " → " + u.target() + " [" + u.error().getClass().getName()
                    + (u.error().getMessage() == null ? "" : ": " + u.error().getMessage()) + " after " + u.ms() + "ms]";
        }
        String head = SERVICE + " → " + u.target() + "[" + u.status() + "]";
        Matcher m = ERROR_PATH.matcher(u.body() == null ? "" : u.body());
        if (m.find()) {
            String upstream = jsonUnescape(m.group(1));
            if (upstream.startsWith(u.target())) return head + upstream.substring(u.target().length());
            return head + " → " + upstream;
        }
        return head;
    }

    private static String requestId(HttpExchange ex) {
        String v = ex.getRequestHeaders().getFirst("X-Request-Id");
        return v == null || v.isBlank() ? UUID.randomUUID().toString().replace("-", "").substring(0, 16) : v;
    }

    private static String find(Pattern p, String s, String def) {
        Matcher m = p.matcher(s == null ? "" : s);
        return m.find() ? m.group(1) : def;
    }

    private static String jsonEscape(String s) {
        StringBuilder b = new StringBuilder();
        for (char c : s.toCharArray()) {
            switch (c) {
                case '"' -> b.append("\\\"");
                case '\\' -> b.append("\\\\");
                case '\n' -> b.append("\\n");
                case '\r' -> b.append("\\r");
                case '\t' -> b.append("\\t");
                default -> { if (c < 0x20) b.append(String.format("\\u%04x", (int) c)); else b.append(c); }
            }
        }
        return b.toString();
    }

    private static String jsonUnescape(String s) {
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c != '\\' || i + 1 >= s.length()) { b.append(c); continue; }
            char n = s.charAt(++i);
            switch (n) {
                case 'n' -> b.append('\n');
                case 't' -> b.append('\t');
                case 'r' -> b.append('\r');
                case 'u' -> {
                    if (i + 4 < s.length()) { b.append((char) Integer.parseInt(s.substring(i + 1, i + 5), 16)); i += 4; }
                }
                default -> b.append(n);
            }
        }
        return b.toString();
    }

    private static String readBody(InputStream in) throws IOException {
        try (in) {
            return new String(in.readAllBytes(), StandardCharsets.UTF_8);
        }
    }

    private static void send(HttpExchange ex, int status, String json) throws IOException {
        byte[] body = json.getBytes(StandardCharsets.UTF_8);
        ex.getResponseHeaders().set("Content-Type", "application/json; charset=utf-8");
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
