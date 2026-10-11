// 2026-10-11 hosted-only defects: hosted Supabase answers differ from the local stubs.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { createHandler as weatherHandler } from '../api/v1/weather/current.js';
import { createHandler as feedCollection } from '../api/v1/feed/index.js';
import { createHandler as ootdCalendar } from '../api/v1/ootd/calendar.js';
import { preflight } from '../lib/cors.js';
import { signedStorageUrl, storageObjectMissing } from '../lib/supabase-user.js';
import { kmaGrid, sameInstant } from '../lib/weather.js';
import { weatherSummary } from '../lib/outfits.js';

const requestId = '11111111-1111-4111-8111-111111111111';
const userId = '22222222-2222-4222-8222-222222222222';
const snapshotId = '33333333-3333-4333-8333-333333333333';
const postId = '44444444-4444-4444-8444-444444444444';
const ootdId = '55555555-5555-4555-8555-555555555555';
const env = { SUPABASE_URL: 'https://abcdefghijklmnopqrst.supabase.co', SUPABASE_PUBLISHABLE_KEY: 'publishable-test',
  SUPABASE_SECRET_KEY: 'fixture-server-secret-key-long-enough' };
const base = new URL(env.SUPABASE_URL);

function response(status, body, headers = {}) {
  return { status, headers: { get: n => headers[n.toLowerCase()] ?? null }, async json() { return body; } };
}
function invoke(create, request, { query = {}, customEnv = env, now = new Date('2026-10-01T03:05:00.000Z') } = {}) {
  const out = { headers: {} };
  const req = { method: 'GET', headers: { authorization: 'Bearer header.payload.signature' }, query };
  const res = { setHeader(k, v) { out.headers[k] = v; }, status(v) { out.statusCode = v; return this; },
    json(v) { out.body = v; return out; }, end() { return out; } };
  return create({ env: customEnv, request, now: () => now, createRequestId: () => requestId })(req, res);
}
const authed = url => (String(url).includes('/auth/v1/user') ? response(200, { id: userId }) : null);

test('#1 CORS preflight allows every request header the browser API reads', async () => {
  const allowed = 'https://app.example';
  const result = preflight({ headers: { origin: allowed } }, { CORS_ALLOWED_ORIGINS: allowed }, ['POST'], requestId);
  const header = result.headers['Access-Control-Allow-Headers'].toLowerCase().split(',').map(value => value.trim());
  const read = new Set(['authorization', 'content-type']);
  for (const file of await fs.readdir(new URL('../lib/', import.meta.url))) {
    const source = await fs.readFile(new URL(`../lib/${file}`, import.meta.url), 'utf8');
    for (const match of source.matchAll(/req\.headers\?\.\['([a-z-]+)'\]/g)) read.add(match[1]);
  }
  // x-worker-* are server-to-server HMAC callback headers, never sent from a browser.
  for (const name of [...read].filter(name => !name.startsWith('x-worker-'))) assert.ok(header.includes(name), name);
  assert.ok(header.includes('idempotency-key'));
});

test('N1 hosted Storage 400 NoSuchKey is a missing object; other 400s are not', async () => {
  assert.equal(await storageObjectMissing(response(404, null)), true);
  assert.equal(await storageObjectMissing(response(400, { statusCode: '404', error: 'NoSuchKey', message: 'Object not found' })), true);
  assert.equal(await storageObjectMissing(response(400, { statusCode: '404', error: 'not_found' })), true);
  assert.equal(await storageObjectMissing(response(400, { statusCode: '400', error: 'InvalidRequest' })), false);
  assert.equal(await storageObjectMissing(response(200, {})), false);
});

test('N2 relative signedURL (/object/sign/...) resolves under /storage/v1 of the same project only', () => {
  const relative = signedStorageUrl('/object/sign/closet-private/u/b/c.png?token=t', base, 'closet-private');
  assert.equal(String(relative), 'https://abcdefghijklmnopqrst.supabase.co/storage/v1/object/sign/closet-private/u/b/c.png?token=t');
  assert.ok(signedStorageUrl('/storage/v1/object/sign/closet-private/u/c.png?token=t', base, 'closet-private'));
  assert.equal(signedStorageUrl('/object/sign/feed-private/u/c.png?token=t', base, 'closet-private'), null);
  assert.equal(signedStorageUrl('https://evil.example/storage/v1/object/sign/closet-private/x?token=t', base, 'closet-private'), null);
  assert.equal(signedStorageUrl('', base, 'closet-private'), null);
});

