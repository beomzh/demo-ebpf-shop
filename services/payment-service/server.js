// 결제 서비스 (Node.js) — 주문 서비스가 호출하고, 회원 등급을 확인하려고 회원 서비스를 호출한다.
//
//   POST /payments {orderId, memberId, amount}   → 회원 서비스 GET /members/{id} (VIP 할인)
//                                                → 외부 PG사 POST https://<PG_DOMAIN>/v1/payments/approve (승인)
//
// PG 도메인은 클러스터 DNS 가 아니라 "사내 DNS"(PG_DNS_SERVERS: 주, 보조 순)에 직접 질의한다.
//   - 주 DNS 가 응답하지 않으면(ETIMEOUT·ECONNREFUSED·ESERVFAIL) 보조 DNS 로 넘어가고, 그 과정을 WARN 으로 남긴다
//   - NXDOMAIN(ENOTFOUND)은 "그런 이름은 없다"는 확정 응답이므로 보조로 넘어가지 않고 바로 실패한다 (OS 리졸버와 같은 동작)
//   - PG_DNS_SERVERS 가 비어 있으면 OS 리졸버(getaddrinfo)를 쓴다 → 실패 시 'getaddrinfo ENOTFOUND'
// 외부 의존성 없이 node 내장 모듈만 사용한다. 서비스 간 호출은 평문 HTTP/1.1.
'use strict';

const http = require('node:http');
const https = require('node:https');
const dns = require('node:dns');
const fs = require('node:fs');
const crypto = require('node:crypto');

const PORT = Number(process.env.PORT || 8080);
const MEMBER_URL = new URL(process.env.MEMBER_URL || 'http://member-service:8080');
const agent = new http.Agent({ keepAlive: true, maxSockets: 50 });

const PG_DOMAIN = process.env.PG_DOMAIN || 'api.pg.example';
const PG_DNS_SERVERS = (process.env.PG_DNS_SERVERS || '').split(',').map((v) => v.trim()).filter(Boolean);
const PG_DNS_TIMEOUT_MS = Number(process.env.PG_DNS_TIMEOUT_MS || 2000);
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

// Node.js DNS 에러 코드 → DNS 응답 이름 (로그에 NXDOMAIN 등으로 분명히 남기기 위해)
const DNS_RESULT = {
  ENOTFOUND: 'NXDOMAIN',     // 그런 이름 없음 (사내 DNS 에 레코드 미등록)
  ENODATA: 'NODATA',         // 이름은 있지만 A 레코드 없음
  ESERVFAIL: 'SERVFAIL',     // DNS 서버 내부 오류
  EREFUSED: 'REFUSED',       // DNS 서버가 질의 거부
  ETIMEOUT: 'TIMEOUT',       // DNS 서버 응답 없음
  ECONNREFUSED: 'CONNREFUSED',
};
const DNS_MEANING = {
  NXDOMAIN: '사내 DNS 에 이 도메인 레코드가 없음',
  NODATA: '사내 DNS 에 이 도메인의 A 레코드가 없음',
  SERVFAIL: '사내 DNS 서버 오류',
  REFUSED: '사내 DNS 가 질의를 거부함',
  TIMEOUT: '사내 DNS 가 응답하지 않음',
  CONNREFUSED: '사내 DNS 포트가 닫혀 있음',
};
const dnsResult = (err) => DNS_RESULT[err.code] || err.code;

// PG 도메인을 사내 DNS 에 주 → 보조 순서로 질의한다. 실패하면 마지막 DNS 에러(err.attempts, err.dnsResult 포함)를 던진다.
async function resolvePg(host) {
  if (PG_DNS_SERVERS.length === 0) {
    const { address } = await dns.promises.lookup(host, { family: 4 });   // OS 리졸버
    return { ip: address, attempts: [] };
  }
  const attempts = [];
  let lastErr;
  for (const [i, server] of PG_DNS_SERVERS.entries()) {
    const who = `${i === 0 ? 'primary' : 'secondary'} ${server}`;
    const resolver = new dns.promises.Resolver({ timeout: PG_DNS_TIMEOUT_MS, tries: 1 });
    resolver.setServers([server]);
    const started = Date.now();
    try {
      const [ip] = await resolver.resolve4(host);
      attempts.push(`${who} → ${ip} (${Date.now() - started}ms)`);
      return { ip, attempts };
    } catch (err) {
      attempts.push(`${who} → ${dnsResult(err)} (${err.code}, ${Date.now() - started}ms)`);
      lastErr = err;
      lastErr.server = who;
      if (err.code === 'ENOTFOUND' || err.code === 'ENODATA') break;   // NXDOMAIN: 확정 응답 → 보조로 넘어가지 않음
    }
  }
  lastErr.attempts = attempts;
  lastErr.dnsResult = dnsResult(lastErr);
  throw lastErr;
}

