// 2026-10-10 track B: several OOTD per day, AI notice/training consent, account deletion.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHandler as meHandler } from '../api/v1/me.js';
import { createHandler as ootdCollection } from '../api/v1/ootd/index.js';
import { createHandler as ootdItem } from '../api/v1/ootd/[ootdId]/index.js';
import { createHandler as ootdCalendar } from '../api/v1/ootd/calendar.js';
import { createHandler as createJobHandler } from '../api/v1/garment-batches/[batchId]/analysis-jobs.js';
import { createHandler as retryJobHandler } from '../api/v1/analysis-jobs/[jobId]/retry.js';

const requestId = '11111111-1111-4111-8111-111111111111';
const userId = '22222222-2222-4222-8222-222222222222';
const ootdId = '44444444-4444-4444-8444-444444444444';
const otherOotdId = '77777777-7777-4777-8777-777777777777';
const topId = '55555555-5555-4555-8555-555555555555';
const topAssetId = '88888888-8888-4888-8888-888888888888';
const batchId = '33333333-3333-4333-8333-333333333333';
const secret = 'sb_secret_test_value_0123456789';
const env = { SUPABASE_URL: 'https://abcdefghijklmnopqrst.supabase.co', SUPABASE_PUBLISHABLE_KEY: 'publishable-test' };
const secretEnv = { ...env, SUPABASE_SECRET_KEY: secret };

function response(status, body) {
  return { status, headers: { get: () => null }, async json() { if (body === undefined) throw Error('no body'); return body; } };
}
function invoke(create, request, { method = 'GET', query = {}, body, headers = {}, runtimeEnv = env } = {}) {
  const out = { headers: {} }; const reqHeaders = { authorization: 'Bearer header.payload.signature', ...headers };
  if (body !== undefined) reqHeaders['content-type'] = 'application/json';
  const req = { method, query, body, headers: reqHeaders };
  const res = { setHeader(k, v) { out.headers[k] = v; }, status(v) { out.statusCode = v; return this; },
    json(v) { out.body = v; return out; }, end() { out.ended = true; return out; } };
  return create({ env: runtimeEnv, request, createRequestId: () => requestId, now: () => new Date('2026-10-10T00:00:00.000Z') })(req, res);
}
const auth = url => String(url).includes('/auth/v1/user') ? response(200, { id: userId }) : null;
const noNetwork = async () => assert.fail('network called');
const ootdRow = (overrides = {}) => ({ id: ootdId, worn_on: '2026-10-09', saved_outfit_id: null, outfit_id: null, wear_status: 'worn',
  note: null, rating: null, weather_snapshot_id: null, version: 1, created_at: '2026-10-09T03:00:00.123456+00:00', visibility: 'private',
  photo_object_key: null, item_snapshot: [{ garment_id: topId, category: 'top', unavailable: false }], ...overrides });
const closetReads = value => {
  if (value.includes('/rest/v1/garment_assets')) return response(200, [{ id: topAssetId }]);
  if (value.includes('/rest/v1/garments')) return response(200, [{ id: topId, asset_id: topAssetId }]);
  return null;
};

// ---------------------------------------------------------------- OOTD
test('OOTD create defaults to worn, never sends planned, and planned is rejected on create and patch', async () => {
  let rpcBody;
  const created = await invoke(ootdCollection, async (url, options) => {
    const a = auth(url); if (a) return a; const value = String(url);
    if (value.includes('/rpc/create_my_ootd_with_photo')) { rpcBody = JSON.parse(options.body); return response(200, { ootd_id: ootdId, replayed: false }); }
    if (value.includes('/rest/v1/ootd_entries')) return response(200, [ootdRow()]);
    return closetReads(value) ?? assert.fail(`unexpected ${value}`);
  }, { method: 'POST', headers: { 'idempotency-key': 'ootd-default-worn' }, body: { worn_on: '2026-10-09', garment_ids: [topId] } });
  assert.equal(created.statusCode, 201); assert.equal(rpcBody.p_wear_status, 'worn'); assert.equal(created.body.wear_status, 'worn');
  for (const body of [{ worn_on: '2026-10-09', garment_ids: [topId], wear_status: 'planned' },
    { worn_on: '2026-10-09', garment_ids: [topId], wear_status: 'unconfirmed' }]) {
    const rejected = await invoke(ootdCollection, noNetwork, { method: 'POST', headers: { 'idempotency-key': 'ootd-planned-no' }, body });
    assert.equal(rejected.statusCode, 422);
  }
  const patched = await invoke(ootdItem, noNetwork, { method: 'PATCH', query: { ootdId }, body: { expected_version: 1, wear_status: 'planned' } });
  assert.equal(patched.statusCode, 422);
});

