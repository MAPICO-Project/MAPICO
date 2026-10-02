import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { createHandler } from '../api/internal/analysis-jobs/[jobId]/result.js';

const requestId = '11111111-1111-4111-8111-111111111111';
const userId = '22222222-2222-4222-8222-222222222222';
const batchId = '33333333-3333-4333-8333-333333333333';
const jobId = '44444444-4444-4444-8444-444444444444';
const eventId = '55555555-5555-4555-8555-555555555555';
const lease = '66666666-6666-4666-8666-666666666666';
const secret = 'fixture-hmac-secret-that-is-at-least-32-bytes';
const service = 'fixture-server-secret-key-long-enough';
const timestamp = '1790823600';
const env = { SUPABASE_URL: 'https://abcdefghijklmnopqrst.supabase.co', SUPABASE_PUBLISHABLE_KEY: 'publishable-test',
  SUPABASE_SECRET_KEY: service, AI_CALLBACK_HMAC_SECRET: secret };

function payload(overrides = {}) { return { event_id: eventId, attempt: 1, status: 'succeeded', model_versions: { attributes: 'fixture-v1' },
  items: [{ client_item_key: 'item-0', bbox: [0.1, 0.1, 0.9, 0.9],
    mask_object_key: `${userId}/${batchId}/cutouts/item-0.png`, attributes: { category: 'top' }, confidence: 0.9, item_index: 0 }],
  errors: [], job_id: jobId, lease_token: lease, ...overrides }; }
function response(status, body, headers = {}) { const bytes = body instanceof Uint8Array ? body : null; return { status,
  headers: { get: name => headers[name.toLowerCase()] ?? null }, async json() { if (bytes) throw Error('no json'); return body; },
  async arrayBuffer() { return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength); } }; }
function invoke({ value = payload(), raw, signature, request, headers = {}, query = { jobId } } = {}) {
  const rawBody = raw ?? Buffer.from(JSON.stringify(value)); const sig = signature ?? createHmac('sha256', secret).update(timestamp).update('.').update(rawBody).digest('hex');
  const result = { headers: {}, statusCode: 200 }; const req = { method: 'POST', query,
    headers: { 'x-worker-timestamp': timestamp, 'x-worker-signature': sig, ...headers } };
  const res = { setHeader(k, v) { result.headers[k] = v; }, status(v) { result.statusCode = v; return this; }, json(v) { result.body = v; return result; } };
  return createHandler({ env, request, rawBody, createRequestId: () => requestId,
    now: () => new Date(Number(timestamp) * 1000) })(req, res);
}
function successRequest(calls) { return async (url, options) => { calls.push({ url: String(url), options }); const value = String(url);
  if (value.includes('/rpc/inspect_analysis_callback')) return response(200, { replayed: false, job: { id: jobId, user_id: userId, batch_id: batchId,
    status: 'running', attempt: 1, lease_token: lease, lease_expires_at: '2026-10-01T03:10:00.000Z' } });
  if (value.includes('/rpc/get_analysis_cutout_fence')) return response(200, { object_id: '77777777-7777-4777-8777-777777777777',
    object_updated_at: '2026-10-01T03:01:00.000Z' });
  if (value.includes('/storage/v1/object/authenticated/')) return response(206, new Uint8Array([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]),
    { 'content-type': 'image/png', 'content-range': 'bytes 0-7/321' });
  if (value.includes('/rpc/apply_analysis_result')) return response(200, { job_id: jobId, event_id: eventId, applied: true });
  assert.fail(`unexpected ${value}`);
}; }

