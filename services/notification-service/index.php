<?php
// 알림 서비스 (PHP) — 주문 서비스가 주문 완료 후 호출한다. 회원 서비스에서 연락처·등급을 받아 알림을 "보낸다"(로그).
//
//   POST /notifications {orderId, memberId}   → 회원 서비스 GET /members/{id}
//
// PHP 내장 웹서버(php -S)로 실행하고, 외부 확장 없이 스트림(http://)으로 회원 서비스를 호출한다.
declare(strict_types=1);

$memberUrl = getenv('MEMBER_URL') ?: 'http://member-service:8080';

function logmsg(string $level, string $msg): void
{
    file_put_contents('php://stderr', date('Y-m-d\TH:i:s') . " $level notification-service $msg\n");
}

function respond(int $status, array $body): never
{
    http_response_code($status);
    header('Content-Type: application/json');
    echo json_encode($body);
    exit;
}

/** @return array{0:int,1:string} [상태코드, 본문] — 연결 실패·타임아웃이면 상태코드 0 */
function http_get(string $url, string $reqId, float $timeout): array
{
    $ctx = stream_context_create(['http' => [
        'method' => 'GET',
        'header' => "X-Request-Id: $reqId\r\nAccept: application/json\r\n",
        'timeout' => $timeout,
        'ignore_errors' => true,
        'protocol_version' => 1.1,
    ]]);
    $body = @file_get_contents($url, false, $ctx);
    if ($body === false || !isset($http_response_header[0])) {
        return [0, ''];
    }
    preg_match('#\s(\d{3})\s#', $http_response_header[0], $m);
    return [(int)($m[1] ?? 0), $body];
}

$method = $_SERVER['REQUEST_METHOD'];
$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
$reqId = $_SERVER['HTTP_X_REQUEST_ID'] ?? bin2hex(random_bytes(8));

if ($path === '/health') {
    respond(200, ['status' => 'UP']);
}

if ($method === 'POST' && $path === '/notifications') {
    $body = json_decode((string)file_get_contents('php://input'), true);
    if (!is_array($body) || empty($body['orderId']) || empty($body['memberId'])) {
        respond(400, ['error' => 'orderId and memberId are required']);
    }
    $orderId = (int)$body['orderId'];
    $memberId = (int)$body['memberId'];

    $started = microtime(true);
    [$status, $resp] = http_get("$memberUrl/members/$memberId", $reqId, 3.0);
    if ($status !== 200) {
        logmsg('WARN', sprintf('member lookup failed req=%s order=%d member=%d status=%d elapsedMs=%d',
            $reqId, $orderId, $memberId, $status, (microtime(true) - $started) * 1000));
        respond(502, ['error' => "member-service returned $status"]);
    }

    $member = json_decode($resp, true) ?: [];
    $channel = ($member['grade'] ?? '') === 'VIP' ? 'sms' : 'email';
    logmsg('INFO', sprintf('notified req=%s order=%d member=%s channel=%s', $reqId, $orderId, $member['name'] ?? $memberId, $channel));
    respond(202, ['notificationId' => bin2hex(random_bytes(8)), 'orderId' => $orderId, 'channel' => $channel]);
}

respond(404, ['error' => 'not found']);
