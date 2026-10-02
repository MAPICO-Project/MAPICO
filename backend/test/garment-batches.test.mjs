import test from 'node:test';
import assert from 'node:assert/strict';
import { createHandler as createBatchHandler } from '../api/v1/garment-batches.js';
import { createHandler as detailHandler } from '../api/v1/garment-batches/[batchId].js';
import { createHandler as refreshHandler } from '../api/v1/garment-batches/[batchId]/upload-url.js';
import { createHandler as completeHandler } from '../api/v1/garment-batches/[batchId]/complete-upload.js';

const requestId = '11111111-1111-4111-8111-111111111111';
const userId = '22222222-2222-4222-8222-222222222222';
const batchId = '33333333-3333-4333-8333-333333333333';
const assetId = '44444444-4444-4444-8444-444444444444';
const token = 'header.payload.signature';
const createdAt = '2026-09-30T01:02:03.123456+00:00';
const objectKey = `${userId}/${batchId}/source.jpg`;
const env = { SUPABASE_URL: 'https://abcdefghijklmnopqrst.supabase.co', SUPABASE_PUBLISHABLE_KEY: 'publishable-test' };

function response(status, body, headers = {}) {
  const bytes = body instanceof Uint8Array ? body : null;
  return { status, headers: { get: name => headers[name.toLowerCase()] ?? null },
    async json() { if (body === undefined || bytes) throw Error('no json'); return body; },
    async arrayBuffer() { if (!bytes) throw Error('no bytes'); return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength); } };
}
function invoke(createHandler, options = {}) {
  const result = { headers: {}, statusCode: 200 };
  const headers = { authorization: `Bearer ${token}`, ...(options.headers ?? {}) };
  if (options.body !== undefined && !headers['content-type']) headers['content-type'] = 'application/json';
  const req = { method: options.method ?? 'GET', headers, query: options.query ?? {}, body: options.body };
  const res = { setHeader(k, v) { result.headers[k] = v; }, status(v) { result.statusCode = v; return this; },
    json(v) { result.body = v; return result; }, end() { return result; } };
  return createHandler({ env, request: options.request, createRequestId: () => requestId,
    now: () => new Date('2026-09-30T03:00:00.000Z') })(req, res);
}
function batch(status = 'awaiting_upload') { return { id: batchId, status, created_at: createdAt }; }
function asset(overrides = {}) { return { id: assetId, batch_id: batchId, kind: 'source', bucket_id: 'closet-private',
  object_key: objectKey, content_type: 'image/jpeg', byte_size: 3, verified_at: null, deleted_at: null, ...overrides }; }
function auth(url) { return String(url).includes('/auth/v1/user'); }

test('createGarmentBatch creates through RPC then returns an exact non-upsert signed upload contract', async () => {
  const calls = [];
  const result = await invoke(createBatchHandler, { method: 'POST', headers: { 'idempotency-key': 'create-key-one' },
    body: { content_type: 'image/jpeg', file_size: 3 }, request: async (url, options) => {
      calls.push({ url: String(url), options });
      if (auth(url)) return response(200, { id: userId });
      if (String(url).includes('/rpc/create_my_garment_batch')) return response(200, { batch: batch(), object_key: objectKey });
      if (String(url).includes('/storage/v1/object/upload/sign/')) return response(200,
        { url: `/object/upload/sign/closet-private/${objectKey}?token=upload-fixture` });
      assert.fail(`unexpected request ${url}`);
    } });
  assert.equal(result.statusCode, 201);
  assert.deepEqual(result.body, { batch: batch(), upload: {
    url: `https://abcdefghijklmnopqrst.supabase.co/storage/v1/object/upload/sign/closet-private/${objectKey}?token=upload-fixture`,
    method: 'PUT', headers: { 'Content-Type': 'image/jpeg' }, expires_at: '2026-09-30T04:50:00.000Z'
  }, object_key: objectKey });
  const rpc = calls.find(call => call.url.includes('/rpc/'));
  assert.deepEqual(JSON.parse(rpc.options.body), { p_content_type: 'image/jpeg', p_file_size: 3, p_idempotency_key: 'create-key-one' });
  const signing = calls.find(call => call.url.includes('/object/upload/sign/'));
  assert.equal(signing.options.headers['x-upsert'], undefined);
  assert.equal(signing.options.body, '{}');
});

test('create validation and hostile signed URLs fail closed without leaking a token', async () => {
  for (const body of [{ content_type: 'text/plain', file_size: 3 }, { content_type: 'image/jpeg', file_size: 0 },
    { content_type: 'image/jpeg', file_size: 3, object_key: 'chosen' }]) {
    const result = await invoke(createBatchHandler, { method: 'POST', headers: { 'idempotency-key': 'create-key-one' }, body,
      request: async () => assert.fail('network called') });
    assert.equal(result.statusCode, 422);
  }
  const hostile = await invoke(createBatchHandler, { method: 'POST', headers: { 'idempotency-key': 'create-key-one' },
    body: { content_type: 'image/jpeg', file_size: 3 }, request: async url => {
      if (auth(url)) return response(200, { id: userId });
      if (String(url).includes('/rpc/')) return response(200, { batch: batch(), object_key: objectKey });
      return response(200, { url: `https://evil.example/upload?token=private-value` });
    } });
  assert.equal(hostile.statusCode, 503);
  assert.equal(JSON.stringify(hostile).includes('private-value'), false);
});

