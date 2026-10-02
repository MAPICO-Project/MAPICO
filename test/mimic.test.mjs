import test from 'node:test';
import assert from 'node:assert/strict';
import { createHandler as createMimic } from '../api/v1/mimic-jobs/index.js';
import { createHandler as getMimic } from '../api/v1/mimic-jobs/[jobId].js';

const requestId = '11111111-1111-4111-8111-111111111111';
const userId = '22222222-2222-4222-8222-222222222222';
const postId = '33333333-3333-4333-8333-333333333333';
const jobId = '44444444-4444-4444-8444-444444444444';
const garmentId = '55555555-5555-4555-8555-555555555555';
const mediaId = '66666666-6666-4666-8666-666666666666';
const env = { SUPABASE_URL: 'https://abcdefghijklmnopqrst.supabase.co', SUPABASE_PUBLISHABLE_KEY: 'publishable-test' };

function response(status, body, headers = {}) {
  return { status, headers: { get: name => headers[name.toLowerCase()] ?? null }, async json() { return body; } };
}
function invoke(create, request, { method = 'GET', query = {}, body, headers = {} } = {}) {
  const out = { headers: {} }; const reqHeaders = { authorization: 'Bearer header.payload.signature', ...headers };
  if (body !== undefined && !reqHeaders['content-type']) reqHeaders['content-type'] = 'application/json';
  const req = { method, query, body, headers: reqHeaders };
  const res = { setHeader(k, v) { out.headers[k] = v; }, status(v) { out.statusCode = v; return this; },
    json(v) { out.body = v; return out; }, end() { out.ended = true; return out; } };
  return create({ env, request, createRequestId: () => requestId })(req, res);
}
function projected(status = 'queued', overrides = {}) {
  const base = { id: jobId, post_id: postId, status, matches: [], model_version: null, coverage: null, error: null };
  if (status === 'succeeded') Object.assign(base, { matches: [{ source_item_key: `media:${mediaId}`, garment_id: garmentId,
    similarity: 0.75, reason: `model echoed media:${mediaId}` }], model_version: 'mimic-v1', coverage: 1 });
  if (status === 'no_match') Object.assign(base, { matches: [{ source_item_key: `media:${mediaId}`, garment_id: null,
    similarity: null, reason: 'none' }], model_version: 'mimic-v1', coverage: 0 });
  if (status === 'failed') Object.assign(base, { error: { code: 'WORKER_TIMEOUT', message: 'retry later', retryable: true } });
  return { ...base, ...overrides };
}
function auth(url) { return String(url).includes('/auth/v1/user'); }

test('create uses exact idempotent RPC arguments and returns queued 202', async () => {
  const calls = [];
  const result = await invoke(createMimic, async (url, options) => {
    calls.push({ url: String(url), options }); return auth(url) ? response(200, { id: userId }) : response(200, projected());
  }, { method: 'POST', headers: { 'idempotency-key': 'mimic-one' }, body: { post_id: postId } });
  assert.equal(result.statusCode, 202); assert.deepEqual(result.body.matches, []);
  assert.match(calls[1].url, /\/rpc\/create_my_mimic_job$/);
  assert.deepEqual(JSON.parse(calls[1].options.body), { p_post_id: postId, p_idempotency_key: 'mimic-one' });
});

test('get supports every safe terminal projection and hides the feed media identifier', async () => {
  for (const status of ['queued', 'running', 'succeeded', 'no_match', 'failed']) {
    const result = await invoke(getMimic, async url => auth(url) ? response(200, { id: userId }) : response(200, projected(status)),
      { query: { jobId } });
    assert.equal(result.statusCode, 200, status); assert.equal(result.body.status, status);
    assert.equal(JSON.stringify(result.body).includes(mediaId), false);
    assert.equal(JSON.stringify(result.body).includes('model echoed'), false);
    if (['succeeded', 'no_match'].includes(status)) assert.equal(result.body.matches[0].source_item_key, 'source-1');
    if (status === 'failed') assert.equal(result.body.error.request_id, requestId);
  }
});

test('malformed inputs fail before auth and unknown or unsafe projection fields fail closed', async () => {
  const invalid = await invoke(createMimic, async () => assert.fail('network'), { method: 'POST',
    headers: { 'idempotency-key': 'short' }, body: { post_id: postId, status: 'queued' } });
  assert.equal(invalid.statusCode, 422);
  for (const row of [projected('succeeded', { lease_token: 'secret' }), projected('succeeded', { coverage: 2 }),
    projected('succeeded', { matches: [{ source_item_key: `media:${mediaId}`, garment_id: garmentId, similarity: NaN, reason: 'x' }] })]) {
    const result = await invoke(getMimic, async url => auth(url) ? response(200, { id: userId }) : response(200, row), { query: { jobId } });
    assert.equal(result.statusCode, 500);
  }
});

test('DB privacy, conflict, and open-limit errors map to stable HTTP errors', async () => {
  const cases = [
    [{ code: 'P0002', message: 'mimic_job_not_found' }, 404, 'MIMIC_JOB_NOT_FOUND'],
    [{ code: 'P0001', message: 'feed_media_unavailable' }, 409, 'MIMIC_CONFLICT'],
    [{ code: 'P0001', message: 'mimic_open_limit' }, 429, 'RATE_LIMITED']
  ];
  for (const [upstream, status, code] of cases) {
    const result = await invoke(createMimic, async url => auth(url) ? response(200, { id: userId }) : response(400, upstream),
      { method: 'POST', headers: { 'idempotency-key': 'mimic-one' }, body: { post_id: postId } });
    assert.equal(result.statusCode, status); assert.equal(result.body.error.code, code);
  }
});

test('GET rejects extra query and body before any network request', async () => {
  const extra = await invoke(getMimic, async () => assert.fail('network'), { query: { jobId, include: 'raw' } });
  assert.equal(extra.statusCode, 400);
  const body = await invoke(getMimic, async () => assert.fail('network'), { query: { jobId }, body: {} });
  assert.equal(body.statusCode, 400);
});
