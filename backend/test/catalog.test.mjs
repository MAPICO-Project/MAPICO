import test from 'node:test';
import assert from 'node:assert/strict';
import { createHandler as createAestheticsHandler } from '../api/v1/aesthetics.js';
import { createHandler as createLegacyAestheticsHandler } from '../api/aesthetics.js';
import { createHandler as createTpoHandler } from '../api/v1/tpo-presets.js';

const requestId = '11111111-1111-4111-8111-111111111111';
const env = { SUPABASE_URL: 'https://abcdefghijklmnopqrst.supabase.co', SUPABASE_PUBLISHABLE_KEY: 'publishable-test' };
const id = '22222222-2222-4222-8222-222222222222';

function response(status, body) { return { status, headers: { get: () => null }, async json() { return body; } }; }
function invoke(createHandler, { method = 'GET', request, authorization = 'Bearer invalid' } = {}) {
  const result = { headers: {}, statusCode: 200 };
  const req = { method, headers: { authorization } };
  const res = { setHeader(k, v) { result.headers[k] = v; }, status(v) { result.statusCode = v; return this; },
    json(v) { result.body = v; return result; }, end() { return result; } };
  return createHandler({ env, request, createRequestId: () => requestId })(req, res);
}

test('aesthetics uses anonymous projection, ignores Authorization and legacy route matches', async () => {
  const calls = [];
  const request = async (url, options) => {
    calls.push({ url: String(url), options });
    return response(200, [{ id, code: 'fixture_style', label: 'Fixture', active: true, definition: 'private' }]);
  };
  const expected = { items: [{ id, code: 'fixture_style', display_name: 'Fixture', active: true }] };
  assert.deepEqual((await invoke(createAestheticsHandler, { request })).body, expected);
  assert.deepEqual((await invoke(createLegacyAestheticsHandler, { request })).body, expected);
  for (const call of calls) {
    assert.equal(call.options.headers.Authorization, undefined);
    assert.equal(call.options.headers.apikey, env.SUPABASE_PUBLISHABLE_KEY);
    const url = new URL(call.url);
    assert.equal(url.searchParams.get('select'), 'id,code,label,active');
    assert.equal(url.searchParams.get('active'), 'eq.true');
  }
});

test('deprecated TPO maps only the known public projection', async () => {
  const result = await invoke(createTpoHandler, { request: async () => response(200, [
    { code: 'daily_campus', label: '일상·등교', active: true, hidden: 'private' }
  ]) });
  assert.equal(result.statusCode, 200);
  assert.deepEqual(result.body, { items: [{ code: 'daily_campus', display_name: '일상·등교', description: '일상과 등교 상황' }] });
  const unknown = await invoke(createTpoHandler, { request: async () => response(200, [
    { code: 'invented', label: 'Unknown', active: true }
  ]) });
  assert.equal(unknown.statusCode, 503);
  assert.equal(unknown.body.error.code, 'SUPABASE_UNAVAILABLE');
});

test('catalog HEAD is bodyless and upstream failures use the safe envelope', async () => {
  const head = await invoke(createAestheticsHandler, { method: 'HEAD', request: async () => response(200, []) });
  assert.equal(head.statusCode, 200);
  assert.equal(head.body, undefined);
  const failure = await invoke(createAestheticsHandler, { request: async () => response(404, { secret: true }) });
  assert.equal(failure.statusCode, 503);
  assert.equal(failure.body.error.code, 'DATABASE_SCHEMA_NOT_READY');
  assert.equal(JSON.stringify(failure).includes('secret'), false);
});