test('#6 feed list propagates a PostgREST 403 as 503 DATABASE_SCHEMA_NOT_READY (not 500)', async () => {
  const result = await invoke(feedCollection, async url => authed(url) ??
    (String(url).includes('/rest/v1/feed_posts') ? response(403, { code: '42501' }) : assert.fail(`unexpected ${url}`)));
  assert.equal(result.statusCode, 503); assert.equal(result.body.error.code, 'DATABASE_SCHEMA_NOT_READY');
});

test('N2/#6 feed signs with relative signedURL and keeps microsecond cursors', async () => {
  const objectKey = `${userId}/${postId}/m.png`; const created = '2026-10-01T03:00:00.123456+00:00';
  const post = { id: postId, author: { id: userId, display_name: 'A' }, caption: 'look', aesthetic_id: '66666666-6666-4666-8666-666666666666',
    weather_code: 'unknown', temperature_c: null, visibility: 'public', liked_by_me: false, like_count: 0, created_at: created,
    media: [{ bucket_id: 'feed-private', object_key: objectKey, position: 0 }], linked_items: [] };
  const second = '77777777-7777-4777-8777-777777777777';
  const request = async url => { const value = String(url);
    return authed(url) ??
      (value.includes('/rpc/project_feed_posts') ? response(200, [post])
        : value.includes('/storage/v1/object/sign/feed-private') ? response(200, [{ path: objectKey, signedURL: `/object/sign/feed-private/${objectKey}?token=read` }])
          : value.includes('/rest/v1/feed_posts') ? response(200, [{ id: postId, created_at: created }, { id: second, created_at: '2026-10-01T02:00:00+00:00' }])
            : assert.fail(`unexpected ${value}`)); };
  const page = await invoke(feedCollection, request, { query: { limit: '1' } });
  assert.equal(page.statusCode, 200);
  assert.equal(page.body.items[0].media[0].url, `https://abcdefghijklmnopqrst.supabase.co/storage/v1/object/sign/feed-private/${objectKey}?token=read`);
  const cursor = JSON.parse(Buffer.from(page.body.next_cursor, 'base64url').toString('utf8'));
  assert.equal(cursor.at, created);
  let filter = null;
  const next = await invoke(feedCollection, async url => { const value = String(url);
    if (value.includes('/rest/v1/feed_posts')) { filter = new URL(value).searchParams.get('or'); return response(200, []); }
    return authed(url) ?? assert.fail(`unexpected ${value}`); }, { query: { limit: '1', cursor: page.body.next_cursor } });
  assert.equal(next.statusCode, 200); assert.ok(filter.includes(`created_at.lt."${created}"`));
});

const snapshotRow = valid => ({ id: snapshotId, source: 'kma_short_term', issued_at: '2026-10-01T02:00:00+00:00',
  valid_at: valid, fetched_at: '2026-10-01T03:01:00+00:00', grid_x: 62, grid_y: 89,
  payload: { temperature_c: 18, feels_like_c: null, precipitation_probability: 20, precipitation_type: 'none', humidity: 60, air_quality: null } });

test('#9 weather cache accepts PostgREST "+00:00" timestamps for the current slot', async () => {
  assert.equal(sameInstant('2026-10-01T03:00:00+00:00', '2026-10-01T03:00:00.000Z'), true);
  assert.equal(sameInstant('2026-10-01T04:00:00+00:00', '2026-10-01T03:00:00.000Z'), false);
  const result = await invoke(weatherHandler, async url => authed(url) ??
    (String(url).includes('/rpc/find_weather_snapshot') ? response(200, snapshotRow('2026-10-01T03:00:00+00:00')) : assert.fail(`unexpected ${url}`)),
  { query: { lat: '37.45', lon: '127.12' } });
  assert.equal(result.statusCode, 200); assert.equal(result.body.id, snapshotId); assert.equal(result.body.is_stale, false);
  const otherSlot = await invoke(weatherHandler, async url => authed(url) ??
    (String(url).includes('/rpc/find_weather_snapshot') ? response(200, snapshotRow('2026-10-01T02:00:00+00:00')) : assert.fail(`unexpected ${url}`)),
  { query: { lat: '37.45', lon: '127.12' } });
  assert.equal(otherSlot.statusCode, 503);
});

