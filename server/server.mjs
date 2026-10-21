// Tutor Notes backend: a small authenticated relay between the iPad app and the Claude API.
//
// The app builds Claude requests itself (there is no official Swift SDK), so this server
// doesn't construct or reinterpret them: it checks the app's access token, applies limits,
// adds the Anthropic API key from the environment, and streams the response straight back.
// That keeps the key off the device.
//
// Environment:
//   ANTHROPIC_API_KEY      required — your Claude API key
//   APP_TOKEN              required — a long random secret; the app sends it as a Bearer token
//   PORT                   provided by Railway (default 8080)
//   ALLOWED_MODELS         optional — comma-separated model ids the app may use
//   MAX_BODY_MB            optional — largest request body accepted (default 40)
//   RATE_LIMIT_PER_MINUTE  optional — requests per minute per client (default 60)
//   ANTHROPIC_BASE_URL     optional — upstream override (used by the tests)

import http from 'node:http';
import { Readable, Transform } from 'node:stream';
import { createHash, timingSafeEqual } from 'node:crypto';
import { pathToFileURL } from 'node:url';

export function loadConfig(env = process.env) {
  return {
    port: Number(env.PORT || 8080),
    apiKey: (env.ANTHROPIC_API_KEY || '').trim(),
    appToken: (env.APP_TOKEN || '').trim(),
    upstream: (env.ANTHROPIC_BASE_URL || 'https://api.anthropic.com').replace(/\/+$/, ''),
    maxBodyBytes: Math.max(1, Number(env.MAX_BODY_MB || 40)) * 1024 * 1024,
    rateLimitPerMinute: Math.max(1, Number(env.RATE_LIMIT_PER_MINUTE || 60)),
    allowedModels: (env.ALLOWED_MODELS || '').split(',').map((s) => s.trim()).filter(Boolean),
  };
}

const ROUTES = {
  'POST /v1/messages': { buffered: true },
  'POST /v1/files': { buffered: false },
  'GET /v1/models': { buffered: false },
};

// Request headers we pass through to Anthropic. Everything else (cookies, the app token,
// forwarding headers) stays here.
const FORWARD_REQUEST_HEADERS = ['content-type', 'accept', 'anthropic-version', 'anthropic-beta'];
const FORWARD_RESPONSE_HEADERS = [
  'content-type', 'request-id', 'retry-after', 'anthropic-organization-id',
  'anthropic-ratelimit-requests-limit', 'anthropic-ratelimit-requests-remaining', 'anthropic-ratelimit-requests-reset',
  'anthropic-ratelimit-tokens-limit', 'anthropic-ratelimit-tokens-remaining', 'anthropic-ratelimit-tokens-reset',
];

function sendJSON(res, status, body, extraHeaders = {}) {
  if (res.headersSent) return res.end();
  const data = JSON.stringify(body);
  res.writeHead(status, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(data), ...extraHeaders });
  res.end(data);
}

function apiError(res, status, type, message, extraHeaders) {
  // Same shape as Anthropic's errors, so the app's error handling works unchanged.
  sendJSON(res, status, { type: 'error', error: { type, message } }, extraHeaders);
}

function tokensMatch(given, expected) {
  if (!given || !expected) return false;
  const a = createHash('sha256').update(given).digest();
  const b = createHash('sha256').update(expected).digest();
  return timingSafeEqual(a, b);
}

function presentedToken(req) {
  const auth = req.headers['authorization'] || '';
  if (auth.toLowerCase().startsWith('bearer ')) return auth.slice(7).trim();
  return (req.headers['x-app-token'] || '').toString().trim();
}

function clientKey(req) {
  const fwd = (req.headers['x-forwarded-for'] || '').toString().split(',')[0].trim();
  return fwd || req.socket.remoteAddress || 'unknown';
}

/** Fixed one-minute windows per client; enough to stop a leaked token from running up a bill. */
function createRateLimiter(limit) {
  const windows = new Map();
  return (key, now = Date.now()) => {
    const minute = Math.floor(now / 60_000);
    const w = windows.get(key);
    if (!w || w.minute !== minute) {
      windows.set(key, { minute, count: 1 });
      if (windows.size > 10_000) {
        for (const [k, v] of windows) if (v.minute !== minute) windows.delete(k);
      }
      return { ok: true };
    }
    w.count += 1;
    if (w.count > limit) return { ok: false, retryAfter: 60 - Math.floor((now % 60_000) / 1000) };
    return { ok: true };
  };
}