test('OOTD list orders a day newest-first and the cursor carries created_at for same-day records', async () => {
  const urls = [];
  const second = ootdRow({ id: otherOotdId, created_at: '2026-10-09T01:00:00+00:00' });
  const network = async url => { const a = auth(url); if (a) return a; const value = String(url);
    if (value.includes('/rest/v1/ootd_entries')) { urls.push(new URL(value)); return response(200, [ootdRow(), second]); }
    return closetReads(value) ?? assert.fail(`unexpected ${value}`); };
  const page = await invoke(ootdCollection, network, { query: { from: '2026-10-01', to: '2026-10-31', limit: '1' } });
  assert.equal(page.statusCode, 200); assert.equal(page.body.items.length, 1);
  assert.equal(urls[0].searchParams.get('order'), 'worn_on.desc,created_at.desc,id.desc');
  const cursor = JSON.parse(Buffer.from(page.body.next_cursor, 'base64url').toString('utf8'));
  assert.deepEqual(cursor, { v: 2, kind: 'ootd', worn_on: '2026-10-09', created_at: '2026-10-09T03:00:00.123456+00:00', id: ootdId,
    from: '2026-10-01', to: '2026-10-31' });
  const next = await invoke(ootdCollection, network, { query: { from: '2026-10-01', to: '2026-10-31', limit: '1', cursor: page.body.next_cursor } });
  assert.equal(next.statusCode, 200);
  assert.equal(urls[1].searchParams.get('or'), `(worn_on.lt.2026-10-09,and(worn_on.eq.2026-10-09,created_at.lt."2026-10-09T03:00:00.123456+00:00"),` +
    `and(worn_on.eq.2026-10-09,created_at.eq."2026-10-09T03:00:00.123456+00:00",id.lt.${ootdId}))`);
  const legacy = Buffer.from(JSON.stringify({ v: 1, kind: 'ootd', worn_on: '2026-10-09', id: ootdId, from: '2026-10-01', to: '2026-10-31' })).toString('base64url');
  const old = await invoke(ootdCollection, noNetwork, { query: { from: '2026-10-01', to: '2026-10-31', cursor: legacy } });
  assert.equal(old.statusCode, 400);
});

