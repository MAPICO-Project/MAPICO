import test from 'node:test';
import assert from 'node:assert/strict';
import { createHandler } from '../api/v1/me.js';

const requestId = '11111111-1111-4111-8111-111111111111';
const userId = '22222222-2222-4222-8222-222222222222';
const aestheticId = '33333333-3333-4333-8333-333333333333';
const token = 'header.payload.signature';
const env = {
  SUPABASE_URL: 'https://abcdefghijklmnopqrst.supabase.co',
  SUPABASE_PUBLISHABLE_KEY: 'publishable-test',
  SUPABASE_SERVICE_ROLE_KEY: 'must-never-appear'
};

function response(status, body, responseHeaders = {}) {
  return {
    status,
    headers: { get(name) { return responseHeaders[name.toLowerCase()] ?? null; } },
    async json() { return body; }
  };
}

function invoke(options = {}) {
  const { method = 'GET', request, runtimeEnv = env } = options;
  const authorization = Object.hasOwn(options, 'authorization') ? options.authorization : `Bearer ${token}`;
  const result = { headers: {}, statusCode: 200 };
  const req = { method, headers: authorization === undefined ? {} : { authorization } };
  const res = {
    setHeader(name, value) { result.headers[name] = value; },
    status(value) { result.statusCode = value; return this; },
    json(body) { result.body = body; return result; },
    end() { return result; }
  };
  const handler = createHandler({ env: runtimeEnv, request, createRequestId: () => requestId });
  return handler(req, res);
}

function successFetch(calls, profileOverrides = {}) {
  return async (url, options) => {
    calls.push({ url: String(url), options });
    if (String(url).includes('/auth/v1/user')) {
      return response(200, { id: userId, email: 'private@example.com', user_metadata: { secret: true } });
    }
    return response(200, [{
      id: userId,
      display_name: '마피코',
      timezone: 'Asia/Seoul',
      default_tpo: null,
      onboarding_completed: false,
      preferences: [{ aesthetic_id: aestheticId, weight: 1 }],
      training_consent: true,
      created_at: 'private',
      ...profileOverrides
    }]);
  };
}

test('rejects unsupported methods and malformed authorization before network', async () => {
  for (const input of [
    { method: 'POST' },
    { authorization: undefined },
    { authorization: 'Basic abc' },
    { authorization: 'Bearer not-a-jwt' },
    { authorization: ['Bearer one.two.three'] },
    { authorization: `Bearer ${'a'.repeat(4090)}.b.c` }
  ]) {
    let called = false;
    const result = await invoke({ ...input, request: async () => { called = true; } });
    assert.equal(called, false);
    assert.equal(result.statusCode, input.method === 'POST' ? 405 : 401);
    assert.equal(result.headers['X-Request-Id'], requestId);
    if (input.method === 'POST') assert.equal(result.headers.Allow, 'GET, HEAD, PATCH');
    else assert.equal(result.headers['WWW-Authenticate'], 'Bearer');
  }
});

test('fails closed for missing or invalid Supabase configuration', async () => {
  for (const runtimeEnv of [{}, { ...env, SUPABASE_URL: 'http://localhost' }]) {
    let called = false;
    const result = await invoke({ runtimeEnv, request: async () => { called = true; } });
    assert.equal(called, false);
    assert.equal(result.statusCode, 503);
    assert.equal(result.body.error.code, 'SUPABASE_NOT_CONFIGURED');
  }
});

test('maps authentication failures without leaking upstream data', async () => {
  const invalid = await invoke({ request: async () => response(401, { token, detail: 'upstream-secret' }) });
  assert.equal(invalid.statusCode, 401);
  assert.equal(invalid.body.error.code, 'INVALID_TOKEN');
  assert.equal(invalid.headers['WWW-Authenticate'], 'Bearer');

  const unavailable = await invoke({ request: async () => { throw Error('private exception'); } });
  assert.equal(unavailable.statusCode, 503);
  assert.equal(unavailable.body.error.code, 'AUTH_UNAVAILABLE');
  const serialized = JSON.stringify([invalid, unavailable]);
  assert.equal(serialized.includes(token), false);
  assert.equal(serialized.includes('upstream-secret'), false);
  assert.equal(serialized.includes('private exception'), false);
});

test('rejects a malformed authenticated user id as an unavailable auth service', async () => {
  const result = await invoke({ request: async () => response(200, { id: 'not-a-uuid', email: 'private@example.com' }) });
  assert.equal(result.statusCode, 503);
  assert.equal(result.body.error.code, 'AUTH_UNAVAILABLE');
  assert.equal(JSON.stringify(result).includes('private@example.com'), false);
});

