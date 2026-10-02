import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { createHandler } from '../api/v1/me.js';
import { createRoute } from '../lib/route.js';

const requestId = '11111111-1111-4111-8111-111111111111';
const allowed = 'https://frontend.example.com';

function invoke(handler, { method = 'GET', origin, authorization } = {}) {
  const result = { headers: {}, statusCode: 200 };
  const headers = {};
  if (origin !== undefined) headers.origin = origin;
  if (authorization !== undefined) headers.authorization = authorization;
  const res = {
    setHeader(name, value) { result.headers[name] = value; },
    status(value) { result.statusCode = value; return this; },
    json(body) { result.body = body; return result; },
    end() { return result; }
  };
  return handler({ method, headers }, res);
}

test('CORS uses exact allowlisted origins and always varies on Origin', async () => {
  const handler = createHandler({
    env: { CORS_ALLOWED_ORIGINS: allowed },
    createRequestId: () => requestId,
    request: async () => assert.fail('network called')
  });
  const cases = [
    [allowed, allowed],
    ['https://frontend.example.com.evil.com', undefined],
    ['http://frontend.example.com', undefined],
    ['null', undefined],
    [undefined, undefined]
  ];
  for (const [origin, expected] of cases) {
    const result = await invoke(handler, { origin });
    assert.equal(result.statusCode, 401);
    assert.equal(result.headers.Vary, 'Origin');
    assert.equal(result.headers['Access-Control-Allow-Origin'], expected);
    assert.equal(result.headers['Access-Control-Allow-Credentials'], undefined);
  }
});

test('invalid, wildcard and empty CORS configuration fail closed', async () => {
  for (const configured of ['', '*', 'https://frontend.example.com/path']) {
    const handler = createHandler({
      env: { CORS_ALLOWED_ORIGINS: configured },
      createRequestId: () => requestId,
      request: async () => assert.fail('network called')
    });
    const result = await invoke(handler, { origin: allowed });
    assert.equal(result.headers['Access-Control-Allow-Origin'], undefined);
    assert.equal(result.headers.Vary, 'Origin');
  }
});

test('allowed preflight is unauthenticated, bodyless and never reaches upstream', async () => {
  let called = false;
  const handler = createHandler({
    env: { CORS_ALLOWED_ORIGINS: allowed },
    createRequestId: () => requestId,
    request: async () => { called = true; }
  });
  const result = await invoke(handler, { method: 'OPTIONS', origin: allowed });
  assert.equal(called, false);
  assert.equal(result.statusCode, 204);
  assert.equal(result.body, undefined);
  assert.equal(result.headers['X-Request-Id'], requestId);
  assert.equal(result.headers['Access-Control-Allow-Origin'], allowed);
  assert.equal(result.headers['Access-Control-Allow-Methods'], 'GET, HEAD, PATCH');
  assert.equal(result.headers['Access-Control-Allow-Headers'], 'Authorization, Content-Type');
  assert.match(result.headers.Vary, /Access-Control-Request-Headers/);
});

test('disallowed preflight never reaches upstream and reveals no allow headers', async () => {
  const handler = createHandler({
    env: { CORS_ALLOWED_ORIGINS: allowed },
    createRequestId: () => requestId,
    request: async () => assert.fail('network called')
  });
  const result = await invoke(handler, { method: 'OPTIONS', origin: 'https://evil.example' });
  assert.equal(result.statusCode, 204);
  assert.equal(result.headers['Access-Control-Allow-Origin'], undefined);
  assert.equal(result.headers['Access-Control-Allow-Methods'], undefined);
});

test('method errors still expose safe CORS and request metadata', async () => {
  const handler = createHandler({
    env: { CORS_ALLOWED_ORIGINS: allowed },
    createRequestId: () => requestId,
    request: async () => assert.fail('network called')
  });
  const result = await invoke(handler, { method: 'POST', origin: allowed });
  assert.equal(result.statusCode, 405);
  assert.equal(result.headers.Allow, 'GET, HEAD, PATCH');
  assert.equal(result.headers['Access-Control-Allow-Origin'], allowed);
  assert.equal(result.headers.Vary, 'Origin');
});

test('allowed-origin errors remain browser-readable without leaking thrown details', async () => {
  const createThrowingHandler = createRoute({
    methods: ['GET'],
    run: async () => { throw Error('private-stack-value'); }
  });
  const result = await invoke(createThrowingHandler({
    env: { CORS_ALLOWED_ORIGINS: allowed },
    createRequestId: () => requestId
  }), { origin: allowed });
  assert.equal(result.statusCode, 500);
  assert.equal(result.headers['Access-Control-Allow-Origin'], allowed);
  assert.equal(result.headers['Access-Control-Expose-Headers'], 'X-Request-Id, Retry-After');
  assert.equal(JSON.stringify(result).includes('private-stack-value'), false);
});

test('runtime api and lib code never read a service-role credential', async () => {
  const roots = [new URL('../api/', import.meta.url), new URL('../lib/', import.meta.url)];
  const files = [];
  async function visit(directory) {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const target = new URL(entry.name + (entry.isDirectory() ? '/' : ''), directory);
      if (entry.isDirectory()) await visit(target);
      else if (entry.name.endsWith('.js')) files.push(target);
    }
  }
  for (const root of roots) await visit(root);
  const internal = files.find(file => file.pathname.endsWith('/lib/supabase-internal.js'));
  assert.ok(internal);
  const source = (await Promise.all(files.filter(file => file !== internal).map(file => readFile(file, 'utf8')))).join('\n');
  assert.equal(source.includes('SUPABASE_SERVICE_ROLE_KEY'), false);
  assert.equal(source.includes('SUPABASE_SECRET_KEY'), false);
  const internalSource = await readFile(internal, 'utf8');
  assert.equal(internalSource.includes('SUPABASE_SERVICE_ROLE_KEY'), false);
  assert.equal(internalSource.includes('SUPABASE_SECRET_KEY'), true);
  assert.equal(internalSource.includes('AI_CALLBACK_HMAC_SECRET'), true);
});
