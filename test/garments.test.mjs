import test from 'node:test';
import assert from 'node:assert/strict';
import { createHandler as createListHandler } from '../api/v1/garments.js';
import { createHandler as createDetailHandler } from '../api/v1/garments/[garmentId].js';

const requestId = '11111111-1111-4111-8111-111111111111';
const userId = '22222222-2222-4222-8222-222222222222';
const garmentId = '33333333-3333-4333-8333-333333333333';
const secondGarmentId = '33333333-3333-4333-8333-333333333332';
const assetId = '44444444-4444-4444-8444-444444444444';
const batchId = '55555555-5555-4555-8555-555555555555';
const sourceId = '66666666-6666-4666-8666-666666666666';
const token = 'header.payload.signature';
const env = { SUPABASE_URL: 'https://abcdefghijklmnopqrst.supabase.co', SUPABASE_PUBLISHABLE_KEY: 'publishable-test' };
const createdAt = '2026-09-30T01:02:03.123456+00:00';
const updatedAt = '2026-09-30T02:03:04.123456+00:00';

function response(status, body, headers = {}) {
  return { status, headers: { get: name => headers[name.toLowerCase()] ?? null }, async json() {
    if (body === undefined) throw Error('no body');
    return body;
  } };
}

function invoke(createHandler, options = {}) {
  const result = { headers: {}, statusCode: 200 };
  const headers = { authorization: `Bearer ${token}`, ...(options.headers ?? {}) };
  if (options.body !== undefined && headers['content-type'] === undefined) headers['content-type'] = 'application/json';
  const req = { method: options.method ?? 'GET', headers, query: options.query ?? {}, body: options.body };
  const res = { setHeader(k, v) { result.headers[k] = v; }, status(v) { result.statusCode = v; return this; },
    json(v) { result.body = v; return result; }, end() { return result; } };
  return createHandler({ env, request: options.request, createRequestId: () => requestId,
    now: () => new Date('2026-09-30T03:00:00.000Z') })(req, res);
}

function garment(id = garmentId, overrides = {}) {
  return { id, asset_id: assetId, category: 'top', attributes: { category: 'private-old', subcategory: 'tee', secret: true },
    memo: 'fixture note', version: 2, created_at: createdAt, updated_at: updatedAt, ...overrides };
}

function successFetch(calls, garmentRows = [garment()]) {
  return async (url, options) => {
    calls.push({ url: String(url), options });
    const value = String(url);
    if (value.includes('/auth/v1/user')) return response(200, { id: userId, private: true });
    if (value.includes('/rest/v1/garments')) return response(200, garmentRows);
    if (value.includes('/rest/v1/garment_assets')) {
      const parsed = new URL(value);
      if (parsed.searchParams.get('kind') === 'eq.cutout') return response(200, [{ id: assetId, batch_id: batchId,
        kind: 'cutout', bucket_id: 'closet-private', object_key: `${userId}/cutout.png`, verified_at: createdAt, deleted_at: null }]);
      return response(200, [{ id: sourceId, batch_id: batchId, kind: 'source', bucket_id: 'closet-private',
        object_key: `${userId}/source.jpg`, verified_at: createdAt, deleted_at: null }]);
    }
    if (value.includes('/storage/v1/object/sign/closet-private')) {
      const paths = JSON.parse(options.body).paths;
      return response(200, paths.map(path => ({ path, signedURL: `/storage/v1/object/sign/closet-private/${path}?token=fixture` })));
    }
    assert.fail(`unexpected request ${value}`);
  };
}

test('listGarments applies keyset pagination and returns only the safe signed projection', async () => {
  const calls = [];
  const rows = [garment(), garment(secondGarmentId, { created_at: '2026-09-29T01:02:03.123456+00:00' })];
  const result = await invoke(createListHandler, { query: { limit: '1', category: 'top' }, request: successFetch(calls, rows) });
  assert.equal(result.statusCode, 200);
  assert.equal(result.body.items.length, 1);
  assert.equal(typeof result.body.next_cursor, 'string');
  assert.deepEqual(result.body.items[0], {
    id: garmentId,
    attributes: { category: 'top', subcategory: 'tee', note: 'fixture note' },
    image: { url: `https://abcdefghijklmnopqrst.supabase.co/storage/v1/object/sign/closet-private/${userId}/cutout.png?token=fixture`, expires_at: '2026-09-30T03:05:00.000Z' },
    version: 2, created_at: createdAt, updated_at: updatedAt,
    original_image: { url: `https://abcdefghijklmnopqrst.supabase.co/storage/v1/object/sign/closet-private/${userId}/source.jpg?token=fixture`, expires_at: '2026-09-30T03:05:00.000Z' }
  });
  assert.equal(JSON.stringify(result).includes('object_key'), false);
  assert.equal(JSON.stringify(result).includes('secret'), false);
  const garmentCall = calls.find(call => call.url.includes('/rest/v1/garments'));
  const garmentUrl = new URL(garmentCall.url);
  assert.equal(garmentUrl.searchParams.get('limit'), '2');
  assert.equal(garmentUrl.searchParams.get('order'), 'created_at.desc,id.desc');
  assert.equal(garmentUrl.searchParams.get('category'), 'eq.top');

  const nextCalls = [];
  await invoke(createListHandler, { query: { limit: '1', category: 'top', cursor: result.body.next_cursor }, request: successFetch(nextCalls, []) });
  const nextUrl = new URL(nextCalls.find(call => call.url.includes('/rest/v1/garments')).url);
  assert.match(nextUrl.searchParams.get('or'), /created_at\.lt\."2026-09-30T01:02:03\.123456\+00:00"/);
  assert.match(nextUrl.searchParams.get('or'), new RegExp(`id\\.lt\\.${garmentId}`));
});