async function readBody(req, limit) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > limit) {
      const err = new Error('Request body too large');
      err.code = 'TOO_LARGE';
      throw err;
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

/** Wraps the incoming request stream so an oversized upload is cut off as it streams. */
function limitedStream(req, limit, onTooLarge) {
  let size = 0;
  const counter = new Transform({
    transform(chunk, _enc, cb) {
      size += chunk.length;
      if (size > limit) {
        onTooLarge();
        cb(new Error('Request body too large'));
        return;
      }
      cb(null, chunk);
    },
  });
  return Readable.toWeb(req.pipe(counter));
}

export function createProxyServer(config = loadConfig()) {
  const rateLimit = createRateLimiter(config.rateLimitPerMinute);
  const configured = Boolean(config.apiKey && config.appToken);

  return http.createServer(async (req, res) => {
    const started = Date.now();
    const url = new URL(req.url || '/', 'http://localhost');
    const routeKey = `${req.method} ${url.pathname}`;
    let model = '-';
    res.on('finish', () => {
      if (url.pathname !== '/health') {
        console.log(`${req.method} ${url.pathname} ${res.statusCode} ${Date.now() - started}ms model=${model}`);
      }
    });

    if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/health')) {
      return sendJSON(res, 200, {
        ok: true,
        configured,
        service: 'tutor-notes-server',
        ...(configured ? {} : { problem: 'Set ANTHROPIC_API_KEY and APP_TOKEN in the service variables.' }),
      });
    }

    const route = ROUTES[routeKey];
    if (!route) return apiError(res, 404, 'not_found_error', `No route for ${routeKey}`);
    if (!configured) {
      return apiError(res, 503, 'api_error', 'Server is not configured: set ANTHROPIC_API_KEY and APP_TOKEN.');
    }
    if (!tokensMatch(presentedToken(req), config.appToken)) {
      return apiError(res, 401, 'authentication_error', 'Missing or invalid app token.');
    }
    const limited = rateLimit(clientKey(req));
    if (!limited.ok) {
      return apiError(res, 429, 'rate_limit_error', 'Too many requests to the tutor server.', { 'retry-after': String(limited.retryAfter) });
    }
    const declared = Number(req.headers['content-length'] || 0);
    if (declared > config.maxBodyBytes) {
      return apiError(res, 413, 'request_too_large', `Request body exceeds ${Math.round(config.maxBodyBytes / 1048576)} MB.`);
    }

    const headers = { 'x-api-key': config.apiKey };
    for (const h of FORWARD_REQUEST_HEADERS) {
      if (req.headers[h]) headers[h] = req.headers[h];
    }
    if (!headers['anthropic-version']) headers['anthropic-version'] = '2023-06-01';

    const controller = new AbortController();
    // Client went away (e.g. the student pressed Stop): cancel the upstream request too.
    res.on('close', () => { if (!res.writableFinished) controller.abort(); });

    let body;
    let tooLarge = false;
    try {
      if (req.method === 'POST' && route.buffered) {
        const buf = await readBody(req, config.maxBodyBytes);
        if (config.allowedModels.length) {
          let parsed;
          try { parsed = JSON.parse(buf.toString('utf8')); } catch {
            return apiError(res, 400, 'invalid_request_error', 'Body is not valid JSON.');
          }
          model = typeof parsed.model === 'string' ? parsed.model : '-';
          if (!config.allowedModels.includes(model)) {
            return apiError(res, 400, 'invalid_request_error', `Model ${model} is not enabled on this server.`);
          }
        } else {
          const m = /"model"\s*:\s*"([^"]{1,100})"/.exec(buf.subarray(0, 4096).toString('utf8'));
          if (m) model = m[1];
        }
        body = buf;
        headers['content-length'] = String(buf.length);
      } else if (req.method === 'POST') {
        body = limitedStream(req, config.maxBodyBytes, () => { tooLarge = true; controller.abort(); });
        if (req.headers['content-length']) headers['content-length'] = req.headers['content-length'];
      }
    } catch (err) {
      if (err.code === 'TOO_LARGE') {
        return apiError(res, 413, 'request_too_large', `Request body exceeds ${Math.round(config.maxBodyBytes / 1048576)} MB.`);
      }
      return apiError(res, 400, 'invalid_request_error', 'Could not read request body.');
    }

    let upstream;
    try {
      upstream = await fetch(config.upstream + url.pathname + url.search, {
        method: req.method,
        headers,
        body,
        duplex: body && !(body instanceof Buffer) ? 'half' : undefined,
        signal: controller.signal,
      });
    } catch (err) {
      if (tooLarge) return apiError(res, 413, 'request_too_large', 'Request body too large.');
      if (controller.signal.aborted) return res.destroy();
      console.error(`upstream error: ${err.message}`);
      return apiError(res, 502, 'api_error', 'Could not reach the Claude API.');
    }

    const outHeaders = {};
    for (const h of FORWARD_RESPONSE_HEADERS) {
      const v = upstream.headers.get(h);
      if (v) outHeaders[h] = v;
    }
    if ((outHeaders['content-type'] || '').includes('text/event-stream')) {
      outHeaders['cache-control'] = 'no-cache';
      outHeaders['x-accel-buffering'] = 'no';
    }
    res.writeHead(upstream.status, outHeaders);
    res.flushHeaders();
    if (!upstream.body) return res.end();
    const stream = Readable.fromWeb(upstream.body);
    stream.on('error', () => res.destroy());
    stream.pipe(res);
  });
}

const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  const config = loadConfig();
  if (!config.apiKey || !config.appToken) {
    console.warn('WARNING: ANTHROPIC_API_KEY and APP_TOKEN must both be set; API routes return 503 until they are.');
  }
  const server = createProxyServer(config);
  // Streams can run for minutes on hard problems; don't let Node time them out.
  server.requestTimeout = 0;
  server.headersTimeout = 65_000;
  server.keepAliveTimeout = 61_000;
  server.listen(config.port, () => console.log(`tutor-notes-server listening on :${config.port}`));
  const shutdown = () => server.close(() => process.exit(0));
  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
}