test('OOTD calendar returns per-day count and a signed representative photo only', async () => {
  const photoKey = `${userId}/ootd_photo/abababab-abab-4bab-8bab-abababababab.jpg`;
  let rpcBody;
  const result = await invoke(ootdCalendar, async (url, options) => { const a = auth(url); if (a) return a; const value = String(url);
    if (value.includes('/rpc/get_my_ootd_calendar')) {
      rpcBody = JSON.parse(options.body);
      return response(200, [
        { date: '2026-10-09', count: 3, representative_ootd_id: ootdId, has_photo: true, weather_snapshot_id: null },
        { date: '2026-10-02', count: 1, representative_ootd_id: otherOotdId, has_photo: false, weather_snapshot_id: null }]);
    }
    if (value.includes('/rest/v1/ootd_entries')) {
      assert.equal(new URL(value).searchParams.get('id'), `in.(${ootdId})`);
      return response(200, [{ id: ootdId, photo_object_key: photoKey }]);
    }
    if (value.includes('/storage/v1/object/sign/ootd-private')) return response(200, [{ path: photoKey, signedURL: `/storage/v1/object/sign/ootd-private/${photoKey}?token=t` }]);
    assert.fail(`unexpected ${value}`);
  }, { query: { from: '2026-09-28', to: '2026-11-08' } });
  assert.equal(result.statusCode, 200);
  assert.deepEqual(rpcBody, { p_from: '2026-09-28', p_to: '2026-11-08' });
  assert.equal(result.body.days.length, 2); assert.equal(result.body.days[0].count, 3);
  assert.match(result.body.days[0].photo.url, /\/storage\/v1\/object\/sign\/ootd-private\//); assert.equal(result.body.days[1].photo, null);
  assert.equal(JSON.stringify(result.body).includes('photo_object_key'), false);
  for (const [query, status] of [[{ from: '2026-09-01', to: '2026-11-08' }, 422], [{ from: '2026-10-09', to: '2026-10-01' }, 422],
    [{ from: '2026-10-01' }, 422], [{ from: '2026-10-01', to: '2026-10-02', limit: '5' }, 400]]) {
    const bad = await invoke(ootdCalendar, noNetwork, { query });
    assert.equal(bad.statusCode, status);
  }
  const foreign = await invoke(ootdCalendar, async url => auth(url) ?? (String(url).includes('/rpc/')
    ? response(200, [{ date: '2026-10-09', count: 1, representative_ootd_id: ootdId, has_photo: true, weather_snapshot_id: null }])
    : response(200, [{ id: ootdId, photo_object_key: 'someone/ootd_photo/x.jpg' }])),
  { query: { from: '2026-10-01', to: '2026-10-31' } });
  assert.equal(foreign.statusCode, 500);
});

// ---------------------------------------------------------------- consent
const profileRow = { id: userId, display_name: null, timezone: 'Asia/Seoul', default_tpo: null, onboarding_completed: true,
  ai_notice_accepted_at: '2026-10-10T00:00:00+00:00', training_consent: true, avatar_object_key: null, preferences: [] };

test('PATCH /me accepts the AI notice and training consent through one settings RPC and returns them', async () => {
  let rpcBody;
  const result = await invoke(meHandler, async (url, options) => { const a = auth(url); if (a) return a; const value = String(url);
    if (value.includes('/rpc/update_my_profile_settings')) { rpcBody = JSON.parse(options.body); return response(204); }
    return response(200, [profileRow]);
  }, { method: 'PATCH', body: { ai_notice_accepted: true, training_consent: true } });
  assert.equal(result.statusCode, 200);
  assert.deepEqual(rpcBody, { p_set_display_name: false, p_display_name: null, p_set_timezone: false, p_timezone: null,
    p_set_avatar: false, p_avatar_upload_id: null, p_accept_ai_notice: true, p_set_training_consent: true, p_training_consent: true });
  assert.equal(result.body.ai_notice_accepted_at, '2026-10-10T00:00:00+00:00'); assert.equal(result.body.training_consent, true);
  for (const body of [{ ai_notice_accepted: false }, { ai_notice_accepted: 'yes' }, { training_consent: null }, { training_consent: 1 }]) {
    const invalid = await invoke(meHandler, noNetwork, { method: 'PATCH', body });
    assert.equal(invalid.statusCode, 422);
  }
});

test('analysis create and retry map ai_notice_required to 403 AI_NOTICE_REQUIRED', async () => {
  for (const [handler, query] of [[createJobHandler, { batchId }], [retryJobHandler, { jobId: ootdId }]]) {
    const result = await invoke(handler, async url => auth(url) ?? response(400, { code: 'P0001', message: 'ai_notice_required' }),
      { method: 'POST', query, headers: { 'idempotency-key': 'notice-check-1' } });
    assert.equal(result.statusCode, 403); assert.equal(result.body.error.code, 'AI_NOTICE_REQUIRED'); assert.equal(result.body.error.retryable, false);
  }
});

// ---------------------------------------------------------------- account deletion
function deletionNetwork(calls, { purge = () => response(200, { user_id: userId, profile_deleted: true, storage_objects_enqueued: 4 }),
  admin = () => response(200, {}) } = {}) {
  return async (url, options) => {
    const value = String(url); calls.push({ url: value, options });
    if (value.includes('/auth/v1/user')) return response(200, { id: userId });
    if (value.endsWith('/rest/v1/rpc/purge_account_data')) return purge();
    if (value.includes('/auth/v1/admin/users/')) return admin();
    assert.fail(`unexpected ${value}`);
  };
}

test('DELETE /me verifies the user JWT, purges with the server key, deletes the auth user and returns 202', async () => {
  const calls = [];
  const result = await invoke(meHandler, deletionNetwork(calls), { method: 'DELETE', headers: { 'idempotency-key': 'delete-me-1' }, runtimeEnv: secretEnv });
  assert.equal(result.statusCode, 202); assert.deepEqual(result.body, { id: userId, status: 'deletion_pending' });
  assert.deepEqual(calls.map(call => [call.options.method ?? 'GET', new URL(call.url).pathname]), [
    ['GET', '/auth/v1/user'], ['POST', '/rest/v1/rpc/purge_account_data'], ['DELETE', `/auth/v1/admin/users/${userId}`]]);
  // The user token never reaches the admin steps; the secret key never reaches the user step or the response.
  assert.equal(calls[0].options.headers.Authorization, 'Bearer header.payload.signature');
  assert.equal(calls[1].options.headers.Authorization, `Bearer ${secret}`); assert.equal(calls[2].options.headers.apikey, secret);
  assert.deepEqual(JSON.parse(calls[1].options.body), { p_user_id: userId });
  assert.equal(JSON.stringify(calls[0]).includes(secret), false); assert.equal(JSON.stringify(result).includes(secret), false);
});

test('DELETE /me is retry-safe: admin failure is retryable, an already-deleted auth user is success', async () => {
  const failed = await invoke(meHandler, deletionNetwork([], { admin: () => response(500, {}) }),
    { method: 'DELETE', headers: { 'idempotency-key': 'delete-me-2' }, runtimeEnv: secretEnv });
  assert.equal(failed.statusCode, 503); assert.equal(failed.body.error.code, 'ACCOUNT_DELETION_INCOMPLETE'); assert.equal(failed.body.error.retryable, true);
  const retried = await invoke(meHandler, deletionNetwork([], {
    purge: () => response(200, { user_id: userId, profile_deleted: false, storage_objects_enqueued: 0 }), admin: () => response(404, {}) }),
  { method: 'DELETE', headers: { 'idempotency-key': 'delete-me-2' }, runtimeEnv: secretEnv });
  assert.equal(retried.statusCode, 202);
  const calls = [];
  const purgeDown = await invoke(meHandler, deletionNetwork(calls, { purge: () => response(503, { message: 'x' }) }),
    { method: 'DELETE', headers: { 'idempotency-key': 'delete-me-3' }, runtimeEnv: secretEnv });
  assert.equal(purgeDown.statusCode, 503); assert.equal(purgeDown.body.error.retryable, true);
  assert.equal(calls.some(call => call.url.includes('/admin/')), false, 'auth user must survive until the data purge succeeded');
});

test('DELETE /me fails closed without the Idempotency-Key or the server key', async () => {
  const noKey = await invoke(meHandler, noNetwork, { method: 'DELETE', runtimeEnv: secretEnv });
  assert.equal(noKey.statusCode, 422);
  const calls = [];
  const noSecret = await invoke(meHandler, deletionNetwork(calls), { method: 'DELETE', headers: { 'idempotency-key': 'delete-me-4' } });
  assert.equal(noSecret.statusCode, 503); assert.equal(noSecret.body.error.code, 'INTERNAL_INTEGRATION_NOT_CONFIGURED');
  assert.equal(calls.some(call => call.url.includes('purge_account_data')), false);
  const anonymous = await invoke(meHandler, noNetwork, { method: 'DELETE', headers: { 'idempotency-key': 'delete-me-5', authorization: '' }, runtimeEnv: secretEnv });
  assert.equal(anonymous.statusCode, 401);
});
