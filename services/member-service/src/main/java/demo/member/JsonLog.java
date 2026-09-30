package demo.member;

import java.io.PrintWriter;
import java.io.StringWriter;
import java.time.Instant;
import java.time.temporal.ChronoUnit;

/**
 * 한 줄짜리 JSON 로그: {"ts","level","service","msg", ...필드}. 표준 라이브러리만 사용한다.
 * 필드는 키·값을 번갈아 넘긴다: log.info("order created", "req", reqId, "orderId", 1001).
 * 예외는 error(메시지)·stack(스택 트레이스) 필드 하나씩에 담아 여러 줄로 쪼개지지 않게 한다.
 */
final class JsonLog {
    private final String service;

    JsonLog(String service) { this.service = service; }

    void info(String msg, Object... kv) { write("INFO", msg, null, kv); }
    void warn(String msg, Object... kv) { write("WARN", msg, null, kv); }
    void error(String msg, Throwable t, Object... kv) { write("ERROR", msg, t, kv); }

    private void write(String level, String msg, Throwable t, Object... kv) {
        StringBuilder sb = new StringBuilder(256).append('{');
        field(sb, "ts", Instant.now().truncatedTo(ChronoUnit.MILLIS).toString());
        field(sb, "level", level);
        field(sb, "service", service);
        field(sb, "msg", msg);
        for (int i = 0; i + 1 < kv.length; i += 2) field(sb, String.valueOf(kv[i]), kv[i + 1]);
        if (t != null) {
            StringWriter sw = new StringWriter();
            t.printStackTrace(new PrintWriter(sw));
            field(sb, "error", t.toString());
            field(sb, "stack", sw.toString());
        }
        System.out.println(sb.append('}'));
    }

    private static void field(StringBuilder sb, String key, Object value) {
        if (value == null) return;
        if (sb.length() > 1) sb.append(',');
        quote(sb, key).append(':');
        if (value instanceof Number || value instanceof Boolean) sb.append(value);
        else quote(sb, String.valueOf(value));
    }

    private static StringBuilder quote(StringBuilder sb, String s) {
        sb.append('"');
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"' -> sb.append("\\\"");
                case '\\' -> sb.append("\\\\");
                case '\n' -> sb.append("\\n");
                case '\r' -> sb.append("\\r");
                case '\t' -> sb.append("\\t");
                default -> {
                    if (c < 0x20) sb.append(String.format("\\u%04x", (int) c));
                    else sb.append(c);
                }
            }
        }
        return sb.append('"');
    }
}
