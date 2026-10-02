import test from 'node:test';
import assert from 'node:assert/strict';
import { createHandler } from '../api/v1/weather/current.js';

const requestId = '11111111-1111-4111-8111-111111111111';
const userId = '22222222-2222-4222-8222-222222222222';
const snapshotId = '33333333-3333-4333-8333-333333333333';
const now = new Date('2026-10-01T03:05:00.000Z');
const env = { SUPABASE_URL: 'https://abcdefghijklmnopqrst.supabase.co', SUPABASE_PUBLISHABLE_KEY: 'publishable-test',
  SUPABASE_SECRET_KEY: 'fixture-server-secret-key-long-enough' };
function response(status, body, headers = {}) { return { status, headers: { get: n => headers[n.toLowerCase()] ?? null }, async json() { return body; } }; }
function invoke(request, query = { lat: '37.45', lon: '127.12' }, customEnv = env) { const out = { headers: {} };
  const req = { method: 'GET', headers: { authorization: 'Bearer header.payload.signature' }, query };
  const res = { setHeader(k, v) { out.headers[k] = v; }, status(v) { out.statusCode = v; return this; }, json(v) { out.body = v; return out; }, end() { return out; } };
  return createHandler({ env: customEnv, request, now: () => now, createRequestId: () => requestId })(req, res);
}
function snapshot(fetchedAt = '2026-10-01T03:00:00.000Z') { return { id: snapshotId, source: 'kma_short_term',
  issued_at: '2026-10-01T02:00:00.000Z', valid_at: '2026-10-01T03:00:00.000Z', fetched_at: fetchedAt,
  grid_x: 62, grid_y: 89, payload: { temperature_c: 18, feels_like_c: null, precipitation_probability: 20,
    precipitation_type: 'none', humidity: 60, air_quality: null } }; }

test('weather returns an exact current-slot fresh cache without provider network', async () => {
  const calls = []; const result = await invoke(async (url, options) => { calls.push(String(url));
    if (String(url).includes('/auth/v1/user')) return response(200, { id: userId });
    if (String(url).includes('/rpc/find_weather_snapshot')) return response(200, snapshot());
    assert.fail(`unexpected ${url}`);
  });
  assert.equal(result.statusCode, 200); assert.equal(result.body.id, snapshotId); assert.equal(result.body.is_stale, false);
  assert.equal(calls.length, 2);
});

test('weather uses a stale same-slot cache only when provider is unavailable', async () => {
  const result = await invoke(async url => {
    if (String(url).includes('/auth/v1/user')) return response(200, { id: userId });
    if (String(url).includes('/rpc/find_weather_snapshot')) return response(200, snapshot('2026-10-01T01:00:00.000Z'));
    assert.fail(`unexpected ${url}`);
  });
  assert.equal(result.statusCode, 200); assert.equal(result.body.is_stale, true);
});

test('successful provider refetch creates a new fresh snapshot over stale and expired caches', async () => {
  for (const fetchedAt of ['2026-10-01T01:00:00.000Z', '2026-09-30T20:00:00.000Z']) {
    const freshId = fetchedAt.includes('01:') ? 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' : 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    const customEnv = { ...env, WEATHER_PROVIDER_BASE_URL: 'https://weather.example.test/current', WEATHER_PROVIDER_API_KEY: 'fixture-weather-key' };
    const result = await invoke(async url => {
      const value = String(url);
      if (value.includes('/auth/v1/user')) return response(200, { id: userId });
      if (value.includes('/rpc/find_weather_snapshot')) return response(200, snapshot(fetchedAt));
      if (value.startsWith('https://weather.example.test/')) return response(200, { issued_at: '2026-10-01T02:00:00.000Z',
        valid_at: '2026-10-01T03:00:00.000Z', temperature_c: 18, feels_like_c: null,
        precipitation_probability: 20, precipitation_type: 'none', humidity: 60, air_quality: null });
      if (value.includes('/rpc/upsert_weather_snapshot')) return response(200, { ...snapshot('2026-10-01T03:05:01.000Z'), id: freshId });
      assert.fail(`unexpected ${value}`);
    }, undefined, customEnv);
    assert.equal(result.statusCode, 200); assert.equal(result.body.id, freshId); assert.equal(result.body.is_stale, false);
  }
});

test('weather rejects unsupported locations before auth and fails closed without cache/provider', async () => {
  const outside = await invoke(async () => assert.fail('network'), { lat: '0', lon: '0' });
  assert.equal(outside.statusCode, 422);
  const unavailable = await invoke(async url => {
    if (String(url).includes('/auth/v1/user')) return response(200, { id: userId });
    if (String(url).includes('/rpc/find_weather_snapshot')) return response(400, { message: 'weather_snapshot_not_found' });
    assert.fail(`unexpected ${url}`);
  });
  assert.equal(unavailable.statusCode, 503); assert.equal(unavailable.body.error.code, 'WEATHER_UNAVAILABLE');
});
