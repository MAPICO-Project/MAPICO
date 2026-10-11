// 2026-10-09 user-flow alignment: aesthetic main/sub roles, avatar via PATCH /me, owner media uploads.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHandler as createMeHandler } from '../api/v1/me.js';
import { createHandler as createPreferencesHandler } from '../api/v1/me/aesthetics.js';
import { createHandler as createUploadHandler } from '../api/v1/media-uploads/index.js';
import { createHandler as createUploadCompleteHandler } from '../api/v1/media-uploads/[uploadId]/complete-upload.js';

const requestId = '11111111-1111-4111-8111-111111111111';
const userId = '22222222-2222-4222-8222-222222222222';
const first = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
const second = 'BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB';
const third = 'CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC';
const uploadId = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
const env = { SUPABASE_URL: 'https://abcdefghijklmnopqrst.supabase.co', SUPABASE_PUBLISHABLE_KEY: 'publishable-test' };

function response(status, body, headers = {}, bytes) {
  return { status, headers: { get: name => headers[name.toLowerCase()] ?? null }, async json() { return body; },
    async arrayBuffer() { return (bytes ?? new Uint8Array()).buffer; } };
}
function invoke(create, request, { method = 'POST', query = {}, body, headers = {} } = {}) {
  const out = { headers: {} }; const reqHeaders = { authorization: 'Bearer header.payload.signature', ...headers };
  if (body !== undefined) reqHeaders['content-type'] = 'application/json';
  const req = { method, query, body, headers: reqHeaders };
  const res = { setHeader(k, v) { out.headers[k] = v; }, status(v) { out.statusCode = v; return this; },
    json(v) { out.body = v; return out; }, end() { out.ended = true; return out; } };
  return create({ env, request, now: () => new Date('2026-10-09T00:00:00.000Z'), createRequestId: () => requestId })(req, res);
}
const auth = url => String(url).includes('/auth/v1/user') ? response(200, { id: userId }) : null;
const noNetwork = async () => assert.fail('network called');
const profileRow = (overrides = {}) => ({ id: userId, display_name: null, timezone: 'Asia/Seoul', default_tpo: null,
  onboarding_completed: true, ai_notice_accepted_at: null, training_consent: false, avatar_object_key: null, preferences: [], ...overrides });

test('PUT /me/aesthetics requires exactly one main, at most two subs, and all-or-none weights with main >= sub', async () => {
  const invalid = [
    [{ aesthetic_id: first, weight: 1 }],
    [{ aesthetic_id: first, role: 'sub' }],
    [{ aesthetic_id: first, role: 'primary' }],
    [{ aesthetic_id: first, role: 'main' }, { aesthetic_id: second, role: 'main' }],
    [{ aesthetic_id: first, role: 'main', weight: 1 }, { aesthetic_id: second, role: 'sub' }],
    [{ aesthetic_id: first, role: 'main', weight: 0.3 }, { aesthetic_id: second, role: 'sub', weight: 0.7 }],
    [{ aesthetic_id: first, role: 'main', weight: 0.6 }, { aesthetic_id: second, role: 'sub', weight: 0.6 }],
    [{ aesthetic_id: first, role: 'main' }, { aesthetic_id: second, role: 'sub' }, { aesthetic_id: third, role: 'sub' },
      { aesthetic_id: 'DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD', role: 'sub' }]
  ];
  for (const preferences of invalid) {
    const result = await invoke(createPreferencesHandler, noNetwork, { method: 'PUT', body: { preferences } });
    assert.equal(result.statusCode, 422, JSON.stringify(preferences));
  }
  const calls = [];
  const request = async (url, options) => {
    calls.push({ url: String(url), options }); const a = auth(url); if (a) return a;
    if (String(url).includes('/rpc/')) return response(204);
    return response(200, [
      { aesthetic_id: second.toLowerCase(), role: 'main', weight: 1 / 3 },
      { aesthetic_id: first.toLowerCase(), role: 'sub', weight: 1 / 3 },
      { aesthetic_id: third.toLowerCase(), role: 'sub', weight: 1 / 3 }
    ]);
  };
  const result = await invoke(createPreferencesHandler, request, { method: 'PUT', body: { preferences: [
    { aesthetic_id: first, role: 'sub' }, { aesthetic_id: second, role: 'main' }, { aesthetic_id: third, role: 'sub' }
  ] } });
  assert.equal(result.statusCode, 200);
  assert.deepEqual(JSON.parse(calls[1].options.body).p_preferences, [
    { aesthetic_id: first.toLowerCase(), role: 'sub' }, { aesthetic_id: second.toLowerCase(), role: 'main' },
    { aesthetic_id: third.toLowerCase(), role: 'sub' }
  ]);
  assert.equal(new URL(calls[2].url).searchParams.get('order'), 'role.asc,aesthetic_id.asc');
  assert.deepEqual(result.body.preferences.map(item => item.role), ['main', 'sub', 'sub']);
  for (const message of ['invalid_aesthetic_roles', 'invalid_main_weight']) {
    const failed = await invoke(createPreferencesHandler, async url => auth(url) ?? response(400, { code: '22023', message }),
      { method: 'PUT', body: { preferences: [{ aesthetic_id: first, role: 'main' }] } });
    assert.equal(failed.statusCode, 422); assert.equal(failed.body.error.code, 'VALIDATION_ERROR');
  }
  const corrupt = await invoke(createPreferencesHandler, async url => auth(url) ??
    (String(url).includes('/rpc/') ? response(204) : response(200, [{ aesthetic_id: first.toLowerCase(), role: 'sub', weight: 1 }])),
  { method: 'PUT', body: { preferences: [{ aesthetic_id: first, role: 'main' }] } });
  assert.equal(corrupt.statusCode, 500);
});