test('get and refresh are owner-filtered, state-bound, and refresh refuses an existing object', async () => {
  const get = await invoke(detailHandler, { query: { batchId }, request: async url => auth(url)
    ? response(200, { id: userId }) : response(200, [batch()]) });
  assert.equal(get.statusCode, 200);
  assert.deepEqual(get.body, batch());

  const existing = await invoke(refreshHandler, { method: 'POST', query: { batchId }, request: async url => {
    const value = String(url);
    if (auth(url)) return response(200, { id: userId });
    if (value.includes('/garment_batches')) return response(200, [batch()]);
    if (value.includes('/garment_assets')) return response(200, [asset()]);
    if (value.includes('/object/authenticated/')) return response(206, new Uint8Array([0xff]),
      { 'content-range': 'bytes 0-0/3', 'content-type': 'image/jpeg' });
    assert.fail(`unexpected request ${url}`);
  } });
  assert.equal(existing.statusCode, 409);

  const missing = await invoke(detailHandler, { query: { batchId }, request: async url => auth(url)
    ? response(200, { id: userId }) : response(200, []) });
  assert.equal(missing.statusCode, 404);
});

test('complete verifies range, MIME and magic bytes then advances through the RPC', async () => {
  const calls = [];
  const result = await invoke(completeHandler, { method: 'POST', query: { batchId },
    headers: { 'idempotency-key': 'complete-key-one' }, request: async (url, options) => {
      calls.push({ url: String(url), options }); const value = String(url);
      if (auth(url)) return response(200, { id: userId });
      if (value.includes('/garment_batches')) return response(200, [batch()]);
      if (value.includes('/garment_assets')) return response(200, [asset()]);
      if (value.includes('/object/authenticated/')) return response(206, new Uint8Array([0xff, 0xd8, 0xff]),
        { 'content-range': 'bytes 0-2/3', 'content-type': 'image/jpeg' });
      if (value.includes('/rpc/complete_my_garment_upload')) return response(200, { batch: batch('uploaded'), invalid: false });
      assert.fail(`unexpected request ${url}`);
    } });
  assert.equal(result.statusCode, 200);
  assert.deepEqual(result.body, batch('uploaded'));
  assert.equal(calls.find(call => call.url.includes('/object/authenticated/')).options.headers.Range, 'bytes=0-65535');
  assert.deepEqual(JSON.parse(calls.find(call => call.url.includes('/rpc/')).options.body), {
    p_batch_id: batchId, p_idempotency_key: 'complete-key-one', p_outcome: 'valid'
  });
});

test('missing upload is retryable; invalid bytes terminate through the invalid outcome', async () => {
  const baseRequest = async (url, options, invalid = false) => {
    const value = String(url);
    if (auth(url)) return response(200, { id: userId });
    if (value.includes('/garment_batches')) return response(200, [batch()]);
    if (value.includes('/garment_assets')) return response(200, [asset()]);
    if (value.includes('/object/authenticated/')) return invalid
      ? response(206, new Uint8Array([1, 2, 3]), { 'content-range': 'bytes 0-2/3', 'content-type': 'image/jpeg' })
      : response(404, { message: 'not found' });
    if (value.includes('/rpc/')) {
      assert.equal(JSON.parse(options.body).p_outcome, 'invalid');
      return response(200, { batch: batch('failed'), invalid: true });
    }
  };
  const missing = await invoke(completeHandler, { method: 'POST', query: { batchId }, headers: { 'idempotency-key': 'complete-key-one' },
    request: (url, options) => baseRequest(url, options, false) });
  assert.equal(missing.statusCode, 409);
  assert.equal(missing.body.error.code, 'UPLOAD_NOT_FOUND');
  assert.equal(missing.body.error.retryable, true);
  const invalid = await invoke(completeHandler, { method: 'POST', query: { batchId }, headers: { 'idempotency-key': 'complete-key-two' },
    request: (url, options) => baseRequest(url, options, true) });
  assert.equal(invalid.statusCode, 422);
});

test('complete is replay-safe for already advanced batches and invalid paths fail locally', async () => {
  let calls = 0;
  const replay = await invoke(completeHandler, { method: 'POST', query: { batchId }, headers: { 'idempotency-key': 'complete-key-one' },
    request: async url => { calls += 1; if (auth(url)) return response(200, { id: userId });
      if (String(url).includes('/rpc/')) return response(200, { batch: batch('processing'), invalid: false });
      return response(200, [batch('processing')]); } });
  assert.equal(replay.statusCode, 200);
  assert.equal(replay.body.status, 'processing');
  assert.equal(calls, 3);
  const invalid = await invoke(completeHandler, { method: 'POST', query: { batchId: 'bad' },
    headers: { 'idempotency-key': 'complete-key-one' }, request: async () => assert.fail('network called') });
  assert.equal(invalid.statusCode, 422);
});
