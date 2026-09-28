package demo.order;

import javax.naming.CommunicationException;
import javax.naming.Context;
import javax.naming.NameNotFoundException;
import javax.naming.NamingException;
import javax.naming.ServiceUnavailableException;
import javax.naming.directory.Attribute;
import javax.naming.directory.DirContext;
import javax.naming.directory.InitialDirContext;
import java.net.InetAddress;
import java.net.UnknownHostException;
import java.net.spi.InetAddressResolver;
import java.net.spi.InetAddressResolverProvider;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Hashtable;
import java.util.List;
import java.util.stream.Stream;

/**
 * 외부 PG사 도메인만 "사내 DNS"(PG_DNS_SERVERS: 주, 보조 순)에 직접 질의하는 JDK 리졸버 (Java 18+ SPI).
 * 그 밖의 이름(클러스터 서비스 등)은 JDK 기본 리졸버(= 파드의 /etc/resolv.conf)로 넘긴다.
 *
 * 동작은 OS 리졸버와 같다:
 *   - 주 DNS 가 응답하지 않으면(타임아웃·거부·SERVFAIL) 보조 DNS 로 넘어간다
 *   - NXDOMAIN 은 "그런 이름은 없다"는 확정 응답이므로 보조 DNS 로 넘어가지 않고 바로 실패한다
 * 실패하면 JDK 가 쓰는 것과 같은 java.net.UnknownHostException 을 원인 예외(javax.naming.*)와 함께 던진다.
 * 서버별 시도 결과는 ATTEMPTS 에 남겨, 호출한 쪽이 로그에 "주 DNS 실패 → 보조 DNS 성공" 을 기록할 수 있게 한다.
 *
 * META-INF/services/java.net.spi.InetAddressResolverProvider 로 등록된다.
 */
public class CorpDnsResolverProvider extends InetAddressResolverProvider {
    static final String PG_DOMAIN = env("PG_DOMAIN", "api.pg.example");
    static final List<String> SERVERS = Arrays.stream(env("PG_DNS_SERVERS", "").split(","))
            .map(String::trim).filter(s -> !s.isEmpty()).toList();
    static final int TIMEOUT_MS = Integer.parseInt(env("PG_DNS_TIMEOUT_MS", "2000"));

    /** 마지막 조회의 서버별 시도 결과 (같은 스레드에서 읽는다) */
    static final ThreadLocal<List<String>> ATTEMPTS = new ThreadLocal<>();

    @Override
    public InetAddressResolver get(Configuration configuration) {
        InetAddressResolver builtin = configuration.builtinResolver();
        return new InetAddressResolver() {
            @Override
            public Stream<InetAddress> lookupByName(String host, LookupPolicy policy) throws UnknownHostException {
                if (SERVERS.isEmpty() || !host.equalsIgnoreCase(PG_DOMAIN)) {
                    return builtin.lookupByName(host, policy);
                }
                return lookupViaCorpDns(host);
            }

            @Override
            public String lookupByAddress(byte[] addr) throws UnknownHostException {
                return builtin.lookupByAddress(addr);
            }
        };
    }

    @Override
    public String name() {
        return "corp-dns";
    }

    private static Stream<InetAddress> lookupViaCorpDns(String host) throws UnknownHostException {
        List<String> attempts = new ArrayList<>();
        ATTEMPTS.set(attempts);
        NamingException last = null;
        for (int i = 0; i < SERVERS.size(); i++) {
            String server = SERVERS.get(i);
            String who = (i == 0 ? "primary " : "secondary ") + server;
            long started = System.nanoTime();
            try {
                List<InetAddress> found = queryA(server, host);
                attempts.add(who + " → " + found.get(0).getHostAddress() + " (" + ms(started) + "ms)");
                return found.stream();
            } catch (NameNotFoundException e) {
                // NXDOMAIN: 확정 응답 → 보조 DNS 로 넘어가지 않는다
                attempts.add(who + " → NXDOMAIN (" + ms(started) + "ms)");
                UnknownHostException u = new UnknownHostException(
                        host + ": Name or service not known (NXDOMAIN from " + who + ")");
                u.initCause(e);
                throw u;
            } catch (NamingException e) {
                attempts.add(who + " → " + describe(e) + " (" + ms(started) + "ms)");
                last = e;
            }
        }
        UnknownHostException u = new UnknownHostException(
                host + ": Temporary failure in name resolution (" + String.join(", ", attempts) + ")");
        u.initCause(last);
        throw u;
    }

    /** JNDI DNS 로 특정 서버에 A 레코드를 묻는다. 타임아웃 TIMEOUT_MS, 재시도 없음. */
    private static List<InetAddress> queryA(String server, String host) throws NamingException {
        Hashtable<String, String> env = new Hashtable<>();
        env.put(Context.INITIAL_CONTEXT_FACTORY, "com.sun.jndi.dns.DnsContextFactory");
        env.put(Context.PROVIDER_URL, "dns://" + server);
        env.put("com.sun.jndi.dns.timeout.initial", String.valueOf(TIMEOUT_MS));
        env.put("com.sun.jndi.dns.timeout.retries", "1");
        DirContext ctx = new InitialDirContext(env);
        try {
            Attribute a = ctx.getAttributes(host, new String[]{"A"}).get("A");
            if (a == null || a.size() == 0) {
                throw new NameNotFoundException("no A record for " + host);
            }
            List<InetAddress> out = new ArrayList<>();
            for (int i = 0; i < a.size(); i++) {
                out.add(InetAddress.getByAddress(host, ipv4(String.valueOf(a.get(i)))));
            }
            return out;
        } catch (UnknownHostException e) {
            throw new NamingException("invalid A record: " + e.getMessage());
        } finally {
            ctx.close();
        }
    }

    private static String describe(NamingException e) {
        Throwable root = e.getRootCause();
        if (e instanceof CommunicationException && root != null) {
            return root.getClass().getSimpleName() + (root.getMessage() == null ? "" : ": " + root.getMessage());
        }
        if (e instanceof ServiceUnavailableException) return "SERVFAIL";
        return e.getClass().getSimpleName() + ": " + e.getExplanation();
    }

    private static byte[] ipv4(String s) {
        String[] p = s.trim().split("\\.");
        return new byte[]{(byte) Integer.parseInt(p[0]), (byte) Integer.parseInt(p[1]),
                (byte) Integer.parseInt(p[2]), (byte) Integer.parseInt(p[3])};
    }

    private static long ms(long started) {
        return (System.nanoTime() - started) / 1_000_000;
    }

    private static String env(String key, String def) {
        String v = System.getenv(key);
        return v == null || v.isBlank() ? def : v;
    }
}
