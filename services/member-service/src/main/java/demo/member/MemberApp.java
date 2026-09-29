package demo.member;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.concurrent.Executors;
import java.util.logging.Level;
import java.util.logging.Logger;

/**
 * 회원 서비스 (Java + MySQL) — 게이트웨이·주문·결제·알림 서비스가 호출한다.
 * MySQL 은 평문(useSSL=false)으로 연결해 eBPF 가 쿼리를 볼 수 있게 한다.
 */
public class MemberApp {
    private static final Logger log = Logger.getLogger("member-service");

    private static final String DB_URL = env("DB_URL",
            "jdbc:mysql://mysql:3306/shop?useSSL=false&allowPublicKeyRetrieval=true&connectTimeout=2000&socketTimeout=2000");
    private static final String DB_USER = env("DB_USER", "shop");
    // 로그용: jdbc:mysql://mysql:3306/shop?... → mysql:3306
    private static final String DB_HOST = DB_URL.replaceFirst("^jdbc:mysql://([^/?]+).*$", "$1");
    private static final String DB_PASSWORD = env("DB_PASSWORD", "shop");

    // 요청 스레드마다 커넥션 1개를 재사용한다 (데모용 초간단 풀).
    private static final ThreadLocal<Connection> CONN = new ThreadLocal<>();

    public static void main(String[] args) throws Exception {
        System.setProperty("java.util.logging.SimpleFormatter.format", "%1$tFT%1$tT %4$s member-service %5$s%6$s%n");
        initSchema();

        int port = Integer.parseInt(env("PORT", "8080"));
        HttpServer server = HttpServer.create(new InetSocketAddress(port), 0);
        server.createContext("/health", ex -> send(ex, 200, "{\"status\":\"UP\"}"));
        server.createContext("/members/", MemberApp::getMember);
        server.setExecutor(Executors.newFixedThreadPool(16));
        server.start();
        log.info("listening on :" + port);
    }

    private static void getMember(HttpExchange ex) throws IOException {
        long started = System.nanoTime();
        String reqId = ex.getRequestHeaders().getFirst("X-Request-Id");
        long id;
        try {
            id = Long.parseLong(ex.getRequestURI().getPath().substring("/members/".length()));
        } catch (NumberFormatException e) {
            send(ex, 400, "{\"error\":\"invalid id\"}");
            return;
        }

        String json;
        try {
            json = queryMember(id);
        } catch (SQLException stale) {
            // MySQL 재시작 등으로 끊긴 연결일 수 있으니 새 연결로 한 번 더 시도한다
            resetConn();
            try {
                json = queryMember(id);
            } catch (SQLException e) {
                // 어디(MySQL 어느 주소)를 호출하다 실패했는지 남기고, 위로 errorPath 를 전달한다
                String reason = String.valueOf(e.getMessage()).lines().findFirst().orElse("");
                String path = "member-service → mysql(" + DB_HOST + ") [" + e.getClass().getSimpleName() + ": " + reason + "]";
                log.log(Level.SEVERE, "upstream call failed req=" + reqId + " target=mysql call=\"SELECT members WHERE id=" + id
                        + "\" path=\"" + path + "\"", e);
                resetConn();
                send(ex, 500, "{\"error\":\"db error\",\"errorPath\":\"" + path.replace("\\", "\\\\").replace("\"", "\\\"") + "\"}");
                return;
            }
        }
        long elapsedMs = (System.nanoTime() - started) / 1_000_000;
        if (json == null) {
            log.info("member not found req=" + reqId + " id=" + id + " elapsedMs=" + elapsedMs);
            send(ex, 404, "{\"error\":\"not found\"}");
        } else {
            log.info("member ok req=" + reqId + " id=" + id + " grade=" + json.replaceFirst(".*\"grade\":\"([^\"]*)\".*", "$1")
                    + " elapsedMs=" + elapsedMs);
            send(ex, 200, json);
        }
    }

    /** 회원 1명 조회. 없으면 null. */
    private static String queryMember(long id) throws SQLException {
        try (PreparedStatement ps = conn().prepareStatement("SELECT id, name, grade FROM members WHERE id = ?")) {
            ps.setLong(1, id);
            try (ResultSet rs = ps.executeQuery()) {
                if (!rs.next()) return null;
                return String.format("{\"id\":%d,\"name\":\"%s\",\"grade\":\"%s\"}",
                        rs.getLong("id"), rs.getString("name"), rs.getString("grade"));
            }
        }
    }

    private static Connection conn() throws SQLException {
        Connection c = CONN.get();
        if (c == null || c.isClosed()) {
            c = DriverManager.getConnection(DB_URL, DB_USER, DB_PASSWORD);
            CONN.set(c);
        }
        return c;
    }

    private static void resetConn() {
        Connection c = CONN.get();
        CONN.remove();
        if (c != null) {
            try { c.close(); } catch (SQLException ignored) { }
        }
    }

    private static void initSchema() throws InterruptedException {
        for (int attempt = 1; ; attempt++) {
            try (Connection c = DriverManager.getConnection(DB_URL, DB_USER, DB_PASSWORD);
                 Statement st = c.createStatement()) {
                st.execute("CREATE TABLE IF NOT EXISTS members ("
                        + "id BIGINT PRIMARY KEY, name VARCHAR(64) NOT NULL, grade VARCHAR(16) NOT NULL)");
                long count;
                try (ResultSet rs = st.executeQuery("SELECT COUNT(*) FROM members")) {
                    rs.next();
                    count = rs.getLong(1);
                }
                if (count == 0) {
                    try (PreparedStatement ps = c.prepareStatement("INSERT INTO members (id, name, grade) VALUES (?, ?, ?)")) {
                        for (int i = 1; i <= 100; i++) {
                            ps.setLong(1, i);
                            ps.setString(2, "member-" + i);
                            ps.setString(3, i % 10 == 0 ? "VIP" : "BASIC");
                            ps.addBatch();
                        }
                        ps.executeBatch();
                    }
                    log.info("seeded 100 members");
                }
                log.info("schema ready");
                return;
            } catch (SQLException e) {
                log.warning("mysql not ready (attempt " + attempt + "): " + e.getMessage());
                Thread.sleep(3000);
            }
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
