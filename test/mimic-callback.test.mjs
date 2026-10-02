import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { createHandler } from '../api/internal/mimic-jobs/[jobId]/result.js';

const requestId = '11111111-1111-4111-8111-111111111111';
const userId = '22222222-2222-4222-8222-222222222222';
const postId = '33333333-3333-4333-8333-333333333333';
const jobId = '44444444-4444-4444-8444-444444444444';
const eventId = '55555555-5555-4555-8555-555555555555';
const lease = '66666666-6666-4666-8666-666666666666';
const garmentId = '77777777-7777-4777-8777-777777777777';
const secret = 'fixture-hmac-secret-that-is-at-least-32-bytes';
const service = 'fixture-server-secret-key-long-enough';
const timestamp = '1790823600';
const env = { SUPABASE_URL: 'https://abcdefghijklmnopqrst.supabase.co', SUPABASE_PUBLISHABLE_KEY: 'publishable-test',
  SUPABASE_SECRET_KEY: service, AI_CALLBACK_HMAC_SECRET: secret };

function payload(overrides = {}) {
  return { event_id: eventId, job_id: jobId, attempt: 1, lease_token: lease, status: 'succeeded', model_version: 'mimic-v1',
    matches: [{ source_item_key: 'media-0', garment_id: garmentId, similarity: 0.82, reason: 'similar silhouette' }],
    coverage: 1, error_code: null, ...overrides };
}
function response(status, body) {
  return { status, headers: { get: () => null }, async json() { return body; } };
}
function signature(raw, prefix = 'mimic.v1') {
  return createHmac('sha256', secret).update(prefix).update('.').update(timestamp).update('.').update(raw).digest('hex');
}
function invoke({ value = payload(), raw, signed, request, headers = {}, query = { jobId }, method = 'POST', customEnv = env } = {}) {
  const rawBody = raw ?? Buffer.from(JSON.stringify(value));
  const result = { headers: {}, statusCode: 200 };
  const req = { method, query, headers: { 'x-worker-timestamp': timestamp, 'x-worker-signature': signed ?? signature(rawBody), ...headers } };
  const res = { setHeader(k, v) { result.headers[k] = v; }, status(v) { result.statusCode = v; return this; }, json(v) { result.body = v; return result; } };
  return createHandler({ env: customEnv, request, rawBody, createRequestId: () => requestId,
    now: () => new Date(Number(timestamp) * 1000) })(req, res);
}
function runningJob() {
  return { id: jobId, user_id: userId, post_id: postId, status: 'running', attempt: 1, lease_token: lease,
    lease_expires_at: '2026-10-01T03:10:00.000Z', absolute_deadline: '2026-10-01T05:00:00.000Z' };
}

test('domain-separated valid callback inspects replay first and applies exact RPC shape', async () => {
  const calls = [];
  const result = await invoke({ request: async (url, options) => {
    calls.push({ url: String(url), options }); const value = String(url);
    if (value.includes('/rpc/inspect_mimic_callback')) return response(200, { replayed: false, job: runningJob() });
    if (value.includes('/rpc/apply_mimic_result')) return response(200, { job_id: jobId, event_id: eventId, applied: true });
    assert.fail(`unexpected ${value}`);
  } });
  assert.equal(result.statusCode, 200);
  assert.deepEqual(result.body, { job_id: jobId, event_id: eventId, applied: true });
  assert.equal(calls.length, 2);
  assert.match(calls[0].url, /inspect_mimic_callback/); assert.match(calls[1].url, /apply_mimic_result/);
  const applied = JSON.parse(calls[1].options.body);
  assert.deepEqual(Object.keys(applied).sort(), ['p_attempt','p_coverage','p_error_code','p_event_id','p_job_id','p_lease_token','p_matches','p_model_version','p_payload_hash','p_status']);
  assert.deepEqual(applied.p_matches, payload().matches); assert.equal(applied.p_coverage, 1);
  for (const call of calls) { assert.equal(call.options.headers.apikey, service); assert.equal(call.options.headers.Authorization, `Bearer ${service}`); }
  assert.equal(JSON.stringify(result).includes(secret), false); assert.equal(JSON.stringify(result).includes(service), false);
});

test('legacy non-domain signature, tampered body, stale timestamp and path mismatch stop before network', async () => {
  const raw = Buffer.from(JSON.stringify(payload()));
  const legacy = createHmac('sha256', secret).update(timestamp).update('.').update(raw).digest('hex');
  assert.equal((await invoke({ raw, signed: legacy, request: async () => assert.fail('network') })).statusCode, 401);
  const valid = signature(raw);
  assert.equal((await invoke({ raw: Buffer.from(JSON.stringify(payload({ attempt: 2 }))), signed: valid,
    request: async () => assert.fail('network') })).statusCode, 401);
  assert.equal((await invoke({ headers: { 'x-worker-timestamp': '1' }, request: async () => assert.fail('network') })).statusCode, 401);
  assert.equal((await invoke({ value: payload({ job_id: eventId }), request: async () => assert.fail('network') })).statusCode, 422);
});

test('exact match and status schemas reject malformed callbacks before service access', async () => {
  const extra = payload({ matches: [{ ...payload().matches[0], raw_vector: [1, 2] }] });
  assert.equal((await invoke({ value: extra, request: async () => assert.fail('network') })).statusCode, 422);
  const badNoMatch = payload({ status: 'no_match', model_version: 'mimic-v1',
    matches: [{ source_item_key: 'media-0', garment_id: garmentId, similarity: 0.1, reason: 'bad' }], coverage: 0, error_code: null });
  assert.equal((await invoke({ value: badNoMatch, request: async () => assert.fail('network') })).statusCode, 422);
  const failed = payload({ status: 'failed', model_version: null, matches: [], coverage: null, error_code: 'WORKER_TIMEOUT' });
  const result = await invoke({ value: failed, request: async (url) => String(url).includes('/inspect_mimic_callback')
    ? response(200, { replayed: false, job: runningJob() })
    : response(200, { job_id: jobId, event_id: eventId, applied: true }) });
  assert.equal(result.statusCode, 200);
});

test('durable replay returns before mutable lease checks and apply RPC', async () => {
  const calls = [];
  const result = await invoke({ request: async (url) => {
    calls.push(String(url));
    if (String(url).includes('/rpc/inspect_mimic_callback')) return response(200, { replayed: true,
      response: { job_id: jobId, event_id: eventId, applied: true } });
    assert.fail('replay must not inspect mutable lease or apply');
  } });
  assert.equal(result.statusCode, 200);
  assert.deepEqual(result.body, { job_id: jobId, event_id: eventId, applied: false });
  assert.equal(calls.length, 1);
});

test('stale lease and missing secrets fail closed', async () => {
  const stale = await invoke({ request: async () => response(200, { replayed: false, job: { ...runningJob(), attempt: 2 } }) });
  assert.equal(stale.statusCode, 409);
  const noSecret = { SUPABASE_URL: env.SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY: env.SUPABASE_PUBLISHABLE_KEY };
  const missing = await invoke({ customEnv: noSecret, request: async () => assert.fail('network') });
  assert.equal(missing.statusCode, 503); assert.equal(JSON.stringify(missing).includes('SECRET'), false);
});
