// Tests the relay against a local mock of the Claude API. Run: npm test
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { createProxyServer, loadConfig } from './server.mjs';

const TOKEN = 'test-app-token-123';
const KEY = 'sk-ant-test-key';

async function listen(server) {
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  return `http://127.0.0.1:${server.address().port}`;
}

/** Mock upstream: records requests, streams SSE for /v1/messages. */
function createMockUpstream() {
  const seen = [];
  let closedEarly = false;
  const server = http.createServer(async (req, res) => {
    const chunks = [];
    for await (const c of req) chunks.push(c);
    const body = Buffer.concat(chunks);
    seen.push({ method: req.method, url: req.url, headers: req.headers, body });
    if (req.url === '/v1/messages') {
      const parsed = JSON.parse(body.toString());
      if (parsed.model === 'overloaded') {
        res.writeHead(529, { 'content-type': 'application/json', 'retry-after': '7', 'request-id': 'req_1' });
        res.end(JSON.stringify({ type: 'error', error: { type: 'overloaded_error', message: 'Overloaded' } }));
        return;
      }
      res.writeHead(200, { 'content-type': 'text/event-stream', 'request-id': 'req_2' });
      res.write('event: message_start\ndata: {"type":"message_start","message":{"model":"claude-sonnet-5-5"}}\n\n');
      res.on('close', () => { if (!res.writableFinished) closedEarly = true; });
      const delay = parsed.slow ? 1500 : 300;
      setTimeout(() => {
        if (res.destroyed) return;
        res.write('event: message_stop\ndata: {"type":"message_stop"}\n\n');
        res.end();
      }, delay);
      return;
    }
    if (req.url === '/v1/files') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ id: 'file_abc', size: body.length, ctype: req.headers['content-type'] }));
      return;
    }
    if (req.url === '/v1/models') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ data: [{ id: 'claude-sonnet-5-5' }] }));
      return;
    }
    res.writeHead(404);
    res.end();
  });
  return { server, seen, wasClosedEarly: () => closedEarly };
}

async function setup(env = {}) {
  const mock = createMockUpstream();
  const upstreamURL = await listen(mock.server);
  const proxy = createProxyServer(loadConfig({
    ANTHROPIC_API_KEY: KEY, APP_TOKEN: TOKEN, ANTHROPIC_BASE_URL: upstreamURL, ...env,
  }));
  const base = await listen(proxy);
  const close = () => { proxy.close(); mock.server.close(); proxy.closeAllConnections?.(); mock.server.closeAllConnections?.(); };
  return { base, mock, close };
}

const auth = { authorization: `Bearer ${TOKEN}` };

test('health reports configured state', async () => {
  const { base, close } = await setup();
  const r = await fetch(`${base}/health`);
  assert.equal(r.status, 200);
  assert.deepEqual((await r.json()).configured, true);
  close();
});

test('unconfigured server refuses API calls with 503', async () => {
  const proxy = createProxyServer(loadConfig({ ANTHROPIC_API_KEY: '', APP_TOKEN: '' }));
  const base = await listen(proxy);
  const r = await fetch(`${base}/v1/messages`, { method: 'POST', body: '{}' });
  assert.equal(r.status, 503);
  const h = await (await fetch(`${base}/health`)).json();
  assert.equal(h.configured, false);
  proxy.close();
});

test('rejects missing or wrong app token', async () => {
  const { base, mock, close } = await setup();
  let r = await fetch(`${base}/v1/messages`, { method: 'POST', body: '{"model":"m"}' });
  assert.equal(r.status, 401);
  assert.equal((await r.json()).error.type, 'authentication_error');
  r = await fetch(`${base}/v1/messages`, { method: 'POST', headers: { authorization: 'Bearer nope' }, body: '{}' });
  assert.equal(r.status, 401);
  assert.equal(mock.seen.length, 0);
  close();
});

test('forwards messages with the server key and streams SSE incrementally', async () => {
  const { base, mock, close } = await setup();
  const t0 = Date.now();
  const r = await fetch(`${base}/v1/messages`, {
    method: 'POST',
    headers: { ...auth, 'content-type': 'application/json', 'anthropic-version': '2023-06-01', 'anthropic-beta': 'server-side-fallback-2026-07-01', 'x-api-key': 'client-should-not-pass' },
    body: JSON.stringify({ model: 'claude-sonnet-5-5', stream: true, messages: [] }),
  });
  assert.equal(r.status, 200);
  assert.match(r.headers.get('content-type'), /text\/event-stream/);
  assert.equal(r.headers.get('request-id'), 'req_2');
  const reader = r.body.getReader();
  const first = await reader.read();
  const firstAt = Date.now() - t0;
  assert.match(Buffer.from(first.value).toString(), /message_start/);
  assert.ok(firstAt < 280, `first event should arrive before the upstream finishes (took ${firstAt}ms)`);
  let rest = '';
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    rest += Buffer.from(value).toString();
  }
  assert.match(rest, /message_stop/);
  const sent = mock.seen[0];
  assert.equal(sent.headers['x-api-key'], KEY);
  assert.equal(sent.headers['anthropic-beta'], 'server-side-fallback-2026-07-01');
  assert.equal(sent.headers['anthropic-version'], '2023-06-01');
  assert.equal(sent.headers['authorization'], undefined);
  close();
});