test('valid raw-body HMAC callback verifies Storage and calls only the service-only RPC', async () => {
  const calls = []; const result = await invoke({ request: successRequest(calls) });
  assert.equal(result.statusCode, 200); assert.deepEqual(result.body, { job_id: jobId, event_id: eventId, applied: true });
  assert.equal(calls.length, 4);
  for (const call of calls) { assert.equal(call.options.headers.apikey, service); assert.equal(call.options.headers.Authorization, `Bearer ${service}`); }
  const rpc = JSON.parse(calls[3].options.body); assert.equal(rpc.p_items[0].mask_object_key, payload().items[0].mask_object_key);
  assert.equal(rpc.p_items[0].content_type, 'image/png'); assert.equal(rpc.p_items[0].byte_size, 321);
  assert.equal(rpc.p_items[0].storage_object_id, '77777777-7777-4777-8777-777777777777');
  assert.equal(JSON.stringify(result).includes(secret), false); assert.equal(JSON.stringify(result).includes(service), false);
});

test('tampered body, stale timestamp, malformed signature and path mismatch stop before network', async () => {
  const signedRaw = Buffer.from(JSON.stringify(payload()));
  const signature = createHmac('sha256', secret).update(timestamp).update('.').update(signedRaw).digest('hex');
  const tampered = await invoke({ raw: Buffer.from(JSON.stringify(payload({ attempt: 2 }))), signature, request: async () => assert.fail('network') });
  assert.equal(tampered.statusCode, 401);
  const stale = await invoke({ headers: { 'x-worker-timestamp': '1' }, request: async () => assert.fail('network') }); assert.equal(stale.statusCode, 401);
  const malformed = await invoke({ signature: 'not-hex', request: async () => assert.fail('network') }); assert.equal(malformed.statusCode, 401);
  const mismatchValue = payload({ job_id: eventId });
  const mismatch = await invoke({ value: mismatchValue, request: async () => assert.fail('network') }); assert.equal(mismatch.statusCode, 422);
});

test('invalid cutout path and stale lease fail closed without applying a callback', async () => {
  let calls = 0;
  const invalidPath = payload({ items: [{ ...payload().items[0], mask_object_key: `${userId}/other/cutouts/item-0.png` }] });
  const pathResult = await invoke({ value: invalidPath, request: async (url) => { calls += 1;
    return response(200, { replayed: false, job: { id: jobId, user_id: userId, batch_id: batchId, status: 'running', attempt: 1,
      lease_token: lease, lease_expires_at: '2026-10-01T03:10:00.000Z' } }); } });
  assert.equal(pathResult.statusCode, 422); assert.equal(calls, 1);
  const stale = await invoke({ request: async () => response(200, { replayed: false, job: { id: jobId, user_id: userId, batch_id: batchId,
    status: 'running', attempt: 2, lease_token: lease, lease_expires_at: '2026-10-01T03:10:00.000Z' } }) });
  assert.equal(stale.statusCode, 409);
});

test('durable callback replay returns before mutable job and Storage checks', async () => {
  const calls = [];
  const result = await invoke({ request: async (url, options) => {
    calls.push({ url: String(url), options });
    if (String(url).includes('/rpc/inspect_analysis_callback')) return response(200, { replayed: true,
      response: { job_id: jobId, event_id: eventId, applied: true } });
    assert.fail('replay must not read mutable job or Storage');
  } });
  assert.equal(result.statusCode, 200);
  assert.deepEqual(result.body, { job_id: jobId, event_id: eventId, applied: false });
  assert.equal(calls.length, 1);
});

test('missing internal secrets fail closed and are never returned', async () => {
  const rawBody = Buffer.from(JSON.stringify(payload())); const result = { headers: {} };
  const handler = createHandler({ env: { SUPABASE_URL: env.SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY: env.SUPABASE_PUBLISHABLE_KEY },
    rawBody, createRequestId: () => requestId, now: () => new Date(Number(timestamp) * 1000), request: async () => assert.fail('network') });
  await handler({ method: 'POST', query: { jobId }, headers: { 'x-worker-timestamp': timestamp, 'x-worker-signature': 'a'.repeat(64) } },
    { setHeader(k, v) { result.headers[k] = v; }, status(v) { result.statusCode = v; return this; }, json(v) { result.body = v; return result; } });
  assert.equal(result.statusCode, 503); assert.equal(JSON.stringify(result).includes('SECRET'), false);
});