test('propagates a safe Retry-After for upstream rate limits', async () => {
  const supplied = await invoke({ request: async () => response(429, {}, { 'retry-after': '17' }) });
  assert.equal(supplied.statusCode, 429);
  assert.equal(supplied.headers['Retry-After'], '17');
  const fallback = await invoke({ request: async () => response(429, {}, { 'retry-after': 'unsafe' }) });
  assert.equal(fallback.headers['Retry-After'], '60');
});

test('returns only the Profile allowlist and keeps the user JWT under RLS', async () => {
  const calls = [];
  const result = await invoke({ request: successFetch(calls) });
  assert.equal(result.statusCode, 200);
  assert.deepEqual(result.body, {
    id: userId,
    display_name: '마피코',
    timezone: 'Asia/Seoul',
    default_tpo: null,
    onboarding_completed: false,
    preferences: [{ aesthetic_id: aestheticId, weight: 1 }]
  });
  assert.equal(calls.length, 2);
  for (const call of calls) {
    assert.equal(call.options.headers.apikey, env.SUPABASE_PUBLISHABLE_KEY);
    assert.equal(call.options.headers.Authorization, `Bearer ${token}`);
    assert.equal(JSON.stringify(call).includes(env.SUPABASE_SERVICE_ROLE_KEY), false);
    assert.equal(call.options.redirect, 'error');
  }
  const restUrl = new URL(calls[1].url);
  assert.equal(restUrl.searchParams.get('id'), `eq.${userId}`);
  assert.match(restUrl.searchParams.get('select'), /preferences:user_aesthetic_preferences/);
  assert.equal(JSON.stringify(result).includes('private@example.com'), false);
  assert.equal(JSON.stringify(result).includes('training_consent'), false);
});

test('maps profile absence and schema failures', async () => {
  const missing = await invoke({ request: async url => String(url).includes('/auth/') ? response(200, { id: userId }) : response(200, []) });
  assert.equal(missing.statusCode, 404);
  assert.equal(missing.body.error.code, 'PROFILE_NOT_FOUND');

  const schema = await invoke({ request: async url => String(url).includes('/auth/') ? response(200, { id: userId }) : response(403, { detail: 'private' }) });
  assert.equal(schema.statusCode, 503);
  assert.equal(schema.body.error.code, 'DATABASE_SCHEMA_NOT_READY');
  assert.equal(JSON.stringify(schema).includes('private'), false);
});

test('rejects malformed or over-cardinality profile data', async () => {
  const invalidRows = [
    { preferences: [{ aesthetic_id: aestheticId, weight: '1' }] },
    { preferences: [{ aesthetic_id: aestheticId, weight: 1.5 }] },
    { preferences: Array.from({ length: 4 }, () => ({ aesthetic_id: aestheticId, weight: 0.25 })) }
  ];
  for (const overrides of invalidRows) {
    const result = await invoke({ request: successFetch([], overrides) });
    assert.equal(result.statusCode, 500);
    assert.equal(result.body.error.code, 'INTERNAL_ERROR');
  }
});

test('rejects multiple profile rows instead of selecting one silently', async () => {
  const row = {
    id: userId,
    display_name: null,
    timezone: 'Asia/Seoul',
    default_tpo: null,
    onboarding_completed: false,
    preferences: []
  };
  const result = await invoke({ request: async url => String(url).includes('/auth/') ? response(200, { id: userId }) : response(200, [row, row]) });
  assert.equal(result.statusCode, 500);
  assert.equal(result.body.error.code, 'INTERNAL_ERROR');
});

test('uses the contract error envelope and HEAD omits the body after full lookup', async () => {
  const calls = [];
  const head = await invoke({ method: 'HEAD', request: successFetch(calls) });
  assert.equal(head.statusCode, 200);
  assert.equal(head.body, undefined);
  assert.equal(calls.length, 2);
  assert.equal(head.headers['Cache-Control'], 'no-store');

  const unauthorized = await invoke({ method: 'HEAD', authorization: undefined, request: async () => assert.fail('network called') });
  assert.equal(unauthorized.statusCode, 401);
  assert.equal(unauthorized.body, undefined);

  const getError = await invoke({ authorization: undefined, request: async () => assert.fail('network called') });
  assert.deepEqual(Object.keys(getError.body.error).sort(), ['code', 'message', 'request_id', 'retryable']);
  assert.equal(getError.body.error.request_id, getError.headers['X-Request-Id']);
});