test('#9 freshly stored snapshot with "+00:00" valid_at is returned (was always 503)', async () => {
  const customEnv = { ...env, WEATHER_PROVIDER_BASE_URL: 'https://weather.example.test/current', WEATHER_PROVIDER_API_KEY: 'fixture-weather-key' };
  const result = await invoke(weatherHandler, async url => { const value = String(url);
    if (value.includes('/rpc/find_weather_snapshot')) return response(200, null);
    if (value.startsWith('https://weather.example.test/')) return response(200, { issued_at: '2026-10-01T02:00:00Z',
      valid_at: '2026-10-01T03:00:00Z', temperature_c: 18, feels_like_c: null, precipitation_probability: 20,
      precipitation_type: 'none', humidity: 60, air_quality: null });
    if (value.includes('/rpc/upsert_weather_snapshot')) return response(200, { ...snapshotRow('2026-10-01T03:00:00+00:00'), fetched_at: '2026-10-01T03:05:00+00:00' });
    return authed(url) ?? assert.fail(`unexpected ${value}`);
  }, { customEnv, query: { region_code: 'seoul' } });
  assert.equal(result.statusCode, 200); assert.equal(result.body.is_stale, false);
});

test('#3 KMA grid conversion matches published 기상청 grid points', () => {
  assert.deepEqual(kmaGrid(37.5665, 126.978), { nx: 60, ny: 127 }); // 서울시청
  assert.deepEqual(kmaGrid(35.1796, 129.0756), { nx: 98, ny: 76 }); // 부산시청
});

test('#3 WEATHER_PROVIDER=kma calls 초단기실황 + 단기예보 and stores the normalized payload', async () => {
  const key = 'kma-service-key-fixture';
  const customEnv = { ...env, WEATHER_PROVIDER: 'kma', WEATHER_PROVIDER_API_KEY: key };
  const now = new Date('2026-10-01T03:50:00.000Z'); // 12:50 KST → 초단기실황 12:00, 단기예보 11:00
  const seen = []; let stored = null;
  const ok = items => response(200, { response: { header: { resultCode: '00', resultMsg: 'NORMAL_SERVICE' }, body: { items: { item: items } } } });
  const result = await invoke(weatherHandler, async (url, options) => { const value = String(url);
    if (value.includes('/rpc/find_weather_snapshot')) return response(200, null);
    if (value.startsWith('https://apis.data.go.kr/1360000/VilageFcstInfoService_2.0/')) {
      const parsed = new URL(value); seen.push(parsed);
      if (parsed.pathname.endsWith('/getUltraSrtNcst')) return ok([{ category: 'T1H', obsrValue: '4.2' }, { category: 'REH', obsrValue: '70' },
        { category: 'PTY', obsrValue: '3' }, { category: 'WSD', obsrValue: '5' }]);
      if (parsed.pathname.endsWith('/getVilageFcst')) return ok([{ category: 'POP', fcstDate: '20261001', fcstTime: '1200', fcstValue: '60' },
        { category: 'POP', fcstDate: '20261001', fcstTime: '1300', fcstValue: '70' }, { category: 'TMP', fcstDate: '20261001', fcstTime: '1200', fcstValue: '5' }]);
    }
    if (value.includes('/rpc/upsert_weather_snapshot')) { stored = JSON.parse(options.body);
      return response(200, { ...snapshotRow('2026-10-01T03:00:00+00:00'), issued_at: '2026-10-01T03:00:00+00:00', payload: stored.p_payload,
        fetched_at: '2026-10-01T03:50:00+00:00' }); }
    return authed(url) ?? assert.fail(`unexpected ${value}`);
  }, { customEnv, now, query: { region_code: 'seoul' } });
  assert.equal(result.statusCode, 200);
  const nowcast = seen.find(url => url.pathname.endsWith('/getUltraSrtNcst'));
  assert.equal(nowcast.searchParams.get('base_date'), '20261001'); assert.equal(nowcast.searchParams.get('base_time'), '1200');
  assert.equal(nowcast.searchParams.get('nx'), '60'); assert.equal(nowcast.searchParams.get('ny'), '127');
  assert.equal(seen.find(url => url.pathname.endsWith('/getVilageFcst')).searchParams.get('base_time'), '1100');
  assert.equal(stored.p_issued_at, '2026-10-01T03:00:00.000Z'); assert.equal(stored.p_valid_at, '2026-10-01T03:00:00.000Z');
  assert.equal(stored.p_payload.temperature_c, 4.2); assert.equal(stored.p_payload.precipitation_type, 'snow');
  assert.equal(stored.p_payload.precipitation_probability, 60); assert.equal(stored.p_payload.humidity, 70);
  assert.ok(stored.p_payload.feels_like_c < 4.2);
  assert.equal(JSON.stringify(result.body).includes(key), false);
});

