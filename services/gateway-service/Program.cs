// 게이트웨이 (C# / .NET 8) — 쇼핑몰의 입구. 사용자(loadgen) 요청을 받아 내부 서비스로 나눠 보낸다.
//
//   GET  /api/products/{id}          → 상품 → 재고 → Redis
//   GET  /api/members/{id}           → 회원 → MySQL
//   POST /api/checkout               → 상품(가격 확인) → 주문 → 회원·재고·결제(→회원)·알림(→회원)
//   GET  /api/orders/{id}/tracking   → 주문 → 배송 → 외부 택배사 (데모 사건 경로)
//
// 모든 요청에 X-Request-Id 를 붙여(없으면 새로 만들어) 다음 서비스로 넘기고 로그에 남긴다.
// 서비스 간 호출은 평문 HTTP/1.1 (eBPF 가 프로토콜을 구분할 수 있게).
using System.Diagnostics;
using System.Net;
using System.Text;
using System.Text.Json;

var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();
builder.Logging.AddSimpleConsole(o => { o.SingleLine = true; o.TimestampFormat = "yyyy-MM-ddTHH:mm:ss "; });
var app = builder.Build();
var log = app.Logger;

static string Env(string key, string def) =>
    Environment.GetEnvironmentVariable(key) is { Length: > 0 } v ? v : def;

var productUrl = Env("PRODUCT_URL", "http://product-service:8080");
var memberUrl = Env("MEMBER_URL", "http://member-service:8080");
var orderUrl = Env("ORDER_URL", "http://order-service:8080");
var defaultTimeout = TimeSpan.FromSeconds(5);
// 배송 조회는 주문 서비스의 배송 호출 타임아웃(10초)보다 길게 둬서, 하위 서비스가 돌려준 5xx 가 그대로 전달되게 한다.
var trackingTimeout = TimeSpan.FromSeconds(double.Parse(Env("TRACKING_TIMEOUT_SECONDS", "15")));

var http = new HttpClient(new SocketsHttpHandler
{
    PooledConnectionLifetime = TimeSpan.FromMinutes(5),
    ConnectTimeout = TimeSpan.FromSeconds(2),
})
{
    DefaultRequestVersion = HttpVersion.Version11,
    DefaultVersionPolicy = HttpVersionPolicy.RequestVersionExact,
    Timeout = Timeout.InfiniteTimeSpan,
};

string RequestId(HttpContext ctx) =>
    ctx.Request.Headers.TryGetValue("X-Request-Id", out var v) && !string.IsNullOrEmpty(v)
        ? v.ToString()
        : Guid.NewGuid().ToString("N")[..16];

// 하위 서비스 호출. 실패(연결 실패·타임아웃)는 status 0 으로 돌려준다.
async Task<(int Status, string Body, long Ms)> Call(HttpMethod method, string url, string reqId, TimeSpan timeout, string? json = null)
{
    var sw = Stopwatch.StartNew();
    try
    {
        using var cts = new CancellationTokenSource(timeout);
        using var req = new HttpRequestMessage(method, url);
        req.Headers.Add("X-Request-Id", reqId);
        if (json != null) req.Content = new StringContent(json, Encoding.UTF8, "application/json");
        using var resp = await http.SendAsync(req, cts.Token);
        var body = await resp.Content.ReadAsStringAsync(cts.Token);
        return ((int)resp.StatusCode, body, sw.ElapsedMilliseconds);
    }
    catch (Exception e) when (e is HttpRequestException or TaskCanceledException)
    {
        log.LogWarning("call failed req={ReqId} {Method} {Url} elapsedMs={Ms} err={Err}", reqId, method, url, sw.ElapsedMilliseconds, e.Message);
        return (0, "", sw.ElapsedMilliseconds);
    }
}

IResult Json(int status, string body) => Results.Content(body, "application/json", Encoding.UTF8, status);
IResult Upstream(string name, int status) =>
    Json(status == 0 ? 504 : 502, JsonSerializer.Serialize(new { error = $"{name} returned {(status == 0 ? "no response" : status)}" }));

app.MapGet("/health", () => Results.Json(new { status = "UP" }));

app.MapGet("/api/products/{id:int}", async (int id, HttpContext ctx) =>
{
    var reqId = RequestId(ctx);
    var r = await Call(HttpMethod.Get, $"{productUrl}/products/{id}", reqId, defaultTimeout);
    return r.Status == 200 ? Json(200, r.Body) : Upstream("product-service", r.Status);
});

app.MapGet("/api/members/{id:int}", async (int id, HttpContext ctx) =>
{
    var reqId = RequestId(ctx);
    var r = await Call(HttpMethod.Get, $"{memberUrl}/members/{id}", reqId, defaultTimeout);
    return r.Status == 200 ? Json(200, r.Body) : Upstream("member-service", r.Status);
});

app.MapPost("/api/checkout", async (HttpContext ctx) =>
{
    var reqId = RequestId(ctx);
    int memberId = 1, productId = 1, qty = 1;
    try
    {
        using var doc = await JsonDocument.ParseAsync(ctx.Request.Body);
        var root = doc.RootElement;
        if (root.TryGetProperty("memberId", out var m)) memberId = m.GetInt32();
        if (root.TryGetProperty("productId", out var p)) productId = p.GetInt32();
        if (root.TryGetProperty("qty", out var q)) qty = Math.Max(1, q.GetInt32());
    }
    catch (JsonException)
    {
        return Json(400, "{\"error\":\"invalid json\"}");
    }

    // 1) 상품 가격 확인 (상품 → 재고 → Redis)
    var product = await Call(HttpMethod.Get, $"{productUrl}/products/{productId}", reqId, defaultTimeout);
    if (product.Status != 200) return Upstream("product-service", product.Status);
    int price;
    using (var pdoc = JsonDocument.Parse(product.Body)) price = pdoc.RootElement.GetProperty("price").GetInt32();

    // 2) 주문 생성 (주문 → 회원·재고·결제·알림)
    var payload = JsonSerializer.Serialize(new { memberId, productId, qty, price });
    var order = await Call(HttpMethod.Post, $"{orderUrl}/orders", reqId, defaultTimeout, payload);
    if (order.Status != 201)
    {
        log.LogWarning("checkout failed req={ReqId} member={Member} product={Product} orderStatus={Status}", reqId, memberId, productId, order.Status);
        return Upstream("order-service", order.Status);
    }
    return Json(201, order.Body);
});

app.MapGet("/api/orders/{id:long}/tracking", async (long id, HttpContext ctx) =>
{
    var reqId = RequestId(ctx);
    var r = await Call(HttpMethod.Get, $"{orderUrl}/orders/{id}/delivery", reqId, trackingTimeout);
    if (r.Status == 200) return Json(200, r.Body);
    log.LogWarning("tracking failed req={ReqId} order={Order} status={Status} elapsedMs={Ms}", reqId, id, r.Status, r.Ms);
    return Upstream("order-service", r.Status);
});

log.LogInformation("gateway listening product={Product} member={Member} order={Order} trackingTimeout={Timeout}s",
    productUrl, memberUrl, orderUrl, trackingTimeout.TotalSeconds);
app.Run();