test('PATCH /me attaches or clears the avatar upload and GET /me returns only a signed avatar read', async () => {
  const avatarKey = `${userId}/avatar/${uploadId}.png`;
  const calls = [];
  const request = async (url, options) => {
    calls.push({ url: String(url), options }); const a = auth(url); if (a) return a; const value = String(url);
    if (value.includes('/rpc/update_my_profile_settings')) return response(204);
    if (value.includes('/storage/v1/object/sign/profile-media')) {
      return response(200, [{ path: avatarKey, signedURL: `/storage/v1/object/sign/profile-media/${avatarKey}?token=t` }]);
    }
    return response(200, [profileRow({ avatar_object_key: avatarKey })]);
  };
  const result = await invoke(createMeHandler, request, { method: 'PATCH', body: { avatar_upload_id: uploadId.toUpperCase() } });
  assert.equal(result.statusCode, 200);
  assert.deepEqual(JSON.parse(calls[1].options.body), {
    p_set_display_name: false, p_display_name: null, p_set_timezone: false, p_timezone: null,
    p_set_avatar: true, p_avatar_upload_id: uploadId,
    p_accept_ai_notice: false, p_set_training_consent: false, p_training_consent: null
  });
  assert.match(result.body.avatar.url, /^https:\/\/abcdefghijklmnopqrst\.supabase\.co\/storage\/v1\/object\/sign\/profile-media\//);
  assert.equal(result.body.avatar.expires_at, '2026-10-09T00:05:00.000Z');
  assert.equal(JSON.stringify(result.body).includes('avatar_object_key'), false);
  assert.deepEqual(JSON.parse(calls.find(call => call.url.includes('/object/sign/')).options.body), { expiresIn: 300, paths: [avatarKey] });

  const got = await invoke(createMeHandler, request, { method: 'GET' });
  assert.equal(got.statusCode, 200); assert.equal(typeof got.body.avatar.url, 'string');

  const cleared = await invoke(createMeHandler, async (url, options) => {
    const a = auth(url); if (a) return a;
    if (String(url).includes('/rpc/')) { assert.equal(JSON.parse(options.body).p_avatar_upload_id, null); return response(204); }
    if (String(url).includes('/object/sign/')) assert.fail('no avatar should not be signed');
    return response(200, [profileRow()]);
  }, { method: 'PATCH', body: { avatar_upload_id: null } });
  assert.equal(cleared.statusCode, 200); assert.equal(cleared.body.avatar, null);

  for (const body of [{ avatar_upload_id: 'not-a-uuid' }, { avatar_upload_id: 7 }, { avatar_url: 'https://example.com/a.png' }]) {
    const invalid = await invoke(createMeHandler, noNetwork, { method: 'PATCH', body });
    assert.equal(invalid.statusCode, 422);
  }
  for (const [code, message, status, expected] of [
    ['P0001', 'media_upload_not_ready', 409, 'MEDIA_UPLOAD_CONFLICT'], ['P0002', 'media_upload_not_found', 404, 'MEDIA_UPLOAD_NOT_FOUND']
  ]) {
    const failed = await invoke(createMeHandler, async url => auth(url) ?? response(400, { code, message }),
      { method: 'PATCH', body: { avatar_upload_id: uploadId } });
    assert.equal(failed.statusCode, status); assert.equal(failed.body.error.code, expected);
  }
  const foreign = await invoke(createMeHandler, async url => auth(url) ?? response(200, [profileRow({ avatar_object_key: 'someone/avatar/x.png' })]),
    { method: 'GET' });
  assert.equal(foreign.statusCode, 500);
});

test('POST /media-uploads validates strictly and returns a signed PUT without exposing the object key', async () => {
  const objectKey = `${userId}/ootd_photo/${uploadId}.jpg`;
  const row = { id: uploadId, purpose: 'ootd_photo', bucket_id: 'ootd-private', object_key: objectKey, content_type: 'image/jpeg',
    byte_size: 3, verified_at: null, attached_at: null, deleted_at: null };
  const calls = [];
  const request = async (url, options) => {
    calls.push({ url: String(url), options }); const a = auth(url); if (a) return a; const value = String(url);
    if (value.includes('/rpc/create_my_media_upload')) return response(200, { upload_id: uploadId, replayed: false });
    if (value.includes('/storage/v1/object/upload/sign/')) return response(200, { url: `/object/upload/sign/ootd-private/${objectKey}?token=up` });
    if (value.includes('/rest/v1/media_uploads')) return response(200, [row]);
    assert.fail(`unexpected ${value}`);
  };
  const body = { purpose: 'ootd_photo', content_type: 'image/jpeg', file_size: 3 };
  assert.equal((await invoke(createUploadHandler, noNetwork, { body })).statusCode, 422);
  for (const bad of [{ ...body, purpose: 'banner' }, { ...body, content_type: 'image/gif' }, { ...body, file_size: 20971521 },
    { purpose: 'avatar', content_type: 'image/png' }, { ...body, object_key: 'x' }]) {
    const invalid = await invoke(createUploadHandler, noNetwork, { body: bad, headers: { 'idempotency-key': 'upload-one' } });
    assert.equal(invalid.statusCode, 422, JSON.stringify(bad));
  }
  const created = await invoke(createUploadHandler, request, { body, headers: { 'idempotency-key': 'upload-one' } });
  assert.equal(created.statusCode, 201);
  assert.equal(created.body.id, uploadId); assert.equal(created.body.purpose, 'ootd_photo');
  assert.deepEqual(created.body.upload.headers, { 'Content-Type': 'image/jpeg' }); assert.equal(created.body.upload.method, 'PUT');
  assert.match(created.body.upload.url, /\/storage\/v1\/object\/upload\/sign\/ootd-private\//);
  assert.equal(created.body.upload.expires_at, '2026-10-09T01:50:00.000Z');
  assert.equal(JSON.stringify(created.body).includes('object_key'), false);
  assert.deepEqual(JSON.parse(calls[1].options.body), { p_purpose: 'ootd_photo', p_content_type: 'image/jpeg', p_file_size: 3, p_idempotency_key: 'upload-one' });

  const replayVerified = await invoke(createUploadHandler, async url => auth(url) ??
    (String(url).includes('/rpc/') ? response(200, { upload_id: uploadId, replayed: true }) : response(200, [{ ...row, verified_at: '2026-10-09T00:00:00Z' }])),
  { body, headers: { 'idempotency-key': 'upload-one' } });
  assert.equal(replayVerified.statusCode, 409); assert.equal(replayVerified.body.error.code, 'MEDIA_UPLOAD_CONFLICT');
  const limit = await invoke(createUploadHandler, async url => auth(url) ?? response(400, { code: 'P0001', message: 'too_many_open_uploads' }),
    { body, headers: { 'idempotency-key': 'upload-two' } });
  assert.equal(limit.statusCode, 409); assert.equal(limit.body.error.code, 'TOO_MANY_OPEN_UPLOADS');
});

test('POST /media-uploads/{id}/complete-upload checks magic bytes and maps outcomes', async () => {
  const objectKey = `${userId}/avatar/${uploadId}.png`;
  const row = { id: uploadId, purpose: 'avatar', bucket_id: 'profile-media', object_key: objectKey, content_type: 'image/png',
    byte_size: 8, verified_at: null, attached_at: null, deleted_at: null };
  const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const flow = (bytes, invalid = false, overrides = {}) => {
    const calls = [];
    const request = async (url, options) => {
      calls.push({ url: String(url), options }); const a = auth(url); if (a) return a; const value = String(url);
      if (value.includes('/storage/v1/object/authenticated/profile-media/')) return response(200, null, { 'content-type': 'image/png' }, bytes);
      if (value.includes('/rpc/complete_my_media_upload')) return response(200, { upload_id: uploadId, purpose: 'avatar', invalid });
      if (value.includes('/rest/v1/media_uploads')) return response(200, [{ ...row, ...overrides }]);
      assert.fail(`unexpected ${value}`);
    };
    return { calls, request };
  };
  const ok = flow(png);
  const done = await invoke(createUploadCompleteHandler, ok.request, { query: { uploadId } });
  assert.equal(done.statusCode, 200);
  assert.deepEqual(done.body, { id: uploadId, purpose: 'avatar', status: 'verified' });
  assert.deepEqual(JSON.parse(ok.calls.at(-1).options.body), { p_upload_id: uploadId, p_outcome: 'valid' });

  const bad = flow(new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]), true);
  const rejected = await invoke(createUploadCompleteHandler, bad.request, { query: { uploadId } });
  assert.equal(rejected.statusCode, 422);
  assert.deepEqual(JSON.parse(bad.calls.at(-1).options.body), { p_upload_id: uploadId, p_outcome: 'invalid' });

  const verified = flow(png, false, { verified_at: '2026-10-09T00:00:00Z' });
  const replay = await invoke(createUploadCompleteHandler, verified.request, { query: { uploadId } });
  assert.equal(replay.statusCode, 200);
  assert.equal(verified.calls.some(call => call.url.includes('/object/authenticated/')), false);

  const retired = await invoke(createUploadCompleteHandler, flow(png, false, { deleted_at: '2026-10-09T00:00:00Z' }).request, { query: { uploadId } });
  assert.equal(retired.statusCode, 409); assert.equal(retired.body.error.code, 'MEDIA_UPLOAD_CONFLICT');
  const missingObject = await invoke(createUploadCompleteHandler, async url => auth(url) ??
    (String(url).includes('/object/authenticated/') ? response(404, null) : response(200, [row])), { query: { uploadId } });
  assert.equal(missingObject.statusCode, 409); assert.equal(missingObject.body.error.code, 'UPLOAD_NOT_FOUND');
  const missing = await invoke(createUploadCompleteHandler, async url => auth(url) ?? response(200, []), { query: { uploadId } });
  assert.equal(missing.statusCode, 404); assert.equal(missing.body.error.code, 'MEDIA_UPLOAD_NOT_FOUND');
  const foreignKey = await invoke(createUploadCompleteHandler, async url => auth(url) ?? response(200, [{ ...row, object_key: 'other/avatar/x.png' }]),
    { query: { uploadId } });
  assert.equal(foreignKey.statusCode, 500);
  assert.equal((await invoke(createUploadCompleteHandler, noNetwork, { query: { uploadId: 'x' } })).statusCode, 422);
  assert.equal((await invoke(createUploadCompleteHandler, noNetwork, { query: { uploadId }, method: 'GET' })).statusCode, 405);
});
