import test from 'node:test';
import assert from 'node:assert/strict';
import { createHandler as createMeHandler } from '../api/v1/me.js';
import { createHandler as createPreferencesHandler } from '../api/v1/me/aesthetics.js';
import { createHandler as createOnboardingHandler } from '../api/v1/me/onboarding.js';

const requestId = '11111111-1111-4111-8111-111111111111';
const userId = '22222222-2222-4222-8222-222222222222';
const aestheticId = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
const token = 'header.payload.signature';
const env = { SUPABASE_URL: 'https://abcdefghijklmnopqrst.supabase.co', SUPABASE_PUBLISHABLE_KEY: 'publishable-test' };

function response(status, body, headers = {}) {
  return { status, headers: { get: name => headers[name.toLowerCase()] ?? null }, async json() {
    if (body === undefined) throw Error('no body');
    return body;
  } };
}

function invoke(createHandler, { method, body, contentType = 'application/json', request, authorization = `Bearer ${token}` }) {
  const result = { headers: {}, statusCode: 200 };
  const headers = {};
  if (authorization !== undefined) headers.authorization = authorization;
  if (contentType !== undefined) headers['content-type'] = contentType;
  const req = { method, headers, body };
  const res = {
    setHeader(name, value) { result.headers[name] = value; },
    status(value) { result.statusCode = value; return this; },
    json(value) { result.body = value; return result; },
    end() { return result; }
  };
  return createHandler({ env, request, createRequestId: () => requestId })(req, res);
}

function profile() {
  return { id: userId, display_name: '새 이름', timezone: 'UTC', default_tpo: null,
    onboarding_completed: false, preferences: [] };
}

test('PATCH /me sends all presence arguments, accepts void 204 and re-reads the Profile with the user JWT', async () => {
  const calls = [];
  const request = async (url, options) => {
    calls.push({ url: String(url), options });
    if (String(url).includes('/auth/v1/user')) return response(200, { id: userId, private: true });
    if (String(url).includes('/rpc/update_my_profile')) return response(204);
    return response(200, [profile()]);
  };
  const result = await invoke(createMeHandler, { method: 'PATCH', body: { display_name: null, timezone: 'UTC' }, request });
  assert.equal(result.statusCode, 200);
  assert.deepEqual(result.body, { ...profile(), display_name: '새 이름' });
  assert.equal(calls.length, 3);
  assert.equal(calls[1].options.method, 'POST');
  assert.deepEqual(JSON.parse(calls[1].options.body), {
    p_set_display_name: true, p_display_name: null, p_set_timezone: true, p_timezone: 'UTC'
  });
  assert.equal(calls[1].options.headers.Authorization, `Bearer ${token}`);
  assert.equal(calls[2].options.headers.Authorization, `Bearer ${token}`);
  assert.equal(new URL(calls[2].url).searchParams.get('id'), `eq.${userId}`);
});

test('profile body allowlist rejects malformed, empty, deprecated and unsupported fields before network', async () => {
  const inputs = [
    [{}, 422, 'VALIDATION_ERROR'],
    [{ default_tpo: 'daily_campus' }, 422, 'VALIDATION_ERROR'],
    [{ avatar_asset_id: null }, 422, 'UNSUPPORTED_FIELD'],
    [{ display_name: '' }, 422, 'VALIDATION_ERROR'],
    [{ display_name: 'x\u0000y' }, 422, 'VALIDATION_ERROR']
  ];
  for (const [body, status, code] of inputs) {
    const result = await invoke(createMeHandler, { method: 'PATCH', body, request: async () => assert.fail('network called') });
    assert.equal(result.statusCode, status);
    assert.equal(result.body.error.code, code);
  }
  for (const options of [
    { body: 'not json' }, { body: [] }, { body: {}, contentType: 'text/plain' },
    { body: 'x'.repeat(17000) }
  ]) {
    const result = await invoke(createMeHandler, { method: 'PATCH', ...options, request: async () => assert.fail('network called') });
    assert.equal(result.statusCode, 400);
    assert.equal(result.body.error.code, 'INVALID_REQUEST_BODY');
  }
});