test('list query and cursor validation fail before authentication', async () => {
  for (const query of [
    { unknown: 'x' }, { limit: '0' }, { limit: '101' }, { limit: '1.5' }, { category: 'not-real' },
    { cursor: 'not-json' }, { category: ['top'] }
  ]) {
    const result = await invoke(createListHandler, { query, request: async () => assert.fail('network called') });
    assert.ok([400, 422].includes(result.statusCode));
  }
});

test('getGarment returns 404 for an absent owned row and rejects invalid path ids locally', async () => {
  const missing = await invoke(createDetailHandler, { query: { garmentId }, request: async url =>
    String(url).includes('/auth/') ? response(200, { id: userId }) : response(200, []) });
  assert.equal(missing.statusCode, 404);
  assert.equal(missing.body.error.code, 'GARMENT_NOT_FOUND');
  const invalid = await invoke(createDetailHandler, { query: { garmentId: 'not-a-uuid' }, request: async () => assert.fail('network called') });
  assert.equal(invalid.statusCode, 422);
});

test('PATCH sends exact presence flags and rereads the safe DTO', async () => {
  const calls = [];
  const request = async (url, options) => {
    calls.push({ url: String(url), options });
    if (String(url).includes('/auth/')) return response(200, { id: userId });
    if (String(url).includes('/rpc/update_my_garment')) return response(204);
    return successFetch([], [garment(undefined, { category: 'bag', attributes: { subcategory: null }, memo: null, version: 3 })])(url, options);
  };
  const result = await invoke(createDetailHandler, { method: 'PATCH', query: { garmentId },
    body: { expected_version: 2, attributes: { category: 'bag', subcategory: null, note: null } }, request });
  assert.equal(result.statusCode, 200);
  const rpc = calls.find(call => call.url.includes('/rpc/update_my_garment'));
  assert.deepEqual(JSON.parse(rpc.options.body), {
    p_garment_id: garmentId, p_expected_version: 2,
    p_set_category: true, p_category: 'bag', p_set_subcategory: true, p_subcategory: null,
    p_set_memo: true, p_memo: null
  });
  assert.equal(result.body.attributes.category, 'bag');
  assert.equal(result.body.attributes.note, null);
});

test('PATCH validates exact body and maps known RPC conflicts safely', async () => {
  for (const body of [
    {}, { expected_version: 1, attributes: {} }, { expected_version: 1, attributes: { category: 'bad' } },
    { expected_version: 1, attributes: { note: 'x\u0000y' } },
    { expected_version: 1, attributes: { subcategory: 'x'.repeat(81) } }
  ]) {
    const result = await invoke(createDetailHandler, { method: 'PATCH', query: { garmentId }, body,
      request: async () => assert.fail('network called') });
    assert.equal(result.statusCode, body && Object.keys(body).length === 0 ? 422 : 422);
  }
  const request = async url => String(url).includes('/auth/') ? response(200, { id: userId })
    : response(400, { code: 'P0001', message: 'version_conflict', details: token });
  const conflict = await invoke(createDetailHandler, { method: 'PATCH', query: { garmentId },
    body: { expected_version: 1, attributes: { note: 'new' } }, request });
  assert.equal(conflict.statusCode, 409);
  assert.equal(conflict.body.error.code, 'VERSION_CONFLICT');
  assert.equal(JSON.stringify(conflict).includes(token), false);
});

test('DELETE requires a safe idempotency key and returns the replayable 202 projection', async () => {
  const missing = await invoke(createDetailHandler, { method: 'DELETE', query: { garmentId }, request: async () => assert.fail('network called') });
  assert.equal(missing.statusCode, 422);
  const calls = [];
  const result = await invoke(createDetailHandler, { method: 'DELETE', query: { garmentId },
    headers: { 'idempotency-key': 'delete-key-one' }, request: async (url, options) => {
      calls.push({ url: String(url), options });
      return String(url).includes('/auth/') ? response(200, { id: userId }) : response(204);
    } });
  assert.equal(result.statusCode, 202);
  assert.deepEqual(result.body, { id: garmentId, status: 'deletion_pending' });
  assert.deepEqual(JSON.parse(calls[1].options.body), { p_garment_id: garmentId, p_idempotency_key: 'delete-key-one' });
});

test('asset item failures become null while whole Storage failures return a safe 503', async () => {
  const itemFailure = await invoke(createListHandler, { request: async (url, options) => {
    const value = String(url);
    if (value.includes('/auth/')) return response(200, { id: userId });
    if (value.includes('/rest/v1/garments')) return response(200, [garment()]);
    if (value.includes('/rest/v1/garment_assets')) return successFetch([], [garment()])(url, options);
    if (value.includes('/storage/')) return response(200, JSON.parse(options.body).paths.map(path => ({ path, error: 'not_found', signedURL: null })));
  } });
  assert.equal(itemFailure.statusCode, 200);
  assert.equal(itemFailure.body.items[0].image, null);
  assert.equal(itemFailure.body.items[0].original_image, null);

  const wholeFailure = await invoke(createListHandler, { request: async (url, options) => {
    if (String(url).includes('/storage/')) return response(500, { private: true });
    return successFetch([], [garment()])(url, options);
  } });
  assert.equal(wholeFailure.statusCode, 503);
  assert.equal(wholeFailure.body.error.code, 'STORAGE_UNAVAILABLE');
  assert.equal(JSON.stringify(wholeFailure).includes('private'), false);
});