test('passes upstream errors through unchanged', async () => {
  const { base, close } = await setup();
  const r = await fetch(`${base}/v1/messages`, { method: 'POST', headers: auth, body: JSON.stringify({ model: 'overloaded' }) });
  assert.equal(r.status, 529);
  assert.equal(r.headers.get('retry-after'), '7');
  assert.equal((await r.json()).error.type, 'overloaded_error');
  close();
});

test('enforces the model allowlist when set', async () => {
  const { base, mock, close } = await setup({ ALLOWED_MODELS: 'claude-sonnet-5-5,claude-haiku-5-5' });
  const bad = await fetch(`${base}/v1/messages`, { method: 'POST', headers: auth, body: JSON.stringify({ model: 'claude-fable-5-1' }) });
  assert.equal(bad.status, 400);
  const good = await fetch(`${base}/v1/messages`, { method: 'POST', headers: auth, body: JSON.stringify({ model: 'claude-sonnet-5-5' }) });
  assert.equal(good.status, 200);
  await good.text();
  assert.equal(mock.seen.length, 1);
  close();
});

test('relays multipart file uploads byte for byte', async () => {
  const { base, mock, close } = await setup();
  const boundary = 'XYZ';
  const payload = Buffer.concat([
    Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="a.pdf"\r\nContent-Type: application/pdf\r\n\r\n`),
    Buffer.from([0, 1, 2, 3, 255, 254]),
    Buffer.from(`\r\n--${boundary}--\r\n`),
  ]);
  const r = await fetch(`${base}/v1/files`, {
    method: 'POST', headers: { ...auth, 'content-type': `multipart/form-data; boundary=${boundary}` }, body: payload,
  });
  assert.equal(r.status, 200);
  const j = await r.json();
  assert.equal(j.id, 'file_abc');
  assert.equal(j.ctype, `multipart/form-data; boundary=${boundary}`);
  assert.ok(mock.seen[0].body.equals(payload));
  close();
});

test('lists models', async () => {
  const { base, close } = await setup();
  const r = await fetch(`${base}/v1/models`, { headers: auth });
  assert.equal(r.status, 200);
  assert.equal((await r.json()).data[0].id, 'claude-sonnet-5-5');
  close();
});

test('rejects oversized bodies', async () => {
  const { base, mock, close } = await setup({ MAX_BODY_MB: '1' });
  const big = 'x'.repeat(1024 * 1024 + 10);
  const r = await fetch(`${base}/v1/messages`, { method: 'POST', headers: auth, body: JSON.stringify({ model: 'm', big }) });
  assert.equal(r.status, 413);
  assert.equal(mock.seen.length, 0);
  close();
});

test('rate limits per client', async () => {
  const { base, close } = await setup({ RATE_LIMIT_PER_MINUTE: '2' });
  for (let i = 0; i < 2; i++) {
    const r = await fetch(`${base}/v1/models`, { headers: auth });
    assert.equal(r.status, 200);
    await r.text();
  }
  const r = await fetch(`${base}/v1/models`, { headers: auth });
  assert.equal(r.status, 429);
  assert.ok(Number(r.headers.get('retry-after')) > 0);
  close();
});

test('cancels the upstream request when the app disconnects', async () => {
  const { base, mock, close } = await setup();
  const controller = new AbortController();
  const r = await fetch(`${base}/v1/messages`, {
    method: 'POST', headers: auth, body: JSON.stringify({ model: 'claude-sonnet-5-5', slow: true }), signal: controller.signal,
  });
  const reader = r.body.getReader();
  await reader.read();
  controller.abort();
  await new Promise((resolve) => setTimeout(resolve, 400));
  assert.equal(mock.wasClosedEarly(), true);
  close();
});

test('unknown routes are 404', async () => {
  const { base, close } = await setup();
  const r = await fetch(`${base}/v1/complete`, { method: 'POST', headers: auth, body: '{}' });
  assert.equal(r.status, 404);
  close();
});
