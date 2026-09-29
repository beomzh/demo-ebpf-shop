// 결제 서비스 (Node.js) — 주문 서비스가 호출하고, 회원 등급을 확인하려고 회원 서비스를 호출한다.
//
//   POST /payments {orderId, memberId, amount}   → 회원 서비스 GET /members/{id} (VIP 할인)
//                                                → 외부 PG사 POST https://<PG_DOMAIN>/v1/payments/approve (승인)
//
// PG 도메인은 평범하게 OS 리졸버(getaddrinfo)로 조회한다. 파드의 DNS 서버가 사내 DNS(주·보조)이므로
// 레코드가 없으면 'getaddrinfo ENOTFOUND', 주 DNS 가 없으면 OS 리졸버가 알아서 보조 DNS 에 묻는다.
// 외부 의존성 없이 node 내장 모듈만 사용한다. 서비스 간 호출은 평문 HTTP/1.1.
'use strict';

const http = require('node:http');
const https = require('node:https');
const fs = require('node:fs');
const crypto = require('node:crypto');

const PORT = Number(process.env.PORT || 8080);
const MEMBER_URL = new URL(process.env.MEMBER_URL || 'http://member-service:8080');
const agent = new http.Agent({ keepAlive: true, maxSockets: 50 });

const PG_DOMAIN = process.env.PG_DOMAIN || 'api.pg.example';
const PG_CA_FILE = process.env.PG_CA_FILE || '/etc/demo-ca/ca.crt';
const PG_CA = fs.existsSync(PG_CA_FILE) ? fs.readFileSync(PG_CA_FILE) : undefined;

function log(level, msg) {
  console.log(`${new Date().toISOString()} ${level} payment-service ${msg}`);
}

const SERVICE = 'payment-service';

// "payment-service → <target>[상태]" 뒤에 하위 서비스가 보낸 errorPath 를 이어 붙인다
function errorPath(target, result) {
  if (result.status === 0) return `${SERVICE} → ${target} [${result.error} after ${result.ms}ms]`;
  const head = `${SERVICE} → ${target}[${result.status}]`;
  try {
    const upstream = JSON.parse(result.body).errorPath;
    if (upstream) return upstream.startsWith(target) ? head + upstream.slice(target.length) : `${head} → ${upstream}`;
  } catch (_) { /* 본문이 JSON 이 아니면 상태코드까지만 */ }
  return head;
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
  const started = Date.now();
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
      res.on('end', () => resolve({ status: res.statusCode, body: data, ms: Date.now() - started }));
    });
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', (err) => resolve({ status: 0, body: '', error: `${err.code || err.name}: ${err.message}`, stack: err.stack, ms: Date.now() - started }));
  });
}

// 외부 PG 승인. 결과는 { status, body, ms, error?, stack? } (연결 실패·타임아웃이면 status 0)
function approveAtPg(payload, reqId) {
  const started = Date.now();
  return new Promise((resolve) => {
    const body = JSON.stringify(payload);
    const req = https.request({
      host: PG_DOMAIN,
      port: 443,
      path: '/v1/payments/approve',
      method: 'POST',
      ca: PG_CA,
      timeout: 3000,
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body), 'X-Request-Id': reqId },
    }, (res) => {
      let data = '';
      res.on('data', (chunk) => { data += chunk; });
      res.on('end', () => resolve({ status: res.statusCode, body: data, ms: Date.now() - started }));
    });
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', (err) => resolve({ status: 0, body: '', ms: Date.now() - started, error: `${err.code || err.name}: ${err.message}`, stack: err.stack }));
    req.end(body);
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
      const path = errorPath('member-service', member);
      const url = `${MEMBER_URL.origin}/members/${body.memberId}`;
      log(member.status === 0 ? 'ERROR' : 'WARN',
        `upstream call failed req=${reqId} target=member-service call="GET ${url}" status=${member.status} elapsedMs=${member.ms} orderId=${body.orderId} path="${path}"`
        + (member.stack ? `\n${member.stack}` : ''));
      return send(res, member.status === 0 ? 504 : 502, { error: 'member-service call failed', errorPath: path });
    }
    const grade = JSON.parse(member.body).grade;
    const charged = grade === 'VIP' ? Math.round(body.amount * 0.9) : body.amount;

    // 외부 PG 승인 (HTTPS)
    const pg = await approveAtPg({ orderId: body.orderId, amount: charged }, reqId);
    if (pg.status !== 200) {
      const target = `pg(${PG_DOMAIN})`;
      const path = errorPath(target, pg);
      const url = `https://${PG_DOMAIN}/v1/payments/approve`;
      log(pg.status === 0 ? 'ERROR' : 'WARN',
        `upstream call failed req=${reqId} target=${target} call="POST ${url}" status=${pg.status} elapsedMs=${pg.ms} orderId=${body.orderId} path="${path}"`
        + (pg.stack ? `\n${pg.stack}` : ''));
      return send(res, pg.status === 0 ? 504 : 502, { error: 'pg call failed', errorPath: path });
    }

    const paymentId = crypto.randomUUID();
    log('INFO', `payment approved req=${reqId} orderId=${body.orderId} paymentId=${paymentId} amount=${body.amount} charged=${charged} grade=${grade} pg=${PG_DOMAIN} memberMs=${member.ms} pgMs=${pg.ms}`);
    send(res, 201, {
      paymentId,
      orderId: body.orderId,
      amount: body.amount,
      charged,
      grade,
      status: 'APPROVED',
      pg: JSON.parse(pg.body),
    });
    return;
  }

  send(res, 404, { error: 'not found' });
});

server.listen(PORT, () => log('INFO', `listening on :${PORT} member=${MEMBER_URL.origin}`));