test('#3 KMA error envelope (resultCode != 00) falls back to WEATHER_UNAVAILABLE', async () => {
  const customEnv = { ...env, WEATHER_PROVIDER: 'kma', WEATHER_PROVIDER_API_KEY: 'kma-service-key-fixture' };
  const result = await invoke(weatherHandler, async url => { const value = String(url);
    if (value.includes('/rpc/find_weather_snapshot')) return response(200, null);
    if (value.startsWith('https://apis.data.go.kr/')) return response(200, { response: { header: { resultCode: '30', resultMsg: 'SERVICE_KEY_IS_NOT_REGISTERED_ERROR' } } });
    return authed(url) ?? assert.fail(`unexpected ${value}`);
  }, { customEnv, query: { region_code: 'seoul' } });
  assert.equal(result.statusCode, 503); assert.equal(result.body.error.code, 'WEATHER_UNAVAILABLE');
});

test('#8 weather summary mapping for icons', () => {
  const row = { weather_snapshot_id: snapshotId, valid_at: '2026-10-01T03:00:00+00:00', temperature_c: 18, feels_like_c: null,
    precipitation_type: 'mixed', precipitation_probability: null };
  assert.equal(weatherSummary(row).weather_code, 'rain');
  assert.equal(weatherSummary({ ...row, precipitation_type: 'none' }).weather_code, 'clear');
  assert.equal(weatherSummary({ ...row, precipitation_type: 'unknown' }).weather_code, 'unknown');
  assert.equal(weatherSummary({ ...row, temperature_c: 'x' }), null);
});

test('#8 OOTD calendar days carry the saved-weather summary', async () => {
  const calls = [];
  const result = await invoke(ootdCalendar, async (url, options) => { const value = String(url); calls.push(value);
    if (value.includes('/rpc/get_my_ootd_calendar')) return response(200, [{ date: '2026-10-01', count: 1, representative_ootd_id: ootdId,
      has_photo: false, weather_snapshot_id: snapshotId }, { date: '2026-09-30', count: 1, representative_ootd_id: postId, has_photo: false, weather_snapshot_id: null }]);
    if (value.includes('/rpc/get_my_ootd_weather')) {
      assert.deepEqual(JSON.parse(options.body), { p_snapshot_ids: [snapshotId] });
      return response(200, [{ weather_snapshot_id: snapshotId, valid_at: '2026-10-01T03:00:00+00:00', temperature_c: 18,
        feels_like_c: null, precipitation_type: 'rain', precipitation_probability: 80 }]);
    }
    return authed(url) ?? assert.fail(`unexpected ${value}`);
  }, { query: { from: '2026-09-30', to: '2026-10-01' } });
  assert.equal(result.statusCode, 200);
  assert.deepEqual(result.body.days[0].weather, { weather_code: 'rain', temperature_c: 18, feels_like_c: null, precipitation_type: 'rain',
    precipitation_probability: 80, valid_at: '2026-10-01T03:00:00+00:00' });
  assert.equal(result.body.days[1].weather, null);
});
