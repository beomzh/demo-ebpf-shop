// 결제 서비스 (Node.js) — 외부 의존성 없이 node:http 만 사용한다.
'use strict';

const http = require('node:http');
const crypto = require('node:crypto');

const PORT = Number(process.env.PORT || 8080);

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

const server = http.createServer(async (req, res) => {
  if (req.method === 'GET' && req.url === '/health') {
    return send(res, 200, { status: 'UP' });
  }

  if (req.method === 'POST' && req.url === '/payments') {
    let body;
    try {
      body = JSON.parse(await readBody(req) || '{}');
    } catch (err) {
      log('WARN', `invalid payment body: ${err.message}`);
      return send(res, 400, { error: 'invalid json' });
    }
    if (!body.orderId || !(body.amount > 0)) {
      log('WARN', `rejected payment orderId=${body.orderId} amount=${body.amount}`);
      return send(res, 400, { error: 'orderId and amount are required' });
    }
    // PG 승인처럼 보이도록 20~80ms 지연
    const delay = 20 + Math.floor(Math.random() * 60);
    setTimeout(() => {
      send(res, 201, {
        paymentId: crypto.randomUUID(),
        orderId: body.orderId,
        amount: body.amount,
        status: 'APPROVED',
      });
    }, delay);
    return;
  }

  send(res, 404, { error: 'not found' });
});

server.listen(PORT, () => log('INFO', `listening on :${PORT}`));