test('PUT preferences normalizes UUIDs, rejects duplicates and returns the safe reread projection', async () => {
  const calls = [];
  const request = async (url, options) => {
    calls.push({ url: String(url), options });
    if (String(url).includes('/auth/')) return response(200, { id: userId });
    if (String(url).includes('/rpc/')) return response(200, null);
    return response(200, [{ aesthetic_id: aestheticId.toLowerCase(), weight: 1 }]);
  };
  const result = await invoke(createPreferencesHandler, {
    method: 'PUT', body: { preferences: [{ aesthetic_id: aestheticId, weight: 1 }] }, request
  });
  assert.equal(result.statusCode, 200);
  assert.deepEqual(result.body, { preferences: [{ aesthetic_id: aestheticId.toLowerCase(), weight: 1 }] });
  assert.deepEqual(JSON.parse(calls[1].options.body), {
    p_preferences: [{ aesthetic_id: aestheticId.toLowerCase(), weight: 1 }]
  });
  const duplicate = await invoke(createPreferencesHandler, {
    method: 'PUT', body: { preferences: [
      { aesthetic_id: aestheticId, weight: 0.5 }, { aesthetic_id: aestheticId.toLowerCase(), weight: 0.5 }
    ] }, request: async () => assert.fail('network called')
  });
  assert.equal(duplicate.statusCode, 422);
});

test('PUT onboarding sends the exact RPC body and renames onboarding_completed on reread', async () => {
  const calls = [];
  const request = async (url, options) => {
    calls.push({ url: String(url), options });
    if (String(url).includes('/auth/')) return response(200, { id: userId });
    if (String(url).includes('/rpc/')) return response(204);
    return response(200, [{ knows_aesthetic: null, tutorial_seen: true, onboarding_completed: true }]);
  };
  const body = { knows_aesthetic: null, tutorial_seen: true, completed: true };
  const result = await invoke(createOnboardingHandler, { method: 'PUT', body, request });
  assert.equal(result.statusCode, 200);
  assert.deepEqual(result.body, body);
  assert.deepEqual(JSON.parse(calls[1].options.body), {
    p_knows_aesthetic: null, p_tutorial_seen: true, p_completed: true
  });
  const missing = await invoke(createOnboardingHandler, {
    method: 'PUT', body: { tutorial_seen: true, completed: true }, request: async () => assert.fail('network called')
  });
  assert.equal(missing.statusCode, 422);
});

test('RPC errors use an exact safe allowlist and never expose upstream details', async () => {
  const cases = [
    [400, { code: '22023', message: 'invalid_timezone', details: token }, 422, 'VALIDATION_ERROR'],
    [500, { code: 'P0002', message: 'profile_not_found', details: token }, 404, 'PROFILE_NOT_FOUND'],
    [404, { code: 'PGRST202', message: 'private function detail' }, 503, 'DATABASE_SCHEMA_NOT_READY'],
    [403, { code: '42501', message: 'permission denied for function' }, 503, 'DATABASE_SCHEMA_NOT_READY'],
    [400, { code: '22P02', message: token }, 503, 'SUPABASE_UNAVAILABLE']
  ];
  for (const [status, payload, expectedStatus, code] of cases) {
    const request = async url => String(url).includes('/auth/')
      ? response(200, { id: userId }) : response(status, payload);
    const result = await invoke(createMeHandler, { method: 'PATCH', body: { timezone: 'Not/A_Zone' }, request });
    assert.equal(result.statusCode, expectedStatus);
    assert.equal(result.body.error.code, code);
    assert.equal(JSON.stringify(result).includes(token), false);
    assert.equal(JSON.stringify(result).includes('private function detail'), false);
  }
});

test('write reread fails closed for missing or malformed rows', async () => {
  for (const rows of [[], [{ knows_aesthetic: 'yes', tutorial_seen: true, onboarding_completed: true }]]) {
    const request = async url => String(url).includes('/auth/') ? response(200, { id: userId })
      : String(url).includes('/rpc/') ? response(204) : response(200, rows);
    const result = await invoke(createOnboardingHandler, {
      method: 'PUT', body: { knows_aesthetic: true, tutorial_seen: true, completed: true }, request
    });
    assert.equal(result.statusCode, 500);
    assert.equal(result.body.error.code, 'INTERNAL_ERROR');
  }
});
