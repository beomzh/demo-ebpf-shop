// 결제 서비스 (Node.js) — 주문 서비스가 호출하고, 회원 등급을 확인하려고 회원 서비스를 호출한다.
//
//   POST /payments {orderId, memberId, amount}   → 회원 서비스 GET /members/{id} (VIP 할인)
//
// 외부 의존성 없이 node:http 만 사용한다. 서비스 간 호출은 평문 HTTP/1.1.
'use strict';

const http = require('node:http');
const crypto = require('node:crypto');

const PORT = Number(process.env.PORT || 8080);
const MEMBER_URL = new URL(process.env.MEMBER_URL || 'http://member-service:8080');
const agent = new http.Agent({ keepAlive: true, maxSockets: 50 });

function log(level, msg) {
  console.log(`${new Date().toISOString()} ${level} payment-service ${msg}`);
}

function send(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', (chunk) => { data += chunk; });
    req.on('end', () => resolve(data));
    req.on('error', reject);
  });
}

// 회원 조회. 연결 실패·타임아웃이면 status 0
function getMember(memberId, reqId) {
  return new Promise((resolve) => {
    const req = http.get({
      host: MEMBER_URL.hostname,
      port: MEMBER_URL.port || 80,
      path: `/members/${encodeURIComponent(memberId)}`,
      headers: { 'X-Request-Id': reqId, Accept: 'application/json' },
      agent,
      timeout: 3000,
    }, (res) => {
      let data = '';
      res.on('data', (chunk) => { data += chunk; });
      res.on('end', () => resolve({ status: res.statusCode, body: data }));
    });
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', (err) => resolve({ status: 0, body: '', error: err.message }));
  });
}

const server = http.createServer(async (req, res) => {
  const reqId = req.headers['x-request-id'] || crypto.randomBytes(8).toString('hex');

  if (req.method === 'GET' && req.url === '/health') {
    return send(res, 200, { status: 'UP' });
  }

  if (req.method === 'POST' && req.url === '/payments') {
    let body;
    try {
      body = JSON.parse(await readBody(req) || '{}');
    } catch (err) {
      log('WARN', `invalid payment body req=${reqId}: ${err.message}`);
      return send(res, 400, { error: 'invalid json' });
    }
    if (!body.orderId || !body.memberId || !(body.amount > 0)) {
      log('WARN', `rejected payment req=${reqId} orderId=${body.orderId} memberId=${body.memberId} amount=${body.amount}`);
      return send(res, 400, { error: 'orderId, memberId and amount are required' });
    }

    const member = await getMember(body.memberId, reqId);
    if (member.status !== 200) {
      log('WARN', `member lookup failed req=${reqId} memberId=${body.memberId} status=${member.status} ${member.error || ''}`);
      return send(res, 502, { error: `member-service returned ${member.status}` });
    }
    const grade = JSON.parse(member.body).grade;
    const charged = grade === 'VIP' ? Math.round(body.amount * 0.9) : body.amount;

    // PG 승인처럼 보이도록 20~80ms 지연
    const delay = 20 + Math.floor(Math.random() * 60);
    setTimeout(() => {
      send(res, 201, {
        paymentId: crypto.randomUUID(),
        orderId: body.orderId,
        amount: body.amount,
        charged,
        grade,
        status: 'APPROVED',
      });
    }, delay);
    return;
  }

  send(res, 404, { error: 'not found' });
});

server.listen(PORT, () => log('INFO', `listening on :${PORT} member=${MEMBER_URL.origin}`));