// 외부 PG 승인. 결과는 { status, body, ms, error?, stack?, attempts }
async function approveAtPg(payload, reqId) {
  const started = Date.now();
  let resolved;
  try {
    resolved = await resolvePg(PG_DOMAIN);
  } catch (err) {
    const result = err.dnsResult || dnsResult(err);
    return {
      status: 0, body: '', ms: Date.now() - started, stack: err.stack, attempts: err.attempts || [],
      dns: { result, server: err.server || 'system resolver', meaning: DNS_MEANING[result] || err.message },
      error: `DNS ${result}: ${PG_DOMAIN} (${err.message})`,
    };
  }
  return new Promise((resolve) => {
    const body = JSON.stringify(payload);
    const req = https.request({
      host: resolved.ip,          // 사내 DNS 로 얻은 IP 로 연결하고
      servername: PG_DOMAIN,      // TLS SNI·인증서 검증은 PG 도메인으로
      port: 443,
      path: '/v1/payments/approve',
      method: 'POST',
      ca: PG_CA,
      timeout: 3000,
      headers: { Host: PG_DOMAIN, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body), 'X-Request-Id': reqId },
    }, (res) => {
      let data = '';
      res.on('data', (chunk) => { data += chunk; });
      res.on('end', () => resolve({ status: res.statusCode, body: data, ms: Date.now() - started, attempts: resolved.attempts }));
    });
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', (err) => resolve({ status: 0, body: '', ms: Date.now() - started, error: `${err.code || err.name}: ${err.message}`, stack: err.stack, attempts: resolved.attempts }));
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

    // 외부 PG 승인 (사내 DNS 로 PG 도메인 조회 → HTTPS)
    const pg = await approveAtPg({ orderId: body.orderId, amount: charged }, reqId);
    const target = `pg(${PG_DOMAIN})`;
    if (pg.attempts.length > 1 && pg.status !== 0) {
      log('WARN', `dns fallback req=${reqId} host=${PG_DOMAIN} attempts="${pg.attempts.join(' | ')}"`);
    }
    if (pg.status !== 200) {
      const url = `https://${PG_DOMAIN}/v1/payments/approve`;
      if (pg.dns) {
        // 원인 한 줄: 어느 DNS 가 무엇이라고 답했는지
        log('ERROR', `dns lookup failed req=${reqId} host=${PG_DOMAIN} result=${pg.dns.result} server="${pg.dns.server}" — ${pg.dns.meaning}`);
      }
      const dnsInfo = pg.attempts.length ? ` dns="${pg.attempts.join(' | ')}"` : '';
      const path = pg.status === 0
        ? `${SERVICE} → ${target} [${pg.error}${dnsInfo ? ' —' + dnsInfo.replace(/^ dns=/, ' ').replace(/"/g, '') : ''}]`
        : `${SERVICE} → ${target}[${pg.status}]`;
      log(pg.status === 0 ? 'ERROR' : 'WARN',
        `upstream call failed req=${reqId} target=${target} call="POST ${url}" status=${pg.status} elapsedMs=${pg.ms} orderId=${body.orderId}${dnsInfo} path="${path}"`
        + (pg.stack ? `\n${pg.stack}` : ''));
      return send(res, pg.status === 0 ? 504 : 502, { error: 'pg call failed', errorPath: path });
    }

    send(res, 201, {
      paymentId: crypto.randomUUID(),
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
